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
#   git push origin HEAD             → 現在ブランチへ解決してから判定（bare symbolic ref）
#   git push origin @                → 同上（'@' は HEAD の別名）
#   git push origin +main:main       → main（強制 push の '+' を除去）
#   git push origin feature/x main   → 複数 refspec を全て走査（1つでも保護ブランチなら deny）
#   git push --all origin            → 宛先を列挙できないため ask
#   git push --mirror origin         → 宛先を列挙できないため ask

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# git push 系コマンドのみ対象。
# 判定前に空白を正規化する — "git  push origin main"（連続空白/タブ）は
# 素の "git push"* 前方一致では取りこぼし、container.settings.json の広い
# Bash allow により保護ブランチ push が deny されず passthrough してしまう
# ため、read -ra でトークン化してから単一スペース区切りに再結合して判定する。
read -ra CMD_TOKENS <<<"$CMD"
NORMALIZED_CMD="${CMD_TOKENS[*]}"
case "$NORMALIZED_CMD" in
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

# "git push" 以降のトークンを取り出す（値を取るフラグはその値ごとスキップ）。
# 元の $CMD ではなく正規化済み NORMALIZED_CMD から剥がす — 元の $CMD のまま
# だと連続空白のケースで "git push" prefix が一致せず REST が丸ごと残り、
# 後続の TOKENS/ARGS 抽出（remote 名/refspec の位置）がずれてしまうため。
REST="${NORMALIZED_CMD#git push}"
read -ra TOKENS <<<"$REST"

ARGS=()
HAS_ALL_OR_MIRROR=0
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
  --all | --mirror)
    HAS_ALL_OR_MIRROR=1
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

# --all / --mirror はリモート上の宛先ブランチを列挙できない（既存の保護/デプロイ
# ブランチも含めて一括 push されうる）ため、機械的に allow/deny を判定せず ask に倒す
if [ "$HAS_ALL_OR_MIRROR" = "1" ]; then
  ask "--all/--mirror は push 宛先を列挙できません（保護ブランチを含む可能性）"
fi

# ARGS[0] はリモート名（明示されていれば）、ARGS[1..] は全て refspec 候補。
# 複数 refspec が指定された場合は全てを走査し、1つでも保護ブランチが含まれれば deny
REFSPECS=()
if [ "${#ARGS[@]}" -ge 2 ]; then
  REFSPECS=("${ARGS[@]:1}")
fi

if [ "${#REFSPECS[@]}" -eq 0 ]; then
  # refspec に宛先ブランチが明示されない → 現在ブランチを fallback 宛先とする
  DEST_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -z "$DEST_BRANCH" ] || [ "$DEST_BRANCH" = "HEAD" ]; then
    ask "push 宛先ブランチを検出できません"
  fi
  if is_protected "$DEST_BRANCH"; then
    deny "$DEST_BRANCH"
  fi
  allow
fi

for REFSPEC in "${REFSPECS[@]}"; do
  # 強制 push を表す先頭の '+' を除去
  REFSPEC="${REFSPEC#+}"
  if [[ $REFSPEC == *:* ]]; then
    DEST_BRANCH="${REFSPEC##*:}"
  else
    DEST_BRANCH="$REFSPEC"
  fi
  DEST_BRANCH="${DEST_BRANCH#refs/heads/}"

  if [ -z "$DEST_BRANCH" ]; then
    continue
  fi

  # bare な symbolic ref（"git push origin HEAD" / "git push origin @"）は
  # コロン付き refspec を経ないため DEST_BRANCH に 'HEAD'/'@' がそのまま
  # 残る。is_protected は具体的なブランチ名しか知らないため一致せず allow
  # してしまう（main checkout 中の "git push origin HEAD" が push 先 main
  # なのに通ってしまうケース）— 実ブランチへ解決してから判定する。
  if [ "$DEST_BRANCH" = "HEAD" ] || [ "$DEST_BRANCH" = "@" ]; then
    RESOLVED_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$RESOLVED_BRANCH" ] || [ "$RESOLVED_BRANCH" = "HEAD" ]; then
      ask "push 宛先ブランチを検出できません"
    fi
    DEST_BRANCH="$RESOLVED_BRANCH"
  fi

  if is_protected "$DEST_BRANCH"; then
    deny "$DEST_BRANCH"
  fi
done

allow
