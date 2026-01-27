#!/bin/bash
# worktree-cleanup.sh - Detect and remove merged git worktrees

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get base branch (default: main)
BASE_BRANCH="${1:-main}"

echo -e "${YELLOW}Checking for merged worktrees...${NC}"
echo ""

# Get list of worktrees (excluding main worktree)
worktrees=$(git worktree list --porcelain | grep "^worktree " | grep -v "$(git rev-parse --show-toplevel)$" | sed 's/^worktree //')

if [ -z "$worktrees" ]; then
    echo -e "${GREEN}No additional worktrees found.${NC}"
    exit 0
fi

# Get merged branches
merged_branches=$(git branch --merged "$BASE_BRANCH" | sed 's/^[* +]*//' | tr -d ' ')

# Track if any worktrees were removed
removed=0

while IFS= read -r worktree_path; do
    [ -z "$worktree_path" ] && continue

    # Get branch name for this worktree
    branch=$(git worktree list | grep "^$worktree_path" | awk '{print $3}' | tr -d '[]')

    if echo "$merged_branches" | grep -q "^${branch}$"; then
        echo -e "${GREEN}✓ Removing merged worktree:${NC} $worktree_path (branch: $branch)"
        git worktree remove "$worktree_path"
        ((removed++))
    else
        echo -e "${YELLOW}⏭ Skipping unmerged worktree:${NC} $worktree_path (branch: $branch)"
    fi
done <<< "$worktrees"

echo ""
if [ $removed -gt 0 ]; then
    echo -e "${GREEN}Removed $removed merged worktree(s).${NC}"
else
    echo -e "${YELLOW}No merged worktrees to remove.${NC}"
fi

# Show remaining worktrees
echo ""
echo -e "${YELLOW}Current worktrees:${NC}"
git worktree list
