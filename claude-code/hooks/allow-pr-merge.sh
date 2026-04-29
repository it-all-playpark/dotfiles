#!/bin/bash
# PreToolUse hook: gh pr merge の base branch チェック
# - base が nightly/* → allow
# - それ以外 → ask
# - PR 番号不明 / 判定不能 → ask

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

case "$CMD" in
"gh pr merge "*) ;;
*) exit 0 ;;
esac

PR_NUM=$(echo "$CMD" | grep -oE '[0-9]+' | head -1)
if [ -z "$PR_NUM" ]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"PR番号を検出できません"}}'
  exit 0
fi

BASE=$(gh pr view "$PR_NUM" --json baseRefName -q .baseRefName 2>/dev/null || true)

if echo "$BASE" | grep -qE '^nightly/'; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"nightly branch merge allowed"}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"base=%s — nightly/* 以外はユーザー確認が必要"}}\n' "$BASE"
fi
