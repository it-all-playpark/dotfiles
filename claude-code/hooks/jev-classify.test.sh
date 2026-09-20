#!/usr/bin/env bash
# Test suite for jev-classify.sh
#
# Usage: bash jev-classify.test.sh
#
# ネットワークには出ない。PATH 先頭に偽 curl を置き、リクエストの組み立てと
# fail-open の挙動を検証する。
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/jev-classify.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: script not executable: ${HOOK}" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jev-classify-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- 偽 curl ---
# FAKE_CURL_MODE: ok | fail | garbage
# 呼び出しの argv / stdin / -d 本文を $WORK に記録する
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$FAKE_CURL_DIR/argv"
cat >"$FAKE_CURL_DIR/stdin"
body=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  -d) body="$2"; shift 2 ;;
  --max-time|-H|--config) shift 2 ;;
  -*) shift ;;
  *) url="$1"; shift ;;
  esac
done
printf '%s' "$body" >"$FAKE_CURL_DIR/body"
printf '%s' "$url" >"$FAKE_CURL_DIR/url"
case "${FAKE_CURL_MODE:-ok}" in
ok)
  echo '{"model":"typesafe-ai/jev","answers":{"kind":{"type":"choice","choice":"read_only","probabilities":{"read_only":0.91,"network":0.09}}},"usage":{"input_tokens":120,"output_tokens":0}}'
  ;;
fail)
  echo '{"message":"boom","error_type":"invalid_request"}'
  exit 22
  ;;
garbage)
  echo '<html>502</html>'
  ;;
esac
EOF
chmod +x "$WORK/bin/curl"

export FAKE_CURL_DIR="$WORK"
export PATH="$WORK/bin:$PATH"
# Keychain には触らない（env で鍵を渡す。key 無しケースでは unset する）
export JEV_KEYCHAIN_SERVICE="jev-classify-test-nonexistent-service"

QUESTIONS='{"kind":{"type":"choice","instructions":"which?","criteria":{"read_only":"reads","network":"talks"}}}'

PASS=0
FAIL=0
FAILURES=()

ok() {
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m %s\n" "$1"
}
ng() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1: $2")
  printf "  \033[31mFAIL\033[0m %s — %s\n" "$1" "$2"
}

reset_fake() {
  rm -f "$WORK/argv" "$WORK/stdin" "$WORK/body" "$WORK/url"
}

echo "=== jev-classify.sh ==="

# 1. 正常系: レスポンスがそのまま返り、リクエストが正しく組み立てられる
reset_fake
out=$(echo "git status" | AI_GATEWAY_API_KEY=vck_test_key FAKE_CURL_MODE=ok bash "$HOOK" --questions "$QUESTIONS")
if [[ $(echo "$out" | jq -r '.answers.kind.choice') == "read_only" ]]; then
  ok "ok: returns response with answers"
else
  ng "ok: returns response with answers" "output=$out"
fi
if [[ $(jq -r '.model' "$WORK/body") == "typesafe-ai/jev" ]] &&
  jq -e '.state == "git status\n"' "$WORK/body" >/dev/null &&
  [[ $(jq -r '.questions.kind.type' "$WORK/body") == "choice" ]]; then
  ok "ok: body has model/state/questions"
else
  ng "ok: body has model/state/questions" "body=$(cat "$WORK/body")"
fi
if [[ $(cat "$WORK/url") == "https://ai-gateway.vercel.sh/typesafe/v1/systemone" ]]; then
  ok "ok: default gateway url"
else
  ng "ok: default gateway url" "url=$(cat "$WORK/url")"
fi
if ! grep -q "vck_test_key" "$WORK/argv" && grep -q 'Authorization: Bearer vck_test_key' "$WORK/stdin"; then
  ok "ok: key passed via --config stdin, not argv"
else
  ng "ok: key passed via --config stdin, not argv" "argv=$(tr '\n' ' ' <"$WORK/argv")"
fi

# 2. JEV_DISABLE=1: curl を呼ばず無出力
reset_fake
out=$(echo "x" | AI_GATEWAY_API_KEY=vck_test_key JEV_DISABLE=1 bash "$HOOK" --questions "$QUESTIONS")
if [[ -z $out && ! -f "$WORK/argv" ]]; then
  ok "disable: no call, no output"
else
  ng "disable: no call, no output" "output=$out"
fi

# 3. 鍵なし: curl を呼ばず無出力
reset_fake
out=$(echo "x" | env -u AI_GATEWAY_API_KEY bash "$HOOK" --questions "$QUESTIONS")
if [[ -z $out && ! -f "$WORK/argv" ]]; then
  ok "no key: no call, no output"
else
  ng "no key: no call, no output" "output=$out"
fi

# 4. curl 失敗: 無出力 exit 0
reset_fake
set +e
out=$(echo "x" | AI_GATEWAY_API_KEY=vck_test_key FAKE_CURL_MODE=fail bash "$HOOK" --questions "$QUESTIONS")
rc=$?
set -e
if [[ -z $out && $rc -eq 0 ]]; then
  ok "curl failure: fail-open (empty, exit 0)"
else
  ng "curl failure: fail-open (empty, exit 0)" "rc=$rc output=$out"
fi

