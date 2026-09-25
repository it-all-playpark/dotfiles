#!/usr/bin/env bash
# jev-broker の単体テスト（jev_broker_test.py）を回す。
# ネットワーク・Keychain・ソケットファイルを使わない。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/home-manager/home/file/jev-broker"

cd "$SRC_DIR"
if python3 -B -m unittest -v jev_broker_test; then
  echo "PASS: jev-broker"
else
  echo "FAIL: jev-broker" >&2
  exit 1
fi
