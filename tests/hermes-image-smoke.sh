#!/usr/bin/env bash
# tests/hermes-image-smoke.sh
# Smoke / integration tests for hermes-tools:latest docker image and config files.
#
# Usage:
#   bash tests/hermes-image-smoke.sh            # Run all tests
#   bash tests/hermes-image-smoke.sh --skip-build  # Skip nix build check
#   bash tests/hermes-image-smoke.sh --skip-docker # Skip docker run tests
#
# Requires: nix (with flakes), docker (optional with --skip-docker), jq, grep
#
# NOTE: This test file is intentionally NOT added to `nix flake check` because
# it requires a running Docker daemon and (on macOS) a linux-builder.
# Run locally after `nix run .#hermes-image-load`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_BUILD=false
SKIP_DOCKER=false
PASS=0
FAIL=0
ERRORS=()

# Parse flags
for arg in "$@"; do
  case "${arg}" in
  --skip-build) SKIP_BUILD=true ;;
  --skip-docker) SKIP_DOCKER=true ;;
  *)
    echo "Unknown flag: ${arg}" >&2
    exit 1
    ;;
  esac
done

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

skip() {
  echo "  SKIP: $1 (${2})"
}

echo "=== hermes-image smoke tests ==="
echo "  REPO_ROOT: ${REPO_ROOT}"
echo "  SKIP_BUILD: ${SKIP_BUILD}, SKIP_DOCKER: ${SKIP_DOCKER}"
echo ""

# ---------------------------------------------------------------------------
# AC1 supplement: nix build hermes-image succeeds (integration)
# ---------------------------------------------------------------------------
echo "- nix_build_hermes_image_succeeds"
if [ "${SKIP_BUILD}" = "true" ]; then
  skip "nix_build_hermes_image_succeeds" "--skip-build"
else
  if nix build "${REPO_ROOT}#packages.aarch64-linux.hermes-image" \
    --no-link 2>&1 | grep -v "^$" | tail -5; then
    pass "nix_build_hermes_image_succeeds"
  else
    fail "nix_build_hermes_image_succeeds" \
      "nix build .#packages.aarch64-linux.hermes-image failed"
  fi
fi

# ---------------------------------------------------------------------------
# AC2: claude CLI runs inside container
# ---------------------------------------------------------------------------
echo "- docker_run_claude_version_succeeds"
if [ "${SKIP_DOCKER}" = "true" ]; then
  skip "docker_run_claude_version_succeeds" "--skip-docker"
else
  # NOTE: `set -e` 下では `var="$(cmd)"` の assignment 後の `$?` は assignment 自体の
  # 終了コード (常に 0) を返してしまい、かつ cmd 失敗時は assignment 段階で
  # script 全体が exit してしまう。これを避けるため `|| true` で exit を抑止しつつ、
  # 出力末尾に exit code を埋め込んで一度の docker 実行で値と exit を取得する。
  claude_run_result="$(
    docker run --rm hermes-tools:latest claude --version 2>&1
    printf '\n__EXIT__=%d' "$?" || true
  )"
  claude_exit="${claude_run_result##*__EXIT__=}"
  claude_out="${claude_run_result%$'\n'__EXIT__=*}"
  if [ "${claude_exit}" -eq 0 ] && echo "${claude_out}" | grep -qE '[0-9]+\.[0-9]+'; then
    pass "docker_run_claude_version_succeeds"
  else
    fail "docker_run_claude_version_succeeds" \
      "claude --version exited ${claude_exit} or no version string found. Output: ${claude_out}"
  fi
fi

# ---------------------------------------------------------------------------
# AC2 supplement: node version is v24.x
# ---------------------------------------------------------------------------
echo "- docker_run_node_version_is_v24"
if [ "${SKIP_DOCKER}" = "true" ]; then
  skip "docker_run_node_version_is_v24" "--skip-docker"
else
  node_out="$(docker run --rm hermes-tools:latest node --version 2>&1)"
  if echo "${node_out}" | grep -qE '^v24\.'; then
    pass "docker_run_node_version_is_v24"
  else
    fail "docker_run_node_version_is_v24" \
      "Expected v24.x from node --version, got: ${node_out}"
  fi
fi

# ---------------------------------------------------------------------------
# AC3: config.yaml forwards CLAUDE_CODE_OAUTH_TOKEN
# ---------------------------------------------------------------------------
echo "- config_yaml_forwards_oauth_token"
if grep -qF "CLAUDE_CODE_OAUTH_TOKEN" "${REPO_ROOT}/hermes/config.yaml"; then
  pass "config_yaml_forwards_oauth_token"
else
  fail "config_yaml_forwards_oauth_token" \
    "CLAUDE_CODE_OAUTH_TOKEN not found in hermes/config.yaml docker_forward_env"
fi

# ---------------------------------------------------------------------------
# AC3 supplement: .env.template has placeholder
# ---------------------------------------------------------------------------
echo "- env_template_has_claude_oauth_placeholder"
if grep -qE '^CLAUDE_CODE_OAUTH_TOKEN=' "${REPO_ROOT}/hermes/.env.template"; then
  pass "env_template_has_claude_oauth_placeholder"
else
  fail "env_template_has_claude_oauth_placeholder" \
    "CLAUDE_CODE_OAUTH_TOKEN= not found in hermes/.env.template"
fi

# ---------------------------------------------------------------------------
# AC4: README documents claude setup-token procedure
# ---------------------------------------------------------------------------
echo "- readme_documents_claude_setup_token"
if grep -qF "claude setup-token" "${REPO_ROOT}/hermes/README.md"; then
  pass "readme_documents_claude_setup_token"
else
  fail "readme_documents_claude_setup_token" \
    "'claude setup-token' not found in hermes/README.md"
fi

# ---------------------------------------------------------------------------
# AC5: treefmt check and shellcheck pass
# ---------------------------------------------------------------------------
echo "- formatters_and_shellcheck_pass"
fmt_ok=true
sc_ok=true

if command -v treefmt >/dev/null 2>&1; then
  if ! treefmt --fail-on-change --no-cache --tree-root "${REPO_ROOT}" 2>&1 | tail -3; then
    fmt_ok=false
  fi
else
  echo "    (treefmt not in PATH, skipping formatter check — run 'nix develop' first)"
fi

if command -v shellcheck >/dev/null 2>&1; then
  shell_targets=()
  # shellcheck disable=SC2207
  if compgen -G "${REPO_ROOT}/tests/*.sh" >/dev/null 2>&1; then
    shell_targets+=("${REPO_ROOT}/tests/"*.sh)
  fi
  if compgen -G "${REPO_ROOT}/hermes/scripts/*.sh" >/dev/null 2>&1; then
    shell_targets+=("${REPO_ROOT}/hermes/scripts/"*.sh)
  fi
  if [ "${#shell_targets[@]}" -gt 0 ]; then
    if ! shellcheck "${shell_targets[@]}" 2>&1; then
      sc_ok=false
    fi
  fi
else
  echo "    (shellcheck not in PATH, skipping — run 'nix develop' first)"
fi

if [ "${fmt_ok}" = "true" ] && [ "${sc_ok}" = "true" ]; then
  pass "formatters_and_shellcheck_pass"
else
  fail "formatters_and_shellcheck_pass" \
    "fmt_ok=${fmt_ok}, sc_ok=${sc_ok}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
