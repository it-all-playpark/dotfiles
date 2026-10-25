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
#        - `codex exec`（`e`）/ `codex review` の後ろに `-c default_permissions="claude-readonly"`・
#          `-c sandbox_mode=read-only`・`-c 'projects={}'` の 3 つを明示したもの（issue #411）。Codex の read-only sandbox は
#          ディスク全体の読み取りを許すので、prompt（PR の文面などで注入された指示を含む）に従って denyRead の
#          対象（~/.ssh・資格情報など）を読み、stdout と model API へ返せる。claude-readonly は
#          codex/config.base.toml の permissions profile で、filesystem を読み取り専用にしたうえで
#          settings.json の denyRead と permissions.deny の Read(…) の各エントリを "none" にする
#          （tests/codex-permissions.test.sh）。
#          `projects={}` は user 設定の trust（[projects."<path>"] trust_level）を空にし、どの dir も trusted で
#          なくする。codex は trusted な project の .codex（config.toml・rules・hooks.json 等）しか読まないので、
#          hook の判定後・codex の起動前に cwd へ .codex を出されても（dir の rename 等）project 層は効かない。
#          profile は sandbox_mode=read-only より優先されるが、`-s` / `--sandbox` は profile を外すので
#          値を問わず受けない（codex 0.164 で実測）。それ以外の option はサブコマンドの後ろの次の許可リストにある
#          ものだけ（値が - で始まるものは受けない。review の --base= 等が git の option として渡る）:
#            -c / --config（キーが model・model_reasoning_effort・model_reasoning_summary・model_verbosity と、
#            上の default_permissions・sandbox_mode・projects のもの）、exec の -m / --model・--skip-git-repo-check・
#            --json・--ephemeral・--color、review の --uncommitted・--base・--commit・--title
#          位置引数はプロンプト。exec の最初の位置引数が resume・fork・review・help なら
#          サブコマンドなので deny。`< file` などのリダイレクトは受けない（sandbox の外の shell が開くので、
#          作業ツリーに置いた symlink 越しに denyRead の対象を prompt に流せる）
#        - 語は素の文字（英数字と _ . / = : , + @ % ~ -）・'…'・"…"（中に \ を含まない）の連結だけ。
#          { } はクォートの中でだけ受ける（クォートの外は素の文字に無いので deny。クォートの中では展開されない）
#      加えて、cwd（論理パスと物理パスの両方）から $HOME の手前までに codex の project 層
#      （`.codex` dir。config.toml・rules・hooks.json 等）があれば、許可形でも deny する（mcp_servers・notify・
#      hooks が sandbox の外で動き、rules が承認を変える）。判定後に作られる .codex は上の projects={} で防ぐ
#      sandbox の外で Codex を使う道具（generate-thumbnail 等）は script の中から codex を呼ぶので、
#      この hook の対象にならない
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
FORM_REASON='codex は sandbox の外で動く（excludedCommands の codex:*）。通すのは codex --version / --help / features list / login status と、exec / review の後ろに -c default_permissions="claude-readonly" と -c sandbox_mode=read-only と -c '"'"'projects={}'"'"' を明示した codex exec / review で、ほかの option が model 系の -c と、exec は -m・--skip-git-repo-check・--json・--ephemeral・--color、review は --uncommitted・--base・--commit・--title だけのもの（-s / --sandbox は profile を外すので通さない）'
PROJECT_REASON='cwd の上に codex の project 層（.codex dir。config.toml・rules・hooks.json 等）がある（mcp_servers・notify・hooks が sandbox の外で動き、rules が承認を変える）。.codex の無い dir から codex を呼ぶ'

META_RE=$'[;&|`$(){}<>\n]'
# 許可形の判定で見るメタ文字。{ } は素の文字（BARE）に無いのでクォートの外では語の分割で deny になり、
# クォートの中では展開されない（projects={} を '…' / "…" で渡せるよう、ここでは見ない）
FORM_META_RE=$'[;&|`$()<>\n]'
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
CONFIG_ALLOW_RE='^(model|model_reasoning_effort|model_reasoning_summary|model_verbosity)$'

body=$CMD
if [[ $body =~ $FORM_META_RE ]]; then
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

