Option Explicit

Dim shell, fileSystem, scriptDirectory, guardScript, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
guardScript = fileSystem.BuildPath(scriptDirectory, "CodexShutdownGuard.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & guardScript & """ -Mode gui"

shell.Run command, 1, False
