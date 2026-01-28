#!/usr/bin/env bash
# init-iterate.sh - Initialize iterate state file
# Usage: init-iterate.sh <pr-number-or-url> [--max-iterations N] [--worktree PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

require_cmd jq
require_gh_auth

PR_INPUT=""
MAX_ITERATIONS=10
WORKTREE=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
        --worktree) WORKTREE="$2"; shift 2 ;;
        -*)
            die_json "Unknown option: $1" 1
            ;;
        *)
            if [[ -z "$PR_INPUT" ]]; then
                PR_INPUT="$1"
            fi
            shift
            ;;
    esac
done

[[ -n "$PR_INPUT" ]] || die_json "PR number or URL required" 1

# Extract PR number from URL if needed
if [[ "$PR_INPUT" =~ ^https?:// ]]; then
    PR_NUMBER=$(echo "$PR_INPUT" | grep -oE '[0-9]+$')
    PR_URL="$PR_INPUT"
else
    PR_NUMBER="$PR_INPUT"
    PR_URL=""
fi

# Get PR info from GitHub
PR_INFO=$(gh pr view "$PR_NUMBER" --json number,headRefName,baseRefName,url 2>/dev/null) || \
    die_json "Failed to fetch PR #$PR_NUMBER info" 1

PR_NUMBER=$(echo "$PR_INFO" | jq -r '.number')
BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName')
BASE_BRANCH=$(echo "$PR_INFO" | jq -r '.baseRefName')
[[ -z "$PR_URL" ]] && PR_URL=$(echo "$PR_INFO" | jq -r '.url')

# Determine state file location
if [[ -n "$WORKTREE" ]]; then
    STATE_DIR="$WORKTREE/.claude"
else
    GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    [[ -n "$GIT_ROOT" ]] || die_json "Not in a git repository" 1
    STATE_DIR="$GIT_ROOT/.claude"
fi

mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/iterate.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create initial state
cat > "$STATE_FILE" <<EOF
{
  "version": "1.0",
  "pr_number": $PR_NUMBER,
  "pr_url": "$PR_URL",
  "branch": "$BRANCH",
  "base_branch": "$BASE_BRANCH",
  "started_at": "$NOW",
  "updated_at": "$NOW",
  "current_iteration": 1,
  "max_iterations": $MAX_ITERATIONS,
  "status": "in_progress",
  "iterations": [
    {
      "number": 1,
      "started_at": "$NOW",
      "review": { "decision": "pending" },
      "ci_status": "pending"
    }
  ],
  "next_actions": ["Run pr-review"]
}
EOF

echo "{\"status\":\"initialized\",\"state_file\":\"$STATE_FILE\",\"pr_number\":$PR_NUMBER}"
