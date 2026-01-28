#!/usr/bin/env bash
# update-phase.sh - Update phase status in kickoff state
# Usage: update-phase.sh <phase> <status> [--result "..."] [--error "..."] [--worktree PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

require_cmd jq

PHASE=""
STATUS=""
RESULT=""
ERROR=""
WORKTREE=""
NEXT_ACTIONS=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --result) RESULT="$2"; shift 2 ;;
        --error) ERROR="$2"; shift 2 ;;
        --worktree) WORKTREE="$2"; shift 2 ;;
        --next) NEXT_ACTIONS="$2"; shift 2 ;;
        -*)
            die_json "Unknown option: $1" 1
            ;;
        *)
            if [[ -z "$PHASE" ]]; then
                PHASE="$1"
            elif [[ -z "$STATUS" ]]; then
                STATUS="$1"
            fi
            shift
            ;;
    esac
done

[[ -n "$PHASE" ]] || die_json "Phase required (1_prepare|2_analyze|3_implement|4_validate|5_commit|6_pr)" 1
[[ -n "$STATUS" ]] || die_json "Status required (pending|in_progress|done|failed|skipped)" 1

# Find state file
if [[ -n "$WORKTREE" ]]; then
    STATE_FILE="$WORKTREE/.claude/kickoff.json"
else
    # Try to find in current git root
    GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$GIT_ROOT" && -f "$GIT_ROOT/.claude/kickoff.json" ]]; then
        STATE_FILE="$GIT_ROOT/.claude/kickoff.json"
    else
        die_json "State file not found. Use --worktree or run from worktree directory." 1
    fi
fi

[[ -f "$STATE_FILE" ]] || die_json "State file not found: $STATE_FILE" 1

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build jq update expression
JQ_UPDATE=".updated_at = \"$NOW\" | .phases.\"$PHASE\".status = \"$STATUS\""

case "$STATUS" in
    in_progress)
        JQ_UPDATE="$JQ_UPDATE | .phases.\"$PHASE\".started_at = \"$NOW\" | .current_phase = \"$PHASE\""
        ;;
    done)
        JQ_UPDATE="$JQ_UPDATE | .phases.\"$PHASE\".completed_at = \"$NOW\""
        # Advance current_phase to next
        case "$PHASE" in
            1_prepare) JQ_UPDATE="$JQ_UPDATE | .current_phase = \"2_analyze\"" ;;
            2_analyze) JQ_UPDATE="$JQ_UPDATE | .current_phase = \"3_implement\"" ;;
            3_implement) JQ_UPDATE="$JQ_UPDATE | .current_phase = \"4_validate\"" ;;
            4_validate) JQ_UPDATE="$JQ_UPDATE | .current_phase = \"5_commit\"" ;;
            5_commit) JQ_UPDATE="$JQ_UPDATE | .current_phase = \"6_pr\"" ;;
            6_pr) JQ_UPDATE="$JQ_UPDATE | .current_phase = \"completed\"" ;;
        esac
        ;;
    failed)
        JQ_UPDATE="$JQ_UPDATE | .phases.\"$PHASE\".completed_at = \"$NOW\""
        ;;
esac

if [[ -n "$RESULT" ]]; then
    JQ_UPDATE="$JQ_UPDATE | .phases.\"$PHASE\".result = $(json_str "$RESULT")"
fi

if [[ -n "$ERROR" ]]; then
    JQ_UPDATE="$JQ_UPDATE | .phases.\"$PHASE\".error = $(json_str "$ERROR")"
fi

if [[ -n "$NEXT_ACTIONS" ]]; then
    # Parse comma-separated actions into array
    JQ_UPDATE="$JQ_UPDATE | .next_actions = $(echo "$NEXT_ACTIONS" | tr ',' '\n' | jq -R . | jq -s .)"
fi

# Apply update
TMP_FILE=$(mktemp)
if jq "$JQ_UPDATE" "$STATE_FILE" > "$TMP_FILE"; then
    mv "$TMP_FILE" "$STATE_FILE"
    echo "{\"status\":\"updated\",\"phase\":\"$PHASE\",\"new_status\":\"$STATUS\"}"
else
    rm -f "$TMP_FILE"
    die_json "Failed to update state" 1
fi
