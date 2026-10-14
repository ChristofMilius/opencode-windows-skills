# Window placement restore across restarts

*Feature documentation for `scripts/restart-opencode.ps1`.*

Part of the `opencode-restart` workflow — see the [opencode-restart
skill](../skills/opencode-restart/SKILL.md) and the repo
[README](../README.md) for installing the scheduled task and skills. This page
documents the **window-placement feature** added to the restart helper.

## What this feature does

The restart helper originally did a plain kill-and-relaunch: it auto-discovered
the main `OpenCode.exe` PID (the one without `--type=`), killed the Electron
process tree, and launched a fresh instance. That left the new window wherever
Electron's own window-state store put it — after every restart the user had to
drag and re-snap opencode back into their multi-monitor Win11 arrangement.

This feature makes restarting **preserve the window exactly as it was**:

- position and size (across monitors),
- maximized / normal / minimized state,
- Win11 snap layout extents (snapped half/quarter arrangements survive),

by capturing the placement right before the kill and forcing the new window
back into that rect after launch.

## How it works

```
        capture                     kill                   fight until stable
  ┌──────────────────┐    ┌──────────────────────┐    ┌──────────────────────────┐
  │ GetWindowPlacement│    │ collect descendants  │    │ ShowWindow + SetWindowPos│
  │ GetWindowRect      │ →  │ Stop-Process -Force │ →  │ every 400 ms             │
  │ (DPI-aware coords) │    │ wait ~2 s            │    │ until rect matches target│
  └──────────────────┘    └──────────────────────┘    └──────────────────────────┘
```

### 1. Capture (before the kill)

`Capture-Placement` reads both the placement table and the true on-screen rect
of the main visible window:

- `GetWindowPlacement` → `showCmd`, restore-rect (`rcNormalPosition`), flags
  (this is also what Windows uses for snap/maximize state).
- `GetWindowRect` → the **actual** screen extents. This is the authoritative
  source for where the window is *right now*, including snapped extents.

Everything runs after the process opts into
`DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`, so both calls return physical
pixels — the same coordinate space Electron works in.

Whatever the window looks like at restart time is what gets captured: position
the window (and snap arrangement) before triggering the restart.

### 2. Kill

Process-tree collection, `Stop-Process -Force`, brief wait for the
single-instance lock/ports to release. Unchanged from the original helper.

### 3. Restore (after the fresh window exists)

Once the new instance's window appears, `Restore-Placement` **fights the
placement back into place**: `ShowWindow` (per captured showCmd) + `SetWindowPos`
re-applied every 400 ms until the window reports the captured rect — up to 30
attempts (~12 s). The loop is intentionally persistent: Electron performs its
own late geometry restore after launch, and the last write wins.

## Why these implementation choices

### DPI awareness first (root cause of "coordinate weirdness")

`SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`
(`-4`) at the top of the script. Without it the helper is system-DPI aware and
user32 virtualizes all rect coordinates, which does not match Electron's
physical pixels — captures and moves landed off any real monitor arrangement.

### `SetWindowPos`, not `SetWindowPlacement`, for the actual move

`SetWindowPlacement` returned success but moved nothing on the Electron window.
`SetWindowPos` really moves it — and as a bonus it triggers Chromium to persist
the new bounds into its own window-state store, so any later framework
re-restore agrees with our target instead of fighting it.

### Order in the fight loop: `ShowWindow` first, `SetWindowPos` last

Restoring a snapped/maximized window with `ShowWindow(SW_MAXIMIZE)` expands it
to the full monitor, destroying the snap extents. Running `SetWindowPos` last
each pass keeps the exact snapped rect on screen.

### PowerShell delegate scope trap

Scriptblock delegates passed as Win32 callbacks cannot assign to captured
variables — they shadow them in their own scope, so the first implementation
silently "found no window" (hwnd 0). Results are returned by mutating a
**shared hashtable** (`$state.best`, `$state.maxArea`), which the caller can
see.

### Don't steal focus while fighting

`SetWindowPos` flags `SWP_NOZORDER|SWP_NOACTIVATE|SWP_SHOWWINDOW` (`0x0054`)
move the window without grabbing focus or breaking the z-order — relevant while
the loop reapplies up to 30 times.

### Log to a file

The scheduled task runs hidden; console output is invisible. The helper logs
every step to `%TEMP%\opencode_restart.log` so a failed restore is diagnosable.

## Verification

A test with the window at rect `1913,0-2887,1039` (showCmd 1), snapped into a
multi-monitor layout (log sample from an earlier run; the launch directory is
now resolved via `%OPENCODE_PROJECTS%` with a `%USERPROFILE%` fallback):

