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
#   4. （2 段目）1〜3 が非検知のとき、字面で「本番に触りうる」候補
#      （cloud CLI / DB クライアント / --context・--profile・--project /
#      prod・live・deploy・migrate 等の語）に絞った上で、Jev に
#      「本番環境・本番 credential・実顧客データに触るか」を noul で判定させ、
#      p >= $CREDENTIAL_GUARD_JEV_THRESHOLD（既定 0.7）なら 1〜3 と同じ ask。
#      1〜3 が見逃す `kubectl --context live-cluster` / `gcloud … xxx-main` /
#      `vercel --prod` / `--profile main-account` のような形を拾う。
#      候補に絞るのは全 Bash に Jev の遅延（~1 秒）を載せないため。
#      Jev 不可（鍵なし・timeout・JEV_DISABLE=1）や CREDENTIAL_GUARD_JEV=0 なら
#      1〜3 だけで判定する（fail-open）。
#      判定は ~/.claude/logs/credential-guard.jsonl に記録する（精度の事後検証用）。
#
# 出力:
#   - 検知時: stdout に
#       {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#         "permissionDecision":"ask",
#         "permissionDecisionReason":"<理由>"}}
#   - 非検知時: stdout 空で exit 0（チェーン通過 → Claude 通常の permission flow）
#
# 環境変数:
#   CREDENTIAL_GUARD_JEV            0 で 2 段目を無効化（既定 1）
#   CREDENTIAL_GUARD_JEV_THRESHOLD  ask にする確率の下限（既定 0.7）
#   CREDENTIAL_GUARD_LOG            記録先（テスト用）
#   JEV_*                           jev-classify.sh を参照
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${CREDENTIAL_GUARD_LOG:-$HOME/.claude/logs/credential-guard.jsonl}"

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

# log_decision <stage: regex|jev> <p (数値 or null)> <asked: true|false>
log_decision() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
  jq -n -c \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg stage "$1" \
    --argjson p "$2" \
    --argjson asked "$3" \
    --arg cmd "$(printf '%s' "$CMD" | head -c 300)" \
    --arg session "$(echo "$INPUT" | jq -r '.session_id // "unknown"')" \
    '{ts: $ts, stage: $stage, p: $p, asked: $asked, cmd: $cmd, session: $session}' \
    >>"$LOG_FILE" 2>/dev/null || true
}

# emit_ask <理由> [stage] [p]
emit_ask() {
  local reason="$1"
  log_decision "${2:-regex}" "${3:-null}" true
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

# --- 4. 2 段目: 候補に絞って Jev に「本番に触るか」を判定させる ---
if [[ ${CREDENTIAL_GUARD_JEV:-1} == "0" ]]; then
  exit 0
fi

# 候補の前選別（字面）。ここに掛からないコマンドは Jev を呼ばず素通し。
#   - cloud / infra / deploy CLI と DB クライアント
#   - 環境・プロジェクト・プロファイルを選ぶフラグ
#   - 本番・稼働・配備・移行を示す語（prod は product を除外するため境界付き）
#   - 接続文字列らしき *_URL= / DSN
CANDIDATE_RE='(^|[^[:alnum:]_])(aws|gcloud|gsutil|az|kubectl|helm|terraform|pulumi|vercel|netlify|fly|flyctl|heroku|railway|render|supabase|firebase|wrangler|doctl|psql|pg_dump|pg_restore|mysql|mysqldump|mongosh|mongo|redis-cli|stripe|twilio|sendgrid|ssh|scp|rsync|ansible|kamal|cap|capistrano)([[:space:]]|$)|--(context|profile|project|env|environment|stage|target|namespace|cluster|prod|production)([=[:space:]]|$)|(^|[^[:alnum:]])(prod|production|live|deploy|deployment|release|rollout|migrate|migration|promote)([^[:alnum:]]|$)|[A-Z_]*(URL|DSN|CONNECTION_STRING)='

if ! echo "$CMD" | grep -qE "$CANDIDATE_RE"; then
  exit 0
fi

PROD_QUESTIONS='{
  "prod": {
    "type": "noul",
    "instructions": "The state is a shell command an AI coding agent wants to run on a developer machine. Does the command read or mutate a PRODUCTION environment, a production credential, or live customer data? Production means the live system serving real users: prod / production / live / main clusters, projects, profiles, accounts, databases, deployments, secrets, or a deploy that goes live. Commands that clearly target test, staging, development, preview, local, sandbox, or CI environments, or that only inspect the local repository, are not production. If the environment cannot be determined from the command, answer no."
  }
}'

RESULT=$(printf '%s' "$CMD" | bash "$SCRIPT_DIR/jev-classify.sh" --redact --questions "$PROD_QUESTIONS" 2>/dev/null || true)
[[ -n $RESULT ]] || exit 0
P=$(echo "$RESULT" | jq -r '.answers.prod.noul // empty' 2>/dev/null || true)
[[ -n $P ]] || exit 0

THRESHOLD="${CREDENTIAL_GUARD_JEV_THRESHOLD:-0.7}"
if jq -en --argjson p "$P" --argjson t "$THRESHOLD" '$p >= $t' >/dev/null; then
  emit_ask "本番環境・credential に触る可能性を検知 (Jev p=${P})" jev "$P"
fi

log_decision jev "$P" false

# 検知なし: pass-through
exit 0
