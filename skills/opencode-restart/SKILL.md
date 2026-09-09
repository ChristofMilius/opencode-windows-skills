---
name: opencode-restart
description: Use when the user needs to restart opencode to load new configuration, skills, agents, plugins, or after config changes. Restarts opencode with NO lingering console window by triggering a Windows Scheduled Task that runs a hidden helper (kills the process tree and launches a fresh instance).
---

# Restarting opencode

opencode loads its config once at startup and does NOT hot-reload. After
changing `opencode.json`, adding a skill/agent/plugin, or editing any
config-time file, the running session keeps using stale config until it is
quit and relaunched.

## Before restarting: mandatory confirmation and state warning

**A restart kills this session.** Killing the opencode process tree discards
all in-memory conversation and session state — unsaved messages, drafting
work, and anything the user typed but did not export are **gone permanently**.
There is no prompt, no autosave rescue, and no undo.

Because of this, the agent MUST do BOTH of the following before triggering
any restart:

1. **Explicitly warn the user** that restarting discards the current
   session's in-memory conversation state.
2. **Wait for explicit user confirmation.** Never run
   `schtasks /Run /TN "opencode_restart"` on your own initiative, on a
   judgment call, or as part of a config change "cleanup". Restart only when
   the user has clearly asked for it or approved it — an explicit yes in
   response to your warning.

A restart triggered without the user's explicit confirmation is a bug in
this workflow.

## The canonical approach: Windows Scheduled Task (no console window)

A scheduled task runs detached, and by routing the action through
`wscript.exe` (a GUI-subsystem host with no console) plus a VBScript that
starts pwsh with window style 0 (hidden), the whole restart is **window-less**.

Files (in `$env:USERPROFILE\.config\opencode\scripts\`):

| File | Purpose |
|---|---|
| `restart-opencode.ps1` | The helper: auto-discovers the main opencode PID, kills the process tree, launches a fresh instance, exits. |
| `restart-opencode-launcher.vbs` | Starts pwsh running the helper with SW_HIDE so no console appears. |

### One-time setup (install the task)

```powershell
$vbs = "$env:USERPROFILE\.config\opencode\scripts\restart-opencode-launcher.vbs"
schtasks /Create /TN "opencode_restart" /TR "wscript.exe `"$vbs`"" /SC ONCE /ST 23:59 /F
```

`/SC ONCE /ST 23:59` just satisfies schtasks' required schedule; the task is
only ever run on demand via `/Run`, never on a timer.

### Triggering a restart

```powershell
schtasks /Run /TN "opencode_restart"
```

That's it — no window. This tool call returns immediately; the new opencode
window appears a few seconds later.

## How the helper works

`restart-opencode.ps1` (auto-discovering, so no PID needed — the PID would
be stale by the time a task runs):

1. Finds the main opencode process: the `OpenCode.exe` whose command line
   does NOT contain `--type=renderer/gpu/utility`.
   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" |
       Where-Object { $_.CommandLine -notmatch '--type=' } | Select-Object -First 1
   ```
2. Enumerates the full process tree (main + Electron children) and
   `Stop-Process -Force`s them.
3. Waits ~2s so the single-instance lock / ports release.
4. Launches a fresh opencode in the configured directory.
5. Exits.

## VBS launcher details

`restart-opencode-launcher.vbs` calls
`shell.Run("pwsh -NoProfile -WindowStyle Hidden -File ...restart-opencode.ps1", 0, False)`:
- `wscript.exe` — GUI subsystem, never shows a console of its own.
- window style `0` (SW_HIDE) — starts pwsh hidden.
- third arg `False` — don't wait; the launcher returns immediately.

## After launching

- Tell the user the restart is in progress; the new window appears shortly.
- Do not attempt to verify state from this session afterwards — it will have
  gone away. Confirm with the user that the new window opened.

## Notes / limitations

- If the task doesn't exist yet, install it with the setup command above
  (do this during skill setup, then trigger with `/Run`).
- To clean up: `schtasks /Delete /TN "opencode_restart" /F`.
