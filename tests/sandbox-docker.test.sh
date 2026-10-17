#!/usr/bin/env bash
# tests/sandbox-docker.test.sh
# VM sandbox-docker（home-manager/home/file/sandbox-docker/lima.yaml・home-manager/programs/sandbox-docker.nix）を
# VM を起動せずに確かめる。
# Run from anywhere: bash tests/sandbox-docker.test.sh
# Requires: jq, yq（mikefarah/yq）。nix（daemon に届くときだけ。届かなければ tier-2 を skip）
#
# tier-1: lima.yaml の定義、claude-code/settings.json の allowUnixSockets / allowedDomains、RULES.md の docker-vm、start.sh（偽の limactl で動かす）
# tier-2: パッチ版 limactl の template copy --fill で展開した mounts / portForwards、
#         Lima の docker template との手順の突き合わせ、home-manager の評価結果（launchd agent・docker-vm・image）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${REPO_ROOT}/home-manager/home/file/sandbox-docker"
LIMA_YAML="${SRC_DIR}/lima.yaml"
START_SH="${SRC_DIR}/start.sh"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"
# shellcheck disable=SC2088 # 意図的: settings.json には ~/ のまま書く（Claude Code が展開する）
VM_SOCKET="~/.lima/sandbox-docker/sock/docker.sock"

for cmd in jq yq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "${cmd} required" >&2
    exit 1
  fi
done

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

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-docker-test.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

echo "=== sandbox-docker tests ==="
echo ""
echo "--- tier-1: lima.yaml / settings.json / start.sh ---"

yq -o=json '.' "${LIMA_YAML}" >"${TMPROOT}/lima.json"

# -----------------------------------------------------------------------------
# lima_yaml_definition: vz・proxy 環境変数を持ち込まない・image は nix が差し込む・
# ホームを mount する _default/mounts と template:docker を base にしない・docker.sock の転送・
# host.docker.internal（Mac のサービスへの名前）を足さない
# -----------------------------------------------------------------------------
echo "- lima_yaml_definition"
got="$(jq -c '{
  vmType,
  propagateProxyEnv,
  images,
  base: [(.base // []) | if type == "array" then .[] else . end
    | if type == "object" then .url else . end
    | select(. == "template:_default/mounts" or . == "template:docker")],
  socket: [.portForwards[] | select(.guestSocket != null) | {guestSocket, hostSocket}],
  hostResolverHosts: .hostResolver.hosts
}' "${TMPROOT}/lima.json")"
want='{"vmType":"vz","propagateProxyEnv":false,"images":[{"location":"@image@","arch":"aarch64"}],"base":[],"socket":[{"guestSocket":"/run/user/{{.UID}}/docker.sock","hostSocket":"{{.Dir}}/sock/docker.sock"}],"hostResolverHosts":null}'
if [ "${got}" = "${want}" ]; then
  pass "lima_yaml_definition"
else
  fail "lima_yaml_definition" "got=${got}"
fi

# -----------------------------------------------------------------------------
# settings_allow_unix_sockets: ~/.lima 配下で sandbox に通す socket は VM の docker.sock だけ
# （ha.sock・ssh.sock・default_*.sock は通さない。OrbStack の socket は docker_proxy_test.py の WiringTest）
# -----------------------------------------------------------------------------
echo "- settings_allow_unix_sockets"
got="$(jq -c '[.sandbox.network.allowUnixSockets[] | select(test("\\.lima(/|$)"))]' "${SETTINGS}")"
want="$(jq -cn --arg s "${VM_SOCKET}" '[$s]')"
if [ "${got}" = "${want}" ]; then
  pass "settings_allow_unix_sockets"
else
  fail "settings_allow_unix_sockets" "got=${got} want=${want}"
fi

# -----------------------------------------------------------------------------
# settings_allowed_domains_docker: docker build（buildkit）がクライアントに任せる Docker Hub のトークン発行先
# auth.docker.io を許可する。ほかのレジストリ（ghcr.io 等）はトークン発行と push が同じドメインで
# 持ち出し経路になるので足さない
# -----------------------------------------------------------------------------
echo "- settings_allowed_domains_docker"
got="$(jq -c '[.sandbox.network.allowedDomains[] | select(test("docker|ghcr|quay|gcr\\.io|azurecr"))]' "${SETTINGS}")"
if [ "${got}" = '["auth.docker.io"]' ]; then
  pass "settings_allowed_domains_docker"
