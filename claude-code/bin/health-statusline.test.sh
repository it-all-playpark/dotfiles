#!/usr/bin/env bash
# claude-code/bin/health-statusline.test.sh
# dev-flow-health と sandbox-tune の結果を statusLine に 1 行で出す health-statusline のテスト。
#
# Usage: bash claude-code/bin/health-statusline.test.sh
#
# ケースごとに $TMPDIR に HOME を作り、~/.claude/logs の下に dev-flow-health のログ・report と
# sandbox-tune の runs.jsonl を置いてから実行する。時刻は実行時の現在時刻から何秒前かで書く。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="$SCRIPT_DIR/health-statusline"
SETTINGS="$SCRIPT_DIR/../settings.json"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/health-statusline-test.XXXXXX")"
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

H=3600

# ago <秒>: 現在時刻から <秒> 前の ISO 8601 UTC（health-report.sh / daily.sh と同じ形）
ago() {
  jq -nr --argjson s "$1" '(now - $s) | floor | todateiso8601'
}

# setup_home <name>: $TMPROOT/<name> を HOME にして ~/.claude/logs を作る
setup_home() {
  HOME_DIR="$TMPROOT/$1"
  LOGS="$HOME_DIR/.claude/logs"
  mkdir -p "$LOGS/dev-flow-health" "$LOGS/sandbox-tune"
}

# report <name> <秒前> [new] [regressed]: report JSON を書き、パスを stdout に出す
report() {
  local path="$LOGS/dev-flow-health/$1.json"
  jq -n --arg at "$(ago "$2")" --argjson new "${3:-0}" --argjson regressed "${4:-0}" \
    '{generated_at: $at, summary: {new: $new, regressed: $regressed, ongoing: 3, resolved: 1}}' >"$path"
  echo "$path"
}

# log_line <log> <report のパス>: dev-flow-health のログに 1 行足す（daily.sh / watch-journal と同じ形）
log_line() {
  jq -nc --arg r "$2" '{report: $r, needs_llm: false, llm_invoked: false, llm_exit: null}' >>"$LOGS/$1"
}

DAILY=dev-flow-health.log
WATCH=dev-flow-health.watch-journal.log

# ok_run <秒前> <remaining> / error_run <秒前>: runs.jsonl に 1 行足す
ok_run() {
  jq -nc --arg ts "$(ago "$1")" --argjson n "$2" '{report: "r.md", analysis: "r.json", remaining: $n, ts: $ts}' \
    >>"$LOGS/sandbox-tune/runs.jsonl"
}
error_run() {
  jq -nc --arg ts "$(ago "$1")" '{ts: $ts, exit: 1, error: "claude exited 1"}' >>"$LOGS/sandbox-tune/runs.jsonl"
}

# run_statusline: statusLine と同じく stdin に JSON を渡して実行し、OUT / RC を設定する
run_statusline() {
  set +e
  printf '%s' '{"session_id":"s","model":{"display_name":"Opus"},"workspace":{"current_dir":"/x"}}' |
    HOME="$HOME_DIR" bash "$STATUSLINE" >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
  set -e
  OUT="$(cat "$TMPROOT/out")"
}

# expect <name> <期待する 1 行>
expect() {
  run_statusline
  if [ "$RC" -eq 0 ] && [ "$OUT" = "$2" ]; then
    pass "$1"
  else
    fail "$1" "rc=$RC out=[$OUT] want=[$2] err=$(cat "$TMPROOT/err")"
  fi
}

echo "=== health-statusline tests ==="

# --- health ----------------------------------------------------------------
setup_home ok
log_line "$DAILY" "$(report a $((2 * H)))"
expect "01_health_ok" "health ✓ 2h前"

setup_home ago_now
log_line "$DAILY" "$(report a 10)"
expect "02_ago_under_60s_is_now" "health ✓ 今"

setup_home ago_minutes
log_line "$DAILY" "$(report a 300)"
expect "03_ago_under_1h_is_minutes" "health ✓ 5m前"

setup_home new_only
log_line "$DAILY" "$(report a $((2 * H)) 1 0)"
expect "04_health_new" "health ⚠ new1 2h前"

setup_home regressed_only
log_line "$DAILY" "$(report a $((2 * H)) 0 3)"
expect "05_health_regressed" "health ⚠ regressed3 2h前"

setup_home new_and_regressed
log_line "$DAILY" "$(report a $((2 * H)) 2 1)"
expect "06_health_new_and_regressed" "health ⚠ new2 regressed1 2h前"

setup_home within_26h
log_line "$DAILY" "$(report a $((25 * H)))"
expect "07_health_ok_within_26h" "health ✓ 1d前"

setup_home stale
log_line "$DAILY" "$(report a $((27 * H)))"
expect "08_health_stale_over_26h" "health ⚠ 止まっている? 1d前"

setup_home stale_days
log_line "$DAILY" "$(report a $((50 * H)))"
expect "09_ago_days" "health ⚠ 止まっている? 2d前"

setup_home found_beats_stale
log_line "$DAILY" "$(report a $((50 * H)) 1 0)"
expect "10_health_found_over_stale" "health ⚠ new1 2d前"

