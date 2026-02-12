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
      ffmpeg
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
      ollama
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

      # skills ディレクトリは setup-skills.sh で管理（setup.sh から呼び出される）
      # ここでは触れない - 既存の symlink を保持するため

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

      # hooks ディレクトリ内のスクリプトへのシンボリックリンク
      if [ -d "$DOTFILES_CLAUDE/hooks" ]; then
        mkdir -p "$CLAUDE_DIR/hooks"
        for f in "$DOTFILES_CLAUDE"/hooks/*.py; do
          if [ -f "$f" ]; then
            target="$CLAUDE_DIR/hooks/$(basename "$f")"
            if [ -f "$target" ] && [ ! -L "$target" ]; then
              rm "$target"
            fi
            ln -sf "$f" "$target"
          fi
        done
      fi
    '';

    # OpenClaw 設定を dotfiles/openclaw/ からシンボリックリンクで参照
    # ~/.openclaw 自体をシンボリックリンクにして、設定ファイルを一元管理
    activation.setupOpenclaw = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      DOTFILES_OPENCLAW="${config.home.homeDirectory}/ghq/github.com/it-all-playpark/dotfiles/openclaw"
      OPENCLAW_DIR="${config.home.homeDirectory}/.openclaw"

      # dotfiles が存在しない場合はスキップ（初回セットアップ時などを考慮）
      if [ ! -d "$DOTFILES_OPENCLAW" ]; then
        echo "Warning: $DOTFILES_OPENCLAW does not exist. Skipping OpenClaw setup."
        exit 0
      fi

      # ~/.openclaw がシンボリックリンクでない場合の処理
      if [ -e "$OPENCLAW_DIR" ] && [ ! -L "$OPENCLAW_DIR" ]; then
        # 既存のディレクトリをバックアップ
        BACKUP_DIR="$OPENCLAW_DIR.backup.$(date +%Y%m%d%H%M%S)"
        echo "Backing up existing .openclaw directory to $BACKUP_DIR"
        mv "$OPENCLAW_DIR" "$BACKUP_DIR"

        # バックアップから credentials, identity, .env をコピー（存在する場合）
        # -p オプションでパーミッションを保持（機密ファイル向け）
        if [ -d "$BACKUP_DIR/credentials" ]; then
          cp -rp "$BACKUP_DIR/credentials" "$DOTFILES_OPENCLAW/credentials"
        fi
        if [ -d "$BACKUP_DIR/identity" ]; then
          cp -rp "$BACKUP_DIR/identity" "$DOTFILES_OPENCLAW/identity"
        fi
        if [ -f "$BACKUP_DIR/.env" ]; then
          cp "$BACKUP_DIR/.env" "$DOTFILES_OPENCLAW/.env"
        fi
      elif [ -L "$OPENCLAW_DIR" ]; then
        # 既存のシンボリックリンクを削除（正しいリンク先に更新するため）
        rm "$OPENCLAW_DIR"
      fi

      # ~/.openclaw → dotfiles/openclaw/ のシンボリックリンク作成
      ln -sfn "$DOTFILES_OPENCLAW" "$OPENCLAW_DIR"
    '';
  };

  # Ollama サーバーをログイン時に自動起動
  # macOS: launchd agent, Linux: systemd user service
  services.ollama = {
    enable = true;
  };
}