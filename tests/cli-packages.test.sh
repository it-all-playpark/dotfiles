#!/usr/bin/env bash
# tests/cli-packages.test.sh
# Unit test for lib/cli-packages.nix via nix eval.
# Run from the repo root: bash tests/cli-packages.test.sh
# Requires: nix (with flakes), jq

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
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
      pkgs = import flake.inputs.nixpkgs {
        system = \"${system}\";
        overlays = [ (_final: _prev: { hunk = flake.inputs.hunk.packages.\"${system}\".default; }) ];
      };
    in
      map (p: p.pname or p.name) (
        import ${REPO_ROOT}/lib/cli-packages.nix { inherit pkgs; mode = \"${mode}\"; }
      )
  " 2>/dev/null
}

echo "=== cli-packages.nix unit tests ==="

# ---------------------------------------------------------------------------
# AC1: container mode must include nodejs_24
# ---------------------------------------------------------------------------
echo "- containerMode_includes_nodejs_24"
container_pkgs="$(eval_pkg_names "container")"
if echo "${container_pkgs}" | jq -e 'map(select(startswith("nodejs"))) | length > 0' >/dev/null 2>&1; then
  pass "containerMode_includes_nodejs_24"
else
  fail "containerMode_includes_nodejs_24" \
    "Expected nodejs* in container mode packages, got: ${container_pkgs}"
fi

# ---------------------------------------------------------------------------
# AC1 supplement: host mode must NOT include nodejs (PATH collision guard)
# ---------------------------------------------------------------------------
echo "- hostMode_unchanged_no_nodejs_in_cli_packages"
host_pkgs="$(eval_pkg_names "host")"
if echo "${host_pkgs}" | jq -e 'map(select(startswith("nodejs"))) | length == 0' >/dev/null 2>&1; then
  pass "hostMode_unchanged_no_nodejs_in_cli_packages"
else
  fail "hostMode_unchanged_no_nodejs_in_cli_packages" \
    "nodejs must NOT appear in host mode (managed by mise). Got: ${host_pkgs}"
fi

# ---------------------------------------------------------------------------
# AC: host mode must include hunk (git diff review TUI)
# upstream pname is "hunkdiff" (binary is bin/hunk), so use a prefix match.
# ---------------------------------------------------------------------------
echo "- hostMode_includes_hunk"
if echo "${host_pkgs}" | jq -e 'map(select(startswith("hunk"))) | length > 0' >/dev/null 2>&1; then
  pass "hostMode_includes_hunk"
else
  fail "hostMode_includes_hunk" \
    "Expected hunk* in host mode packages, got: ${host_pkgs}"
fi

# ---------------------------------------------------------------------------
# AC: container mode must NOT include hunk (host-only, not needed in
# hermes-agent container image)
# ---------------------------------------------------------------------------
echo "- containerMode_excludes_hunk"
if echo "${container_pkgs}" | jq -e 'map(select(startswith("hunk"))) | length == 0' >/dev/null 2>&1; then
  pass "containerMode_excludes_hunk"
else
  fail "containerMode_excludes_hunk" \
    "hunk must NOT appear in container mode (host-only tool). Got: ${container_pkgs}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
