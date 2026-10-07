#!/usr/bin/env bash
# tests/agent-vault.test.sh
# agent-vault（Claude Code 本体の上流 proxy。home-manager/programs/agent-vault.nix）の設定を検証する。
# Run from anywhere: bash tests/agent-vault.test.sh
# Requires: jq, yq (yq-go), python3 / nix（tier-2、daemon に届くときだけ）
#
# - agent-vault-server.sh: Keychain のマスターパスワードを stdin で server に渡し、CA bundle を書く
#   （偽の security / agent-vault を使う。Keychain・ネットワークには触れない）
# - services.yaml: owner ごとの git（basic）/ REST（bearer）の振り分け
# - settings.json: sandbox から ~/.agent-vault（DB・CA 鍵・proxy token）を読めない
# - lib/agent-vault: 固定した版の binary（tier-2 で実際に build して version を見る）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${REPO_ROOT}/home-manager/home/file/agent-vault/agent-vault-server.sh"
SERVICES="${REPO_ROOT}/home-manager/home/file/agent-vault/services.yaml"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"
WRAPPER="${REPO_ROOT}/claude-code/bin/claude"

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

for cmd in jq yq python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "${cmd} required (nix develop -c tests/agent-vault.test.sh)" >&2
    exit 1
  fi
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-test.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

echo "=== agent-vault tests ==="
echo ""
echo "--- agent-vault-server.sh ---"

# 偽の security: 決まった service / account のときだけパスワードを返す
STUB_BIN="${TMPROOT}/stub-bin"
STUB_OUT="${TMPROOT}/stub-out"
mkdir -p "${STUB_BIN}" "${STUB_OUT}"
cat >"${STUB_BIN}/security" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "find-generic-password -s agent-vault -a master-password -w" ]; then
  echo "pw-s3cret"
  exit 0
fi
echo "security: The specified item could not be found in the keychain." >&2
exit 44
EOF
# 偽の agent-vault: server は argv / stdin / env を記録して終わる。ca fetch は -o に PEM を書く
cat >"${STUB_BIN}/agent-vault" <<'EOF'
#!/usr/bin/env bash
case "$1" in
server)
  printf '%s\n' "$@" >"$STUB_OUT/server.argv"
  cat >"$STUB_OUT/server.stdin"
  env >"$STUB_OUT/server.env"
  ;;
ca)
  out=""
  while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; fi
    shift
  done
  printf -- '-----BEGIN CERTIFICATE-----\nVAULT-CA\n-----END CERTIFICATE-----\n' >"$out"
  ;;
esac
EOF
chmod +x "${STUB_BIN}/security" "${STUB_BIN}/agent-vault"
printf -- '-----BEGIN CERTIFICATE-----\nSYSTEM-CA\n-----END CERTIFICATE-----\n' >"${TMPROOT}/system-ca.pem"
CA_BUNDLE="${TMPROOT}/state/agent-vault/ca-bundle.pem"

run_launcher() {
  local account="$1"
  set +e
  env STUB_OUT="${STUB_OUT}" \
    AGENT_VAULT_BIN="${STUB_BIN}/agent-vault" \
    AGENT_VAULT_SECURITY_BIN="${STUB_BIN}/security" \
    AGENT_VAULT_KEYCHAIN_SERVICE=agent-vault \
    AGENT_VAULT_KEYCHAIN_ACCOUNT="${account}" \
    AGENT_VAULT_CA_BUNDLE="${CA_BUNDLE}" \
    SYSTEM_CA_BUNDLE="${TMPROOT}/system-ca.pem" \
    AGENT_VAULT_CA_WAIT_SECONDS=5 \
    bash "${LAUNCHER}" 2>"${TMPROOT}/launcher.err"
  RC=$?
  set -e
}

# ---------------------------------------------------------------------------
# launcher_passes_password_via_stdin: パスワードは stdin にだけ渡り、argv・env に出ない
# ---------------------------------------------------------------------------
echo "- launcher_passes_password_via_stdin"
run_launcher master-password
argv="$(cat "${STUB_OUT}/server.argv" 2>/dev/null || true)"
if [ "${RC}" -eq 0 ] &&
  [ "$(cat "${STUB_OUT}/server.stdin" 2>/dev/null)" = "pw-s3cret" ] &&
  printf '%s\n' "${argv}" | grep -qx -- '--password-stdin' &&
  printf '%s\n' "${argv}" | grep -qx -- '--mitm-port' &&
  printf '%s\n' "${argv}" | grep -qx -- '14322' &&
  ! grep -q 'pw-s3cret' "${STUB_OUT}/server.argv" "${STUB_OUT}/server.env"; then
  pass "launcher_passes_password_via_stdin"
