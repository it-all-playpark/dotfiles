#!/usr/bin/env bash
# home-manager の activation ブロックが素の `exit` でスクリプト全体を止めないことを検証する。
#
# home-manager は全 activation ブロックを 1 本のシェルスクリプトに連結する。
# ブロック内で `exit 0` を呼ぶと、そのブロックだけでなく後続の全ステップ
# (setupLaunchAgents や ucHandoffBinary など) が実行されずに終了する。しかも
# 終了コードが 0 なので `home-manager switch` は成功として報告し、
# plist もバイナリも作られていないことに気づけない。
#
# よって「`exit` を含む activation ブロックはサブシェル `( ... )` で囲む」を不変条件とする。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/hm-activation-exit-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

cat > "$TMPROOT/check.awk" <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

!inblock {
  if ($0 ~ /activation\.[A-Za-z0-9_]+ = lib\.hm\.dag\.entry[A-Za-z]+ \[[^]]*\] ''$/) {
    match($0, /^[ \t]*/)
    close_marker = substr($0, 1, RLENGTH) "'';"
    match($0, /activation\.[A-Za-z0-9_]+/)
    name = substr($0, RSTART, RLENGTH)
    inblock = 1
    n = 0
    has_exit = 0
    delete body
  }
  next
}

inblock {
  if ($0 == close_marker) {
    inblock = 0
    if (!has_exit) {
      printf "SKIP %s:%s (exit なし)\n", FILENAME, name
    } else if (n >= 2 && body[1] == "(" && body[n] == ")") {
      printf "OK %s:%s\n", FILENAME, name
    } else {
      printf "FAIL %s:%s exit を含むがサブシェルで囲まれていない\n", FILENAME, name
    }
    next
  }
  line = trim($0)
  if (line ~ /^exit([ \t]|$)/) { has_exit = 1 }
  if (line != "" && line !~ /^#/) { body[++n] = line }
  next
}
AWK

mapfile -t NIX_FILES < <(find "$REPO_ROOT/home-manager" -name '*.nix' | sort)

PASS=0
FAIL=0

while IFS= read -r result; do
  case "$result" in
    OK\ *)
      echo "  PASS: ${result#OK }"
      PASS=$((PASS + 1))
      ;;
    FAIL\ *)
      echo "  FAIL: ${result#FAIL }" >&2
      FAIL=$((FAIL + 1))
      ;;
  esac
done < <(awk -f "$TMPROOT/check.awk" "${NIX_FILES[@]}")

echo
echo "checked: $((PASS + FAIL)) activation block(s) containing exit / passed: $PASS / failed: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL: activation ブロックの exit がサブシェルで囲まれていない" >&2
  exit 1
fi

if [ "$PASS" -eq 0 ]; then
  echo "FAIL: exit を含む activation ブロックを 1 つも検出できなかった (検査が空振りしている)" >&2
  exit 1
fi

echo "PASS: hm-activation-exit"
