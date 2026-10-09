#!/usr/bin/env bash
# tests/agent-vault.test.sh
# agent-vault（Claude Code 本体の上流 proxy。home-manager/programs/agent-vault.nix）の設定を検証する。
# Run from anywhere: bash tests/agent-vault.test.sh
# Requires: jq, yq (yq-go), python3 / nix（tier-2、daemon に届くときだけ）
#
# - agent-vault-server.sh: Keychain のマスターパスワードを stdin で server に渡し、CA bundle を書く
#   （偽の security / agent-vault を使う。Keychain・ネットワークには触れない）
# - services.yaml / account-map.json / agent-vault-gh/*/hosts.yml: gh のアカウント（placeholder）と
#   git の振り分けが 3 か所で食い違わない
# - settings.json: sandbox から ~/.agent-vault（DB・CA 鍵・セッション・proxy token）を読めず、
#   gh の placeholder 入り config dir は読める。managed settings の drop-in（proxy token 入り）も読めない
# - lib/agent-vault: 固定した版の binary（tier-2 で実際に build して version を見る）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${REPO_ROOT}/home-manager/home/file/agent-vault/agent-vault-server.sh"
SERVICES_EXAMPLE="${REPO_ROOT}/home-manager/home/file/agent-vault/services.example.yaml"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"
WRAPPER="${REPO_ROOT}/claude-code/bin/claude"
MANAGED_ENV="${REPO_ROOT}/home-manager/home/file/agent-vault/agent-vault-managed-env.sh"
ACCOUNT_MAP_EXAMPLE="${REPO_ROOT}/claude-code/account-map.example.json"
VAULT_GH_SRC="${REPO_ROOT}/home-manager/home/file/agent-vault-gh"
VAULT_GH_EXAMPLE="${REPO_ROOT}/home-manager/home/file/agent-vault-gh.example"
DOTFILES_PRIVATE="${DOTFILES_PRIVATE:-${HOME}/ghq/github.com/it-all-playpark/dotfiles-private}"
LABEL=""

PASS=0
FAIL=0
SKIP=0
ERRORS=()

