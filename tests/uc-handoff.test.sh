#!/usr/bin/env bash
# uc-handoff の純粋関数を --self-test 経由で検証する。
# GUI もアクセシビリティ権限も不要。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/home-manager/home/file/uc-handoff/uc-handoff.c"
BIN="$(mktemp -d)/uc-handoff"

trap 'rm -rf "$(dirname "$BIN")"' EXIT

cc -O2 -Wall -Wextra -Werror \
  -framework ApplicationServices \
  -o "$BIN" "$SRC"

if "$BIN" --self-test; then
  echo "PASS: uc-handoff --self-test"
else
  echo "FAIL: uc-handoff --self-test" >&2
  exit 1
fi
