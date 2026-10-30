#!/usr/bin/env bash
# tests/sandbox-docker.test.sh
# VM sandbox-docker（home-manager/home/file/sandbox-docker/lima.yaml・home-manager/programs/sandbox-docker.nix）を
# VM を起動せずに確かめる。
# Run from anywhere: bash tests/sandbox-docker.test.sh
# Requires: jq, yq（mikefarah/yq）。nix（daemon に届くときだけ。届かなければ tier-2 を skip）
#
# tier-1: lima.yaml の定義と vm-egress-proxy の設定、claude-code/settings.json の allowUnixSockets / allowedDomains、RULES.md の docker-vm、start.sh（偽の limactl で動かす）、
#         docker-vm.sh（build の前の参照イメージの pull。偽の docker で動かす）
# tier-2: パッチ版 limactl の template copy --fill で展開した mounts / portForwards、
#         Lima の docker template との手順の突き合わせ、home-manager の評価結果（launchd agent・docker-vm・image）
#
# LIMA_SANDBOX_SKIP_BUILD=1 のときはパッチ版 Lima の build を要する 4 つ（filled_*・provision_matches_docker_template）を
# skip し、評価だけで済む残りの tier-2 は走らせる

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
# lima_yaml_egress_proxy: provision の実行環境・apt・rootless dockerd（と中の buildkit）・VM 内の docker CLI が
# 作るコンテナの既定（~/.docker/config.json の proxies）が vm-egress-proxy を使う。param.egressProxy は
# lib/lima-sandbox/deny.go の proxyAddress（forwarder が通す唯一の宛先）と同じ。env は Lima が param を
# 展開しないので同じ値を直に書く。provision は Lima と同じく param を埋め、同じ path の yq を上から順に
# null から評価した結果を見る
# -----------------------------------------------------------------------------
echo "- lima_yaml_egress_proxy"
proxy_address="$(sed -n 's/^const proxyAddress = "\(.*\)"$/\1/p' "${REPO_ROOT}/lib/lima-sandbox/deny.go")"
jq -r '.param | to_entries[] | "s|{{.Param.\(.key)}}|\(.value)|g"' "${TMPROOT}/lima.json" >"${TMPROOT}/param.sed"
yq_result() {
  echo 'null' >"${TMPROOT}/yq.json"
  jq -c --arg p "$1" '.provision[] | select(.mode == "yq" and .path == $p) | .expression' "${TMPROOT}/lima.json" |
    while IFS= read -r expr; do
      expr="$(jq -r . <<<"${expr}" | sed -f "${TMPROOT}/param.sed")"
      yq -p=json -o=json "${expr}" "${TMPROOT}/yq.json" >"${TMPROOT}/yq.next" && mv "${TMPROOT}/yq.next" "${TMPROOT}/yq.json"
    done
  cat "${TMPROOT}/yq.json"
}
apt_conf="$(jq -r '.provision[] | select(.mode == "data" and .path == "/etc/apt/apt.conf.d/95vm-egress-proxy") | .content' \
  "${TMPROOT}/lima.json" | sed -f "${TMPROOT}/param.sed")"
got="$(jq -c --argjson daemon "$(yq_result '{{.Home}}/.config/docker/daemon.json')" \
  --argjson cli "$(yq_result '{{.Home}}/.docker/config.json')" --arg apt "${apt_conf}" '{
  proxy: .param.egressProxy,
  noProxy: .param.egressNoProxy,
  env: .env,
  apt: $apt,
  dockerd: $daemon.proxies,
  cli: $cli.proxies
}' "${TMPROOT}/lima.json")"
want="$(jq -cn --arg p "http://${proxy_address}" --arg n "localhost,127.0.0.1,::1" '{
  proxy: $p,
  noProxy: $n,
  env: {http_proxy: $p, https_proxy: $p, HTTP_PROXY: $p, HTTPS_PROXY: $p, no_proxy: $n, NO_PROXY: $n},
  apt: "Acquire::http::Proxy \"\($p)\";\nAcquire::https::Proxy \"\($p)\";",
  dockerd: {"http-proxy": $p, "https-proxy": $p, "no-proxy": $n},
  cli: {default: {httpProxy: $p, httpsProxy: $p, noProxy: $n}}
}')"
if [ -n "${proxy_address}" ] && [ "${got}" = "${want}" ]; then
  pass "lima_yaml_egress_proxy"