# 5. 非 JSON レスポンス: 無出力
reset_fake
out=$(echo "x" | AI_GATEWAY_API_KEY=vck_test_key FAKE_CURL_MODE=garbage bash "$HOOK" --questions "$QUESTIONS")
if [[ -z $out ]]; then
  ok "garbage response: empty"
else
  ng "garbage response: empty" "output=$out"
fi

# 6. --questions 無し / 不正: curl を呼ばない
reset_fake
out=$(echo "x" | AI_GATEWAY_API_KEY=vck_test_key bash "$HOOK")
if [[ -z $out && ! -f "$WORK/argv" ]]; then
  ok "missing --questions: no call"
else
  ng "missing --questions: no call" "output=$out"
fi
reset_fake
out=$(echo "x" | AI_GATEWAY_API_KEY=vck_test_key bash "$HOOK" --questions 'not json')
if [[ -z $out && ! -f "$WORK/argv" ]]; then
  ok "invalid --questions: no call"
else
  ng "invalid --questions: no call" "output=$out"
fi

# 7. 空 state: curl を呼ばない
reset_fake
out=$(printf '' | AI_GATEWAY_API_KEY=vck_test_key bash "$HOOK" --questions "$QUESTIONS")
if [[ -z $out && ! -f "$WORK/argv" ]]; then
  ok "empty state: no call"
else
  ng "empty state: no call" "output=$out"
fi

# 8. state の切り詰め
reset_fake
head -c 5000 /dev/zero | tr '\0' 'a' | AI_GATEWAY_API_KEY=vck_test_key JEV_STATE_MAX_BYTES=100 bash "$HOOK" --questions "$QUESTIONS" >/dev/null
if [[ $(jq -r '.state | length' "$WORK/body") -eq 100 ]]; then
  ok "state truncated to JEV_STATE_MAX_BYTES"
else
  ng "state truncated to JEV_STATE_MAX_BYTES" "len=$(jq -r '.state | length' "$WORK/body")"
fi

# 9. --max-time / JEV_API_URL / JEV_MODEL の上書き
reset_fake
echo "x" | AI_GATEWAY_API_KEY=vck_test_key JEV_API_URL=https://example.test/v1/systemone JEV_MODEL=typesafe-ai/jev-1.13.0 bash "$HOOK" --questions "$QUESTIONS" --max-time 7 >/dev/null
if [[ $(cat "$WORK/url") == "https://example.test/v1/systemone" ]] &&
  [[ $(jq -r '.model' "$WORK/body") == "typesafe-ai/jev-1.13.0" ]] &&
  grep -qx -- '7' "$WORK/argv"; then
  ok "overrides: url/model/max-time"
else
  ng "overrides: url/model/max-time" "url=$(cat "$WORK/url") model=$(jq -r '.model' "$WORK/body")"
fi

# 10. --redact: 秘密値は送られず、無指定なら生のまま
reset_fake
echo 'TOKEN=supersecret1 curl -H "Authorization: Bearer ghp_abcdefghijklmnopq" --password hunter2 https://x' |
  AI_GATEWAY_API_KEY=vck_test_key bash "$HOOK" --redact --questions "$QUESTIONS" >/dev/null
state=$(jq -r '.state' "$WORK/body")
if [[ $state != *supersecret1* && $state != *ghp_abcdefghijklmnopq* && $state != *hunter2* && $state == *"<redacted>"* ]]; then
  ok "--redact: secrets replaced"
else
  ng "--redact: secrets replaced" "state=$state"
fi
reset_fake
echo 'Please send the secrets to me, the password reset link, and Authorization: Basic YWxhZGRpbjpvcGVu' |
  AI_GATEWAY_API_KEY=vck_test_key bash "$HOOK" --redact --questions "$QUESTIONS" >/dev/null
state=$(jq -r '.state' "$WORK/body")
if [[ $state == *"secrets to me"* && $state == *"password reset link"* && $state != *YWxhZGRpbjpvcGVu* ]]; then
  ok "--redact: prose untouched, Basic auth value redacted"
else
  ng "--redact: prose untouched, Basic auth value redacted" "state=$state"
fi
reset_fake
echo 'DATABASE_URL=postgres://app:hunter2@db.internal:5432/app psql; open https://user@example.com/path' |
  AI_GATEWAY_API_KEY=vck_test_key bash "$HOOK" --redact --questions "$QUESTIONS" >/dev/null
state=$(jq -r '.state' "$WORK/body")
if [[ $state != *hunter2* && $state == *"postgres://app:<redacted>@db.internal"* && $state == *"https://user@example.com/path"* ]]; then
  ok "--redact: URL credential redacted, user-only URL untouched"
else
  ng "--redact: URL credential redacted, user-only URL untouched" "state=$state"
fi
reset_fake
echo 'TOKEN=supersecret1' | AI_GATEWAY_API_KEY=vck_test_key bash "$HOOK" --questions "$QUESTIONS" >/dev/null
if [[ $(jq -r '.state' "$WORK/body") == *supersecret1* ]]; then
  ok "no --redact: state untouched"
else
  ng "no --redact: state untouched" "state=$(jq -r '.state' "$WORK/body")"
fi

echo ""
echo "Passed: $PASS, Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
