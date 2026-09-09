' restart-opencode-launcher.vbs
'
' Launch the opencode restart helper with NO visible console window.
' Used as the Scheduled Task action. wscript.exe itself is GUI-subsystem
' (no console), and Run(..., 0, false) starts pwsh hidden (window style 0).
'
' Invoked by the "opencode_restart" scheduled task. The helper script
' auto-discovers the main opencode PID, kills the tree, relaunches, exits.

Option Explicit

Dim shell, pwsh, script
Set shell = CreateObject("WScript.Shell")

' Resolve the user profile path so this file is portable.
pwsh   = "pwsh.exe"
script = shell.ExpandEnvironmentStrings("%USERPROFILE%") & _
         "\.config\opencode\scripts\restart-opencode.ps1"

' Run the helper hidden (0 = SW_HIDE). Third arg false = don't wait.
shell.Run """" & pwsh & """ -NoProfile -WindowStyle Hidden -File """ & script & """", 0, False