pass() {
  echo "  PASS: $1${LABEL:+ [${LABEL}]}"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1${LABEL:+ [${LABEL}]}"
  echo "        $2"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1${LABEL:+ [${LABEL}]}: $2")
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
# argv はファイルから直接 grep する。`printf | grep -q` は grep が先に一致して抜けると
# printf（bash の builtin は 1 行ずつ write する）が SIGPIPE で落ち、pipefail で偽になる
if [ "${RC}" -eq 0 ] &&
  [ "$(cat "${STUB_OUT}/server.stdin" 2>/dev/null)" = "pw-s3cret" ] &&
  grep -qx -- '--password-stdin' "${STUB_OUT}/server.argv" &&
  grep -qx -- '--mitm-port' "${STUB_OUT}/server.argv" &&
  grep -qx -- '14322' "${STUB_OUT}/server.argv" &&
  ! grep -q 'pw-s3cret' "${STUB_OUT}/server.argv" "${STUB_OUT}/server.env"; then
  pass "launcher_passes_password_via_stdin"
else
  fail "launcher_passes_password_via_stdin" "rc=${RC} argv=${argv} err=$(cat "${TMPROOT}/launcher.err")"
fi

# ---------------------------------------------------------------------------
# launcher_writes_ca_bundle: システムの CA bundle + agent-vault の CA を連結して書く
# （書くのは server と並行して動く background job なので、期待する内容になり、job が最後に
# 書くログが出るまで待つ。ログ前に抜けると、次のケースが launcher.err を作り直した後に
# この job のログが先頭へ上書きされる）
# ---------------------------------------------------------------------------
echo "- launcher_writes_ca_bundle"
expected="$(cat "${TMPROOT}/system-ca.pem")"$'\n'"-----BEGIN CERTIFICATE-----"$'\n'"VAULT-CA"$'\n'"-----END CERTIFICATE-----"
for _ in $(seq 1 50); do
  [ "$(cat "${CA_BUNDLE}" 2>/dev/null)" = "${expected}" ] &&
    grep -q 'wrote CA bundle' "${TMPROOT}/launcher.err" && break
  sleep 0.1
done
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

# check_config_set <label> <services.yaml> <account-map.json> <hosts.yml の dir>...:
# gh のアカウント（placeholder）と git の振り分けが services / account-map / hosts.yml の 3 か所で
# 食い違わないことを確かめる。public の example 一式は常に、private repo（取引先の名前を含む本物）は
# checkout があるときだけ確かめる
check_config_set() {
  LABEL="$1"
  SERVICES="$2"
  ACCOUNT_MAP="$3"
  shift 3
  VAULT_GH_DIRS=("$@")

  echo ""
  echo "--- services.yaml / account-map.json / hosts.yml (${LABEL}) ---"

  SERVICES_JSON="$(yq -o=json '.' "${SERVICES}")"

  # service_auth <host>: host がちょうど一致する service の auth を compact JSON で出す
  service_auth() {
    printf '%s' "${SERVICES_JSON}" | jq -c --arg h "$1" '[.services[] | select(.host == $h) | .auth]'
  }

  # ---------------------------------------------------------------------------
  # services_api_is_passthrough_with_header_substitutions: api.github.com は認証を付けず
  # （placeholder を送らない client は認証なし）、ヘッダの placeholder だけを vault の token に置き換える。
  # REST の owner 別 service は持たない（GraphQL は path で振り分けられないので、アカウントは送る側が選ぶ）
  # ---------------------------------------------------------------------------
  echo "- services_api_is_passthrough_with_header_substitutions"
  api_services="$(printf '%s' "${SERVICES_JSON}" | jq -c '[.services[] | select(.host | startswith("api.github.com"))]')"
  if printf '%s' "${api_services}" | jq -e '
    length == 1 and .[0].host == "api.github.com" and .[0].auth == {"type": "passthrough"}
    and (.[0].substitutions | length > 0)
    and all(.[0].substitutions[]; .in == ["header"] and (.placeholder | test("^__gh_[a-z0-9_]+__$")))' >/dev/null; then
    pass "services_api_is_passthrough_with_header_substitutions"
  else
    fail "services_api_is_passthrough_with_header_substitutions" "api.github.com services=${api_services}"
  fi

  # vault_key_of_dir <~/.config/agent-vault-gh/<account>>: その dir の hosts.yml（repo の
  # home-manager/home/file/agent-vault-gh/<account>/hosts.yml）の placeholder を置き換える vault の key。
  # hosts.yml が無い・user の token と既定の token が食い違う・置換の定義が無いときは空
  vault_key_of_dir() {
    local account hosts placeholder
    # shellcheck disable=SC2088 # 意図的: account-map の値の "~/" を文字列として比べる（展開しない）
    case "$1" in
    "~/.config/agent-vault-gh/"*) account="${1#"~/.config/agent-vault-gh/"}" ;;
    *) return 0 ;;
    esac
    hosts=""
    for d in "${VAULT_GH_DIRS[@]}"; do
      if [ -f "${d}/${account}/hosts.yml" ]; then
        hosts="${d}/${account}/hosts.yml"
        break
      fi
    done
    [ -n "${hosts}" ] || return 0
    placeholder="$(yq -o=json '.' "${hosts}" | jq -r '
    .["github.com"] as $h
    | if ($h.users[$h.user].oauth_token) == $h.oauth_token then $h.oauth_token else empty end')"
    [ -n "${placeholder}" ] || return 0
    printf '%s' "${SERVICES_JSON}" | jq -r --arg p "${placeholder}" '
    [.services[] | select(.host == "api.github.com") | .substitutions[]? | select(.placeholder == $p) | .key] | first // empty'
  }

  # ---------------------------------------------------------------------------
  # accounts_resolve_to_substitutions: account-map の gh_vault_config_dir（default と各 org）が、
  # placeholder 入りの hosts.yml を経て api.github.com の置換の key に届く
  # ---------------------------------------------------------------------------
  echo "- accounts_resolve_to_substitutions"
  unresolved=""
  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    [ -n "$(vault_key_of_dir "${dir}")" ] || unresolved="${unresolved} ${dir}"
  done <<<"$(jq -r '[.default.gh_vault_config_dir] + [.orgs[].gh_vault_config_dir] | map(select(. != null)) | unique | .[]' "${ACCOUNT_MAP}")"
  if [ -n "$(jq -r '.default.gh_vault_config_dir // empty' "${ACCOUNT_MAP}")" ] && [ -z "${unresolved}" ]; then
    pass "accounts_resolve_to_substitutions"
  else
    fail "accounts_resolve_to_substitutions" "default missing or unresolved:${unresolved}"
  fi

  # ---------------------------------------------------------------------------
  # git_routes_match_account_map: git（Basic 認証は置換が届かない）は path の owner で振り分ける。
  # github.com（既定）は default のアカウント、default と違うアカウントを使う org は
  # github.com/<org>/* でそのアカウント。それ以外の owner 別 git service は持たない
  # ---------------------------------------------------------------------------
  echo "- git_routes_match_account_map"
  default_key="$(vault_key_of_dir "$(jq -r '.default.gh_vault_config_dir // empty' "${ACCOUNT_MAP}")")"
  other_orgs="$(jq -r '.default.gh_vault_config_dir as $d
  | .orgs | to_entries[] | select(.value.gh_vault_config_dir != null and .value.gh_vault_config_dir != $d)
  | [.key, .value.gh_vault_config_dir] | @tsv' "${ACCOUNT_MAP}")"
  expected_git="github.com=${default_key}"
  while IFS=$'\t' read -r org dir; do
    [ -n "${org}" ] || continue
    expected_git="${expected_git}"$'\n'"github.com/${org}/*=$(vault_key_of_dir "${dir}")"
  done <<<"${other_orgs}"
  actual_git="$(printf '%s' "${SERVICES_JSON}" | jq -r '
  .services[] | select(.host == "github.com" or (.host | startswith("github.com/")))
  | select(.auth.type == "basic" and .auth.username == "GITHUB_GIT_USERNAME") | "\(.host)=\(.auth.password)"' | sort)"
  expected_git="$(printf '%s\n' "${expected_git}" | sort)"
  other_git="$(printf '%s' "${SERVICES_JSON}" | jq -r '
  .services[] | select(.host == "github.com" or (.host | startswith("github.com/")))
  | select((.auth.type == "basic" and .auth.username == "GITHUB_GIT_USERNAME") | not) | .host')"
  if [ -n "${default_key}" ] && [ "${actual_git}" = "${expected_git}" ] && [ -z "${other_git}" ]; then
    pass "git_routes_match_account_map"
  else
    fail "git_routes_match_account_map" "expected=[${expected_git}] actual=[${actual_git}] other=[${other_git}]"
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
}

