#!/usr/bin/env bash
# PreToolUse(Bash) hook: public repo に個人情報・取引先名・secret を出す前に人間に確認する
#
# 目的:
#   public repo では push した branch も PR / issue の本文も、その時点で公開される。CI で
#   見つけても遅いので、公開する操作の直前に決定論で止める（dotfiles で携帯番号・取引先名・
#   API キーが公開されていた件の再発防止）。
#
# 対象 repo:
#   cwd の repo の root に `.public-repo` がある repo だけ（他の repo では何もしない）。
#
# 検査する操作と範囲:
#   - git push: まだどの remote にも無い commit（--branches --not --remotes）の追加行と commit message
#   - gh pr|issue create|comment|edit: コマンド文字列（--title / --body）と --body-file / -F のファイル
#
# パターン:
#   - 汎用（ここに書く）: 携帯電話番号、token の形（GitHub / AWS / Slack / OpenAI 系 / DeepL）、秘密鍵
#   - 固有（取引先名・住所など）: private repo の denylist（1 行 1 つの拡張正規表現、大文字小文字を
#     区別しない、# 始まりはコメント）。public に禁止語を書くとそれ自体が漏洩になるので分ける
#   `public-guard: allow` を含む行は検査しない（テストの fixture など、意図して残す行）。
#
# 出力:
#   検知時は permissionDecision "ask"（人間が内容を見て決める）。非検知・対象外は stdout 空で exit 0。
#
# 環境変数:
#   PUBLIC_GUARD_DENYLIST  denylist の場所（既定 ~/ghq/github.com/it-all-playpark/dotfiles-private/public-guard/denylist）

set -euo pipefail

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT")
CWD=$(jq -r '.cwd // empty' <<<"$INPUT")
[[ -n $CMD ]] || exit 0
[[ -n $CWD && -d $CWD ]] || CWD=$PWD

PUSH_RE='(^|[;&|[:space:]])git([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+push([[:space:];&|]|$)'
GH_RE='(^|[;&|[:space:]])gh([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+(pr|issue)[[:space:]]+(create|comment|edit)([[:space:];&|]|$)'

is_push=0
is_gh=0
grep -qE "$PUSH_RE" <<<"$CMD" && is_push=1
grep -qE "$GH_RE" <<<"$CMD" && is_gh=1
[[ $is_push -eq 1 || $is_gh -eq 1 ]] || exit 0

ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
[[ -f "$ROOT/.public-repo" ]] || exit 0

DENYLIST="${PUBLIC_GUARD_DENYLIST:-$HOME/ghq/github.com/it-all-playpark/dotfiles-private/public-guard/denylist}"

# 汎用パターン: 携帯電話番号 / GitHub token / AWS access key / Slack token / OpenAI・Anthropic 系の key /
# DeepL の key（UUID:fx）/ 秘密鍵。番号と sk- は英数字に挟まれたもの（hash の一部、task- 等）を拾わない
GENERIC_RE='(^|[^0-9A-Za-z])0[789]0[- ]?[0-9]{4}[- ]?[0-9]{4}([^0-9A-Za-z]|$)|gh[pousr]_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|(^|[^0-9A-Za-z])sk-(ant-)?[A-Za-z0-9_-]{20,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:fx|-----BEGIN [A-Z ]*PRIVATE KEY-----'

TEXT=$(mktemp "${TMPDIR:-/tmp}/public-guard.XXXXXX")
trap 'rm -f "$TEXT"' EXIT

if [[ $is_push -eq 1 ]]; then
  git -C "$CWD" log --format=%B --branches --not --remotes >>"$TEXT" 2>/dev/null || true
  git -C "$CWD" log -p --format= --branches --not --remotes 2>/dev/null |
    grep -E '^\+' | grep -vE '^\+\+\+ ' >>"$TEXT" || true
fi

if [[ $is_gh -eq 1 ]]; then
  printf '%s\n' "$CMD" >>"$TEXT"
  files=$(grep -oE '(--body-file|-F)(=|[[:space:]]+)[^;&|[:space:]]+' <<<"$CMD" |
    sed -E 's/^(--body-file|-F)(=|[[:space:]]+)//; s/^["'\'']//; s/["'\'']$//' || true)
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    [[ $f == /* ]] || f="$CWD/$f"
    if [[ -f $f ]]; then cat "$f" >>"$TEXT"; fi
  done <<<"$files"
fi

SCAN=$(grep -v 'public-guard: allow' "$TEXT" || true)
[[ -n $SCAN ]] || exit 0

hits=$(grep -oE "$GENERIC_RE" <<<"$SCAN" || true)
if [[ -f $DENYLIST ]]; then
  while IFS= read -r pat; do
    [[ -z $pat || $pat == \#* ]] && continue
    hits+=$'\n'$(grep -oiE -- "$pat" <<<"$SCAN" || true)
  done <"$DENYLIST"
fi
hits=$(grep -v '^$' <<<"$hits" | sort -u | head -5 || true)
[[ -n $hits ]] || exit 0

# 見つけた値そのものは理由に載せない（ログや画面に残る）。先頭 4 文字と長さだけ示す
summary=$(while IFS= read -r h; do printf '%s…(%d文字) ' "${h:0:4}" "${#h}"; done <<<"$hits")
denynote=""
[[ -f $DENYLIST ]] || denynote="（denylist ${DENYLIST} が無いので、取引先名などの固有語は検査していない）"
reason="public repo（${ROOT}）に出す内容に、個人情報・取引先名・secret らしき文字列がある: ${summary}${denynote}。取引先や個人の情報は dotfiles-private に置く。意図して残す行には 'public-guard: allow' を書く"

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
