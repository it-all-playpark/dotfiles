#!/usr/bin/env bash
# tests/codex-permissions.test.sh
# codex/config.base.toml の permissions profile（claude-readonly）が、claude-code/settings.json の
# sandbox.filesystem.denyRead の各エントリを "none" にしているかを確かめる。
# codex-guard（claude-code/hooks/pretool-codex-guard.sh）は、この profile を
# -c default_permissions="claude-readonly" で選んだ codex exec / review だけを通す。Codex の
# read-only sandbox はディスク全体を読めるので、denyRead にだけエントリを足すと、Claude の sandbox が
# 隠したものを Codex 経由で読めてしまう。
# denyRead の `<path>/**` は profile の `<path>`（その下ごと "none"）に当たる。
# 通常の codex セッションの workspace-write を変えないよう、config.base.toml は default_permissions を
# 設定しない。
# Run from the repo root: bash tests/codex-permissions.test.sh
# Requires: jq, yq (yq-go)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"
CODEX_CONFIG="${REPO_ROOT}/codex/config.base.toml"
PROFILE="claude-readonly"

for cmd in jq yq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "${cmd} required" >&2
    exit 1
  fi
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-permissions-test.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

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

# missing_entries <settings.json> <config.json>: profile に "none" で無い denyRead のエントリを 1 行ずつ出す
missing_entries() {
  jq -r --arg profile "${PROFILE}" --slurpfile codex "$2" '
    ($codex[0].permissions[$profile].filesystem // {}) as $fs
    | .sandbox.filesystem.denyRead[]
    | select(($fs[sub("/\\*\\*$"; "")] // "") != "none")
  ' "$1"
}

echo "=== Codex permissions profile tests ==="

yq -p toml -o json '.' "${CODEX_CONFIG}" >"${TMPROOT}/codex.json"

# --- AC-1: profile は filesystem を読み取り専用にする ---
root_access="$(jq -r --arg profile "${PROFILE}" '.permissions[$profile].filesystem[":root"] // empty' "${TMPROOT}/codex.json")"
if [[ ${root_access} == "read" ]]; then
  pass "${PROFILE} reads :root"
else
  fail "${PROFILE} reads :root" "permissions.${PROFILE}.filesystem.\":root\" = '${root_access}' (want read)"
fi

writable="$(jq -r --arg profile "${PROFILE}" '
  .permissions[$profile].filesystem // {} | to_entries[] | select(.value != "read" and .value != "none") | "\(.key) = \(.value)"
' "${TMPROOT}/codex.json")"
if [[ -z ${writable} ]]; then
  pass "${PROFILE} has no writable entry"
else
  fail "${PROFILE} has no writable entry" "${writable//$'\n'/, }"
fi

# --- AC-1: denyRead の各エントリが profile で "none" ---
missing="$(missing_entries "${SETTINGS}" "${TMPROOT}/codex.json")"
if [[ -z ${missing} ]]; then
  pass "every denyRead entry is \"none\" in ${PROFILE}"
else
  fail "every denyRead entry is \"none\" in ${PROFILE}" "missing in codex/config.base.toml: ${missing//$'\n'/, }"
fi

# denyRead にだけエントリを足すと、上の検査が拾う
# shellcheck disable=SC2088 # denyRead のエントリと同じく ~ を展開しない文字列
extra='~/.kube/**'
jq --arg extra "${extra}" '.sandbox.filesystem.denyRead += [$extra]' "${SETTINGS}" >"${TMPROOT}/settings.json"
if [[ "$(missing_entries "${TMPROOT}/settings.json" "${TMPROOT}/codex.json")" == "${extra}" ]]; then
  pass "a denyRead-only entry is reported"
else
  fail "a denyRead-only entry is reported" "${extra} added to denyRead was not reported"
fi

# --- AC-4: 通常のセッションは workspace-write のまま（default_permissions を設定しない）---
if jq -e 'has("default_permissions") | not' "${TMPROOT}/codex.json" >/dev/null; then
  pass "config.base.toml does not set default_permissions"
else
  fail "config.base.toml does not set default_permissions" "default_permissions = $(jq -c '.default_permissions' "${TMPROOT}/codex.json")"
fi

sandbox_mode="$(jq -r '.sandbox_mode // empty' "${TMPROOT}/codex.json")"
if [[ ${sandbox_mode} == "workspace-write" ]]; then
  pass "config.base.toml keeps sandbox_mode = workspace-write"
else
  fail "config.base.toml keeps sandbox_mode = workspace-write" "sandbox_mode = '${sandbox_mode}'"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
