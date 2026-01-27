{ pkgs, lib, config, username ? "naramotoyuuji", ... }:
let
  packages = import ../../common/packages.nix { inherit pkgs; };
in
{
  # claude-code のみ unfree を許可
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (pkgs.lib.getName pkg) [ "claude-code" ];

  home = {
    username = username;
    homeDirectory = pkgs.lib.strings.concatStringsSep "" [
      (pkgs.lib.optionalString pkgs.stdenv.isDarwin "/Users/")
      (pkgs.lib.optionalString (!pkgs.stdenv.isDarwin) "/home/")
      username
    ];
    stateVersion = "24.05"; # Please read the comment before changing.

    # 共通パッケージを全プラットフォームでインストール
    packages = packages.commonPackages ++ (with pkgs; [
      act
      bat
      claude-code
      python313Packages.deepl
      devcontainer
      eza
      fastfetch
      fd
      flyctl
      fzf
      gh
      ghq
      jq
      lazydocker
      lazygit
      mariadb
      marp-cli
      mise
      # mycli  # TODO: 一時的に無効化 - llm 0.28 のテスト失敗 (nixpkgs upstream issue)
      opentofu
      postgresql_17
      procs
      rip2
      ripgrep
      ripgrep-all
      sd
      starship
      stripe-cli
      tbls
      tldr
      tmux
      vips
      zoxide
    ]);

    file = {
      ".tmux.conf".source = ./file/.tmux.conf;
      ".myclirc".source = ./file/.myclirc;
      ".ripgreprc".source = ./file/.ripgreprc;
      ".mcpservers.json.template".source = ./file/.mcpservers.json.template;
      ".myclirc.local.template".source = ./file/.myclirc.local.template;
      ".config/git/config.local.template".source = ./file/git/config.local.template;
      ".config/fish/config.fish.local.template".source = ./file/fish/config.fish.local.template;
      ".config/nvim" = {
        source = ./file/nvim;
        recursive = true;
      };
      ".config/mise" = {
        source = ./file/mise;
        recursive = true;
      };
      ".config/zed" = {
        source = ./file/zed;
        recursive = true;
      };
      "Library/Application Support/lazygit" = {
        source = ./file/lazygit;
        recursive = true;
      };
      ".warp" = {
        source = ./file/.warp;
        recursive = true;
      };
    };

    # Claude Code 設定を dotfiles/claude-code/ からシンボリックリンクで参照
    # Nixのread-only制約を回避し、直接編集可能にする
    activation.setupClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      DOTFILES_CLAUDE="${config.home.homeDirectory}/ghq/github.com/it-all-playpark/dotfiles/claude-code"
      CLAUDE_DIR="${config.home.homeDirectory}/.claude"

      # dotfiles が存在しない場合はスキップ（初回セットアップ時などを考慮）
      if [ ! -d "$DOTFILES_CLAUDE" ]; then
        echo "Warning: $DOTFILES_CLAUDE does not exist. Skipping Claude Code setup."
        exit 0
      fi

      # ~/.claude ディレクトリ作成
      mkdir -p "$CLAUDE_DIR"

      # skills ディレクトリへのシンボリックリンク
      # 既存のディレクトリ（シンボリックリンクでない）はバックアップしてから置換
      # 注意: -d はシンボリックリンク先がディレクトリの場合も true を返すため、
      # -L でシンボリックリンクチェックを先に行う
      if [ -e "$CLAUDE_DIR/skills" ] && [ ! -L "$CLAUDE_DIR/skills" ]; then
        BACKUP_DIR="$CLAUDE_DIR/skills.backup.$(date +%Y%m%d%H%M%S)"
        echo "Backing up existing skills directory to $BACKUP_DIR"
        mv "$CLAUDE_DIR/skills" "$BACKUP_DIR"
      elif [ -L "$CLAUDE_DIR/skills" ]; then
        # 既存のシンボリックリンクを削除（正しいリンク先に更新するため）
        rm "$CLAUDE_DIR/skills"
      fi
      ln -sfn "$DOTFILES_CLAUDE/skills" "$CLAUDE_DIR/skills"

      # settings.json へのシンボリックリンク
      # 既存ファイルがシンボリックリンクでない場合は削除
      if [ -f "$CLAUDE_DIR/settings.json" ] && [ ! -L "$CLAUDE_DIR/settings.json" ]; then
        rm "$CLAUDE_DIR/settings.json"
      fi
      ln -sf "$DOTFILES_CLAUDE/settings.json" "$CLAUDE_DIR/settings.json"

      # markdown files へのシンボリックリンク
      for f in CLAUDE.md PRINCIPLES.md RULES.md FLAGS.md README.md; do
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
    '';
  };
}
