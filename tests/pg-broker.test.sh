#!/usr/bin/env bash
# pg-broker のテスト（pg_broker_client_test.py）を回す。
# docker-vm は偽物に差し替える（sandbox-docker VM も Postgres も起動しない）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/home-manager/home/file/pg-broker"

cd "$SRC_DIR"
if python3 -B -m unittest -v pg_broker_client_test; then
  echo "PASS: pg-broker"
else
  echo "FAIL: pg-broker" >&2
  exit 1
fi