else
  fail "lima_yaml_egress_proxy" "got=${got} want=${want}"
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
# /private/tmp/claude だけの mount と build context / docker cp・BuildKit はレジストリを問わず Mac 側の CLI で
# トークンを取るので手元に無いイメージは VM 側で pull が要り、build では docker-vm が参照イメージを自動で pull し、
# compose の build と --pull は手で docker-vm pull する・VM の外向き通信は許可リスト（allowedDomains と vm-domains.txt）で絞られ、足りないホストはプロキシの
# 拒否ログで確かめてどちらかに足す）がある。sandbox 内では素の docker が docker-vm に回り（claude-code/bin/docker）、
# テストやスクリプトには素の docker を書いて DOCKER のような差し替え変数を repo に持ち込まないことも書かれている
# -----------------------------------------------------------------------------
echo "- rules_docker_vm"
rules_line="$(awk '/^使えるもの:/ { f = 1; next } f && /^$/ { exit } f && /^- docker-vm:/' "${REPO_ROOT}/claude-code/RULES.md")"
missing=()
# shellcheck disable=SC2016 # 意図的: RULES.md のバッククォートを文字列として探す
for want in "rootless docker" '`/private/tmp/claude` だけ' "build context" '`docker cp`' \
  "BuildKit はレジストリを問わず Mac 側の docker CLI でトークンを取る" "手元に無いイメージは VM 側で pull しておく必要がある" \
  '`docker-vm` が Dockerfile の参照イメージ' "VM に無いものを自動で pull する" \
  'compose の build（`compose build` / `up --build`）と `--pull` は自動では拾えないので、手で `docker-vm pull` しておく' \
  "外向き通信は許可リスト" '`allowedDomains`' '`vm-domains.txt`' '`~/.local/state/vm-egress-proxy.err.log`' '`denied`' \
  '`HTTPS_PROXY`' 'sandbox 内では素の `docker` も docker-vm に回る' 'テストやスクリプトには CI と同じ素の `docker` を書き' \
  '`DOCKER` のような sandbox 用の差し替え変数を repo に持ち込まない'; do
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

# -----------------------------------------------------------------------------
# docker_vm_*: docker-vm の本体 docker-vm.sh。nix の docker-vm と同じく先頭に --host を付けて走らせる。
# 偽の docker は受けた引数を 1 行ずつ記録し、image inspect は FAKE_PRESENT にある参照だけ見つかり、
# pull は FAKE_PULL_FAIL にある参照だけ失敗する
# -----------------------------------------------------------------------------
VM_SH="${SRC_DIR}/docker-vm.sh"
VM_HOST="unix:///vm/docker.sock"
mkdir -p "${TMPROOT}/vmbin"
cat >"${TMPROOT}/vmbin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_LOG}"
ref="${*: -1}"
case "$*" in
*" image inspect -- "*)
  case " ${FAKE_PRESENT} " in
  *" ${ref} "*) exit 0 ;;
  esac
  exit 1
  ;;
*" pull "*)
  case " ${FAKE_PULL_FAIL} " in
  *" ${ref} "*) exit 1 ;;
  esac
  ;;
esac
EOF
chmod +x "${TMPROOT}/vmbin/docker"

# run_vm <dir> <args...>: <dir> で docker-vm.sh を走らせ、偽の docker の呼び出しを vm-calls に、stderr を vm-err に残す
run_vm() {
  local dir="$1"
  shift
  : >"${TMPROOT}/vm-calls"
  (cd "${dir}" && FAKE_LOG="${TMPROOT}/vm-calls" FAKE_PRESENT="${FAKE_PRESENT-}" FAKE_PULL_FAIL="${FAKE_PULL_FAIL-}" \
    PATH="${TMPROOT}/vmbin:${PATH}" bash "${VM_SH}" --host "${VM_HOST}" "$@") >/dev/null 2>"${TMPROOT}/vm-err"
}

# vm_calls <ref>...: 参照ごとの inspect と pull（FAKE_PRESENT にあるものは inspect だけ）の呼び出し列。
# VM_PULL_OPTS（--platform）があるときは inspect せず、FAKE_PRESENT に関わらず常に pull する
vm_calls() {
  local ref
  for ref in "$@"; do
    if [ -n "${VM_PULL_OPTS-}" ]; then
      echo "--host ${VM_HOST} pull ${VM_PULL_OPTS} -- ${ref}"
      continue
    fi
    echo "--host ${VM_HOST} image inspect -- ${ref}"
    case " ${FAKE_PRESENT-} " in
    *" ${ref} "*) ;;
    *) echo "--host ${VM_HOST} pull -- ${ref}" ;;
    esac
  done
}

