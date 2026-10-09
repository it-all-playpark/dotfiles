#!/bin/bash
# PreToolUse(Bash) hook: ps / pgrep / lsof / top を sandbox 外で動く形に書かせる
#
# 背景:
#   sandbox 内では ps / top が EPERM、pgrep が "sysmond service not found"、lsof は自プロセスしか見えない。
#   settings.json の sandbox.excludedCommands に絶対パス（`/bin/ps *` `/usr/bin/top *` `/usr/bin/pgrep *`
#   `/usr/sbin/lsof *`）で登録してあるが、一致するのは絶対パスで始まる単独コマンドだけ。bare 名・`;`・パイプ・
#   `$(…)`・リダイレクトを付けると sandbox 内に戻って失敗し、agent が人間に実行を頼んでいた。
#   excludedCommands を広げずに、書き方の段階で単独・絶対パス形へ直させる。
#
# 判定:
#   コマンド位置（行頭・`;` `&` `|` `(` `$(` backtick の直後。`VAR=x` 前置とパスの前置を許す）に
#   ps / pgrep / lsof / top があり、コマンド全体が「/bin/ps /usr/bin/pgrep /usr/sbin/lsof /usr/bin/top の
#   どれかで始まる 1 行の単独コマンド（`;` `&` `|` `$(` backtick `<` `>` を含まない）」でなければ deny。
#   引数（`echo ps` `git log --grep=ps` `docker ps` `pnpm ps`）や語の一部（`topgrade`）は見ない。
#   シングルクォートの中身と、区切りをクォートした heredoc（`<<'EOF'`）の本文は展開されない文字列なので
#   先に取り除く（PR 本文や commit message に `ps aux | head` と書いても止めない）。
#   lexical な判定でシェルの完全なパースではない。目的は書き方の誘導で、見逃しは EPERM に戻るだけ。
#
# 出力:
#   - deny 時:  {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                 "permissionDecision":"deny","permissionDecisionReason":"<理由>"}}
#   - 素通し時: stdout 空で exit 0（allow は返さない。Claude 通常の permission flow に委ねる）

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [[ -z $CMD ]]; then
  exit 0
fi

# クォートした heredoc の本文を除き、残りからシングルクォートの中身を除く
STRIPPED=$(printf '%s\n' "$CMD" | awk '
  delim != "" {
    line = $0
    if (strip_tabs) sub(/^\t+/, "", line)
    if (line == delim) { delim = ""; print }
    next
  }
  {
    print
    if (match($0, /<<-?[[:space:]]*["\047][A-Za-z_][A-Za-z0-9_]*["\047]/)) {
      d = substr($0, RSTART, RLENGTH)
      strip_tabs = (d ~ /^<<-/)
      sub(/^<<-?[[:space:]]*["\047]/, "", d)
      sub(/["\047]$/, "", d)
      delim = d
    }
  }
' | sed "s/'[^']*'//g")

# コマンド位置の ps / pgrep / lsof / top
# shellcheck disable=SC2016 # 意図的なリテラル: `$(` と backtick を正規表現の字面として書く
PS_RE='(^|[;&|(`]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|()<>`]*/)?(ps|pgrep|lsof|top)([[:space:];&|()<>`]|$)'

if ! printf '%s\n' "$STRIPPED" | grep -qE "$PS_RE"; then
  exit 0
fi

# 単独・絶対パス形なら素通し
SINGLE_RE='^[[:space:]]*(/bin/ps|/usr/bin/pgrep|/usr/sbin/lsof|/usr/bin/top)([[:space:]][^;&|<>`]*)?$'
# shellcheck disable=SC2016 # 意図的なリテラル: `$(` の字面を探す
if [[ $STRIPPED != *$'\n'* && $STRIPPED != *'$('* ]] && printf '%s\n' "$STRIPPED" | grep -qE "$SINGLE_RE"; then
  exit 0
fi

# shellcheck disable=SC2016 # 意図的なリテラル: agent に見せる文字列
REASON='ps / pgrep / lsof / top は sandbox 内では EPERM になる。単独・絶対パスで叩く（/bin/ps /usr/bin/pgrep /usr/sbin/lsof /usr/bin/top で始め、; && || | $( ` リダイレクトを付けない）。件数は引数で絞る（例 /usr/bin/top -l 1 -o mem -n 15 -stats pid,command,mem）'
jq -cn --arg reason "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
exit 0
