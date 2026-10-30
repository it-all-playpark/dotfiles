#!/usr/bin/env bash
# tests/agent-vault-managed-env.test.sh
# managed settings の drop-in に wrapper と同じ env を書く agent-vault-managed-env.sh のテスト。
# Run from anywhere: bash tests/agent-vault-managed-env.test.sh
# Requires: jq, python3
#
# 偽の token / CA bundle と、python3 で 127.0.0.1 の空き port を listen して agent-vault の代わりにする。
# 出力先は $TMPDIR 配下（実際の /Library には触れない）。chown は偽物（root:wheel を記録するだけ）、
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
for v in HTTPS_PROXY HTTP_PROXY NO_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE GIT_SSL_CAINFO \
  CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE CLAUDE_GH_VAULT HOST_EXEC_ENV GIT_CONFIG_COUNT; do
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
  HTTPS_PROXY: $proxy, HTTP_PROXY: $proxy, NO_PROXY: "localhost,127.0.0.1,::1,fonts.googleapis.com,fonts.gstatic.com,zernio.com,api.anthropic.com",
  NODE_EXTRA_CA_CERTS: $ca, SSL_CERT_FILE: $ca, GIT_SSL_CAINFO: $ca,
  CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE: $ca,
  CLAUDE_GH_VAULT: "1",
  GIT_CONFIG_COUNT: "3",
  GIT_CONFIG_KEY_0: "credential.https://github.com.helper", GIT_CONFIG_VALUE_0: "",
  GIT_CONFIG_KEY_1: "branch.autoSetupMerge", GIT_CONFIG_VALUE_1: "false",
  GIT_CONFIG_KEY_2: "push.default", GIT_CONFIG_VALUE_2: "current",
  HOST_EXEC_ENV: ({HTTPS_PROXY: null, HTTP_PROXY: null, NO_PROXY: null,
    NODE_EXTRA_CA_CERTS: null, SSL_CERT_FILE: null, GIT_SSL_CAINFO: null,
    CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE: null, CLAUDE_GH_VAULT: null,
    AGENT_BROWSER_SOCKET_DIR: null, CODEX_HOME: null, PNPM_HOME: null, UV_CACHE_DIR: null,
    GIT_CONFIG_KEY_0: "branch.autoSetupMerge", GIT_CONFIG_VALUE_0: "false"} | tojson)}')"
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
echo "--- host-exec から外す env（settings.json の env で sandbox 内から書ける場所を指すもの） ---"

# sandbox_writable_env <settings.json>: env のうち、値が sandbox.filesystem.allowWrite のいずれか（またはその配下）を
# 指す変数名を JSON 配列（sort 済み）で出す。allowWrite の ** は任意の階層、* は 1 階層内の任意の文字列。
# ~/ は展開せずに env と allowWrite の両方の表記のまま比べる
sandbox_writable_env() {
  # shellcheck disable=SC2016 # 意図的: jq の式（$v / $pat / $pats は jq の変数）
  jq -c '.sandbox.filesystem.allowWrite as $pats
    | [.env | to_entries[] | select((.value | type) == "string") | .value as $v
      | select(any($pats[]; . as $pat | $v | test("^" + ($pat
          | gsub("(?<c>[.+?^${}()|\\[\\]\\\\])"; "\\\(.c)")
          | gsub("\\*\\*"; "\u0001") | gsub("\\*"; "[^/]*") | gsub("\u0001"; ".*")) + "(/.*)?$")))
      | .key] | sort' "$1"
}

# not_nulled <names JSON> <HOST_EXEC_ENV JSON>: names のうち HOST_EXEC_ENV で null（取り除く）になっていないもの
not_nulled() {
  # shellcheck disable=SC2016 # 意図的: jq の式（$names / $spec / $s / $k は jq の変数）
  jq -nc --argjson names "$1" --arg spec "$2" \
    '($spec | fromjson) as $s | [$names[] as $k | select(($s | has($k) | not) or $s[$k] != null) | $k]'
}

