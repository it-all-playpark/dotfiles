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
# 判定:
#   コマンドを awk で語に分け（シングル / ダブルクォート・バックスラッシュ・`$(…)` / backtick・
#   `;` `&` `|` `(` `)` 改行・リダイレクト・クォートした / しない heredoc の本文・コメント）、
#   各単純コマンドの先頭の語（`VAR=x` 前置と `{` `!` `if` `then` `do` 等の予約語は飛ばす）が
#   codex（パス付きを含む）のものを取り出す。`cd x && codex …` のような複合形も 1 つずつ見る。
#   通すのは次だけで、それ以外の codex 呼び出し（sandbox・apply・mcp・対話 TUI・read-only を
#   明示しない exec 等）は deny する:
#     - `codex --version` / `codex --help` / `codex features list` / `codex login status`
#     - `-s read-only` か `--sandbox read-only` を明示した `codex exec` / `codex review`
#   ただし次を 1 つでも含めば、上の形でも deny する:
#     - `--dangerously-*`（`--dangerously-bypass-approvals-and-sandbox` / `--dangerously-bypass-hook-trust`）
#     - `-s` / `--sandbox` の `workspace-write` / `danger-full-access`
#     - `--add-dir`
#     - `--approve-for-me`（workspace-write の sandbox で承認を自動で通す）
#     - `-c` / `--config` で sandbox_mode・sandbox_workspace_write・approval_policy・
#       sandbox_permissions・shell_environment_policy・mcp_servers で始まるキー
#       （`profiles.<name>.` の下に置いたものを含む）を上書きするもの
#     - `$` 展開・コマンド置換・`<(…)`・クォートしない glob / brace を含む引数
#       （hook からは展開後の値が見えず、`"$(cat f)"` でもフラグとして読まれうるため）。
#       プロンプトは `-` を付けて stdin（`< file` かクォートした heredoc）から渡す
#   lexical な判定でシェルの完全なパースではない（alias・関数・eval で組み立てた呼び出しは追えない）。
#
# 出力:
#   - deny 時:  {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                 "permissionDecision":"deny","permissionDecisionReason":"<理由>"}}
#     理由は固定文で、入力の command の文字列を埋め込まない
#   - 素通し時: stdout 空で exit 0（allow は返さない。Claude 通常の permission flow に委ねる）

set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

# codex の語を含まないコマンドは見ない
if [[ $CMD != *codex* ]]; then
  exit 0
fi

