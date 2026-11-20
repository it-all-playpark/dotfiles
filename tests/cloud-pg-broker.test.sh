#!/usr/bin/env bash
# tests/cloud-pg-broker.test.sh
# cloud/bin/pg-broker を偽の docker で検証する（コンテナも Postgres も起動しない）。
# 偽の docker は argv を 1 行ずつ記録し、FAKE_PORTS（docker ps の Ports 列）と FAKE_IDS（LABEL 付きの id）を返す。
#
# 検証項目:
#   1. create_output          - create は 1 行の JSON で id（コンテナ id の先頭 12 桁）・database_url・expires_at を返す
#   2. create_run_argv        - docker run に LABEL、127.0.0.1 の 5500〜5599 の publish、postgres:17 を渡し、
#                               database_url の port・password は run に渡したものと同じ
#   3. create_version         - --version 16 で postgres:16 を起動する
#   4. create_skips_used_port - ほかのコンテナが publish している port は選ばない
#   5. create_rejects_version - 数字でない --version は起動せずに 1 で終わる
#   6. delete_removes         - delete <id> は LABEL 付きの該当コンテナを rm -f -v し、{"id","deleted":true} を返す
#   7. delete_unknown_id      - LABEL 付きに無い id は rm せずに 1 で終わる

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cloud-pg-broker-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

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

PG_BROKER="$REPO_ROOT/cloud/bin/pg-broker"
FAKEBIN="$TMPROOT/bin"
LOG="$TMPROOT/docker.log"
mkdir -p "$FAKEBIN"

FULL_ID="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SHORT_ID="${FULL_ID:0:12}"

cat >"$FAKEBIN/docker" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_DOCKER_LOG"
case "$1" in
ps)
  case "$*" in
  *--no-trunc*) [ -z "$FAKE_IDS" ] || echo "$FAKE_IDS" ;;
  *) echo "$FAKE_PORTS" ;;
  esac
  ;;
run) echo "$FAKE_RUN_ID" ;;
esac
EOF
chmod +x "$FAKEBIN/docker"

# broker <args...>: stdout を $TMPROOT/out に、rc を RC に残す。docker の記録は呼び出しごとに空にする
broker() {
  : >"$LOG"
  set +e
  PATH="$FAKEBIN:$PATH" FAKE_DOCKER_LOG="$LOG" FAKE_RUN_ID="$FULL_ID" \
    FAKE_PORTS="${FAKE_PORTS:-}" FAKE_IDS="${FAKE_IDS:-}" \
    bash "$PG_BROKER" "$@" >"$TMPROOT/out" 2>"$TMPROOT/err"
  RC=$?
  set -e
}

run_line() {
  grep '^run ' "$LOG" || true
}

# --- 1. create_output ---
broker create
url="$(jq -r '.database_url' "$TMPROOT/out" 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$TMPROOT/out" | tr -d ' ')" = 1 ] &&
  [ "$(jq -r '.id' "$TMPROOT/out")" = "$SHORT_ID" ] &&
  [[ $url =~ ^postgresql://app:([0-9a-f]+)@127\.0\.0\.1:(55[0-9][0-9])/app$ ]] &&
  jq -e '.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$TMPROOT/out" >/dev/null; then
  pass "create_output"
  password="${BASH_REMATCH[1]}"
  port="${BASH_REMATCH[2]}"
else
  fail "create_output" "rc=$RC out=$(cat "$TMPROOT/out") err=$(cat "$TMPROOT/err")"
  password=""
  port=""
fi

# --- 2. create_run_argv ---
line="$(run_line)"
if [ -n "$port" ] &&
  [[ $line == "run -d --rm --label pg-broker -p 127.0.0.1:$port:5432 "* ]] &&
  [[ $line == *" -e POSTGRES_PASSWORD=$password "* ]] &&
  [[ $line == *" postgres:17 "* ]]; then
  pass "create_run_argv"
else
  fail "create_run_argv" "docker run の argv: $line"
fi

# --- 3. create_version ---
broker create --version 16
line="$(run_line)"
if [ "$RC" -eq 0 ] && [[ $line == *" postgres:16 "* ]]; then
  pass "create_version"
else
  fail "create_version" "rc=$RC argv: $line"
fi

# --- 4. create_skips_used_port ---
FAKE_PORTS="0.0.0.0:5500->5432/tcp, 127.0.0.1:5501->5432/tcp" broker create
got_port="$(jq -r '.database_url | capture(":(?<p>[0-9]+)/app$").p' "$TMPROOT/out" 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ -n "$got_port" ] && [ "$got_port" -ge 5502 ] && [ "$got_port" -le 5599 ]; then
  pass "create_skips_used_port"
else
  fail "create_skips_used_port" "rc=$RC port=$got_port"
fi

# --- 5. create_rejects_version ---
broker create --version latest
if [ "$RC" -eq 1 ] && [ -z "$(run_line)" ] && [ ! -s "$TMPROOT/out" ]; then
  pass "create_rejects_version"
else
  fail "create_rejects_version" "rc=$RC argv: $(run_line)"
fi

# --- 6. delete_removes ---
FAKE_IDS="$FULL_ID" broker delete "$SHORT_ID"
if [ "$RC" -eq 0 ] && grep -qx "rm -f -v $FULL_ID" "$LOG" &&
  jq -e --arg id "$SHORT_ID" '.id == $id and .deleted == true' "$TMPROOT/out" >/dev/null &&
  [ "$(wc -l <"$TMPROOT/out" | tr -d ' ')" = 1 ]; then
  pass "delete_removes"
else
  fail "delete_removes" "rc=$RC out=$(cat "$TMPROOT/out") calls=$(cat "$LOG")"
fi

# --- 7. delete_unknown_id ---
FAKE_IDS="$FULL_ID" broker delete "ffffffffffff"
if [ "$RC" -eq 1 ] && ! grep -q '^rm ' "$LOG"; then
  pass "delete_unknown_id"
else
  fail "delete_unknown_id" "rc=$RC calls=$(cat "$LOG")"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
echo "PASS: cloud-pg-broker"