# ---------------------------------------------------------------------------
# sandbox_writable_env_is_enumerated: 列挙が allowWrite の配下・glob・~/ を拾い、隣の名前（/private/tmp/claudex）・
# パスでない値・文字列でない値は拾わない
# ---------------------------------------------------------------------------
echo "- sandbox_writable_env_is_enumerated"
cat >"${TMPROOT}/writable-settings.json" <<'EOF'
{"env": {"UNDER_TMP": "/private/tmp/claude/x", "TMP_ROOT": "/private/tmp/claude", "UNDER_HOME": "~/.cache/gh/y",
  "UNDER_GLOB": "~/.config/gcloud-a/b", "SIBLING": "/private/tmp/claudex", "OUTSIDE": "~/.cache/other",
  "PLAIN": "1", "URL": "direct://", "NUM": 1},
 "sandbox": {"filesystem": {"allowWrite": ["/private/tmp/claude", "~/.cache/gh", "~/.config/gcloud-*"]}}}
EOF
got="$(sandbox_writable_env "${TMPROOT}/writable-settings.json" 2>&1 || true)"
if [ "${got}" = '["TMP_ROOT","UNDER_GLOB","UNDER_HOME","UNDER_TMP"]' ]; then
  pass "sandbox_writable_env_is_enumerated"
else
  fail "sandbox_writable_env_is_enumerated" "got=${got}"
fi

# ---------------------------------------------------------------------------
# host_exec_env_drops_sandbox_writable_env: repo の settings.json の env のうち sandbox 内から書ける場所を指す変数は、
# wrapper（claude-code/bin/claude）と drop-in の両方の HOST_EXEC_ENV で null（host-exec の起動から外す）。
# host-exec は sandbox の外で動くので、残すと sandbox 内のプロセスが書き換えたキャッシュ・設定を sandbox の外で使う
# ---------------------------------------------------------------------------
echo "- host_exec_env_drops_sandbox_writable_env"
writable="$(sandbox_writable_env "${REPO_ROOT}/claude-code/settings.json")"
out="${TMPROOT}/host-exec-env/managed-settings.d/50-agent-vault.json"
run_script "${out}"
dropin_spec="$(jq -r '.env.HOST_EXEC_ENV // empty' "${out}" 2>/dev/null || true)"
wrapper_spec="$(wrapper_env | sed -n 's/^HOST_EXEC_ENV=//p')"
if [ "${RC}" -eq 0 ] && [ "${writable}" != "[]" ] && [ -n "${dropin_spec}" ] && [ -n "${wrapper_spec}" ] &&
  [ "$(not_nulled "${writable}" "${dropin_spec}")" = "[]" ] &&
  [ "$(not_nulled "${writable}" "${wrapper_spec}")" = "[]" ]; then
  pass "host_exec_env_drops_sandbox_writable_env"
else
  fail "host_exec_env_drops_sandbox_writable_env" \
    "rc=${RC} writable=${writable} drop-in HOST_EXEC_ENV=${dropin_spec} wrapper HOST_EXEC_ENV=${wrapper_spec} err=${ERR}"
fi

echo ""
echo "--- token ファイルの検査（root で読むので、リンクと他人のファイルは読まない） ---"

# check_token_rejected <name> [VAR=value...]: token を読まず、proxy 抜きの内容を書く
check_token_rejected() {
  local name="$1" out
  shift
  out="${TMPROOT}/${name}/50-agent-vault.json"
  echo "- ${name}"
  run_script "${out}" "$@"
  if [ "${RC}" -eq 0 ] && jq -e --argjson want "${INACTIVE_ENV}" '. == {env: $want}' "${out}" >/dev/null 2>&1; then
    pass "${name}"
  else
    fail "${name}" "rc=${RC} out=$(cat "${out}" 2>/dev/null || echo '<missing>') err=${ERR}"
  fi
}

