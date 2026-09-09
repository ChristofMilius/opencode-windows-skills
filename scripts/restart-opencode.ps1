# restart-opencode.ps1
#
# restart-opencode.ps1
#
# Restart helper: kills the running opencode process tree and launches a
# fresh instance, then exits. Canonical invocation is via the
# "opencode_restart" Windows Scheduled Task routed through wscript.exe +
# restart-opencode-launcher.vbs so no console window ever appears.
#
# The target opencode PID is auto-discovered at runtime: the main
# OpenCode.exe process (the one WITHOUT --type=renderer/gpu/utility in its
# command line). That makes the helper fully self-contained — you don't
# need to pass a PID that would be stale by the time the task runs.
#
# Trigger (after `schtasks /Create ... /TR "wscript.exe ...\restart-opencode-launcher.vbs"`):
#   schtasks /Run /TN "opencode_restart"

param(
    [string]$Directory = (Get-Location).Path,
    [int]$DelaySeconds = 2
)

$ErrorActionPreference = 'Stop'

function Resolve-OpencodeExe {
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $default = "$env:LOCALAPPDATA\Programs\@opencode-aidesktop\OpenCode.exe"
    if (Test-Path $default) { return $default }
    throw "Could not locate opencode executable."
}

# --- 0. Discover the main opencode PID at runtime ---------------------------
$mainProc = Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" |
    Where-Object { $_.CommandLine -notmatch '--type=' } |
    Select-Object -First 1

if (-not $mainProc) {
    Write-Output "restart-opencode: no running main opencode process found; skipping kill."
} else {
    $targetPid = $mainProc.ProcessId
    Write-Output "restart-opencode: discovered opencode PID $targetPid, cwd '$Directory'"

    # --- 1. Collect the target process and descendants ---------------------
    $toKill = New-Object System.Collections.Generic.List[int]
    $toKill.Add($targetPid)
    $all = Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -ne 0 }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in $all) {
            if ($toKill -contains $p.ParentProcessId -and -not ($toKill -contains $p.ProcessId)) {
                $toKill.Add($p.ProcessId)
                $changed = $true
            }
        }
    }

    Write-Output "restart-opencode: terminating opencode tree: $($toKill -join ', ')"
    foreach ($id in $toKill) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    # Give the OS a beat to release the single-instance lock / ports.
    Start-Sleep -Seconds $DelaySeconds
}

# --- 2. Launch a fresh instance in the requested directory ------------------
$exe = Resolve-OpencodeExe
Write-Output "restart-opencode: launching '$exe' in '$Directory'"
Start-Process -FilePath $exe -WorkingDirectory $Directory

Write-Output "restart-opencode: done."
