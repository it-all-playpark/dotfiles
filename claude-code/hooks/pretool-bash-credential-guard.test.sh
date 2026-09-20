#!/usr/bin/env bash
# Test suite for pretool-bash-credential-guard.sh
#
# Usage: bash pretool-bash-credential-guard.test.sh
#
# Exit 0 on all pass, non-zero otherwise.
#
# shellcheck disable=SC2016
# 単一引用符内の `$VAR` は意図的なリテラル（hook に生文字列として渡す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pretool-bash-credential-guard.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=()

# --- 2 段目（Jev）用の偽 curl ---
# 既存の正規表現ケースは鍵なしで走らせ（Keychain も存在しない service 名にして）
# Jev を呼ばない。Jev ケースだけ AI_GATEWAY_API_KEY と FAKE_P を渡す。
WORK=$(mktemp -d "${TMPDIR:-/tmp}/credential-guard-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  -d) body="$2"; shift 2 ;;
  --max-time|-H|--config) shift 2 ;;
  *) shift ;;
  esac
done
printf '%s' "$body" >"$FAKE_CURL_DIR/body"
printf '{"model":"typesafe-ai/jev","answers":{"prod":{"type":"noul","noul":%s}},"usage":{"input_tokens":80,"output_tokens":0}}\n' "${FAKE_P:-0.9}"
EOF
chmod +x "$WORK/bin/curl"
export FAKE_CURL_DIR="$WORK"
export PATH="$WORK/bin:$PATH"
export JEV_KEYCHAIN_SERVICE="credential-guard-test-nonexistent-service"
export CREDENTIAL_GUARD_LOG="$WORK/log.jsonl"
unset AI_GATEWAY_API_KEY

