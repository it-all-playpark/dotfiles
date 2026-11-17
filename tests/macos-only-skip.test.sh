#!/usr/bin/env bash
# tests/macos-only-skip.test.sh
# macOS 前提のテストが、Darwin 以外（zsh が無い環境を含む）では理由付きで SKIP して exit 0 で終わることを確かめる。
# Run from anywhere: bash tests/macos-only-skip.test.sh
#
# - claude-code/bin/wt-add.test.sh・tests/agent-vault-managed-env.test.sh・tests/uc-handoff.test.sh:
#   PATH の先頭に `Linux` を返す偽の uname を置いて走らせ、`SKIP: ` 行と exit 0 を確かめる
#   （macOS で走らせても Linux の分岐を通る）
# - tests/zsh-path.test.sh: zsh を含まない PATH で走らせ、`SKIP: zsh_available (zsh not found)` と exit 0 を確かめる

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macos-only-skip-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# 偽の uname: Linux を返す
FAKE_UNAME_DIR="${WORK}/fake-uname"
mkdir -p "${FAKE_UNAME_DIR}"
printf '#!/bin/sh\necho Linux\n' >"${FAKE_UNAME_DIR}/uname"
chmod +x "${FAKE_UNAME_DIR}/uname"

# zsh を含まない PATH: テストが使うコマンドだけを symlink で置いた dir
NO_ZSH_DIR="${WORK}/no-zsh-bin"
mkdir -p "${NO_ZSH_DIR}"
for cmd in bash env dirname basename mkdir mktemp rm cat awk sed grep tr sort uniq; do
  if src="$(command -v "${cmd}")"; then
    ln -s "${src}" "${NO_ZSH_DIR}/${cmd}"
  fi
done

# check_skips <name> <expected SKIP line prefix> <PATH> <script>: exit 0 で、期待した SKIP 行が出る
check_skips() {
  local name="$1" expected="$2" path_value="$3" script="$4" rc out
  set +e
  out="$(PATH="${path_value}" bash "${script}" 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ] && printf '%s\n' "${out}" | grep -qF "SKIP: ${expected}"; then
    pass "${name}"
  else
    fail "${name}" "rc=${rc} expected 'SKIP: ${expected}' in: $(printf '%s' "${out}" | tail -5)"
  fi
}

echo "=== macos-only-skip tests ==="

LINUX_PATH="${FAKE_UNAME_DIR}:${PATH}"
check_skips "wt_add_skips_not_darwin" "01_plain_worktree_add_fails (not Darwin)" \
  "${LINUX_PATH}" "${REPO_ROOT}/claude-code/bin/wt-add.test.sh"
check_skips "agent_vault_managed_env_skips_not_darwin" "active_vault_writes_env (not Darwin)" \
  "${LINUX_PATH}" "${REPO_ROOT}/tests/agent-vault-managed-env.test.sh"
check_skips "uc_handoff_skips_not_darwin" "uc-handoff --self-test (not Darwin)" \
  "${LINUX_PATH}" "${REPO_ROOT}/tests/uc-handoff.test.sh"
check_skips "zsh_path_skips_without_zsh" "zsh_available (zsh not found)" \
  "${NO_ZSH_DIR}" "${REPO_ROOT}/tests/zsh-path.test.sh"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
echo "PASS: macos-only-skip"