vm_got() {
  echo "calls=$(tr '\n' ';' <"${TMPROOT}/vm-calls") err=$(tr '\n' ';' <"${TMPROOT}/vm-err")"
}

# 参照の集め方を確かめる Dockerfile。ステージ名（大文字小文字を問わない）・scratch・ステージ番号は pull しない
mkdir -p "${TMPROOT}/vm/refs"
cat >"${TMPROOT}/vm/refs/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1.7
# 先頭のコメント
FROM --platform=$BUILDPLATFORM golang:1.22 AS build
RUN --mount=type=cache,target=/root/.cache \
    --mount=type=bind,from=busybox:1.36,source=/bin,target=/bb true
FROM build AS test
COPY --from=alpine:3.18.6 /etc/os-release /
FROM scratch
COPY --from=build /out /out
COPY --from=0 /out /out2
FROM Test
from debian:12 as Deb
COPY --from=deb /etc /etc
EOF
refs_all=(docker/dockerfile:1.7 golang:1.22 busybox:1.36 alpine:3.18.6 debian:12)

# AC-1: build / buildx build / image build で、VM に無い参照だけを同じ --host で pull してから、受けた引数のまま build する
echo "- docker_vm_pulls_missing_refs"
bad=()
for sub in "build" "buildx build" "image build"; do
  read -r -a sub_words <<<"${sub}"
  FAKE_PRESENT="golang:1.22" run_vm "${TMPROOT}/vm/refs" "${sub_words[@]}" -t x --build-arg A=1 .
  want="$(FAKE_PRESENT="golang:1.22" vm_calls "${refs_all[@]}")
--host ${VM_HOST} ${sub} -t x --build-arg A=1 ."
  if [ "$(cat "${TMPROOT}/vm-calls")" != "${want}" ]; then
    bad+=("${sub}: $(vm_got)")
  fi
done
if [ "${#bad[@]}" -eq 0 ]; then
  pass "docker_vm_pulls_missing_refs"
else
  fail "docker_vm_pulls_missing_refs" "${bad[*]}"
fi

# AC-2: 参照がすべて inspect で見つかれば pull を呼ばない
echo "- docker_vm_no_pull_when_present"
FAKE_PRESENT="${refs_all[*]}" run_vm "${TMPROOT}/vm/refs" build -t x .
want="$(FAKE_PRESENT="${refs_all[*]}" vm_calls "${refs_all[@]}")
--host ${VM_HOST} build -t x ."
if [ "$(cat "${TMPROOT}/vm-calls")" = "${want}" ] && ! grep -q ' pull ' "${TMPROOT}/vm-calls"; then
  pass "docker_vm_no_pull_when_present"
else
  fail "docker_vm_no_pull_when_present" "$(vm_got)"
fi

# AC-3: Dockerfile は -f / --file / --file=（相対パスはカレントディレクトリ基準）、無ければ context の Dockerfile。
# files/ は context（ctx）の中に無いので、context 基準に解決すると読めずに素通しになる
echo "- docker_vm_dockerfile_location"
mkdir -p "${TMPROOT}/vm/loc/ctx" "${TMPROOT}/vm/loc/files"
echo "FROM ctx-image:1" >"${TMPROOT}/vm/loc/ctx/Dockerfile"
echo "FROM file-image:1" >"${TMPROOT}/vm/loc/files/app.Dockerfile"
bad=()
for case_args in "ctx-image:1|build ctx" "file-image:1|build -f files/app.Dockerfile ctx" \
  "file-image:1|build --file files/app.Dockerfile ctx" "file-image:1|build --file=files/app.Dockerfile ctx"; do
  read -r -a words <<<"${case_args#*|}"
  run_vm "${TMPROOT}/vm/loc" "${words[@]}"
  want="$(vm_calls "${case_args%%|*}")
