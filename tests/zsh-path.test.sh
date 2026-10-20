#!/usr/bin/env bash
# tests/zsh-path.test.sh
# home-manager/programs/zsh.nix の envExtra（.zshenv）と initContent（.zshrc）が作る PATH の順序を確かめる。
# Run from the repo root: bash tests/zsh-path.test.sh
# Requires: awk, zsh
#
# nix の '' 文字列を awk で取り出し（インデントを外し、''${ を ${ に戻す）、ユーザーの rc を読まない zsh -f で source する。
# - 非対話: launchd 由来のセッションの Bash は .zshrc を読まないので、.zshenv だけで mise の shims が PATH に入り、
#   ~/.claude/bin がその前（先頭）にあること
# - 対話: .zshenv → .zprofile（loginExtra の /opt/homebrew/bin）→ .zshrc の後も ~/.claude/bin → mise の shims → その他

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZSH_NIX="${REPO_ROOT}/home-manager/programs/zsh.nix"
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zsh-path-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}"

# zsh.nix から `<name> = ''` 〜 `'';` の中身を取り出し、zsh のスクリプトとして書き出す
extract_nix_string() {
  local name="$1" out="$2"
  awk -v name="${name}" '
    !inside && $0 ~ "^ *" name " = '\'''\''$" { inside = 1; next }
    inside && /^ *'\'''\'';$/ { exit }
    inside {
      sub(/^      /, "")
      gsub(/'\'''\''\$\{/, "${")
      print
    }
  ' "${ZSH_NIX}" >"${out}"
  [ -s "${out}" ]
}

ZSH_BIN="$(command -v zsh || true)"

# PATH=/usr/bin:/bin から始めて、引数のファイルを順に source した後の PATH を 1 行 1 要素で出す
run_zsh_path() {
  # shellcheck disable=SC2016 # 意図的: 子の zsh が展開する
  env -i HOME="${FAKE_HOME}" USER=zsh-path-test PATH=/usr/bin:/bin "${ZSH_BIN}" -f -c '
    for f in "$@"; do source "$f"; done
    print -rl -- $path
  ' zsh "$@"
}

# 1 始まりの位置。無ければ 0
index_of() {
  local needle="$1" list="$2"
  printf '%s\n' "${list}" | awk -v n="${needle}" '$0 == n { print NR; found = 1; exit } END { if (!found) print 0 }'
}

CLAUDE_BIN="${FAKE_HOME}/.claude/bin"
MISE_SHIMS="${FAKE_HOME}/.local/share/mise/shims"

echo "=== zsh.nix PATH tests ==="

if [ -z "${ZSH_BIN}" ]; then
  fail "zsh_available" "zsh が見つからない"
elif ! extract_nix_string envExtra "${WORK}/zshenv" || ! extract_nix_string initContent "${WORK}/zshrc"; then
  fail "extract_nix_strings" "${ZSH_NIX} から envExtra / initContent を取り出せない"
else
  # -------------------------------------------------------------------------
  # 非対話 zsh（.zshenv だけ）
  # -------------------------------------------------------------------------
  echo "- noninteractive_envExtra_has_mise_shims_after_claude_bin"
  noninteractive="$(run_zsh_path "${WORK}/zshenv")"
  claude_idx="$(index_of "${CLAUDE_BIN}" "${noninteractive}")"
  shims_idx="$(index_of "${MISE_SHIMS}" "${noninteractive}")"
  if [ "${shims_idx}" -eq 0 ]; then
    fail "noninteractive_envExtra_has_mise_shims_after_claude_bin" \
      "envExtra の PATH に ${MISE_SHIMS} が無い: $(printf '%s' "${noninteractive}" | tr '\n' ':')"
  elif [ "${claude_idx}" -ne 1 ] || [ "${claude_idx}" -ge "${shims_idx}" ]; then
    fail "noninteractive_envExtra_has_mise_shims_after_claude_bin" \
      "${CLAUDE_BIN} が先頭（mise の shims より前）に無い: $(printf '%s' "${noninteractive}" | tr '\n' ':')"
  else
    pass "noninteractive_envExtra_has_mise_shims_after_claude_bin"
  fi

  # -------------------------------------------------------------------------
  # 対話 zsh（.zshenv → .zprofile の /opt/homebrew/bin → .zshrc）
  # -------------------------------------------------------------------------
  echo "- interactive_initContent_keeps_claude_bin_then_mise_shims"
  # shellcheck disable=SC2016 # 意図的: loginExtra と同じ行を子の zsh に展開させる
  printf 'export PATH="/opt/homebrew/bin:$PATH"\n' >"${WORK}/zprofile"
  interactive="$(run_zsh_path "${WORK}/zshenv" "${WORK}/zprofile" "${WORK}/zshrc")"
  first_three="$(printf '%s\n' "${interactive}" | awk 'NR <= 3' | tr '\n' ':')"
  shims_count="$(printf '%s\n' "${interactive}" | awk -v n="${MISE_SHIMS}" '$0 == n { c++ } END { print c + 0 }')"
  if [ "${first_three}" != "${CLAUDE_BIN}:${MISE_SHIMS}:/opt/homebrew/bin:" ]; then
    fail "interactive_initContent_keeps_claude_bin_then_mise_shims" \
      "PATH の先頭が ~/.claude/bin → mise の shims → その他 になっていない: $(printf '%s' "${interactive}" | tr '\n' ':')"
  elif [ "${shims_count}" -ne 1 ]; then
    fail "interactive_initContent_keeps_claude_bin_then_mise_shims" \
      "mise の shims が PATH に ${shims_count} 個ある: $(printf '%s' "${interactive}" | tr '\n' ':')"
  else
    pass "interactive_initContent_keeps_claude_bin_then_mise_shims"
  fi
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