else
  fail "launcher_passes_password_via_stdin" "rc=${RC} argv=${argv} err=$(cat "${TMPROOT}/launcher.err")"
fi

# ---------------------------------------------------------------------------
# launcher_writes_ca_bundle: システムの CA bundle + agent-vault の CA を連結して書く
# （書くのは server と並行して動く background job なので、出来上がるまで待つ）
# ---------------------------------------------------------------------------
echo "- launcher_writes_ca_bundle"
for _ in $(seq 1 50); do
  [ -s "${CA_BUNDLE}" ] && break
  sleep 0.1
done
expected="$(cat "${TMPROOT}/system-ca.pem")"$'\n'"-----BEGIN CERTIFICATE-----"$'\n'"VAULT-CA"$'\n'"-----END CERTIFICATE-----"
if [ -f "${CA_BUNDLE}" ] && [ "$(cat "${CA_BUNDLE}")" = "${expected}" ]; then
  pass "launcher_writes_ca_bundle"
else
  fail "launcher_writes_ca_bundle" "bundle=$(cat "${CA_BUNDLE}" 2>/dev/null || echo '<missing>')"
fi

# ---------------------------------------------------------------------------
# launcher_fails_without_keychain_item: Keychain に無ければ server を起動せず非 0 で終わる
# （launchd の KeepAlive / ThrottleInterval で 30 秒おきに読み直す）
# ---------------------------------------------------------------------------
echo "- launcher_fails_without_keychain_item"
rm -f "${STUB_OUT}"/server.*
run_launcher other-account
if [ "${RC}" -ne 0 ] && [ ! -e "${STUB_OUT}/server.argv" ] &&
  grep -q 'master password not found in keychain' "${TMPROOT}/launcher.err"; then
  pass "launcher_fails_without_keychain_item"
else
  fail "launcher_fails_without_keychain_item" "rc=${RC} err=$(cat "${TMPROOT}/launcher.err")"
fi

echo ""
echo "--- services.yaml ---"

SERVICES_JSON="$(yq -o=json '.' "${SERVICES}")"

# service_auth <host>: host がちょうど一致する service の auth を compact JSON で出す
service_auth() {
  printf '%s' "${SERVICES_JSON}" | jq -c --arg h "$1" '[.services[] | select(.host == $h) | .auth]'
}

