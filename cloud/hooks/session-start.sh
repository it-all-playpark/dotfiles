#!/usr/bin/env bash
# cloud/hooks/session-start.sh
# SessionStart hook（クラウドセッション用。cloud/settings.jq が settings に足す）:
# docker の socket が無ければ dockerd をバックグラウンドで起動し、socket ができるまで最大 30 秒待つ。
#
# クラウドのコンテナは root で動き、dockerd をそのまま起動できる（Mac の docker-vm の置き換え）。
# 待ちきれなくてもセッションは止めない: 理由を stderr に 1 行出して exit 0 で終わる。
#
# 環境変数:
#   CLAUDE_CODE_REMOTE          クラウドセッションでは true。それ以外では何もしない (exit 0)
#   CLOUD_DOCKER_SOCK           待つ socket（既定 /var/run/docker.sock。テスト用）
#   CLOUD_DOCKERD_WAIT_SECONDS  socket を待つ秒数（既定 30。テスト用）
#   CLOUD_DOCKERD_LOG           dockerd の出力先（既定 /tmp/dockerd.log）

set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

sock="${CLOUD_DOCKER_SOCK:-/var/run/docker.sock}"
wait_seconds="${CLOUD_DOCKERD_WAIT_SECONDS:-30}"
log="${CLOUD_DOCKERD_LOG:-/tmp/dockerd.log}"

[ -S "$sock" ] && exit 0

if ! command -v dockerd >/dev/null 2>&1; then
  echo "cloud session-start: dockerd が PATH に無いので docker は使えない" >&2
  exit 0
fi

# hook の stdin / stdout / stderr を dockerd に引き継がない（引き継ぐと hook が終わっても pipe が閉じない）
nohup dockerd </dev/null >"$log" 2>&1 &

waited=0
while [ "$waited" -lt "$wait_seconds" ]; do
  [ -S "$sock" ] && exit 0
  sleep 1
  waited=$((waited + 1))
done
[ -S "$sock" ] && exit 0

echo "cloud session-start: dockerd を起動したが ${wait_seconds} 秒待っても $sock ができない（ログ: $log）" >&2
exit 0
