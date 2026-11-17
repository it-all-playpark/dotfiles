# Grok Bot の box（使い捨ての隔離 Linux コンテナ。ユーザー box、作業領域 /workspace）用の最小構成。
# フル構成（home-manager/default.nix）は GUI・macOS・個人用ツール込みなので imports しない。
# 手順は README.md の「Grok Bot の box」を参照。
{
  pkgs,
  lib,
  config,
  ...
}:
let
  # box 上の dotfiles の checkout パス。symlink 元と、Linux 版 settings の denyWrite はこの値から作る。
  # 別の場所に置くときは GROKBOT_DOTFILES_CHECKOUT を渡して --impure で switch する（README.md 参照）。
  checkoutFromEnv = builtins.getEnv "GROKBOT_DOTFILES_CHECKOUT";
  dotfilesCheckout = if checkoutFromEnv != "" then checkoutFromEnv else "/workspace/dotfiles";

  # Linux 版の Claude Code settings。Mac 版（claude-code/settings.json）に settings.jq の変換を当てて作る
  # （手で写した JSON を repo に置かない）。変換の中身は tests/grokbot-linux-settings.test.sh が確かめる
  claudeSettings = pkgs.runCommand "grokbot-linux-claude-settings.json" { } ''
    ${pkgs.jq}/bin/jq --arg checkout ${lib.escapeShellArg dotfilesCheckout} \
      -f ${./settings.jq} ${../../claude-code/settings.json} > $out
  '';
in
{
  home = {
    username = "box";
    homeDirectory = "/home/box";
    stateVersion = "24.05";

    packages = [
      pkgs.socat
      pkgs.tmux
      pkgs.postgresql_17
      pkgs.gh
    ];

    # Claude Code の設定を置く。指示書・hooks・bin は checkout への symlink（home-manager/home/default.nix の
    # setupClaudeCode と同じ処理）、user settings は上で生成した Linux 版
    activation.setupClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # `exit 0` の影響をこのブロック内に閉じ込めるためのサブシェル（tests/hm-activation-exit.test.sh）
      (
      DOTFILES_CLAUDE="${dotfilesCheckout}/claude-code"
      CLAUDE_DIR="${config.home.homeDirectory}/.claude"
      # box では使わない bin（Mac の docker 振り分けと、Mac 側の checkout を更新・反映するコマンド）
      CLAUDE_BIN_EXCLUDE="docker dotfiles-apply dotfiles-sync"

      if [ ! -d "$DOTFILES_CLAUDE" ]; then
        echo "Warning: $DOTFILES_CLAUDE does not exist. Skipping Claude Code setup."
        exit 0
      fi

      mkdir -p "$CLAUDE_DIR"

      # user settings は生成した Linux 版（nix store）への symlink。既存の通常ファイルは置き換える
      if [ -f "$CLAUDE_DIR/settings.json" ] && [ ! -L "$CLAUDE_DIR/settings.json" ]; then
        rm "$CLAUDE_DIR/settings.json"
      fi
      ln -sf ${claudeSettings} "$CLAUDE_DIR/settings.json"

      . ${../lib/claude-code-symlinks.sh}
      )
    '';
  };

  # 2 回目以降の `home-manager switch --flake .#grokbot-linux` 用
  programs.home-manager.enable = true;
}
