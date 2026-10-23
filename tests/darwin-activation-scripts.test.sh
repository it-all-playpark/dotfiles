#!/usr/bin/env bash
# tests/darwin-activation-scripts.test.sh
# nix-darwin の activate は決まった名前の activation script しか実行しない（modules/system/activation-scripts.nix）。
# 独自の名前（例: activationScripts.pmsetServerConfig）は評価もビルドも通るのに黙って実行されないので、
# darwin/ で定義してよいのは利用者向けの preActivation / extraActivation / postActivation だけにする。
# Run from the repo root: bash tests/darwin-activation-scripts.test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== darwin activation script names ==="
bad="$(grep -rnoE 'activationScripts\.[A-Za-z0-9_]+' "$REPO_ROOT/darwin" --include='*.nix' |
  grep -vE 'activationScripts\.(preActivation|extraActivation|postActivation)$' || true)"
if [ -n "$bad" ]; then
  echo "  FAIL: nix-darwin が実行しない activation script の名前がある（postActivation 等に入れる）"
  printf '        %s\n' "$bad"
  exit 1
fi
echo "  PASS: darwin/ の activation script は実行される名前だけ"
