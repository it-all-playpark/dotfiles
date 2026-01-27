#!/usr/bin/env bash
# git-status.sh - Repository status with JSON output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../_lib/common.sh"

require_git_repo

SHORT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --short) SHORT=true; shift ;;
        --json) shift ;;
        -h|--help)
            echo "Usage: git-status.sh [--short] [--json]"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ "$SHORT" == true ]]; then
    git status --short
    exit 0
fi

branch=$(git_current_branch)
tracking=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "")
ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo "0")

staged=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
modified=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')

dirty="false"
[[ "$staged" -gt 0 || "$modified" -gt 0 || "$untracked" -gt 0 ]] && dirty="true"

echo "{"
echo "  \"branch\": $(json_str "$branch"),"
echo "  \"tracking\": $(json_str "$tracking"),"
echo "  \"ahead\": $ahead,"
echo "  \"behind\": $behind,"
echo "  \"staged\": $staged,"
echo "  \"modified\": $modified,"
echo "  \"untracked\": $untracked,"
echo "  \"conflicts\": $conflicts,"
echo "  \"dirty\": $dirty"
echo "}"
