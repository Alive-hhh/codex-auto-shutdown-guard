[CmdletBinding()]
param(
    [string]$TaskSummary = 'Codex is waiting for user input',
    [string]$TaskId = $env:CODEX_THREAD_ID
)

$guardScript = Join-Path $PSScriptRoot 'CodexShutdownGuard.ps1'
& $guardScript -Mode task-waiting -TaskSummary $TaskSummary -TaskId $TaskId
exit $LASTEXITCODE
