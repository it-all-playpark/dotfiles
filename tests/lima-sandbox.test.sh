#!/usr/bin/env bash
# tests/lima-sandbox.test.sh
# lib/lima-sandbox（VM から Mac・LAN に届かないパッチ版 Lima）を build して確かめる。
# Run from anywhere: bash tests/lima-sandbox.test.sh
# Requires: nix（daemon に届くときだけ。届かなければ skip）
#
# denied() の判定表（deny_test.go）は build の checkPhase で走り、外れたら build が落ちる。
# ここでは build した limactl の実体（wrapper の先）に deny.go が入っていることと、
# version が nixpkgs の lima と同じこと（自前の src にしていない）、home.packages に素の lima でなく
# パッチ版が入ることを見る

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GO="${REPO_ROOT}/lib/lima-sandbox/deny.go"

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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/lima-sandbox-test.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

echo "=== lima-sandbox tests ==="
echo ""
echo "--- lib/lima-sandbox (tier-2: nix build) ---"

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
else
  system=""
fi

if [ "${system}" != "aarch64-darwin" ]; then
  skip "binary_contains_deny_cidrs" "nix daemon unreachable or not aarch64-darwin"
  skip "version_matches_nixpkgs_lima" "nix daemon unreachable or not aarch64-darwin"
  skip "home_packages_use_patched_lima" "nix daemon unreachable or not aarch64-darwin"
else
  pkgs_expr="import (builtins.getFlake \"${REPO_ROOT}\").inputs.nixpkgs { system = \"${system}\"; }"
  out="$(nix build --no-link --print-out-paths --impure --expr "
    let pkgs = ${pkgs_expr}; in pkgs.callPackage ${REPO_ROOT}/lib/lima-sandbox { }
  " 2>"${TMPROOT}/nix.err" || true)"
  # bin/limactl は makeWrapper の shell script。exec する先が go の binary
  wrapped=""
  if [ -n "${out}" ] && [ -f "${out}/bin/limactl" ]; then
    # shellcheck disable=SC2016 # 意図的: wrapper のソース上の "$0" を文字列として拾う
    wrapped="$(sed -n 's/^exec -a "\$0" "\([^"]*\)".*/\1/p' "${out}/bin/limactl")"
  fi

  # -------------------------------------------------------------------------
  # binary_contains_deny_cidrs: deny.go の CIDR がすべて limactl の実体に入っている
  # （素の lima には 169.254.0.0/16 以外が無い。forwarder に deny.go が入らなければ落ちる）
  # -------------------------------------------------------------------------
  echo "- binary_contains_deny_cidrs"
  grep -oE '"[0-9.]+/[0-9]+"' "${DENY_GO}" | tr -d '"' >"${TMPROOT}/cidrs"
  missing=""
  if [ -n "${wrapped}" ] && [ -f "${wrapped}" ]; then
    while IFS= read -r cidr; do
      grep -qaF -- "${cidr}" "${wrapped}" || missing="${missing} ${cidr}"
    done <"${TMPROOT}/cidrs"
  fi
  if [ -n "${wrapped}" ] && [ -f "${wrapped}" ] && [ "$(wc -l <"${TMPROOT}/cidrs")" -ge 11 ] && [ -z "${missing}" ]; then
    pass "binary_contains_deny_cidrs"
  else
    fail "binary_contains_deny_cidrs" "wrapped=${wrapped:-<none>} missing:${missing} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  # -------------------------------------------------------------------------
  # version_matches_nixpkgs_lima: limactl --version が nixpkgs の lima の version を返す
  # -------------------------------------------------------------------------
  echo "- version_matches_nixpkgs_lima"
  expected="$(nix eval --impure --raw --expr "(${pkgs_expr}).lima.version" 2>>"${TMPROOT}/nix.err" || true)"
  version="$([ -n "${out}" ] && HOME="${TMPROOT}" "${out}/bin/limactl" --version 2>/dev/null || true)"
  if [ -n "${expected}" ] && [ "${version}" = "limactl version ${expected}" ]; then
    pass "version_matches_nixpkgs_lima"
  else
    fail "version_matches_nixpkgs_lima" "version=${version:-<none>} expected=limactl version ${expected:-<none>}"
  fi

  # -------------------------------------------------------------------------
  # home_packages_use_patched_lima: darwin の home.packages にパッチ版が入り、素の pkgs.lima は入らない
  # （getFlake で評価するので、untracked の新規ファイルは git add してから走らせる）
  # -------------------------------------------------------------------------
  echo "- home_packages_use_patched_lima"
  hm="$(nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"${REPO_ROOT}\";
      hm = flake.homeConfigurations.\"naramotoyuuji-darwin\";
      drvs = map (p: p.drvPath) hm.config.home.packages;
    in {
      patched = builtins.elem (hm.pkgs.callPackage ${REPO_ROOT}/lib/lima-sandbox { }).drvPath drvs;
      plain = builtins.elem hm.pkgs.lima.drvPath drvs;
    }
  " 2>>"${TMPROOT}/nix.err" || true)"
  if [ "${hm}" = '{"patched":true,"plain":false}' ]; then
    pass "home_packages_use_patched_lima"
  else
    fail "home_packages_use_patched_lima" "got=${hm:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
echo "PASS: lima-sandbox"
