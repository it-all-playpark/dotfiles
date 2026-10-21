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
#
# issue #352: gh run view --log / --log-failed はログ本体を GitHub の Actions ログ用ストレージ
# productionresultssa<N>.blob.core.windows.net から取る（N は run ごとに変わり、観測は 1〜19）。
# *.blob.core.windows.net は誰でもストレージを作れる外部の書き込み先になるので、0〜19 を完全一致で列挙する。
#
# issue #385: Prisma CLI は実行のたびに checkpoint.prisma.io:443 へ使用状況を送り、sandbox が
# `host is not on the allow list` で拒否していた。allowedDomains には足さず、env の
# CHECKPOINT_DISABLE=1 で送信そのものを止める。

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
# gh_actions_log_hosts_exact: productionresultssa0〜19.blob.core.windows.net の 20 ホストが完全一致のエントリで入っている
# ---------------------------------------------------------------------------
echo "- gh_actions_log_hosts_exact"
missing=()
for n in $(seq 0 19); do
  host="productionresultssa${n}.blob.core.windows.net"
  if ! jq -e --arg h "${host}" '.sandbox.network.allowedDomains | index($h) != null' "${SETTINGS}" >/dev/null; then
    missing+=("${host}")
  fi
done
if [ "${#missing[@]}" -eq 0 ]; then
  pass "gh_actions_log_hosts_exact"
else
  fail "gh_actions_log_hosts_exact" "missing=${missing[*]}"
fi

# ---------------------------------------------------------------------------
# prisma_checkpoint_disabled_by_env: env.CHECKPOINT_DISABLE が "1" で、checkpoint.prisma.io は
# allowedDomains に入れていない（送信を止めて拒否をなくし、外向きの許可は広げない）
# ---------------------------------------------------------------------------
echo "- prisma_checkpoint_disabled_by_env"
checkpoint_disable="$(jq -r '.env.CHECKPOINT_DISABLE // ""' "${SETTINGS}")"
if [ "${checkpoint_disable}" != "1" ]; then
  fail "prisma_checkpoint_disabled_by_env" "env.CHECKPOINT_DISABLE=${checkpoint_disable} want=1"
elif jq -e '.sandbox.network.allowedDomains | index("checkpoint.prisma.io") != null' "${SETTINGS}" >/dev/null; then
  fail "prisma_checkpoint_disabled_by_env" "checkpoint.prisma.io is in allowedDomains"
else
  pass "prisma_checkpoint_disabled_by_env"
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
