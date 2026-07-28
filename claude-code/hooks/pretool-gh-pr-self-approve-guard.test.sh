#!/usr/bin/env bash
# Test suite for pretool-gh-pr-self-approve-guard.sh
#
# Usage: bash pretool-gh-pr-self-approve-guard.test.sh
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pretool-gh-pr-self-approve-guard.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=()

# run_case <name> <command> <expected: deny|pass>
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

echo "=== pretool-gh-pr-self-approve-guard tests ==="

# --- Positive cases: should trigger "deny" ---
echo "[Positive cases — should deny]"
run_case "pr review --approve trailing" 'gh pr review 137 --approve' "deny"
run_case "pr review --approve leading" 'gh pr review --approve 137' "deny"
run_case "pr review -a trailing" 'gh pr review 137 -a' "deny"
run_case "pr review -a only" 'gh pr review -a' "deny"
run_case "pr review with -R global flag" 'gh -R it-all-playpark/dotfiles pr review 137 --approve' "deny"
run_case "pr review --approve with --body" 'gh pr review 137 --approve --body "LGTM"' "deny"
run_case "compound command with &&" 'git fetch && gh pr review 137 --approve' "deny"
run_case "pr review --approve=true (cobra = form)" 'gh pr review 137 --approve=true' "deny"
run_case "pr review -a=true (cobra = form)" 'gh pr review 137 -a=true' "deny"
run_case "pr review --approve=false (fail-closed)" 'gh pr review 137 --approve=false' "deny"
run_case "pr review --approve then ; compound (no space)" 'gh pr review 137 --approve; echo done' "deny"
run_case "pr review -a then ; compound (no space)" 'gh pr review -a; echo done' "deny"
run_case "pr review --approve then && compound" 'gh pr review 137 --approve&&echo done' "deny"
run_case "pr review --approve then | pipe" 'gh pr review 137 --approve|cat' "deny"

# --- Negative cases: should NOT trigger (pass through) ---
echo "[Negative cases — should pass through]"
run_case "pr review --comment with body" 'gh pr review 137 --comment --body "looks good"' "pass"
run_case "pr review --request-changes with body" 'gh pr review 137 --request-changes --body "fix"' "pass"
run_case "pr review --comment only" 'gh pr review 137 --comment' "pass"
run_case "pr view (not review)" 'gh pr view 137' "pass"
run_case "pr merge (not review)" 'gh pr merge 137' "pass"
run_case "git commit -a (unrelated -a)" 'git commit -a -m msg' "pass"
run_case "ls -a (unrelated -a)" 'ls -a' "pass"
run_case "echo gh pr review (no approve token)" 'echo gh pr review' "pass"

# --- Word-boundary guard cases (documented) ---
echo "[Word-boundary guard — should pass through]"
run_case "--approver should not match --approve" 'gh pr review 137 --approver someone' "pass"
run_case "-abc should not match -a" 'gh pr review 137 -abc' "pass"

# --- Fail-closed documented behavior: quoted --approve in --body ---
echo "[Fail-closed — quoted --approve inside --body deny by design]"
run_case "--body contains literal --approve text" 'gh pr review 137 --comment --body "please --approve later"' "deny"

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
