#!/bin/bash
# PreToolUse hook: gh pr merge は常にユーザー確認 (ask) にする
# auto mode の classifier に merge 可否を委ねず、merge を人間の判断に固定する。

set -euo pipefail

CMD=$(jq -r '.tool_input.command // empty')

case "$CMD" in
"gh pr merge "*)
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"PR の merge はユーザー確認が必要"}}'
  ;;
esac
