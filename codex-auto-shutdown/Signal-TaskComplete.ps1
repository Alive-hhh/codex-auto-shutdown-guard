[CmdletBinding()]
param(
    [string]$TaskSummary = 'Codex task completed',
    [string]$TaskId = $env:CODEX_THREAD_ID
)

$guardScript = Join-Path $PSScriptRoot 'CodexShutdownGuard.ps1'
& $guardScript -Mode signal -TaskSummary $TaskSummary -TaskId $TaskId
exit $LASTEXITCODE
