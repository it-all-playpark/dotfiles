#!/usr/bin/env bash
# shellcheck disable=SC2016 # 意図的: jq の式（$i / $o などは jq の変数）をシングルクォートで渡す
# tests/cloud-settings.test.sh
# クラウドセッション用の Claude Code settings を作る変換定義 cloud/settings.jq を、
# repo の claude-code/settings.json へ当てて検証する（cloud/setup.sh が同じファイルを jq -f で使う）。
# 入力から引き継ぐ値の期待値は直書きせず、入力から読んで作る。
#
# 検証項目:
#   1. generates                    - 変換が成功して JSON になる
#   2. no_sandbox                   - sandbox キーが残らない
#   3. no_mac_only_values           - /private/tmp/・/Library/・~/.lima・.orbstack を含む値と、
#                                     osascript・`security ` で始まる hook command が残らない
#   4. plugins_same_as_input        - enabledPlugins の playpark-core / dev-flow と extraKnownMarketplaces.playpark は入力と同じ
#   5. path_cloud_bin_first         - env.PATH で cloud/bin が claude-code/bin より前に来て、渡した PATH が後ろに続く
#   6. docker_reaches_real_docker   - 生成した env（PATH・DOCKER_HOST）で docker を叩くと、claude-code/bin/docker を通って
#                                     実体の docker に届く（docker-vm を探して落ちない）
#   7. hooks_keep_existing_files    - hook は、入力のうち command が参照するファイルが claude-code/hooks/ にあるものだけが
#                                     同じイベント・同じ順で残る（足した SessionStart を除く）
#   8. hooks_follow_hook_files      - 渡した hook のファイル名に無い hook は残らない
#   9. no_empty_hook_groups         - hook が無くなった matcher グループとイベントは残らない
#  10. session_start_added          - SessionStart に cloud/hooks/session-start.sh が足され、timeout は待ち時間の 30 秒より長い
#  11. relative_dotfiles_rejected   - dotfiles を相対パスで渡すと失敗する
#  12. session_start_path_not_expanded - checkout 先の名前に $( ) / ` / クォートがあっても SessionStart の command は
#                                     それを評価せず、パス全体を 1 つの引数として渡す

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cloud-settings-test.XXXXXX")"
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

INPUT="$REPO_ROOT/claude-code/settings.json"
FILTER="$REPO_ROOT/cloud/settings.jq"
HOOKS_DIR="$REPO_ROOT/claude-code/hooks"

DOTFILES="/opt/dotfiles"
BASE_PATH="/usr/local/bin:/usr/bin:/bin"

# generate <dotfiles> <path> <hook のファイル名の JSON 配列>
generate() {
  jq --arg dotfiles "$1" --arg path "$2" --argjson hook_files "$3" -f "$FILTER" "$INPUT"
}

# claude-code/hooks/ にある hook のファイル名（setup が ~/.claude/hooks に置くもの）
find "$HOOKS_DIR" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) ! -name '*.test.sh' -exec basename {} \; |
  sort >"$TMPROOT/hook-files.txt"
HOOK_FILES="$(jq -R . "$TMPROOT/hook-files.txt" | jq -sc .)"

# --- 1. generates ---
OUT="$TMPROOT/out.json"
if generate "$DOTFILES" "$BASE_PATH" "$HOOK_FILES" >"$OUT" 2>"$TMPROOT/err" && jq -e 'type == "object"' "$OUT" >/dev/null; then
  pass "generates"
else
  fail "generates" "jq -f cloud/settings.jq が失敗した: $(cat "$TMPROOT/err")"
  summary
fi

# --- 2. no_sandbox ---
if jq -e 'has("sandbox") | not' "$OUT" >/dev/null; then
  pass "no_sandbox"
else
  fail "no_sandbox" "sandbox キーが残っている"
fi

# --- 3. no_mac_only_values ---
leftover="$(jq -c '
  [.. | strings | select(test("/private/tmp/|/Library/|~/\\.lima|\\.orbstack"))]
  + [.hooks[][].hooks[].command | select(test("^(osascript|security )"))]
' "$OUT")"
if [ "$leftover" = "[]" ]; then
  pass "no_mac_only_values"
else
  fail "no_mac_only_values" "macOS 専用の値が残っている: $leftover"
fi

# --- 4. plugins_same_as_input ---
if jq -e --slurpfile i "$INPUT" '
  . as $o | $i[0] as $i
  | $i.enabledPlugins["playpark-core@playpark"] != null
  and $o.enabledPlugins["playpark-core@playpark"] == $i.enabledPlugins["playpark-core@playpark"]
  and $o.enabledPlugins["dev-flow@playpark"] == $i.enabledPlugins["dev-flow@playpark"]
  and $i.extraKnownMarketplaces.playpark != null
  and $o.extraKnownMarketplaces.playpark == $i.extraKnownMarketplaces.playpark
' "$OUT" >/dev/null; then
  pass "plugins_same_as_input"
else
  fail "plugins_same_as_input" "enabledPlugins / extraKnownMarketplaces.playpark が入力と違う"
fi

# --- 5. path_cloud_bin_first ---
got_path="$(jq -r '.env.PATH' "$OUT")"
if [ "$got_path" = "$DOTFILES/cloud/bin:$DOTFILES/claude-code/bin:$BASE_PATH" ]; then
  pass "path_cloud_bin_first"
else
  fail "path_cloud_bin_first" "env.PATH=$got_path"
fi

