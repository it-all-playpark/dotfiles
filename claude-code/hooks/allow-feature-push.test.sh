#!/usr/bin/env bash
# Test suite for allow-feature-push.sh
#
# Usage: bash allow-feature-push.test.sh
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/allow-feature-push.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=()

# --------------------------------------------------------------------------
# Fixtures: isolated repos with a fixed current branch, for fallback tests
# (no explicit refspec → hook must fall back to current branch)
# --------------------------------------------------------------------------

TMP_MAIN_REPO=$(mktemp -d "${TMPDIR:-/tmp}/allow-feature-push-test-main.XXXXXX")
TMP_FEATURE_REPO=$(mktemp -d "${TMPDIR:-/tmp}/allow-feature-push-test-feature.XXXXXX")
TMP_NOGIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/allow-feature-push-test-nogit.XXXXXX")

cleanup() {
  rm -rf "$TMP_MAIN_REPO" "$TMP_FEATURE_REPO" "$TMP_NOGIT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

init_repo() {
  local dir="$1" branch="$2"
  git -C "$dir" init -q -b "$branch"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" commit -q --allow-empty -m init
}

init_repo "$TMP_MAIN_REPO" "main"
init_repo "$TMP_FEATURE_REPO" "feature/x"

# run_case <name> <command> <expected: deny|ask|allow|noop> [workdir]
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"
  local workdir="${4:-$SCRIPT_DIR}"

  local input
  input=$(jq -n --arg cmd "$cmd" '{tool_name:"Bash", tool_input:{command:$cmd}}')

  local output
  output=$(cd "$workdir" && echo "$input" | bash "$HOOK" 2>&1 || true)

  local decision="noop"
  if [[ -n $output ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "noop"' 2>/dev/null || echo "noop")
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

echo "=== allow-feature-push tests ==="

echo "[Explicit refspec destination — protected → deny]"
run_case "origin main" 'git push origin main' "deny"
run_case "origin master" 'git push origin master' "deny"
run_case "origin dev" 'git push origin dev' "deny"
run_case "origin develop" 'git push origin develop' "deny"
run_case "origin development" 'git push origin development' "deny"
run_case "origin production" 'git push origin production' "deny"
run_case "origin staging" 'git push origin staging' "deny"
run_case "origin release" 'git push origin release' "deny"
run_case "origin nightly" 'git push origin nightly' "deny"
run_case "HEAD:refs/heads/production" 'git push origin HEAD:refs/heads/production' "deny"
run_case "HEAD:refs/heads/main" 'git push origin HEAD:refs/heads/main' "deny"
run_case "force push +main:main" 'git push origin +main:main' "deny"
run_case "with flags -u origin main" 'git push -u origin main' "deny"
run_case "with --force-with-lease origin main" 'git push --force-with-lease origin main' "deny"

echo "[Explicit refspec destination — feature/etc → allow]"
run_case "origin feature/x" 'git push origin feature/x' "allow"
run_case "HEAD:refs/heads/feature/foo" 'git push origin HEAD:refs/heads/feature/foo' "allow"
run_case "origin fix/bug-123" 'git push origin fix/bug-123' "allow"
run_case "with -u origin feature/x" 'git push -u origin feature/x' "allow"

echo "[Multiple refspecs — protected among them → deny]"
run_case "origin feature/x main (second refspec protected)" 'git push origin feature/x main' "deny"
run_case "origin main feature/x (first refspec protected)" 'git push origin main feature/x' "deny"
run_case "origin feat:feat dev:dev (colon refspecs, second protected)" 'git push origin feat:feat dev:dev' "deny"
run_case "origin feature/x fix/y (all non-protected)" 'git push origin feature/x fix/y' "allow"

echo "[--all / --mirror — destination unenumerable → ask]"
run_case "--all origin" 'git push --all origin' "ask"
run_case "--mirror origin" 'git push --mirror origin' "ask"
run_case "origin --all" 'git push origin --all' "ask"

echo "[Fallback to current branch when destination not specified]"
run_case "bare git push on main repo" 'git push' "deny" "$TMP_MAIN_REPO"
run_case "git push origin (remote only) on main repo" 'git push origin' "deny" "$TMP_MAIN_REPO"
run_case "bare git push on feature repo" 'git push' "allow" "$TMP_FEATURE_REPO"

echo "[Undetectable destination → ask]"
run_case "bare git push outside git repo" 'git push' "ask" "$TMP_NOGIT_DIR"

echo "[Whitespace-normalized matching — protected → deny]"
run_case "double space between git and push" 'git  push origin main' "deny"
run_case "double space plus explicit feature refspec" 'git  push origin feature/x' "allow"
run_case "tab between git and push" "$(printf 'git\tpush origin main')" "deny"

echo "[Bare symbolic ref refspec (HEAD/@) — resolved to current branch]"
run_case "origin HEAD on main repo (resolves to main)" 'git push origin HEAD' "deny" "$TMP_MAIN_REPO"
run_case "origin HEAD on feature repo (resolves to feature/x)" 'git push origin HEAD' "allow" "$TMP_FEATURE_REPO"
run_case "origin @ on main repo (resolves to main)" 'git push origin @' "deny" "$TMP_MAIN_REPO"
run_case "origin @ on feature repo (resolves to feature/x)" 'git push origin @' "allow" "$TMP_FEATURE_REPO"
run_case "force push +HEAD on main repo (resolves to main)" 'git push origin +HEAD' "deny" "$TMP_MAIN_REPO"

echo "[Non-push commands → no hook output]"
run_case "git status" 'git status' "noop"
run_case "git push-something (not a real push)" 'echo not-a-push' "noop"

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