else
  fail "settings_allowed_domains_docker" "got=${got} want=[\"auth.docker.io\"]"
fi

# -----------------------------------------------------------------------------
# rules_docker_vm: RULES.md の「使えるもの」に docker-vm の使い方（VM の rootless docker・
# /private/tmp/claude だけの mount と build context / docker cp・Docker Hub 以外は先に docker-vm pull）がある
# -----------------------------------------------------------------------------
echo "- rules_docker_vm"
rules_line="$(awk '/^使えるもの:/ { f = 1; next } f && /^$/ { exit } f && /^- docker-vm:/' "${REPO_ROOT}/claude-code/RULES.md")"
missing=()
# shellcheck disable=SC2016 # 意図的: RULES.md のバッククォートを文字列として探す
for want in "rootless docker" '`/private/tmp/claude` だけ' "build context" '`docker cp`' "ghcr.io" '`docker-vm pull`'; do
  case "${rules_line}" in
  *"${want}"*) ;;
  *) missing+=("${want}") ;;
  esac
done
if [ -n "${rules_line}" ] && [ "${#missing[@]}" -eq 0 ]; then
  pass "rules_docker_vm"
else
  fail "rules_docker_vm" "line=${rules_line:-<none>} missing=${missing[*]:-}"
fi

# -----------------------------------------------------------------------------
# start_*: launchd agent が走らせる start.sh。VM が無ければ作って起動し、あれば起動だけする。
# 偽の limactl が受けた引数を記録し、list --quiet には FAKE_LIST を返す
# -----------------------------------------------------------------------------
cat >"${TMPROOT}/limactl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_LOG}"
if [ "$1" = list ]; then
  printf '%s' "${FAKE_LIST}"
fi
EOF
chmod +x "${TMPROOT}/limactl"

run_start() {
  : >"${TMPROOT}/calls"
  FAKE_LOG="${TMPROOT}/calls" FAKE_LIST="$1" LIMACTL="${TMPROOT}/limactl" \
    SANDBOX_DOCKER_YAML=/nix/store/x-lima.yaml bash "${START_SH}"
}

create_and_start="list --quiet
create --tty=false --name=sandbox-docker /nix/store/x-lima.yaml
start --tty=false sandbox-docker"

echo "- start_creates_missing_vm"
if run_start "" && [ "$(cat "${TMPROOT}/calls")" = "${create_and_start}" ]; then
  pass "start_creates_missing_vm"
else
  fail "start_creates_missing_vm" "calls=$(tr '\n' ';' <"${TMPROOT}/calls")"
fi

echo "- start_matches_whole_instance_name"
if run_start "$(printf 'default\nsandbox-docker-old\n')" && [ "$(cat "${TMPROOT}/calls")" = "${create_and_start}" ]; then
  pass "start_matches_whole_instance_name"
else
  fail "start_matches_whole_instance_name" "calls=$(tr '\n' ';' <"${TMPROOT}/calls")"
fi

echo "- start_starts_existing_vm"
if run_start "$(printf 'default\nsandbox-docker\n')" &&
  [ "$(cat "${TMPROOT}/calls")" = "$(printf 'list --quiet\nstart --tty=false sandbox-docker')" ]; then
  pass "start_starts_existing_vm"
else
  fail "start_starts_existing_vm" "calls=$(tr '\n' ';' <"${TMPROOT}/calls")"
fi

echo ""
echo "--- tier-2: limactl template copy --fill / home-manager (nix) ---"

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
else
  system=""
fi

tier2=(filled_mounts_only_tmp_claude filled_port_forwards provision_matches_docker_template
  launchd_agent_uses_patched_limactl image_is_fixed_output docker_vm_in_home_packages docker_vm_keeps_buildx_config)
if [ "${system}" != "aarch64-darwin" ]; then
  for t in "${tier2[@]}"; do
    skip "${t}" "nix daemon unreachable or not aarch64-darwin"
  done
