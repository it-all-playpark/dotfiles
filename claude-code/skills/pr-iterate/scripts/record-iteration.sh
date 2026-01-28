#!/usr/bin/env bash
# record-iteration.sh - Record iteration results
# Usage: record-iteration.sh <action> [options] [--worktree PATH]
#   Actions:
#     review --decision <approved|request-changes|comment> [--issues "issue1,issue2"] [--summary "..."]
#     ci --status <passed|failed|pending>
#     fix --applied "fix1,fix2"
#     next - Start next iteration
#     complete --status <lgtm|failed|max_reached>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

require_cmd jq

ACTION=""
DECISION=""
CI_STATUS=""
ISSUES=""
SUMMARY=""
FIXES=""
COMPLETE_STATUS=""
WORKTREE=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --decision) DECISION="$2"; shift 2 ;;
        --status)
            if [[ -z "$ACTION" || "$ACTION" == "ci" ]]; then
                CI_STATUS="$2"
            else
                COMPLETE_STATUS="$2"
            fi
            shift 2
            ;;
        --issues) ISSUES="$2"; shift 2 ;;
        --summary) SUMMARY="$2"; shift 2 ;;
        --applied) FIXES="$2"; shift 2 ;;
        --worktree) WORKTREE="$2"; shift 2 ;;
        review|ci|fix|next|complete)
            ACTION="$1"; shift
            ;;
        -*)
            die_json "Unknown option: $1" 1
            ;;
        *)
            if [[ -z "$ACTION" ]]; then
                ACTION="$1"
            fi
            shift
            ;;
    esac
done

[[ -n "$ACTION" ]] || die_json "Action required (review|ci|fix|next|complete)" 1

# Find state file
if [[ -n "$WORKTREE" ]]; then
    STATE_FILE="$WORKTREE/.claude/iterate.json"
else
    GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$GIT_ROOT" && -f "$GIT_ROOT/.claude/iterate.json" ]]; then
        STATE_FILE="$GIT_ROOT/.claude/iterate.json"
    else
        die_json "State file not found" 1
    fi
fi

[[ -f "$STATE_FILE" ]] || die_json "State file not found: $STATE_FILE" 1

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CURRENT=$(jq -r '.current_iteration' "$STATE_FILE")

case "$ACTION" in
    review)
        [[ -n "$DECISION" ]] || die_json "Decision required for review action" 1

        JQ_UPDATE=".updated_at = \"$NOW\" |
            .iterations[$CURRENT - 1].review.decision = \"$DECISION\""

        if [[ -n "$ISSUES" ]]; then
            ISSUES_JSON=$(echo "$ISSUES" | tr ',' '\n' | jq -R . | jq -s .)
            JQ_UPDATE="$JQ_UPDATE | .iterations[$CURRENT - 1].review.issues = $ISSUES_JSON"
        fi

        if [[ -n "$SUMMARY" ]]; then
            JQ_UPDATE="$JQ_UPDATE | .iterations[$CURRENT - 1].review.summary = $(json_str "$SUMMARY")"
        fi

        # Update next_actions based on decision
        if [[ "$DECISION" == "approved" ]]; then
            JQ_UPDATE="$JQ_UPDATE | .next_actions = [\"LGTM! Consider completing.\"] | .status = \"lgtm\""
        else
            JQ_UPDATE="$JQ_UPDATE | .next_actions = [\"Run pr-fix to address issues\"]"
        fi
        ;;

    ci)
        [[ -n "$CI_STATUS" ]] || die_json "Status required for ci action" 1
        JQ_UPDATE=".updated_at = \"$NOW\" |
            .iterations[$CURRENT - 1].ci_status = \"$CI_STATUS\""

        if [[ "$CI_STATUS" == "failed" ]]; then
            JQ_UPDATE="$JQ_UPDATE | .next_actions = [\"Fix CI failures\"]"
        fi
        ;;

    fix)
        [[ -n "$FIXES" ]] || die_json "Applied fixes required for fix action" 1
        FIXES_JSON=$(echo "$FIXES" | tr ',' '\n' | jq -R . | jq -s .)
        JQ_UPDATE=".updated_at = \"$NOW\" |
            .iterations[$CURRENT - 1].fixes_applied = (.iterations[$CURRENT - 1].fixes_applied // []) + $FIXES_JSON |
            .next_actions = [\"Run pr-review to check fixes\"]"
        ;;

    next)
        NEXT=$((CURRENT + 1))
        MAX=$(jq -r '.max_iterations' "$STATE_FILE")

        if [[ $NEXT -gt $MAX ]]; then
            JQ_UPDATE=".updated_at = \"$NOW\" |
                .status = \"max_reached\" |
                .next_actions = [\"Maximum iterations reached. Manual intervention required.\"]"
        else
            JQ_UPDATE=".updated_at = \"$NOW\" |
                .current_iteration = $NEXT |
                .iterations[$CURRENT - 1].completed_at = \"$NOW\" |
                .iterations += [{\"number\": $NEXT, \"started_at\": \"$NOW\", \"review\": {\"decision\": \"pending\"}, \"ci_status\": \"pending\"}] |
                .next_actions = [\"Run pr-review\"]"
        fi
        ;;

    complete)
        [[ -n "$COMPLETE_STATUS" ]] || die_json "Status required for complete action" 1
        JQ_UPDATE=".updated_at = \"$NOW\" |
            .status = \"$COMPLETE_STATUS\" |
            .iterations[$CURRENT - 1].completed_at = \"$NOW\" |
            .next_actions = []"
        ;;

    *)
        die_json "Unknown action: $ACTION" 1
        ;;
esac

# Apply update
TMP_FILE=$(mktemp)
if jq "$JQ_UPDATE" "$STATE_FILE" > "$TMP_FILE"; then
    mv "$TMP_FILE" "$STATE_FILE"
    echo "{\"status\":\"recorded\",\"action\":\"$ACTION\",\"iteration\":$CURRENT}"
else
    rm -f "$TMP_FILE"
    die_json "Failed to update state" 1
fi
