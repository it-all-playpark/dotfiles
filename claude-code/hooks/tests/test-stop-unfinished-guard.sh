#!/usr/bin/env bash
# test-stop-unfinished-guard.sh
# stop-unfinished-guard.sh の振る舞いテスト
#
# 使い方: bash tests/test-stop-unfinished-guard.sh
#
# 検証項目:
#   1. main/master/dev/develop branch では exit 0
#   2. git 管理外ディレクトリでは exit 0
#   3. CLAUDE_STOP_GUARD=0 で bypass
#   4. feature branch で差分なしなら exit 0
#   5. feature branch で unstaged 差分があれば exit 2
#   6. feature branch で staged 差分があれば exit 2
#   7. detached HEAD では exit 0
#
# 終了コード: 0 = 全テスト pass / 1 = 1 件以上 fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="${SCRIPT_DIR}/../stop-unfinished-guard.sh"

if [[ ! -x ${HOOK_SCRIPT} ]]; then
  echo "ERROR: hook script not found or not executable: ${HOOK_SCRIPT}" >&2
  exit 1
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "${TMPROOT}"' EXIT

PASS=0
FAIL=0

run_case() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ ${actual} == "${expected}" ]]; then
    echo "PASS: ${name} (exit=${actual})"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${name} (expected=${expected} actual=${actual})" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Helper: run hook inside a given dir, capturing exit code without killing us.
# Stop hooks get a JSON blob on stdin; we emulate that.
run_hook() {
  local dir="$1"
  local rc=0
  (
    cd "${dir}"
    echo '{"session_id":"test","hook_event_name":"Stop"}' | bash "${HOOK_SCRIPT}" >/dev/null 2>&1
  ) || rc=$?
  echo "${rc}"
}

setup_repo() {
  local dir="$1"
  local branch="$2"
  mkdir -p "${dir}"
  (
    cd "${dir}"
    git init -q -b "${branch}"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "initial" >initial.txt
    git add initial.txt
    git commit -q -m "initial"
  )
}

# --- Case 1: main branch, with unstaged diff → exit 0 (guard inactive) ---
REPO1="${TMPROOT}/main-repo"
setup_repo "${REPO1}" "main"
echo "dirty" >>"${REPO1}/initial.txt"
run_case "main branch skips guard even with diff" "0" "$(run_hook "${REPO1}")"

# --- Case 2: dev branch, with unstaged diff → exit 0 ---
REPO2="${TMPROOT}/dev-repo"
setup_repo "${REPO2}" "dev"
echo "dirty" >>"${REPO2}/initial.txt"
run_case "dev branch skips guard" "0" "$(run_hook "${REPO2}")"

# --- Case 3: develop branch → exit 0 ---
REPO3="${TMPROOT}/develop-repo"
setup_repo "${REPO3}" "develop"
echo "dirty" >>"${REPO3}/initial.txt"
run_case "develop branch skips guard" "0" "$(run_hook "${REPO3}")"

# --- Case 4: non-git directory → exit 0 ---
NONGIT="${TMPROOT}/non-git"
mkdir -p "${NONGIT}"
run_case "non-git directory skips guard" "0" "$(run_hook "${NONGIT}")"

# --- Case 5: feature branch, clean → exit 0 ---
REPO5="${TMPROOT}/feature-clean"
setup_repo "${REPO5}" "feature/clean"
run_case "feature clean passes" "0" "$(run_hook "${REPO5}")"

# --- Case 6: feature branch, unstaged diff → exit 2 ---
REPO6="${TMPROOT}/feature-unstaged"
setup_repo "${REPO6}" "feature/dirty"
echo "dirty" >>"${REPO6}/initial.txt"
run_case "feature unstaged diff blocks" "2" "$(run_hook "${REPO6}")"

# --- Case 7: feature branch, staged diff → exit 2 ---
REPO7="${TMPROOT}/feature-staged"
setup_repo "${REPO7}" "feature/staged"
echo "dirty" >>"${REPO7}/initial.txt"
(cd "${REPO7}" && git add initial.txt)
run_case "feature staged diff blocks" "2" "$(run_hook "${REPO7}")"

# --- Case 8: feature branch with diff + CLAUDE_STOP_GUARD=0 → exit 0 ---
REPO8="${TMPROOT}/feature-bypass"
setup_repo "${REPO8}" "feature/bypass"
echo "dirty" >>"${REPO8}/initial.txt"
rc=0
(
  cd "${REPO8}"
  CLAUDE_STOP_GUARD=0 bash "${HOOK_SCRIPT}" <<<'{}' >/dev/null 2>&1
) || rc=$?
run_case "CLAUDE_STOP_GUARD=0 bypasses" "0" "${rc}"

# --- Case 9: detached HEAD with diff → exit 0 (can't classify safely) ---
REPO9="${TMPROOT}/feature-detached"
setup_repo "${REPO9}" "feature/detach"
(
  cd "${REPO9}"
  echo "second" >second.txt
  git add second.txt
  git commit -q -m "second"
  git checkout -q HEAD~1
  echo "dirty" >>initial.txt
)
run_case "detached HEAD skips guard" "0" "$(run_hook "${REPO9}")"

echo ""
echo "Total: $((PASS + FAIL))  Pass: ${PASS}  Fail: ${FAIL}"
if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi
