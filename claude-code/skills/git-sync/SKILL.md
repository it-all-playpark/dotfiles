---
name: git-sync
description: |
  Sync with remote - pull and push with conflict handling.
  Use when: syncing with remote, pulling changes, pushing changes.
  Accepts args: [--pull] [--push] [--rebase]
---

# git-sync

Sync with remote repository.

## Execution

```bash
~/.claude/skills/git-sync/scripts/git-sync.sh [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--pull` | Pull from remote |
| `--push` | Push to remote |
| `--rebase` | Pull with rebase |

## Output

```json
{"status":"success|error|conflict","action":"pull|push|rebase","message":"..."}
```

Conflict detection:
```json
{"status":"conflict","action":"pull","message":"Merge conflicts detected","conflicts":true}
```

Default (no args) shows sync status:
```json
{"branch":"main","remote":"origin","ahead":2,"behind":0}
```

## Examples

```bash
scripts/git-sync.sh --pull
scripts/git-sync.sh --push
scripts/git-sync.sh --rebase
```
