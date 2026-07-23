#!/usr/bin/env bats
# tests/verify-branch-protection.bats
# Unit tests for scripts/verify-branch-protection.sh (AC-11: 横断安全策)
# Tests the extract_repos() and check_repo_protection() functions.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/verify-branch-protection.sh"

setup() {
  export WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-branch-protection-test.XXXXXX")"

  # Source script functions (BASH_SOURCE[0] != $0 skips main())
  # shellcheck disable=SC1090
  source "${SCRIPT}"

  # Setup fake gh stub controlled by environment variables
  STUB_BIN_DIR="${WORK_DIR}/bin"
  mkdir -p "${STUB_BIN_DIR}"
  cat >"${STUB_BIN_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" != "api" ]; then
  echo "fake gh: unhandled subcommand: $1" >&2
  exit 1
fi
path="$2"
case "${path}" in
  */branches/*/protection)
    if [ "${GH_STUB_PROTECTION_FAIL:-0}" = "1" ]; then
      echo "fake gh: 404 Branch not protected" >&2
      exit 1
    fi
    body="${GH_STUB_PROTECTION_JSON:-}"
    [ -z "${body}" ] && body='{}'
    echo "${body}"
    ;;
  repos/*)
    if [ "${GH_STUB_REPO_FAIL:-0}" = "1" ]; then
      echo "fake gh: 404 Not Found" >&2
      exit 1
    fi
    printf '{"default_branch": "%s"}' "${GH_STUB_DEFAULT_BRANCH:-main}"
    ;;
  *)
    echo "fake gh: unhandled api path: ${path}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${STUB_BIN_DIR}/gh"
}

teardown() {
  rm -rf "${WORK_DIR}"
}

@test "extract_repos dedupes and sorts across channels" {
  command -v yq >/dev/null 2>&1 || skip "yq not on PATH"
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"

  BINDINGS_FILE="${WORK_DIR}/repo_bindings.yaml"
  cat >"${BINDINGS_FILE}" <<'BINDINGS_EOF'
platforms:
  slack:
    channels:
      C_ONE:
        repos:
          - it-all-playpark/dotfiles
      C_TWO:
        repos:
          - it-all-playpark/dotfiles
          - it-all-playpark/skills
  discord:
    channels:
      D_ONE:
        repos:
          - it-all-playpark/zzz-last-repo
BINDINGS_EOF

  GOT_REPOS="$(extract_repos "${BINDINGS_FILE}")"
  EXPECTED_REPOS="$(printf 'it-all-playpark/dotfiles\nit-all-playpark/skills\nit-all-playpark/zzz-last-repo')"
  [ "${GOT_REPOS}" = "${EXPECTED_REPOS}" ]
}

@test "check_repo_protection passes when required review enabled" {
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"

  OUT="$(
    PATH="${STUB_BIN_DIR}:${PATH}" \
      GH_STUB_DEFAULT_BRANCH="main" \
      GH_STUB_PROTECTION_JSON='{"required_pull_request_reviews":{"required_approving_review_count":1}}' \
      check_repo_protection "it-all-playpark/dotfiles"
  )"

  [[ "${OUT}" =~ ^PASS\ it-all-playpark/dotfiles ]]
}

@test "check_repo_protection fails when branch unprotected" {
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"

  OUT="$(
    PATH="${STUB_BIN_DIR}:${PATH}" \
      GH_STUB_DEFAULT_BRANCH="main" \
      GH_STUB_PROTECTION_FAIL=1 \
      check_repo_protection "it-all-playpark/unprotected-repo" 2>&1 || true
  )"

  [[ "${OUT}" =~ ^FAIL\ it-all-playpark/unprotected-repo ]]
}

@test "check_repo_protection fails when protected without required review" {
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"

  OUT="$(
    PATH="${STUB_BIN_DIR}:${PATH}" \
      GH_STUB_DEFAULT_BRANCH="main" \
      GH_STUB_PROTECTION_JSON='{"required_status_checks":{"strict":true}}' \
      check_repo_protection "it-all-playpark/no-review-repo" 2>&1 || true
  )"

  [[ "${OUT}" =~ ^FAIL\ it-all-playpark/no-review-repo ]]
}

@test "check_repo_protection fails when required_approving_review_count is 0" {
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"

  OUT="$(
    PATH="${STUB_BIN_DIR}:${PATH}" \
      GH_STUB_DEFAULT_BRANCH="main" \
      GH_STUB_PROTECTION_JSON='{"required_pull_request_reviews":{"required_approving_review_count":0}}' \
      check_repo_protection "it-all-playpark/zero-review-repo" 2>&1 || true
  )"

  [[ "${OUT}" =~ ^FAIL\ it-all-playpark/zero-review-repo ]]
}

@test "check_repo_protection fails when repo unreachable" {
  command -v jq >/dev/null 2>&1 || skip "jq not on PATH"

  OUT="$(
    PATH="${STUB_BIN_DIR}:${PATH}" \
      GH_STUB_REPO_FAIL=1 \
      check_repo_protection "it-all-playpark/missing-repo" 2>&1 || true
  )"

  [[ "${OUT}" =~ ^FAIL\ it-all-playpark/missing-repo ]]
}
