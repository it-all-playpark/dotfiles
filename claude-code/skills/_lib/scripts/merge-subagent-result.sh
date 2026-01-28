#!/usr/bin/env bash
# merge-subagent-result.sh - Merge subagent results into state
# Usage: merge-subagent-result.sh <phase> --result "..." [--worktree PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

require_cmd jq

PHASE=""
RESULT=""
WORKTREE=""
SUBAGENT_TYPE=""
SUBAGENT_ID=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --result) RESULT="$2"; shift 2 ;;
        --worktree) WORKTREE="$2"; shift 2 ;;
        --subagent-type) SUBAGENT_TYPE="$2"; shift 2 ;;
        --subagent-id) SUBAGENT_ID="$2"; shift 2 ;;
        -*)
            die_json "Unknown option: $1" 1
            ;;
        *)
            if [[ -z "$PHASE" ]]; then
                PHASE="$1"
            fi
            shift
            ;;
    esac
done

[[ -n "$PHASE" ]] || die_json "Phase required" 1
[[ -n "$RESULT" ]] || die_json "Result required (--result)" 1

# Find state file
if [[ -n "$WORKTREE" ]]; then
    STATE_FILE="$WORKTREE/.claude/kickoff.json"
else
    GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$GIT_ROOT" && -f "$GIT_ROOT/.claude/kickoff.json" ]]; then
        STATE_FILE="$GIT_ROOT/.claude/kickoff.json"
    else
        die_json "State file not found" 1
    fi
fi

[[ -f "$STATE_FILE" ]] || die_json "State file not found: $STATE_FILE" 1

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build subagent result object
SUBAGENT_OBJ="{\"timestamp\":\"$NOW\",\"result\":$(json_str "$RESULT")}"

if [[ -n "$SUBAGENT_TYPE" ]]; then
    SUBAGENT_OBJ=$(echo "$SUBAGENT_OBJ" | jq --arg t "$SUBAGENT_TYPE" '. + {type: $t}')
fi

if [[ -n "$SUBAGENT_ID" ]]; then
    SUBAGENT_OBJ=$(echo "$SUBAGENT_OBJ" | jq --arg id "$SUBAGENT_ID" '. + {id: $id}')
fi

# Update state
TMP_FILE=$(mktemp)
if jq --argjson sub "$SUBAGENT_OBJ" \
    ".updated_at = \"$NOW\" |
     .phases.\"$PHASE\".subagent_results = (.phases.\"$PHASE\".subagent_results // {}) + {\"$(date +%s)\": \$sub}" \
    "$STATE_FILE" > "$TMP_FILE"; then
    mv "$TMP_FILE" "$STATE_FILE"
    echo "{\"status\":\"merged\",\"phase\":\"$PHASE\",\"timestamp\":\"$NOW\"}"
else
    rm -f "$TMP_FILE"
    die_json "Failed to merge subagent result" 1
fi
