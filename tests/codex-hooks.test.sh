#!/usr/bin/env bash
# Smoke tests for Codex hook wrappers managed by dotfiles.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_DIR="$REPO_ROOT/codex/hooks"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-hooks-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
ERRORS=()

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1: $2")
}

run_test() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name" "command failed: $*"
  fi
}

echo "=== Codex hook wrapper tests ==="

for hook in \
  pretool-bash-credential-guard.sh \
  posttool-secret-mask.sh \
  permission-journal.sh \
  pre-compact-dump.sh \
  session-start-replay.sh \
  stop-unfinished-guard.sh \
  memory-monitor.py; do
  if [[ -x "$HOOK_DIR/$hook" ]]; then
    pass "$hook is executable"
  else
    fail "$hook is executable" "missing or not executable: $HOOK_DIR/$hook"
  fi
done

run_test "shell syntax" bash -n \
  "$HOOK_DIR/pretool-bash-credential-guard.sh" \
  "$HOOK_DIR/posttool-secret-mask.sh" \
  "$HOOK_DIR/permission-journal.sh" \
  "$HOOK_DIR/pre-compact-dump.sh" \
  "$HOOK_DIR/session-start-replay.sh" \
  "$HOOK_DIR/stop-unfinished-guard.sh"

if rg -q 'claude-code|\.claude|CLAUDE_' "$HOOK_DIR"; then
  fail "Codex hooks do not reference Claude runtime paths" "unexpected Claude reference under $HOOK_DIR"
else
  pass "Codex hooks do not reference Claude runtime paths"
fi

pretool_out="$(
  jq -n '{tool_name:"Bash", tool_input:{command:"echo $PROD_DATABASE_URL"}}' |
    "$HOOK_DIR/pretool-bash-credential-guard.sh"
)"
if [[ $(printf '%s' "$pretool_out" | jq -r '.hookSpecificOutput.permissionDecision // empty') == "ask" ]]; then
  pass "pretool credential guard detects prod env"
else
  fail "pretool credential guard detects prod env" "unexpected output: $pretool_out"
fi

set +e
aws_no_profile_out="$(
  jq -n '{tool_name:"Bash", tool_input:{command:"aws s3 ls"}}' |
    "$HOOK_DIR/pretool-bash-credential-guard.sh"
)"
aws_no_profile_rc=$?
set -e
if [[ $aws_no_profile_rc -eq 0 ]] &&
  [[ -z "$(printf '%s' "$aws_no_profile_out" | jq -r '.hookSpecificOutput.permissionDecision // empty')" ]]; then
  pass "pretool credential guard passes aws command without --profile"
else
  fail "pretool credential guard passes aws command without --profile" \
    "rc=$aws_no_profile_rc output=$aws_no_profile_out"
fi

set +e
benign_out="$(
  jq -n '{tool_name:"Bash", tool_input:{command:"ls -la"}}' |
    "$HOOK_DIR/pretool-bash-credential-guard.sh"
)"
benign_rc=$?
set -e
if [[ $benign_rc -eq 0 ]] &&
  [[ -z "$(printf '%s' "$benign_out" | jq -r '.hookSpecificOutput.permissionDecision // empty')" ]]; then
  pass "pretool credential guard passes benign command"
else
  fail "pretool credential guard passes benign command" "rc=$benign_rc output=$benign_out"
fi

posttool_out="$(
  jq -n --arg stdout 'TOKEN=ghp_1234567890123456789012345678901234567890' \
    '{tool_name:"Bash", tool_response:{stdout:$stdout, stderr:""}}' |
    "$HOOK_DIR/posttool-secret-mask.sh"
)"
if printf '%s' "$posttool_out" | jq -e '.hookSpecificOutput.updatedToolOutput.stdout | contains("[REDACTED:GITHUB_TOKEN]")' >/dev/null; then
  pass "posttool secret mask redacts token"
else
  fail "posttool secret mask redacts token" "unexpected output: $posttool_out"
fi

CODEX_HOME="$TMPROOT/codex" "$HOOK_DIR/permission-journal.sh" <<'JSON'
{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"git status"}}
JSON
if [[ -s "$TMPROOT/codex/log/permission-requests.jsonl" ]]; then
  pass "permission journal writes under CODEX_HOME"
else
  fail "permission journal writes under CODEX_HOME" "missing log"
fi

printf '{}' | "$HOOK_DIR/memory-monitor.py"
pass "memory monitor no-op exits cleanly"

for hook in pre-compact-dump.sh session-start-replay.sh stop-unfinished-guard.sh; do
  printf '{}' | "$HOOK_DIR/$hook"
  pass "$hook no-op exits cleanly"
done

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
