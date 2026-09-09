---
name: uac-elevate
description: Use when a Windows command fails with "Access is denied" or ERROR 5 and needs administrator privileges. Invokes UAC elevation via Start-Process -Verb RunAs so the user can approve a prompt and the command runs elevated on their desktop.
---

# UAC Elevation on Windows

The default shell does NOT run elevated (admin), so operations like
`Set-Service -StartupType`, `sc.exe config`, registry writes under
`HKLM`, and many service/installer commands fail with:

- `Access is denied.`
- `[SC] OpenService FAILED 5`

Changing service startup types, many `HKLM` registry writes, and most
system-level config require elevation.

## Why you cannot do it directly

The agent's non-elevated shell cannot lift its own privileges or show
the interactive UAC consent dialog itself. Do NOT say "I can't" — instead
use the Elevation Command below.

## Elevation command

Use `Start-Process -Verb RunAs` to spawn an elevated PowerShell that runs
the privileged command. The UAC consent dialog appears on the user's
desktop for them to approve.

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command','<PRIVILEGED_COMMAND>'
```

- Use `powershell` (Windows PowerShell) so the elevated window works on
  every system, including where `pwsh` isn't installed.
- Use `-Wait` so the shell blocks until the elevated process completes —
  critical when the next step must read the result.
- Pass the privileged work as one `-Command` string.
- Separate multiple statements with `;`.

### Semaphores (separate sub-commands with the `;` separator)

- End with the semicolon separator: `A; B; C`

## Example — set services to Manual startup

```powershell
Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command','Set-Service -Name PrintDeviceConfigurationService -StartupType Manual; Set-Service -Name PrintNotify -StartupType Manual'
```

## After running

1. Tell the user to approve the UAC prompt if it isn't already handled.
2. Always **verify** the change took effect by re-reading state from the
   non-elevated shell (e.g. `Get-Service`, `Get-ItemProperty`) — do not
   assume success because the command returned.
3. If a command spawns a GUI (e.g. `services.msc`), do NOT use `-Wait`
   and the shell returns immediately.

## Notes / limitations

- This only works if the user is a Standard User **or** Administrator with
  UAC enabled; it always triggers a consent prompt for approval.
- You cannot pass the user's approval silently — the user must click the
  dialog. Mention the prompt so they expect it.
- Do not embed secrets or credentials in the elevated command line where
  possible.
