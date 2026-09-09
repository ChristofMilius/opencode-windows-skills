# opencode-window-restore

Preserve the opencode desktop window's **position, size, and Win11 snap
arrangement** across restarts.

![Guide status](https://img.shields.io/badge/status-guide-blue)

## Overview

The opencode desktop app (an Electron shell) is restarted via a scheduled task
(`opencode_restart`). Restarts used to reset the window to a default or stale
position, breaking carefully arranged multi-monitor layouts built with Win11 Pro
snap layouts.

This guide explains how to make the restart helper **capture the window
placement before killing the old instance** and **fight the fresh instance back
into that exact rect** until it sticks — including the traps that make naive
implementations fail.

## Prerequisites

| Item | Notes |
|---|---|
| Windows 10/11 (tested on Win11 Pro) | multi-monitor + snap layouts supported |
| PowerShell 7+ (`pwsh`) | the helper relies on it |
| opencode desktop (Electron) | main process named `OpenCode.exe` |
| Scheduled task `opencode_restart` | created so the restart runs hidden |

## 1. The problem

A restart helper killed the opencode process tree and relaunched a fresh
instance. The new window came up at a **wrong or stale position**:

- the window landed wherever Electron's own window-state store dictated, and
- a naive `SetWindowPlacement` during restore was silently overridden by the
  app's late geometry restore.

The visible symptom: after every restart you had to re-drag / re-snap opencode
into your layout.

## 2. How it works

```
        capture                     kill                   fight until stable
  ┌──────────────┐           ┌────────────────┐      ┌─────────────────────────┐
  │ GetWindowPlacement  │    │ stop tree      │      │ ShowWindow + SetWindowPos│
  │ GetWindowRect        │ →  │ Stop-Process   │  →   │ every 400 ms             │
  │ (DPI-aware coords)  │    │                │      │ until rect matches target│
  └──────────────┘           └────────────────┘      └─────────────────────────┘
```

Three phases in `restart-opencode.ps1`:

1. **Capture** — read the placement table (`showCmd`, restore-rect, flags) and
   the true on-screen rect of the main window. Everything runs in
   **per-monitor-DPI-aware** coordinates so numbers match what you see.
2. **Kill** — collect the main process plus its whole descendant tree, then
   `Stop-Process -Force` them and wait a moment for the single-instance lock.
3. **Restore (fighting loop)** — once the fresh window exists, re-apply
   `ShowWindow` + `SetWindowPos` every 400 ms until the window reports the
   captured rect (max 30 attempts / ~12 s), then exit.

## 3. Installation

### 3.1. Install the helper script

Create `%USERPROFILE%\.config\opencode\scripts\restart-opencode.ps1` with the
full listing from the [Appendix](#appendix-a-full-listing).

### 3.2. Launcher (no console window)

Create `%USERPROFILE%\.config\opencode\scripts\restart-opencode-launcher.vbs`:

```vbs
Option Explicit

Dim shell, pwsh, script
Set shell = CreateObject("WScript.Shell")

pwsh   = "pwsh.exe"
script = shell.ExpandEnvironmentStrings("%USERPROFILE%") & _
         "\.config\opencode\scripts\restart-opencode.ps1"

shell.Run """" & pwsh & """ -NoProfile -WindowStyle Hidden -File """ & script & """", 0, False
```

### 3.3. Register the scheduled task

```powershell
schtasks /Create /TN "opencode_restart" `
  /TR "wscript.exe `"%USERPROFILE%\.config\opencode\scripts\restart-opencode-launcher.vbs`"" `
  /SC ONCE /ST 00:00 /RL LIMITED /IT /F
```

`/IT` (interactive only) keeps the task running in your session so GUI apps,
window enumeration, and snapping behave normally.

### 3.4. Test

1. Position and snap the opencode window exactly where you want it.
2. Trigger the restart:

   ```powershell
   schtasks /Run /TN "opencode_restart"
   ```

3. After relaunch, the window should be back in the same spot. Check the log
   for what happened:

   ```powershell
   Get-Content "$env:TEMP\opencode_restart.log"
   ```

Example of a healthy run:

```
[23:44:29.988] discovered opencode PID 17776, cwd 'C:\Windows\System32'
[23:44:30.070] captured window placement (showCmd=1, rect=1913,0-2887,1039)
[23:44:30.166] terminating opencode tree: 17776, 2744, 7588, ...
[23:44:32.225] launching '...\OpenCode.exe' in 'C:\Windows\System32'
[23:44:35.540] placement matched on attempt 1
[23:44:35.557] done.
```

## 4. Why each implementation choice matters

### 4.1. Always run DPI-aware

Add `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`
(a value of `-4`) at the start. Without it, a non-DPI-aware process asks
user32 for **virtualized system-DPI coordinates**, which mismatch the physical
pixels Electron uses. The result was "coordinate weirdness" — rects that didn't
correspond to anything on screen and moves that landed off-target.

### 4.2. `SetWindowPos`, not `SetWindowPlacement`, for the actual move

`SetWindowPlacement` returned success but **moved nothing** on the Electron
window. `SetWindowPos` really moves it — and as a bonus it triggers Chromium to
persist the new bounds into its own window-state store, so any later framework
re-restore agrees with our target instead of fighting it.

### 4.3. Order in the fight loop: `ShowWindow` first, `SetWindowPos` last

Restoring a snapped/maximized window with `ShowWindow(SW_MAXIMIZE)` expands it
to the **full monitor**, destroying the half/quarter-snap extents. Running
`SetWindowPos` last each pass keeps the exact snapped rect on screen.

### 4.4. PowerShell delegate scope trap

Scriptblock delegates passed as Win32 callbacks **cannot assign to captured
variables** — they shadow them in their own scope. The first implementation
silently returned hwnd 0 (window "not found") for this reason. Fix: mutate a
shared **hashtable object** (`$state.best`, `$state.maxArea`); object mutation
is visible to the caller.

### 4.5. Don't steal focus while fighting

`SetWindowPos` flags `SWP_NOZORDER|SWP_NOACTIVATE|SWP_SHOWWINDOW` (`0x0054`)
move the window without grabbing focus or yanking it to the top of the z-order
— important while the loop reapplies up to 30 times.

### 4.6. Log to a file

The scheduled task runs hidden; print to console is invisible. Everything goes
to `%TEMP%\opencode_restart.log` so a failed restore is diagnosable.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `placement did not stabilize after 30 attempts` | Electron's geometry restore keeps overriding, or the rect is off the visible area | verify the captured rect in the log is sensible; raise `30` attempts / wait |
| window "not found" / hwnd 0 | delegate returned no match (scope trap) | make sure results go through a shared hashtable, see [4.4](#44-powershell-delegate-scope-trap) |
| window moves to a weird spot / wrong monitor | DPI-awareness missing | ensure `[WinPlace]::SetDpiAware()` runs before any rect call, see [4.1](#41-always-run-dpi-aware) |
| snapped window expands to full screen after restart | `ShowWindow(SW_MAXIMIZE)` ran after `SetWindowPos` | reorder: `SetWindowPos` last, see [4.3](#43-order-in-the-fight-loop-showwindow-first-setwindowpos-last) |
| restart leaves opencode down | relaunch is unconditional — but check the log for errors before the `Start-Process` line | `Get-Content "$env:TEMP\opencode_restart.log"` |

### Known quirks

- The scheduled task relaunches opencode with the task's default working
  directory (e.g. `C:\Windows\System32`). Pass `-Directory` explicitly if a
  project folder should be used instead.
- The helper targets the main `OpenCode.exe` process (the one without
  `--type=` in its command line) and its descendants — it never touches other
  running processes.

## Appendix A: Full listing

### `restart-opencode.ps1`

Current version — the canonical copy lives at `scripts/restart-opencode.ps1`
in this repo (and is installed to `%USERPROFILE%\.config\opencode\scripts\`);
the guide mirrors it.

```powershell
param(
    [string]$Directory = (Get-Location).Path,
    [int]$DelaySeconds = 2,
    [string]$LogFile = "$env:TEMP\opencode_restart.log"
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $Message
    Write-Output $line
    try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
}

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WinPlace {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT {
        public int length;
        public int flags;
        public int showCmd;
        public POINT ptMinPosition;
        public POINT ptMaxPosition;
        public RECT rcNormalPosition;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, ref RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
    [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiAwarenessContext);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, so our coordinates are in the
    // same physical pixel space Electron uses. Without this, GetWindowRect /
    // SetWindowPos operate on virtualized (system-DPI) coordinates that do not
    // match the snapped/monitor positions the user sees.
    public static void SetDpiAware() {
        SetProcessDpiAwarenessContext(new IntPtr(-4));
    }
}
'@

[WinPlace]::SetDpiAware()

function Resolve-OpencodeExe {
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $default = "$env:LOCALAPPDATA\Programs\@opencode-aidesktop\OpenCode.exe"
    if (Test-Path $default) { return $default }
    throw "Could not locate opencode executable."
}

# Returns the most prominent visible top-level window of a process.
function Get-OpencodeWindow {
    param([int]$TargetPid)
    $state = @{ best = [IntPtr]::Zero; maxArea = 0 }
    $cb = [WinPlace+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        $procId = [uint32]0
        [WinPlace]::GetWindowThreadProcessId($hWnd, [ref]$procId) | Out-Null
        if ($procId -eq $TargetPid -and [WinPlace]::IsWindowVisible($hWnd)) {
            $rect = New-Object WinPlace+RECT
            [WinPlace]::GetWindowRect($hWnd, [ref]$rect) | Out-Null
            $area = ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)
            if ($area -gt $state.maxArea) { $state.maxArea = $area; $state.best = $hWnd }
        }
        return $true
    }
    [WinPlace]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $state.best
}

function Capture-Placement {
    param([IntPtr]$Hwnd)
    $wp = New-Object WinPlace+WINDOWPLACEMENT
    $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf([type][WinPlace+WINDOWPLACEMENT])
    if (-not [WinPlace]::GetWindowPlacement($Hwnd, [ref]$wp)) { return $null }
    $rect = New-Object WinPlace+RECT
    if (-not [WinPlace]::GetWindowRect($Hwnd, [ref]$rect)) { return $null }
    return [pscustomobject]@{
        showCmd = $wp.showCmd
        flags   = $wp.flags
        Normal  = $wp.rcNormalPosition
        Rect    = $rect
    }
}

function Test-PlacementMatch {
    param($Current, $Target)
    if ($null -eq $Current -or $null -eq $Target) { return $false }
    if ($Current.showCmd -ne $Target.showCmd) { return $false }
    $c = $Current.Rect
    $t = $Target.Rect
    return ([Math]::Abs($c.Left - $t.Left) -le 2 -and
            [Math]::Abs($c.Top - $t.Top) -le 2 -and
            [Math]::Abs($c.Right - $t.Right) -le 2 -and
            [Math]::Abs($c.Bottom - $t.Bottom) -le 2)
}

# Re-apply the placement repeatedly until it sticks. Electron performs its own
# late geometry restore after launch, so we fight for the target with
# ShowWindow/SetWindowPos until the window reports the captured screen rect.
# SetWindowPos runs LAST each pass so the snapped/extents rect is what sticks,
# even when the window was snapped or maximized (ShowWindow first would
# otherwise expand a snapped window to the full monitor).
function Restore-Placement {
    param([IntPtr]$Hwnd, $Placement, [int]$TargetPid)
    if ($null -eq $Placement -or [IntPtr]::Zero -eq $Hwnd) { return $false }
    $w  = $Placement.Rect.Right - $Placement.Rect.Left
    $h  = $Placement.Rect.Bottom - $Placement.Rect.Top
    try {
        for ($i = 0; $i -lt 30; $i++) {
            if ($Placement.showCmd -eq 3) {
                [WinPlace]::ShowWindow($Hwnd, 3) | Out-Null
            } elseif ($Placement.showCmd -eq 2) {
                [WinPlace]::ShowWindow($Hwnd, 2) | Out-Null
            } else {
                [WinPlace]::ShowWindow($Hwnd, 9) | Out-Null
            }
            # SWP_NOZORDER|SWP_NOACTIVATE|SWP_SHOWWINDOW: don't steal focus and
            # don't yank the window to the top of the z-order while fighting.
            [WinPlace]::SetWindowPos($Hwnd, [IntPtr]::Zero,
                $Placement.Rect.Left, $Placement.Rect.Top,
                $w, $h, 0x0054) | Out-Null
            Start-Sleep -Milliseconds 400
            $curr = Capture-Placement -Hwnd $Hwnd
            if (Test-PlacementMatch -Current $curr -Target $Placement) {
                Write-Log "placement matched on attempt $($i + 1)"
                return $true
            }
        }
        Write-Log "placement did not stabilize after 30 attempts"
        return $false
    } catch {
        Write-Log "window placement restore failed: $($_.Exception.Message)"
        return $false
    }
}

# --- 0. Discover the main opencode PID at runtime ---------------------------
$mainProc = Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" |
    Where-Object { $_.CommandLine -notmatch '--type=' } |
    Select-Object -First 1

$placement = $null

if (-not $mainProc) {
    Write-Log "no running main opencode process found; skipping kill."
} else {
    $targetPid = $mainProc.ProcessId
    Write-Log "discovered opencode PID $targetPid, cwd '$Directory'"

    # --- 0.5. Capture the window placement so we can restore it ------------
    try {
        $oldHwnd = Get-OpencodeWindow -TargetPid $targetPid
        if ($oldHwnd -ne [IntPtr]::Zero) {
            $placement = Capture-Placement -Hwnd $oldHwnd
            if ($placement) {
                Write-Log "captured window placement (showCmd=$($placement.showCmd), rect=$($placement.Rect.Left),$($placement.Rect.Top)-$($placement.Rect.Right),$($placement.Rect.Bottom))"
            }
        }
    } catch {
        Write-Log "could not capture window placement: $($_.Exception.Message)"
    }

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

    Write-Log "terminating opencode tree: $($toKill -join ', ')"
    foreach ($id in $toKill) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    # Give the OS a beat to release the single-instance lock / ports.
    Start-Sleep -Seconds $DelaySeconds
}

# --- 2. Launch a fresh instance in the requested directory ------------------
$exe = Resolve-OpencodeExe
Write-Log "launching '$exe' in '$Directory'"
Start-Process -FilePath $exe -WorkingDirectory $Directory

# --- 3. Re-apply the captured window placement to the new instance ----------
if ($placement) {
    $newPid = 0
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        $newMain = Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" |
            Where-Object { $_.CommandLine -notmatch '--type=' -and $_.ProcessId -ne $targetPid } |
            Select-Object -First 1
        if ($newMain) { $newPid = $newMain.ProcessId; break }
    }
    if ($newPid -eq 0) {
        Write-Log "new opencode process not detected; skipping placement restore."
    } else {
        $restored = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 300
            $newHwnd = Get-OpencodeWindow -TargetPid $newPid
            if ($newHwnd -ne [IntPtr]::Zero) {
                Restore-Placement -Hwnd $newHwnd -Placement $placement -TargetPid $newPid
                $restored = $true
                break
            }
        }
        if (-not $restored) {
            Write-Log "new instance window not found; skipping placement restore."
        }
    }
}

Write-Log "done."
```

## Appendix B: `restart-opencode-launcher.vbs`

```vbs
Option Explicit

Dim shell, pwsh, script
Set shell = CreateObject("WScript.Shell")

pwsh   = "pwsh.exe"
script = shell.ExpandEnvironmentStrings("%USERPROFILE%") & _
         "\.config\opencode\scripts\restart-opencode.ps1"

shell.Run """" & pwsh & """ -NoProfile -WindowStyle Hidden -File """ & script & """", 0, False
```

## License

MIT — see [LICENSE](LICENSE).