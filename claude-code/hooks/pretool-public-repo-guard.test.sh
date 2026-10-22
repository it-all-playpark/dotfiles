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
# --repo の checkout は一時ディレクトリの ghq 配置から探す（実際の ~/ghq を見ない）
export PUBLIC_GUARD_GHQ_ROOT="$TMPROOT/ghq"

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

# commit_on_branch <repo> <branch> <content>: 別ブランチに未 push の commit を作り、元のブランチに戻る
commit_on_branch() {
  git -C "$1" switch -q -c "$2"
  commit_file "$1" "$3"
  git -C "$1" switch -q -
}

# 15-16. push する src だけを見る: 別ブランチにだけ token があり、現在ブランチは clean → 通す
OTHER=$(new_repo otherleak 1)
commit_on_branch "$OTHER" leak "token=$GH_TOKEN_LIKE"
commit_on_branch "$OTHER" side "just a normal line"
commit_file "$OTHER" "just a normal line"
run_case "15_other_branch_leak_push_passes" "$OTHER" "git push" pass
run_case "16_other_branch_leak_push_head_passes" "$OTHER" "git push origin HEAD" pass

# 17. 現在ブランチに token（別ブランチは clean）→ git push / git push origin HEAD とも ask
CUR=$(new_repo curleak 1)
commit_on_branch "$CUR" side "just a normal line"
commit_file "$CUR" "token=$GH_TOKEN_LIKE"
run_case "17a_current_branch_leak_push_asks" "$CUR" "git push" ask
run_case "17b_current_branch_leak_push_head_asks" "$CUR" "git push -u origin HEAD" ask

# 18-19. src を明示した push はそのブランチを見る
run_case "18a_explicit_leak_branch_asks" "$OTHER" "git push origin leak" ask
run_case "18b_explicit_leak_refspec_asks" "$OTHER" "git push origin +leak:refs/heads/review" ask
run_case "19a_explicit_clean_branch_passes" "$CUR" "git push origin side" pass
run_case "19b_explicit_clean_refspec_passes" "$CUR" "git push origin side:review" pass

# 20. 複数 refspec はすべての src を見る（どれか 1 つに token があれば ask）
run_case "20a_multiple_refspecs_one_leak_asks" "$OTHER" "git push origin side leak:review" ask
run_case "20b_multiple_refspecs_all_clean_passes" "$OTHER" "git push origin HEAD side:review" pass
run_case "20c_multiple_push_commands_one_leak_asks" "$OTHER" "git push origin side && git push origin leak" ask

# 21. src を解決できない push は全ローカルブランチを見る
run_case "21a_all_falls_back_to_branches" "$OTHER" "git push --all origin" ask
run_case "21b_mirror_falls_back_to_branches" "$OTHER" "git push --mirror origin" ask
run_case "21c_tags_falls_back_to_branches" "$OTHER" "git push --tags origin" ask
run_case "21d_missing_ref_falls_back_to_branches" "$OTHER" "git push origin no-such-branch" ask
run_case "21e_global_option_falls_back_to_branches" "$OTHER" "git -C $OTHER push" ask
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=push.default GIT_CONFIG_VALUE_0=matching \
  run_case "21f_push_default_matching_falls_back" "$OTHER" "git push" ask
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0='refs/heads/*:refs/heads/*' \
  run_case "21g_remote_push_refspec_falls_back" "$OTHER" "git push origin" ask
run_case "21h_xargs_appended_refspec_falls_back" "$OTHER" "echo leak | xargs git push origin" ask
run_case "21i_env_prefix_falls_back" "$OTHER" "GIT_DIR=$OTHER/.git git push origin HEAD" ask
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.mirror GIT_CONFIG_VALUE_0=true \
  run_case "21j_remote_mirror_falls_back" "$OTHER" "git push origin" ask

# 22. 前段が HEAD や cwd を変えうる複合コマンドは、hook 時点の HEAD で解決せず全ローカルブランチを見る
run_case "22a_switch_then_push_falls_back" "$OTHER" "git switch leak && git push" ask
run_case "22b_checkout_then_push_head_falls_back" "$OTHER" "git checkout leak; git push origin HEAD" ask
run_case "22c_cd_then_push_falls_back" "$OTHER" "cd $OTHER && git push" ask

# 23. gh を内部で呼ぶ起票スクリプト（create_issue.py）も --title / --body-file を検査する
R=$(new_repo issuescript 1)
echo "deployed for acme-secret-corp" >"$R/leak.md"
echo "plain body" >"$R/clean.md"
SCRIPT=/opt/plugins/dev-flow/git-issue/scripts/create_issue.py
run_case "23a_create_issue_body_file_asks" "$R" "python3 $SCRIPT --title t --body-file leak.md" ask
run_case "23b_create_issue_title_asks" "$R" "create_issue.py --title 'notes for ACME-Secret-Corp' --body-file clean.md" ask
run_case "23c_create_issue_clean_passes" "$R" "python3 $SCRIPT --title t --body-file clean.md" pass
if [[ -z $LAST_OUTPUT ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: 23d_create_issue_clean_stdout_empty"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("23d_create_issue_clean_stdout_empty: $LAST_OUTPUT")
  echo "  FAIL: 23d_create_issue_clean_stdout_empty"
fi

# 24. --repo OWNER/NAME は cwd ではなく ghq 配置の checkout の .public-repo で判定する
mkdir -p "$PUBLIC_GUARD_GHQ_ROOT/github.com/acme-test/pubrepo" "$PUBLIC_GUARD_GHQ_ROOT/github.com/acme-test/privrepo"
touch "$PUBLIC_GUARD_GHQ_ROOT/github.com/acme-test/pubrepo/.public-repo"
P=$(new_repo privcwd 0)
echo "deployed for acme-secret-corp" >"$P/leak.md"
run_case "24a_gh_repo_public_target_asks" "$P" "gh issue create --repo acme-test/pubrepo --title t --body-file leak.md" ask
run_case "24b_create_issue_repo_public_target_asks" "$P" "python3 $SCRIPT --title t --body-file leak.md --repo acme-test/pubrepo" ask
run_case "24c_gh_short_repo_option_asks" "$P" "gh issue create -R github.com/acme-test/pubrepo --title t --body-file leak.md" ask
run_case "24d_gh_repo_private_target_passes" "$R" "gh issue create --repo acme-test/privrepo --title t --body-file leak.md" pass

# 25. --repo の checkout が見つからなければ cwd の repo で判定する
run_case "25a_missing_checkout_public_cwd_asks" "$R" "gh issue create --repo acme-test/nowhere --title t --body-file leak.md" ask
run_case "25b_missing_checkout_private_cwd_passes" "$P" "python3 $SCRIPT --title t --body-file leak.md --repo acme-test/nowhere" pass

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
echo "PASS: pretool-public-repo-guard"
