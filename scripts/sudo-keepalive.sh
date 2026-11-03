#!/usr/bin/env bash
# sudo の認証をここで 1 回だけ求め、呼び出し元のプロセスが終わるまで裏で sudo の有効期間を延ばし続ける。
# nix run .#update から呼ぶ。update は linux-builder VM の起動・停止（scripts/with-linux-builder.sh）と
# nix-darwin の switch で sudo を使い、間の build 検証が sudo の有効期間（既定 5 分）を超えると
# 途中で何度も認証を求められ、席を離れると止まったままになる。
# 延長は呼び出し元が終わると SUDO_KEEPALIVE_INTERVAL 秒（既定 10）以内に止まる。
# usage: bash scripts/sudo-keepalive.sh   （認証に失敗したら非 0）

set -euo pipefail

INTERVAL="${SUDO_KEEPALIVE_INTERVAL:-10}"
PARENT="$PPID"

sudo -v

# 出力をすべて閉じる: 呼び出し元のパイプやコマンド置換を延長のプロセスが握ったままにしない
(
  while kill -0 "$PARENT" 2>/dev/null; do
    sudo -n -v || exit 0
    sleep "$INTERVAL"
  done
) </dev/null >/dev/null 2>&1 &
