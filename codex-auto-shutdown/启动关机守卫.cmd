@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CodexShutdownGuard.ps1" -Mode gui
