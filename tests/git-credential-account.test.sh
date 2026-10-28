#!/usr/bin/env bash
# tests/git-credential-account.test.sh
# home-manager/programs/git.nix の github.com 向け credential helper が gh の shim（account-exec）を通り、
# repo の org に応じた GH_CONFIG_DIR で gh auth git-credential を呼ぶことを確かめる。
# Run from the repo root: bash tests/git-credential-account.test.sh
# Requires: git, jq
#
# git.nix から helper の文字列を取り出し、${pkgs.gh} を fake の gh（受け取った GH_CONFIG_DIR を password として返す）に
# 差し替えて、一時 HOME の ~/.claude/bin/gh（実物の claude-code/bin/gh への symlink）から呼ばせる。
# PATH には gh を置かない（GUI の git クライアントと同じ）ので、helper が自分で gh の実体を渡さないと shim が落ちる。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_NIX="${REPO_ROOT}/home-manager/programs/git.nix"
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

# /var → /private/var のような symlink を解決しておく（shim は $PWD と HOME の前方一致で org を判定する）
WORK="$(mktemp -d "${TMPDIR:-/tmp}/git-credential-account-test.XXXXXX")"
WORK="$(cd "${WORK}" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

HOME_T="${WORK}/home"
FAKE_GH_ROOT="${WORK}/fake-gh"
TOOLS="${WORK}/tools"
ALIAS_REPO="${HOME_T}/ghq/github.com-work/acme/repo"
UNMAPPED_REPO="${HOME_T}/ghq/github.com/nobody/repo"
OUTSIDE_DIR="${HOME_T}/elsewhere"
mkdir -p "${HOME_T}/.claude/bin" "${FAKE_GH_ROOT}/bin" "${TOOLS}" "${ALIAS_REPO}" "${UNMAPPED_REPO}" "${OUTSIDE_DIR}"

ln -s "${REPO_ROOT}/claude-code/bin/gh" "${HOME_T}/.claude/bin/gh"

cat >"${HOME_T}/account-map.json" <<'EOF'
{ "orgs": { "acme": { "gh_config_dir": "~/.config/gh-acme" } } }
EOF

# git credential helper の get に、受け取った GH_CONFIG_DIR を password として返す
cat >"${FAKE_GH_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
if [ "$*" = "auth git-credential get" ]; then
  printf 'username=x-access-token\npassword=%s\n' "${GH_CONFIG_DIR-<unset>}"
fi
EOF
chmod +x "${FAKE_GH_ROOT}/bin/gh"

# shim と helper が使うコマンドだけを並べた PATH（gh は入れない）
for cmd in git bash jq basename dirname readlink env cat; do
  cmd_path="$(command -v "${cmd}")"
  ln -s "${cmd_path}" "${TOOLS}/${cmd}"
done
RUN_PATH="${TOOLS}:/usr/bin:/bin"

# git.nix の `"!… auth git-credential"` を取り出し、nix の文字列から git の設定値に戻す
helper_line="$(grep -F 'auth git-credential"' "${GIT_NIX}")"
helper="${helper_line#*\"}"
helper="${helper%\"*}"
helper="${helper//\\\"/\"}"
helper="${helper//\$\{pkgs.gh\}/${FAKE_GH_ROOT}}"

# fill_password <cwd> [git の前置引数...] — git credential fill が返した password を出す
fill_password() {
  local dir="$1"
  shift
  (cd "${dir}" && printf 'protocol=https\nhost=github.com\npath=acme/repo.git\n\n' |
    env -i HOME="${HOME_T}" PATH="${RUN_PATH}" ACCOUNT_MAP="${HOME_T}/account-map.json" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
      git "$@" -c "credential.https://github.com.helper=${helper}" credential fill 2>"${WORK}/err") |
    sed -n 's/^password=//p'
}

echo "=== git credential helper → gh shim tests ==="

echo "--- 1. helper が git.nix から取り出せる ---"
case "${helper}" in
!*"auth git-credential") pass "helper: ${helper}" ;;
*) fail "helper を取り出せない" "got: ${helper}" ;;
esac

echo "--- 2. マップにある org の repo（SSH host alias の置き場）で org の GH_CONFIG_DIR が付く ---"
got="$(fill_password "${ALIAS_REPO}" || true)"
if [ "${got}" = "${HOME_T}/.config/gh-acme" ]; then
  pass "GH_CONFIG_DIR=${got}"
else
  fail "org の GH_CONFIG_DIR が付かない" "got: ${got:-<empty>} / stderr: $(cat "${WORK}/err")"
fi

echo "--- 3. repo の外から git -C で操作しても repo の org で判定される ---"
got="$(fill_password "${OUTSIDE_DIR}" -C "${ALIAS_REPO}" || true)"
if [ "${got}" = "${HOME_T}/.config/gh-acme" ]; then
  pass "GH_CONFIG_DIR=${got}"
else
  fail "git -C で org の GH_CONFIG_DIR が付かない" "got: ${got:-<empty>} / stderr: $(cat "${WORK}/err")"
fi

echo "--- 4. マップに無い org では GH_CONFIG_DIR を付けない（既定の ~/.config/gh のまま） ---"
got="$(fill_password "${UNMAPPED_REPO}" || true)"
if [ "${got}" = "<unset>" ]; then
  pass "GH_CONFIG_DIR は未設定"
else
  fail "マップに無い org で GH_CONFIG_DIR が付いた" "got: ${got:-<empty>} / stderr: $(cat "${WORK}/err")"
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -ne 0 ]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