check_config_set example "${SERVICES_EXAMPLE}" "${ACCOUNT_MAP_EXAMPLE}" "${VAULT_GH_SRC}" "${VAULT_GH_EXAMPLE}"
if [ -d "${DOTFILES_PRIVATE}" ]; then
  check_config_set private "${DOTFILES_PRIVATE}/agent-vault/services.yaml" "${DOTFILES_PRIVATE}/account-map.json" \
    "${VAULT_GH_SRC}" "${DOTFILES_PRIVATE}/agent-vault-gh"
else
  skip "config_set_private" "${DOTFILES_PRIVATE} not checked out"
fi
LABEL=""
ACCOUNT_MAP="${ACCOUNT_MAP_EXAMPLE}"

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
  read_denied "${HOME}/.agent-vault/session.json" &&
  read_denied "${token_path}"; then
  pass "settings_deny_read_agent_vault_dir"
else
  fail "settings_deny_read_agent_vault_dir" \
    "denyRead must cover ~/.agent-vault and the proxy token (${token_path:-<wrapper default not found>})"
fi

# managed settings の drop-in（proxy token 入り。agent-vault-managed-env.sh の既定の出力先）と、
# 同じ dir に作る一時ファイルも塞ぐ
# shellcheck disable=SC2016 # 意図的: スクリプトのソース上の "${...:-...}" を文字列として拾う
managed_out="$(sed -n 's/^out="\${AGENT_VAULT_MANAGED_SETTINGS:-\(.*\)}"$/\1/p' "${MANAGED_ENV}")"
echo "- settings_deny_read_managed_settings_dropin"
if [ -n "${managed_out}" ] &&
  read_denied "${managed_out}" &&
  read_denied "$(dirname "${managed_out}")/.$(basename "${managed_out}").XXXXXX"; then
  pass "settings_deny_read_managed_settings_dropin"
else
  fail "settings_deny_read_managed_settings_dropin" \
    "denyRead must cover the managed settings drop-in dir (${managed_out:-<script default not found>})"
fi

# CA bundle は sandbox 内のコマンドが読む（GIT_SSL_CAINFO 等）ので塞がない
echo "- settings_ca_bundle_readable"
if [ -n "${ca_default}" ] && ! read_denied "${ca_path}"; then
  pass "settings_ca_bundle_readable"
else
  fail "settings_ca_bundle_readable" "CA bundle (${ca_path:-<wrapper default not found>}) must stay readable from the sandbox"
fi

# gh の placeholder 入り config dir は sandbox 内の gh が読む（読めないと gh は起動もしない）ので塞がない
echo "- settings_vault_gh_config_readable"
blocked=""
while IFS= read -r dir; do
  [ -n "${dir}" ] || continue
  path="${HOME}/${dir#"~/"}/hosts.yml"
  if read_denied "${path}"; then blocked="${blocked} ${path}"; fi
done <<<"$(jq -r '[.default.gh_vault_config_dir] + [.orgs[].gh_vault_config_dir] | map(select(. != null)) | unique | .[]' "${ACCOUNT_MAP}")"
if [ -z "${blocked}" ]; then
  pass "settings_vault_gh_config_readable"
else
  fail "settings_vault_gh_config_readable" "denyRead blocks:${blocked}"
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
