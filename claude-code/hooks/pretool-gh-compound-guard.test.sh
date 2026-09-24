#!/usr/bin/env bash
# Test suite for pretool-gh-compound-guard.py
#
# Usage: bash pretool-gh-compound-guard.test.sh
#
# pass ケースは 2026-09-24 に harness が sandbox 外で実行すると実測した形、
# deny ケースは sandbox 内に戻されて gh が落ちると実測した形 / tool-failures.jsonl
# に実際に出ていた形。
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pretool-gh-compound-guard.py"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gh-compound-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/settings.json" <<'EOF'
{"sandbox":{"enabled":true,"excludedCommands":[
  "gh","gh *","git","git *","journal","journal *","codex:*",
  "bash $HOME/ghq/github.com/it-all-playpark/skills/*"
]}}
EOF
echo '{"sandbox":{"enabled":false,"excludedCommands":["gh"]}}' >"$WORK/disabled.json"

PASS=0
FAIL=0
FAILURES=()

# run_case <name> <command> <expected: deny|pass> [settings]
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"
  local settings="${4:-$WORK/settings.json}"

  local input
  input=$(jq -n --arg cmd "$cmd" '{tool_name:"Bash", tool_input:{command:$cmd}}')

  local output
  output=$(echo "$input" | GH_COMPOUND_GUARD_SETTINGS="$settings" python3 "$HOOK" 2>&1 || true)

  local decision="pass"
  if [[ -n $output ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null || echo "invalid")
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

echo "=== pretool-gh-compound-guard tests ==="

echo "[deny — harness が sandbox 内に戻す形]"
run_case "pipe to head" 'gh auth status 2>&1 | head -3' "deny"
run_case "or true" 'gh api user --jq .login || true' "deny"
run_case "cd prefix" 'cd /x/wt && gh pr create --title "t" --body-file b.md' "deny"
run_case "env prefix" 'GH_PAGER=cat gh api user --jq .login' "deny"
run_case "file redirect" 'gh api user --jq .login > "$TMPDIR/x"' "deny"
run_case "stderr to devnull" 'gh api user 2>/dev/null' "deny"
run_case "append redirect" 'gh pr view 1 --json body >> out.md' "deny"
run_case "redirect then wc" 'gh pr view 1477 --json body -q .body > "$TMPDIR/b.md" && wc -l "$TMPDIR/b.md"' "deny"
run_case "for loop" 'for pr in 645 681; do gh api repos/o/r/pulls/$pr/commits; done' "deny"
run_case "heredoc then gh" "cat > \"\$TMPDIR/b.md\" <<'EOF'
## 結論
it's done
EOF
gh pr create --body-file \"\$TMPDIR/b.md\"" "deny"
run_case "command substitution arg" 'gh pr create --title t --body "$(cat b.md)"' "deny"
run_case "gh inside substitution" 'echo "$(gh pr view 1 --json url -q .url)"' "deny"
run_case "subshell" '(gh pr list)' "deny"
run_case "pipe-and" 'gh api x |& cat' "deny"
run_case "git push piped" 'git -C /x/wt push -u origin feat 2>&1 | tail -5' "deny"
run_case "cd then git push" 'cd /x/wt && git push' "deny"
run_case "git fetch or true" 'git fetch origin || true' "deny"
run_case "gh via absolute path piped" '/Users/u/.claude/bin/gh pr list | head' "deny"
run_case "newline then non-excluded" 'gh pr list
echo done' "deny"
run_case "git -C push alone" 'git -C /x/wt push -u origin feat' "deny"
run_case "git -C fetch alone" 'git -C /x/wt fetch origin --prune --quiet' "deny"
run_case "git -c push" 'git -c core.quotepath=false push' "deny"
run_case "git --work-tree= push" 'git --work-tree=/x/wt push' "deny"
run_case "git --git-dir push" 'git --git-dir /x/.git push' "deny"
run_case "gh and git -C local op" 'gh api user --jq .login && git -C /x/wt log --oneline -1' "deny"

echo "[pass — harness が sandbox 外で実行する形]"
run_case "plain gh" 'gh auth status' "pass"
run_case "gh with jq filter" "gh api user --jq '.login | ascii_upcase'" "pass"
run_case "gh and git chained" 'gh auth status 2>&1 && git --version' "pass"
run_case "gh semicolon git" 'gh api user --jq .login; git --version' "pass"
run_case "gh piped to gh" 'gh api user 2>&1 | gh api user --jq .id' "pass"
run_case "newline separated" 'gh pr list
git status' "pass"
run_case "semicolon newline" 'gh pr list;
git status' "pass"
run_case "excluded skill command" 'gh pr view 1 && journal log --x' "pass"
run_case "legacy prefix pattern" 'gh pr view 1 && codex exec hi' "pass"
run_case "HOME expanded pattern" "gh pr view 1 && bash $HOME/ghq/github.com/it-all-playpark/skills/a/b.sh" "pass"
run_case "quoted redirect chars" "gh api x --jq '.[] | select(.n > 1)'" "pass"
run_case "git --no-pager push" 'git --no-pager push -u origin feat' "pass"
run_case "gh -R flag" 'gh -R o/r pr view 1 --json state --jq .state' "pass"

echo "[pass — 対象外]"
run_case "no gh/git" 'ls -la | head' "pass"
run_case "git local op piped" 'git log --oneline -3 | cat' "pass"
run_case "git diff redirect" 'git diff > "$TMPDIR/d.patch"' "pass"
run_case "cd then git status" 'cd /x && git status' "pass"
run_case "git -C local op piped" 'git -C /x/wt log --oneline -3 | cat' "pass"
run_case "gh as a word in args" 'echo gh | cat' "pass"
run_case "grep for gh" 'grep -rn "gh pr" . | head' "pass"
run_case "sandbox disabled" 'gh pr list | head' "pass" "$WORK/disabled.json"

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if ((FAIL > 0)); then
  printf '%s\n' "${FAILURES[@]}" >&2
  exit 1
fi
