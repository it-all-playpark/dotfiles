#!/usr/bin/env bash
# tests/run-all.sh
# repo 内のテストを全部まとめて並列に走らせる。pre-push hook と CI から呼ぶ。
# Run from anywhere: bash tests/run-all.sh   （依存込みなら nix develop -c tests/run-all.sh）
#
# 対象（新しいテストは命名を合わせれば自動で拾われる）:
#   *.test.sh / *_test.sh / test-*.sh（tests/ claude-code/ scripts/ 配下） → bash で実行
#   *.bats → bats で実行
# 各テストは自前の mktemp 領域で完結している前提なので並列に流す。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-all-tests.XXXXXX")"
trap 'rm -rf "${LOG_DIR}"' EXIT

# process substitution は Claude の sandbox で /dev/fd が塞がれるので一時ファイル経由
find tests claude-code scripts -type f \
  \( -name '*.test.sh' -o -name '*_test.sh' -o -name 'test-*.sh' -o -name '*.bats' \) |
  sort >"${LOG_DIR}/list"
TESTS=()
while IFS= read -r f; do
  TESTS+=("${f}")
done <"${LOG_DIR}/list"

if [ "${#TESTS[@]}" -eq 0 ]; then
  echo "run-all: no tests found" >&2
  exit 1
fi

if printf '%s\n' "${TESTS[@]}" | grep -q '\.bats$' && ! command -v bats >/dev/null 2>&1; then
  echo "run-all: bats が見つからない（nix develop -c tests/run-all.sh で走らせる）" >&2
  exit 1
fi

PIDS=()
for i in "${!TESTS[@]}"; do
  f="${TESTS[$i]}"
  case "${f}" in
  *.bats) bats "${f}" >"${LOG_DIR}/${i}.log" 2>&1 & ;;
  *) bash "${f}" >"${LOG_DIR}/${i}.log" 2>&1 & ;;
  esac
  PIDS+=("$!")
done

FAILED=()
for i in "${!TESTS[@]}"; do
  if wait "${PIDS[$i]}"; then
    echo "ok   ${TESTS[$i]}"
  else
    echo "FAIL ${TESTS[$i]}"
    FAILED+=("${i}")
  fi
done

for i in "${FAILED[@]+"${FAILED[@]}"}"; do
  echo ""
  echo "===== ${TESTS[$i]} ====="
  cat "${LOG_DIR}/${i}.log"
done

echo ""
echo "run-all: $((${#TESTS[@]} - ${#FAILED[@]})) passed, ${#FAILED[@]} failed (${#TESTS[@]} files)"
[ "${#FAILED[@]}" -eq 0 ]
