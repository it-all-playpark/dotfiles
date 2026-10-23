#!/usr/bin/env bash
# scripts/flake-lock-pr.sh の検証。一時 repo（bare の origin と clone）で、更新した flake.lock だけが
# origin/main を親にした commit で feature branch に push され、PR と auto-merge が頼まれ、作業ツリーの lock が戻ること、
# main と入力が違うときや PR を作れないときは何も push せず / lock を残して非 0 になることを確かめる。gh は stub。
# Run from the repo root: bash tests/flake-lock-pr.test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/flake-lock-pr.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/flake-lock-pr-test.XXXXXX")"
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

# 外側の git 環境（hook 実行中の GIT_DIR など）を持ち込まない
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# gh の stub: 引数を GH_LOG に 1 行ずつ残す。GH_FAIL_CREATE / GH_FAIL_MERGE で失敗させる
mkdir -p "$TMPROOT/bin"
cat >"$TMPROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case "$1 $2" in
  "pr create") [ -z "${GH_FAIL_CREATE:-}" ] || exit 1; echo "https://github.com/o/r/pull/1" ;;
  "pr merge") [ -z "${GH_FAIL_MERGE:-}" ] || exit 1 ;;
esac
EOF
chmod +x "$TMPROOT/bin/gh"
export PATH="$TMPROOT/bin:$PATH"

# setup <name>: origin（bare）と clone を作り、flake.nix / flake.lock / README を main に push した clone のパスを出す
setup() {
  local d="$TMPROOT/$1"
  git init -q --bare -b main "$d/origin.git"
  git init -q -b main "$d/work"
  git -C "$d/work" remote add origin "$d/origin.git"
  echo nix-v1 >"$d/work/flake.nix"
  echo lock-v1 >"$d/work/flake.lock"
  echo readme >"$d/work/README"
  git -C "$d/work" add .
  git -C "$d/work" commit -q -m init
  git -C "$d/work" push -q origin main
  echo "$d/work"
}

# run <work>: work を cwd にして script を走らせ、終了コードを RC、出力を OUT に入れる
run() {
  export GH_LOG="$TMPROOT/gh.log"
  : >"$GH_LOG"
  set +e
  OUT="$(cd "$1" && bash "$SCRIPT" 2>&1)"
  RC=$?
  set -e
}

remote_branches() {
  git -C "$1/../origin.git" for-each-ref --format='%(refname:short)' refs/heads/ | grep -v '^main$' || true
}

echo "=== flake-lock-pr tests ==="
echo ""

echo "- unchanged_lock_does_nothing"
W="$(setup unchanged)"
run "$W"
if [ "$RC" -eq 0 ] && [ -z "$(remote_branches "$W")" ] && [ ! -s "$GH_LOG" ]; then
  pass "unchanged_lock_does_nothing"
else
  fail "unchanged_lock_does_nothing" "rc=$RC branches=$(remote_branches "$W") gh=$(cat "$GH_LOG") out=$OUT"
fi

echo "- pushes_lock_only_commit_and_opens_auto_merge_pr"
W="$(setup changed)"
echo lock-v2 >"$W/flake.lock"
echo local-edit >"$W/README"
head_before="$(git -C "$W" rev-parse HEAD)"
run "$W"
br="$(remote_branches "$W")"
origin="$W/../origin.git"
main_sha="$(git -C "$origin" rev-parse main)"
if [ "$RC" -ne 0 ] || [ -z "$br" ]; then
  fail "pushes_lock_only_commit_and_opens_auto_merge_pr" "rc=$RC branches=$br out=$OUT"
else
  changed="$(git -C "$origin" diff --name-only "main" "$br")"
  parent="$(git -C "$origin" rev-parse "$br^")"
  lock="$(git -C "$origin" show "$br:flake.lock")"
  if [[ "$br" == chore/flake-lock-* ]] && [ "$changed" = flake.lock ] && [ "$parent" = "$main_sha" ] && [ "$lock" = lock-v2 ]; then
    pass "pushes_lock_only_commit_and_opens_auto_merge_pr: commit"
  else
    fail "pushes_lock_only_commit_and_opens_auto_merge_pr: commit" "br=$br changed=$changed parent=$parent main=$main_sha lock=$lock"
  fi
  if grep -q "^pr create --base main --head $br " "$GH_LOG" && grep -q '^pr merge https://github.com/o/r/pull/1 --auto --squash' "$GH_LOG"; then
    pass "pushes_lock_only_commit_and_opens_auto_merge_pr: gh"
  else
    fail "pushes_lock_only_commit_and_opens_auto_merge_pr: gh" "gh=$(cat "$GH_LOG")"
  fi
  if [ "$(cat "$W/flake.lock")" = lock-v1 ] && [ "$(cat "$W/README")" = local-edit ] &&
    [ "$(git -C "$W" rev-parse HEAD)" = "$head_before" ] && [ "$(git -C "$W" symbolic-ref --short HEAD)" = main ]; then
    pass "pushes_lock_only_commit_and_opens_auto_merge_pr: worktree"
  else
    fail "pushes_lock_only_commit_and_opens_auto_merge_pr: worktree" "lock=$(cat "$W/flake.lock") readme=$(cat "$W/README") status=$(git -C "$W" status --short)"
  fi
fi

echo "- main_with_different_inputs_is_not_pushed"
W="$(setup diverged)"
other="$TMPROOT/diverged/other"
git clone -q "$W/../origin.git" "$other"
echo nix-v2 >"$other/flake.nix"
git -C "$other" commit -q -am "change inputs"
git -C "$other" push -q origin main
echo lock-v2 >"$W/flake.lock"
run "$W"
if [ "$RC" -ne 0 ] && [ -z "$(remote_branches "$W")" ] && [ ! -s "$GH_LOG" ] && [ "$(cat "$W/flake.lock")" = lock-v2 ]; then
  pass "main_with_different_inputs_is_not_pushed"
else
  fail "main_with_different_inputs_is_not_pushed" "rc=$RC branches=$(remote_branches "$W") lock=$(cat "$W/flake.lock") out=$OUT"
fi

echo "- pr_create_failure_keeps_lock"
W="$(setup createfail)"
echo lock-v2 >"$W/flake.lock"
GH_FAIL_CREATE=1 run "$W"
if [ "$RC" -ne 0 ] && [ "$(cat "$W/flake.lock")" = lock-v2 ] && ! grep -q '^pr merge' "$GH_LOG"; then
  pass "pr_create_failure_keeps_lock"
else
  fail "pr_create_failure_keeps_lock" "rc=$RC lock=$(cat "$W/flake.lock") gh=$(cat "$GH_LOG") out=$OUT"
fi

echo "- auto_merge_failure_only_warns"
W="$(setup mergefail)"
echo lock-v2 >"$W/flake.lock"
GH_FAIL_MERGE=1 run "$W"
if [ "$RC" -eq 0 ] && [ "$(cat "$W/flake.lock")" = lock-v1 ] && [[ "$OUT" == *"auto-merge を予約できない"* ]]; then
  pass "auto_merge_failure_only_warns"
else
  fail "auto_merge_failure_only_warns" "rc=$RC lock=$(cat "$W/flake.lock") out=$OUT"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  printf '  %s\n' "${ERRORS[@]}"
  exit 1
fi
