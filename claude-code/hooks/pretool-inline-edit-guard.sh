#!/usr/bin/env bash
# PreToolUse(Edit|Write) hook: inline 生成区間への直接編集の防止
#
# 目的:
#   skills repo の tools/sync-inlines.mjs が _lib/ の canonical ソースから
#   .claude/workflows/*.js に inline 生成するコード区間を、Edit/Write で
#   直接書き換えられないようにする。生成物を手で編集すると、次回
#   sync-inlines.mjs --write 実行時に変更が黙って上書き・消失するため、
#   canonical 側（_lib/）を編集して再生成する運用を deterministic に強制する。
#
# 検知対象:
#   1. tool_input.file_path が正規表現 (^|/)\.claude/workflows/[^/]+\.js$ に
#      マッチするファイルへの Edit/Write
#   2. マッチした場合、以下のいずれかが生成マーカーを含むか grep で走査:
#      - Edit: 編集対象ファイルが既に存在し、その内容にマーカーを含む
#      - Write: 新規内容（tool_input.content）にマーカーを含む
#        （生成物の手書き再作成 — 存在しないファイルへの Write も対象）
#   3. マーカー正規表現は skills repo の tools/sync-inlines.mjs の
#      BEGIN_RE = /^\/\/ ==== BEGIN inline: (\S+) .*====$/ と同形
#      （grep -E '^// ==== BEGIN inline: '）。行頭アンカー必須 —
#      文字列リテラル・ドキュメント内での言及への誤爆を防ぐ。
#
# 出力:
#   - 検知時: stdout に
#       {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#         "permissionDecision":"deny",
#         "permissionDecisionReason":"<理由>"}}
#   - 非検知時: stdout 空で exit 0（チェーン通過 → Claude 通常の permission flow）
#
# 正規の再生成経路（deny されないことをテストで担保）:
#   `node tools/sync-inlines.mjs --write` は Bash tool 経由の実行であり、
#   本 hook は Edit/Write のみを対象とするため妨げられない。
#
# 誤検知（false-positive）テストケース:
#   - マーカーを含まない .claude/workflows/*.js への Edit
#   - canonical 側（_lib/ 配下）への Edit
#   - .claude/workflows/ 配下でも拡張子が .js でないファイル（README.md 等）
#   - 行頭 `// ==== BEGIN inline: ` 形式ではなく、文字列リテラル内に
#     "BEGIN inline:" という語だけが現れるケース（行頭アンカーで除外）
#   詳細は pretool-inline-edit-guard.test.sh を参照。

set -euo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [[ $TOOL != "Edit" && $TOOL != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
if [[ -z $FILE_PATH ]]; then
  exit 0
fi

if ! echo "$FILE_PATH" | grep -qE '(^|/)\.claude/workflows/[^/]+\.js$'; then
  exit 0
fi

MARKER_RE='^// ==== BEGIN inline: '

deny() {
  local file_path="$1"
  jq -n --arg reason "${file_path} は tools/sync-inlines.mjs の生成区間を含む生成物。_lib/ の canonical 側（マーカー内に記載のパス）を編集し、node tools/sync-inlines.mjs --write で再生成せよ" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

if [[ -f $FILE_PATH ]] && grep -qE "$MARKER_RE" "$FILE_PATH"; then
  deny "$FILE_PATH"
fi

if [[ $TOOL == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  if [[ -n $CONTENT ]] && echo "$CONTENT" | grep -qE "$MARKER_RE"; then
    deny "$FILE_PATH"
  fi
fi

# 検知なし: pass-through
exit 0