# root 専用ファイルの代わり: 中身が token として通る別ファイルへの symlink
printf 'secret_from_target\n' >"${TMPROOT}/link-target"
ln -s "${TMPROOT}/link-target" "${TMPROOT}/proxy-token-link"
check_token_rejected token_symlink_is_not_followed AGENT_VAULT_PROXY_TOKEN_FILE="${TMPROOT}/proxy-token-link"
check_token_rejected token_owned_by_other_user_is_not_read AGENT_VAULT_TOKEN_OWNER=root

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
# write_via_temp_file_with_mode_0640: 同じ dir の一時ファイルを root:wheel 0640 + 実行ユーザーだけの読み取り ACL
# にしてから mv で置き換え（staff は macOS の標準ユーザー全員の primary group なので使わない）、
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
acl="$(/bin/ls -le "${OUT}" 2>/dev/null | sed -n '2,$p' || true)"
if [ "${RC}" -eq 0 ] && [ "${mv_args}" = "-f ${tmp_src} ${OUT}" ] &&
  [ "$(dirname "${tmp_src}")" = "${DIR}" ] &&
  case "${tmp_src}" in *.json) false ;; *) true ;; esac &&
  [ "${chown_args}" = "root:wheel ${tmp_src}" ] &&
  [ "${perm}" = 0o640 ] &&
  [ "$(printf '%s\n' "${acl}" | sed 's/^ *//')" = "0: user:$(id -un) allow read" ] &&
  [ "$(ls -A "${DIR}")" = "50-agent-vault.json" ]; then
  pass "write_via_temp_file_with_mode_0640"
else
  fail "write_via_temp_file_with_mode_0640" \
    "rc=${RC} mv=[${mv_args}] chown=[${chown_args}] perm=${perm} acl=[${acl}] dir=[$(ls -A "${DIR}" 2>/dev/null)] err=${ERR}"
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
echo "--- excludedCommands のホームパス（60-home-paths.json） ---"

# settings.json は ~/.claude/settings.json → repo の symlink なので、fixture も symlink にする
SETTINGS_SRC="${TMPROOT}/repo/claude-code/settings.json"
mkdir -p "$(dirname "${SETTINGS_SRC}")" "${HOME_T}/.claude"
ln -s "${SETTINGS_SRC}" "${HOME_T}/.claude/settings.json"
cat >"${SETTINGS_SRC}" <<'EOF'
{"env": {"TOOL_HOME": "~/.local/state/tool", "UV_CACHE_DIR": "/private/tmp/x", "OTHER": "a ~/b", "NUM": 1},
 "sandbox": {"excludedCommands": [
  "~/.claude/plugins/cache/playpark/*",
  "bash ~/.claude/plugins/cache/playpark/*",
  "python3 $HOME/.claude/plugins/cache/playpark/*",
  "git status",
  "/opt/tool/*"
]}}
EOF
HP_DIR="${TMPROOT}/home-paths/managed-settings.d"
HP_OUT="${HP_DIR}/60-home-paths.json"
HP_LISTING="$(printf '50-agent-vault.json\n60-home-paths.json')"

# ---------------------------------------------------------------------------
# tilde_entries_are_expanded_to_home: ~/ で始まるエントリ（コマンド名の後ろの ~/ も）と、値が ~/ で始まる env だけを
# 対象ユーザーのホームに置き換えて書く。$HOME 形式・他のエントリ・他の env は settings.json 側でそのまま効くので書かない。
# 50-agent-vault.json と同じ書き方（root:wheel 0640 + 実行ユーザーだけの読み取り ACL）
# ---------------------------------------------------------------------------
echo "- tilde_entries_are_expanded_to_home"
rm -f "${STUB_OUT}/chown"
run_script "${HP_DIR}/50-agent-vault.json"
want="$(jq -n --arg h "${HOME_T}" '{sandbox: {excludedCommands: [
  "\($h)/.claude/plugins/cache/playpark/*", "bash \($h)/.claude/plugins/cache/playpark/*"]},
  env: {TOOL_HOME: "\($h)/.local/state/tool"}}')"
acl="$(/bin/ls -le "${HP_OUT}" 2>/dev/null | sed -n '2,$p' || true)"
if [ "${RC}" -eq 0 ] && jq -e --argjson want "${want}" '. == $want' "${HP_OUT}" >/dev/null 2>&1 &&
  [ "$(mode_of "${HP_OUT}")" = 0o640 ] &&
  grep -q "^root:wheel ${HP_DIR}/.60-home-paths.json." "${STUB_OUT}/chown" &&
  [ "$(printf '%s\n' "${acl}" | sed 's/^ *//')" = "0: user:$(id -un) allow read" ] &&
  [ "$(ls -A "${HP_DIR}")" = "${HP_LISTING}" ]; then
  pass "tilde_entries_are_expanded_to_home"
else
  fail "tilde_entries_are_expanded_to_home" \
    "rc=${RC} out=$(cat "${HP_OUT}" 2>/dev/null || echo '<missing>') dir=[$(ls -A "${HP_DIR}")] err=${ERR}"
