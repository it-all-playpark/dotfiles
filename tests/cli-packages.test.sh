#!/usr/bin/env bash
# tests/cli-packages.test.sh
# Unit test for lib/cli-packages.nix via nix eval.
# Run from the repo root: bash tests/cli-packages.test.sh
# Requires: awk, grep (tier-1, always run) / nix (with flakes), jq (tier-2, optional)
#
# tier-1: 静的テキスト検証 (awk/grep のみ, nix daemon 不要, 常時実行)
# tier-2: nix eval 検証 (builtins.getFlake で flake を評価, nix daemon 到達時のみ実行)
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
# tier-1 (1): the (single, host-only) package list must NOT include nodejs*
# (PATH collision guard; Node.js is managed by mise, "node = lts")
#
# NOTE: commit 21b56f2 (hermes repo separation) intentionally removed the
# mode = "host" / "container" split from lib/cli-packages.nix — the
# container-only list (incl. nodejs_24 for the hermes-agent Docker image)
# now lives and evolves independently in the hermes repo. flake.nix's
# hermes-image build target was removed in the same commit, so this repo no
# longer has a "container mode" to test. The former
# static_containerOnly_includes_nodejs_24 assertion is obsolete and removed;
# the PATH-collision regression guard below is preserved against the
# current flat list.
# ---------------------------------------------------------------------------
echo "- static_hostList_excludes_nodejs"
if grep -qE '^ +nodejs' "${REPO_ROOT}/lib/cli-packages.nix"; then
  fail "static_hostList_excludes_nodejs" \
    "'nodejs*' must NOT appear in ${REPO_ROOT}/lib/cli-packages.nix (managed by mise)"
else
  pass "static_hostList_excludes_nodejs"
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
  # -------------------------------------------------------------------------
  # PATH collision guard: the package list must NOT include nodejs
  # (Node.js is managed by mise, "node = lts")
  # -------------------------------------------------------------------------
  echo "- eval_hostList_excludes_nodejs"
  host_pkgs="$(eval_pkg_names || true)"
  if echo "${host_pkgs}" | jq -e 'map(select(startswith("nodejs"))) | length == 0' >/dev/null 2>&1; then
    pass "eval_hostList_excludes_nodejs"
  else
    fail "eval_hostList_excludes_nodejs" \
      "nodejs must NOT appear in cli-packages.nix (managed by mise). Got: ${host_pkgs}"
  fi
  # -------------------------------------------------------------------------
  # AC: package list must include hunk (git diff review TUI)
  # upstream pname is "hunkdiff" (binary is bin/hunk), so use a prefix match.
  # -------------------------------------------------------------------------
  echo "- hostList_includes_hunk"
  if echo "${host_pkgs}" | jq -e 'map(select(startswith("hunk"))) | length > 0' >/dev/null 2>&1; then
    pass "hostList_includes_hunk"
  else
    fail "hostList_includes_hunk" \
      "Expected hunk* in cli-packages.nix, got: ${host_pkgs}"
  fi
else
  skip "eval_hostList_excludes_nodejs" \
    "nix daemon unreachable (sandboxed environment) — run outside sandbox for full verification"
  skip "hostList_includes_hunk" \
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
