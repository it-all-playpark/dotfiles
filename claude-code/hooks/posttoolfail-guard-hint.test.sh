#!/usr/bin/env bash
# Test suite for posttoolfail-guard-hint.sh
#
# Usage: bash posttoolfail-guard-hint.test.sh
#
# Exit 0 on all pass, non-zero otherwise.
#
# shellcheck disable=SC2016
# 単一引用符内の `$(…)` / `$VAR` は意図的なリテラル（hook に生文字列として渡す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/posttoolfail-guard-hint.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=()

WT=/Users/u/ghq/github.com/o/r/.claude/worktrees/df-1
PREFIX="This session is isolated in the worktree ${WT}, but this command"
SUFFIX=" Refusing to run it — a worktree-isolated session's git operations must target its own worktree. Split it into plain, separate commands and run them from ${WT}."

# run_hook <tool> <error>
run_hook() {
  jq -n --arg tool "$1" --arg err "$2" '{tool_name:$tool, tool_input:{command:"x"}, error:$err}' | bash "$HOOK"
}

record() {
  if [[ $1 == ok ]]; then
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s\n" "$2"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$2: $3")
    printf "  \033[31mFAIL\033[0m %s\n" "$2"
  fi
}

# run_hint_case <name> <error> <substring expected in additionalContext>
run_hint_case() {
  local ctx
  ctx=$(run_hook Bash "$2" | jq -r '.hookSpecificOutput.additionalContext // ""')
  if [[ $ctx == *"$3"* ]]; then
    record ok "$1"
  else
    record ng "$1" "context does not contain '$3' (got: $ctx)"
  fi
}

# run_silent_case <name> <tool> <error>
run_silent_case() {
  local out
  out=$(run_hook "$2" "$3")
  if [[ -z $out ]]; then
    record ok "$1"
  else
    record ng "$1" "expected no output (got: $out)"
  fi
}

echo "posttoolfail-guard-hint.sh"

# 拒否理由ごと（文面は 2026-10 の実際の拒否メッセージから）
run_hint_case "git -C to shared checkout" \
  "${PREFIX} redirects git to the shared checkout via -C.${SUFFIX}" '`git -C <path>`'
run_hint_case "git -C with glob pathspec" \
  "${PREFIX} redirects git through a glob pattern that expands at runtime.${SUFFIX}" '-C なしなら通る'
run_hint_case "git in a complex form" \
  "${PREFIX} names git in a form too complex to verify that it stays inside the worktree.${SUFFIX}" '固定パス（例 `/tmp/claude/x`）'
run_hint_case "git named more than once" \
  "${PREFIX} names git more than once in a single command, which cannot be verified to stay inside the worktree.${SUFFIX}" 'rg -f /tmp/claude/pat'
run_hint_case "cd to computed location" \
  "${PREFIX} changes directory to a location computed at runtime before running git.${SUFFIX}" '相対パスの固定値だけ'
run_hint_case "bash inside a construct" \
  "${PREFIX} runs bash inside a construct too complex to verify; what it reads or is handed as shell text cannot be shown not to run git.${SUFFIX}" '`./script.sh` で直接実行'
run_hint_case "value where an option may stand" \
  "${PREFIX} runs sed with a value computed at runtime (the variable TMPDIR) where an option may stand (a value that is not double-quoted, or whose first character is matched or computed rather than spelled out, may begin with -; put -- before it) in a plain command, so what it runs cannot be shown not to be git.${SUFFIX}" 'sed には'
run_hint_case "string through eval" \
  "${PREFIX} runs a string through eval, which can't be verified to stay inside the worktree.${SUFFIX}" 'Write ツールでファイルに書き'

# 該当する直し方が複数あればすべて出す
ctx=$(run_hook Bash "${PREFIX} names git in a form too complex; also runs bash inside a construct too complex to verify.${SUFFIX}" | jq -r '.hookSpecificOutput.additionalContext')
if [[ $ctx == *'固定パス（例 `/tmp/claude/x`）'* && $ctx == *'`./script.sh` で直接実行'* ]]; then
  record ok "multiple reasons give multiple hints"
else
  record ng "multiple reasons give multiple hints" "got: $ctx"
fi

run_hint_case "event name" \
  "${PREFIX} names git more than once in a single command.${SUFFIX}" '通る書き方'
out=$(run_hook Bash "${PREFIX} names git more than once in a single command.${SUFFIX}" | jq -r '.hookSpecificOutput.hookEventName')
if [[ $out == PostToolUseFailure ]]; then record ok "hookEventName"; else record ng "hookEventName" "got: $out"; fi

# 何も足さない
run_silent_case "unknown guard reason" Bash "${PREFIX} runs log with the text eventMessage inside a construct.${SUFFIX}"
run_silent_case "not a guard failure" Bash "Exit code 1
fatal: not a git repository"
run_silent_case "non-Bash tool" Read "${PREFIX} names git more than once in a single command.${SUFFIX}"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
  printf '%s\n' "${FAILURES[@]}" >&2
  exit 1
fi
