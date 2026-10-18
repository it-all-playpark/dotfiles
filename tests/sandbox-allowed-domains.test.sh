#!/usr/bin/env bash
# tests/sandbox-allowed-domains.test.sh
# Unit test for claude-code/settings.json's sandbox.network.allowedDomains array.
# Run from the repo root: bash tests/sandbox-allowed-domains.test.sh
# Requires: jq
#
# issue #351: corporate-site の seed-harvest（harvest_topics.sh）が叩く hn.algolia.com・
# suggestqueries.google.com・b.hatena.ne.jp を user scope に足す。user scope の
# sandbox.network.strictAllowlist: true により repo の .claude/settings.json の allowedDomains は
# 無視され、sandbox が `host is not on the allow list` で拒否していた。
# どれも読み取り用の公開 API / RSS なので完全一致のホスト名で足し、wildcard（*.）は増やさない。

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

echo "=== sandbox.network.allowedDomains unit tests ==="
echo ""

# ---------------------------------------------------------------------------
# seed_harvest_hosts_exact: hn.algolia.com / suggestqueries.google.com / b.hatena.ne.jp が完全一致のエントリで入っている
# ---------------------------------------------------------------------------
echo "- seed_harvest_hosts_exact"
missing=()
for host in hn.algolia.com suggestqueries.google.com b.hatena.ne.jp; do
  if ! jq -e --arg h "${host}" '.sandbox.network.allowedDomains | index($h) != null' "${SETTINGS}" >/dev/null; then
    missing+=("${host}")
  fi
done
if [ "${#missing[@]}" -eq 0 ]; then
  pass "seed_harvest_hosts_exact"
else
  fail "seed_harvest_hosts_exact" "missing=${missing[*]}"
fi

# ---------------------------------------------------------------------------
# wildcard_entries_fixed: wildcard（*.）のエントリはこの一覧だけ。サブドメインをまとめて開くので、
# 増やすときはここも直して、その理由を PR で確かめる
# ---------------------------------------------------------------------------
echo "- wildcard_entries_fixed"
want='["*.amazonaws.com","*.cachix.org","*.githubusercontent.com","*.googleapis.com","*.npmjs.org"]'
got="$(jq -c '[.sandbox.network.allowedDomains[] | select(startswith("*."))] | sort' "${SETTINGS}")"
if [ "${got}" = "${want}" ]; then
  pass "wildcard_entries_fixed"
else
  fail "wildcard_entries_fixed" "got=${got} want=${want}"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -gt 0 ]; then
  printf '  %s\n' "${ERRORS[@]}"
  exit 1
fi
