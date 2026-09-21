#!/usr/bin/env bash
# SessionStart hook: ~/.claude/bin (gh / gcloud / tofu の cwd 連動アカウント shim) を
# セッションの PATH 先頭に載せる。
#
# Claude Code の Bash ツールは rc ファイルを読み直さず、claude を起動した
# プロセスの PATH を snapshot して使う。ターミナルから起動すれば zsh/fish の
# rc で ~/.claude/bin が入っているが、desktop app / bg job / 古い env からの
# 起動では入らないことがある。この hook は $CLAUDE_ENV_FILE に export を
# 追記してそれを保証する。cwd には依存しない（アカウントの選択は shim が
# 実行時の $PWD で行う）ので、1 セッションで複数 org を触っても問題ない。
#
# 設計: docs/specs/2026-09-19-claude-account-env-design.md §7
#
# 環境変数:
#   CLAUDE_ENV_FILE  Claude Code が渡す。未設定なら何もしない (exit 0)
#   HOME             ~/.claude/bin の基点。未設定なら何もしない (exit 0)

set -euo pipefail

[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
[ -n "${HOME:-}" ] || exit 0

# 既に先頭にあれば二重追加しない（resume / compact で複数回呼ばれる）
case ":${PATH:-}:" in
":$HOME/.claude/bin:"*) exit 0 ;;
esac

# shellcheck disable=SC2016 # 意図的なリテラル: $PATH は展開させず export 行としてそのまま書き出す
printf 'export PATH="%s/.claude/bin:$PATH"\n' "$HOME" >>"$CLAUDE_ENV_FILE"
