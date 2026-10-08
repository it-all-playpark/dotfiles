#!/usr/bin/env bash
# tests/agent-vault-managed-env.test.sh
# managed settings の drop-in に wrapper と同じ env を書く agent-vault-managed-env.sh のテスト。
# Run from anywhere: bash tests/agent-vault-managed-env.test.sh
# Requires: jq, python3
#
# 偽の token / CA bundle と、python3 で 127.0.0.1 の空き port を listen して agent-vault の代わりにする。
# 出力先は $TMPDIR 配下（実際の /Library には触れない）。chown は偽物（root:staff を記録するだけ）、
# mv は引数を記録してから本物を呼ぶ。wrapper（claude-code/bin/claude）は claude.test.sh と同じく
# 偽の実体を exec させ、付いた env を drop-in の env と突き合わせる。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/home-manager/home/file/agent-vault/agent-vault-managed-env.sh"
WRAPPER="${REPO_ROOT}/claude-code/bin/claude"

for cmd in jq python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "${cmd} required (nix develop -c tests/agent-vault-managed-env.test.sh)" >&2
    exit 1
  fi
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-managed-env-test.XXXXXX")"
LISTENER_PID=""
cleanup() {
  if [ -n "${LISTENER_PID}" ]; then
    kill "${LISTENER_PID}" 2>/dev/null || true
  fi
  rm -rf "${TMPROOT}"
}
trap cleanup EXIT

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
# fixture
# ---------------------------------------------------------------------------
HOME_T="${TMPROOT}/home"
TOKEN_FILE="${HOME_T}/.agent-vault/proxy-token"
CA_BUNDLE="${HOME_T}/.local/state/agent-vault/ca-bundle.pem"
STUB_BIN="${TMPROOT}/stub-bin"
STUB_OUT="${TMPROOT}/stub-out"
FAKE_BIN="${TMPROOT}/fake-bin"
UTIL_BIN="${TMPROOT}/util-bin"
mkdir -p "$(dirname "${TOKEN_FILE}")" "$(dirname "${CA_BUNDLE}")" "${STUB_BIN}" "${STUB_OUT}" "${FAKE_BIN}" "${UTIL_BIN}"

printf '  tok_123\n' >"${TOKEN_FILE}"
printf -- '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n' >"${CA_BUNDLE}"

# 偽の chown（root にはなれないので引数だけ記録する）と、引数を記録して本物を呼ぶ mv
cat >"${STUB_BIN}/chown" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${STUB_OUT}/chown"
EOF
cat >"${STUB_BIN}/mv" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${STUB_OUT}/mv"
exec "$(command -v mv)" "\$@"
EOF
chmod +x "${STUB_BIN}/chown" "${STUB_BIN}/mv"

# wrapper が exec する偽の実体: wrapper が付ける env のうち、付いているものを K=V で 1 行ずつ出す
cat >"${FAKE_BIN}/claude" <<'EOF'
#!/usr/bin/env bash
for v in HTTPS_PROXY HTTP_PROXY NO_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE GIT_SSL_CAINFO CLAUDE_GH_VAULT \
  GIT_CONFIG_COUNT; do
  if [ -n "${!v+x}" ]; then printf '%s=%s\n' "$v" "${!v}"; fi
