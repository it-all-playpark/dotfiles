#!/usr/bin/env bash
# Test suite for pretool-live-skills-git-guard.py
#
# Usage: bash pretool-live-skills-git-guard.test.sh
#
# 一時 dir を live checkout に見立て（LIVE_SKILLS_GUARD_ROOT）、payload の cwd と
# コマンドの組み合わせで deny / pass を確かめる。
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pretool-live-skills-git-guard.py"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/live-skills-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

LIVE="$WORK/skills"
DEV="$WORK/skills-dev"
mkdir -p "$LIVE/plugins/dev-flow" "$LIVE/.claude/worktrees/df-1" "$DEV"
# ~/.claude/skills と同じく symlink 経由で渡しても実体で判定する
ln -s "$LIVE" "$WORK/claude-skills-link"

PASS=0
FAIL=0
FAILURES=()

# run_case <name> <cwd> <command> <expected: deny|pass>
run_case() {
  local name="$1" cwd="$2" cmd="$3" expected="$4"

  local input
  input=$(jq -n --arg cmd "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$cmd}}')

  local output
  output=$(echo "$input" | LIVE_SKILLS_GUARD_ROOT="$WORK/claude-skills-link" python3 "$HOOK" 2>&1 || true)

  local decision="pass"
  if [[ -n $output ]] &&
    [[ "$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" == "deny" ]]; then
    decision="deny"
  fi

  if [[ $decision == "$expected" ]]; then
    printf "  \033[32mPASS\033[0m %s\n" "$name"
    PASS=$((PASS + 1))
  else
    printf "  \033[31mFAIL\033[0m %s (expected %s, got %s)\n" "$name" "$expected" "$decision"
    [[ -n $output ]] && echo "       output: $output"
    FAIL=$((FAIL + 1))
    FAILURES+=("$name")
  fi
}

echo "== live checkout で書き換え系の素の git は deny"
for sub in "checkout feature/x" "switch main" "reset --hard origin/main" "restore ." \
  "pull" "merge origin/main" "rebase origin/main" "stash" "clean -fdx" \
  "commit -m x" "apply x.patch" "cherry-pick abc" "rm -r plugins"; do
  run_case "git $sub" "$LIVE" "git $sub" deny
done
run_case "サブディレクトリの cwd でも deny" "$LIVE/plugins/dev-flow" "git checkout -- ." deny
run_case "グローバルオプション付き（--no-pager）でも deny" "$LIVE" "git --no-pager checkout x" deny
run_case "連結の後ろにあっても deny" "$LIVE" "git fetch origin && git reset --hard origin/main" deny
run_case "環境変数の前置があっても deny" "$LIVE" "GIT_TRACE=1 git checkout x" deny
run_case "heredoc でパースできなくても字面で deny" "$LIVE" $'git commit -F - <<EOF\nmsg\nEOF' deny
run_case "cwd を symlink で渡しても deny" "$WORK/claude-skills-link" "git pull" deny

echo "== live checkout でも読むだけの git は pass"
for sub in "status" "log --oneline -5" "diff" "fetch origin main" "branch -a" \
  "show HEAD" "rev-parse HEAD" "worktree list" "ls-files"; do
  run_case "git $sub" "$LIVE" "git $sub" pass
done

echo "== 対象外"
run_case "skills-dev（通常 clone）の書き換えは pass" "$DEV" "git reset --hard origin/main" pass
run_case "live 配下の .claude/worktrees は別 worktree なので pass" "$LIVE/.claude/worktrees/df-1" "git commit -m x" pass
run_case "-C 付きは sandbox 内で走り保護で落ちるので止めない" "$DEV" "git -C $LIVE checkout x" pass
run_case "git 以外は pass" "$LIVE" "rg checkout plugins" pass
run_case "引数の中の git 文字列は pass" "$LIVE" "echo 'git checkout x'" pass

echo "== 例外時は fail-open"
out=$(echo 'not json' | python3 "$HOOK" 2>&1 || true)
if [[ -z $out ]]; then
  printf "  \033[32mPASS\033[0m 壊れた入力で何も出さない\n"
  PASS=$((PASS + 1))
else
  printf "  \033[31mFAIL\033[0m 壊れた入力で出力した: %s\n" "$out"
  FAIL=$((FAIL + 1))
  FAILURES+=("fail-open")
fi

echo
echo "PASS: $PASS  FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