--host ${VM_HOST} ${case_args#*|}"
  if [ "$(cat "${TMPROOT}/vm-calls")" != "${want}" ]; then
    bad+=("${case_args#*|}: $(vm_got)")
  fi
done
if [ "${#bad[@]}" -eq 0 ]; then
  pass "docker_vm_dockerfile_location"
else
  fail "docker_vm_dockerfile_location" "${bad[*]}"
fi

# AC-3: --platform（--platform= 形式を含む）は pull にも同じ値を渡す。VM に（別プラットフォーム版が）あって
# inspect が見つかったと返す参照でも、inspect に頼らず --platform 付きで pull する
echo "- docker_vm_platform"
bad=()
for present in "" "ctx-image:1"; do
  for case_args in "linux/amd64|--platform linux/amd64" "linux/arm64|--platform=linux/arm64"; do
    read -r -a words <<<"${case_args#*|}"
    FAKE_PRESENT="${present}" run_vm "${TMPROOT}/vm/loc" build "${words[@]}" ctx
    want="$(VM_PULL_OPTS="--platform ${case_args%%|*}" vm_calls ctx-image:1)
--host ${VM_HOST} build ${case_args#*|} ctx"
    if [ "$(cat "${TMPROOT}/vm-calls")" != "${want}" ]; then
      bad+=("present=${present:-none} ${case_args#*|}: $(vm_got)")
    fi
  done
done
if [ "${#bad[@]}" -eq 0 ]; then
  pass "docker_vm_platform"
else
  fail "docker_vm_platform" "${bad[*]}"
fi

# AC-3: 最初の FROM より前の ARG の既定値と --build-arg（--build-arg= 形式を含む）で $VAR / ${VAR} を展開する
echo "- docker_vm_build_args"
mkdir -p "${TMPROOT}/vm/args"
cat >"${TMPROOT}/vm/args/Dockerfile" <<'EOF'
ARG BASE=alpine
ARG TAG="3.18"
ARG REG
ARG FULL=${BASE}:$TAG
FROM ${BASE}:$TAG
FROM $REG/tool:1
FROM ${FULL}-slim
EOF
run_vm "${TMPROOT}/vm/args" build --build-arg TAG=3.19 --build-arg=REG=registry.example .
want="$(vm_calls alpine:3.19 registry.example/tool:1 alpine:3.19-slim)
--host ${VM_HOST} build --build-arg TAG=3.19 --build-arg=REG=registry.example ."
got1="$(vm_got)"
ok=0
if [ "$(cat "${TMPROOT}/vm-calls")" = "${want}" ]; then
  run_vm "${TMPROOT}/vm/args" build .
  want="$(vm_calls alpine:3.18 alpine:3.18-slim)
--host ${VM_HOST} build ."
  if [ "$(cat "${TMPROOT}/vm-calls")" = "${want}" ]; then
    ok=1
  fi
fi
if [ "${ok}" = 1 ]; then
  pass "docker_vm_build_args"
else
  fail "docker_vm_build_args" "with build-arg: ${got1} / defaults: $(vm_got)"
fi

# AC-4: 展開できない変数を含む参照は pull せず 1 行警告し、pull の失敗も警告して build はそのまま実行する
echo "- docker_vm_warns_and_continues"
mkdir -p "${TMPROOT}/vm/warn"
cat >"${TMPROOT}/vm/warn/Dockerfile" <<'EOF'
ARG REG
FROM $REG/tool:1
FROM ${TAG:-x}/y
FROM alpine:3.18.6
ARG LATE=1
FROM busybox:$LATE
FROM debian:12
EOF
FAKE_PULL_FAIL="alpine:3.18.6" run_vm "${TMPROOT}/vm/warn" build -t x .
want="$(vm_calls alpine:3.18.6 debian:12)
--host ${VM_HOST} build -t x ."
# shellcheck disable=SC2016 # 意図的: Dockerfile の $ を文字列として探す
if [ "$(cat "${TMPROOT}/vm-calls")" = "${want}" ] &&
  [ "$(grep -c '^docker-vm: .*\$REG/tool:1$' "${TMPROOT}/vm-err")" = 1 ] &&
  [ "$(grep -c '^docker-vm: .*\${TAG:-x}/y$' "${TMPROOT}/vm-err")" = 1 ] &&
  [ "$(grep -c '^docker-vm: .*busybox:\$LATE$' "${TMPROOT}/vm-err")" = 1 ] &&
  [ "$(grep -c '^docker-vm: .*alpine:3.18.6$' "${TMPROOT}/vm-err")" = 1 ] &&
  [ "$(wc -l <"${TMPROOT}/vm-err" | tr -d ' ')" = 4 ]; then
  pass "docker_vm_warns_and_continues"
else
  fail "docker_vm_warns_and_continues" "$(vm_got)"
fi

# AC-5: build 以外・-f -・context が - / URL / git・Dockerfile が無い / 読めないときは inspect も pull も呼ばずに素通しする
echo "- docker_vm_passthrough"
mkdir -p "${TMPROOT}/vm/pass/locked"
echo "FROM alpine:3.18.6" >"${TMPROOT}/vm/pass/Dockerfile"
echo "FROM alpine:3.18.6" >"${TMPROOT}/vm/pass/locked/Dockerfile"
chmod 000 "${TMPROOT}/vm/pass/locked/Dockerfile"
pass_cases=("ps -a" "buildx ls" "image ls" "build -f - ." "build -" "build https://github.com/example/app.git"
  "build git@github.com:example/app.git" "build github.com/example/app" "build missing" "build -f nothere.Dockerfile .")
if [ ! -r "${TMPROOT}/vm/pass/locked/Dockerfile" ]; then
  pass_cases+=("build locked")
fi
bad=()
for c in "${pass_cases[@]}"; do
  read -r -a words <<<"${c}"
  run_vm "${TMPROOT}/vm/pass" "${words[@]}"
  if [ "$(cat "${TMPROOT}/vm-calls")" != "--host ${VM_HOST} ${c}" ]; then
    bad+=("${c}: $(vm_got)")
  fi
done
if [ "${#bad[@]}" -eq 0 ]; then
  pass "docker_vm_passthrough"
else
  fail "docker_vm_passthrough" "${bad[*]}"
fi

# AC-5: --pull はそのまま渡し、CLI がトークンを取りにいくので sandbox 内では失敗しうると stderr に出す
echo "- docker_vm_pull_flag_warns"
run_vm "${TMPROOT}/vm/pass" build --pull -t x .
if [ "$(cat "${TMPROOT}/vm-calls")" = "--host ${VM_HOST} build --pull -t x ." ] &&
  grep -q -- '--pull では Mac 側の docker CLI がレジストリのトークンを取りにいくので、sandbox 内では失敗しうる' "${TMPROOT}/vm-err"; then
  pass "docker_vm_pull_flag_warns"
else
  fail "docker_vm_pull_flag_warns" "$(vm_got)"
fi

echo ""
echo "--- tier-2: limactl template copy --fill / home-manager (nix) ---"

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
else
  system=""
fi

tier2=(filled_mounts_only_tmp_claude filled_port_forwards filled_egress_proxy provision_matches_docker_template
  launchd_agent_uses_patched_limactl image_is_fixed_output docker_vm_in_home_packages docker_vm_keeps_buildx_config
  docker_vm_pulls_via_vm)
if [ "${system}" != "aarch64-darwin" ]; then
  for t in "${tier2[@]}"; do
    skip "${t}" "nix daemon unreachable or not aarch64-darwin"
  done
else
  # path: で評価する（git の flake は untracked の新規ファイルを見ないので、commit 前でも走るように）
  flake_ref="path:${REPO_ROOT}"
  pkgs_expr="import (builtins.getFlake \"${flake_ref}\").inputs.nixpkgs { system = \"${system}\"; }"

  # パッチ版 Lima は cache.nixos.org に無く、build はソースからで約 3 分かかる。CI は関係するパスが変わらない
  # PR・push でこれを 1 にして、build した limactl を要する 4 つを飛ばす（.github/workflows/ci.yml）
  if [ "${LIMA_SANDBOX_SKIP_BUILD:-}" = "1" ]; then
    for t in filled_mounts_only_tmp_claude filled_port_forwards filled_egress_proxy provision_matches_docker_template; do
      skip "${t}" "LIMA_SANDBOX_SKIP_BUILD=1"
    done
  else
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
    # filled_egress_proxy: Lima が展開した後の provision（apt の data・daemon.json・config.json の yq）に
    # param.egressProxy が埋まり、env が VM に渡る（param を展開しない欄に書いていないこと）
    # ---------------------------------------------------------------------------
    echo "- filled_egress_proxy"
    proxy="$(jq -r '.param.egressProxy' "${TMPROOT}/lima.json")"
    # {{.Home}} は VM の中のホーム（.user.home）に展開されるので ~ に戻して比べる
    got="$(jq -c --arg p "${proxy}" '(.user.home // "") as $h | {
    env: ((.env // {}) | [.http_proxy, .https_proxy, .HTTP_PROXY, .HTTPS_PROXY] | unique),
    provisions: [(.provision // [])[] | select((.content // .expression // "") | contains($p))
      | .path | if $h != "" and startswith($h + "/") then "~" + ltrimstr($h) else . end],
    unfilled: [(.provision // [])[] | select(tojson | contains("{{.Param.egress"))] | length
  }' "${TMPROOT}/filled.json" 2>&1 || true)"
    want="$(jq -cn --arg p "${proxy}" '{
    env: [$p],
    provisions: ["/etc/apt/apt.conf.d/95vm-egress-proxy", "~/.config/docker/daemon.json", "~/.docker/config.json"],
    unfilled: 0
  }')"
    if [ "${got}" = "${want}" ]; then
      pass "filled_egress_proxy"
    else
      fail "filled_egress_proxy" "got=${got} want=${want}"
    fi

    # ---------------------------------------------------------------------------
    # provision_matches_docker_template: rootless docker の入れ方は Lima の docker template と同じ。
    # 外すのは先頭の provision（/etc/hosts に host.docker.internal を足す）だけ。
    # 足すのは vm-egress-proxy の設定（param.egressProxy を使うもの。lima_yaml_egress_proxy で見る）だけ
    # ---------------------------------------------------------------------------
    echo "- provision_matches_docker_template"
    upstream="${lima}/share/lima/templates/docker.yaml"
    if [ -n "${lima}" ] && [ -f "${upstream}" ]; then
      yq -o=json '{"provision": .provision[1:], "probes": .probes, "containerd": .containerd,
      "containerdSnapshotter": .param.containerdSnapshotter}' "${upstream}" >"${TMPROOT}/upstream.json"
      jq '{"provision": [.provision[] | select(tojson | test("egressProxy") | not)], "probes": .probes,
      "containerd": .containerd, "containerdSnapshotter": .param.containerdSnapshotter}' "${TMPROOT}/lima.json" >"${TMPROOT}/ours.json"
      if jq -e --slurpfile u "${TMPROOT}/upstream.json" '. == $u[0]' "${TMPROOT}/ours.json" >/dev/null &&
        jq -e '.provision[0].script | test("get.docker.com")' "${TMPROOT}/ours.json" >/dev/null; then
        pass "provision_matches_docker_template"
      else
        fail "provision_matches_docker_template" "ours=$(jq -c . "${TMPROOT}/ours.json") upstream=$(jq -c . "${TMPROOT}/upstream.json")"
      fi
    else
      fail "provision_matches_docker_template" "lima=${lima:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
    fi
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
echo "DOCKER_CONFIG=${DOCKER_CONFIG-<unset>}"
EOF
  chmod +x "${TMPROOT}/fakebin/docker"
  # Dockerfile の無いディレクトリで走らせる（build の前の inspect / pull を挟まない）
  mkdir -p "${TMPROOT}/empty"
  run_docker_vm() {
    [ -n "${out}" ] && (cd "${TMPROOT}/empty" && PATH="${TMPROOT}/fakebin:${PATH}" "$@" "${out}/bin/docker-vm" build -t x . 2>&1)
  }
  got_full="$(run_docker_vm env -u BUILDX_CONFIG || true)"
  got="$(head -n 2 <<<"${got_full}")"
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

  # ---------------------------------------------------------------------------
  # docker_vm_container_proxy: docker-vm は Mac の docker CLI なので、コンテナと build の RUN に入るプロキシは
  # docker-vm の DOCKER_CONFIG の proxies から決まる（VM 側の ~/.docker/config.json は読まれない）。
  # 呼び出し側の DOCKER_CONFIG に関わらず、proxies.default が vm-egress-proxy（deny.go の proxyAddress）で、
  # buildx を ~/.docker/cli-plugins から探す config に向ける
  # ---------------------------------------------------------------------------
  echo "- docker_vm_container_proxy"
  got_full="$(run_docker_vm env DOCKER_CONFIG="${TMPROOT}/my-docker" || true)"
  docker_config="$(sed -n 's/^DOCKER_CONFIG=//p' <<<"${got_full}")"
  got=""
  if [ -f "${docker_config}/config.json" ]; then
    got="$(jq -c '{proxies, cliPluginsExtraDirs}' "${docker_config}/config.json")"
  fi
  want="$(jq -cn --arg p "http://${proxy_address}" --arg n "localhost,127.0.0.1,::1" --arg d "${home}/.docker/cli-plugins" '{
    proxies: {default: {httpProxy: $p, httpsProxy: $p, noProxy: $n}},
    cliPluginsExtraDirs: [$d]
  }')"
  if [ -n "${proxy_address}" ] && [ -n "${home}" ] && [ "${got}" = "${want}" ]; then
    pass "docker_vm_container_proxy"
  else
    fail "docker_vm_container_proxy" "DOCKER_CONFIG=${docker_config:-<none>} got=${got:-<none>} want=${want}"
  fi

  # ---------------------------------------------------------------------------
  # docker_vm_no_keychain: docker-vm の DOCKER_CONFIG の config.json は credsStore / credHelpers / auths の
  # いずれかが空でない（docker/cli の ContainsAuth() が true になり、macOS の既定の
  # docker-credential-osxkeychain を選ばない）。credsStore・credHelpers に osxkeychain を含まず、
  # auths は資格情報を持たない（Docker Hub からは匿名で pull する）
  # ---------------------------------------------------------------------------
  echo "- docker_vm_no_keychain"
  got=""
  if [ -f "${docker_config}/config.json" ]; then
    got="$(jq -c '{
      containsAuth: (((.credsStore // "") != "") or ((.credHelpers // {}) | length > 0) or ((.auths // {}) | length > 0)),
      osxkeychain: [.credsStore // empty, (.credHelpers // {})[] | select(test("osxkeychain"))],
      credentials: [(.auths // {}) | to_entries[] | .key as $k | .value
        | to_entries[] | select((.key | IN("auth", "identitytoken", "registrytoken", "username", "password")) and .value != "")
        | "\($k).\(.key)"]
    }' "${docker_config}/config.json")"
  fi
  want='{"containsAuth":true,"osxkeychain":[],"credentials":[]}'
  if [ "${got}" = "${want}" ]; then
    pass "docker_vm_no_keychain"
  else
    fail "docker_vm_no_keychain" "DOCKER_CONFIG=${docker_config:-<none>} got=${got:-<none>} want=${want}"
  fi

  # ---------------------------------------------------------------------------
  # docker_vm_pulls_via_vm: home.packages の docker-vm は、build の前の inspect / pull も build と同じ接続先
  # （VM の docker.sock）と同じ DOCKER_CONFIG で叩く。docker-vm.sh の偽の docker（tier-1）で記録し、
  # 呼び出しごとの DOCKER_CONFIG を DOCKER_CONFIG_LOG に残す
  # ---------------------------------------------------------------------------
  echo "- docker_vm_pulls_via_vm"
  mkdir -p "${TMPROOT}/vmbin-env"
  cat >"${TMPROOT}/vmbin-env/docker" <<'EOF'
#!/usr/bin/env bash
echo "${DOCKER_CONFIG-<unset>}" >>"${DOCKER_CONFIG_LOG}"
exec "${FAKE_DOCKER}" "$@"
EOF
  chmod +x "${TMPROOT}/vmbin-env/docker"
  : >"${TMPROOT}/vm-calls"
  : >"${TMPROOT}/vm-config"
  if [ -n "${out}" ]; then
    (cd "${TMPROOT}/vm/pass" && FAKE_LOG="${TMPROOT}/vm-calls" FAKE_PRESENT="" FAKE_PULL_FAIL="" \
      FAKE_DOCKER="${TMPROOT}/vmbin/docker" DOCKER_CONFIG_LOG="${TMPROOT}/vm-config" \
      PATH="${TMPROOT}/vmbin-env:${PATH}" "${out}/bin/docker-vm" build -t x . >/dev/null 2>&1) || true
  fi
  vm_socket="unix://${home}/.lima/sandbox-docker/sock/docker.sock"
  want="--host ${vm_socket} image inspect -- alpine:3.18.6
--host ${vm_socket} pull -- alpine:3.18.6
--host ${vm_socket} build -t x ."
  if [ -n "${home}" ] && [ -n "${docker_config}" ] && [ "$(cat "${TMPROOT}/vm-calls")" = "${want}" ] &&
    [ "$(sort -u "${TMPROOT}/vm-config")" = "${docker_config}" ]; then
    pass "docker_vm_pulls_via_vm"
  else
    fail "docker_vm_pulls_via_vm" "calls=$(tr '\n' ';' <"${TMPROOT}/vm-calls") configs=$(tr '\n' ';' <"${TMPROOT}/vm-config") want_config=${docker_config:-<none>}"
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
