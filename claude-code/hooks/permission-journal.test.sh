#!/usr/bin/env bash
# Test suite for permission-journal.sh
#
# Usage: bash permission-journal.test.sh
#
# ネットワークには出ない。PATH 先頭の偽 curl で Jev 応答を差し替え、
# JSONL への記録内容（class 付与・redaction・fail-open）を検証する。
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/permission-journal.sh"

if [[ ! -f ${HOOK} ]]; then
  echo "FAIL: hook not found: ${HOOK}" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/permission-journal-test.XXXXXX")
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
echo '{"model":"typesafe-ai/jev","answers":{"kind":{"type":"choice","choice":"read_only","probabilities":{"read_only":0.91,"mutating_local":0.05,"git_mutation":0.02,"network":0.01,"destructive":0.01}}},"usage":{"input_tokens":120,"output_tokens":0}}'
EOF
chmod +x "$WORK/bin/curl"

export FAKE_CURL_DIR="$WORK"
export PATH="$WORK/bin:$PATH"
# 実機の jev-broker ソケットを拾わない（鍵なしで Jev を呼ばないことを検証するケースがある）
export JEV_BROKER_SOCKET="$WORK/no-broker.sock"
export JEV_KEYCHAIN_SERVICE="permission-journal-test-nonexistent-service"
export PERMISSION_JOURNAL_FILE="$WORK/log.jsonl"

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

# run_hook <tool> <tool_input JSON> [env assignments...]
run_hook() {
  local tool="$1" tool_input="$2"
  shift 2
  rm -f "$WORK/body"
  jq -n --arg tool "$tool" --argjson ti "$tool_input" '{session_id:"sess-1", tool_name:$tool, tool_input:$ti}' |
    (cd "$WORK/proj" && env "$@" bash "$HOOK")
}

last_record() {
  tail -n 1 "$PERMISSION_JOURNAL_FILE"
}

echo "=== permission-journal.sh ==="

# 1. Bash + Jev 応答あり → class / class_p が付く
run_hook Bash '{"command":"cd /x; grep -n foo bar.txt; echo \"=== done ===\""}' AI_GATEWAY_API_KEY=vck_test_key
rec=$(last_record)
if [[ $(echo "$rec" | jq -r '.tool') == "Bash" ]] &&
  [[ $(echo "$rec" | jq -r '.class') == "read_only" ]] &&
  [[ $(echo "$rec" | jq -r '.class_p') == "0.91" ]] &&
  [[ $(echo "$rec" | jq -r '.detail') == 'cd /x; grep -n foo bar.txt; echo "=== done ==="' ]] &&
  [[ $(echo "$rec" | jq -r '.project') == "proj" ]] &&
  [[ $(echo "$rec" | jq -r '.session') == "sess-1" ]]; then
  ok "bash: record carries class/class_p and legacy fields"
else
  ng "bash: record carries class/class_p and legacy fields" "rec=$rec"
fi
if jq -e '.questions.kind.type == "choice" and (.questions.kind.criteria | keys) == ["destructive","git_mutation","mutating_local","network","read_only"]' "$WORK/body" >/dev/null; then
  ok "bash: jev asked with the 5-label choice question"
else
  ng "bash: jev asked with the 5-label choice question" "body=$(cat "$WORK/body")"
fi

# 2. Bash + Jev 使用不可（鍵なし）→ class なしで記録される（fail-open）
run_hook Bash '{"command":"git status"}'
rec=$(last_record)
if [[ $(echo "$rec" | jq -r '.tool') == "Bash" ]] &&
  [[ $(echo "$rec" | jq 'has("class")') == "false" ]] &&
  [[ $(echo "$rec" | jq 'has("class_p")') == "false" ]] &&
  [[ ! -f "$WORK/body" ]]; then
  ok "bash without jev: recorded without class"
else
  ng "bash without jev: recorded without class" "rec=$rec"
fi

# 3. JEV_DISABLE=1 → 同上
run_hook Bash '{"command":"git status"}' AI_GATEWAY_API_KEY=vck_test_key JEV_DISABLE=1
rec=$(last_record)
if [[ $(echo "$rec" | jq 'has("class")') == "false" && ! -f "$WORK/body" ]]; then
  ok "JEV_DISABLE: recorded without class, no call"
else
  ng "JEV_DISABLE: recorded without class, no call" "rec=$rec"
fi

# 4. 非 Bash ツールは Jev を呼ばない
run_hook Read '{"file_path":"/etc/hosts"}' AI_GATEWAY_API_KEY=vck_test_key
rec=$(last_record)
if [[ $(echo "$rec" | jq -r '.detail') == "/etc/hosts" ]] &&
  [[ $(echo "$rec" | jq 'has("class")') == "false" ]] &&
  [[ ! -f "$WORK/body" ]]; then
  ok "non-bash: no jev call"
else
  ng "non-bash: no jev call" "rec=$rec"
fi

# 5. 送信前 redaction: 秘密値は Jev に渡らず、記録の detail は従来通り生のまま
run_hook Bash '{"command":"TOKEN=supersecret1 curl -H \"Authorization: Bearer vck_abcdefghijklmnop\" --password hunter2 https://x"}' AI_GATEWAY_API_KEY=vck_test_key
state=$(jq -r '.state' "$WORK/body")
rec=$(last_record)
if [[ $state != *supersecret1* && $state != *vck_abcdefghijklmnop* && $state != *hunter2* && $state == *"<redacted>"* ]]; then
  ok "redaction: secrets not sent to jev"
else
  ng "redaction: secrets not sent to jev" "state=$state"
fi
if [[ $(echo "$rec" | jq -r '.detail') == *supersecret1* ]]; then
  ok "redaction: log detail unchanged (legacy behaviour)"
else
  ng "redaction: log detail unchanged (legacy behaviour)" "rec=$rec"
fi

# 6. 空コマンドは Jev を呼ばない
run_hook Bash '{"command":""}' AI_GATEWAY_API_KEY=vck_test_key
if [[ ! -f "$WORK/body" ]]; then
  ok "empty command: no jev call"
else
  ng "empty command: no jev call" "body=$(cat "$WORK/body")"
fi

echo ""
echo "Passed: $PASS, Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
