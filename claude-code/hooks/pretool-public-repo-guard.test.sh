#!/usr/bin/env bash
# Test suite for pretool-public-repo-guard.sh
#
# Usage: bash pretool-public-repo-guard.test.sh
#
# 一時ディレクトリに bare remote と clone を作り、push 済み / 未 push の commit を用意して hook に
# PreToolUse の入力（command と cwd）を渡す。denylist は PUBLIC_GUARD_DENYLIST で差し替える。
# 秘密っぽい文字列は実行時に組み立てる（このファイル自体が検査に掛からないように）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pretool-public-repo-guard.sh"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/public-guard-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

DENYLIST="$TMPROOT/denylist"
printf '# client names\nacme-secret-corp\n' >"$DENYLIST"
export PUBLIC_GUARD_DENYLIST="$DENYLIST"

PHONE="090-$((1000 + 2345))-6789"
GH_TOKEN_LIKE="ghp_$(printf 'a%.0s' {1..36})"

# new_repo <name> <marker: 1|0>: remote に push 済みの初期 commit を持つ clone を作り、パスを出す
new_repo() {
  local dir="$TMPROOT/$1"
  git init -q --bare "$dir.git"
  git clone -q "$dir.git" "$dir" 2>/dev/null
  if [[ $2 -eq 1 ]]; then touch "$dir/.public-repo"; fi
  echo base >"$dir/README"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  git -C "$dir" push -q origin HEAD 2>/dev/null
  echo "$dir"
}

# commit_file <repo> <content> [message]
commit_file() {
  echo "$2" >>"$1/file.txt"
  git -C "$1" add file.txt
  git -C "$1" commit -q -m "${3:-change}"
}

# run_case <name> <cwd> <command> <expected: ask|pass>
run_case() {
  local name="$1" cwd="$2" cmd="$3" expected="$4" input output decision="pass"
  input=$(jq -n --arg cmd "$cmd" --arg cwd "$cwd" '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd}')
  output=$(bash "$HOOK" <<<"$input" 2>&1 || true)
  if [[ -n $output ]]; then
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // "pass"' <<<"$output" 2>/dev/null || echo "invalid")
  fi
  if [[ $decision == "$expected" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected=$expected got=$decision output=$output")
    echo "  FAIL: $name (expected=$expected got=$decision)"
  fi
  LAST_OUTPUT=$output
}

echo "=== pretool-public-repo-guard tests ==="

# 1. 未 push の commit に携帯番号 → ask。理由に値そのものを載せない
R=$(new_repo phone 1)
commit_file "$R" "TEL: $PHONE"
run_case "01_push_phone_number_asks" "$R" "git push" ask
if [[ $LAST_OUTPUT != *"$PHONE"* ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: 02_reason_does_not_echo_value"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("02_reason_does_not_echo_value: $LAST_OUTPUT")
  echo "  FAIL: 02_reason_does_not_echo_value"
fi

# 3. 同じ内容でも .public-repo が無い repo では何もしない
R=$(new_repo private 0)
commit_file "$R" "TEL: $PHONE"
run_case "03_repo_without_marker_passes" "$R" "git push" pass

# 4. 問題の無い commit は通す
R=$(new_repo clean 1)
commit_file "$R" "just a normal line"
run_case "04_clean_push_passes" "$R" "git push" pass

# 5. push 済みの commit は検査しない（既に公開済み・これから出るものだけを見る）
R=$(new_repo pushed 1)
commit_file "$R" "TEL: $PHONE"
git -C "$R" push -q origin HEAD 2>/dev/null
commit_file "$R" "harmless follow-up"
run_case "05_already_pushed_commit_ignored" "$R" "git push" pass

# 6. denylist の語は commit message でも拾う（大文字小文字は区別しない）
R=$(new_repo message 1)
commit_file "$R" "ok" "docs: notes for ACME-Secret-Corp"
run_case "06_denylist_in_commit_message_asks" "$R" "git push" ask

# 7. denylist が無ければ固有語は拾わない（汎用パターンだけ）
R=$(new_repo nodeny 1)
commit_file "$R" "acme-secret-corp"
PUBLIC_GUARD_DENYLIST="$TMPROOT/missing" run_case "07_without_denylist_generic_only" "$R" "git push" pass

# 8. `public-guard: allow` の行は検査しない
R=$(new_repo allow 1)
commit_file "$R" "fixture $GH_TOKEN_LIKE # public-guard: allow"
run_case "08_allow_marker_skips_line" "$R" "git push" pass

# 9. token の形 → ask（compound command の中の push も拾う）
R=$(new_repo token 1)
commit_file "$R" "token=$GH_TOKEN_LIKE"
run_case "09_token_in_compound_push_asks" "$R" "git add -A; git push origin HEAD" ask

# 10. gh pr create の --body-file に denylist の語 → ask
R=$(new_repo ghbody 1)
echo "deployed for acme-secret-corp" >"$R/body.md"
run_case "10_gh_body_file_asks" "$R" "gh pr create --title t --body-file body.md" ask

# 11. gh issue comment の inline body に携帯番号 → ask
run_case "11_gh_inline_body_asks" "$R" "gh issue comment 1 --body \"call $PHONE\"" ask

# 12. 問題の無い gh pr create は通す / 対象外のコマンドは通す
echo "plain body" >"$R/clean.md"
run_case "12_gh_clean_body_passes" "$R" "gh pr create --title t --body-file clean.md" pass
run_case "13_unrelated_command_passes" "$R" "echo $PHONE" pass

# 14. hash の一部のような英数字に挟まれた番号・task- のような語は拾わない
R=$(new_repo hashlike 1)
commit_file "$R" "rev = a${PHONE//-/}b; name = task-$(printf 'x%.0s' {1..24})"
run_case "14_embedded_digits_and_task_prefix_pass" "$R" "git push" pass

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
echo "PASS: pretool-public-repo-guard"
