[CmdletBinding()]
param(
    [ValidateSet('gui', 'status', 'arm', 'disarm', 'signal', 'cancel', 'process-once', 'task-start', 'task-waiting', 'task-idle', 'task-status')]
    [string]$Mode = 'gui',

    [ValidateRange(30, 3600)]
    [int]$DelaySeconds = 120,

    [string]$TaskSummary = 'Codex task completed',

    [string]$TaskId,

    [string]$StateDirectory,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 evaluates parameter defaults before $PSScriptRoot is
# populated for a script started with -File. Resolve the default in the body.
if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
    $StateDirectory = Join-Path -Path $PSScriptRoot -ChildPath '.state'
}

if ([string]::IsNullOrWhiteSpace($TaskId)) {
    $TaskId = $env:CODEX_THREAD_ID
}
if ([string]::IsNullOrWhiteSpace($TaskId)) {
    $TaskId = 'manual-default'
}

$StateFile = Join-Path $StateDirectory 'guard-state.json'
$TaskStateFile = Join-Path $StateDirectory 'task-state.json'
$SignalsDirectory = Join-Path $StateDirectory 'signals'

function Get-UtcTimestamp {
    return [DateTime]::UtcNow.ToString('o')
}

function Initialize-StateStorage {
    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $SignalsDirectory)) {
        New-Item -ItemType Directory -Path $SignalsDirectory -Force | Out-Null
    }
}

function New-DefaultState {
    return [pscustomobject][ordered]@{
        version          = 1
        armed            = $false
        armedAtUtc       = $null
        delaySeconds     = 120
        shutdownPending  = $false
        shutdownAtUtc    = $null
        lastEvent        = '守卫默认关闭'
        lastEventAtUtc   = (Get-UtcTimestamp)
        lastTaskSummary  = $null
        dryRun           = $false
    }
}

function Read-GuardState {
    Initialize-StateStorage

    if (-not (Test-Path -LiteralPath $StateFile)) {
        $state = New-DefaultState
        Write-GuardState -State $state
        return $state
    }

    try {
        $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $state.version -or [int]$state.version -ne 1) {
            throw '不支持的状态文件版本。'
        }
        return $state
    }
    catch {
        $backup = Join-Path $StateDirectory ("guard-state.corrupt-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $StateFile -Destination $backup -Force
        $state = New-DefaultState
        $state.lastEvent = '损坏的状态文件已备份，守卫已安全关闭'
        Write-GuardState -State $state
        return $state
    }
}

function Write-GuardState {
    param([Parameter(Mandatory)]$State)

    Initialize-StateStorage
    $temporaryFile = Join-Path $StateDirectory ("guard-state.{0}.{1}.tmp" -f $PID, [Guid]::NewGuid().ToString('N'))
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryFile -Encoding UTF8
    Move-Item -LiteralPath $temporaryFile -Destination $StateFile -Force
}

function New-DefaultTaskState {
    return [pscustomobject][ordered]@{
        version              = 2
        activeTasks          = @()
        lastCompletedTaskId  = $null
        lastCompletedSummary = $null
        lastCompletedAtUtc   = $null
        updatedAtUtc         = (Get-UtcTimestamp)
    }
}

