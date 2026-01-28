#!/usr/bin/env bash
# init-kickoff.sh - Initialize kickoff state file
# Usage: init-kickoff.sh <issue> <branch> <worktree> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

require_cmd jq

# Defaults
ISSUE=""
BRANCH=""
WORKTREE=""
BASE_BRANCH="main"
STRATEGY="tdd"
DEPTH="standard"
LANG="ja"
ENV_MODE="hardlink"
SKIP_PR="false"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base) BASE_BRANCH="$2"; shift 2 ;;
        --strategy) STRATEGY="$2"; shift 2 ;;
        --depth) DEPTH="$2"; shift 2 ;;
        --lang) LANG="$2"; shift 2 ;;
        --env-mode) ENV_MODE="$2"; shift 2 ;;
        --skip-pr) SKIP_PR="true"; shift ;;
        -*)
            die_json "Unknown option: $1" 1
            ;;
        *)
            if [[ -z "$ISSUE" ]]; then
                ISSUE="$1"
            elif [[ -z "$BRANCH" ]]; then
                BRANCH="$1"
            elif [[ -z "$WORKTREE" ]]; then
                WORKTREE="$1"
            fi
            shift
            ;;
    esac
done

[[ -n "$ISSUE" ]] || die_json "Issue number required" 1
[[ -n "$BRANCH" ]] || die_json "Branch name required" 1
[[ -n "$WORKTREE" ]] || die_json "Worktree path required" 1

# Ensure .claude directory exists in worktree
mkdir -p "$WORKTREE/.claude"

STATE_FILE="$WORKTREE/.claude/kickoff.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create initial state
cat > "$STATE_FILE" <<EOF
{
  "version": "1.0",
  "issue": $ISSUE,
  "branch": "$BRANCH",
  "worktree": "$WORKTREE",
  "base_branch": "$BASE_BRANCH",
  "started_at": "$NOW",
  "updated_at": "$NOW",
  "current_phase": "1_prepare",
  "phases": {
    "1_prepare": { "status": "done", "started_at": "$NOW", "completed_at": "$NOW", "result": "Worktree created" },
    "2_analyze": { "status": "pending" },
    "3_implement": { "status": "pending" },
    "4_validate": { "status": "pending" },
    "5_commit": { "status": "pending" },
    "6_pr": { "status": "pending" }
  },
  "next_actions": ["Run dev-issue-analyze"],
  "decisions": [],
  "config": {
    "strategy": "$STRATEGY",
    "depth": "$DEPTH",
    "lang": "$LANG",
    "env_mode": "$ENV_MODE",
    "skip_pr": $SKIP_PR
  }
}
EOF

echo "{\"status\":\"initialized\",\"state_file\":\"$STATE_FILE\"}"
