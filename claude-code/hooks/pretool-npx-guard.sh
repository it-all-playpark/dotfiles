#!/bin/bash
# PreToolUse(Bash) hook: npx / pnpx による任意リモートパッケージ実行の deny
#
# 背景:
#   以前は permissions.deny の `Bash(npx:*)` / `Bash(pnpx:*)` で npx を全面禁止し、
#   permissions.allow に `Bash(npx vitest run*)` を置いて例外を作ろうとしていた。
#   しかし deny は allow に常勝するため、この例外は一度も機能していなかった
#   （実測: `npx vitest run` は allow に完全一致しても拒否された）。
#
#   公式ドキュメントも「引数を制約する Bash permission パターンは fragile であり、
#   PreToolUse hook を使え」としているため、deny 規則を撤去し本 hook へ移行した。
#
# 方針:
#   許可リストに載る npx 呼び出しのみ素通しし、それ以外を deny する。
#   **allow は返さない**。allow を返すと他の deny 規則まで短絡してしまい、
#   `npx foo && rm -rf /` のような compound command を通してしまうため。
#   素通し時は stdout 空で exit 0 とし、Claude 通常の permission flow に委ねる。
#
# 許可する対象:
#   - vitest 実行:            `npx vitest ...` / `npx -y vitest ...`
#   - vdelta 経由の vitest:   `npx -y vdelta@<ver> run -- npx vitest ...`
#   いずれもプロジェクトのテスト実行系であり、日常的に必要。
#
# deny する例:
#   - `npx some-unknown-package`      （任意リモートパッケージ実行）
#   - `npx -y create-something`
#   - `pnpx whatever`
#
# fail-closed 仕様:
#   npx 呼び出しを検出したうえで許可リストに一致しなければ deny。
#   compound command（`a && npx foo`）内の npx も検出する。
#
# 出力:
#   - 検知時:   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                 "permissionDecision":"deny","permissionDecisionReason":"<理由>"}}
#   - 非検知時: stdout 空で exit 0（チェーン通過）

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [[ -z $CMD ]]; then
  exit 0
fi

# compound command 区切りも含めた npx / pnpx 呼び出しの検出
NPX_RE='(^|[;&|(][[:space:]]*|[[:space:]])p?npx([[:space:]]|$)'

if ! echo "$CMD" | grep -qE "$NPX_RE"; then
  exit 0
fi

# 許可リスト: npx 直後（-y / --yes は挟んでよい）が vitest、
# または vdelta 経由で vitest を呼ぶ形。
ALLOW_VITEST_RE='(^|[;&|(][[:space:]]*|[[:space:]])p?npx([[:space:]]+(-y|--yes))*[[:space:]]+vitest([[:space:]]|$)'
ALLOW_VDELTA_RE='(^|[;&|(][[:space:]]*|[[:space:]])p?npx([[:space:]]+(-y|--yes))*[[:space:]]+vdelta(@[^[:space:]]+)?[[:space:]]+run[[:space:]]+--[[:space:]]+p?npx([[:space:]]+(-y|--yes))*[[:space:]]+vitest([[:space:]]|$)'

# 許可形に一致しない npx 呼び出しが 1 つでもあれば deny（fail-closed）。
# vdelta 形は内側に `npx vitest` を含むため ALLOW_VITEST_RE でも拾えるが、
# 意図を明示するため両方を列挙している。
if echo "$CMD" | grep -qE "$ALLOW_VDELTA_RE"; then
  exit 0
fi

# npx 呼び出しの出現回数と、vitest 形の出現回数が一致すれば全て許可対象。
# grep は非マッチで exit 1 を返す。pipefail 下でも中断しないよう `|| true` で受ける。
NPX_COUNT=$(echo "$CMD" | { grep -oE "$NPX_RE" || true; } | wc -l | tr -d ' ')
VITEST_COUNT=$(echo "$CMD" | { grep -oE "$ALLOW_VITEST_RE" || true; } | wc -l | tr -d ' ')

if [[ $NPX_COUNT -eq $VITEST_COUNT ]]; then
  exit 0
fi

echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"npx / pnpx による任意リモートパッケージ実行は禁止（許可されるのは vitest 実行のみ）"}}'
exit 0
