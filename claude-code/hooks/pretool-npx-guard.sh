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
#   なお deny 規則を「多層防御」として併置することはできない。deny は allow に
#   常勝するため、`Bash(npx:*)` を残すと本 hook が素通しを決めても vitest が
#   実行できない。permission 層は all-or-nothing であり、許可リスト方式は
#   hook 側でしか表現できない。
#
# 方針:
#   許可リストに載る npx 呼び出しのみ素通しし、それ以外を deny する。
#   **allow は返さない**。allow を返すと他の deny 規則まで短絡してしまい、
#   `npx foo && <危険コマンド>` のような compound command を通してしまうため。
#   素通し時は stdout 空で exit 0 とし、Claude 通常の permission flow に委ねる。
#
# 許可する対象:
#   - vitest 実行:          `npx vitest ...` / `npx -y vitest ...`
#   - vdelta の run:        `npx -y vdelta@<ver> run -- ...`
#   いずれもプロジェクトのテスト実行系であり、日常的に必要。
#
# 検出の考え方（fail-closed）:
#   コマンド文字列中に「npx / pnpx を指しうる語」が 1 つでも現れたら、その全てが
#   許可形でない限り deny する。語の検出は境界を緩く取り、以下を全て拾う:
#     - 素の `npx foo`
#     - 絶対 / 相対パス起動 `/usr/local/bin/npx foo`, `./node_modules/.bin/npx foo`
#     - コマンド置換の内側 `$(echo npx)`, backtick 内
#     - 変数代入 `X=npx` （後段で `$X` として実行されうる）
#     - compound command `a && npx foo`, パイプ, サブシェル
#   ファイル名に "npx" を含むだけのケースは誤検知しうるが、安全側に倒す。
#
#   これは lexical な検出であり、シェルの完全なパースではない。動的に組み立てた
#   文字列を eval するような経路までは追えないため、完全な封じ込めではなく
#   「事故と手癖による実行を止める」ことを目的とする。
#
# 対象外:
#   `npm exec` / `yarn dlx` / `bunx` は本 hook の対象外（移行前の deny 規則も
#   npx / pnpx のみを対象としていたため、範囲を変えない）。
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

# npx / pnpx を指しうる語。直前は「英数字・アンダースコア・ハイフンでない」
# （= 行頭 / 空白 / `/` / `=` / `$(` / backtick / `;&|(` 等）を許し、直後は
# 空白・行末・またはパス構成文字でない記号（`)` `;` `&` `|` `"` `'` 等）とする。
# これにより裸の npx・パス起動・コマンド置換内・変数代入の全てを拾う。
NPX_RE='(^|[^[:alnum:]_-])p?npx([[:space:]]|$|[^[:alnum:]_./-])'

# grep は非マッチで exit 1 を返す。pipefail 下でも中断しないよう `|| true` で受ける。
NPX_COUNT=$(echo "$CMD" | { grep -oE "$NPX_RE" || true; } | wc -l | tr -d ' ')

if [[ $NPX_COUNT -eq 0 ]]; then
  exit 0
fi

# 許可形。npx の手前にパス（`/usr/local/bin/` 等）が付いていてもよい。
# 直前境界は NPX_RE と対称に取る。
PATH_PREFIX='((/|\./|\.\./|~/)[^[:space:]]*/)?'
YES_FLAGS='([[:space:]]+(-y|--yes))*'

ALLOW_VITEST_RE="(^|[^[:alnum:]_-])${PATH_PREFIX}p?npx${YES_FLAGS}[[:space:]]+vitest([[:space:]]|$)"
ALLOW_VDELTA_RE="(^|[^[:alnum:]_-])${PATH_PREFIX}p?npx${YES_FLAGS}[[:space:]]+vdelta(@[^[:space:]]+)?[[:space:]]+run([[:space:]]|$)"

VITEST_COUNT=$(echo "$CMD" | { grep -oE "$ALLOW_VITEST_RE" || true; } | wc -l | tr -d ' ')
VDELTA_COUNT=$(echo "$CMD" | { grep -oE "$ALLOW_VDELTA_RE" || true; } | wc -l | tr -d ' ')

ALLOWED_COUNT=$((VITEST_COUNT + VDELTA_COUNT))

# 検出した npx 語の全てが許可形として説明できる場合のみ素通し。
# 1 つでも説明できない出現があれば deny（fail-closed）。
if [[ $NPX_COUNT -eq $ALLOWED_COUNT ]]; then
  exit 0
fi

echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"npx / pnpx による任意リモートパッケージ実行は禁止（許可されるのは vitest 実行と vdelta run のみ）"}}'
exit 0
