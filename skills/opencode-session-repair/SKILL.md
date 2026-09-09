---
name: opencode-session-repair
description: Use when answering whether opencode sessions/messages survive a kill or crash, verifying session integrity after a forced restart, or investigating opencode storage. Codifies how opencode persists sessions to disk (SQLite/WAL), what survives a process kill, what is genuinely lost (in-flight generation, unsent input), and how to verify sessions are intact without guessing.
---

# opencode session persistence & repair

This skill teaches the verified persistence model of local opencode
storage so agents can answer session-survival questions accurately and
verify integrity after crashes or forced restarts — without the wrong
claim that "everything is lost".

## Ground truth (verified on this machine)

- Sessions and messages are stored in a **SQLite database**:
  `%USERPROFILE%\.local\share\opencode\opencode.db`
- The DB runs in **WAL mode** (`opencode.db-wal`/`opencode.db-shm` siblings
  exist). Committed transactions survive process termination, crashes, and
  `Stop-Process -Force`.
- Key tables (confirmed via `sqlite_master`):
  `session`, `message`, `part`, `event`, `todo`, `project`, `permission`,
  `session_message`, `session_context_epoch`, `session_input`,
  `control_account`, `credential`, `account`.
- `%USERPROFILE%\.local\share\opencode\storage\session_diff\` holds
  per-session diff files (JSON arrays; typically `[]` when empty).
- **Sensitive data lives in this DB** (`account`, `credential` tables).
  Never copy, commit, or share `opencode.db` — treat it like a credentials
  vault.

## What survives a kill, what does not

A force-kill (e.g. the opencode-restart helper, `Stop-Process -Force`,
crash) does NOT erase conversation history:

| Item | Survives? |
|---|---|
| Completed messages / parts | Yes — committed to DB continuously (WAL) |
| Session list & structure | Yes |
| In-flight generation (a reply still streaming) | **No** — that partial turn is lost |
| In-progress tool call result | **No** — not yet committed |
| Unsubmitted text in the input box | **No** — memory only |

Cost of a hard kill = the current in-flight turn and unsent draft text.
This is the same class of loss as closing the window mid-reply.

## Correct user-facing framing

- History is safe: "Your conversation is saved to disk continuously;
  sessions are resumable after a restart, same as a manual close."
- Only warn about the unfinished turn / unsent input — do NOT claim "all
  session data destroyed".

## Verifying sessions survived (read-only)

```powershell
python -c "import sqlite3,os; c=sqlite3.connect('file:%s?mode=ro'%os.path.expandvars(r'%USERPROFILE%\.local\share\opencode\opencode.db'),uri=True); print('sessions:', c.execute('SELECT count(*) FROM session').fetchone()[0]); print('messages:', c.execute('SELECT count(*) FROM message').fetchone()[0])"
```

- `mode=ro` URI flag opens read-only — safe while opencode is running.
- Compare `event` count growth / `LastWriteTime` of `opencode.db` to
  confirm recent activity persisted.
- If counts look right, session integrity is intact; no repair needed.

## Escalation path

1. Re-probe read-only first (above) — never open the DB read-write while
   opencode is running.
2. If opencode is closed and the DB is corrupted (`PRAGMA integrity_check`
   fails), the WAL checkpoint may still hold recent data: copy
   `opencode.db` + `-wal` + `-shm` together before attempting any repair.
3. Treat the copy as secret material (credentials inside). Do not commit it.
4. Beyond read-only diagnosis, recommend a backup/restore from the user's
   own copies rather than hand-editing the DB.

## Pitfalls

- Do not claim persistence "doesn't happen" or that kills destroy history —
  both are wrong for the current opencode builds.
- Do not read the DB `mode=rw` while opencode is live; WAL + locked writers
  can wedge the app.
- Do not commit or transmit any copy of `opencode.db` (contains
  `account`/`credential` data).