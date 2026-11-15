#!/usr/bin/env bash
# tests/openpost.test.sh
# SNS の予約投稿サーバー OpenPost（lib/openpost, home-manager/programs/openpost.nix）を確かめる。
# Run from anywhere: bash tests/openpost.test.sh
# Requires: jq。nix（daemon に届くときだけ。届かなければ tier-2 を skip）
#
# tier-1: openpost-server.sh は Mac Studio（か、マーカーのあるマシン）でだけ server を起動する
#         （偽の scutil / server を使う）
# tier-2: lib/openpost の cli は固定した版の binary（実際に build して version を見る）。
#         server は約 500MB あるので build せず、常駐の定義が指す先だけを見る

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${REPO_ROOT}/home-manager/home/file/openpost/openpost-server.sh"

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
echo ""
echo "--- tier-1: openpost-server.sh ---"

STUB_BIN="${TMPROOT}/bin"
SERVER_DIR="${TMPROOT}/share"
mkdir -p "${STUB_BIN}" "${SERVER_DIR}"

# 偽の scutil: どの名前を聞かれても FAKE_HOST_NAME を返す
cat >"${STUB_BIN}/scutil" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_HOST_NAME}"
EOF
# 偽の server: 起動された cwd を記録して終わる
cat >"${STUB_BIN}/openpost-server" <<'EOF'
#!/usr/bin/env bash
pwd -P >"${SERVER_RAN}"
EOF
chmod +x "${STUB_BIN}/scutil" "${STUB_BIN}/openpost-server"

# run_launcher <host name> <marker path>: server が起動されたら、その cwd を stdout に出す
run_launcher() {
  local ran="${TMPROOT}/ran"
  rm -f "${ran}"
  env PATH="${STUB_BIN}:${PATH}" \
    FAKE_HOST_NAME="$1" \
    SERVER_RAN="${ran}" \
    OPENPOST_SERVER_BIN="${STUB_BIN}/openpost-server" \
    OPENPOST_SERVER_DIR="${SERVER_DIR}" \
    OPENPOST_SERVER_MARKER="$2" \
    bash "${LAUNCHER}" || echo "exit=$?"
  if [ -f "${ran}" ]; then
    cat "${ran}"
  fi
}

want_dir="$(cd "${SERVER_DIR}" && pwd -P)"
touch "${TMPROOT}/marker"

echo "- launcher_starts_server_on_studio"
got="$(run_launcher "Example-Mac-Studio" "${TMPROOT}/no-marker")"
if [ "${got}" = "${want_dir}" ]; then
  pass "launcher_starts_server_on_studio"
else
  fail "launcher_starts_server_on_studio" "got=${got:-<not started>} want=${want_dir}"
fi

echo "- launcher_starts_server_with_marker"
got="$(run_launcher "Example-MacBook" "${TMPROOT}/marker")"
if [ "${got}" = "${want_dir}" ]; then
  pass "launcher_starts_server_with_marker"
else
  fail "launcher_starts_server_with_marker" "got=${got:-<not started>} want=${want_dir}"
fi

# 対象外のマシンでは server を起動せず、agent が再起動しないよう正常終了する
echo "- launcher_exits_cleanly_elsewhere"
got="$(run_launcher "Example-MacBook" "${TMPROOT}/no-marker")"
if [ -z "${got}" ]; then
  pass "launcher_exits_cleanly_elsewhere"
else
  fail "launcher_exits_cleanly_elsewhere" "got=${got}"
fi

echo ""
echo "--- tier-2: lib/openpost / home-manager (nix) ---"

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

  # launchd agent openpost は openpost-server.sh を走らせ、cli と同じ版の server を
  # ~/.local/share/openpost で起動させる。対象外のマシンの正常終了では再起動しない
  echo "- launchd_agent_runs_pinned_server"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"${flake_ref}\";
      hm = flake.homeConfigurations.\"naramotoyuuji-darwin\";
      agent = hm.config.launchd.agents.openpost;
      env = agent.config.EnvironmentVariables;
      openpost = hm.pkgs.callPackage ${REPO_ROOT}/lib/openpost { };
    in {
      inherit (agent) enable;
      inherit (agent.config) RunAtLoad KeepAlive;
      server = env.OPENPOST_SERVER_BIN == \"\${openpost.server}/bin/openpost-server\";
      sameVersion = openpost.server.version == openpost.cli.version;
      dir = env.OPENPOST_SERVER_DIR == \"\${hm.config.home.homeDirectory}/.local/share/openpost\";
      script = hm.pkgs.lib.last agent.config.ProgramArguments;
    }
  " >"${TMPROOT}/agent.json" 2>>"${TMPROOT}/nix.err" || echo '{}' >"${TMPROOT}/agent.json"
  # KeepAlive は評価結果に未設定の項目が null で入るので、設定した 2 つだけを比べる
  got="$(jq -c '{enable, RunAtLoad, KeepAlive: (.KeepAlive | {Crashed, SuccessfulExit}), server, sameVersion, dir}' "${TMPROOT}/agent.json" 2>/dev/null || true)"
  script="$(jq -r '.script // empty' "${TMPROOT}/agent.json")"
  if [ "${got}" = '{"enable":true,"RunAtLoad":true,"KeepAlive":{"Crashed":true,"SuccessfulExit":false},"server":true,"sameVersion":true,"dir":true}' ] &&
    [ -n "${script}" ] && cmp -s "${script}" "${LAUNCHER}"; then
    pass "launchd_agent_runs_pinned_server"
  else
    fail "launchd_agent_runs_pinned_server" "got=${got} script=${script:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
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
