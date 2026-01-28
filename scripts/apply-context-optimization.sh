#!/bin/bash
# Apply context optimization changes from issue #15
# Run this script after merging the PR to apply skill deletions

set -e

SKILLS_DIR="${HOME}/.claude/skills"

echo "=== Context Optimization Script ==="
echo ""

# Phase 1: Delete unused skills
echo "Phase 1: Deleting 18 unused skills..."
UNUSED_SKILLS=(
  "case-study-generator"
  "dev-troubleshoot"
  "plan-estimate"
  "plan-design"
  "doc-explain"
  "dev-improve"
  "git-status"
  "git-stash"
  "git-sync"
  "git-log"
  "git-branch"
  "meta-spawn"
  "meta-task"
  "issue-split"
  "meta-select-tool"
  "meta-orchestrate"
  "git-worktree-cleanup"
  "session-reflect"
)

deleted=0
skipped=0
for skill in "${UNUSED_SKILLS[@]}"; do
  target="${SKILLS_DIR}/${skill}"
  # Check for directory, symlink (valid or broken)
  if [ -d "$target" ] || [ -L "$target" ]; then
    rm -rf "$target"
    echo "  Deleted: ${skill}"
    ((deleted++))
  else
    echo "  Skipped (not found): ${skill}"
    ((skipped++))
  fi
done

echo ""
echo "Deleted: ${deleted} skills"
echo "Skipped: ${skipped} skills"

# Phase 2: Create mcp-guide skill symlink
echo ""
echo "Phase 2: Creating mcp-guide skill symlink..."

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_GUIDE_SRC="${DOTFILES_DIR}/claude-code/skills/mcp-guide"
MCP_GUIDE_DST="${SKILLS_DIR}/mcp-guide"

if [ -d "${MCP_GUIDE_SRC}" ]; then
  if [ -L "${MCP_GUIDE_DST}" ] || [ -d "${MCP_GUIDE_DST}" ]; then
    rm -rf "${MCP_GUIDE_DST}"
  fi
  ln -s "${MCP_GUIDE_SRC}" "${MCP_GUIDE_DST}"
  echo "  Created symlink: ${MCP_GUIDE_DST} -> ${MCP_GUIDE_SRC}"
else
  echo "  ERROR: Source not found: ${MCP_GUIDE_SRC}"
  exit 1
fi

echo ""
echo "=== Context optimization complete ==="
echo "Expected token savings: ~3.2k tokens (1.6%)"
