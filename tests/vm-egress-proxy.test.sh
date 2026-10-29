#!/usr/bin/env bash
# tests/vm-egress-proxy.test.sh
# VM sandbox-docker の外向き通信の出口 vm-egress-proxy（home-manager/programs/vm-egress-proxy.nix）を確かめる。
# Run from anywhere: bash tests/vm-egress-proxy.test.sh
# Requires: python3, jq。nix（daemon に届くときだけ。届かなければ tier-2 を skip）
#
# tier-1: プロキシのユニットテスト（vm_egress_proxy_test.py。外には繋がない）
# tier-2: 許可リストの生成（allowlist.nix）と launchd agent の評価結果

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${REPO_ROOT}/home-manager/home/file/vm-egress-proxy"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"

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

# TMPROOT は nix の式にパスとして埋め込む。macOS の TMPDIR は末尾が / なので、そのまま繋ぐと
# `T//vm-egress-proxy-test…` になり、nix のパスとして読めずに構文エラーになる。末尾の / を落とす
tmpbase="${TMPDIR:-/tmp}"
TMPROOT="$(mktemp -d "${tmpbase%/}/vm-egress-proxy-test.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

echo "=== vm-egress-proxy tests ==="
echo ""
echo "--- tier-1: vm_egress_proxy_test.py ---"

echo "- proxy_unit_tests"
if (cd "${SRC_DIR}" && python3 -B -m unittest -v vm_egress_proxy_test) >"${TMPROOT}/unit.log" 2>&1; then
  pass "proxy_unit_tests"
else
  fail "proxy_unit_tests" "$(tail -n 20 "${TMPROOT}/unit.log")"
fi

echo ""
echo "--- tier-2: allowlist.nix / home-manager (nix) ---"

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
else
  system=""
fi

if [ "${system}" != "aarch64-darwin" ]; then
  skip "allowlist_follows_settings_allowed_domains" "nix daemon unreachable or not aarch64-darwin"
  skip "launchd_agent_uses_generated_allowlist" "nix daemon unreachable or not aarch64-darwin"
else
  # path: で評価する（git の flake は untracked の新規ファイルを見ないので、commit 前でも走るように）
  flake_ref="path:${REPO_ROOT}"
  pkgs_expr="import (builtins.getFlake \"${flake_ref}\").inputs.nixpkgs { system = \"${system}\"; }"

  # ---------------------------------------------------------------------------
  # allowlist_follows_settings_allowed_domains: 許可リストは settings.json の allowedDomains と
  # vm-domains.txt（コメント・空行を除く）の和。settings.json にドメインを足すと生成結果に入る。
  # settings.json の写しに 1 件足して allowlist.nix に渡し、build した中身を比べる
  # ---------------------------------------------------------------------------
  echo "- allowlist_follows_settings_allowed_domains"
  added="vm-egress-test-added.example"
  jq --arg d "${added}" '.sandbox.network.allowedDomains += [$d]' "${SETTINGS}" >"${TMPROOT}/settings.json"
  out="$(nix build --no-link --print-out-paths --impure --expr "
    let pkgs = ${pkgs_expr}; in import ${SRC_DIR}/allowlist.nix {
      inherit (pkgs) lib writeText;
      settingsJson = ${TMPROOT}/settings.json;
    }
  " 2>"${TMPROOT}/nix.err" || true)"
  {
    jq -r '.sandbox.network.allowedDomains[]' "${TMPROOT}/settings.json"
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "${SRC_DIR}/vm-domains.txt" | grep -v '^$'
  } | awk '!seen[$0]++' >"${TMPROOT}/want"
  if [ -n "${out}" ] && [ -f "${out}" ] && grep -qxF "${added}" "${out}" &&
    diff -u "${TMPROOT}/want" "${out}" >"${TMPROOT}/diff"; then
    pass "allowlist_follows_settings_allowed_domains"
  else
    fail "allowlist_follows_settings_allowed_domains" "out=${out:-<none>} diff=$(head -n 20 "${TMPROOT}/diff" 2>/dev/null) err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  # ---------------------------------------------------------------------------
  # launchd_agent_uses_generated_allowlist: launchd agent vm-egress-proxy は常駐し、許可リストは
  # repo の settings.json と vm-domains.txt から生成したもの、ソケットは ~/.local/state/vm-egress-proxy/proxy.sock、
  # 走らせるのは vm_egress_proxy.py
  # ---------------------------------------------------------------------------
  echo "- launchd_agent_uses_generated_allowlist"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"${flake_ref}\";
      hm = flake.homeConfigurations.\"naramotoyuuji-darwin\";
      agent = hm.config.launchd.agents.vm-egress-proxy;
      env = agent.config.EnvironmentVariables;
      allowlist = import ${SRC_DIR}/allowlist.nix { inherit (hm.pkgs) lib writeText; };
    in {
      inherit (agent) enable;
      inherit (agent.config) RunAtLoad KeepAlive;
      generated = env.VM_EGRESS_PROXY_ALLOWLIST == \"\${allowlist}\";
      socket = env.VM_EGRESS_PROXY_SOCKET == \"\${hm.config.home.homeDirectory}/.local/state/vm-egress-proxy/proxy.sock\";
      script = hm.pkgs.lib.last agent.config.ProgramArguments;
    }
  " >"${TMPROOT}/agent.json" 2>>"${TMPROOT}/nix.err" || echo '{}' >"${TMPROOT}/agent.json"
  got="$(jq -c '{enable, RunAtLoad, KeepAlive, generated, socket}' "${TMPROOT}/agent.json")"
  script="$(jq -r '.script // empty' "${TMPROOT}/agent.json")"
  if [ "${got}" = '{"enable":true,"RunAtLoad":true,"KeepAlive":true,"generated":true,"socket":true}' ] &&
    [ -n "${script}" ] && cmp -s "${script}" "${SRC_DIR}/vm_egress_proxy.py"; then
    pass "launchd_agent_uses_generated_allowlist"
  else
    fail "launchd_agent_uses_generated_allowlist" "got=${got} script=${script:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
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
echo "PASS: vm-egress-proxy"
