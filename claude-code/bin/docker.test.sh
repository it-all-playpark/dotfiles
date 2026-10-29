#!/usr/bin/env bash
# claude-code/bin/docker.test.sh
# sandbox 内の素の docker を docker-vm に振り分ける shim (bin/docker) のテスト。
#
# Usage: bash claude-code/bin/docker.test.sh
#
# $TMPDIR 配下に一時 HOME を作り、shim dir ($HOME_T/.claude/bin、実運用と同じ位置) から実物の bin/docker を
# symlink して呼ぶ。実体の docker と docker-vm は偽物（どちらが呼ばれたかと argv を 1 行ずつ出し、
# FAKE_EXIT で終わる）。OrbStack の socket は $HOME_T/.orbstack/run/docker.sock に置いた UNIX socket への
# symlink で用意する（socket は sandbox が bind を許す $TMPDIR/sock の下に作る。パス長の上限 104 字も避ける）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/docker"

if [[ ! -x $SHIM ]]; then
  echo "FAIL: shim not executable: $SHIM" >&2
  exit 1
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
TMPDIR_BASE="${TMPDIR_BASE%/}"
TMPROOT="$(mktemp -d "$TMPDIR_BASE/docker-shim-test.XXXXXX")"
mkdir -p "$TMPDIR_BASE/sock"
SOCK_DIR="$(mktemp -d "$TMPDIR_BASE/sock/dkr-XXXXXX")"
trap 'rm -rf "$TMPROOT" "$SOCK_DIR"' EXIT

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

# ---------------------------------------------------------------------------
# fixture
# ---------------------------------------------------------------------------
HOME_T="$TMPROOT/home"
SHIM_BIN="$HOME_T/.claude/bin"
REAL_BIN="$TMPROOT/real-bin"
VM_BIN="$TMPROOT/vm-bin"
VM_EXEC_BIN="$TMPROOT/vm-exec-bin"
LOOP_BIN="$TMPROOT/loop-bin"
UTIL_BIN="$TMPROOT/util-bin"
SOCKET="$HOME_T/.orbstack/run/docker.sock"
mkdir -p "$SHIM_BIN" "$REAL_BIN" "$VM_BIN" "$VM_EXEC_BIN" "$LOOP_BIN" "$UTIL_BIN" "$(dirname "$SOCKET")"

# 実運用と同じ: ~/.claude/bin/docker → claude-code/bin/docker
ln -s "$SHIM" "$SHIM_BIN/docker"

for name in docker docker-vm; do
  dir="$REAL_BIN"
  [ "$name" = docker-vm ] && dir="$VM_BIN"
  cat >"$dir/$name" <<EOF
#!/usr/bin/env bash
echo "called=$name"
for a in "\$@"; do printf 'arg=[%s]\n' "\$a"; done
exit "\${FAKE_EXIT:-0}"
EOF
  chmod +x "$dir/$name"
done

# 本物の docker-vm（sandbox-docker.nix）と同じく、素の docker を --host 付きで exec する docker-vm
cat >"$VM_EXEC_BIN/docker-vm" <<'EOF'
#!/usr/bin/env bash
exec docker --host unix:///vm/docker.sock "$@"
EOF
chmod +x "$VM_EXEC_BIN/docker-vm"

# shim dir の外にある shim 自身（同一 inode）
ln -s "$SHIM" "$LOOP_BIN/docker"

# shim が使う bash（シェバン）/ readlink / dirname だけを置く。ホストの PATH にある実 docker は混ぜない
for cmd in bash readlink dirname; do
  ln -s "$(command -v "$cmd")" "$UTIL_BIN/$cmd"
done

socket_on() {
  rm -f "$SOCKET" "$SOCK_DIR/docker.sock"
  python3 -B -c 'import socket, sys; socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).bind(sys.argv[1])' \
    "$SOCK_DIR/docker.sock"
  ln -s "$SOCK_DIR/docker.sock" "$SOCKET"
}

socket_off() {
  rm -f "$SOCKET" "$SOCK_DIR/docker.sock"
}

# run_shim [args...]
#   RUN_PATH / RUN_ENV (配列) で上書き可。結果は OUT / ERR / RC に入る。
RUN_PATH=""
RUN_ENV=()
reset_run() {
  RUN_PATH="$SHIM_BIN:$VM_BIN:$REAL_BIN:$UTIL_BIN"
  RUN_ENV=()
}
run_shim() {
  set +e
  OUT="$(env -u DOCKER_HOST -u DOCKER_CONTEXT HOME="$HOME_T" PATH="$RUN_PATH" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SHIM_BIN/docker" "$@" 2>"$TMPROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMPROOT/err")"
}