function Invoke-WithTaskStateLock {
    param([Parameter(Mandatory)][scriptblock]$Action)

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, 'Local\CodexAutoShutdownTaskState', [ref]$createdNew)
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne(10000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }

        if (-not $lockTaken) {
            throw '等待任务状态锁超时。'
        }

        return & $Action
    }
    finally {
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Write-TaskState {
    param([Parameter(Mandatory)]$TaskState)

    Initialize-StateStorage
    $temporaryFile = Join-Path $StateDirectory ("task-state.{0}.{1}.tmp" -f $PID, [Guid]::NewGuid().ToString('N'))
    $TaskState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryFile -Encoding UTF8
    Move-Item -LiteralPath $temporaryFile -Destination $TaskStateFile -Force
}

function Convert-LegacyTaskState {
    param([Parameter(Mandatory)]$LegacyState)

    $taskState = New-DefaultTaskState
    if ([string]$LegacyState.status -eq 'completed') {
        $taskState.lastCompletedTaskId = [string]$LegacyState.taskId
        $taskState.lastCompletedSummary = [string]$LegacyState.summary
        $taskState.lastCompletedAtUtc = [string]$LegacyState.completedAtUtc
    }
    $taskState.updatedAtUtc = Get-UtcTimestamp
    return $taskState
}

function Read-TaskState {
    return Invoke-WithTaskStateLock -Action {
        Initialize-StateStorage

        if (-not (Test-Path -LiteralPath $TaskStateFile)) {
            $taskState = New-DefaultTaskState
            Write-TaskState -TaskState $taskState
            return $taskState
        }

        try {
            $taskState = Get-Content -LiteralPath $TaskStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $taskState.version) {
                throw '任务状态文件缺少版本号。'
            }
            if ([int]$taskState.version -eq 1) {
                $taskState = Convert-LegacyTaskState -LegacyState $taskState
                Write-TaskState -TaskState $taskState
            }
            elseif ([int]$taskState.version -ne 2) {
                throw '不支持的任务状态文件版本。'
            }
            return $taskState
        }
        catch {
            $backup = Join-Path $StateDirectory ("task-state.corrupt-{0}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
            Copy-Item -LiteralPath $TaskStateFile -Destination $backup -Force
            $taskState = New-DefaultTaskState
            Write-TaskState -TaskState $taskState
            return $taskState
        }
    }
}

function Get-SafeTaskSummary {
    param([string]$Summary)

    $trimmedSummary = if ([string]::IsNullOrWhiteSpace($Summary)) { 'Codex task' } else { $Summary.Trim() }
    if ($trimmedSummary.Length -gt 200) {
        $trimmedSummary = $trimmedSummary.Substring(0, 200)
    }
    return $trimmedSummary
}

function Set-TaskActivity {
    param(
        [ValidateSet('running', 'waiting', 'completed', 'idle')]
        [string]$Status,
        [string]$Summary,
        [Parameter(Mandatory)][string]$Id
    )

    return Invoke-WithTaskStateLock -Action {
        $now = Get-UtcTimestamp
        $taskState = Read-TaskState
        $safeSummary = Get-SafeTaskSummary -Summary $Summary
        $tasks = @($taskState.activeTasks)
        $existingTask = $tasks | Where-Object { [string]$_.taskId -eq $Id } | Select-Object -First 1

        switch ($Status) {
            'running' {
                if ($null -eq $existingTask) {
                    $tasks += [pscustomobject][ordered]@{
                        taskId       = $Id
                        status       = 'running'
                        summary      = $safeSummary
                        startedAtUtc = $now
                        updatedAtUtc = $now
                    }
                }
                else {
                    $existingTask.status = 'running'
                    $existingTask.summary = $safeSummary
                    $existingTask.updatedAtUtc = $now
                }
            }
            'waiting' {
                if ($null -eq $existingTask) {
                    $tasks += [pscustomobject][ordered]@{
                        taskId       = $Id
                        status       = 'waiting'
                        summary      = $safeSummary
                        startedAtUtc = $now
                        updatedAtUtc = $now
                    }
                }
                else {
                    $existingTask.status = 'waiting'
                    $existingTask.summary = $safeSummary
                    $existingTask.updatedAtUtc = $now
                }
            }
            'completed' {
                $tasks = @($tasks | Where-Object { [string]$_.taskId -ne $Id })
                $taskState.lastCompletedTaskId = $Id
                $taskState.lastCompletedSummary = $safeSummary
                $taskState.lastCompletedAtUtc = $now
            }
            'idle' {
                $tasks = @($tasks | Where-Object { [string]$_.taskId -ne $Id })
            }
        }

        $taskState.activeTasks = @($tasks)
        $taskState.updatedAtUtc = $now
        Write-TaskState -TaskState $taskState
        return $taskState
    }
}

function Clear-StaleSignals {
    Initialize-StateStorage
    Get-ChildItem -LiteralPath $SignalsDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.processed.json' } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Set-GuardArmed {
    param([int]$Seconds)

    $existingState = Read-GuardState
    if ([bool]$existingState.shutdownPending) {
        $null = Stop-SystemShutdown
    }

    Clear-StaleSignals
    $state = Read-GuardState
    $state.armed = $true
    $state.armedAtUtc = Get-UtcTimestamp
    $state.delaySeconds = $Seconds
    $state.shutdownPending = $false
    $state.shutdownAtUtc = $null
    $state.lastTaskSummary = $null
    $state.lastEvent = '已开启：等待下一次成功完成信号'
    $state.lastEventAtUtc = Get-UtcTimestamp
    $state.dryRun = [bool]$DryRun
    Write-GuardState -State $state
    return $state
}

function Set-GuardDisarmed {
    param([string]$Reason = '已由用户关闭')

    $state = Read-GuardState
    $state.armed = $false
    $state.armedAtUtc = $null
    $state.shutdownPending = $false
    $state.shutdownAtUtc = $null
    $state.lastEvent = $Reason
    $state.lastEventAtUtc = Get-UtcTimestamp
    Write-GuardState -State $state
    return $state
}

function Write-CompletionSignal {
    param(
        [string]$Summary,
        [Parameter(Mandatory)][string]$Id
    )

    Initialize-StateStorage
    $trimmedSummary = Get-SafeTaskSummary -Summary $Summary
    $taskState = Set-TaskActivity -Status completed -Summary $trimmedSummary -Id $Id
    $remainingActiveTasks = @($taskState.activeTasks).Count

    $signalId = [Guid]::NewGuid().ToString('N')
    $signalPath = Join-Path $SignalsDirectory ("{0}-{1}.json" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff'), $signalId)
    $signal = [pscustomobject][ordered]@{
        version      = 2
        id           = $signalId
        eventType    = 'task-completed'
        taskId       = $Id
        createdAtUtc = Get-UtcTimestamp
        summary      = $trimmedSummary
        remainingActiveTasks = $remainingActiveTasks
        processId    = $PID
    }
    $signal | ConvertTo-Json | Set-Content -LiteralPath $signalPath -Encoding UTF8

    return [pscustomobject]@{
        signaled   = $true
        signalId  = $signalId
        summary   = $trimmedSummary
        guardArmed = [bool](Read-GuardState).armed
        taskStatus = $(if ($remainingActiveTasks -gt 0) { 'active-tasks-remain' } else { 'all-tasks-completed' })
        remainingActiveTasks = $remainingActiveTasks
    }
}

function Get-NextCompletionSignal {
    param([Parameter(Mandatory)]$State)

    if (-not [bool]$State.armed -or [string]::IsNullOrWhiteSpace([string]$State.armedAtUtc)) {
        return $null
    }

    $armedAt = [DateTime]::Parse([string]$State.armedAtUtc).ToUniversalTime()
    foreach ($file in (Get-ChildItem -LiteralPath $SignalsDirectory -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)) {
        if ($file.Name -like '*.processed.json') {
            continue
        }

        try {
            $signal = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $createdAt = [DateTime]::Parse([string]$signal.createdAtUtc).ToUniversalTime()
            if ($createdAt -ge $armedAt) {
                return [pscustomobject]@{
                    File   = $file
                    Signal = $signal
                }
            }
        }
        catch {
            # A partially written or invalid signal is ignored and can be retried on the next tick.
        }
    }

    return $null
}

function Get-ShutdownExecutable {
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $candidate = Join-Path $env:SystemRoot 'System32\shutdown.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return 'shutdown.exe'
}

function Invoke-SystemShutdown {
    param([int]$Seconds)

    if ($DryRun) {
        return [pscustomobject]@{ success = $true; dryRun = $true; exitCode = 0 }
    }

    $shutdownExecutable = Get-ShutdownExecutable
    $comment = 'Codex 任务已完成。关机守卫将在倒计时结束后关机；可在守卫中取消。'
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $shutdownExecutable /s /t $Seconds /d p:0:0 /c $comment 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{ success = ($exitCode -eq 0); dryRun = $false; exitCode = $exitCode }
}

function Stop-SystemShutdown {
    if ($DryRun) {
        return [pscustomobject]@{ success = $true; dryRun = $true; exitCode = 0 }
    }

    $shutdownExecutable = Get-ShutdownExecutable
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & $shutdownExecutable /a 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    # shutdown /a returns a non-zero code when there was no pending shutdown.
    return [pscustomobject]@{ success = $true; dryRun = $false; exitCode = $exitCode }
}

function Invoke-CancelAndDisarm {
    $null = Stop-SystemShutdown
    return Set-GuardDisarmed -Reason '已关闭守卫并取消排定的关机'
}

function Resume-PendingShutdownForActiveTasks {
    $activeTaskCount = @((Read-TaskState).activeTasks).Count
    $state = Read-GuardState
    if (-not [bool]$state.shutdownPending -or $activeTaskCount -eq 0) {
        return [pscustomobject]@{ resumed = $false; activeTaskCount = $activeTaskCount }
    }

    $null = Stop-SystemShutdown
    $state.armed = $true
    $state.shutdownPending = $false
    $state.shutdownAtUtc = $null
    $state.lastEvent = "检测到 $activeTaskCount 个未完成任务，已取消倒计时并继续等待"
    $state.lastEventAtUtc = Get-UtcTimestamp
    Write-GuardState -State $state
    return [pscustomobject]@{ resumed = $true; activeTaskCount = $activeTaskCount }
}

function Invoke-ProcessSignalOnce {
    $state = Read-GuardState
    if (-not [bool]$state.armed -or [bool]$state.shutdownPending) {
        return [pscustomobject]@{ processed = $false; reason = 'not-armed-or-already-pending' }
    }

    $pendingSignal = Get-NextCompletionSignal -State $state
    if ($null -eq $pendingSignal) {
        return [pscustomobject]@{ processed = $false; reason = 'no-new-signal' }
    }

    $activeTaskCount = @((Read-TaskState).activeTasks).Count
    $signalRemainingCount = 0
    if ($null -ne $pendingSignal.Signal.PSObject.Properties['remainingActiveTasks']) {
        $signalRemainingCount = [int]$pendingSignal.Signal.remainingActiveTasks
    }

    if ($activeTaskCount -gt 0 -or $signalRemainingCount -gt 0) {
        $processedPath = [IO.Path]::ChangeExtension($pendingSignal.File.FullName, '.processed.json')
        Move-Item -LiteralPath $pendingSignal.File.FullName -Destination $processedPath -Force
        $state.lastTaskSummary = [string]$pendingSignal.Signal.summary
        $state.lastEvent = "一个任务已完成，仍有 $activeTaskCount 个任务未完成"
        $state.lastEventAtUtc = Get-UtcTimestamp
        Write-GuardState -State $state
        return [pscustomobject]@{
            processed         = $true
            shutdownScheduled = $false
            reason            = 'active-tasks-remain'
            activeTaskCount   = $activeTaskCount
        }
    }

    $shutdownAt = [DateTime]::UtcNow.AddSeconds([int]$state.delaySeconds)
    $state.armed = $false
    $state.shutdownPending = $true
    $state.shutdownAtUtc = $shutdownAt.ToString('o')
    $state.lastTaskSummary = [string]$pendingSignal.Signal.summary
    $state.lastEvent = '收到成功完成信号，已进入关机倒计时'
    $state.lastEventAtUtc = Get-UtcTimestamp
    $state.dryRun = [bool]$DryRun
    Write-GuardState -State $state

    $shutdownResult = Invoke-SystemShutdown -Seconds ([int]$state.delaySeconds)
    if (-not [bool]$shutdownResult.success) {
        $state.shutdownPending = $false
        $state.shutdownAtUtc = $null
        $state.lastEvent = "无法排定关机，shutdown.exe 退出码：$($shutdownResult.exitCode)"
        $state.lastEventAtUtc = Get-UtcTimestamp
        Write-GuardState -State $state
        return [pscustomobject]@{ processed = $false; reason = 'shutdown-command-failed'; exitCode = $shutdownResult.exitCode }
    }

    $processedPath = [IO.Path]::ChangeExtension($pendingSignal.File.FullName, '.processed.json')
    Move-Item -LiteralPath $pendingSignal.File.FullName -Destination $processedPath -Force
    return [pscustomobject]@{
        processed       = $true
        dryRun          = [bool]$DryRun
        delaySeconds    = [int]$state.delaySeconds
        shutdownAtUtc   = $state.shutdownAtUtc
        taskSummary     = $state.lastTaskSummary
    }
}

function Write-JsonResult {
    param([Parameter(Mandatory)]$Value)
    $Value | ConvertTo-Json -Depth 6
}

function Start-GuardGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexGuardConsoleWindow
{
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Launch normally so WinForms may create a visible window, then hide only
    # the temporary PowerShell console opened by Explorer/cmd launchers.
    $consoleWindow = [CodexGuardConsoleWindow]::GetConsoleWindow()
    if ($consoleWindow -ne [IntPtr]::Zero) {
        $null = [CodexGuardConsoleWindow]::ShowWindow($consoleWindow, 0)
    }

    $showEventCreated = $false
    $showEvent = New-Object System.Threading.EventWaitHandle(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        'Local\CodexAutoShutdownGuardShowWindow',
        [ref]$showEventCreated
    )

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, 'Local\CodexAutoShutdownGuard', [ref]$createdNew)
    if (-not $createdNew) {
        $null = $showEvent.Set()
        $showEvent.Dispose()
        $mutex.Dispose()
        return
    }

    $stateOnStart = Read-GuardState
    if (-not [bool]$stateOnStart.shutdownPending) {
        $null = Set-GuardDisarmed -Reason '程序已启动，等待用户开启'
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Codex 任务完成自动关机'
    $form.Size = New-Object System.Drawing.Size(540, 500)
    $form.MinimumSize = New-Object System.Drawing.Size(540, 500)
    $form.MaximumSize = New-Object System.Drawing.Size(540, 500)
    $form.StartPosition = 'CenterScreen'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'Codex 任务完成自动关机'
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(24, 22)
    $form.Controls.Add($titleLabel)

    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = '实时显示任务检测状态；守卫收到成功完成信号后进入可取消倒计时。'
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.ForeColor = [System.Drawing.Color]::DimGray
    $subtitleLabel.Location = New-Object System.Drawing.Point(27, 66)
    $form.Controls.Add($subtitleLabel)

    $taskPanel = New-Object System.Windows.Forms.Panel
    $taskPanel.Location = New-Object System.Drawing.Point(28, 102)
    $taskPanel.Size = New-Object System.Drawing.Size(468, 82)
    $taskPanel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($taskPanel)

    $taskTitle = New-Object System.Windows.Forms.Label
    $taskTitle.Text = 'Codex 任务检测'
    $taskTitle.AutoSize = $true
    $taskTitle.ForeColor = [System.Drawing.Color]::DimGray
    $taskTitle.Location = New-Object System.Drawing.Point(15, 10)
    $taskPanel.Controls.Add($taskTitle)

    $taskLabel = New-Object System.Windows.Forms.Label
    $taskLabel.Text = '未检测到正在运行的任务'
    $taskLabel.AutoSize = $true
    $taskLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $taskLabel.Location = New-Object System.Drawing.Point(14, 38)
    $taskPanel.Controls.Add($taskLabel)

    $taskSummaryLabel = New-Object System.Windows.Forms.Label
    $taskSummaryLabel.Text = ''
    $taskSummaryLabel.AutoEllipsis = $true
    $taskSummaryLabel.TextAlign = 'MiddleRight'
    $taskSummaryLabel.ForeColor = [System.Drawing.Color]::DimGray
    $taskSummaryLabel.Location = New-Object System.Drawing.Point(270, 39)
    $taskSummaryLabel.Size = New-Object System.Drawing.Size(180, 24)
    $taskPanel.Controls.Add($taskSummaryLabel)

    $statusPanel = New-Object System.Windows.Forms.Panel
    $statusPanel.Location = New-Object System.Drawing.Point(28, 198)
    $statusPanel.Size = New-Object System.Drawing.Size(468, 82)
    $statusPanel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($statusPanel)

    $statusTitle = New-Object System.Windows.Forms.Label
    $statusTitle.Text = '自动关机守卫'
    $statusTitle.AutoSize = $true
    $statusTitle.ForeColor = [System.Drawing.Color]::DimGray
    $statusTitle.Location = New-Object System.Drawing.Point(15, 10)
    $statusPanel.Controls.Add($statusTitle)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Text = '关闭'
    $statusLabel.AutoSize = $true
    $statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $statusLabel.Location = New-Object System.Drawing.Point(14, 36)
    $statusPanel.Controls.Add($statusLabel)

    $delayLabel = New-Object System.Windows.Forms.Label
    $delayLabel.Text = '关机倒计时：'
    $delayLabel.AutoSize = $true
    $delayLabel.Location = New-Object System.Drawing.Point(28, 307)
    $form.Controls.Add($delayLabel)

    $delayInput = New-Object System.Windows.Forms.NumericUpDown
    $delayInput.Minimum = 30
    $delayInput.Maximum = 3600
    $delayInput.Increment = 30
    $delayInput.Value = [Math]::Max(30, [Math]::Min(3600, [int](Read-GuardState).delaySeconds))
    $delayInput.Location = New-Object System.Drawing.Point(134, 304)
    $delayInput.Size = New-Object System.Drawing.Size(88, 30)
    $form.Controls.Add($delayInput)

    $secondsLabel = New-Object System.Windows.Forms.Label
    $secondsLabel.Text = '秒（建议 120 秒）'
    $secondsLabel.AutoSize = $true
    $secondsLabel.ForeColor = [System.Drawing.Color]::DimGray
    $secondsLabel.Location = New-Object System.Drawing.Point(232, 307)
    $form.Controls.Add($secondsLabel)

    $armButton = New-Object System.Windows.Forms.Button
    $armButton.Text = '开启：等待下一次完成'
    $armButton.Location = New-Object System.Drawing.Point(28, 352)
    $armButton.Size = New-Object System.Drawing.Size(224, 44)
    $armButton.BackColor = [System.Drawing.Color]::FromArgb(30, 125, 70)
    $armButton.ForeColor = [System.Drawing.Color]::White
    $armButton.FlatStyle = 'Flat'
    $form.Controls.Add($armButton)

    $offButton = New-Object System.Windows.Forms.Button
    $offButton.Text = '关闭 / 取消关机'
    $offButton.Location = New-Object System.Drawing.Point(272, 352)
    $offButton.Size = New-Object System.Drawing.Size(224, 44)
    $form.Controls.Add($offButton)

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = '关闭窗口会缩到通知区域；从托盘菜单可完全退出。关机不使用强制关闭参数。'
    $hintLabel.AutoSize = $true
    $hintLabel.ForeColor = [System.Drawing.Color]::DimGray
    $hintLabel.Location = New-Object System.Drawing.Point(28, 420)
    $form.Controls.Add($hintLabel)

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Shield
    $notifyIcon.Text = 'Codex 关机守卫'
    $notifyIcon.Visible = $true

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $openMenuItem = $trayMenu.Items.Add('打开')
    $toggleMenuItem = $trayMenu.Items.Add('开启：等待下一次完成')
    $cancelMenuItem = $trayMenu.Items.Add('关闭 / 取消关机')
    $null = $trayMenu.Items.Add('-')
    $exitMenuItem = $trayMenu.Items.Add('退出守卫')
    $notifyIcon.ContextMenuStrip = $trayMenu

    $script:allowExit = $false
    $script:balloonShownForPending = $false

    $refreshUi = {
        $state = Read-GuardState
        $taskState = Read-TaskState
        $guardTrayState = '守卫已关闭'
        if ([bool]$state.shutdownPending) {
            $shutdownAt = [DateTime]::Parse([string]$state.shutdownAtUtc).ToUniversalTime()
            $remaining = [Math]::Max(0, [int][Math]::Ceiling(($shutdownAt - [DateTime]::UtcNow).TotalSeconds))
            $statusLabel.Text = "已排定关机：剩余 $remaining 秒"
            $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
            $statusPanel.BackColor = [System.Drawing.Color]::MistyRose
            $armButton.Enabled = $false
            $delayInput.Enabled = $false
            $toggleMenuItem.Enabled = $false
            $form.Text = "Codex 自动关机（倒计时 $remaining 秒）"
            $guardTrayState = "倒计时 $remaining 秒"

            if (-not $script:balloonShownForPending) {
                $notifyIcon.BalloonTipTitle = 'Codex 任务已完成'
                $notifyIcon.BalloonTipText = "电脑将在 $remaining 秒后关机。需要时请点击关闭 / 取消关机。"
                $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
                $notifyIcon.ShowBalloonTip(10000)
                $script:balloonShownForPending = $true
            }
        }
        elseif ([bool]$state.armed) {
            $statusLabel.Text = '已开启：等待下一次成功完成'
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
            $statusPanel.BackColor = [System.Drawing.Color]::Honeydew
            $armButton.Enabled = $false
            $delayInput.Enabled = $false
            $toggleMenuItem.Text = '已开启'
            $toggleMenuItem.Enabled = $false
            $form.Text = 'Codex 自动关机（已开启）'
            $guardTrayState = '守卫已开启'
            $script:balloonShownForPending = $false
        }
        else {
            $statusLabel.Text = '关闭：不会自动关机'
            $statusLabel.ForeColor = [System.Drawing.Color]::DimGray
            $statusPanel.BackColor = [System.Drawing.Color]::WhiteSmoke
            $armButton.Enabled = $true
            $delayInput.Enabled = $true
            $toggleMenuItem.Text = '开启：等待下一次完成'
            $toggleMenuItem.Enabled = $true
            $form.Text = 'Codex 自动关机（已关闭）'
            $guardTrayState = '守卫已关闭'
            $script:balloonShownForPending = $false
        }

        $activeTasks = @($taskState.activeTasks)
        $activeTaskCount = $activeTasks.Count
        if ($activeTaskCount -gt 0) {
            $runningTaskCount = @($activeTasks | Where-Object { [string]$_.status -eq 'running' }).Count
            $waitingTaskCount = $activeTaskCount - $runningTaskCount
            $oldestTask = $activeTasks | Sort-Object { [DateTime]::Parse([string]$_.startedAtUtc) } | Select-Object -First 1
            $latestTask = $activeTasks | Sort-Object { [DateTime]::Parse([string]$_.updatedAtUtc) } -Descending | Select-Object -First 1
            $elapsed = [DateTime]::UtcNow - [DateTime]::Parse([string]$oldestTask.startedAtUtc).ToUniversalTime()
            $elapsedText = if ($elapsed.TotalHours -ge 1) {
                '{0:00}:{1:00}:{2:00}' -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
            }
            else {
                '{0:00}:{1:00}' -f $elapsed.Minutes, $elapsed.Seconds
            }
            $taskSummaryLabel.Text = [string]$latestTask.summary

            if ($runningTaskCount -gt 0) {
                $taskLabel.Text = "● $activeTaskCount 个任务未完成 · 最久 $elapsedText"
                $taskLabel.ForeColor = [System.Drawing.Color]::FromArgb(25, 95, 170)
                $taskPanel.BackColor = [System.Drawing.Color]::AliceBlue
                $notifyIcon.Text = "Codex：$activeTaskCount 个任务活动 | $guardTrayState"
            }
            else {
                $taskLabel.Text = "● $waitingTaskCount 个任务等待你的操作"
                $taskLabel.ForeColor = [System.Drawing.Color]::DarkOrange
                $taskPanel.BackColor = [System.Drawing.Color]::LemonChiffon
                $notifyIcon.Text = "Codex：$waitingTaskCount 个任务等待 | $guardTrayState"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$taskState.lastCompletedAtUtc)) {
            $completedAt = [DateTime]::Parse([string]$taskState.lastCompletedAtUtc).ToLocalTime()
            $taskLabel.Text = "✓ 所有任务已完成 · $($completedAt.ToString('HH:mm:ss'))"
            $taskLabel.ForeColor = [System.Drawing.Color]::DarkGreen
            $taskPanel.BackColor = [System.Drawing.Color]::Honeydew
            $taskSummaryLabel.Text = [string]$taskState.lastCompletedSummary
            $notifyIcon.Text = "Codex：所有任务已完成 | $guardTrayState"
        }
        else {
            $taskLabel.Text = '○ 未检测到正在运行的任务'
            $taskLabel.ForeColor = [System.Drawing.Color]::DimGray
            $taskPanel.BackColor = [System.Drawing.Color]::WhiteSmoke
            $taskSummaryLabel.Text = ''
            $notifyIcon.Text = "Codex：无运行任务 | $guardTrayState"
        }
    }

    $armAction = {
        $null = Set-GuardArmed -Seconds ([int]$delayInput.Value)
        $notifyIcon.BalloonTipTitle = '关机守卫已开启'
        $notifyIcon.BalloonTipText = '仅下一次成功完成信号会触发关机倒计时。'
        $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notifyIcon.ShowBalloonTip(5000)
        & $refreshUi
    }

    $cancelAction = {
        $null = Invoke-CancelAndDisarm
        & $refreshUi
    }

    $armButton.Add_Click($armAction)
    $offButton.Add_Click($cancelAction)
    $toggleMenuItem.Add_Click($armAction)
    $cancelMenuItem.Add_Click($cancelAction)
    $openMenuItem.Add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
    $notifyIcon.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

    $exitMenuItem.Add_Click({
        $null = Invoke-CancelAndDisarm
        $script:allowExit = $true
        $notifyIcon.Visible = $false
        $form.Close()
    })

    $form.Add_Resize({
        if ($form.WindowState -eq 'Minimized') {
            $form.Hide()
        }
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) {
            $script:allowExit = $true
        }

        if (-not $script:allowExit) {
            $eventArgs.Cancel = $true
            $form.Hide()
            $notifyIcon.BalloonTipTitle = '关机守卫仍在运行'
            $notifyIcon.BalloonTipText = '可从任务栏通知区域重新打开或退出。'
            $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $notifyIcon.ShowBalloonTip(4000)
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        try {
            if ($showEvent.WaitOne(0)) {
                $form.Show()
                $form.WindowState = 'Normal'
                $form.Activate()
            }

            $null = Resume-PendingShutdownForActiveTasks
            $state = Read-GuardState
            if ([bool]$state.armed -and -not [bool]$state.shutdownPending) {
                $null = Invoke-ProcessSignalOnce
            }
            & $refreshUi
        }
        catch {
            $statusLabel.Text = "守卫错误：$($_.Exception.Message)"
            $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
        }
    })
    $timer.Start()
    & $refreshUi

    try {
        $form.Show()
        $form.Activate()
        [System.Windows.Forms.Application]::Run($form)
    }
    finally {
        $timer.Stop()
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        if ($createdNew) {
            $mutex.ReleaseMutex()
        }
        $showEvent.Dispose()
        $mutex.Dispose()
    }
}

switch ($Mode) {
    'gui' {
        Start-GuardGui
    }
    'status' {
        Write-JsonResult -Value (Read-GuardState)
    }
    'arm' {
        Write-JsonResult -Value (Set-GuardArmed -Seconds $DelaySeconds)
    }
    'disarm' {
        Write-JsonResult -Value (Invoke-CancelAndDisarm)
    }
    'signal' {
        Write-JsonResult -Value (Write-CompletionSignal -Summary $TaskSummary -Id $TaskId)
    }
    'cancel' {
        Write-JsonResult -Value (Invoke-CancelAndDisarm)
    }
    'process-once' {
        Write-JsonResult -Value (Invoke-ProcessSignalOnce)
    }
    'task-start' {
        Write-JsonResult -Value (Set-TaskActivity -Status running -Summary $TaskSummary -Id $TaskId)
    }
    'task-waiting' {
        Write-JsonResult -Value (Set-TaskActivity -Status waiting -Summary $TaskSummary -Id $TaskId)
    }
    'task-idle' {
        Write-JsonResult -Value (Set-TaskActivity -Status idle -Summary $TaskSummary -Id $TaskId)
    }
    'task-status' {
        Write-JsonResult -Value (Read-TaskState)
    }
}