# run_case <name> <command> <expected: ask|pass> [env assignments...]
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"
  shift 3

  local input
  input=$(jq -n --arg cmd "$cmd" '{tool_name:"Bash", tool_input:{command:$cmd}}')

  rm -f "$WORK/body"
  local output
  output=$(echo "$input" | env "$@" bash "$HOOK" 2>&1 || true)

  local decision="pass"
  if [[ -n $output ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null || echo "pass")
  fi

  if [[ $decision == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected=$expected got=$decision cmd=$cmd")
    printf "  \033[31mFAIL\033[0m %s (expected=%s, got=%s)\n" "$name" "$expected" "$decision"
  fi
}

echo "=== pretool-bash-credential-guard tests ==="

# --- Positive cases: should trigger "ask" ---
echo "[Positive cases — should detect]"
run_case "PROD env var reference" 'echo $PROD_API_KEY' "ask"
run_case "PROD env var with braces" 'echo ${PROD_DB_PASSWORD}' "ask"
run_case "PRODUCTION env var reference" 'echo $PRODUCTION_SECRET' "ask"
run_case "LIVE env var reference" 'curl -H "X: $LIVE_TOKEN" https://api.example.com' "ask"
run_case "cat .env.production" 'cat .env.production' "ask"
run_case "cat .env.prod" 'cat .env.prod' "ask"
run_case "source .env.production" 'source .env.production' "ask"
run_case "grep in .env.production" 'grep KEY .env.production' "ask"
run_case "aws --profile prod" 'aws s3 ls --profile prod' "ask"
run_case "aws --profile my-prod-admin" 'aws --profile my-prod-admin sts get-caller-identity' "ask"

# --- Negative cases: should NOT trigger ---
echo "[Negative cases — should pass through]"
run_case 'echo $HOME' 'echo $HOME' "pass"
run_case 'echo $PATH' 'echo $PATH' "pass"
run_case "ls -la" 'ls -la' "pass"
run_case "git status" 'git status' "pass"
run_case "cat .env.test" 'cat .env.test' "pass"
run_case "cat .env.development" 'cat .env.development' "pass"
run_case "cat .env.staging" 'cat .env.staging' "pass"
run_case 'echo $STAGING_API_KEY' 'echo $STAGING_API_KEY' "pass"
run_case 'echo $DEV_TOKEN' 'echo $DEV_TOKEN' "pass"
run_case "aws --profile staging" 'aws s3 ls --profile staging' "pass"
run_case "aws --profile default" 'aws sts get-caller-identity --profile default' "pass"

# --- False-positive guard cases (documented) ---
echo "[False-positive guard — should pass through]"
# The word "prod" appearing in unrelated context should not trigger.
run_case "echo product listing" 'echo "product listing"' "pass"
run_case "ls products/" 'ls products/' "pass"
run_case "git log --grep production" 'git log --grep=production' "pass"
# $PRODUCER is not PROD_ / PRODUCTION_ / LIVE_ — should not match (word boundary)
run_case 'echo $PRODUCER' 'echo $PRODUCER' "pass"

# --- Stage 2: Jev（候補に絞って noul 判定）---
echo "[Stage 2 — Jev on candidates]"
# expect_call <name> <yes|no>: 直前の run_case で偽 curl が呼ばれたか
expect_call() {
  local name="$1" want="$2" got="no"
  [[ -f "$WORK/body" ]] && got="yes"
  if [[ $got == "$want" ]]; then
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s (jev call=%s)\n" "$name" "$got"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected jev call=$want got=$got")
    printf "  \033[31mFAIL\033[0m %s (expected jev call=%s, got=%s)\n" "$name" "$want" "$got"
  fi
}
last_log() { tail -n 1 "$CREDENTIAL_GUARD_LOG"; }

# regex が見逃す形 → 候補に掛かり Jev が高確率 → ask
run_case "kubectl --context live-cluster (p=0.92)" 'kubectl --context live-cluster get secrets' "ask" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.92
expect_call "  jev called" yes
if [[ $(last_log | jq -r '.stage') == "jev" && $(last_log | jq -r '.asked') == "true" && $(last_log | jq -r '.p') == "0.92" ]]; then
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m   logged stage=jev asked=true\n"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("log after jev ask: $(last_log)")
  printf "  \033[31mFAIL\033[0m   logged stage=jev asked=true: %s\n" "$(last_log)"
fi
run_case "vercel --prod (p=0.88)" 'vercel deploy --prod' "ask" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.88
run_case "gcloud project xxx-main (p=0.75)" 'gcloud config set project acme-main' "ask" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.75

# 候補だが Jev が低確率 → pass（記録は asked=false）
run_case "kubectl --context kind-local (p=0.05)" 'kubectl --context kind-local get pods' "pass" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.05
expect_call "  jev called" yes
if [[ $(last_log | jq -r '.stage') == "jev" && $(last_log | jq -r '.asked') == "false" ]]; then
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m   logged stage=jev asked=false\n"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("log after jev pass: $(last_log)")
  printf "  \033[31mFAIL\033[0m   logged stage=jev asked=false: %s\n" "$(last_log)"
fi
run_case "vercel deploy preview (p=0.1)" 'vercel deploy' "pass" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.1

# 閾値ちょうど / 上書き
run_case "threshold boundary p=0.7 → ask" 'aws s3 ls --profile main-account' "ask" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.7
run_case "threshold override 0.9: p=0.8 → pass" 'aws s3 ls --profile main-account' "pass" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.8 CREDENTIAL_GUARD_JEV_THRESHOLD=0.9

# 候補外は Jev を呼ばない（鍵があっても）
run_case "ls -la (not a candidate)" 'ls -la' "pass" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.99
expect_call "  jev not called" no
run_case "git status (not a candidate)" 'git status' "pass" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.99
expect_call "  jev not called" no
run_case "echo product listing (not a candidate)" 'echo "product listing"' "pass" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.99
expect_call "  jev not called" no

# regex が先に検知したときは Jev を呼ばない（記録は stage=regex）
run_case "regex hit short-circuits jev" 'aws s3 ls --profile prod' "ask" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.01
expect_call "  jev not called" no
if [[ $(last_log | jq -r '.stage') == "regex" && $(last_log | jq -r '.asked') == "true" ]]; then
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m   logged stage=regex asked=true\n"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("log after regex ask: $(last_log)")
  printf "  \033[31mFAIL\033[0m   logged stage=regex asked=true: %s\n" "$(last_log)"
fi

# 2 段目の無効化 / Jev 不可 → 候補でも素通し
run_case "CREDENTIAL_GUARD_JEV=0" 'kubectl --context live-cluster get secrets' "pass" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.99 CREDENTIAL_GUARD_JEV=0
expect_call "  jev not called" no
run_case "no key: fail-open" 'kubectl --context live-cluster get secrets' "pass"
expect_call "  jev not called" no
run_case "JEV_DISABLE=1: fail-open" 'kubectl --context live-cluster get secrets' "pass" AI_GATEWAY_API_KEY=vck_test_key JEV_DISABLE=1
expect_call "  jev not called" no

# 送信前 redaction
run_case "redact before jev" 'DATABASE_URL=postgres://u:hunter2@db.prod.internal/app psql' "ask" AI_GATEWAY_API_KEY=vck_test_key FAKE_P=0.9
if [[ $(jq -r '.state' "$WORK/body") != *hunter2* && $(jq -r '.state' "$WORK/body") == *"<redacted>"* ]]; then
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m   secret not sent to jev\n"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("redaction: $(jq -r '.state' "$WORK/body")")
  printf "  \033[31mFAIL\033[0m   secret not sent to jev: %s\n" "$(jq -r '.state' "$WORK/body")"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if ((FAIL > 0)); then
  printf '\n'
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
