' restart-opencode-launcher.vbs
'
' Launch the opencode restart helper with NO visible console window.
' Used as the Scheduled Task action. wscript.exe itself is GUI-subsystem
' (no console), and Run(..., 0, false) starts pwsh hidden (window style 0).
'
' Invoked by the "opencode_restart" scheduled task. The helper script
' auto-discovers the main opencode PID, kills the tree, relaunches, and
' restores the window placement.
'
' Launch directory: the fresh opencode instance starts in %OPENCODE_PROJECTS%
' if that variable is set (e.g. "I:\opencode_projects"), otherwise in the
' user profile. Set it with:  setx OPENCODE_PROJECTS "I:\opencode_projects"
' No machine-specific paths are hardcoded here.

Option Explicit

Dim shell, pwsh, script, dir
Set shell = CreateObject("WScript.Shell")

' Resolve the user profile path so this file is portable.
pwsh   = "pwsh.exe"
script = shell.ExpandEnvironmentStrings("%USERPROFILE%") & _
         "\.config\opencode\scripts\restart-opencode.ps1"

' Launch directory: OPENCODE_PROJECTS if set, else the user profile.
dir = shell.ExpandEnvironmentStrings("%OPENCODE_PROJECTS%")
If Len(Trim(dir)) = 0 Or InStr(dir, "%") > 0 Then
    dir = shell.ExpandEnvironmentStrings("%USERPROFILE%")
End If

' Run the helper hidden (0 = SW_HIDE). Third arg false = don't wait.
shell.Run """" & pwsh & """ -NoProfile -WindowStyle Hidden -File """ & script & """ -Directory """ & dir & """", 0, False