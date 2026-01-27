#!/usr/bin/env bash
# git-log.sh - View commit history with formatting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

require_git_repo

# Defaults
ONELINE=false
GRAPH=false
AUTHOR=""
COUNT=10
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --oneline) ONELINE=true; shift ;;
        --graph) GRAPH=true; shift ;;
        --author) AUTHOR="$2"; shift 2 ;;
        -n) COUNT="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        -h|--help)
            echo "Usage: git-log.sh [--oneline] [--graph] [--author NAME] [-n COUNT] [--json]"
            exit 0
            ;;
        *) shift ;;
    esac
done

# Build and execute
args=("-n" "$COUNT")
[[ -n "$AUTHOR" ]] && args+=("--author=$AUTHOR")

if [[ "$JSON_OUTPUT" == true ]]; then
    if has_jq; then
        git log "${args[@]}" --format='{"hash":"%H","short_hash":"%h","author":"%an","date":"%ci","subject":"%s"}' | jq -s '.'
    else
        die_json "JSON output requires jq"
    fi
elif [[ "$GRAPH" == true ]]; then
    if [[ "$ONELINE" == true ]]; then
        git log "${args[@]}" --graph --oneline --decorate
    else
        git log "${args[@]}" --graph --format="%h %s (%an, %cr)"
    fi
elif [[ "$ONELINE" == true ]]; then
    git log "${args[@]}" --oneline
else
    git log "${args[@]}" --format="%h %s (%an, %cr)"
fi
