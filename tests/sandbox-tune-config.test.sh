#!/usr/bin/env bash
# tests/sandbox-tune-config.test.sh
# sandbox-tune.json の intended（sandbox-tune が remaining・recurring から外す意図した拒否・実行）を検証する。
#   - 各項目は id か kind のどちらか一方と、空でない reason を持つ（sandbox-tune の config が受け付ける形）
#   - RULES の Git 節どおりの host-exec の dotfiles-sync は型の id で intended にする。
#     kind（host_exec 全体）で書くと、直すべきほかの host-exec の実行まで remaining から消える
# Run from the repo root: bash tests/sandbox-tune-config.test.sh
# Requires: jq

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/sandbox-tune.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

echo "=== sandbox-tune.json intended tests ==="

FAILED=0

check() {
  local name="$1" filter="$2"
  if jq -e "${filter}" "${CONFIG}" >/dev/null; then
    echo "  PASS: ${name}"
  else
    echo "  FAIL: ${name}"
    FAILED=1
  fi
}

check "intended の各項目は id か kind の一方と空でない reason を持つ" \
  '.intended | length > 0 and all(.[]; ((has("id")) != (has("kind"))) and (.reason | type == "string" and length > 0))'

check "host-exec の dotfiles-sync を id で intended にしている" \
  '.intended[] | select(.id == "host_exec:ran:dotfiles-sync") | .reason | length > 0'

check "host_exec を kind で intended にしない" \
  '[.intended[] | select(.kind == "host_exec")] | length == 0'

if [ "${FAILED}" -ne 0 ]; then
  echo "FAIL: sandbox-tune-config"
  exit 1
fi
echo "PASS: sandbox-tune-config"
