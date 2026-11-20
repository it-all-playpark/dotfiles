#!/usr/bin/env bash
# cloud/setup.sh
# Claude Code のクラウドセッション用の setup。クラウド環境の setup スクリプトから、dotfiles を clone したあとに呼ぶ
# （手順は cloud/README.md）。何度実行しても同じ結果になる。
#
#   1. bats と codex CLI を入れる（dev-flow が使う。jq は settings の生成に使う）
#   2. claude-code/hooks/ の hook を $HOME/.claude/hooks/ に、claude-code/bin/ のコマンドを $HOME/.claude/bin/ に symlink する
#   3. cloud/settings.jq で claude-code/settings.json から $HOME/.claude/settings.json を作る
#
# クラウドのコンテナは root で動く前提（apt-get / npm install -g に sudo を付けない）。

set -euo pipefail

# codex CLI（@openai/codex）の版。上げるときはここを書き換える
CODEX_VERSION="0.171.0"

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"

# 1. tools
apt-get update
apt-get install -y --no-install-recommends bats jq
npm install -g "@openai/codex@$CODEX_VERSION"

# 2. hooks（Mac の home-manager/lib/claude-code-symlinks.sh と同じく *.py / *.sh を張り、*.test.sh は張らない）
mkdir -p "$CLAUDE_DIR/hooks"
hook_files=()
for f in "$DOTFILES"/claude-code/hooks/*.py "$DOTFILES"/claude-code/hooks/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in
  *.test.sh) continue ;;
  esac
  ln -sfn "$f" "$CLAUDE_DIR/hooks/$base"
  hook_files+=("$base")
done

# bin（hook は $SCRIPT_DIR/../bin/jev-classify、statusLine は ~/.claude/bin/health-statusline を参照する。
# Mac の home-manager/lib/claude-code-symlinks.sh と同じく *.test.sh / *.bats は張らない）
mkdir -p "$CLAUDE_DIR/bin"
for f in "$DOTFILES"/claude-code/bin/*; do
  # repo 内 symlink（bin/gh）も対象にするため -f ではなく -e / -L で判定
  if { [ -e "$f" ] || [ -L "$f" ]; } && [ ! -d "$f" ]; then
    base="$(basename "$f")"
    case "$base" in
    *.test.sh | *.bats) continue ;;
    esac
    ln -sfn "$f" "$CLAUDE_DIR/bin/$base"
  fi
done

# 3. settings
# settings の env.PATH に続ける PATH。再実行で重ならないよう、settings が先頭に足す 2 つは除く
base_path=""
rest="$PATH:"
while [ -n "$rest" ]; do
  dir="${rest%%:*}"
  rest="${rest#*:}"
  case "$dir" in
  "" | "$DOTFILES/cloud/bin" | "$DOTFILES/claude-code/bin") continue ;;
  esac
  base_path="${base_path:+$base_path:}$dir"
done

generated="$(mktemp "${TMPDIR:-/tmp}/cloud-settings.XXXXXX")"
trap 'rm -f "$generated"' EXIT
jq --arg dotfiles "$DOTFILES" \
  --arg path "$base_path" \
  --argjson hook_files "$(printf '%s\n' "${hook_files[@]}" | jq -R . | jq -sc .)" \
  -f "$DOTFILES/cloud/settings.jq" "$DOTFILES/claude-code/settings.json" >"$generated"

settings="$CLAUDE_DIR/settings.json"
if [ -e "$settings" ] || [ -L "$settings" ]; then
  if cmp -s "$generated" "$settings"; then
    exit 0
  fi
  # 既にある settings（環境が置いたもの・前回と違う生成物）は退避してから書く
  mv -f "$settings" "$settings.bak"
fi
cp "$generated" "$settings"
