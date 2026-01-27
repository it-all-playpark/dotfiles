---
name: git-branch
description: |
  Branch management - create, list, delete, switch branches.
  Use when: creating branches, switching branches, listing branches.
  Accepts args: [name] [--create] [--delete] [--list] [--switch] [--remote]
---

# git-branch

Branch management operations.

## Execution

```bash
~/.claude/skills/git-branch/scripts/git-branch.sh [name] [options]
```

## Options

| Option | Description |
|--------|-------------|
| `--create` | Create new branch |
| `--delete` | Delete branch (must be merged) |
| `--list` | List all branches |
| `--switch` | Switch to branch |
| `--remote` | Include remote branches (with --list) |

## Output

JSON format:
```json
{"status":"success|error","action":"list|create|delete|switch","branch":"name","message":"..."}
```

For `--list`:
```json
{"status":"success","action":"list","current":"main","branches":["main","dev","feature/x"]}
```

## Examples

```bash
# List local branches
scripts/git-branch.sh --list

# List all including remote
scripts/git-branch.sh --list --remote

# Create branch
scripts/git-branch.sh feature/new --create

# Switch branch
scripts/git-branch.sh main --switch

# Delete branch
scripts/git-branch.sh old-feature --delete
```