# --- 6. docker_reaches_real_docker ---
# 実体の docker（偽物）は PATH の後ろに置く。claude-code/bin/docker は繋ぎ先の明示が無いと docker-vm を探して落ちる
FAKEBIN="$TMPROOT/fakebin"
mkdir -p "$FAKEBIN" "$TMPROOT/home"
printf '#!/bin/sh\necho "real-docker $*"\n' >"$FAKEBIN/docker"
chmod +x "$FAKEBIN/docker"
generate "$REPO_ROOT" "$FAKEBIN:/usr/bin:/bin" "$HOOK_FILES" >"$TMPROOT/out-repo.json"
set +e
docker_out="$(env -i HOME="$TMPROOT/home" \
  PATH="$(jq -r '.env.PATH' "$TMPROOT/out-repo.json")" \
  DOCKER_HOST="$(jq -r '.env.DOCKER_HOST' "$TMPROOT/out-repo.json")" \
  /bin/sh -c 'docker ps' 2>&1)"
docker_rc=$?
set -e
if [ "$docker_rc" -eq 0 ] && [ "$docker_out" = "real-docker ps" ]; then
  pass "docker_reaches_real_docker"
else
  fail "docker_reaches_real_docker" "rc=$docker_rc out=$docker_out"
fi

# --- 7. hooks_keep_existing_files ---
# 「イベント<TAB>command」の行にして比べる。期待値は入力の hook のうち、参照するファイルが claude-code/hooks/ にあるもの
hook_lines() {
  jq -r '.hooks | to_entries[] | .key as $k | .value[].hooks[] | [$k, .command] | @tsv' "$1"
}
SESSION_START_CMD="bash '$DOTFILES/cloud/hooks/session-start.sh'"
hook_lines "$INPUT" >"$TMPROOT/input-hooks.tsv"
: >"$TMPROOT/expected-hooks.tsv"
while IFS= read -r line; do
  file="$(printf '%s\n' "$line" | sed -n 's|.*\.claude/hooks/\([A-Za-z0-9._-]*\).*|\1|p')"
  if [ -n "$file" ] && [ -f "$HOOKS_DIR/$file" ]; then
    printf '%s\n' "$line" >>"$TMPROOT/expected-hooks.tsv"
  fi
done <"$TMPROOT/input-hooks.tsv"
jq -r --arg added "$SESSION_START_CMD" '
  .hooks | to_entries[] | .key as $k | .value[].hooks[] | select(.command != $added) | [$k, .command] | @tsv
' "$OUT" >"$TMPROOT/got-hooks.tsv"
if [ -s "$TMPROOT/expected-hooks.tsv" ] && cmp -s "$TMPROOT/expected-hooks.tsv" "$TMPROOT/got-hooks.tsv"; then
  pass "hooks_keep_existing_files"
else
  fail "hooks_keep_existing_files" "$(diff "$TMPROOT/expected-hooks.tsv" "$TMPROOT/got-hooks.tsv" | head -20)"
fi

# --- 8. hooks_follow_hook_files ---
ONLY="memory-monitor.py"
got_only="$(generate "$DOTFILES" "$BASE_PATH" "[\"$ONLY\"]" |
  jq -c --arg added "$SESSION_START_CMD" '[.hooks[][].hooks[].command | select(. != $added)]')"
want_only="$(jq -c --arg f "$ONLY" '[.hooks[][].hooks[].command | select(contains("/.claude/hooks/" + $f))]' "$INPUT")"
if [ "$want_only" != "[]" ] && [ "$got_only" = "$want_only" ]; then
  pass "hooks_follow_hook_files"
else
  fail "hooks_follow_hook_files" "got=$got_only want=$want_only"
fi

# --- 9. no_empty_hook_groups ---
if jq -e '[.hooks[] | length > 0 and all(.[]; .hooks | length > 0)] | all' "$OUT" >/dev/null; then
  pass "no_empty_hook_groups"
else
  fail "no_empty_hook_groups" "hook の無い matcher グループかイベントが残っている"
fi

# --- 10. session_start_added ---
if jq -e --arg added "$SESSION_START_CMD" '
  [.hooks.SessionStart[].hooks[] | select(.command == $added)]
  | length == 1 and .[0].type == "command" and .[0].timeout > 30
' "$OUT" >/dev/null; then
  pass "session_start_added"
else
  fail "session_start_added" "SessionStart=$(jq -c '.hooks.SessionStart' "$OUT")"
fi

# --- 11. relative_dotfiles_rejected ---
if generate "dotfiles" "$BASE_PATH" "$HOOK_FILES" >/dev/null 2>&1; then
  fail "relative_dotfiles_rejected" "相対パスの dotfiles で変換が成功した"
else
  pass "relative_dotfiles_rejected"
fi

# --- 12. session_start_path_not_expanded ---
# checkout 先の名前にコマンド置換・クォートが入っていても、SessionStart の command はそれを評価せず、
# パス全体を 1 つの引数として bash に渡す
EVIL_DIR="$TMPROOT/evil \$(touch $TMPROOT/pwned)\`touch $TMPROOT/pwned2\`'\""
mkdir -p "$EVIL_DIR/cloud/hooks"
printf '#!/bin/sh\necho reached\n' >"$EVIL_DIR/cloud/hooks/session-start.sh"
evil_cmd="$(generate "$EVIL_DIR" "$BASE_PATH" "$HOOK_FILES" | jq -r '.hooks.SessionStart[-1].hooks[0].command')"
evil_out="$(env -i PATH=/usr/bin:/bin sh -c "$evil_cmd" 2>&1 || true)"
if [ "$evil_out" = "reached" ] && [ ! -e "$TMPROOT/pwned" ] && [ ! -e "$TMPROOT/pwned2" ]; then
  pass "session_start_path_not_expanded"
else
  fail "session_start_path_not_expanded" "command=$evil_cmd out=$evil_out"
fi

summary
echo "PASS: cloud-settings"
