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

# run_case <name> <command> <expected: ask|pass>
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"

  local input
  input=$(jq -n --arg cmd "$cmd" '{tool_name:"Bash", tool_input:{command:$cmd}}')

  local output
  output=$(echo "$input" | bash "$HOOK" 2>&1 || true)

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
