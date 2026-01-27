---
name: git-stash
description: |
  Stash changes temporarily.
  Use when: saving work temporarily, switching context, cleaning working directory.
  Accepts args: [--push] [--pop] [--list] [--apply] [--drop]
---

# git-stash

Stash management operations.

## Execution

```bash
~/.claude/skills/git-stash/scripts/git-stash.sh [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--push [msg]` | Save changes to stash |
| `--pop` | Apply and remove latest |
| `--list` | List all stashes |
| `--apply [idx]` | Apply without removing |
| `--drop [idx]` | Remove stash |

## Output

JSON format:
```json
{"status":"success|error","action":"push|pop|list|apply|drop","message":"..."}
```

For `--list`:
```json
{"status":"success","action":"list","stashes":[{"index":"stash@{0}","message":"..."}]}
```

## Examples

```bash
scripts/git-stash.sh --push "WIP: feature"
scripts/git-stash.sh --list
scripts/git-stash.sh --pop
scripts/git-stash.sh --apply stash@{1}
```
