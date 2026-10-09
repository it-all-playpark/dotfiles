#!/usr/bin/env bash
# PostToolUseFailure(Bash) hook: worktree 隔離ガードに拒否されたとき、通る書き方を足す
#
# 背景:
#   worktree に隔離されたセッション（bg job・dev-flow の df-*）では、組み込みガードが
#   「git に届かないと証明できない」Bash を拒否する（設定では外せない）。拒否メッセージは理由を
#   書くが直し方は書かないことが多く、2026-10-01〜10-09 の拒否 521 回のうち 170 回は同じセッションで
#   60 秒以内に再拒否されていた（多くは implementer 等の subagent）。
#   PreToolUse で先に deny しても 1 回失敗する点は変わらず、ガードの判定を予測すると誤検知も出る。
#   ガードが実際に拒否した後に、その理由に対応する直し方だけを additionalContext で渡す。
#
# 直し方は 2026-10-09 に Claude Code 2.1.294 の隔離セッションで実際にガードへ当てて、
# 通ることを確かめた形だけを書く（例: git の出力を "$TMPDIR/…" へリダイレクトすると拒否、
# /tmp/claude/… へは通る。macOS の sed は -- を受け付けない）。
#
# 入力: PostToolUseFailure の payload {tool_name, tool_input, error, ...}
# 出力: 理由が既知のときだけ
#   {"hookSpecificOutput":{"hookEventName":"PostToolUseFailure","additionalContext":"<直し方>"}}
#   それ以外（ガード以外の失敗・未知の理由）は何も出さない。挙動は変えない。

set -euo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
ERROR=$(echo "$INPUT" | jq -r '.error // empty | if type == "string" then . else tojson end')

if [[ $TOOL != "Bash" || $ERROR != *"isolated in the worktree"* ]]; then
  exit 0
fi

HINTS=()

# shellcheck disable=SC2016 # 意図的なリテラル: agent に見せる文字列
if [[ $ERROR =~ "redirects git to the shared checkout"|"points git at a directory computed"|"redirects git through a glob" ]]; then
  HINTS+=('cwd はすでに自分の worktree。`git -C <path>` / `--git-dir` を外して `git …` をそのまま叩く（glob の pathspec も `git clean -n -- foo*` のように -C なしなら通る）')
fi

# shellcheck disable=SC2016
if [[ $ERROR =~ "names git in a form too complex"|"names git more than once"|"changes directory to a location computed"|"naming git"|"git command among its operands" ]]; then
  HINTS+=('git は他のコマンドと混ぜず 1 回の呼び出しで単独に叩く。`$(git …)` や backtick は使わず、値が要るなら先に git を単独で叩いて出力を読む。git の出力を保存するときは `"$TMPDIR/…"` ではなく固定パス（例 `/tmp/claude/x`）へリダイレクトする。`cd` は相対パスの固定値だけ（変数・glob で計算した場所へ cd しない）。git 以外のコマンドの引数（rg / grep のパターン等）に git という語があるだけでも拒否されるので、パターンは `rg -f /tmp/claude/pat` のようにファイルで渡す')
fi

# shellcheck disable=SC2016
if [[ $ERROR =~ "runs bash"|"hands bash"|"runs sh "|"hands sh" ]]; then
  HINTS+=('`bash script.sh > "$TMPDIR/x.log"` のように変数を含む構文と組み合わせた bash は拒否される。リダイレクト先を固定パス（例 `/tmp/claude/x.log`）にするか、実行権のあるスクリプトは `./script.sh` で直接実行する。ループや `bash -c` の中で回さず 1 回ずつ単独で叩く')
fi

# shellcheck disable=SC2016
if [[ $ERROR =~ "where an option may stand" ]]; then
  HINTS+=('変数の値の前に `--` を置く（例 `rg -n foo -- "$P"`）。ただし macOS の sed は `--` を受け付けないので、sed には `sed -n 1,20p < "$TMPDIR/x"` のように標準入力で渡す')
fi

# shellcheck disable=SC2016
if [[ $ERROR =~ "through eval"|"through source"|"program assembled at runtime"|"program computed at runtime" ]]; then
  HINTS+=('実行するプログラムは Write ツールでファイルに書き、`python3 /tmp/claude/x.py` のように固定パスを単独で実行する')
fi

if [[ ${#HINTS[@]} -eq 0 ]]; then
  exit 0
fi

CONTEXT="worktree 隔離ガードに拒否された。通る書き方:"
for h in "${HINTS[@]}"; do
  CONTEXT+=$'\n- '"$h"
done

jq -cn --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"PostToolUseFailure",additionalContext:$ctx}}'