# codex 呼び出し 1 つにつき `C`（引数が静的）か `D`（展開を含む）の行、引数ごとに `A<引数>` の行、
# 終わりに `E` の行を出す
# shellcheck disable=SC2016 # 意図的なリテラル: awk のプログラム
TOKENIZER='
function init(d) { cstart[d] = 1; iscodex[d] = 0; cn[d] = 0; cdyn[d] = 0; wrap[d] = 0; wrapval[d] = 0 }
function kw(w) { return w ~ /^(\{|!|if|then|else|elif|do|while|until)$/ }
function wrapper(w) { return w ~ /^(.*\/)?(timeout|nice|nohup|stdbuf|time)$/ }
function endword(   w, dy) {
  if (!inword) return
  w = word; dy = wdyn
  word = ""; inword = 0; wdyn = 0
  gsub(/\n/, " ", w)
  if (skipnext) { skipnext = 0; return }
  if (hdnext) { nhd++; hdelim[nhd] = w; hstrip[nhd] = (hdnext == 2); hdnext = 0; return }
  if (cstart[depth]) {
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || kw(w)) return
    # timeout / nice 等の後ろの codex も sandbox の外で動くので、wrapper とそのオプション・
    # 値（秒数・nice 値・展開を含む語）を飛ばして次の語を先頭として見る
    if (wrapval[depth]) { wrapval[depth] = 0; return }
    if (!dy && wrapper(w)) { wrap[depth] = 1; return }
    if (wrap[depth] && (dy || w ~ /^-/ || w ~ /^[0-9.]+[smhd]?$/)) {
      if (w ~ /^(-n|-k|-s|-i|-o|-e|--signal|--kill-after|--adjustment|--input|--output|--error)$/) wrapval[depth] = 1
      return
    }
    cstart[depth] = 0
    if (!dy && (w == "codex" || w ~ /\/codex$/)) iscodex[depth] = 1
    return
  }
  if (iscodex[depth]) {
    cn[depth]++; ca[depth, cn[depth]] = w
    if (dy) cdyn[depth] = 1
  }
}
function endcmd(   k) {
  endword()
  skipnext = 0; hdnext = 0
  if (iscodex[depth]) {
    print (cdyn[depth] ? "D" : "C")
    for (k = 1; k <= cn[depth]; k++) print "A" ca[depth, k]
    print "E"
  }
  init(depth)
}
function pushsub(kind) {
  sp++; stk[sp] = kind
  sword[sp] = word; sinw[sp] = inword
  word = ""; inword = 0; wdyn = 0
  depth++; init(depth)
  mode = "N"
}
function popsub(   k) {
  k = stk[sp]
  endcmd()
  depth--
  word = sword[sp]; inword = 1; wdyn = 1
  sp--
  mode = (k == "SD" || k == "BD") ? "D" : "N"
}
{ src = (NR > 1) ? src "\n" $0 : $0 }
END {
  n = length(src)
  depth = 0; sp = 0; mode = "N"; nhd = 0
  init(0)
  i = 1
  while (i <= n) {
    c = substr(src, i, 1)
    nc = substr(src, i + 1, 1)
    if (mode == "Q") {
      e = index(substr(src, i), "\047")
      if (e == 0) { word = word substr(src, i); i = n + 1; continue }
      word = word substr(src, i, e - 1); i += e; mode = "N"; continue
    }
    if (mode == "D") {
      if (c == "\\") {
        if (nc == "\n") { i += 2; continue }
        if (nc ~ /[$`"\\]/) { word = word nc; i += 2; continue }
        word = word c; i++; continue
      }
      if (c == "\"") { mode = "N"; i++; continue }
      if (c == "$" && nc == "(") { pushsub("SD"); i += 2; continue }
      if (c == "`") { pushsub("BD"); i++; continue }
      if (c == "$" && nc ~ /[A-Za-z0-9_{@*#?$!-]/) wdyn = 1
      word = word c; i++; continue
    }
    # mode == "N"
    if (c == "\\") {
      if (nc == "\n") { i += 2; continue }
      word = word nc; inword = 1; i += 2; continue
    }
    if (c == "\047") { mode = "Q"; inword = 1; i++; continue }
    if (c == "\"") { mode = "D"; inword = 1; i++; continue }
    if (c == "$") {
      if (nc == "(") { pushsub("S"); i += 2; continue }
      if (nc ~ /[A-Za-z0-9_{@*#?$!\047"-]/) wdyn = 1
      if (nc == "\047" || nc == "\"") { inword = 1; i++; continue }
      word = word c; inword = 1; i++; continue
    }
    if (c == "`") {
      if (sp > 0 && (stk[sp] == "B" || stk[sp] == "BD")) popsub(); else pushsub("B")
      i++; continue
    }
    if (c == "#" && !inword) {
      e = index(substr(src, i), "\n")
      i = (e == 0) ? n + 1 : i + e - 1
      continue
    }
    if (c == " " || c == "\t") { endword(); i++; continue }
    if (c == "\n") {
      endcmd()
      i++
      for (k = 1; k <= nhd; k++) {
        while (i <= n) {
          e = index(substr(src, i), "\n")
          if (e == 0) { line = substr(src, i); i = n + 1 } else { line = substr(src, i, e - 1); i += e }
          if (hstrip[k]) sub(/^\t+/, "", line)
          if (line == hdelim[k]) break
        }
      }
      nhd = 0
      continue
    }
    if (c == ";" || c == "|") { endcmd(); i++; continue }
    if (c == "&") {
      if (nc == ">") {
        endword(); i += 2
        if (substr(src, i, 1) == ">") i++
        skipnext = 1; continue
      }
      endcmd(); i++; continue
    }
    if (c == "(") { endcmd(); sp++; stk[sp] = "P"; i++; continue }
    if (c == ")") {
      if (sp > 0 && (stk[sp] == "S" || stk[sp] == "SD")) { popsub(); i++; continue }
      endcmd()
      if (sp > 0 && stk[sp] == "P") sp--
      i++; continue
    }
    if (c == "<" || c == ">") {
      if (nc == "(") { pushsub("S"); i += 2; continue }
      if (inword && !wdyn && word ~ /^[0-9]+$/) { word = ""; inword = 0 } else endword()
      if (substr(src, i, 3) == "<<<") { skipnext = 1; i += 3; continue }
      if (c == "<" && nc == "<") {
        if (substr(src, i + 2, 1) == "-") { hdnext = 2; i += 3 } else { hdnext = 1; i += 2 }
        continue
      }
      i++
      while (substr(src, i, 1) ~ /[<>&|]/) i++
      skipnext = 1; continue
    }
    if (c ~ /[*?[{]/) wdyn = 1
    word = word c; inword = 1; i++
  }
  endcmd()
  while (depth > 0) { depth--; endcmd() }
}
'

# `-c` / `--config` で上書きさせないキー（先頭か `.` の直後）
CONFIG_KEY_RE='(^|\.)(sandbox_mode|sandbox_workspace_write|approval_policy|sandbox_permissions|shell_environment_policy|mcp_servers)'

# judge <codex の引数…>: 通すなら何も出さない。deny なら理由の種類（danger / form）を出す
judge() {
  local n=$# i v key ro=0 sub=""
  local -a a=("$@")

  for ((i = 0; i < n; i++)); do
    case ${a[i]} in
    --dangerously-* | --add-dir | --add-dir=* | --approve-for-me)
      echo danger
      return
      ;;
    -s | --sandbox | --sandbox=* | -s?*)
      case ${a[i]} in
      -s | --sandbox) v=${a[i + 1]-} ;;
      --sandbox=*) v=${a[i]#--sandbox=} ;;
      *) v=${a[i]#-s} v=${v#=} ;;
      esac
      case $v in
      read-only) ro=1 ;;
      workspace-write | danger-full-access)
        echo danger
        return
        ;;
      esac
      ;;
    -c | --config | --config=* | -c?*)
      case ${a[i]} in
      -c | --config) v=${a[i + 1]-} ;;
      --config=*) v=${a[i]#--config=} ;;
      *) v=${a[i]#-c} v=${v#=} ;;
      esac
      key=${v%%=*}
      key=${key//[[:space:]\"\']/}
      if [[ $key =~ $CONFIG_KEY_RE ]]; then
        echo danger
        return
      fi
      ;;
    esac
  done

  # サブコマンド（グローバルオプションとその値を飛ばした最初の位置引数）
  for ((i = 0; i < n; i++)); do
    case ${a[i]} in
    --)
      sub="--"
      break
      ;;
    -c | --config | --enable | --disable | --remote | --remote-auth-token-env | -i | --image | -m | --model | --local-provider | -p | --profile | -s | --sandbox | -C | --cd | --add-dir | -a | --ask-for-approval)
      i=$((i + 1))
      ;;
    -*) ;;
    *)
      sub=${a[i]}
      break
      ;;
    esac
  done

  if ((n == 1)) && [[ ${a[0]} == --version || ${a[0]} == --help ]]; then
    return
  fi
  if ((n == 2)) && [[ "${a[0]} ${a[1]}" == "features list" || "${a[0]} ${a[1]}" == "login status" ]]; then
    return
  fi
  if [[ $sub == exec || $sub == e || $sub == review ]] && ((ro)); then
    return
  fi
  echo form
}

deny() {
  jq -cn --arg reason "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

FORM_REASON='codex は sandbox の外で動く（excludedCommands の codex:*）。通すのは codex --version / --help / features list / login status と、-s read-only か --sandbox read-only を明示した codex exec / codex review だけ'
DANGER_REASON='codex の sandbox を外す・広げる指定は使わない（--dangerously-* / -s・--sandbox の workspace-write・danger-full-access / --add-dir / --approve-for-me / sandbox_mode・sandbox_workspace_write・approval_policy・sandbox_permissions・shell_environment_policy・mcp_servers の -c 上書き）。-s read-only で呼ぶ'
DYNAMIC_REASON='codex の引数に $ 展開・コマンド置換・<(…)・クォートしない glob / brace を使わない（hook が展開後の値を確かめられない）。プロンプトは - を付けて stdin（< file かクォートした heredoc）から渡す'

# collect: awk の出力を読み、最初に deny になった呼び出しの理由の種類を出す。awk が SIGPIPE で
# 落ちて pipefail が exit 0 以外を返さないよう、入力は最後まで読む
# （macOS の bash 3.2 は `$(…)` の中の case を読み違えるので関数に出しておく）
collect() {
  local verdict="" kind="" line
  local -a args=()
  while IFS= read -r line; do
    case $line in
    C | D)
      kind=$line
      args=()
      ;;
    A*) args+=("${line#A}") ;;
    E)
      if [[ -n $verdict ]]; then
        continue
      fi
      if [[ $kind == D ]]; then
        verdict=dynamic
      else
        verdict=$(judge ${args[@]+"${args[@]}"})
      fi
      ;;
    esac
  done
  echo "$verdict"
}

VERDICT=$(printf '%s\n' "$CMD" | awk "$TOKENIZER" | collect)

case $VERDICT in
dynamic) deny "$DYNAMIC_REASON" ;;
danger) deny "$DANGER_REASON" ;;
form) deny "$FORM_REASON" ;;
esac
exit 0
