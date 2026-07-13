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
# tier-1 (1): containerOnly list must include nodejs_24
# ---------------------------------------------------------------------------
echo "- static_containerOnly_includes_nodejs_24"
if awk '/^  containerOnly = with pkgs; \[/,/^  \];/' "${REPO_ROOT}/lib/cli-packages.nix" |
  grep -qE '^ +nodejs_24$'; then
  pass "static_containerOnly_includes_nodejs_24"
else
  fail "static_containerOnly_includes_nodejs_24" \
    "Expected 'nodejs_24' inside the containerOnly list in ${REPO_ROOT}/lib/cli-packages.nix"
fi

# ---------------------------------------------------------------------------
# tier-1 (2): common / hostOnly lists must NOT include nodejs*
# (host mode = common ++ hostOnly, so absence in both proves nodejs is
#  excluded from host mode; PATH collision guard, Node.js is managed by mise)
# ---------------------------------------------------------------------------
echo "- static_hostSets_exclude_nodejs"
if awk '/^  common = with pkgs; \[/,/^  \];/' "${REPO_ROOT}/lib/cli-packages.nix" |
  grep -qE '^ +nodejs'; then
  fail "static_hostSets_exclude_nodejs" \
    "'nodejs*' must NOT appear in the common list of ${REPO_ROOT}/lib/cli-packages.nix"
elif awk '/^  hostOnly = with pkgs; \[/,/^  \];/' "${REPO_ROOT}/lib/cli-packages.nix" |
  grep -qE '^ +nodejs'; then
  fail "static_hostSets_exclude_nodejs" \
    "'nodejs*' must NOT appear in the hostOnly list of ${REPO_ROOT}/lib/cli-packages.nix"
else
  pass "static_hostSets_exclude_nodejs"
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
  local mode="$1"
  local system
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"${REPO_ROOT}\";
      pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
    in
      map (p: p.pname or p.name) (
        import ${REPO_ROOT}/lib/cli-packages.nix { inherit pkgs; mode = \"${mode}\"; }
      )
  " 2>/dev/null
}

if nix store info >/dev/null 2>&1; then
  NIX_AVAILABLE=1
else
  NIX_AVAILABLE=0
fi

if [ "${NIX_AVAILABLE}" -eq 1 ]; then
  # -------------------------------------------------------------------------
  # AC1: container mode must include nodejs_24
  # -------------------------------------------------------------------------
  echo "- eval_containerMode_includes_nodejs_24"
  container_pkgs="$(eval_pkg_names "container")"
  if echo "${container_pkgs}" | jq -e 'map(select(startswith("nodejs"))) | length > 0' >/dev/null 2>&1; then
    pass "eval_containerMode_includes_nodejs_24"
  else
    fail "eval_containerMode_includes_nodejs_24" \
      "Expected nodejs* in container mode packages, got: ${container_pkgs}"
  fi

  # -------------------------------------------------------------------------
  # AC1 supplement: host mode must NOT include nodejs (PATH collision guard)
  # -------------------------------------------------------------------------
  echo "- eval_hostMode_unchanged_no_nodejs_in_cli_packages"
  host_pkgs="$(eval_pkg_names "host")"
  if echo "${host_pkgs}" | jq -e 'map(select(startswith("nodejs"))) | length == 0' >/dev/null 2>&1; then
    pass "eval_hostMode_unchanged_no_nodejs_in_cli_packages"
  else
    fail "eval_hostMode_unchanged_no_nodejs_in_cli_packages" \
      "nodejs must NOT appear in host mode (managed by mise). Got: ${host_pkgs}"
  fi
else
  skip "eval_containerMode_includes_nodejs_24" \
    "nix daemon unreachable (sandboxed environment) — run outside sandbox for full verification"
  skip "eval_hostMode_unchanged_no_nodejs_in_cli_packages" \
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
