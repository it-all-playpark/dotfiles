#!/usr/bin/env bash
# Test suite for posttoolfail-classify.sh
#
# Usage: bash posttoolfail-classify.test.sh
#
# ネットワークには出ない。PATH 先頭の偽 curl で Jev 応答を差し替え、
# JSONL への記録内容（class 付与・state の組み立て・redaction・fail-open）を検証する。
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/posttoolfail-classify.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/posttoolfail-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/proj"
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
echo '{"model":"typesafe-ai/jev","answers":{"kind":{"type":"choice","choice":"sandbox_denied","probabilities":{"sandbox_denied":0.88,"other":0.12}}},"usage":{"input_tokens":200,"output_tokens":0}}'
EOF
chmod +x "$WORK/bin/curl"

export FAKE_CURL_DIR="$WORK"
export PATH="$WORK/bin:$PATH"
# 実機の jev-broker ソケットを拾わない（鍵なしで Jev を呼ばないことを検証するケースがある）
export JEV_BROKER_SOCKET="$WORK/no-broker.sock"
export JEV_KEYCHAIN_SERVICE="posttoolfail-test-nonexistent-service"
export TOOL_FAILURES_LOG="$WORK/failures.jsonl"

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

# run_hook <payload JSON> [env assignments...]
run_hook() {
  local payload="$1"
  shift
  rm -f "$WORK/body"
  echo "$payload" | (cd "$WORK/proj" && env "$@" bash "$HOOK")
}

last_record() {
  tail -n 1 "$TOOL_FAILURES_LOG"
}

echo "=== posttoolfail-classify.sh ==="

# 1. Bash 失敗 + Jev 応答あり
payload=$(jq -n --arg cwd "$WORK/proj" '{session_id:"sess-9", cwd:$cwd, tool_name:"Bash", tool_input:{command:"echo x > /tmp/foo"}, error:"Command failed with exit code 1", tool_response:"zsh: operation not permitted: /tmp/foo"}')
run_hook "$payload" AI_GATEWAY_API_KEY=vck_test_key
rec=$(last_record)
if [[ $(echo "$rec" | jq -r '.tool') == "Bash" ]] &&
  [[ $(echo "$rec" | jq -r '.class') == "sandbox_denied" ]] &&
  [[ $(echo "$rec" | jq -r '.class_p') == "0.88" ]] &&
  [[ $(echo "$rec" | jq -r '.detail') == "echo x > /tmp/foo" ]] &&
  [[ $(echo "$rec" | jq -r '.error') == "Command failed with exit code 1" ]] &&
  [[ $(echo "$rec" | jq -r '.project') == "proj" ]] &&
  [[ $(echo "$rec" | jq -r '.session') == "sess-9" ]]; then
  ok "bash failure: record carries class and context"
else
  ng "bash failure: record carries class and context" "rec=$rec"
fi
state=$(jq -r '.state' "$WORK/body")
if [[ $state == *"tool: Bash"* && $state == *"input: echo x > /tmp/foo"* && $state == *"error: Command failed"* && $state == *"operation not permitted"* ]]; then
  ok "bash failure: state includes tool/input/error/output"
else
  ng "bash failure: state includes tool/input/error/output" "state=$state"
fi
if jq -e '(.questions.kind.criteria | keys | length) == 8 and (.questions.kind.criteria | has("sandbox_denied") and has("other"))' "$WORK/body" >/dev/null; then
  ok "bash failure: 8-label question"
else
  ng "bash failure: 8-label question" "body=$(cat "$WORK/body")"
fi

# 2. Jev 使用不可 → class なしで記録
run_hook "$payload"
rec=$(last_record)
if [[ $(echo "$rec" | jq 'has("class")') == "false" && ! -f "$WORK/body" ]]; then
  ok "no jev: recorded without class"
else
  ng "no jev: recorded without class" "rec=$rec"
fi

# 3. tool_response がオブジェクトでも落ちない（Edit 失敗）
payload=$(jq -n --arg cwd "$WORK/proj" '{session_id:"s", cwd:$cwd, tool_name:"Edit", tool_input:{file_path:"/x/y.ts", old_string:"a", new_string:"b"}, error:"old_string not found", tool_response:{ok:false, reason:"old_string not found"}}')
run_hook "$payload" AI_GATEWAY_API_KEY=vck_test_key
rec=$(last_record)
if [[ $(echo "$rec" | jq -r '.tool') == "Edit" && $(echo "$rec" | jq -r '.detail') == "/x/y.ts" ]] &&
  [[ $(jq -r '.state' "$WORK/body") == *'"reason":"old_string not found"'* ]]; then
  ok "edit failure: object tool_response handled"
else
  ng "edit failure: object tool_response handled" "rec=$rec"
fi

# 4. error も tool_response も空なら記録しない
before=$(wc -l <"$TOOL_FAILURES_LOG")
run_hook '{"tool_name":"Bash","tool_input":{"command":"true"}}' AI_GATEWAY_API_KEY=vck_test_key
after=$(wc -l <"$TOOL_FAILURES_LOG")
if [[ $before -eq $after && ! -f "$WORK/body" ]]; then
  ok "empty failure: nothing recorded"
else
  ng "empty failure: nothing recorded" "before=$before after=$after"
fi

# 5. redaction
payload=$(jq -n '{tool_name:"Bash", tool_input:{command:"curl -H \"Authorization: Bearer ghp_abcdefghijklmnopq\" https://x"}, error:"401", tool_response:"TOKEN=supersecret1 rejected"}')
run_hook "$payload" AI_GATEWAY_API_KEY=vck_test_key
state=$(jq -r '.state' "$WORK/body")
if [[ $state != *ghp_abcdefghijklmnopq* && $state != *supersecret1* && $state == *"<redacted>"* ]]; then
  ok "redaction: secrets not sent to jev"
else
  ng "redaction: secrets not sent to jev" "state=$state"
fi

# 6. 長い出力は切り詰められて送られる（state 上限より前に output 6000 バイトで切る）
long=$(head -c 20000 /dev/zero | tr '\0' 'e')
payload=$(jq -n --arg r "$long" '{tool_name:"Bash", tool_input:{command:"npm test"}, error:"exit 1", tool_response:$r}')
run_hook "$payload" AI_GATEWAY_API_KEY=vck_test_key
len=$(jq -r '.state | length' "$WORK/body")
if [[ $len -lt 6200 ]]; then
  ok "long output truncated (state len=$len)"
else
  ng "long output truncated" "len=$len"
fi

echo ""
echo "Passed: $PASS, Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
