---
name: git-log
description: |
  View commit history with formatting options.
  Use when: viewing history, finding commits, understanding changes.
  Accepts args: [--oneline] [--graph] [--author NAME] [-n COUNT] [--json]
---

# git-log

View commit history.

## Execution

```bash
~/.claude/skills/git-log/scripts/git-log.sh [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--oneline` | Compact format |
| `--graph` | Show branch graph |
| `--author` | Filter by author name |
| `-n COUNT` | Limit commits (default: 10) |
| `--json` | Output as JSON array |

## Output

Default: `hash subject (author, relative_time)`

JSON format (with `--json`):
```json
[{"hash":"...","short_hash":"...","author":"...","date":"...","subject":"..."}]
```

## Examples

```bash
# Recent 10 commits
scripts/git-log.sh

# Last 5 commits, compact
scripts/git-log.sh --oneline -n 5

# Graph view
scripts/git-log.sh --graph

# Filter by author as JSON
scripts/git-log.sh --author "name" --json
```
