#!/usr/bin/env bash
# tests/cli-packages.test.sh
# Unit test for lib/cli-packages.nix via nix eval.
# Run from the repo root: bash tests/cli-packages.test.sh
# Requires: awk, grep (tier-1, always run) / nix (with flakes), jq (tier-2, optional)
#
# tier-1: 静的テキスト検証 (awk/grep のみ, nix daemon 不要, 常時実行)
# tier-2: nix eval 検証 (builtins.getFlake で flake を評価, nix daemon 到達時のみ実行)
#
# NOTE: cli-packages.nix は host (開発マシン) 専用の単一リスト構成。
# mode=host/container の分岐は hermes を playpark-llc/hermes へ独立repo化した際
# (commit 21b56f2) に削除され、container 向けパッケージ (nodejs_24 等) は
# hermes 新repo側で独立管理されている。このテストは単一リストの内容のみ検証する。
#
# NOTE: sandbox 等で nix daemon に到達できない環境では tier-2 は SKIP される。
# 完全検証は sandbox 外で実行すること。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
SKIP=0
ERRORS=()

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1: $2")
}

skip() {
  echo "  SKIP: $1 ($2)"
  SKIP=$((SKIP + 1))
}

echo "=== cli-packages.nix unit tests ==="
echo ""
echo "--- tier-1: static text verification (no nix required) ---"

# ---------------------------------------------------------------------------
# tier-1 (1): package list must NOT include nodejs*
# (Node.js は host では mise ("node = lts") で管理。PATH 衝突を避けるため
#  nix パッケージリストには含めない。container 向け nodejs_24 は
#  playpark-llc/hermes 側で独立管理されており、この repo の対象外)
# ---------------------------------------------------------------------------
echo "- static_excludes_nodejs"
if grep -qE '^ +nodejs' "${REPO_ROOT}/lib/cli-packages.nix"; then
  fail "static_excludes_nodejs" \
    "'nodejs*' must NOT appear in ${REPO_ROOT}/lib/cli-packages.nix (managed by mise on host)"
else
  pass "static_excludes_nodejs"
fi

# ---------------------------------------------------------------------------
# tier-1 (2): package list must include hunk (git diff review TUI)
# upstream pname is "hunkdiff" (binary is bin/hunk), so use a prefix match.
# ---------------------------------------------------------------------------
echo "- static_includes_hunk"
if grep -qE '^ +hunk$' "${REPO_ROOT}/lib/cli-packages.nix"; then
  pass "static_includes_hunk"
else
  fail "static_includes_hunk" \
    "Expected 'hunk' in ${REPO_ROOT}/lib/cli-packages.nix"
fi

echo ""
echo "--- tier-2: nix eval verification (requires nix daemon) ---"

# ---------------------------------------------------------------------------
# Helper: evaluate cli-packages.nix and return JSON list of package names
#
# flake の pinned nixpkgs を `builtins.getFlake` 経由で取得することで、
# host の nix-channel 設定 (<nixpkgs>) に依存せず flake.lock と同じ nixpkgs で
# 評価する。これにより CI / 開発環境で評価結果が一致する。
# ---------------------------------------------------------------------------
eval_pkg_names() {
  local system
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null || true)"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"${REPO_ROOT}\";
      pkgs = import flake.inputs.nixpkgs {
        system = \"${system}\";
        overlays = [ (_final: _prev: { hunk = flake.inputs.hunk.packages.\"${system}\".default; }) ];
      };
    in
      map (p: p.pname or p.name) (
        import ${REPO_ROOT}/lib/cli-packages.nix { inherit pkgs; }
      )
  " 2>/dev/null
}

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  NIX_AVAILABLE=1
else
  NIX_AVAILABLE=0
fi

if [ "${NIX_AVAILABLE}" -eq 1 ]; then
  pkgs="$(eval_pkg_names || true)"

  # -------------------------------------------------------------------------
  # package list must NOT include nodejs (PATH collision guard, managed by mise)
  # -------------------------------------------------------------------------
  echo "- eval_excludes_nodejs"
  if echo "${pkgs}" | jq -e 'map(select(startswith("nodejs"))) | length == 0' >/dev/null 2>&1; then
    pass "eval_excludes_nodejs"
  else
    fail "eval_excludes_nodejs" \
      "nodejs must NOT appear in cli-packages.nix (managed by mise). Got: ${pkgs}"
  fi

  # -------------------------------------------------------------------------
  # package list must include hunk (git diff review TUI)
  # upstream pname is "hunkdiff" (binary is bin/hunk), so use a prefix match.
  # -------------------------------------------------------------------------
  echo "- eval_includes_hunk"
  if echo "${pkgs}" | jq -e 'map(select(startswith("hunk"))) | length > 0' >/dev/null 2>&1; then
    pass "eval_includes_hunk"
  else
    fail "eval_includes_hunk" \
      "Expected hunk* in cli-packages.nix packages, got: ${pkgs}"
  fi
else
  skip "eval_excludes_nodejs" \
    "nix daemon unreachable (sandboxed environment) — run outside sandbox for full verification"
  skip "eval_includes_hunk" \
    "nix daemon unreachable (sandboxed environment) — run outside sandbox for full verification"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
