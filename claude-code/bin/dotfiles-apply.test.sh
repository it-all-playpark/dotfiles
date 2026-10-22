#!/usr/bin/env bash
# claude-code/bin/dotfiles-apply.test.sh
# origin/main の dotfiles を home-manager と nix-darwin に反映する dotfiles-apply のテスト。
#
# Usage: bash claude-code/bin/dotfiles-apply.test.sh
#
# ケースごとに bare の origin と、メイン checkout 役の clone（$HOME/ghq/github.com/it-all-playpark/dotfiles。HOME を
# $TMPDIR に向ける）を作り、nix / sudo は呼ばれた引数を記録するだけの stub に PATH で差し替える。
# 本物の dotfiles にも、システムの設定にも触れない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY="$SCRIPT_DIR/dotfiles-apply"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-apply-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

pass() {
  printf "  \033[32mPASS\033[0m %s\n" "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf "  \033[31mFAIL\033[0m %s\n" "$1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  FAILURES+=("$1: $2")
}

# 利用者の global / system の git 設定（hooksPath 等）を持ち込まない
export GIT_CONFIG_GLOBAL="$TMPROOT/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name t
git config --file "$GIT_CONFIG_GLOBAL" user.email t@t
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

USER_NAME="$(id -un)"

# stub: 呼ばれた引数を $CALLS に 1 行ずつ書く。nix は NIX_FAIL_ON に一致する引数を含むと失敗する
STUB="$TMPROOT/stub"
mkdir -p "$STUB"
cat >"$STUB/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix $*" >>"$CALLS"
if [ -n "${NIX_FAIL_ON:-}" ] && [[ " $* " == *" $NIX_FAIL_ON "* ]]; then
  exit 1
fi
EOF
cat >"$STUB/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$CALLS"
EOF
chmod +x "$STUB/nix" "$STUB/sudo"

# setup_case <name>: $TMPROOT/<name>/{origin.git,home/ghq/.../dotfiles,pusher} を作り、CASE_HOME / REPO / PUSHER を設定する
setup_case() {
  local dir="$TMPROOT/$1"
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/pusher" 2>/dev/null
  echo a >"$dir/pusher/a.txt"
  git -C "$dir/pusher" add -A
  git -C "$dir/pusher" commit -q -m init
  git -C "$dir/pusher" push -q origin main
  CASE_HOME="$dir/home"
  REPO="$CASE_HOME/ghq/github.com/it-all-playpark/dotfiles"
  mkdir -p "${REPO%/*}"
  git clone -q "$dir/origin.git" "$REPO"
  PUSHER="$dir/pusher"
  export CALLS="$dir/calls"
  : >"$CALLS"
}

# push_change <file> <content>: origin/main に <file> を <content> にする commit を足す
push_change() {
  printf '%s\n' "$2" >"$PUSHER/$1"
  git -C "$PUSHER" add -A
  git -C "$PUSHER" commit -q -m "change $1"
  git -C "$PUSHER" push -q origin main
}

run_apply() {
  set +e
  HOME="$CASE_HOME" PATH="$STUB:$PATH" bash "$APPLY" "$@" >/dev/null 2>"$TMPROOT/err"
  RC=$?
  set -e
  ERR="$(cat "$TMPROOT/err")"
  CALLED="$(cat "$CALLS")"
}

echo "=== dotfiles-apply tests ==="

# ---------------------------------------------------------------------------
# 1. HEAD = origin/main なら home-manager → nix-darwin（sudo）の順に、origin/main の rev に固定した flake で反映する。
#    未 commit のローカル変更があっても作業ツリーは評価しない。flake update はしない
# ---------------------------------------------------------------------------
setup_case main
echo local >"$REPO/a.txt"
rev="$(git -C "$REPO" rev-parse origin/main)"
run_apply
hm_line="$(sed -n 1p "$CALLS")"
darwin_line="$(sed -n 2p "$CALLS")"
flake="git+file://$REPO?rev=$rev"
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 2 ] &&
  [[ $hm_line == "nix run home-manager -- -b backup-"*" --flake $flake#${USER_NAME}-darwin switch" ]] &&
  [ "$darwin_line" = "sudo nix --extra-experimental-features nix-command flakes run nix-darwin -- switch --flake $flake#MyMBP-${USER_NAME}" ] &&
  [[ $CALLED != *"flake update"* ]]; then
  pass "01_applies_origin_main_rev_with_home_manager_then_nix_darwin"
else
  fail "01_applies_origin_main_rev_with_home_manager_then_nix_darwin" "rc=$RC calls=[$CALLED] err=$ERR"
fi

# ---------------------------------------------------------------------------
# 2. main 以外を checkout していたら何も反映せずに非 0 で終わる
# ---------------------------------------------------------------------------
setup_case feature
git -C "$REPO" switch -q -c feat/x
run_apply
if [ "$RC" -ne 0 ] && [ -z "$CALLED" ] && [[ $ERR == *"'feat/x' を checkout している"* ]]; then
  pass "02_not_main_stops_without_applying"
else
  fail "02_not_main_stops_without_applying" "rc=$RC calls=[$CALLED] err=$ERR"
fi

# ---------------------------------------------------------------------------
# 3. origin に無いローカル commit が main にあれば（PR を通っていない変更）何も反映せずに非 0 で終わる
# ---------------------------------------------------------------------------
setup_case local-commit
echo local >"$REPO/a.txt"
git -C "$REPO" commit -q -am local
run_apply
if [ "$RC" -ne 0 ] && [ -z "$CALLED" ] && [[ $ERR == *"HEAD が origin/main"* ]]; then
  pass "03_local_commit_ahead_of_origin_stops_without_applying"
else
  fail "03_local_commit_ahead_of_origin_stops_without_applying" "rc=$RC calls=[$CALLED] err=$ERR"
fi

# ---------------------------------------------------------------------------
# 4. origin/main が先に進んでいたら（dotfiles-sync の前）fetch して気付き、何も反映せずに非 0 で終わる
# ---------------------------------------------------------------------------
setup_case behind
push_change a.txt a2
run_apply
if [ "$RC" -ne 0 ] && [ -z "$CALLED" ] && [[ $ERR == *"dotfiles-sync で揃えてから"* ]]; then
  pass "04_behind_origin_stops_without_applying"
else
  fail "04_behind_origin_stops_without_applying" "rc=$RC calls=[$CALLED] err=$ERR"
fi

# ---------------------------------------------------------------------------
# 5. home-manager の switch が失敗したら nix-darwin（sudo）は走らせずに非 0 で終わる
# ---------------------------------------------------------------------------
setup_case hm-fail
NIX_FAIL_ON=home-manager run_apply
if [ "$RC" -ne 0 ] && [[ $CALLED == *"nix run home-manager"* ]] && [[ $CALLED != *sudo* ]]; then
  pass "05_home_manager_failure_skips_nix_darwin"
else
  fail "05_home_manager_failure_skips_nix_darwin" "rc=$RC calls=[$CALLED] err=$ERR"
fi

# ---------------------------------------------------------------------------
# 6. 引数を渡すと usage で exit 2 になり、何も反映しない（sudo に渡る引数を外から変えさせない）
# ---------------------------------------------------------------------------
setup_case args
run_apply --flake other
if [ "$RC" -eq 2 ] && [ -z "$CALLED" ] && [[ $ERR == *"usage: dotfiles-apply"* ]]; then
  pass "06_arguments_are_rejected"
else
  fail "06_arguments_are_rejected" "rc=$RC calls=[$CALLED] err=$ERR"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  printf '  %s\n' "${FAILURES[@]}"
  exit 1
fi
