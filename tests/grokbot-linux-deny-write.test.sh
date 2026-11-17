#!/usr/bin/env bash
# tests/grokbot-linux-deny-write.test.sh
# Linux の sandbox（bubblewrap）の中で、いま効いている settings（~/.claude/settings.json）の
# sandbox.filesystem.denyWrite のうち glob を含まない絶対パスのエントリへ、Bash から実際に書けないことを確かめる。
# Linux の sandbox は denyWrite の glob（`*` / `**`）を展開せず、文字どおりのパスだけを塞ぐ（#501）。
# home-manager/grokbot-linux/settings.jq が `**` のエントリを具体パスに写しているのはそのため。
#
# 走らせる場所: Grok Bot の box の Claude Code セッション（sandbox 内の Bash。pre-push の tests/run-all.sh からも走る）。
# それ以外（Linux でない・sandbox の外・settings が無い）では理由付きで SKIP して exit 0 で終わる。
#
# 検証項目（エントリごと）:
#   denied <path> - 既存のディレクトリには中にファイルを作れない / 既存のファイルは書き込み用に開けない /
#                   無いパスは作れない（sandbox は無いパスを /dev/null で塞ぐので、文字デバイスに見えれば塞がれている）

set -uo pipefail

SETTINGS="${HOME}/.claude/settings.json"

skip_all() {
  echo "SKIP: grokbot-linux-deny-write ($1)"
  echo "Results: 0 passed, 0 failed, 1 skipped"
  exit 0
}

[ "$(uname -s)" = "Linux" ] || skip_all "not Linux"
[ -n "${SANDBOX_RUNTIME:-}" ] || skip_all "sandbox の外"
[ -r "$SETTINGS" ] || skip_all "$SETTINGS が無い"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/grokbot-linux-deny-write-test.XXXXXX")"
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

# glob を含まない絶対パスのエントリ（box 用に足したもの。~ 始まりは Mac 版から引き継いだ ~/ghq 起点で、box には無い）
jq -r '.sandbox.filesystem.denyWrite // [] | .[] | select(startswith("/") and (contains("*") | not))' \
  "$SETTINGS" >"$TMPROOT/targets"

[ -s "$TMPROOT/targets" ] || skip_all "denyWrite に glob を含まない絶対パスのエントリが無い"

while IFS= read -r target; do
  name="denied $target"
  if [ -c "$target" ]; then
    # 無いパスは sandbox が /dev/null を被せて塞ぐ（作れない・置き換えられない）
    pass "$name"
  elif [ -d "$target" ]; then
    if probe="$(mktemp "$target/.deny-write-probe.XXXXXX" 2>/dev/null)"; then
      rm -f "$probe"
      fail "$name" "ディレクトリの中にファイルを作れた"
    else
      pass "$name"
    fi
  elif [ -e "$target" ]; then
    # 追記用に開くだけ（中身は変えない）。塞がれていれば開けない
    if (: >>"$target") 2>/dev/null; then
      fail "$name" "ファイルを書き込み用に開けた"
    else
      pass "$name"
    fi
  elif mkdir "$target" 2>/dev/null; then
    rmdir "$target"
    fail "$name" "無いパスを作れた"
  else
    pass "$name"
  fi
done <"$TMPROOT/targets"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
echo "PASS: grokbot-linux-deny-write"
