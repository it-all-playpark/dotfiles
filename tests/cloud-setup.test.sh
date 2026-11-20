#!/usr/bin/env bash
# tests/cloud-setup.test.sh
# cloud/setup.sh を、偽の apt-get と一時 HOME で実行して検証する（何も install しない）。
#
# 検証項目:
#   1. setup_succeeds              - setup が exit 0 で終わる
#   2. installs_bats               - apt-get install に bats を渡す
#   3. links_hooks                 - claude-code/hooks/ の *.sh / *.py が $HOME/.claude/hooks/ に symlink され、*.test.sh は張られない
#   4. writes_settings             - $HOME/.claude/settings.json は cloud/settings.jq の出力（sandbox が無く、
#                                    SessionStart にこの checkout の cloud/hooks/session-start.sh が入る）
#   5. backs_up_existing_settings  - 既にあった settings は settings.json.bak に退避される
#   6. hook_files_exist            - 生成した settings の全 hook の command が参照するファイルが、setup 後に存在する
#                                    （参照先が無い hook は黙って外れる）
#   7. bin_referenced_exists       - hook が呼ぶ ~/.claude/bin/jev-classify と statusLine の参照先が setup 後に存在し、
#                                    *.bats は張られない
#   8. rerun_same_result          - 再実行（PATH に settings が足す 2 つが入った状態）しても settings・.bak・hooks が変わらない

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cloud-setup-test.XXXXXX")"
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

summary() {
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  if [ "${FAIL}" -gt 0 ]; then
    echo "Failed tests:"
    for err in "${ERRORS[@]}"; do
      echo "  - ${err}"
    done
    exit 1
  fi
}

SETUP="$REPO_ROOT/cloud/setup.sh"
HOOKS_DIR="$REPO_ROOT/claude-code/hooks"
FAKE_HOME="$TMPROOT/home"
FAKEBIN="$TMPROOT/fakebin"
LOG="$TMPROOT/calls.log"
mkdir -p "$FAKE_HOME/.claude" "$FAKEBIN"

# 偽の apt-get は argv を 1 行で記録するだけ
# shellcheck disable=SC2016 # 意図的なリテラル: $* / $FAKE_CALLS_LOG は偽コマンドの実行時に展開させる
printf '#!/bin/sh\necho "apt-get $*" >>"$FAKE_CALLS_LOG"\n' >"$FAKEBIN/apt-get"
chmod +x "$FAKEBIN/apt-get"
# jq は実体を使う（setup が apt-get で入れる想定のもの）
ln -s "$(command -v jq)" "$FAKEBIN/jq"

BASE_PATH="$FAKEBIN:/usr/bin:/bin"
SETTINGS="$FAKE_HOME/.claude/settings.json"
echo '{"existing":true}' >"$SETTINGS"

run_setup() {
  env -i HOME="$FAKE_HOME" PATH="$1" TMPDIR="$TMPROOT" FAKE_CALLS_LOG="$LOG" bash "$SETUP"
}

# --- 1. setup_succeeds ---
if run_setup "$BASE_PATH" >"$TMPROOT/run1.out" 2>&1; then
  pass "setup_succeeds"
else
  fail "setup_succeeds" "$(cat "$TMPROOT/run1.out")"
  summary
fi

# --- 2. installs_bats ---
if grep -Eq '^apt-get install .*\bbats\b' "$LOG"; then
  pass "installs_bats"
else
  fail "installs_bats" "calls: $(cat "$LOG")"
fi

# --- 3. links_hooks ---
bad=""
count=0
for f in "$HOOKS_DIR"/*.sh "$HOOKS_DIR"/*.py; do
  base="$(basename "$f")"
  target="$FAKE_HOME/.claude/hooks/$base"
  case "$base" in
  *.test.sh)
    if [ -e "$target" ] || [ -L "$target" ]; then bad="$bad $base(test が張られた)"; fi
    ;;
  *)
    count=$((count + 1))
    if [ ! -L "$target" ] || [ "$(readlink "$target")" != "$f" ]; then bad="$bad $base"; fi
    ;;
  esac
done
if [ "$count" -gt 0 ] && [ -z "$bad" ]; then
  pass "links_hooks"
else
  fail "links_hooks" "期待どおりでない hook:$bad"
fi

# --- 4. writes_settings ---
SESSION_START="$REPO_ROOT/cloud/hooks/session-start.sh"
if jq -e --arg f "$SESSION_START" '
  (has("sandbox") | not)
  and ([.hooks.SessionStart[].hooks[].command | select(contains($f))] | length == 1)
' "$SETTINGS" >/dev/null 2>&1; then
  pass "writes_settings"
else
  fail "writes_settings" "settings.json が cloud/settings.jq の出力になっていない"
fi

# --- 5. backs_up_existing_settings ---
if [ "$(cat "$SETTINGS.bak" 2>/dev/null)" = '{"existing":true}' ]; then
  pass "backs_up_existing_settings"
else
  fail "backs_up_existing_settings" "settings.json.bak が元の内容でない"
fi

# --- 6. hook_files_exist ---
# command の中のスクリプトのパス（$HOME 起点か絶対パス）を取り出し、$HOME を一時 HOME に読み替えて存在を確かめる
jq -r '.hooks[][].hooks[].command' "$SETTINGS" >"$TMPROOT/commands.txt"
missing=""
while IFS= read -r command; do
  path="$(printf '%s\n' "$command" | sed -n "s|.*[\"']\\([^\"']*\\.[a-z]*\\)[\"'].*|\\1|p")"
  path="${path/#\$HOME/$FAKE_HOME}"
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    missing="$missing [$command]"
  fi
done <"$TMPROOT/commands.txt"
if [ -s "$TMPROOT/commands.txt" ] && [ -z "$missing" ]; then
  pass "hook_files_exist"
else
  fail "hook_files_exist" "参照先が無い hook:$missing"
fi

# --- 7. bin_referenced_exists ---
# hook が $SCRIPT_DIR/../bin/jev-classify（= ~/.claude/bin）で呼ぶ jev-classify と、statusLine の command の参照先が
# setup 後の一時 HOME にある（無いと Jev 判定は `|| true` で黙って素通りし、statusLine は出ない）
statusline="$(jq -r '.statusLine.command // ""' "$SETTINGS")"
statusline="${statusline/#\~/$FAKE_HOME}"
statusline="${statusline/#\$HOME/$FAKE_HOME}"
if [ -x "$FAKE_HOME/.claude/hooks/../bin/jev-classify" ] && [ -n "$statusline" ] && [ -x "$statusline" ] &&
  [ ! -e "$FAKE_HOME/.claude/bin/jev-classify.bats" ]; then
  pass "bin_referenced_exists"
else
  fail "bin_referenced_exists" "statusLine=$statusline bin=$(ls "$FAKE_HOME/.claude/bin" 2>&1)"
fi

# --- 8. rerun_same_result ---
# $HOME/.claude/hooks の中身を「名前 -> symlink 先」の行で出す
hook_links() {
  for t in "$FAKE_HOME"/.claude/hooks/*; do
    echo "$(basename "$t") -> $(readlink "$t")"
  done
}
cp "$SETTINGS" "$TMPROOT/settings.first"
hook_links >"$TMPROOT/hooks.first"
if run_setup "$REPO_ROOT/cloud/bin:$REPO_ROOT/claude-code/bin:$BASE_PATH" >"$TMPROOT/run2.out" 2>&1 &&
  cmp -s "$TMPROOT/settings.first" "$SETTINGS" &&
  [ "$(cat "$SETTINGS.bak")" = '{"existing":true}' ] &&
  hook_links | cmp -s - "$TMPROOT/hooks.first"; then
  pass "rerun_same_result"
else
  fail "rerun_same_result" "再実行で settings / .bak / hooks が変わった: $(cat "$TMPROOT/run2.out")"
fi

summary
echo "PASS: cloud-setup"
