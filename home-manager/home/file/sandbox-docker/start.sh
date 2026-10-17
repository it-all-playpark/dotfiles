#!/usr/bin/env bash
# launchd agent sandbox-docker（home-manager/programs/sandbox-docker.nix）がログイン時に走らせる。
# VM sandbox-docker が無ければ SANDBOX_DOCKER_YAML（lima.yaml）から作って起動し、あれば起動する。
# LIMACTL はパッチ版 Lima（lib/lima-sandbox）の limactl。素の Lima は VM から Mac・LAN に届く。
# 作った後の lima.yaml の変更は既存の VM に効かない（limactl delete sandbox-docker してから作り直す）
set -euo pipefail

name=sandbox-docker

# list を grep に直接つなぐと grep -q が先に閉じて limactl が SIGPIPE で落ち、pipefail で「無い」扱いになる
names="$("${LIMACTL}" list --quiet)"
if ! grep -qxF "${name}" <<<"${names}"; then
  "${LIMACTL}" create --tty=false --name="${name}" "${SANDBOX_DOCKER_YAML}"
fi
exec "${LIMACTL}" start --tty=false "${name}"
