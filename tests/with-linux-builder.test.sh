#!/usr/bin/env bash
# scripts/with-linux-builder.sh の検証。launchctl / sudo / ssh-keyscan を stub にして、
# 止まっていた VM は起動して終了時（失敗・中断を含む）に止め、終了コードを返すこと、
# 既に動いていた VM と linux-builder の無い環境では起動も停止もしないことを確かめる。
# Run from the repo root: bash tests/with-linux-builder.test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/with-linux-builder.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/with-linux-builder-test.XXXXXX")"
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

# stub の状態: $STUB/state（running / stopped / absent）、$STUB/ready があれば SSH を受け付ける。
# sudo は引数を $STUB/sudo.log に残してそのまま実行する。KICKSTART_NO_SSH=1 なら起動しても SSH は開かない
STUB="$TMPROOT/stub"
mkdir -p "$TMPROOT/bin" "$STUB"
cat >"$TMPROOT/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
state="$(cat "$STUB/state")"
case "$1" in
  print)
    [ "$state" = absent ] && exit 113
    printf 'system/org.nixos.linux-builder = {\n\tstate = %s\n\tjob state = x\n}\n' "$state" ;;
  kickstart)
    echo running >"$STUB/state"
    [ -n "${KICKSTART_NO_SSH:-}" ] || touch "$STUB/ready" ;;
  kill)
    echo "not running" >"$STUB/state"
    rm -f "$STUB/ready" ;;
esac
EOF
cat >"$TMPROOT/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB/sudo.log"
exec "$@"
EOF
cat >"$TMPROOT/bin/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
[ -e "$STUB/ready" ] && echo "[localhost]:31022 ssh-ed25519 AAAA"
exit 0
EOF
chmod +x "$TMPROOT/bin/"*
export PATH="$TMPROOT/bin:$PATH" STUB

# reset <state> [ready]: stub の状態を作り直す
reset() {
  echo "$1" >"$STUB/state"
  rm -f "$STUB/ready" "$STUB/sudo.log" "$STUB/cmd.log"
  : >"$STUB/sudo.log"
  [ "${2:-}" != ready ] || touch "$STUB/ready"
}

# run <args...>: script を走らせ、終了コードを RC、出力を OUT に入れる
run() {
  set +e
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  set -e
}

final_state() { cat "$STUB/state"; }
sudo_log() { tr '\n' ';' <"$STUB/sudo.log"; }

echo "=== with-linux-builder tests ==="
echo ""

echo "- stopped_vm_is_started_for_command_and_stopped_after"
reset "not running"
# コマンドの実行中に SSH を受け付ける VM が動いていたことを記録させる
run bash -c 'cat "$STUB/state" >"$STUB/cmd.log"; [ -e "$STUB/ready" ] && echo ready >>"$STUB/cmd.log"'
if [ "$RC" -eq 0 ] && [ "$(tr '\n' ' ' <"$STUB/cmd.log")" = "running ready " ] &&
  [ "$(final_state)" = "not running" ] &&
  [ "$(sudo_log)" = "launchctl kickstart system/org.nixos.linux-builder;launchctl kill TERM system/org.nixos.linux-builder;" ]; then
  pass "stopped_vm_is_started_for_command_and_stopped_after"
else
  fail "stopped_vm_is_started_for_command_and_stopped_after" "rc=$RC cmd=$(cat "$STUB/cmd.log" 2>/dev/null) state=$(final_state) sudo=$(sudo_log) out=$OUT"
fi

echo "- command_failure_still_stops_vm_and_keeps_exit_code"
reset "not running"
run bash -c 'exit 7'
if [ "$RC" -eq 7 ] && [ "$(final_state)" = "not running" ] && [[ "$(sudo_log)" == *"launchctl kill TERM"* ]]; then
  pass "command_failure_still_stops_vm_and_keeps_exit_code"
else
  fail "command_failure_still_stops_vm_and_keeps_exit_code" "rc=$RC state=$(final_state) sudo=$(sudo_log) out=$OUT"
fi

echo "- interrupt_still_stops_vm"
reset "not running"
# 子から親（script）に SIGINT を送り、Ctrl-C で中断された状況を作る。
# run-all.sh はテストを & で走らせるので SIGINT が無視された状態で始まり、bash はそれに trap を張れない。
# 端末から前面で動く update と同じ条件にするため、perl で SIGINT を既定に戻してから script を起動する
set +e
OUT="$(perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' bash "$SCRIPT" bash -c 'kill -INT $PPID; sleep 0.2' 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 130 ] && [ "$(final_state)" = "not running" ] && [[ "$(sudo_log)" == *"launchctl kill TERM"* ]]; then
  pass "interrupt_still_stops_vm"
else
  fail "interrupt_still_stops_vm" "rc=$RC state=$(final_state) sudo=$(sudo_log) out=$OUT"
fi

echo "- running_vm_is_left_alone"
reset running ready
run bash -c 'exit 0'
if [ "$RC" -eq 0 ] && [ "$(final_state)" = running ] && [ ! -s "$STUB/sudo.log" ]; then
  pass "running_vm_is_left_alone"
else
  fail "running_vm_is_left_alone" "rc=$RC state=$(final_state) sudo=$(sudo_log) out=$OUT"
fi

echo "- vm_outside_launchd_answering_ssh_is_left_alone"
reset "not running" ready
run bash -c 'exit 0'
if [ "$RC" -eq 0 ] && [ ! -s "$STUB/sudo.log" ]; then
  pass "vm_outside_launchd_answering_ssh_is_left_alone"
else
  fail "vm_outside_launchd_answering_ssh_is_left_alone" "rc=$RC sudo=$(sudo_log) out=$OUT"
fi

echo "- no_linux_builder_runs_command_without_sudo"
reset absent
run bash -c 'exit 3'
if [ "$RC" -eq 3 ] && [ ! -s "$STUB/sudo.log" ]; then
  pass "no_linux_builder_runs_command_without_sudo"
else
  fail "no_linux_builder_runs_command_without_sudo" "rc=$RC sudo=$(sudo_log) out=$OUT"
fi

echo "- ssh_timeout_runs_command_and_stops_vm"
reset "not running"
KICKSTART_NO_SSH=1 LINUX_BUILDER_WAIT_SECS=0 run bash -c 'exit 0'
if [ "$RC" -eq 0 ] && [ "$(final_state)" = "not running" ] && [[ $OUT == *"SSH を受け付けなかった"* ]]; then
  pass "ssh_timeout_runs_command_and_stops_vm"
else
  fail "ssh_timeout_runs_command_and_stops_vm" "rc=$RC state=$(final_state) out=$OUT"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  printf '  %s\n' "${ERRORS[@]}"
  exit 1
fi
