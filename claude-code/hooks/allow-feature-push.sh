#!/bin/bash
# PreToolUse hook: git push のブランチ保護
# - 保護ブランチ → deny
# - feature/* 等 → allow
# - 判定不能 → ask（ユーザーに確認）

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# git push 系コマンドのみ対象
case "$CMD" in
"git push"*) ;;
*) exit 0 ;;
esac

# 現在のブランチを取得
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BRANCH" ]; then
  # git リポジトリ外 or detached HEAD → ユーザーに確認
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"ブランチを検出できません"}}'
  exit 0
fi

# 保護ブランチなら deny
case "$BRANCH" in
main | master | dev | develop | development)
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"保護ブランチ ($BRANCH) への push は禁止\"}}"
  exit 0
  ;;
esac

# それ以外は allow
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"non-protected branch push auto-approved"}}'
