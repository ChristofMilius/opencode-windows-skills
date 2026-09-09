# opencode-windows-skills

PowerShell/Windows skills and helpers for [opencode](https://opencode.ai)
agents that fill gaps in non-elevated shells: raising a UAC prompt, restarting
opencode itself without leaving a stray console window behind, and repairing
sessions after drive/path changes.

## Skills

| Skill | Path | Purpose |
|---|---|---|
| `uac-elevate` | `skills/uac-elevate/SKILL.md` | Run a privileged command via `Start-Process -Verb RunAs` when a command fails with "Access is denied" / ERROR 5. Shows a UAC consent prompt on the user's desktop. |
| `opencode-restart` | `skills/opencode-restart/SKILL.md` | Restart opencode with **no lingering console window** by triggering a Windows Scheduled Task that runs a hidden helper: kills the process tree and launches a fresh instance. |
| `opencode-session-repair` | `skills/opencode-session-repair/SKILL.md` | Repairs sessions after a drive-letter/path change (disk consolidation). Rewrites stale `project.worktree` / `project_directory` / `session.directory`/`path` paths in `opencode.db` after backup, with verified SQL. |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/restart-opencode.ps1` | Auto-discovers the main `OpenCode.exe` PID (the one without `--type=`), captures the window placement, kills the whole Electron process tree, waits, relaunches opencode, and **restores the window position/size/snap layout** on the fresh instance. |
| `scripts/restart-opencode-launcher.vbs` | Starts the helper with a hidden window via `wscript.exe` + `WScript.Shell.Run(..., 0, False)`, so no console ever appears. |

## Guides

| Guide | Purpose |
|---|---|
| [docs/window-placement-restore.md](docs/window-placement-restore.md) | Deep dive into the window-placement preservation in `restart-opencode.ps1`: capture → restore fighting loop, and the traps that make naive restores fail (DPI awareness, `SetWindowPos` vs `SetWindowPlacement`, snap layouts, the PowerShell delegate scope trap). |

## Requirements

- Windows 10/11
- `pwsh` (PowerShell 7+)
- `schtasks` (built in)
- opencode (desktop app installs to `%LOCALAPPDATA%\Programs\@opencode-aidesktop\OpenCode.exe` by default)

## Install

Copy the folders into your opencode config:

```powershell
# Skills
Copy-Item skills\uac-elevate "$env:USERPROFILE\.config\opencode\skills\" -Recurse
Copy-Item skills\opencode-restart "$env:USERPROFILE\.config\opencode\skills\" -Recurse

# Helpers
Copy-Item scripts\restart-opencode.ps1 "$env:USERPROFILE\.config\opencode\scripts\"
Copy-Item scripts\restart-opencode-launcher.vbs "$env:USERPROFILE\.config\opencode\scripts\"
```

Then **restart opencode once** so the skills load (config is not hot-reloaded).

## Setting up the restart scheduled task (one time)

```powershell
$vbs = "$env:USERPROFILE\.config\opencode\scripts\restart-opencode-launcher.vbs"
schtasks /Create /TN "opencode_restart" /TR "wscript.exe `"$vbs`"" /SC ONCE /ST 23:59 /F
```

The `/SC ONCE /ST 23:59` only satisfies `schtasks`' required schedule — the
task is never triggered on a timer, only on demand:

```powershell
schtasks /Run /TN "opencode_restart"
```

Delete it with `schtasks /Delete /TN "opencode_restart" /F`.

## Usage

### uac-elevate

When a command fails with `Access is denied` (e.g. `Set-Service`,
`sc.exe config` quit with ERROR 5), run the elevated command via:

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command','<PRIVILEGED_COMMAND>'
```

A UAC consent prompt appears; once approved, the command runs elevated.
Always verify the result afterwards from the non-elevated shell.

### opencode-restart

When config, skills, plugins, or agents changed and a reload is needed,
trigger the hidden restart:

```powershell
schtasks /Run /TN "opencode_restart"
```

There is no console window. The current opencode session is torn down and a
fresh instance launches in a few seconds. The restart helper captures the
window placement (position, size, Win11 snap arrangement) just before killing
the old instance, and re-applies it to the new window — see
[docs/window-placement-restore.md](docs/window-placement-restore.md).

## Notes

- Restarting opencode interrupts any in-flight generation and loses unsent
  input; previously committed messages in the session history are safe and
  resumable after restart.
- Window placement is captured from whatever is on screen at restart time:
  position the opencode window (and snap arrangement) before triggering the
  restart.
- The helper resolves the opencode executable via `Get-Command opencode`
  first, then falls back to the default desktop install path.
- No hardcoded user paths or credentials are used; install paths come from
  `%USERPROFILE%` / `%LOCALAPPDATA%`.
- The window-restore guide's appendix mirrors the installed script; the
  canonical copy lives at `scripts/restart-opencode.ps1` in this repo.

## License

MIT