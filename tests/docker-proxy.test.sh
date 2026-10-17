#!/usr/bin/env bash
# docker-proxy のテスト（docker_proxy_test.py）を回す。
# 実 docker は使わない。上流の docker.sock は一時ディレクトリの Unix ソケットのスタブが受ける。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/home-manager/home/file/docker-proxy"

cd "$SRC_DIR"
if python3 -B -m unittest -v docker_proxy_test; then
  echo "PASS: docker-proxy"
else
  echo "FAIL: docker-proxy" >&2
  exit 1
fi
