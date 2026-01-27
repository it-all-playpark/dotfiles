---
name: git-worktree-cleanup
description: |
  Detect and remove git worktrees for branches that have been merged into the base branch.
  Use when: (1) cleaning up after PR merges, (2) user asks to remove merged worktrees,
  (3) managing worktree sprawl, (4) keywords like "cleanup worktree", "remove merged worktree".
---

# Worktree Cleanup

Clean up git worktrees for branches already merged into the base branch (default: main).

## Workflow

1. List all worktrees: `git worktree list`
2. Get merged branches: `git branch --merged <base-branch>`
3. For each worktree on a merged branch: `git worktree remove <path>`
4. Report results

## Quick Usage

### Manual Steps

```bash
# Check worktrees and merged branches
git worktree list
git branch --merged main

# Remove specific merged worktree
git worktree remove /path/to/worktree
```

### Automated Script

```bash
# Run cleanup script (base branch defaults to main)
bash scripts/worktree-cleanup.sh

# Specify different base branch
bash scripts/worktree-cleanup.sh develop
```

## Scripts

- `scripts/worktree-cleanup.sh` - Automated detection and removal of merged worktrees
