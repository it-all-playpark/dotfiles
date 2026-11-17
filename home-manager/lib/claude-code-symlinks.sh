# shellcheck shell=bash
# home-manager/lib/claude-code-symlinks.sh
# dotfiles の claude-code/ にある指示書・hooks・bin を ~/.claude/ 配下へ symlink する処理。
# home-manager の activation（home-manager/home/default.nix の setupClaudeCode と
# home-manager/grokbot-linux/default.nix）が、次の変数を決めたうえで source する:
#   DOTFILES_CLAUDE     - dotfiles の claude-code/ の絶対パス（symlink 元）
#   CLAUDE_DIR          - ~/.claude の絶対パス（symlink 先。作成済みであること）
#   CLAUDE_BIN_EXCLUDE  - bin/ のうち symlink しないファイル名（空白区切り。省略時は除外なし）
# tests/claude-hooks-symlink.test.sh と tests/claude-bin-symlink.test.sh がマーカーで区間を抜き出して検証する。

# markdown files へのシンボリックリンク
for f in CLAUDE.md RULES.md FLAGS.md README.md; do
  target="$CLAUDE_DIR/$f"
  if [ -f "$target" ] && [ ! -L "$target" ]; then
    rm "$target"
  fi
  [ -f "$DOTFILES_CLAUDE/$f" ] && ln -sf "$DOTFILES_CLAUDE/$f" "$target"
done

# MCP_*.md files
for f in "$DOTFILES_CLAUDE"/MCP_*.md; do
  if [ -f "$f" ]; then
    target="$CLAUDE_DIR/$(basename "$f")"
    if [ -f "$target" ] && [ ! -L "$target" ]; then
      rm "$target"
    fi
    ln -sf "$f" "$target"
  fi
done

# MODE_*.md files
for f in "$DOTFILES_CLAUDE"/MODE_*.md; do
  if [ -f "$f" ]; then
    target="$CLAUDE_DIR/$(basename "$f")"
    if [ -f "$target" ] && [ ! -L "$target" ]; then
      rm "$target"
    fi
    ln -sf "$f" "$target"
  fi
done

# hooks-symlink: begin
# hooks ディレクトリ内のスクリプトへのシンボリックリンク
if [ -d "$DOTFILES_CLAUDE/hooks" ]; then
  mkdir -p "$CLAUDE_DIR/hooks"

  # dotfiles 側で削除された hook の dangling symlink を掃除する
  # (plugin へ移植した hook 等。dotfiles/claude-code/hooks を指すものだけ対象)
  for t in "$CLAUDE_DIR"/hooks/*; do
    if [ -L "$t" ] && [ ! -e "$t" ]; then
      case "$(readlink "$t")" in
      "$DOTFILES_CLAUDE"/hooks/*) rm -f "$t" ;;
      esac
    fi
  done

  for f in "$DOTFILES_CLAUDE"/hooks/*.py "$DOTFILES_CLAUDE"/hooks/*.sh; do
    if [ -f "$f" ]; then
      base="$(basename "$f")"
      case "$base" in
      *.test.sh) continue ;;
      esac
      target="$CLAUDE_DIR/hooks/$base"
      if [ -f "$target" ] && [ ! -L "$target" ]; then
        rm "$target"
      fi
      ln -sf "$f" "$target"
    fi
  done
fi
# hooks-symlink: end

# bin-symlink: begin
# gh / gcloud / tofu の cwd 連動アカウント shim (bin/account-exec と symlink の bin/gh, bin/gcloud, bin/tofu) を
# ~/.claude/bin/ へ symlink。bin/gh は repo 内で account-exec への symlink なので
# ~/.claude/bin/gh → claude-code/bin/gh → account-exec の 2 段になる (ln -sf は dereference しない)
if [ -d "$DOTFILES_CLAUDE/bin" ]; then
  mkdir -p "$CLAUDE_DIR/bin"

  # dotfiles 側で削除された shim の dangling symlink を掃除する
  # (dotfiles/claude-code/bin を指すものだけ対象)
  for t in "$CLAUDE_DIR"/bin/*; do
    if [ -L "$t" ] && [ ! -e "$t" ]; then
      case "$(readlink "$t")" in
      "$DOTFILES_CLAUDE"/bin/*) rm -f "$t" ;;
      esac
    fi
  done

  for f in "$DOTFILES_CLAUDE"/bin/*; do
    # repo 内 symlink (bin/gh) も対象にするため -f ではなく -e / -L で判定
    if { [ -e "$f" ] || [ -L "$f" ]; } && [ ! -d "$f" ]; then
      base="$(basename "$f")"
      case "$base" in
      *.test.sh | *.bats) continue ;;
      esac
      # CLAUDE_BIN_EXCLUDE に挙げた名前は張らない（その構成では使わない bin）
      case " ${CLAUDE_BIN_EXCLUDE:-} " in
      *" $base "*) continue ;;
      esac
      target="$CLAUDE_DIR/bin/$base"
      if [ -e "$target" ] && [ ! -L "$target" ]; then
        rm "$target"
      fi
      ln -sf "$f" "$target"
    fi
  done
fi
# bin-symlink: end
