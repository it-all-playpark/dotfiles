#!/usr/bin/env bash
# tests/run-all-tmpdir.test.sh
# tests/run-all.sh が、呼び出し元の TMPDIR の末尾の / を除いてから各テストを起動することを確かめる。
# Run from the repo root: bash tests/run-all-tmpdir.test.sh
#
# macOS 既定の TMPDIR（/var/folders/.../T/）は末尾に / があり、そのまま渡すと各テストの
# mktemp -d "${TMPDIR:-/tmp}/..." が // 入りのパスを作る。
#
# 一時ディレクトリに repo の配置（tests/run-all.sh の複製と、受け取った TMPDIR の末尾が / なら
# fail するテスト 1 本）を組み、TMPDIR を変えて run-all.sh を実行して終了コードを確かめる。

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/run-all-tmpdir-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# run-all.sh が find で走査する 3 ディレクトリを持つ repo の配置
FAKE_REPO="${WORK}/repo"
mkdir -p "${FAKE_REPO}/tests" "${FAKE_REPO}/claude-code" "${FAKE_REPO}/scripts"
cp "${REPO_ROOT}/tests/run-all.sh" "${FAKE_REPO}/tests/run-all.sh"

# 受け取った TMPDIR の末尾が / なら fail するテスト
cat >"${FAKE_REPO}/tests/tmpdir-probe.test.sh" <<'PROBE'
#!/usr/bin/env bash
case "${TMPDIR:-}" in
*/)
  echo "FAIL: TMPDIR が / で終わっている: ${TMPDIR}"
  exit 1
  ;;
esac
echo "PASS: TMPDIR=${TMPDIR:-}"
PROBE

# run-all.sh に渡す TMPDIR の実体（末尾の / の有無だけを変えて渡す）
FAKE_TMP="${WORK}/tmp"
mkdir -p "${FAKE_TMP}"

# $1: ケース名 / $2: run-all.sh に渡す TMPDIR
check_run_all() {
  local name="$1" tmpdir="$2" out rc=0
  out="$(TMPDIR="${tmpdir}" bash "${FAKE_REPO}/tests/run-all.sh" 2>&1)" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    pass "${name}"
  else
    fail "${name}" "TMPDIR=${tmpdir} で run-all.sh が exit ${rc}: ${out}"
  fi
}

echo "run-all.sh の TMPDIR の扱い"
check_run_all "TMPDIR の末尾に / がある" "${FAKE_TMP}/"
check_run_all "TMPDIR の末尾に / が複数ある" "${FAKE_TMP}//"
check_run_all "TMPDIR の末尾に / がない" "${FAKE_TMP}"

echo
echo "passed: ${PASS} / failed: ${FAIL}"

if [ "${FAIL}" -ne 0 ]; then
  for e in "${ERRORS[@]}"; do
    echo "FAIL: ${e}" >&2
  done
  exit 1
fi

echo "PASS: run-all-tmpdir"
