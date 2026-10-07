#!/usr/bin/env bash
# pg-broker のテスト（pg_broker_test.py）を回す。
# 単体テストは Postgres を起動しない。PATH に nix store の Postgres 17 があれば（nix develop）
# 実際に起動する結合テストも走る。Claude の sandbox 内では shmget が EPERM になるので skip される。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/home-manager/home/file/pg-broker"

cd "$SRC_DIR"
if python3 -B -m unittest -v pg_broker_test; then
  echo "PASS: pg-broker"
else
  echo "FAIL: pg-broker" >&2
  exit 1
fi