done
i=0
while [ "$i" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
  k="GIT_CONFIG_KEY_$i" v="GIT_CONFIG_VALUE_$i"
  printf '%s=%s\n%s=%s\n' "$k" "${!k}" "$v" "${!v}"
  i=$((i + 1))
done
EOF
chmod +x "${FAKE_BIN}/claude"
# wrapper のシェバン（#!/usr/bin/env bash）と内部で使うコマンドだけを置いた dir
for cmd in bash env tr readlink dirname; do
  ln -s "$(command -v "${cmd}")" "${UTIL_BIN}/${cmd}"
done

# agent-vault の代わりに listen する。port は空きを OS に選ばせる
python3 -I -c '
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(16)
print(s.getsockname()[1], flush=True)
time.sleep(600)
' >"${TMPROOT}/port" &
LISTENER_PID=$!
for _ in $(seq 1 50); do
  [ -s "${TMPROOT}/port" ] && break
  sleep 0.1
done
OPEN_PORT="$(cat "${TMPROOT}/port")"
CLOSED_PORT="$(python3 -I -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"

# run_script <out> [VAR=value...]: 書き出しスクリプトを走らせる。結果は RC / ERR
run_script() {
  local out="$1"
  shift
  set +e
  env -i HOME="${HOME_T}" PATH="${STUB_BIN}:${PATH}" \
    AGENT_VAULT_PROXY_PORT="${OPEN_PORT}" \
    AGENT_VAULT_MANAGED_SETTINGS="${out}" \
    "$@" bash "${SCRIPT}" 2>"${TMPROOT}/err"
  RC=$?
  set -e
  ERR="$(cat "${TMPROOT}/err")"
}

# wrapper_env [VAR=value...]: 同じ条件で wrapper が実体に付ける env（K=V を sort したもの）
wrapper_env() {
  env -i HOME="${HOME_T}" PATH="${FAKE_BIN}:${UTIL_BIN}" \
    AGENT_VAULT_PROXY_PORT="${OPEN_PORT}" \
    "$@" "${WRAPPER}" 2>/dev/null | sort
}

# dropin_env <out>: drop-in の env（K=V を sort したもの）
dropin_env() {
  jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$1" | sort
}

ACTIVE_ENV="$(jq -n --arg proxy "http://tok_123:default@127.0.0.1:${OPEN_PORT}" --arg ca "${CA_BUNDLE}" '{
  HTTPS_PROXY: $proxy, HTTP_PROXY: $proxy, NO_PROXY: "localhost,127.0.0.1,::1",
  NODE_EXTRA_CA_CERTS: $ca, SSL_CERT_FILE: $ca, GIT_SSL_CAINFO: $ca,
  CLAUDE_GH_VAULT: "1",
  GIT_CONFIG_COUNT: "3",
  GIT_CONFIG_KEY_0: "credential.https://github.com.helper", GIT_CONFIG_VALUE_0: "",
  GIT_CONFIG_KEY_1: "branch.autoSetupMerge", GIT_CONFIG_VALUE_1: "false",
  GIT_CONFIG_KEY_2: "push.default", GIT_CONFIG_VALUE_2: "current"}')"
INACTIVE_ENV='{
  "GIT_CONFIG_COUNT": "2",
  "GIT_CONFIG_KEY_0": "branch.autoSetupMerge", "GIT_CONFIG_VALUE_0": "false",
  "GIT_CONFIG_KEY_1": "push.default", "GIT_CONFIG_VALUE_1": "current"}'

echo "=== agent-vault-managed-env tests ==="
echo ""
echo "--- 判定と出力（wrapper と同じ） ---"

# check_case <name> <expected env JSON> [VAR=value...]: drop-in が妥当な JSON で env がちょうど期待どおり、
# かつ同じ条件で wrapper が付ける env（GIT_CONFIG_* の並びを含む）と一致する
check_case() {
  local name="$1" expected="$2" out actual from_wrapper
  shift 2
  out="${TMPROOT}/${name}/managed-settings.d/50-agent-vault.json"
  echo "- ${name}"
  run_script "${out}" "$@"
  if [ "${RC}" -eq 0 ] && jq -e --argjson want "${expected}" '. == {env: $want}' "${out}" >/dev/null 2>&1; then
    pass "${name}_writes_env"
  else
    fail "${name}_writes_env" "rc=${RC} out=$(cat "${out}" 2>/dev/null || echo '<missing>') err=${ERR}"
    return 0
  fi
  actual="$(dropin_env "${out}")"
  from_wrapper="$(wrapper_env "$@")"
  if [ -n "${from_wrapper}" ] && [ "${actual}" = "${from_wrapper}" ]; then
    pass "${name}_matches_wrapper_env"
  else
    fail "${name}_matches_wrapper_env" "drop-in=[${actual}] wrapper=[${from_wrapper}]"
  fi
}

check_case active_vault "${ACTIVE_ENV}"
check_case no_token "${INACTIVE_ENV}" AGENT_VAULT_PROXY_TOKEN_FILE="${TMPROOT}/missing-token"
check_case no_ca_bundle "${INACTIVE_ENV}" AGENT_VAULT_CA_BUNDLE="${TMPROOT}/missing-ca.pem"
check_case closed_port "${INACTIVE_ENV}" AGENT_VAULT_PROXY_PORT="${CLOSED_PORT}"

# AGENT_VAULT_VAULT で vault 名（proxy URL の password 部）を変えられる
echo "- vault_name_override"
out="${TMPROOT}/vault-name/50-agent-vault.json"
run_script "${out}" AGENT_VAULT_VAULT=work
if [ "${RC}" -eq 0 ] &&
  [ "$(jq -r '.env.HTTPS_PROXY' "${out}")" = "http://tok_123:work@127.0.0.1:${OPEN_PORT}" ]; then
  pass "vault_name_override"
