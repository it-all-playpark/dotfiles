#!/usr/bin/env bash
# post-plan-comment.sh - Post implementation plan to parent issue
# Usage: post-plan-comment.sh <parent-issue> <plan-file>

set -euo pipefail

PARENT_ISSUE="${1:-}"
PLAN_FILE="${2:-}"

if [[ -z "$PARENT_ISSUE" || -z "$PLAN_FILE" ]]; then
    echo "Usage: post-plan-comment.sh <parent-issue> <plan-file>" >&2
    exit 1
fi

gh issue comment "$PARENT_ISSUE" --body-file "$PLAN_FILE"
echo "Plan posted to issue #${PARENT_ISSUE}"
