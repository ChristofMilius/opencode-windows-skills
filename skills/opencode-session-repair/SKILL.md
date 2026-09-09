---
name: opencode-session-repair
description: Use when opencode projects/sessions break after a drive or path change (disk consolidation, new drive letters, folders moved). Repairs stale absolute paths in the opencode SQLite DB (project.worktree, project_directory.directory, session.directory/path) to re-link sessions to moved projects. Also covers the persistence model (SQLite/WAL) that makes sessions safe to repair.
---

# opencode session repair — drive/path change

When you consolidate/repartition HDDs and drive letters change (e.g. `G:`
becomes `I:`), sessions for projects under the old path break. This skill
documents the exact repair, which was proven on a live DB.

## Failure mode

Symptoms after a path change:

- Projects show dead `G:/...` paths in the opencode list; clicking them fails.
- Sessions don't load / resume; diff & file-tree operations fail.
- Opening the project at its new path doesn't fix it.

## Why it breaks (important)

- opencode stores session history in a SQLite DB:
  `%USERPROFILE%\.local\share\opencode\opencode.db`
- The DB has **absolute path columns** (forward slashes):
  `project.worktree`, `project_directory.directory`, `session.directory`,
  `session.path`.
- **Project IDs are NOT derived from the path.** For git repos they come
  from the remote URL / a `.git/opencode` cache file / the root commit hash.
  IDs therefore survive a move — sessions keep their link.
- Only the absolute path columns go stale. opencode will NOT self-heal:
  `Project.fromDirectory` reads the stale `worktree` from the DB and writes
  it back unchanged.
- **Side-effect of persistence**: because history lives in SQLite (WAL
  mode), the migration is safe — you are editing path pointers, not
  destroying messages.

## The repair (5 steps)

Do not skip the backup. Never edit without one.

### 1. Locate the database

```
Windows:  %USERPROFILE%\.local\share\opencode\opencode.db
Linux/macOS: ~/.local/share/opencode/opencode.db
```

The `-wal`/`-shm` siblings confirm WAL mode (normal).

### 2. Diagnose — count stale rows

```python
import sqlite3, os
DB = os.path.expandvars(r"%USERPROFILE%\.local\share\opencode\opencode.db")
OLD = "G:/opencode_projects"   # <-- your old prefix
con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
q = lambda t, c: con.execute(f"SELECT count(*) FROM {t} WHERE {c} LIKE ?", (OLD + "%",)).fetchone()[0]
print("project.worktree     ", q("project", "worktree"))
print("project_directory    ", q("project_directory", "directory"))
print("session.directory    ", q("session", "directory"))
print("session.path         ", q("session", "path"))
con.close()
```

Also list distinct stale prefixes to scope exactly what moved:

```python
for t, c in (("session","directory"),("project","worktree"),("project_directory","directory")):
    for (v,) in con.execute(f"SELECT DISTINCT {c} FROM {t} WHERE {c} LIKE 'G:/%'"):
        print(t, c, "=", v)
```

### 3. Backup — `VACUUM INTO`

```python
import sqlite3, datetime, os
DB = os.path.expandvars(r"%USERPROFILE%\.local\share\opencode\opencode.db")
bdir = r"I:\TEMP\opencode"   # your scratch dir
os.makedirs(bdir, exist_ok=True)
backup = os.path.join(bdir, f"opencode-{datetime.datetime.now():%Y%m%d-%H%M%S}.db")
con = sqlite3.connect(DB)                     # read-write needed for VACUUM INTO
con.execute("VACUUM INTO ?", (backup,))       # snapshots a consistent DB state
con.close()
print("backup:", backup)
```

Simply use: `con.execute("VACUUM INTO ?", (backup,))` — safe while the app
runs because it snapshots a consistent point.

### 4. Migrate — transactional prefix rewrite

```python
con = sqlite3.connect(DB, timeout=30)
con.execute("PRAGMA busy_timeout=30000")
NEW = "I:/opencode_projects"   # <-- your new prefix
try:
    cur = con.cursor()
    # 4a. subfolder rows (old prefix + "/")
    n = cur.execute(
      "UPDATE project SET worktree = replace(worktree, ?, ?) WHERE worktree LIKE ?",
      (OLD + "/", NEW + "/", OLD + "/%")).rowcount
    print("project.worktree:", n)
    n = cur.execute(
      "UPDATE project_directory SET directory = replace(directory, ?, ?) WHERE directory LIKE ?",
      (OLD + "/", NEW + "/", OLD + "/%")).rowcount
    print("project_directory:", n)
    n = cur.execute(
      "UPDATE session SET directory = replace(directory, ?, ?), path = replace(path, ?, ?) "
      "WHERE directory LIKE ? OR path LIKE ?",
      (OLD + "/", NEW + "/", OLD + "/", NEW + "/", OLD + "/%", OLD + "/%")).rowcount
    print("session (subfolder):", n)
    # 4b. EXACT-prefix rows (moved project FOLDER itself, no trailing slash)
    n = cur.execute(
      "UPDATE session SET directory = ?, path = ? WHERE directory = ? OR path = ?",
      (NEW, NEW, OLD, OLD)).rowcount
    print("session (exact folder):", n)
    con.commit()
except Exception:
    con.rollback()
    raise
con.close()
```

**The trailing-slash trap**: `LIKE 'G:/opencode_projects/%'` matches
subfolders only. The exact string `G:/opencode_projects` (the moved parent
folder, no slash) needs the separate `WHERE directory = ?` update. Omitting
4b leaves the folder-root sessions broken.

### 5. Verify

```python
con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
print("integrity:", con.execute("PRAGMA integrity_check").fetchone()[0])   # 'ok'
for (w,) in con.execute("SELECT DISTINCT worktree FROM project WHERE worktree LIKE 'I:/%'"):
    print(w, "->", "EXISTS" if os.path.isdir(w.replace("/", os.sep)) else "MISSING")
# remaining stale refs (should be only intentional leftovers):
for t, c in (("session","directory"),("session","path"),("project","worktree")):
    for (v,) in con.execute(f"SELECT DISTINCT {c} FROM {t} WHERE {c} LIKE 'G:/%'"):
        print("LEFT:", t, c, "=", v)
con.close()
```

## After: restart opencode

The running app caches old state. Restart opencode (desktop + CLI) to pick
up the new paths. Use the `opencode-restart` skill for a windowless restart.

## Scope decisions

- **Leftovers you must decide on**: sessions rooted at the old drive
  (`G:/` root), or at paths that were NOT part of the move (e.g.
  `G:/PRIVAT/...`) stay stale. Map them only if the destination is correct.
- **Duplicate project rows** (same project, two generation ids) remain
  separate histories — leave them unless the user wants a merge.
- **Optional deep rewrite**: `message.data`/`part.data`/`event.data` JSON
  blobs contain old path strings (cosmetic in rendered history). Rewriting
  them is heavier and touches event-replay logic — structural-only is the
  safe default. Ask before doing the deep version.

## Guardrails

- Never run the writes while a different opencode instance might also write
  without a restart plan; SQLite/WAL tolerates it, but close the app first
  when possible.
- Always back up first. Never skip step 3.
- The DB contains account/credential tables — never commit, upload, or share
  `opencode.db` or its backup.
- Sanitize: replace real drive letters with placeholders (`OLD`/`NEW`) when
  turning the transcript into docs or examples.