else
  fail "vault_name_override" "rc=${RC} out=$(cat "${out}" 2>/dev/null || echo '<missing>') err=${ERR}"
fi

echo ""
echo "--- 書き出し ---"

DIR="${TMPROOT}/write/managed-settings.d"
OUT="${DIR}/50-agent-vault.json"
# stat の書式は BSD と GNU（nix develop の coreutils）で違うので python3 で読む
inode_of() {
  python3 -I -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$1"
}
mode_of() {
  python3 -I -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"
}

# ---------------------------------------------------------------------------
# write_via_temp_file_with_mode_0640: 同じ dir の一時ファイルを root:staff 0640 にしてから mv で置き換え、
# dir には drop-in だけが残る（managed-settings.json 本体は作らない）
# ---------------------------------------------------------------------------
echo "- write_via_temp_file_with_mode_0640"
rm -f "${STUB_OUT}/chown" "${STUB_OUT}/mv"
run_script "${OUT}"
mv_args="$(cat "${STUB_OUT}/mv" 2>/dev/null || true)"
chown_args="$(cat "${STUB_OUT}/chown" 2>/dev/null || true)"
tmp_src="${mv_args#-f }"
tmp_src="${tmp_src% "${OUT}"}"
perm="$(mode_of "${OUT}" 2>/dev/null || true)"
if [ "${RC}" -eq 0 ] && [ "${mv_args}" = "-f ${tmp_src} ${OUT}" ] &&
  [ "$(dirname "${tmp_src}")" = "${DIR}" ] &&
  case "${tmp_src}" in *.json) false ;; *) true ;; esac &&
  [ "${chown_args}" = "root:staff ${tmp_src}" ] &&
  [ "${perm}" = 0o640 ] &&
  [ "$(ls -A "${DIR}")" = "50-agent-vault.json" ]; then
  pass "write_via_temp_file_with_mode_0640"
else
  fail "write_via_temp_file_with_mode_0640" \
    "rc=${RC} mv=[${mv_args}] chown=[${chown_args}] perm=${perm} dir=[$(ls -A "${DIR}" 2>/dev/null)] err=${ERR}"
fi

# ---------------------------------------------------------------------------
# unchanged_content_is_not_rewritten: 内容が同じなら置き換えない（mtime・inode が変わらず、一時ファイルも残らない）
# ---------------------------------------------------------------------------
echo "- unchanged_content_is_not_rewritten"
touch -t 202001010000 "${OUT}"
touch -t 202001010001 "${TMPROOT}/mtime-ref"
inode_before="$(inode_of "${OUT}")"
rm -f "${STUB_OUT}/chown" "${STUB_OUT}/mv"
run_script "${OUT}"
if [ "${RC}" -eq 0 ] && [ "${OUT}" -ot "${TMPROOT}/mtime-ref" ] &&
  [ "$(inode_of "${OUT}")" = "${inode_before}" ] &&
  [ ! -e "${STUB_OUT}/mv" ] &&
  [ "$(ls -A "${DIR}")" = "50-agent-vault.json" ]; then
  pass "unchanged_content_is_not_rewritten"
else
  fail "unchanged_content_is_not_rewritten" \
    "rc=${RC} mv=[$(cat "${STUB_OUT}/mv" 2>/dev/null)] dir=[$(ls -A "${DIR}")] err=${ERR}"
fi

# ---------------------------------------------------------------------------
# changed_content_is_replaced: agent-vault が落ちたら proxy 抜きの内容に置き換える（別の inode = mv）
# ---------------------------------------------------------------------------
echo "- changed_content_is_replaced"
run_script "${OUT}" AGENT_VAULT_PROXY_PORT="${CLOSED_PORT}"
if [ "${RC}" -eq 0 ] && [ "$(inode_of "${OUT}")" != "${inode_before}" ] &&
  jq -e --argjson want "${INACTIVE_ENV}" '. == {env: $want}' "${OUT}" >/dev/null &&
  [ "$(ls -A "${DIR}")" = "50-agent-vault.json" ]; then
  pass "changed_content_is_replaced"
else
  fail "changed_content_is_replaced" "rc=${RC} out=$(cat "${OUT}") dir=[$(ls -A "${DIR}")] err=${ERR}"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
echo "PASS: agent-vault-managed-env"
