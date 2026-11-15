#!/usr/bin/env bash
# tests/openpost.test.sh
# SNS の予約投稿サーバー OpenPost（lib/openpost, home-manager/programs/openpost.nix）を確かめる。
# Run from anywhere: bash tests/openpost.test.sh
# Requires: jq。nix（daemon に届くときだけ。届かなければ skip）
#
# - lib/openpost: cli は固定した版の binary（実際に build して version を見る）。
#   server は約 500MB あるので build せず、常駐の定義が指す先だけを見る
# - launchd agent openpost: 常駐し、cli と同じ版の server を、.env と DB を置く
#   ~/.local/share/openpost で起動する

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

tmpbase="${TMPDIR:-/tmp}"
TMPROOT="$(mktemp -d "${tmpbase%/}/openpost-test.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

echo "=== openpost tests ==="

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
else
  system=""
fi

if [ "${system}" != "aarch64-darwin" ]; then
  skip "cli_is_pinned_version" "nix daemon unreachable or not aarch64-darwin"
  skip "launchd_agent_runs_pinned_server" "nix daemon unreachable or not aarch64-darwin"
else
  # path: で評価する（git の flake は untracked の新規ファイルを見ないので、commit 前でも走るように）
  flake_ref="path:${REPO_ROOT}"

  echo "- cli_is_pinned_version"
  out="$(nix build --no-link --print-out-paths --impure --expr "
    let
      flake = builtins.getFlake \"${flake_ref}\";
      pkgs = import flake.inputs.nixpkgs { system = \"${system}\"; };
    in
      (pkgs.callPackage ${REPO_ROOT}/lib/openpost { }).cli
  " 2>"${TMPROOT}/nix.err" || true)"
  # version は stderr に出る
  version="$([ -n "${out}" ] && "${out}/bin/openpost" version 2>&1 | head -n 1 || true)"
  if [ "${version}" = "v7.41.6" ]; then
    pass "cli_is_pinned_version"
  else
    fail "cli_is_pinned_version" "version=${version:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  echo "- launchd_agent_runs_pinned_server"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"${flake_ref}\";
      hm = flake.homeConfigurations.\"naramotoyuuji-darwin\";
      agent = hm.config.launchd.agents.openpost;
      openpost = hm.pkgs.callPackage ${REPO_ROOT}/lib/openpost { };
    in {
      inherit (agent) enable;
      inherit (agent.config) RunAtLoad KeepAlive;
      program = agent.config.ProgramArguments == [ \"\${openpost.server}/bin/openpost-server\" ];
      sameVersion = openpost.server.version == openpost.cli.version;
      workdir = agent.config.WorkingDirectory == \"\${hm.config.home.homeDirectory}/.local/share/openpost\";
    }
  " >"${TMPROOT}/agent.json" 2>>"${TMPROOT}/nix.err" || echo '{}' >"${TMPROOT}/agent.json"
  got="$(jq -c '{enable, RunAtLoad, KeepAlive, program, sameVersion, workdir}' "${TMPROOT}/agent.json")"
  if [ "${got}" = '{"enable":true,"RunAtLoad":true,"KeepAlive":true,"program":true,"sameVersion":true,"workdir":true}' ]; then
    pass "launchd_agent_runs_pinned_server"
  else
    fail "launchd_agent_runs_pinned_server" "got=${got} err=$(tail -n 3 "${TMPROOT}/nix.err")"
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
echo "PASS: openpost"
