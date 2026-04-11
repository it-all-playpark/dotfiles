#!/usr/bin/env bash
# PreToolUse(Bash) hook: prod credential 露出の検知
#
# 目的:
#   long-running session で Bash 経由に prod 環境の credential が露出することを
#   deterministic に防ぐ。検知時は permissionDecision="ask" を返して、
#   ユーザーに明示的な確認を求める（完全 deny ではなく escape 可能）。
#
# 検知対象:
#   1. 環境変数参照: $PROD_*, ${PRODUCTION_*}, $LIVE_*
#      - 必ず `_` サフィックスを要求することで $PRODUCER のような false positive を回避
#   2. .env.production / .env.prod ファイルの読み込み
#      - cat/less/more/head/tail/source/./grep/awk/sed/bat 等任意のコマンド
#   3. aws --profile に prod を含むプロファイル名
#      - aws ... --profile prod / --profile=prod-admin / --profile my-prod-read
#
# 出力:
#   - 検知時: stdout に
#       {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#         "permissionDecision":"ask",
#         "permissionDecisionReason":"<理由>"}}
#   - 非検知時: stdout 空で exit 0（チェーン通過 → Claude 通常の permission flow）
#
# 誤検知（false-positive）テストケース:
#   以下は検知「しない」ことをテストで担保している。
#     - echo $HOME / echo $PATH                （一般的な変数）
#     - echo "product listing" / ls products/  （product は検知しない）
#     - echo $PRODUCER                         （PROD + UCER、_ 区切りなし）
#     - git log --grep=production              （.env.production ファイルではない）
#     - cat .env.test / .env.development / .env.staging
#     - echo $STAGING_API_KEY / echo $DEV_TOKEN
#     - aws --profile staging / --profile default
#   詳細は pretool-bash-credential-guard.test.sh を参照。
#
# 参考:
#   - Simon Willison: Designing agentic loops (credential scoping to test/staging)
#   - Simon Willison: Parallel coding agents (blast radius containment)

set -euo pipefail

INPUT=$(cat)

# Bash ツール以外は対象外
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [[ $TOOL != "Bash" ]]; then
  exit 0
fi

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [[ -z $CMD ]]; then
  exit 0
fi

emit_ask() {
  local reason="$1"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# --- 1. PROD/PRODUCTION/LIVE 環境変数参照 ---
# $PROD_XXX / ${PROD_XXX} / $PRODUCTION_XXX / $LIVE_XXX 形式を検知
# PROD/PRODUCTION/LIVE の直後に `_` が必須（$PRODUCER 等を除外）
if echo "$CMD" | grep -qE '\$\{?(PROD|PRODUCTION|LIVE)_[A-Z0-9_]+'; then
  MATCH=$(echo "$CMD" | grep -oE '\$\{?(PROD|PRODUCTION|LIVE)_[A-Z0-9_]+' | head -1)
  emit_ask "prod credential env var を検知: ${MATCH}"
fi

# --- 2. .env.production / .env.prod ファイルの参照 ---
# 単語境界で `.env.production` または `.env.prod` が登場するケースを検知
# ファイル名末尾 (空白/行末/引用符/セミコロン/パイプ/リダイレクト) で境界を判定
if echo "$CMD" | grep -qE '(^|[[:space:]/"'"'"'=])\.env\.(production|prod)([[:space:]"'"'"';|&<>]|$)'; then
  MATCH=$(echo "$CMD" | grep -oE '\.env\.(production|prod)' | head -1)
  emit_ask "prod env ファイル参照を検知: ${MATCH}"
fi

# --- 3. aws --profile に prod を含むプロファイル名 ---
# `aws` コマンドかつ `--profile <name>` or `--profile=<name>` に prod を含む
if echo "$CMD" | grep -qE '(^|[[:space:]])aws([[:space:]]|$)'; then
  # --profile <value> または --profile=<value> を抽出
  PROFILE=$(echo "$CMD" | grep -oE -- '--profile[= ][^[:space:]]+' | head -1 | sed -E 's/^--profile[= ]//')
  if [[ -n $PROFILE ]] && echo "$PROFILE" | grep -qiE 'prod'; then
    emit_ask "aws prod profile を検知: --profile ${PROFILE}"
  fi
fi

# 検知なし: pass-through
exit 0
