{
  pkgs,
  lib,
  config,
  username ? "naramotoyuuji",
  ...
}:
let
  packages = import ../../common/packages.nix { inherit pkgs; };
  # CLI tool 一覧は lib/cli-packages.nix に集約 (mode=host で hostOnly 込みのフルセット)
  # hermes-agent 用 container image (mode=container) と単一ソースを共有する。
  cliPackages = import ../../lib/cli-packages.nix {
    inherit pkgs;
    mode = "host";
    # 注: cliPackages の common には commonPackages と重複する coreutils/curl/git を含む。
    # Nix store の dedup によりインストール上の重複は発生しない (behavior-preserving)。
  };
in
{
  home = {
    username = username;
    homeDirectory = pkgs.lib.strings.concatStringsSep "" [
      (pkgs.lib.optionalString pkgs.stdenv.isDarwin "/Users/")
      (pkgs.lib.optionalString (!pkgs.stdenv.isDarwin) "/home/")
      username
    ];
    stateVersion = "24.05"; # Please read the comment before changing.

    # 共通パッケージ + CLI tool 群 (host モード)
    packages = packages.commonPackages ++ cliPackages;

    file = {
      ".myclirc".source = ./file/.myclirc;
      ".ripgreprc".source = ./file/.ripgreprc;
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
      ".config/ghostty" = {
        source = ./file/ghostty;
        recursive = true;
      };
      ".config/zellij" = {
        source = ./file/zellij;
        recursive = true;
      };
      ".config/herdr" = {
        source = ./file/herdr;
        recursive = true;
      };
      ".config/cc-launch" = {
        source = ./file/cc-launch;
        recursive = true;
      };
    };

    # Claude Code 設定を dotfiles/claude-code/ からシンボリックリンクで参照
    # claude-code バイナリ自体は mise で管理（home-manager/home/file/mise/config.toml）
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

      # ~/.claude/agents → skills repo の .claude/agents
      # dev-kickoff-worker 等の subagent 定義。任意 repo で dev-flow を実行するには
      # user-global (~/.claude/agents) で解決させる必要があるため home-manager で symlink。
      # skills 本体は setup-skills.sh 管理だが、agents は cwd 非依存解決が必須なのでここで貼る。
      SKILLS_AGENTS="${config.home.homeDirectory}/ghq/github.com/it-all-playpark/skills/.claude/agents"
      CLAUDE_AGENTS="$CLAUDE_DIR/agents"
      if [ -d "$SKILLS_AGENTS" ]; then
        if [ -L "$CLAUDE_AGENTS" ] || [ ! -e "$CLAUDE_AGENTS" ]; then
          ln -sfn "$SKILLS_AGENTS" "$CLAUDE_AGENTS"
        else
          echo "Warning: $CLAUDE_AGENTS exists and is not a symlink. Skipping (manual review needed)."
        fi
      else
        echo "Warning: $SKILLS_AGENTS does not exist. Skipping agents symlink."
      fi

      # ~/.claude/skills/hunk-review → hunk 同梱スキル（upstream 推奨の symlink 方式）
      # `hunk skill path` の store path は hunk 更新 + GC で消えるため、
      # rebuild ごとに現行世代の pkgs.hunk へ貼り直して同期を保つ。
      # ~/.claude/skills は skills repo への symlink なので実体は repo 内に作られる
      # （store path は環境依存のため skills repo 側で gitignore する）。
      CLAUDE_SKILLS="$CLAUDE_DIR/skills"
      HUNK_SKILL="$CLAUDE_SKILLS/hunk-review"
      if [ -d "$CLAUDE_SKILLS" ]; then
        if [ -L "$HUNK_SKILL" ] || [ ! -e "$HUNK_SKILL" ]; then
          ln -sfn "${pkgs.hunk}/skills/hunk-review" "$HUNK_SKILL"
        else
          echo "Warning: $HUNK_SKILL exists and is not a symlink. Skipping (manual review needed)."
        fi
      else
        echo "Warning: $CLAUDE_SKILLS does not exist. Skipping hunk-review skill symlink."
      fi

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

      # hooks.json は Codex runtime が trust state を持つためここでは上書きしない。
      # ただし既存 hooks.json が参照する ~/.codex/hooks/* は dotfiles から補完する。
      # 参照先が欠けると PreToolUse/PostToolUse が毎回失敗するため、hook scripts は managed symlink にする。
      if [ -d "$DOTFILES_CODEX/hooks" ]; then
        hooks_dir="$CODEX_DIR/hooks"
        mkdir -p "$hooks_dir"
        for f in "$DOTFILES_CODEX"/hooks/*.py "$DOTFILES_CODEX"/hooks/*.sh; do
          if [ -f "$f" ]; then
            base="$(basename "$f")"
            case "$base" in
              *.test.sh) continue ;;
            esac
            target="$hooks_dir/$base"
            if [ -e "$target" ] && [ ! -L "$target" ]; then
              backup="$hooks_dir/$base.backup.$(date +%Y%m%d%H%M%S)"
              echo "Backing up existing Codex hook $target to $backup"
              mv "$target" "$backup"
            fi
            ln -sfn "$f" "$target"
          fi
        done
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

    # Hermes-agent 設定を dotfiles/hermes/ からシンボリックリンクで参照
    # - config.yaml と plugins/* は symlink (上書き不可ファイルは事前削除)
    # - .env は初回のみ template から copy。既存があれば tokens 保護のため触らない
    activation.setupHermes = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      DOTFILES_HERMES="${config.home.homeDirectory}/ghq/github.com/it-all-playpark/dotfiles/hermes"
      HERMES_DIR="${config.home.homeDirectory}/.hermes"

      if [ ! -d "$DOTFILES_HERMES" ]; then
        echo "Warning: $DOTFILES_HERMES does not exist. Skipping hermes setup."
        exit 0
      fi

      mkdir -p "$HERMES_DIR/plugins" "$HERMES_DIR/logs"

      # config.yaml — symlink (上書き不可ファイルは事前削除)
      if [ -f "$HERMES_DIR/config.yaml" ] && [ ! -L "$HERMES_DIR/config.yaml" ]; then
        rm "$HERMES_DIR/config.yaml"
      fi
      ln -sf "$DOTFILES_HERMES/config.yaml" "$HERMES_DIR/config.yaml"

      # hermes-wrapper.sh — symlink。~/.hermes/.env を load してから real hermes を exec する。
      # launchd agent と手動起動の双方で同じ env 注入経路を提供する。
      if [ -f "$HERMES_DIR/hermes-wrapper.sh" ] && [ ! -L "$HERMES_DIR/hermes-wrapper.sh" ]; then
        rm "$HERMES_DIR/hermes-wrapper.sh"
      fi
      ln -sf "$DOTFILES_HERMES/hermes-wrapper.sh" "$HERMES_DIR/hermes-wrapper.sh"

      # plugins — 各 plugin ディレクトリを symlink
      # NOTE: 末尾 / 付き plugin_dir + 既存 directory symlink に対する ln -sf は、
      # BSD ln (macOS) で symlink を dereference してその中に link を作る挙動を取り、
      # dotfiles/hermes/plugins/<name>/<name> という循環 symlink を量産する。
      # 末尾 / を剥がし、既存 symlink を rm -f で必ず消してから ln することで回避。
      for plugin_dir in "$DOTFILES_HERMES/plugins/"*/; do
        [ -d "$plugin_dir" ] || continue
        plugin_dir="''${plugin_dir%/}"
        plugin_name="$(basename "$plugin_dir")"
        if [ -e "$HERMES_DIR/plugins/$plugin_name" ] && [ ! -L "$HERMES_DIR/plugins/$plugin_name" ]; then
          rm -rf "$HERMES_DIR/plugins/$plugin_name"
        fi
        rm -f "$HERMES_DIR/plugins/$plugin_name"
        ln -sf "$plugin_dir" "$HERMES_DIR/plugins/$plugin_name"
      done

      # .env — 初回のみ copy。既存があれば触らない (tokens 保持のため)
      if [ ! -f "$HERMES_DIR/.env" ]; then
        cp "$DOTFILES_HERMES/.env.template" "$HERMES_DIR/.env"
        chmod 600 "$HERMES_DIR/.env"
        echo "hermes: created ~/.hermes/.env from template — fill in tokens before running"
      fi
    '';
  };

  # Ollama サーバーをログイン時に自動起動
  # macOS: launchd agent, Linux: systemd user service
  services.ollama = {
    enable = true;
  };

  # Syncthing をログイン時に自動起動
  # macOS: launchd agent, Linux: systemd user service
  # MacBook ↔ Mac Studio 間でスクショ等を双方向同期する。回線が切れても復帰時に差分を
  # 自動同期するため、トンネル区間を含む移動中でもファイル受け渡しが途切れない。
  # 初回のみ各マシンの Web UI (http://127.0.0.1:8384) でデバイス相互承認 + 共有フォルダ設定が必要。
  services.syncthing = {
    enable = true;
  };

  # hermes gateway をログイン時に自動起動 (macOS 限定)
  # Docker Desktop が未起動でも KeepAlive + ThrottleInterval で復旧するまで再試行。
  #
  # 同一 user account を複数 Mac で運用する場合の二重起動防止:
  # opt-in marker `~/.hermes/.gateway-primary` が存在する host でだけ実際に起動する。
  # marker 不在なら exit 0 で終了 (KeepAlive.SuccessfulExit=false なので restart しない)。
  # 切り替え時は旧機で `rm`、新機で `touch` + `launchctl kickstart -k gui/$(id -u)/com.playpark.hermes-gateway`。
  launchd.agents = lib.optionalAttrs pkgs.stdenv.isDarwin {
    hermes-gateway = {
      enable = true;
      config = {
        Label = "com.playpark.hermes-gateway";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''
            MARKER="${config.home.homeDirectory}/.hermes/.gateway-primary"
            if [ ! -f "$MARKER" ]; then
              echo "hermes-gateway: $MARKER not found on this host — skipping (opt-in via 'touch $MARKER')" >&2
              exit 0
            fi
            /bin/wait4path "${config.home.homeDirectory}/.local/bin/hermes" \
              && /bin/wait4path "${config.home.homeDirectory}/.hermes/hermes-wrapper.sh" \
              && exec "${config.home.homeDirectory}/.hermes/hermes-wrapper.sh" gateway
          ''
        ];
        EnvironmentVariables = {
          PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${config.home.homeDirectory}/.local/bin";
          HOME = config.home.homeDirectory;
        };
        WorkingDirectory = "${config.home.homeDirectory}/.hermes";
        RunAtLoad = true;
        KeepAlive = {
          Crashed = true;
          SuccessfulExit = false;
        };
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/.hermes/logs/gateway.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/.hermes/logs/gateway.err.log";
        ThrottleInterval = 30;
      };
    };

    # mise 管理ツールを毎日自動更新する。
    # minimum_release_age_excludes (mise/config.toml) と組で、claude-code 等の
    # 高頻度リリースツールへの即日追随を宣言的に実現する。
    # 04:30 (ローカルタイム) にスリープ中だった場合は launchd が復帰時にまとめて実行する。
    mise-upgrade = {
      enable = true;
      config = {
        Label = "com.playpark.mise-upgrade";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''
            /bin/wait4path "${pkgs.mise}/bin/mise" \
              && exec "${pkgs.mise}/bin/mise" upgrade --yes
          ''
        ];
        EnvironmentVariables = {
          # npm backend が node/npm を解決できるよう mise shims を先頭に置く
          PATH = "${config.home.homeDirectory}/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
          HOME = config.home.homeDirectory;
        };
        StartCalendarInterval = [
          {
            Hour = 4;
            Minute = 30;
          }
        ];
        RunAtLoad = false;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mise-upgrade.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mise-upgrade.log";
      };
    };
  };
}
