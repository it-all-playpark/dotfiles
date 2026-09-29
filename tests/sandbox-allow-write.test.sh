#!/usr/bin/env bash
# tests/sandbox-allow-write.test.sh
# Unit test for claude-code/settings.json's sandbox.filesystem.allowWrite array.
# Run from the repo root: bash tests/sandbox-allow-write.test.sh
# Requires: jq
#
# issue #214: pnpm の store operation lock（/tmp/pnpm-store-operation-locks-<uid>/）
# の配下に書けることを、Claude Code の sandbox と同じ一致規則で検証する。
# - glob（* ? [ を含む）エントリ: パス全体に一致する正規表現になる（`*`→`[^/]*`、
#   `**/`→`(.*/)?`、`**`→`.*`）。そのパス自体にしか効かず、配下には効かない
# - リテラルのエントリ: subpath 扱いで、そのパスと配下すべてに効く
# `/private/tmp/pnpm-store-operation-locks-*` だけではディレクトリ作成しか通らず、
# 既存の all-stores.lock を開き直す 2 回目以降の pnpm が EPERM で落ちていた。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"

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

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

echo "=== sandbox.filesystem.allowWrite unit tests ==="
echo ""

# ---------------------------------------------------------------------------
# settings_is_valid_json
# ---------------------------------------------------------------------------
echo "- settings_is_valid_json"
if jq empty "${SETTINGS}" >/dev/null 2>&1; then
  pass "settings_is_valid_json"
else
  fail "settings_is_valid_json" "${SETTINGS} is not valid JSON"
fi

ALLOW_WRITE_JSON="$(jq -c '.sandbox.filesystem.allowWrite' "${SETTINGS}")"

# write_allowed <path>: allowWrite のいずれかのエントリが <path> への書き込みを許すか
write_allowed() {
  jq -e --arg p "$1" --arg home "${HOME}" '
    def glob_to_regex:
      "^" + (
        gsub("(?<c>[.^$+{}()|\\\\])"; "\\\(.c)")
        | gsub("\\*\\*/"; "\u0001")
        | gsub("\\*\\*"; "\u0002")
        | gsub("\\*"; "[^/]*")
        | gsub("\\?"; "[^/]")
        | gsub("\u0001"; "(.*/)?")
        | gsub("\u0002"; ".*")
      ) + "$";
    def expand_home: if startswith("~/") then $home + .[1:] else . end;
    map(expand_home)
    | any(
        . as $e
        | if $e | test("[*?\\[]") then
            $p | test($e | glob_to_regex)
          else
            ($p == $e) or ($p | startswith($e + "/"))
          end
      )
  ' <<<"${ALLOW_WRITE_JSON}" >/dev/null
}

LOCK_DIR="/private/tmp/pnpm-store-operation-locks-502"

# ---------------------------------------------------------------------------
# pnpm_lock_dir_writable
# ---------------------------------------------------------------------------
echo "- pnpm_lock_dir_writable"
if write_allowed "${LOCK_DIR}"; then
  pass "pnpm_lock_dir_writable"
else
  fail "pnpm_lock_dir_writable" "${LOCK_DIR} is not covered by allowWrite"
fi

# ---------------------------------------------------------------------------
# pnpm_all_stores_lock_writable
# ---------------------------------------------------------------------------
echo "- pnpm_all_stores_lock_writable"
if write_allowed "${LOCK_DIR}/all-stores.lock"; then
  pass "pnpm_all_stores_lock_writable"
else
  fail "pnpm_all_stores_lock_writable" "${LOCK_DIR}/all-stores.lock is not covered by allowWrite"
fi

# ---------------------------------------------------------------------------
# pnpm_per_store_lock_writable
# ---------------------------------------------------------------------------
echo "- pnpm_per_store_lock_writable"
per_store_lock="${LOCK_DIR}/0fddfda5c3f3059f44d27e74068169714961516a980eb80cf6533e87e93601e7.lock"
if write_allowed "${per_store_lock}"; then
  pass "pnpm_per_store_lock_writable"
else
  fail "pnpm_per_store_lock_writable" "${per_store_lock} is not covered by allowWrite"
fi

# ---------------------------------------------------------------------------
# pnpm_store_dir_writable
# ---------------------------------------------------------------------------
echo "- pnpm_store_dir_writable"
store_file="${HOME}/Library/pnpm/store/v10/index/00/abc-index.json"
if write_allowed "${store_file}"; then
  pass "pnpm_store_dir_writable"
else
  fail "pnpm_store_dir_writable" "${store_file} is not covered by allowWrite"
fi

# ---------------------------------------------------------------------------
# tmp_root_not_writable
# ---------------------------------------------------------------------------
echo "- tmp_root_not_writable"
# /tmp 全体は開けない（hook の claude-skill-ctx-* や bridge のソケットと共有する領域）
not_expected=(
  "/private/tmp/claude-skill-ctx-probe"
  "/private/tmp/pnpm-store-operation-locks"
  "/private/tmp/other-dir/pnpm-store-operation-locks-502/all-stores.lock"
)
leaked=()
for p in "${not_expected[@]}"; do
  write_allowed "${p}" && leaked+=("${p}")
done
if [ "${#leaked[@]}" -eq 0 ]; then
  pass "tmp_root_not_writable"
else
  fail "tmp_root_not_writable" "Unexpectedly writable: ${leaked[*]}"
fi

# ---------------------------------------------------------------------------
# no_duplicate_entries
# ---------------------------------------------------------------------------
echo "- no_duplicate_entries"
total_len="$(jq 'length' <<<"${ALLOW_WRITE_JSON}")"
unique_len="$(jq 'unique | length' <<<"${ALLOW_WRITE_JSON}")"
if [ "${total_len}" -eq "${unique_len}" ]; then
  pass "no_duplicate_entries"
else
  fail "no_duplicate_entries" "length=${total_len} unique=${unique_len}"
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