fi

# ---------------------------------------------------------------------------
# invalid_settings_keep_previous_dropin: settings.json が JSON として読めない（git 操作の途中など）ときは
# 前回の drop-in を残す（空にすると plugin のスクリプトが sandbox 内に戻る）
# ---------------------------------------------------------------------------
echo "- invalid_settings_keep_previous_dropin"
before="$(cat "${HP_OUT}")"
cp "${SETTINGS_SRC}" "${TMPROOT}/settings.bak"
printf '{"sandbox": ' >"${SETTINGS_SRC}"
run_script "${HP_DIR}/50-agent-vault.json"
cp "${TMPROOT}/settings.bak" "${SETTINGS_SRC}"
if [ "${RC}" -eq 0 ] && [ "$(cat "${HP_OUT}")" = "${before}" ] &&
  [ "$(ls -A "${HP_DIR}")" = "${HP_LISTING}" ]; then
  pass "invalid_settings_keep_previous_dropin"
else
  fail "invalid_settings_keep_previous_dropin" "rc=${RC} out=$(cat "${HP_OUT}") dir=[$(ls -A "${HP_DIR}")] err=${ERR}"
fi

# ---------------------------------------------------------------------------
# settings_owned_by_other_user_is_not_read: root で読むので、対象ユーザーのファイルでなければ読まない
# （root 専用の JSON への symlink にされると、その中身が drop-in に漏れる）。前回の drop-in も消す
# ---------------------------------------------------------------------------
echo "- settings_owned_by_other_user_is_not_read"
out_dir="${TMPROOT}/home-paths-other/managed-settings.d"
mkdir -p "${out_dir}"
cp "${HP_OUT}" "${out_dir}/60-home-paths.json"
run_script "${out_dir}/50-agent-vault.json" AGENT_VAULT_TOKEN_OWNER=root
if [ "${RC}" -eq 0 ] && [ ! -e "${out_dir}/60-home-paths.json" ] &&
  printf '%s\n' "${ERR}" | grep -q "removed ${out_dir}/60-home-paths.json: .* is not a regular file owned by root"; then
  pass "settings_owned_by_other_user_is_not_read"
else
  fail "settings_owned_by_other_user_is_not_read" "rc=${RC} dir=[$(ls -A "${out_dir}" 2>/dev/null)] err=${ERR}"
fi

# ---------------------------------------------------------------------------
# missing_settings_removes_dropin: settings.json が無い（symlink 先が消えた）ときは前回の drop-in を消す
# （sandbox 外で動かす許可を settings.json の実態より長く残さない）。無いままなら何もしない（ログも出さない）
# ---------------------------------------------------------------------------
echo "- missing_settings_removes_dropin"
mv "${SETTINGS_SRC}" "${TMPROOT}/settings.moved"
run_script "${HP_DIR}/50-agent-vault.json"
rc1="${RC}" err1="${ERR}"
run_script "${HP_DIR}/50-agent-vault.json"
mv "${TMPROOT}/settings.moved" "${SETTINGS_SRC}"
if [ "${rc1}" -eq 0 ] && [ "${RC}" -eq 0 ] && [ ! -e "${HP_OUT}" ] &&
  [ "$(ls -A "${HP_DIR}")" = "50-agent-vault.json" ] &&
  printf '%s\n' "${err1}" | grep -q "removed ${HP_OUT}: .* is missing" &&
  ! printf '%s\n' "${ERR}" | grep -q removed; then
  pass "missing_settings_removes_dropin"
else
  fail "missing_settings_removes_dropin" "rc1=${rc1} rc=${RC} dir=[$(ls -A "${HP_DIR}")] err1=${err1} err=${ERR}"
fi

