@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexShutdownGuard.ps1" -Mode cancel
echo.
echo Shutdown has been cancelled and the guard is off.
pause
