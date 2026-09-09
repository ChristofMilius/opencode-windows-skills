# restart-opencode.ps1
#
# Restart helper: kills the running opencode process tree, launches a fresh
# instance, then exits. Canonical invocation is via the "opencode_restart"
# Windows Scheduled Task routed through wscript.exe +
# restart-opencode-launcher.vbs so no console window ever appears.
#
# The target opencode PID is auto-discovered at runtime: the main
# OpenCode.exe process (the one WITHOUT --type=renderer/gpu/utility in its
# command line). That makes the helper fully self-contained — you don't
# need to pass a PID that would be stale by the time the task runs.
#
# Window geometry is preserved: the main window's placement (position, size,
# maximized/minimized state) is captured from the old instance before it is
# killed and re-applied to the fresh instance once it appears, so a restart
# no longer resets the window position or config.
#
# Trigger (after `schtasks /Create ... /TR "wscript.exe ...\restart-opencode-launcher.vbs"`):
#   schtasks /Run /TN "opencode_restart"

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
    $cx = $Placement.Rect.Left + ($w / 2)
    $cy = $Placement.Rect.Top + ($h / 2)
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