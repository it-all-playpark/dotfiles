#!/usr/bin/env bash
# tests/fish-mise-dirs.test.sh
# home-manager/programs/fish.nix の shellInit が、`mise activate fish --shims | source` と同じ箇所で
# mise の data / state / config ディレクトリを設定していることを確かめる（zsh 側は tests/zsh-path.test.sh）。
# Run from the repo root: bash tests/fish-mise-dirs.test.sh
# Requires: awk（fish があれば、取り出した行を実行して値も確かめる）
#
# `mise activate fish --shims | source` を含む、空行で区切られた段落を awk で取り出し（インデントを外す）、
# その段落に 3 変数の `set -gx` があることを確かめる。fish があるときは、その `MISE_*_DIR` の行だけを
# ユーザーの設定を読まない fish --no-config で実行し、
# - 値が無ければ <HOME>/.local/share/mise・<HOME>/.local/state/mise・<HOME>/.config/mise になること
# - 親が渡した値があれば上書きしないこと
# を確かめる。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FISH_NIX="${REPO_ROOT}/home-manager/programs/fish.nix"
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fish-mise-dirs-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}"

# mise activate の行を含む段落（空行区切り）から、MISE_*_DIR を扱う行を取り出す
awk '
  /^[[:space:]]*$/ {
    if (found) exit
    n = 0
    next
  }
  { sub(/^ +/, ""); lines[++n] = $0 }
  /^mise activate fish --shims \| source$/ { found = 1 }
  END {
    if (!found) exit
    for (i = 1; i <= n; i++) if (lines[i] ~ /^[^#]*MISE_(DATA|STATE|CONFIG)_DIR/) print lines[i]
  }
' "${FISH_NIX}" >"${WORK}/mise-dirs.fish"

# fish で取り出した行を実行した後の、子プロセスの環境の MISE_DATA_DIR:MISE_STATE_DIR:MISE_CONFIG_DIR を出す。
# 引数（VAR=value）は親が渡す環境変数として足す
run_fish_mise_dirs() {
  # shellcheck disable=SC2016 # 意図的: 子の fish が展開する
  env -i HOME="${FAKE_HOME}" PATH=/usr/bin:/bin "$@" "${FISH_BIN}" --no-config -c '
    source $argv[1]
    env
  ' "${WORK}/mise-dirs.fish" | awk -F= '
    $1 == "MISE_DATA_DIR" { d = substr($0, length($1) + 2) }
    $1 == "MISE_STATE_DIR" { s = substr($0, length($1) + 2) }
    $1 == "MISE_CONFIG_DIR" { c = substr($0, length($1) + 2) }
    END { print d ":" s ":" c }
  '
}

FISH_BIN="$(command -v fish || true)"

echo "=== fish.nix mise dirs tests ==="

echo "- shellInit_sets_mise_dirs_next_to_mise_activate"
missing=()
for var in MISE_DATA_DIR MISE_STATE_DIR MISE_CONFIG_DIR; do
  if ! grep -Eq "set -gx ${var} " "${WORK}/mise-dirs.fish"; then
    missing+=("${var}")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  fail "shellInit_sets_mise_dirs_next_to_mise_activate" \
    "mise activate fish --shims の段落に set -gx が無い: ${missing[*]}"
else
  pass "shellInit_sets_mise_dirs_next_to_mise_activate"

  if [ -z "${FISH_BIN}" ]; then
    echo "- fish が無いので、値を実行して確かめるケースは走らせない"
  else
    echo "- shellInit_sets_mise_dirs_under_home"
    mise_dirs="$(run_fish_mise_dirs)"
    expected_dirs="${FAKE_HOME}/.local/share/mise:${FAKE_HOME}/.local/state/mise:${FAKE_HOME}/.config/mise"
    if [ "${mise_dirs}" != "${expected_dirs}" ]; then
      fail "shellInit_sets_mise_dirs_under_home" \
        "MISE_DATA_DIR:MISE_STATE_DIR:MISE_CONFIG_DIR が ${expected_dirs} でない: ${mise_dirs}"
    else
      pass "shellInit_sets_mise_dirs_under_home"
    fi

    echo "- shellInit_keeps_given_mise_dirs"
    given_dirs="$(run_fish_mise_dirs MISE_DATA_DIR=/real/data MISE_STATE_DIR=/real/state MISE_CONFIG_DIR=/real/config)"
    if [ "${given_dirs}" != "/real/data:/real/state:/real/config" ]; then
      fail "shellInit_keeps_given_mise_dirs" \
        "親が渡した値（/real/data:/real/state:/real/config）が残っていない: ${given_dirs}"
    else
      pass "shellInit_keeps_given_mise_dirs"
    fi
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
