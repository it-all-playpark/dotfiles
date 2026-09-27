#!/bin/sh
# mise が入れた claude-code の実体をバージョン非依存の固定パスへ移し、
# mise のインストールディレクトリにはそこへの symlink を残す。
#
# 目的: macOS の TCC (プライバシーとセキュリティ) は CLI バイナリを実体パスで識別するため、
# mise の installs/claude-code/<version>/claude のままだと更新のたびに別アプリ扱いになり、
# フルディスクアクセス等の一覧に claude が増え続け、許可ダイアログも毎回出る。
# 実体パスを固定すれば、署名要件 (identifier com.anthropic.claude-code + Team ID) は
# バージョン間で不変なので、一度与えた許可がそのまま引き継がれる。
#
# shim / mise activate / launchd の PATH いずれ経由でも symlink が固定パスへ解決されるので、
# PATH の順序は変えなくてよい。
# 前提: claude-code は "latest" 1 本のみ運用。複数バージョンを併存させると、全バージョンが
# 最後に pin した実体を指す。自己更新は settings.json の DISABLE_AUTOUPDATER=1 で止めている。
#
# 呼び出し元: mise/config.toml の postinstall (MISE_TOOL_INSTALL_PATH)、
# mise-upgrade launchd ジョブと home-manager activation (第 1 引数)。何度呼んでも同じ結果になる。
set -eu

install_dir="${1:-${MISE_TOOL_INSTALL_PATH:-}}"
if [ -z "$install_dir" ]; then
  echo "pin-claude-code: install dir が未指定 (引数か MISE_TOOL_INSTALL_PATH)" >&2
  exit 1
fi

bin="$install_dir/claude"
fixed_dir="$HOME/.local/opt/claude-code"
fixed="$fixed_dir/claude"

if [ -L "$bin" ]; then
  exit 0 # pin 済み
fi
if [ ! -f "$bin" ]; then
  echo "pin-claude-code: $bin がない" >&2
  exit 1
fi

mkdir -p "$fixed_dir"
# 実行中の claude が掴んでいる旧実体を上書きしないよう、同一ボリューム内の rename で差し替える
# (上書きすると code signature のページ検証に失敗して実行中プロセスが kill される)。
# cp -c は APFS clone なので 200MB 超でも即時。途中で落ちても元の実体は残る。
# -c は BSD cp 固有。PATH 上の GNU coreutils (nix) を避けるため /bin/cp を明示する。
tmp="$fixed_dir/.claude.tmp.$$"
/bin/cp -c "$bin" "$tmp"
mv -f "$tmp" "$fixed"
ln -sf "$fixed" "$bin"
echo "pin-claude-code: $bin -> $fixed"
