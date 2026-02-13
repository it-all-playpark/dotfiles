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

    # Codex 設定を dotfiles/codex/ から同期
    # runtime データを維持しつつ、静的設定のみを管理する
    activation.setupCodex = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      DOTFILES_CODEX="${config.home.homeDirectory}/ghq/github.com/it-all-playpark/dotfiles/codex"
      CODEX_DIR="${config.home.homeDirectory}/.codex"
      GENERATED_MARKER="# AUTO-GENERATED BY DOTFILES CODEX SETUP"
      migrated_from_existing=0

      # dotfiles が存在しない場合はスキップ（初回セットアップ時などを考慮）
      if [ ! -d "$DOTFILES_CODEX" ]; then
        echo "Warning: $DOTFILES_CODEX does not exist. Skipping Codex setup."
        exit 0
      fi

      mkdir -p "$CODEX_DIR"

      # 静的アセットをシンボリックリンクで同期
      # NOTE: rules は Codex runtime で更新されるため symlink 管理しない
      for d in prompts policy; do
        src="$DOTFILES_CODEX/$d"
        target="$CODEX_DIR/$d"

        if [ ! -d "$src" ]; then
          continue
        fi

        if [ -L "$target" ]; then
          rm "$target"
        elif [ -e "$target" ]; then
          backup="$CODEX_DIR/''${d}.backup.$(date +%Y%m%d%H%M%S)"
          echo "Backing up existing $target to $backup"
          mv "$target" "$backup"
        fi

        ln -sfn "$src" "$target"
      done

      # rules は runtime で更新されるためローカル実体ファイルを保持する
      rules_dir="$CODEX_DIR/rules"
      if [ -L "$rules_dir" ]; then
        rm "$rules_dir"
      elif [ -e "$rules_dir" ] && [ ! -d "$rules_dir" ]; then
        backup="$CODEX_DIR/rules.backup.$(date +%Y%m%d%H%M%S)"
        echo "Backing up existing $rules_dir to $backup"
        mv "$rules_dir" "$backup"
      fi
      mkdir -p "$rules_dir"

      rules_target="$rules_dir/default.rules"
      if [ -L "$rules_target" ]; then
        rm "$rules_target"
      fi
      if [ ! -f "$rules_target" ] && [ -f "$DOTFILES_CODEX/rules/default.rules" ]; then
        cp "$DOTFILES_CODEX/rules/default.rules" "$rules_target"
      fi

      # base config をシンボリックリンクで同期
      if [ -f "$CODEX_DIR/config.base.toml" ] && [ ! -L "$CODEX_DIR/config.base.toml" ]; then
        rm "$CODEX_DIR/config.base.toml"
      fi
      if [ -f "$DOTFILES_CODEX/config.base.toml" ]; then
        ln -sfn "$DOTFILES_CODEX/config.base.toml" "$CODEX_DIR/config.base.toml"
      fi

      if [ ! -f "$CODEX_DIR/config.base.toml" ]; then
        echo "Warning: $DOTFILES_CODEX/config.base.toml does not exist. Skipping Codex config generation."
        exit 0
      fi

      # config.local.toml がない場合は既存 config.toml から移行、なければ template から生成
      if [ ! -f "$CODEX_DIR/config.local.toml" ]; then
        if [ -f "$CODEX_DIR/config.toml" ] && [ "$(head -n 1 "$CODEX_DIR/config.toml" 2>/dev/null)" != "$GENERATED_MARKER" ]; then
          backup="$CODEX_DIR/config.toml.backup.$(date +%Y%m%d%H%M%S)"
          cp "$CODEX_DIR/config.toml" "$backup"
          extracted="$CODEX_DIR/config.local.toml.extracted.tmp"
          : > "$extracted"
          keep=0
          while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
              \[*\])
                case "$line" in
                  "[projects."*|"[mcp_servers"*)
                    keep=1
                    ;;
                  *)
                    keep=0
                    ;;
                esac
                ;;
            esac

            if [ "$keep" -eq 1 ]; then
              printf '%s\n' "$line" >> "$extracted"
            fi
          done < "$backup"

          if [ -s "$extracted" ]; then
            {
              echo "# Migrated from legacy ~/.codex/config.toml."
              echo "# Review and clean up as needed."
              echo ""
              cat "$extracted"
            } > "$CODEX_DIR/config.local.toml"
          elif [ -f "$DOTFILES_CODEX/config.local.toml.template" ]; then
            cp "$DOTFILES_CODEX/config.local.toml.template" "$CODEX_DIR/config.local.toml"
            echo "" >> "$CODEX_DIR/config.local.toml"
            echo "# Backup from migration: $backup" >> "$CODEX_DIR/config.local.toml"
          else
            echo "# Backup from migration: $backup" > "$CODEX_DIR/config.local.toml"
          fi

          rm -f "$extracted"
          chmod 600 "$CODEX_DIR/config.local.toml"
          echo "Migrated existing config.toml sections to config.local.toml (backup: $backup)"
          migrated_from_existing=1
        elif [ -f "$DOTFILES_CODEX/config.local.toml.template" ]; then
          cp "$DOTFILES_CODEX/config.local.toml.template" "$CODEX_DIR/config.local.toml"
          chmod 600 "$CODEX_DIR/config.local.toml"
          echo "Created $CODEX_DIR/config.local.toml from template"
        else
          touch "$CODEX_DIR/config.local.toml"
          chmod 600 "$CODEX_DIR/config.local.toml"
        fi
      fi

      # 既存の手動 config.toml は初回のみバックアップ
      if [ "$migrated_from_existing" -eq 0 ] && [ -f "$CODEX_DIR/config.toml" ] && [ "$(head -n 1 "$CODEX_DIR/config.toml" 2>/dev/null)" != "$GENERATED_MARKER" ]; then
        backup="$CODEX_DIR/config.toml.backup.$(date +%Y%m%d%H%M%S)"
        cp "$CODEX_DIR/config.toml" "$backup"
        echo "Backed up existing config.toml to $backup"
      fi

      # base + local で config.toml を再生成
      tmp_config="$CODEX_DIR/config.toml.tmp"
      {
        echo "$GENERATED_MARKER"
        echo "# Edit dotfiles/codex/config.base.toml for shared settings."
        echo "# Edit ~/.codex/config.local.toml for local secrets and overrides."
        echo ""
        cat "$CODEX_DIR/config.base.toml"
        if [ -s "$CODEX_DIR/config.local.toml" ]; then
          echo ""
          echo "# ---- Local overrides ----"
          cat "$CODEX_DIR/config.local.toml"
        fi
      } > "$tmp_config"

      mv "$tmp_config" "$CODEX_DIR/config.toml"
      chmod 600 "$CODEX_DIR/config.toml"
    '';
  };

  # Ollama サーバーをログイン時に自動起動
  # macOS: launchd agent, Linux: systemd user service
  services.ollama = {
    enable = true;
  };
}
