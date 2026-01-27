---
name: git-status
description: |
  Show working directory and staging area status.
  Use when: checking git status, seeing changes, before commit.
  Accepts args: [--short] [--json]
---

# git-status

Repository status with structured output.

## Execution

```bash
~/.claude/skills/git-status/scripts/git-status.sh [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--short` | Compact format (git status -s) |
| `--json` | Full JSON output (default) |

## Output

```json
{
  "branch": "main",
  "tracking": "origin/main",
  "ahead": 0,
  "behind": 0,
  "staged": 2,
  "modified": 1,
  "untracked": 3,
  "conflicts": 0,
  "dirty": true
}
```

## Examples

```bash
# Full JSON status
scripts/git-status.sh

# Short format
scripts/git-status.sh --short
```
