#!/usr/bin/env bash
# create-sub-issue.sh - Create a sub-issue with labels
# Usage: create-sub-issue.sh <title> <body-file> <order> <parent-issue>
#
# Output: Created issue number

set -euo pipefail

TITLE="${1:-}"
BODY_FILE="${2:-}"
ORDER="${3:-1}"
PARENT_ISSUE="${4:-}"

if [[ -z "$TITLE" || -z "$BODY_FILE" || -z "$PARENT_ISSUE" ]]; then
    echo "Usage: create-sub-issue.sh <title> <body-file> <order> <parent-issue>" >&2
    exit 1
fi

# Pad order for sorting
PADDED_ORDER=$(printf "%02d" "$ORDER")
LABELS="sub-task,order-${PADDED_ORDER}"

# Append parent reference to body
FULL_BODY=$(cat "$BODY_FILE"; echo ""; echo "Parent: #${PARENT_ISSUE}")

# Create issue
ISSUE_NUM=$(gh issue create \
    --title "$TITLE" \
    --body "$FULL_BODY" \
    --label "$LABELS" \
    --json number --jq .number)

echo "$ISSUE_NUM"