# has_project_config: cwd（論理パスと物理パスの両方）から $HOME の手前までに codex の project 層
# （.codex dir）があるか（config.toml の mcp_servers・notify や hooks.json は Codex の sandbox の外で
#  起動し、rules は承認を変える。$HOME/.codex は user 設定なので見ない）
has_project_config() {
  local d
  for d in "$LOGICAL_CWD" "$HOOK_CWD"; do
    while [[ -n $d && $d != / && $d != "$HOME" ]]; do
      if [[ -e $d/.codex ]]; then
        return 0
      fi
      d=${d%/*}
    done
  done
  return 1
}

# judge <codex の引数…>: 許可形なら 0。exec / review の許可形なら SUB にサブコマンドを入れる
judge() {
  local n=$# i=0 np=0 t v key val dp=0 ro=0 pj=0 sub=""
  local -a a=("$@")

  if ((n == 1)) && [[ ${a[0]} == --version || ${a[0]} == --help ]]; then
    return 0
  fi
  if ((n == 2)) && [[ "${a[0]} ${a[1]}" == "features list" || "${a[0]} ${a[1]}" == "login status" ]]; then
    return 0
  fi

  while ((i < n)); do
    t=${a[i]}
    v=""
    case $t in
    -m | --model | -c | --config | --color | --base | --commit | --title)
      if ((i + 1 >= n)); then
        return 1
      fi
      v=${a[i + 1]}
      i=$((i + 2))
      ;;
    --model=* | --config=* | --color=* | --base=* | --commit=* | --title=*)
      v=${t#*=}
      t=${t%%=*}
      i=$((i + 1))
      ;;
    -*)
      # 値を取らない option（サブコマンドごとの許可は下で見る。-s / --sandbox は値を問わずここから deny）
      i=$((i + 1))
      ;;
    *)
      # 位置引数: 最初の 1 つがサブコマンド、以降はプロンプト
      if [[ -z $sub ]]; then
        case $t in
        exec | e | review) sub=$t ;;
        *) return 1 ;;
        esac
      elif [[ $sub != review && ($t == resume || $t == fork || $t == review || $t == help) ]]; then
        # codex exec resume / fork / review / help はサブコマンド。clap は位置引数の後ろの
        # サブコマンドも受け得るので、位置を問わず拒否する
        return 1
      else
        np=$((np + 1))
      fi
      i=$((i + 1))
      continue
      ;;
    esac

    # option はサブコマンドの後ろだけ。値の位置にフラグを置いて紛れ込ませる形（-m --yolo・
    # --base=--output=… 等。review は --base / --commit の値を git に渡す）も許可しない
    if [[ -z $sub || $v == -* ]]; then
      return 1
    fi

    case $t in
    -c | --config)
      if [[ $v != *=* ]]; then
        return 1
      fi
      key=${v%%=*}
      key=${key//[[:blank:]]/}
      # 値は TOML の文字列でも素の語でもよい
      val=${v#*=}
      val=${val//[[:blank:]]/}
      case $key in
      default_permissions)
        if [[ $val != claude-readonly && $val != '"claude-readonly"' && $val != "'claude-readonly'" ]]; then
          return 1
        fi
        dp=1
        ;;
      sandbox_mode)
        if [[ $val != read-only && $val != '"read-only"' && $val != "'read-only'" ]]; then
          return 1
        fi
        ro=1
        ;;
      projects)
        # trust を空にして project 層（.codex）を読ませない。中身のある table（trust_level の付与）は受けない
        if [[ $val != '{}' ]]; then
          return 1
        fi
        pj=1
        ;;
      *)
        if [[ ! $key =~ $CONFIG_ALLOW_RE ]]; then
          return 1
        fi
        ;;
      esac
      ;;
    -m | --model | --color | --skip-git-repo-check | --json | --ephemeral)
      if [[ $sub != exec && $sub != e ]]; then
        return 1
      fi
      ;;
    --uncommitted | --base | --commit | --title)
      if [[ $sub != review ]]; then
        return 1
      fi
      ;;
    *) return 1 ;;
    esac
  done

  SUB=$sub
  [[ -n $sub ]] && ((dp && ro && pj))
}

SUB=""
if ! judge "${TOKS[@]:1}"; then
  deny "$FORM_REASON"
fi
# project config は exec / review だけが読む（--version 等の情報表示は見ない）
if [[ -n $SUB ]]; then
  LOGICAL_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
  LOGICAL_CWD=${LOGICAL_CWD:-$PWD}
  # codex は物理パス（getcwd）から project root を探すので、symlink を解いた cwd でも見る
  HOOK_CWD=$(cd -- "$LOGICAL_CWD" 2>/dev/null && pwd -P) || deny "$PROJECT_REASON"
  if has_project_config; then
    deny "$PROJECT_REASON"
  fi
fi
exit 0
