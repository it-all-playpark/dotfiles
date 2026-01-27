#!/usr/bin/env bash
# git-sync.sh - Sync with remote repository

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

require_git_repo

ACTION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --pull) ACTION="pull"; shift ;;
        --push) ACTION="push"; shift ;;
        --rebase) ACTION="rebase"; shift ;;
        -h|--help)
            echo "Usage: git-sync.sh [--pull|--push|--rebase]"
            exit 0
            ;;
        *) shift ;;
    esac
done

branch=$(git_current_branch)
remote=$(git config --get "branch.$branch.remote" 2>/dev/null || echo "origin")

case "$ACTION" in
    pull)
        if output=$(git pull "$remote" "$branch" 2>&1); then
            if echo "$output" | grep -q "Already up to date"; then
                echo "{\"status\":\"success\",\"action\":\"pull\",\"message\":\"Already up to date\"}"
            else
                echo "{\"status\":\"success\",\"action\":\"pull\",\"message\":\"Pulled latest changes\"}"
            fi
        else
            if echo "$output" | grep -q "CONFLICT"; then
                echo "{\"status\":\"conflict\",\"action\":\"pull\",\"message\":\"Merge conflicts detected\",\"conflicts\":true}"
            else
                die_json "Pull failed: ${output%%$'\n'*}"
            fi
        fi
        ;;
    push)
        if git push "$remote" "$branch" 2>/dev/null; then
            echo "{\"status\":\"success\",\"action\":\"push\",\"message\":\"Pushed to $remote/$branch\"}"
        else
            die_json "Push failed. Check if remote exists and you have permission."
        fi
        ;;
    rebase)
        if output=$(git pull --rebase "$remote" "$branch" 2>&1); then
            echo "{\"status\":\"success\",\"action\":\"rebase\",\"message\":\"Rebased on $remote/$branch\"}"
        else
            if echo "$output" | grep -q "CONFLICT"; then
                echo "{\"status\":\"conflict\",\"action\":\"rebase\",\"message\":\"Rebase conflicts\",\"conflicts\":true}"
                warn "Run 'git rebase --abort' to cancel or fix conflicts and 'git rebase --continue'"
            else
                die_json "Rebase failed"
            fi
        fi
        ;;
    "")
        ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
        behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo "0")
        echo "{\"status\":\"success\",\"branch\":$(json_str "$branch"),\"remote\":$(json_str "$remote"),\"ahead\":$ahead,\"behind\":$behind}"
        ;;
esac