# ---------------------------------------------------------------------------
# services_route_git_and_rest_per_owner: owner ごとに git は basic（x-access-token + PAT）、
# REST の /repos/<owner>/ は bearer（同じ PAT）
# ---------------------------------------------------------------------------
for pair in it-all-playpark:GITHUB_PAT_IT_ALL_PLAYPARK playpark-llc:GITHUB_PAT_PLAYPARK_LLC Cistree-dev:GITHUB_PAT_CISTREE_DEV; do
  owner="${pair%%:*}"
  key="${pair#*:}"
  name="services_route_git_and_rest_per_owner[${owner}]"
  echo "- ${name}"
  git_auth="$(service_auth "github.com/${owner}/*")"
  api_auth="$(service_auth "api.github.com/repos/${owner}/*")"
  if [ "${git_auth}" = "[{\"type\":\"basic\",\"username\":\"GITHUB_GIT_USERNAME\",\"password\":\"${key}\"}]" ] &&
    [ "${api_auth}" = "[{\"type\":\"bearer\",\"token\":\"${key}\"}]" ]; then
    pass "${name}"
  else
    fail "${name}" "git=${git_auth} api=${api_auth}"
  fi
done

# ---------------------------------------------------------------------------
# services_default_api_bearer: owner が path に出ない REST / GraphQL は api.github.com（path なし）の bearer
# ---------------------------------------------------------------------------
echo "- services_default_api_bearer"
default_auth="$(service_auth "api.github.com")"
if [ "${default_auth}" = '[{"type":"bearer","token":"GITHUB_PAT_IT_ALL_PLAYPARK"}]' ]; then
  pass "services_default_api_bearer"
else
  fail "services_default_api_bearer" "api.github.com=${default_auth}"
fi

# ---------------------------------------------------------------------------
# services_names_are_unique_slugs: name は 3-64 文字の小文字英数とハイフン、重複なし
# （`vault service set` は name で upsert するので、重複すると後の定義が前を消す）
# ---------------------------------------------------------------------------
echo "- services_names_are_unique_slugs"
bad_names="$(printf '%s' "${SERVICES_JSON}" | jq -r '
  [.services[].name] as $n
  | ($n | map(select(test("^[a-z0-9]([a-z0-9]|-(?!-)){1,62}[a-z0-9]$") | not)))
    + ($n | group_by(.) | map(select(length > 1) | .[0]))
  | .[]')"
if [ -z "${bad_names}" ]; then
  pass "services_names_are_unique_slugs"
else
  fail "services_names_are_unique_slugs" "invalid or duplicated: ${bad_names}"
fi

echo ""
echo "--- settings.json ---"

# read_denied <path>: denyRead のいずれかのエントリが <path> の読み取りを塞ぐか
# （末尾の /** を剥がしたリテラルは subpath 扱い。sandbox-allow-write.test.sh の allowWrite と同じ規則）
read_denied() {
  jq -e --arg p "$1" --arg home "${HOME}" '
    [.sandbox.filesystem.denyRead[]
      | sub("/\\*\\*$"; "")
      | (if startswith("~/") then $home + ltrimstr("~") else . end)
      | select(test("[*?\\[]") | not)
      | . as $e
      | select($p == $e or ($p | startswith($e + "/")))]
    | length > 0' "${SETTINGS}" >/dev/null
}

# 塞ぐ対象は agent-vault の DB・CA 鍵と、wrapper が読む proxy token（wrapper の既定値から取る）
# shellcheck disable=SC2016 # 意図的: wrapper のソース上の "${...:-$HOME/...}" を文字列として拾う
token_default="$(sed -n 's/^token_file="\${AGENT_VAULT_PROXY_TOKEN_FILE:-\(.*\)}"$/\1/p' "${WRAPPER}")"
# shellcheck disable=SC2016 # 同上
ca_default="$(sed -n 's/^ca_bundle="\${AGENT_VAULT_CA_BUNDLE:-\(.*\)}"$/\1/p' "${WRAPPER}")"
token_path="${token_default/\$HOME/${HOME}}"
ca_path="${ca_default/\$HOME/${HOME}}"

echo "- settings_deny_read_agent_vault_dir"
if [ -n "${token_default}" ] &&
  read_denied "${HOME}/.agent-vault/agent-vault.db" &&
  read_denied "${HOME}/.agent-vault/ca/ca.key" &&
  read_denied "${token_path}"; then
  pass "settings_deny_read_agent_vault_dir"
else
  fail "settings_deny_read_agent_vault_dir" \
    "denyRead must cover ~/.agent-vault and the proxy token (${token_path:-<wrapper default not found>})"
fi

# CA bundle は sandbox 内のコマンドが読む（GIT_SSL_CAINFO 等）ので塞がない
echo "- settings_ca_bundle_readable"
if [ -n "${ca_default}" ] && ! read_denied "${ca_path}"; then
  pass "settings_ca_bundle_readable"
else
  fail "settings_ca_bundle_readable" "CA bundle (${ca_path:-<wrapper default not found>}) must stay readable from the sandbox"
fi

echo ""
echo "--- lib/agent-vault (tier-2: nix build) ---"

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
else
  system=""
fi

echo "- package_is_pinned_version"
if [ "${system}" != "aarch64-darwin" ]; then
  skip "package_is_pinned_version" "nix daemon unreachable or not aarch64-darwin"
else
  out="$(nix build --no-link --print-out-paths --impure --expr "
    let
      flake = builtins.getFlake \"${REPO_ROOT}\";
      pkgs = import flake.inputs.nixpkgs { system = \"${system}\"; };
    in
      pkgs.callPackage ${REPO_ROOT}/lib/agent-vault { }
  " 2>"${TMPROOT}/nix.err" || true)"
  version="$([ -n "${out}" ] && "${out}/bin/agent-vault" --telemetry=false version 2>/dev/null | head -n 1 || true)"
  if [ "${version}" = "agent-vault 0.40.0" ]; then
    pass "package_is_pinned_version"
  else
    fail "package_is_pinned_version" "version=${version:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
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
echo "PASS: agent-vault"
