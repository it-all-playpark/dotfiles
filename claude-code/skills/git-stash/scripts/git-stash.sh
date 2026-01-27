#!/usr/bin/env bash
# git-stash.sh - Stash management operations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

require_git_repo

ACTION=""
MESSAGE=""
INDEX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --push) ACTION="push"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { MESSAGE="$1"; shift; } ;;
        --pop) ACTION="pop"; shift ;;
        --list) ACTION="list"; shift ;;
        --apply) ACTION="apply"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { INDEX="$1"; shift; } ;;
        --drop) ACTION="drop"; shift; [[ $# -gt 0 && ! "$1" =~ ^-- ]] && { INDEX="$1"; shift; } ;;
        -h|--help)
            echo "Usage: git-stash.sh [--push|--pop|--list|--apply|--drop] [message|index]"
            exit 0
            ;;
        *) shift ;;
    esac
done

case "$ACTION" in
    push)
        if [[ -n "$MESSAGE" ]]; then
            git stash push -m "$MESSAGE" 2>/dev/null && \
                echo "{\"status\":\"success\",\"action\":\"push\",\"message\":$(json_str "Stashed: $MESSAGE")}" || \
                die_json "No changes to stash"
        else
            git stash push 2>/dev/null && \
                echo "{\"status\":\"success\",\"action\":\"push\",\"message\":\"Changes stashed\"}" || \
                die_json "No changes to stash"
        fi
        ;;
    pop)
        git stash pop 2>/dev/null && \
            echo "{\"status\":\"success\",\"action\":\"pop\",\"message\":\"Stash applied and removed\"}" || \
            die_json "No stash to pop or conflict occurred"
        ;;
    list)
        if has_jq; then
            stashes=$(git stash list --format='{"index":"%gd","message":"%s"}' 2>/dev/null | jq -s '.' || echo "[]")
        else
            stashes="[]"
        fi
        echo "{\"status\":\"success\",\"action\":\"list\",\"stashes\":$stashes}"
        ;;
    apply)
        ref="${INDEX:-stash@{0}}"
        git stash apply "$ref" 2>/dev/null && \
            echo "{\"status\":\"success\",\"action\":\"apply\",\"ref\":$(json_str "$ref")}" || \
            die_json "Failed to apply $ref"
        ;;
    drop)
        ref="${INDEX:-stash@{0}}"
        git stash drop "$ref" 2>/dev/null && \
            echo "{\"status\":\"success\",\"action\":\"drop\",\"ref\":$(json_str "$ref")}" || \
            die_json "Failed to drop $ref"
        ;;
    "")
        count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
        echo "{\"status\":\"success\",\"action\":\"count\",\"count\":$count}"
        ;;
esac
