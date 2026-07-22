#!/usr/bin/env bash
# scripts/verify-branch-protection.sh
# 横断安全策 (AC-11): "bind 対象 repo すべてに required review 付き
# branch protection が設定されていることを確認できる".
#
# Reads every repo listed under `platforms.*.channels.*.repos` in
# hermes/repo_bindings.yaml and, for each one, uses `gh api` to confirm the
# repo's default branch has protection enabled with
# `required_pull_request_reviews` (required_approving_review_count >= 1).
# Repos that are unprotected, missing required reviews, or otherwise
# unreachable via `gh api` are collected and reported as failures.
#
# This script deliberately calls `gh` itself rather than expecting the
# caller to `cd`/export env vars first: REPO_ROOT and the bindings file
# default are resolved from the script's own location (BASH_SOURCE), so it
# can be invoked bare as `scripts/verify-branch-protection.sh` from any cwd
# (needed so the sandbox's leading-token gh excludedCommands match still
# applies when this script is the invoked command).
#
# Usage:
#   scripts/verify-branch-protection.sh
#
# Env:
#   HERMES_REPO_BINDINGS_PATH - override the repo_bindings.yaml path
#                                (same convention as hermes/plugins/claude_runner/bindings.py)
#
# Requires: yq, gh (authenticated), jq
#
# Exit codes: 0 = all bound repos have required-review branch protection
#             1 = at least one bound repo is missing it
#             2 = usage/environment error (missing tool, missing bindings file, etc.)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINDINGS_FILE="${HERMES_REPO_BINDINGS_PATH:-${REPO_ROOT}/hermes/repo_bindings.yaml}"

# ---------------------------------------------------------------------------
# extract_repos <bindings_file>
# Prints the unique, sorted set of "owner/name" repo slugs referenced across
# every platforms.*.channels.*.repos entry in the bindings file.
# ---------------------------------------------------------------------------
extract_repos() {
  local bindings_file="$1"
  yq -r '.platforms[].channels[].repos[]' "${bindings_file}" | sort -u
}

# ---------------------------------------------------------------------------
# check_repo_protection <owner/repo>
# Prints a "PASS <repo>: ..." / "FAIL <repo>: ..." line and returns 0/1.
# ---------------------------------------------------------------------------
check_repo_protection() {
  local repo="$1"
  local repo_json default_branch protection_json

  if ! repo_json="$(gh api "repos/${repo}" 2>/dev/null)"; then
    echo "FAIL ${repo}: unable to fetch repo metadata via 'gh api repos/${repo}'" >&2
    return 1
  fi

  default_branch="$(echo "${repo_json}" | jq -r '.default_branch // empty')"
  if [ -z "${default_branch}" ]; then
    echo "FAIL ${repo}: repo metadata missing default_branch" >&2
    return 1
  fi

  if ! protection_json="$(gh api "repos/${repo}/branches/${default_branch}/protection" 2>/dev/null)"; then
    echo "FAIL ${repo}: branch '${default_branch}' has no branch protection configured" >&2
    return 1
  fi

  if ! echo "${protection_json}" |
    jq -e '.required_pull_request_reviews != null and ((.required_pull_request_reviews.required_approving_review_count // 0) >= 1)' \
      >/dev/null 2>&1; then
    echo "FAIL ${repo}: branch '${default_branch}' is protected but required_pull_request_reviews is not enabled (>= 1 required approving review)" >&2
    return 1
  fi

  echo "PASS ${repo}: branch '${default_branch}' has required_pull_request_reviews enabled"
  return 0
}

main() {
  local tool
  for tool in yq gh jq; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "ERROR: '${tool}' is required but not on PATH" >&2
      exit 2
    fi
  done

  if [ ! -f "${BINDINGS_FILE}" ]; then
    echo "ERROR: repo_bindings.yaml not found at ${BINDINGS_FILE}" >&2
    exit 2
  fi

  local repos
  repos="$(extract_repos "${BINDINGS_FILE}")"
  if [ -z "${repos}" ]; then
    echo "ERROR: no repos found in ${BINDINGS_FILE}" >&2
    exit 2
  fi

  echo "=== verify-branch-protection (AC-11) ==="
  echo "  BINDINGS_FILE: ${BINDINGS_FILE}"
  echo ""

  local total=0 fail_count=0
  local -a failed_repos=()
  local repo
  while IFS= read -r repo; do
    [ -z "${repo}" ] && continue
    total=$((total + 1))
    if check_repo_protection "${repo}"; then
      :
    else
      fail_count=$((fail_count + 1))
      failed_repos+=("${repo}")
    fi
  done <<<"${repos}"

  echo ""
  echo "Results: $((total - fail_count))/${total} bound repos have required-review branch protection"
  if [ "${fail_count}" -gt 0 ]; then
    echo "Repos missing required-review branch protection:"
    for repo in "${failed_repos[@]}"; do
      echo "  - ${repo}"
    done
    return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