else
  # path: で評価する（git の flake は untracked の新規ファイルを見ないので、commit 前でも走るように）
  flake_ref="path:${REPO_ROOT}"
  pkgs_expr="import (builtins.getFlake \"${flake_ref}\").inputs.nixpkgs { system = \"${system}\"; }"
  lima="$(nix build --no-link --print-out-paths --impure --expr "
    let pkgs = ${pkgs_expr}; in pkgs.callPackage ${REPO_ROOT}/lib/lima-sandbox { }
  " 2>"${TMPROOT}/nix.err" || true)"

  # 展開は使い捨ての LIMA_HOME で行う（~/.lima/_config の default.yaml / override.yaml を混ぜない）。
  # image は nix が store パスを差し込む前の @image@ のままでは展開できないので仮のパスにする
  sed 's|@image@|/nix/store/00000000000000000000000000000000-image.img|' "${LIMA_YAML}" >"${TMPROOT}/sandbox-docker.yaml"
  mkdir -p "${TMPROOT}/lima-home"
  if [ -n "${lima}" ] &&
    LIMA_HOME="${TMPROOT}/lima-home" HOME="${TMPROOT}" "${lima}/bin/limactl" template copy --fill \
      "${TMPROOT}/sandbox-docker.yaml" - >"${TMPROOT}/filled.yaml" 2>>"${TMPROOT}/nix.err"; then
    yq -o=json '.' "${TMPROOT}/filled.yaml" >"${TMPROOT}/filled.json"
  else
    echo '{}' >"${TMPROOT}/filled.json"
  fi

  # ---------------------------------------------------------------------------
  # filled_mounts_only_tmp_claude: 展開後の mounts は /private/tmp/claude（writable）の 1 件だけ
  # ---------------------------------------------------------------------------
  echo "- filled_mounts_only_tmp_claude"
  got="$(jq -c '[(.mounts // [])[] | {location, mountPoint, writable}]' "${TMPROOT}/filled.json")"
  want='[{"location":"/private/tmp/claude","mountPoint":"/private/tmp/claude","writable":true}]'
  if [ "${got}" = "${want}" ]; then
    pass "filled_mounts_only_tmp_claude"
  else
    fail "filled_mounts_only_tmp_claude" "got=${got} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  # ---------------------------------------------------------------------------
  # filled_port_forwards: 展開後の portForwards を Lima と同じく上から最初に一致した規則で引き、
  # guest の TCP 1024〜9999 だけが host の 127.0.0.1 に転送され、8384 とそれ以外（UDP を含む）は
  # ignore になる。どれにも一致しなければ Lima が末尾に足す 127.0.0.1 への転送に落ちる。
  # guestIP 127.0.0.1 は 0.0.0.0・::・::1 で待ち受けるものにも一致する（Lima の templates/default.yaml）
  # ---------------------------------------------------------------------------
  echo "- filled_port_forwards"
  got="$(jq -c --argjson uid "$(id -u)" '
    def ip_match($r; $ip):
      if ($r.guestIP == "0.0.0.0" or $r.guestIP == "::") then
        (if $r.guestIPMustBeZero then ($ip == "0.0.0.0" or $ip == "::") else true end)
      elif $r.guestIP == "127.0.0.1" then ($ip | IN("127.0.0.1", "0.0.0.0", "::", "::1"))
      else $r.guestIP == $ip end;
    def decide($proto; $ip; $port):
      [(.portForwards // [])[]
        | select((.guestSocket // "") == "")
        | select(.proto == "any" or .proto == $proto)
        | select(.guestPortRange[0] <= $port and $port <= .guestPortRange[1])
        | select(ip_match(.; $ip))][0] as $r
      | if $r == null then "forward 127.0.0.1:\($port)"
        elif $r.ignore then "ignore"
        else "forward \($r.hostIP):\($r.hostPortRange[0] + $port - $r.guestPortRange[0])" end;
    {
      sockets: [(.portForwards // [])[] | select((.guestSocket // "") != "") | .guestSocket],
      ports: ([
        ["tcp", "127.0.0.1", 1024], ["tcp", "0.0.0.0", 3000], ["tcp", "::", 9999],
        ["tcp", "0.0.0.0", 8384], ["tcp", "127.0.0.1", 8384],
        ["tcp", "0.0.0.0", 1023], ["tcp", "0.0.0.0", 10000], ["tcp", "0.0.0.0", 65535],
        ["tcp", "192.168.5.15", 3000],
        ["udp", "0.0.0.0", 3000], ["udp", "127.0.0.1", 53], ["udp", "0.0.0.0", 8384]
      ] as $cases
      | [$cases[] as $c | "\($c[0]) \($c[1]) \($c[2]) => \(decide($c[0]; $c[1]; $c[2]))"])
    }' "${TMPROOT}/filled.json" 2>&1 || true)"
  want="$(jq -cn --arg s "/run/user/$(id -u)/docker.sock" '{
    sockets: [$s],
    ports: [
      "tcp 127.0.0.1 1024 => forward 127.0.0.1:1024", "tcp 0.0.0.0 3000 => forward 127.0.0.1:3000",
      "tcp :: 9999 => forward 127.0.0.1:9999",
      "tcp 0.0.0.0 8384 => ignore", "tcp 127.0.0.1 8384 => ignore",
      "tcp 0.0.0.0 1023 => ignore", "tcp 0.0.0.0 10000 => ignore", "tcp 0.0.0.0 65535 => ignore",
      "tcp 192.168.5.15 3000 => ignore",
      "udp 0.0.0.0 3000 => ignore", "udp 127.0.0.1 53 => ignore", "udp 0.0.0.0 8384 => ignore"
    ]
  }')"
  if [ "${got}" = "${want}" ]; then
    pass "filled_port_forwards"
  else
    fail "filled_port_forwards" "got=${got}"
  fi

  # ---------------------------------------------------------------------------
  # provision_matches_docker_template: rootless docker の入れ方は Lima の docker template と同じ。
  # 外すのは先頭の provision（/etc/hosts に host.docker.internal を足す）だけ
  # ---------------------------------------------------------------------------
  echo "- provision_matches_docker_template"
  upstream="${lima}/share/lima/templates/docker.yaml"
  if [ -n "${lima}" ] && [ -f "${upstream}" ]; then
    yq -o=json '{"provision": .provision[1:], "probes": .probes, "containerd": .containerd,
      "containerdSnapshotter": .param.containerdSnapshotter}' "${upstream}" >"${TMPROOT}/upstream.json"
    yq -o=json '{"provision": .provision, "probes": .probes, "containerd": .containerd,
      "containerdSnapshotter": .param.containerdSnapshotter}' "${LIMA_YAML}" >"${TMPROOT}/ours.json"
    if jq -e --slurpfile u "${TMPROOT}/upstream.json" '. == $u[0]' "${TMPROOT}/ours.json" >/dev/null &&
      jq -e '.provision[0].script | test("get.docker.com")' "${TMPROOT}/ours.json" >/dev/null; then
      pass "provision_matches_docker_template"
    else
      fail "provision_matches_docker_template" "ours=$(jq -c . "${TMPROOT}/ours.json") upstream=$(jq -c . "${TMPROOT}/upstream.json")"
    fi
  else
    fail "provision_matches_docker_template" "lima=${lima:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  hm_expr="
    let
      flake = builtins.getFlake \"${flake_ref}\";
      hm = flake.homeConfigurations.\"naramotoyuuji-darwin\";
    in"

  # ---------------------------------------------------------------------------
  # launchd_agent_uses_patched_limactl: launchd agent sandbox-docker はログイン時に start.sh を走らせ、
  # limactl は lib/lima-sandbox のパッチ版（素の pkgs.lima ではない）
  # ---------------------------------------------------------------------------
  echo "- launchd_agent_uses_patched_limactl"
  nix eval --json --impure --expr "${hm_expr}
    let
      agent = hm.config.launchd.agents.sandbox-docker;
      env = agent.config.EnvironmentVariables;
    in {
      inherit (agent) enable;
      inherit (agent.config) RunAtLoad;
      script = builtins.elemAt agent.config.ProgramArguments 1;
      patched = env.LIMACTL == \"\${hm.pkgs.callPackage ${REPO_ROOT}/lib/lima-sandbox { }}/bin/limactl\";
      plain = hm.pkgs.lib.hasPrefix \"\${hm.pkgs.lima}\" env.LIMACTL;
      yaml = builtins.attrNames (builtins.getContext env.SANDBOX_DOCKER_YAML);
    }
  " >"${TMPROOT}/agent.json" 2>>"${TMPROOT}/nix.err" || echo '{}' >"${TMPROOT}/agent.json"
  got="$(jq -c '{enable, RunAtLoad, patched, plain}' "${TMPROOT}/agent.json")"
  script="$(jq -r '.script // empty' "${TMPROOT}/agent.json")"
  if [ "${got}" = '{"enable":true,"RunAtLoad":true,"patched":true,"plain":false}' ] &&
    [ -n "${script}" ] && cmp -s "${script}" "${START_SH}"; then
    pass "launchd_agent_uses_patched_limactl"
  else
    fail "launchd_agent_uses_patched_limactl" "got=${got} script=${script:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  # ---------------------------------------------------------------------------
  # image_is_fixed_output: VM に渡す lima.yaml（replaceVars の生成物）の入力に、hash 固定の
  # fetchurl の image がある。image の download は要らないので build せず derivation だけ見る
  # ---------------------------------------------------------------------------
  echo "- image_is_fixed_output"
  yaml_drv="$(jq -r '.yaml[0] // empty' "${TMPROOT}/agent.json")"
  got=""
  if [ -n "${yaml_drv}" ] && nix derivation show -r "${yaml_drv}" >"${TMPROOT}/drv.json" 2>>"${TMPROOT}/nix.err"; then
    got="$(jq -c '[(.derivations // .) | to_entries[] | .value
      | select(.name | endswith(".img")) | (.outputs.out.hash // "") | length > 0]' "${TMPROOT}/drv.json")"
  fi
  if [ "${got}" = '[true]' ]; then
    pass "image_is_fixed_output"
  else
    fail "image_is_fixed_output" "got=${got:-<none>} drv=${yaml_drv:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  # ---------------------------------------------------------------------------
  # docker_vm_in_home_packages: home.packages の docker-vm は VM の docker.sock に向いた docker で、
  # BUILDX_CONFIG が無ければ sandbox から書ける /private/tmp/claude 配下を入れる
  # （~/.docker/buildx は sandbox 内から書けず build が始まる前に落ちる）。
  # docker-vm を偽の docker（受けた BUILDX_CONFIG と引数を出す）を PATH の先頭に置いて走らせる
  # ---------------------------------------------------------------------------
  echo "- docker_vm_in_home_packages"
  home="$(nix eval --raw --impure --expr "${hm_expr} hm.config.home.homeDirectory" 2>>"${TMPROOT}/nix.err" || true)"
  out="$(nix build --no-link --print-out-paths --impure --expr "${hm_expr}
    builtins.head (builtins.filter (p: (p.name or \"\") == \"docker-vm\") hm.config.home.packages)
  " 2>>"${TMPROOT}/nix.err" || true)"
  mkdir -p "${TMPROOT}/fakebin"
  cat >"${TMPROOT}/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
echo "BUILDX_CONFIG=${BUILDX_CONFIG-<unset>}"
echo "$*"
EOF
  chmod +x "${TMPROOT}/fakebin/docker"
  run_docker_vm() {
    [ -n "${out}" ] && PATH="${TMPROOT}/fakebin:${PATH}" "$@" "${out}/bin/docker-vm" build -t x . 2>&1
  }
  got="$(run_docker_vm env -u BUILDX_CONFIG || true)"
  want="BUILDX_CONFIG=/private/tmp/claude/docker-vm-buildx
--host unix://${home}/.lima/sandbox-docker/sock/docker.sock build -t x ."
  if [ -n "${home}" ] && [ "${got}" = "${want}" ]; then
    pass "docker_vm_in_home_packages"
  else
    fail "docker_vm_in_home_packages" "out=${out:-<none>} got=${got} want=${want} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  # ---------------------------------------------------------------------------
  # docker_vm_keeps_buildx_config: 呼び出し側が BUILDX_CONFIG を決めていれば docker-vm は上書きしない
  # ---------------------------------------------------------------------------
  echo "- docker_vm_keeps_buildx_config"
  got="$(run_docker_vm env BUILDX_CONFIG="${TMPROOT}/my-buildx" || true)"
  if [ "${got%%$'\n'*}" = "BUILDX_CONFIG=${TMPROOT}/my-buildx" ]; then
    pass "docker_vm_keeps_buildx_config"
  else
    fail "docker_vm_keeps_buildx_config" "out=${out:-<none>} got=${got}"
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
echo "PASS: sandbox-docker"