```
[23:44:29.988] discovered opencode PID 17776, cwd 'C:\Windows\System32'
[23:44:30.070] captured window placement (showCmd=1, rect=1913,0-2887,1039)
[23:44:30.166] terminating opencode tree: 17776, 2744, 7588, ...
[23:44:32.225] launching '...\OpenCode.exe' in 'C:\Windows\System32'
[23:44:35.540] placement matched on attempt 1
[23:44:35.557] done.
```

Post-restart measurement of the fresh instance confirmed the window at exactly
`1913,0-2887,1039`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `placement did not stabilize after 30 attempts` | Electron's geometry restore keeps overriding, or the rect is off any visible monitor | verify the captured rect in the log is sensible; the loop is capped at ~12 s by design |
| window "not found" / hwnd 0 | delegate returned no match (scope trap) | make sure results go through a shared hashtable (see above) |
| window moves to a weird spot / wrong monitor | DPI awareness missing | ensure `[WinPlace]::SetDpiAware()` runs before any rect call |
| snapped window expands to full screen after restart | `ShowWindow(SW_MAXIMIZE)` ran after `SetWindowPos` | reorder: `SetWindowPos` last |
| `placement matched` but window still wrong afterwards | later framework restore beat the last attempt | raise the attempt cap / re-apply for longer |

## v2: why the app does not restore the window itself

The helper exists because opencode's own window-state restore is not reliable.
Since the v2 desktop rewrite it is worse than flaky: two things in the Electron
main process mean opencode *cannot* restore a maximized window's placement, and
always drops the zoom level. They are recorded here because both produce
symptoms that look like this helper failing.

Verified against opencode desktop **2.0.28** (2026-10-14) by reading the
minified main bundle in `resources/app.asar` and the live state files it
writes.

### Only non-maximized bounds are ever recorded

The window-state writer updates the saved geometry only while the window is
normal — maximized, minimized and fullscreen frames are deliberately skipped:

```js
o = () => {
  if (e.isDestroyed()) return
  let t = e.getBounds()
  !e.isMaximized() && !e.isMinimized() && !e.isFullScreen() &&
    (i.x = t.x, i.y = t.y, i.width = t.width, i.height = t.height)
  i.isMaximized = e.isMaximized()
  i.isFullScreen = e.isFullScreen()
}
```

`createMainWindow` seeds the file with `defaultWidth: 1280, defaultHeight: 800`.
So for a window that is always maximized, the saved `x/y/width/height` stay at
the seed and the real position is never learned. The live file shows exactly
that:

```
%APPDATA%\ai.opencode.desktop\window-state-<id>.json
{"width":1280,"height":800,"x":0,"y":0,
 "displayBounds":{"x":0,"y":0,"width":1920,"height":1080},
 "isMaximized":true,"isFullScreen":false}
```

Move the window to a second monitor or into a snap layout and keep it
maximized, and the file still says `1280x800 @ 0,0` — the next plain launch
opens on the primary monitor.

### Zoom is forced back to 100% at every launch

`wireZoom` runs on every window creation and sets the factor to 1 before
anything else:

```js
function wireZoom(win) {
  pinchZoomEnabled.set(win, getPinchZoomEnabled())
  win.webContents.setZoomFactor(1)
  ...
}
```

The factor is only ever changed from the pinch-zoom path (±0.2 steps, clamped
to 0.2–10) and is never persisted, so a `Ctrl +` / `Ctrl -` level is gone on
the next start.

### What that means for the helper

- **A plain launch and a helper restart are not equivalent.** The helper
  re-applies the captured Win32 rect with `SetWindowPos` after launch,
  independent of opencode's own store — so placement survives *a restart
  through the helper* even when the app's stored state is the `1280x800`
  default.
- **A maximized window is never learned by the app.** opencode's writer skips
  maximized frames, so restarting a maximized window through the helper
  restores it for that session only; the next *plain* launch falls back to
  `1280x800 @ 0,0` again. Keep restarting through the helper, or leave the
  window snapped/normal once so the app's store records the real rect.
- **Zoom is out of scope.** The factor lives only inside the running renderer
  and cannot be read from outside the process, so the helper can neither
  capture nor re-apply it. Re-apply zoom manually after a restart until
  upstream persists it.

Upstream tracking (desktop app issues, not this repo): window state reset to
defaults on every launch (#15165), unreliable window-state save/load (#10791),
broken maximized-state restore (#12413), and zoom reset to 100 % on restart
(#50168, open fix PR #50169).

## Related

- [opencode-restart skill](../skills/opencode-restart/SKILL.md) — the restart
  workflow this feature is part of (confirmation rules, scheduled task, log
  location).
- [scripts/restart-opencode.ps1](../scripts/restart-opencode.ps1) — the
  canonical implementation (no mirrored listing here; no drift risk).