[CmdletBinding()]
param(
    [string]$TaskSummary = 'Codex task started',
    [string]$TaskId = $env:CODEX_THREAD_ID
)

$guardScript = Join-Path $PSScriptRoot 'CodexShutdownGuard.ps1'
& $guardScript -Mode task-start -TaskSummary $TaskSummary -TaskId $TaskId
exit $LASTEXITCODE
