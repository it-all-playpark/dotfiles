#!/usr/bin/env bash
# 引数のコマンドを linux-builder VM が動いている状態で実行し、その終了コードを返す。
# nix run .#update の build 検証から呼ぶ。nixpkgs が上がると linux-builder VM 自体の
# aarch64-linux derivation（boot.json・nix.conf 等）を作り直す必要があり、それは VM の中でしか build できない。
# VM は常駐させていない（darwin/nix.nix）ので、止まっていればここで起動し、終了時（失敗・Ctrl-C を含む）に止める。
# 実行前から動いていた VM（人が Linux 向け build のために起動したもの）には触らない。
# usage: with-linux-builder.sh <command> [args...]

set -uo pipefail

LABEL=system/org.nixos.linux-builder
PORT=31022
WAIT_SECS="${LINUX_BUILDER_WAIT_SECS:-120}"

if [ "$#" -eq 0 ]; then
  echo "usage: with-linux-builder.sh <command> [args...]" >&2
  exit 2
fi

ssh_ready() {
  [ -n "$(ssh-keyscan -T 2 -p "$PORT" localhost 2>/dev/null)" ]
}

# linux-builder を入れていない環境はそのまま実行する
if ! launchctl print "$LABEL" >/dev/null 2>&1; then
  exec "$@"
fi

# 既に動いている（起動途中を含む）VM は自分のものではないので、起動も停止もしない
if launchctl print "$LABEL" 2>/dev/null | grep -q $'^\tstate = running$' || ssh_ready; then
  exec "$@"
fi

echo "Starting linux-builder VM for the build (sudo)..."
if ! sudo launchctl kickstart "$LABEL"; then
  echo "WARNING: linux-builder VM を起動できなかった。VM なしで続ける（Linux 向けの build は失敗する）" >&2
  exec "$@"
fi

# shellcheck disable=SC2329 # 下の trap から呼ぶ
stop_builder() {
  echo "Stopping linux-builder VM (sudo)..."
  sudo launchctl kill TERM "$LABEL" ||
    echo "WARNING: linux-builder VM を止められなかった。手で止める: sudo launchctl kill TERM $LABEL" >&2
}
# shellcheck disable=SC2329 # 下の trap から呼ぶ
# 中断のシグナルでは VM を止めてから同じシグナルで自分を終える。exit 130 のように通常終了すると、
# 呼び出し元の bash は子がシグナルで死んでいないと判断して後続（switch 等）に進んでしまう
die_by_signal() {
  trap - EXIT INT TERM
  stop_builder
  kill -s "$1" "$$"
}
trap stop_builder EXIT
trap 'die_by_signal INT' INT
trap 'die_by_signal TERM' TERM

deadline=$((SECONDS + WAIT_SECS))
until ssh_ready; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "WARNING: linux-builder VM が ${WAIT_SECS} 秒以内に SSH を受け付けなかった。そのまま続ける" >&2
    break
  fi
  sleep 2
done

rc=0
"$@" || rc=$?
exit "$rc"
