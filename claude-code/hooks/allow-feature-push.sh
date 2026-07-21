#!/bin/bash
# PreToolUse hook: git push のブランチ保護
# - push 宛先(push コマンドの refspec から抽出したブランチ)が保護/デプロイブランチ → deny
# - feature/* 等 → allow
# - 宛先が判定不能 → ask（ユーザーに確認）
#
# 宛先の決め方:
#   git push                         → 現在ブランチを宛先として fallback
#   git push origin                  → 現在ブランチを宛先として fallback
#   git push origin main             → main
#   git push origin feature/x        → feature/x
#   git push origin HEAD:refs/heads/production → production
#   git push origin +main:main       → main（強制 push の '+' を除去）

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# git push 系コマンドのみ対象
case "$CMD" in
"git push"*) ;;
*) exit 0 ;;
esac

deny() {
  local branch="$1"
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"保護/デプロイブランチ ($branch) への push は禁止\"}}"
  exit 0
}

ask() {
  local reason="$1"
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"$reason\"}}"
  exit 0
}

allow() {
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"non-protected push destination auto-approved"}}'
  exit 0
}

is_protected() {
  case "$1" in
  main | master | dev | develop | development | production | staging | release | nightly)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

# "git push" 以降のトークンを取り出す（値を取るフラグはその値ごとスキップ）
REST="${CMD#git push}"
read -ra TOKENS <<<"$REST"

ARGS=()
skip_next=0
for tok in "${TOKENS[@]}"; do
  if [ "$skip_next" = "1" ]; then
    skip_next=0
    continue
  fi
  case "$tok" in
  -o | --push-option | --repo | --receive-pack | --exec)
    skip_next=1
    continue
    ;;
  -*)
    continue
    ;;
  *)
    ARGS+=("$tok")
    ;;
  esac
done

REFSPEC=""
if [ "${#ARGS[@]}" -ge 2 ]; then
  REFSPEC="${ARGS[1]}"
fi

DEST_BRANCH=""
if [ -n "$REFSPEC" ]; then
  # 強制 push を表す先頭の '+' を除去
  REFSPEC="${REFSPEC#+}"
  if [[ $REFSPEC == *:* ]]; then
    DEST_BRANCH="${REFSPEC##*:}"
  else
    DEST_BRANCH="$REFSPEC"
  fi
  DEST_BRANCH="${DEST_BRANCH#refs/heads/}"
fi

if [ -z "$DEST_BRANCH" ]; then
  # refspec に宛先ブランチが明示されない → 現在ブランチを fallback 宛先とする
  DEST_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -z "$DEST_BRANCH" ] || [ "$DEST_BRANCH" = "HEAD" ]; then
    ask "push 宛先ブランチを検出できません"
  fi
fi

if is_protected "$DEST_BRANCH"; then
  deny "$DEST_BRANCH"
fi

allow
