#!/usr/bin/env bash
# tests/zsh-path.test.sh
# home-manager/programs/zsh.nix の envExtra（.zshenv）と initContent（.zshrc）が作る PATH の順序と、
# envExtra が export する mise の data / state / config ディレクトリを確かめる。
# Run from the repo root: bash tests/zsh-path.test.sh
# Requires: awk, zsh
#
# nix の '' 文字列を awk で取り出し（インデントを外し、''${ を ${ に戻す）、ユーザーの rc を読まない zsh -f で source する。
# - 非対話: launchd 由来のセッションの Bash は .zshrc を読まないので、.zshenv だけで mise の shims が PATH に入り、
#   ~/.claude/bin がその前（先頭）にあること。path_helper の entry（/usr/local/bin 等）が nix の entry の後に入ること
# - 対話: .zshenv → .zprofile（loginExtra の /opt/homebrew/bin）→ .zshrc の後も ~/.claude/bin → mise の shims → その他で、
#   同じ entry が 2 回現れないこと

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
# launchd が子プロセスに渡す既定の PATH
LAUNCHD_PATH=/usr/bin:/bin:/usr/sbin:/sbin

# launchd の既定と同じ PATH（LAUNCHD_PATH）から始めて、引数のファイルを順に source した後の PATH を 1 行 1 要素で出す
run_zsh_path() {
  # shellcheck disable=SC2016 # 意図的: 子の zsh が展開する
  env -i HOME="${FAKE_HOME}" USER=zsh-path-test PATH="${LAUNCHD_PATH}" "${ZSH_BIN}" -f -c '
    for f in "$@"; do source "$f"; done
    print -rl -- $path
  ' zsh "$@"
}

# envExtra を source した子プロセスの環境の MISE_DATA_DIR:MISE_STATE_DIR:MISE_CONFIG_DIR を出す。
# 引数（VAR=value）は親が渡す環境変数として足す
run_zsh_mise_dirs() {
  # shellcheck disable=SC2016 # 意図的: 子の zsh が展開する
  env -i HOME="${FAKE_HOME}" USER=zsh-path-test PATH=/usr/bin:/bin "$@" "${ZSH_BIN}" -f -c '
    source "$1"
    env | awk -F= '\''
      $1 == "MISE_DATA_DIR" { d = substr($0, length($1) + 2) }
      $1 == "MISE_STATE_DIR" { s = substr($0, length($1) + 2) }
      $1 == "MISE_CONFIG_DIR" { c = substr($0, length($1) + 2) }
      END { print d ":" s ":" c }
    '\''
  ' zsh "${WORK}/zshenv"
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

  # path_helper が /etc/paths・/etc/paths.d から組む entry（/usr/local/bin 等）が、envExtra の足す nix の entry の後に
  # その順のまま入る。期待値は envExtra を通さず、同じ PATH から path_helper を直接呼んで作る
  # （path_helper が無い環境では LAUNCHD_PATH のまま）
  echo "- noninteractive_envExtra_has_path_helper_entries_after_nix"
  # shellcheck disable=SC2016 # 意図的: 子の zsh が展開する
  system_entries="$(env -i PATH="${LAUNCHD_PATH}" "${ZSH_BIN}" -f -c '
    [[ -x /usr/libexec/path_helper ]] && eval "$(/usr/libexec/path_helper -s)"
    print -rl -- $path
  ')"
  last_nix_idx=0
  nix_missing=""
  for nix_entry in "${FAKE_HOME}/.nix-profile/bin" /etc/profiles/per-user/zsh-path-test/bin \
    /run/current-system/sw/bin /nix/var/nix/profiles/default/bin; do
    idx="$(index_of "${nix_entry}" "${noninteractive}")"
    [ "${idx}" -eq 0 ] && nix_missing="${nix_entry}"
    [ "${idx}" -gt "${last_nix_idx}" ] && last_nix_idx="${idx}"
  done
  prev_idx="${last_nix_idx}"
  out_of_order=""
  while IFS= read -r entry; do
    idx="$(index_of "${entry}" "${noninteractive}")"
    if [ "${idx}" -le "${prev_idx}" ]; then
      out_of_order="${entry}"
      break
    fi
    prev_idx="${idx}"
  done <<<"${system_entries}"
  if [ -n "${nix_missing}" ]; then
    fail "noninteractive_envExtra_has_path_helper_entries_after_nix" \
      "envExtra の PATH に ${nix_missing} が無い: $(printf '%s' "${noninteractive}" | tr '\n' ':')"
  elif [ -n "${out_of_order}" ]; then
    fail "noninteractive_envExtra_has_path_helper_entries_after_nix" \
      "${out_of_order} が無いか、path_helper の順（nix の entry の後）に並んでいない: $(printf '%s' "${noninteractive}" | tr '\n' ':')"
  else
    pass "noninteractive_envExtra_has_path_helper_entries_after_nix"
  fi

  # -------------------------------------------------------------------------
  # mise の data / state / config ディレクトリ（.zshenv だけ）
  # -------------------------------------------------------------------------
  echo "- noninteractive_envExtra_sets_mise_dirs_under_home"
  mise_dirs="$(run_zsh_mise_dirs)"
  expected_dirs="${FAKE_HOME}/.local/share/mise:${FAKE_HOME}/.local/state/mise:${FAKE_HOME}/.config/mise"
  if [ "${mise_dirs}" != "${expected_dirs}" ]; then
    fail "noninteractive_envExtra_sets_mise_dirs_under_home" \
      "MISE_DATA_DIR:MISE_STATE_DIR:MISE_CONFIG_DIR が ${expected_dirs} でない: ${mise_dirs}"
  else
    pass "noninteractive_envExtra_sets_mise_dirs_under_home"
  fi

  echo "- noninteractive_envExtra_keeps_given_mise_dirs"
  given_dirs="$(run_zsh_mise_dirs MISE_DATA_DIR=/real/data MISE_STATE_DIR=/real/state MISE_CONFIG_DIR=/real/config)"
  if [ "${given_dirs}" != "/real/data:/real/state:/real/config" ]; then
    fail "noninteractive_envExtra_keeps_given_mise_dirs" \
      "親が渡した値（/real/data:/real/state:/real/config）が残っていない: ${given_dirs}"
  else
    pass "noninteractive_envExtra_keeps_given_mise_dirs"
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
  duplicates="$(printf '%s\n' "${interactive}" | sort | uniq -d | tr '\n' ':')"
  if [ "${first_three}" != "${CLAUDE_BIN}:${MISE_SHIMS}:/opt/homebrew/bin:" ]; then
    fail "interactive_initContent_keeps_claude_bin_then_mise_shims" \
      "PATH の先頭が ~/.claude/bin → mise の shims → その他 になっていない: $(printf '%s' "${interactive}" | tr '\n' ':')"
  elif [ "${shims_count}" -ne 1 ]; then
    fail "interactive_initContent_keeps_claude_bin_then_mise_shims" \
      "mise の shims が PATH に ${shims_count} 個ある: $(printf '%s' "${interactive}" | tr '\n' ':')"
  elif [ -n "${duplicates}" ]; then
    fail "interactive_initContent_keeps_claude_bin_then_mise_shims" \
      "PATH に同じ entry が 2 回ある（${duplicates}）: $(printf '%s' "${interactive}" | tr '\n' ':')"
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
