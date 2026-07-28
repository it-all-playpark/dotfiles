#!/bin/bash
# PreToolUse(Bash) hook: gh pr review --approve（self-approve）の検知・deny
#
# 目的:
#   merge/approve は常に人間が行う invariant を、プロンプト指示のみに依存せず
#   決定論的な hook で担保する（issue #137）。
#
# 検知対象:
#   コマンド文字列内に `gh ... pr review ...` 呼び出しが存在し、かつ
#   standalone token として `--approve` または `-a` が含まれる場合。
#   - 引数順序に依らない（`gh pr review --approve 137` / `gh pr review 137 --approve` 等）
#   - `gh -R owner/repo pr review ...` のようなグローバルフラグ挟み込みも検出
#   - `git fetch && gh pr review 137 --approve` のような compound command 内も検出
#     （settings.json 側で matcher を "Bash(gh pr review*)" のような前方一致に
#     せず、全 Bash コマンドで本 hook を起動する前提）
#
# fail-closed 仕様:
#   `--body "please --approve later"` のように引用文字列内に --approve token が
#   含まれる場合も deny する（安全側）。シェル引用の完全パースは非現実的なため、
#   偽陽性を許容し fail-closed に倒す。
#
# 素通しする例:
#   - `gh pr review 137 --comment --body "looks good"`
#   - `gh pr review 137 --request-changes --body "fix"`
#   - `gh pr view 137` / `gh pr merge 137`（pr review 呼び出しでない）
#   - `git commit -a -m msg` / `ls -a`（pr review 呼び出しでない -a）
#
# 出力:
#   - 検知時: stdout に
#       {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#         "permissionDecision":"deny",
#         "permissionDecisionReason":"<理由>"}}
#   - 非検知時: stdout 空で exit 0（チェーン通過 → Claude 通常の permission flow）

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [[ -z $CMD ]]; then
  exit 0
fi

# gh ... pr review ... の呼び出し検出（compound command 内・グローバルフラグ挟み込み含む）
PR_REVIEW_RE='(^|[;&|[:space:]])gh([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+pr[[:space:]]+review([[:space:]]|$)'

# standalone token としての --approve / -a 検出（--approver / -abc に誤爆しない）
# --approve=true / -a=true のような cobra 形式（`=` 区切り値）も検出する
# （--approve=false も fail-closed で deny する: 安全側）
# 境界は PR_REVIEW_RE と対称に compound command 区切り（;&|）も含める。
# 末尾は `--approve; echo` / `--approve&&x` / `--approve|cat` のような
# 区切り文字直後の token も検出できるよう [;&|<>[:space:]] まで広げる
# （fail-closed: 誤検知より見逃しを避ける）
APPROVE_TOKEN_RE='(^|[;&|[:space:]])(--approve(=[^[:space:]]*)?|-a(=[^[:space:]]*)?)([;&|<>[:space:]]|$)'

if echo "$CMD" | grep -qE "$PR_REVIEW_RE" && echo "$CMD" | grep -qE "$APPROVE_TOKEN_RE"; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"PR self-approve は禁止（merge/approve は常に人間が行う invariant）"}}'
  exit 0
fi

exit 0
