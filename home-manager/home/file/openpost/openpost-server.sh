#!/usr/bin/env bash
# OpenPost の server を、24/7 稼働のサーバー機（Mac Studio）でだけ起動する。
# launchd agent openpost（home-manager/programs/openpost.nix）から呼ばれる。
#
# nix の設定は全マシンで共有なので、対象かどうかは darwin/remote-access.nix と同じ基準で実行時に決める:
# LocalHostName / ComputerName に Studio を含むか、マーカー OPENPOST_SERVER_MARKER がある。
# 対象外のマシンでは何もせず exit 0 する（agent の KeepAlive は正常終了では再起動しない）。
#
# 必須の環境変数:
#   OPENPOST_SERVER_BIN     server の binary
#   OPENPOST_SERVER_DIR     .env と DB を置くディレクトリ（server は cwd の .env を読む）
#   OPENPOST_SERVER_MARKER  対象を明示するマーカーファイル
set -euo pipefail

: "${OPENPOST_SERVER_BIN:?}"
: "${OPENPOST_SERVER_DIR:?}"
: "${OPENPOST_SERVER_MARKER:?}"

server_enabled() {
  if [ -f "${OPENPOST_SERVER_MARKER}" ]; then
    return 0
  fi
  case "$(scutil --get LocalHostName 2>/dev/null || true) $(scutil --get ComputerName 2>/dev/null || true)" in
  *Studio*) return 0 ;;
  *) return 1 ;;
  esac
}

if ! server_enabled; then
  exit 0
fi

cd "${OPENPOST_SERVER_DIR}"
exec "${OPENPOST_SERVER_BIN}"
