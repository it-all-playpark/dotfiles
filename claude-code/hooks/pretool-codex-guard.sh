#!/bin/bash
# PreToolUse(Bash) hook: 素の codex 呼び出しが Codex 自身の sandbox を外せないようにする
#
# 背景:
#   settings.json の sandbox.excludedCommands の `codex:*` は、先頭トークンが codex のコマンドを
#   Claude の sandbox の外で動かす（generate-thumbnail と dev-flow の Codex review が使うので外さない）。
#   素の `codex exec "..."` は user 設定（sandbox_mode = "workspace-write"・network_access = true）で
#   動くので、sandbox の外で書き込みも通信もできる。`--dangerously-bypass-approvals-and-sandbox` や
#   `-s danger-full-access` を付ければ Codex の sandbox ごと外れる。どの session からも
#   そうした Codex を起動できないよう、許可形以外の codex 呼び出しを deny する（issue #409）。
#
# 判定（許可形への完全一致。シェルの構文は解釈しない）:
#   1. `codex` の語を含まないコマンドは見ない
#   （比較は LC_ALL=C のバイト単位。4096 バイトを超えるものと、途中で失敗したもの（ERR trap）は deny）
#   2. シェルのメタ文字（; & | ` $ ( ) { } < > 改行）と、印字可能な ASCII・空白以外のバイトを含まず、先頭の語が素の名前
#      （英数字と _ . / ~ + - # だけ）で、codex（パス付きを含む）でも、後ろのコマンドを起動する
#      wrapper（timeout・nice・env・command 等）でもなければ、codex は引数にしか現れないので素通しする
#   3. それ以外は、次の許可形に完全一致するものだけ通し、残りはすべて deny する
#      （複合コマンド・置換・算術式・heredoc・VAR=x 前置・wrapper 越しの codex は、中身を問わず deny）
#        - `codex --version` / `codex --help` / `codex features list` / `codex login status`
#        - 語は素の文字（英数字と _ . / = : , + @ % ~ -）・'…'・"…"（中に \ を含まない）の連結だけ
#      `codex exec` / `codex review` は `-s read-only` を明示しても通さない。Codex の read-only sandbox は
#      ディスク全体の読み取りを許すので、prompt（PR の文面などで注入された指示を含む）に従って denyRead の
#      対象（~/.ssh・資格情報など）を読み、stdout と model API へ返せる。読み取りを作業ツリーに限る
#      Codex の設定が実際に効くことを確かめられていないので、許可形に入れない。sandbox の外で Codex を
#      使う道具（generate-thumbnail 等）は script の中から codex を呼ぶので、この hook の対象にならない
#   zsh の global alias（alias -g）で語を書き換える呼び出しは追えない。
#
# 出力:
#   - deny 時:  {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                 "permissionDecision":"deny","permissionDecisionReason":"<理由>"}}
#     理由は固定文で、入力の command の文字列を埋め込まない
#   - 素通し時: stdout 空で exit 0（allow は返さない。Claude 通常の permission flow に委ねる）

set -eEuo pipefail
# regex と glob をバイト単位で比べる（UTF-8 ロケールでは不正なマルチバイト列で regexec が一致なしを返しうる）
export LC_ALL=C