# 2 つのログが指す report のうち generated_at が新しい方で決める（どちらのログにあっても）
setup_home newer_in_watch
log_line "$DAILY" "$(report old $((30 * H)) 4 0)"
log_line "$WATCH" "$(report fresh $((2 * H)))"
expect "11_newer_report_in_watch_log" "health ✓ 2h前"

setup_home newer_in_daily
log_line "$DAILY" "$(report fresh $((2 * H)))"
log_line "$WATCH" "$(report old $((30 * H)) 4 0)"
expect "12_newer_report_in_daily_log" "health ✓ 2h前"

# 各ログは最終行の report だけを見る。壊れた行・空行は読み飛ばす
setup_home last_line
log_line "$WATCH" "$(report fresh $((2 * H)))"
log_line "$WATCH" "$(report latest $((3 * H)) 0 2)"
printf '\n{"report":"/x' >>"$LOGS/$WATCH"
expect "13_last_line_of_log_skipping_broken" "health ⚠ regressed2 3h前"

# 読める report が無ければ health 部分は出さない
setup_home unreadable_reports
log_line "$DAILY" "$LOGS/dev-flow-health/missing.json"
printf '{not json' >"$LOGS/dev-flow-health/broken.json"
log_line "$WATCH" "$LOGS/dev-flow-health/broken.json"
ok_run $((3 * H)) 5
expect "14_unreadable_reports_omit_health" "sbx 残5 3h前"

# --- sbx -------------------------------------------------------------------
setup_home sbx_up
ok_run $((50 * H)) 3
error_run $((26 * H))
ok_run $((3 * H)) 5
expect "15_sbx_increase_against_previous_success" "sbx 残5(+2) 3h前"

setup_home sbx_down
ok_run $((5 * H)) 4
ok_run $((3 * H)) 1
expect "16_sbx_decrease" "sbx 残1(-3) 3h前"

setup_home sbx_same
ok_run $((5 * H)) 4
ok_run $((3 * H)) 4
expect "17_sbx_unchanged" "sbx 残4(±0) 3h前"

setup_home sbx_first
ok_run $((3 * H)) 5
expect "18_sbx_without_previous_success" "sbx 残5 3h前"

setup_home sbx_error
ok_run $((26 * H)) 5
error_run $((3 * H))
expect "19_sbx_failed" "sbx ⚠ 失敗 3h前"

# 壊れた行・空行・ts が日時として読めない行は読み飛ばす
setup_home sbx_broken_lines
ok_run $((5 * H)) 2
printf '\n\n{"ts":"2026-\n' >>"$LOGS/sandbox-tune/runs.jsonl"
ok_run $((3 * H)) 5
printf '{"ts":"not a date","error":"x"}\n{"remaining":9}\n{"ts":"2026-' >>"$LOGS/sandbox-tune/runs.jsonl"
expect "20_sbx_skips_broken_lines" "sbx 残5(+3) 3h前"

setup_home sbx_no_valid_line
printf '\n{"ts":\n[1,2]\n' >"$LOGS/sandbox-tune/runs.jsonl"
log_line "$DAILY" "$(report a $((2 * H)))"
expect "21_sbx_omitted_without_valid_line" "health ✓ 2h前"

# --- 1 行にまとめる ----------------------------------------------------------
setup_home both
log_line "$DAILY" "$(report a $((2 * H)))"
ok_run $((26 * H)) 3
ok_run $((3 * H)) 5
expect "22_both_joined_health_first" "health ✓ 2h前 · sbx 残5(+2) 3h前"

# ファイルが無ければ空行を出して exit 0。何も書かない
setup_home no_files
before="$(find "$HOME_DIR" | sort)"
run_statusline
after="$(find "$HOME_DIR" | sort)"
if [ "$RC" -eq 0 ] && [ "$(od -An -c "$TMPROOT/out" | tr -d ' ')" = '\n' ] && [ "$before" = "$after" ]; then
  pass "23_no_files_prints_empty_line"
else
  fail "23_no_files_prints_empty_line" "rc=$RC out=[$(od -An -c "$TMPROOT/out")] before=[$before] after=[$after]"
fi

setup_home writes_nothing
log_line "$DAILY" "$(report a $((2 * H)))"
ok_run $((3 * H)) 5
snapshot() {
  find "$HOME_DIR" | sort
  find "$HOME_DIR" -type f -exec cksum {} + | sort
}
before="$(snapshot)"
run_statusline
after="$(snapshot)"
if [ "$RC" -eq 0 ] && [ "$before" = "$after" ]; then
  pass "24_writes_nothing"
else
  fail "24_writes_nothing" "rc=$RC before=[$before] after=[$after]"
fi

# --- settings.json ---------------------------------------------------------
# statusLine は home-manager が claude-code/bin を symlink する ~/.claude/bin の配置先で指す
cmd="$(jq -r 'select(.statusLine.type == "command") | .statusLine.command' "$SETTINGS")"
# shellcheck disable=SC2088 # settings.json に書いた文字列そのものと比べる
if [ "$cmd" = "~/.claude/bin/health-statusline" ] && [ -x "$STATUSLINE" ]; then
  pass "25_settings_statusline_command"
else
  fail "25_settings_statusline_command" "statusLine.command=[$cmd]"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "PASS: health-statusline"