# expect <name> <want rc> <want out>
expect() {
  if [ "$RC" -eq "$2" ] && [ "$OUT" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "rc=$RC out=[$OUT] err=[$ERR]"
  fi
}

echo "=== docker shim tests ==="

# ---------------------------------------------------------------------------
# 1. socket があれば実体の docker に引数をそのまま渡し、終了コードは実体のもの
# ---------------------------------------------------------------------------
socket_on
reset_run
RUN_ENV=(FAKE_EXIT=7)
run_shim build -t "a b" "" .
expect "01_socket_execs_real_docker" 7 "called=docker
arg=[build]
arg=[-t]
arg=[a b]
arg=[]
arg=[.]"

# ---------------------------------------------------------------------------
# 2. socket が無ければ docker-vm に引数をそのまま渡し、終了コードは docker-vm のもの
# ---------------------------------------------------------------------------
socket_off
reset_run
RUN_ENV=(FAKE_EXIT=3)
run_shim run --rm "a b" ""
expect "02_no_socket_execs_docker_vm" 3 "called=docker-vm
arg=[run]
arg=[--rm]
arg=[a b]
arg=[]"

# ---------------------------------------------------------------------------
# 3. socket の位置にあるのが UNIX socket でなければ（普通のファイル）docker-vm
# ---------------------------------------------------------------------------
socket_off
: >"$SOCKET"
reset_run
run_shim ps
expect "03_non_socket_file_execs_docker_vm" 0 "called=docker-vm
arg=[ps]"
rm -f "$SOCKET"

# ---------------------------------------------------------------------------
# 4. socket が無くても、サブコマンドより前の --host / -H / --context / -c は実体に素通し
# ---------------------------------------------------------------------------
socket_off
for args in "--host|unix:///x.sock|ps" "--host=unix:///x.sock|ps" "-H|unix:///x.sock|ps" "-Hunix:///x.sock|ps" \
  "--context|other|ps" "--context=other|ps" "-c|other|ps" "--debug|-l|debug|-H|unix:///x.sock|ps"; do
  IFS='|' read -r -a argv <<<"$args"
  reset_run
  run_shim "${argv[@]}"
  want="called=docker"
  for a in "${argv[@]}"; do want+=$'\n'"arg=[$a]"; done
  expect "04_global_option_passthrough ${argv[*]}" 0 "$want"
done

# ---------------------------------------------------------------------------
# 5. socket が無くても、DOCKER_HOST / DOCKER_CONTEXT があれば実体に素通し
# ---------------------------------------------------------------------------
socket_off
for e in DOCKER_HOST=unix:///x.sock DOCKER_CONTEXT=other; do
  reset_run
  RUN_ENV=("$e")
  run_shim ps
  expect "05_env_passthrough $e" 0 "called=docker
arg=[ps]"
done

# ---------------------------------------------------------------------------
# 6. サブコマンドの後ろの -c / --host はグローバルオプションではない（docker run -c は cpu-shares）
# ---------------------------------------------------------------------------
socket_off
reset_run
run_shim run -c 512 --host x img
expect "06_subcommand_option_goes_to_docker_vm" 0 "called=docker-vm
arg=[run]
arg=[-c]
arg=[512]
arg=[--host]
arg=[x]
arg=[img]"

# ---------------------------------------------------------------------------
# 7. 本物と同じく docker --host … を exec する docker-vm が shim を通っても、VM に戻らず実体に届く
# ---------------------------------------------------------------------------
socket_off
reset_run
RUN_PATH="$SHIM_BIN:$VM_EXEC_BIN:$REAL_BIN:$UTIL_BIN"
run_shim build .
expect "07_docker_vm_reaches_real_docker_once" 0 "called=docker
arg=[--host]
arg=[unix:///vm/docker.sock]
arg=[build]
arg=[.]"

# ---------------------------------------------------------------------------
# 8. 解決した実体が shim 自身（同一 inode）なら exec せず、stderr に出して 0 以外で終わる
# ---------------------------------------------------------------------------
socket_on
reset_run
RUN_PATH="$SHIM_BIN:$LOOP_BIN:$REAL_BIN:$UTIL_BIN"
run_shim ps
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && [[ $ERR == *"shim itself"* ]]; then
  pass "08_resolved_self_refuses"
else
  fail "08_resolved_self_refuses" "rc=$RC out=[$OUT] err=[$ERR]"
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
echo "PASS: docker"