deny() {
  trap - ERR
  jq -cn --arg reason "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

SHAPE_REASON='codex の語を含むコマンドは、; & | ` $ ( ) { } < > 改行と非 ASCII を含まない 4096 バイト以下の単純コマンドにする（codex が引数に現れるだけのものか、codex の許可形）。codex を wrapper（timeout・env 等）や VAR=x 前置の後ろに置かない。codex のプロンプトは ASCII の引数で渡す（< file は使えない）。git commit の非 ASCII の文面は -F file で渡す'
# 途中で失敗したら deny に倒す（hook の非 0 終了は Claude にとって非ブロックで、素通しになる）
trap 'deny "$SHAPE_REASON"' ERR

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

# codex の語を含まないコマンドは見ない
if [[ $CMD != *codex* ]]; then
  exit 0
fi

# 字句分割の前に長さで切る（巨大な入力で hook の timeout に達すると素通しになる）
if ((${#CMD} > 4096)); then
  deny "$SHAPE_REASON"
fi
FORM_REASON='codex は sandbox の外で動く（excludedCommands の codex:*）。通すのは codex --version / --help / features list / login status だけ。codex exec / review は -s read-only でもディスク全体を読めるので通さない'

META_RE=$'[;&|`$(){}<>\n]'
PLAIN_HEAD_RE='^[A-Za-z0-9_./~+#-]+$'
# 後ろの語をコマンドとして起動する wrapper / precommand modifier（zsh の `-`・noglob 等を含む）
RUNNER_RE='^(-|timeout|gtimeout|nice|nohup|stdbuf|time|env|command|exec|builtin|noglob|nocorrect|xargs|sudo|doas|caffeinate|ionice|chrt|taskset|setsid|arch|unbuffer|chronic)$'

# 2. メタ文字を含まず、先頭の語が素の名前で codex でも wrapper でもない → codex は引数にしか現れない
#    印字可能な ASCII と空白以外のバイトを含むものは素通しせず段階 3 に回す
if [[ $CMD != *[![:print:][:blank:]]* && ! $CMD =~ $META_RE ]]; then
  head=${CMD#"${CMD%%[![:blank:]]*}"}
  head=${head%%[[:blank:]]*}
  if [[ $head =~ $PLAIN_HEAD_RE && $head != codex && $head != */codex && ! ${head##*/} =~ $RUNNER_RE ]]; then
    exit 0
  fi
fi

# 3. codex の許可形への完全一致
BARE='[A-Za-z0-9_./=:,+@%~-]+'
SQ="'[^']*'"
DQ='"[^"\]*"'
WORD_RE="^(${BARE}|${SQ}|${DQ})+"
BARE_CAP="^(${BARE})"
SQ_CAP="^'([^']*)'"
DQ_CAP='^"([^"\]*)"'

body=$CMD
if [[ $body =~ $META_RE ]]; then
  deny "$SHAPE_REASON"
fi

# unquote <語>: '…' / "…" / 素の文字の連結を外して UQ に入れる
unquote() {
  local w=$1
  UQ=""
  while [[ -n $w ]]; do
    if [[ $w =~ $SQ_CAP || $w =~ $DQ_CAP || $w =~ $BARE_CAP ]]; then
      UQ+=${BASH_REMATCH[1]}
      w=${w:${#BASH_REMATCH[0]}}
    else
      return 1
    fi
  done
}

# 語に分ける。許可した文字・クォート以外が混じれば deny
RAW=()
TOKS=()
s=$body
while :; do
  s=${s#"${s%%[![:blank:]]*}"}
  if [[ -z $s ]]; then
    break
  fi
  if [[ ! $s =~ $WORD_RE ]]; then
    deny "$SHAPE_REASON"
  fi
  w=${BASH_REMATCH[0]}
  s=${s:${#w}}
  if [[ -n $s && $s != [[:blank:]]* ]]; then
    deny "$SHAPE_REASON"
  fi
  unquote "$w" || deny "$SHAPE_REASON"
  RAW+=("$w")
  TOKS+=("$UQ")
done

# 先頭はクォートしない codex（パス付きを含む）。VAR=x 前置・wrapper・クォートした名前は deny
if ((${#RAW[@]} == 0)) || [[ ${RAW[0]} != codex && ${RAW[0]} != */codex ]] || [[ ${RAW[0]} == *[\'\"]* ]]; then
  deny "$SHAPE_REASON"
fi

# 情報表示の 4 形だけを通す（exec / review は read-only でもディスク全体を読めるので通さない）
ARGS="${TOKS[*]:1}"
if ((${#TOKS[@]} == 2)) && [[ ${TOKS[1]} == --version || ${TOKS[1]} == --help ]]; then
  exit 0
fi
if ((${#TOKS[@]} == 3)) && [[ $ARGS == "features list" || $ARGS == "login status" ]]; then
  exit 0
fi
deny "$FORM_REASON"