# ---------------------------------------------------------------------------
# repo_settings_have_no_unexpanded_home: repo の settings.json を展開すると、ホーム基点のエントリが
# すべて対象ユーザーのホームに置き換わって drop-in に揃う（過不足なし。~/ のエントリが 0 件なら drop-in も空）
# ---------------------------------------------------------------------------
echo "- repo_settings_have_no_unexpanded_home"
cp "${REPO_ROOT}/claude-code/settings.json" "${SETTINGS_SRC}"
out_dir="${TMPROOT}/home-paths-repo/managed-settings.d"
run_script "${out_dir}/50-agent-vault.json"
got="$(jq -c '[(.sandbox.excludedCommands | sort), (.env // {})]' "${out_dir}/60-home-paths.json" 2>/dev/null || true)"
want="$(jq -c --arg h "${HOME_T}" \
  '[([.sandbox.excludedCommands[] | select(test("(^| )~/")) | sub("~/"; "\($h)/")] | sort),
    (.env | with_entries(select(.value | startswith("~/")) | .value |= sub("^~/"; "\($h)/")))]' \
  "${REPO_ROOT}/claude-code/settings.json")"
if [ "${RC}" -eq 0 ] && [ -n "${got}" ] && [ "${got}" = "${want}" ]; then
  pass "repo_settings_have_no_unexpanded_home"
else
  fail "repo_settings_have_no_unexpanded_home" "rc=${RC} want=${want} got=${got} err=${ERR}"
fi

echo ""
echo "--- LaunchDaemon の plist（darwin/agent-vault.nix、nix daemon 到達時のみ） ---"

# ---------------------------------------------------------------------------
# launchd_plist_waits_for_nix_store: 生成 plist は /bin/sh -c で /bin/wait4path /nix/store を待ってから
# bash でスクリプトを exec する（/nix/store の bash を直接起動すると、再起動直後にボリュームが未マウントで
# spawn failed のまま止まる）。他のキーは ProgramArguments 直書きだったときと同じ値
# ---------------------------------------------------------------------------
echo "- launchd_plist_waits_for_nix_store"
if command -v nix >/dev/null 2>&1 && nix store info >/dev/null 2>&1; then
  plist="$(nix build --no-link --print-out-paths \
    "${REPO_ROOT}#darwinConfigurations.MyMBP-naramotoyuuji.config.environment.launchDaemons.\"com.playpark.agent-vault-managed-env.plist\".source" \
    2>"${TMPROOT}/nix-build.err" || true)"
  got="$(python3 -I -c 'import json, plistlib, sys; print(json.dumps(plistlib.load(open(sys.argv[1], "rb"))))' \
    "${plist}" 2>/dev/null || true)"
  h=/Users/naramotoyuuji
  if [ -n "${got}" ] && printf '%s\n' "${got}" | jq -e --arg h "${h}" '
    (keys == ["EnvironmentVariables", "Label", "ProgramArguments", "RunAtLoad", "StandardErrorPath",
      "StandardOutPath", "StartInterval", "WatchPaths"]) and
    (.ProgramArguments | length == 3 and .[0] == "/bin/sh" and .[1] == "-c" and
      (.[2] | test("^/bin/wait4path /nix/store && exec /nix/store/[^/ ]+-bash[^/ ]*/bin/bash /nix/store/[^/ ]+-agent-vault-managed-env\\.sh$"))) and
    .Label == "com.playpark.agent-vault-managed-env" and
    (.EnvironmentVariables | del(.PATH) == {
      AGENT_VAULT_PROXY_TOKEN_FILE: "\($h)/.agent-vault/proxy-token",
      AGENT_VAULT_CA_BUNDLE: "\($h)/.local/state/agent-vault/ca-bundle.pem",
      AGENT_VAULT_TOKEN_OWNER: "naramotoyuuji",
      CLAUDE_USER_SETTINGS: "\($h)/.claude/settings.json",
      CLAUDE_USER_HOME: $h}) and
    (.EnvironmentVariables.PATH | test("^/nix/store/[^/]+-jq-[^/]+/bin:/usr/bin:/bin:/usr/sbin:/sbin$")) and
    .RunAtLoad == true and .StartInterval == 30 and
    .WatchPaths == ["\($h)/.agent-vault/proxy-token", "\($h)/.local/state/agent-vault/ca-bundle.pem"] and
    .StandardOutPath == "/var/log/agent-vault-managed-env.log" and
    .StandardErrorPath == "/var/log/agent-vault-managed-env.log"' >/dev/null; then
    pass "launchd_plist_waits_for_nix_store"
  else
    fail "launchd_plist_waits_for_nix_store" "plist=${plist} got=${got} err=$(tail -5 "${TMPROOT}/nix-build.err")"
  fi
else
  echo "  SKIP: launchd_plist_waits_for_nix_store (nix daemon unreachable)"
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
