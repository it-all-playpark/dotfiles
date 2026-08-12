{
  pkgs,
  lib,
  config,
  username ? "naramotoyuuji",
  ...
}:
let
  packages = import ../../common/packages.nix { inherit pkgs; };
  # CLI tool 一覧は lib/cli-packages.nix に集約
  cliPackages = import ../../lib/cli-packages.nix {
    inherit pkgs;
    # 注: cliPackages には commonPackages と重複する coreutils/curl/git を含む。
    # Nix store の dedup によりインストール上の重複は発生しない (behavior-preserving)。
  };

  # 切断後も居座り続ける stale な mosh-server (起動から長時間経過 かつ CPU 使用時間が
  # ほぼゼロ = 接続が来ていない) を検出し通知するだけの watchdog。
  # 自動 kill は「本当に使われていないか」の誤判定リスクがあるため行わない。
  moshWatchdogScript = pkgs.writeShellApplication {
    name = "mosh-watchdog";
    runtimeInputs = [ pkgs.gawk ];
    text = ''
      # 1 時間以上起動していて累積 CPU 時間が 2 分未満のプロセスを stale 候補とみなす。
      ETIME_THRESHOLD_SECS=3600
      CPU_THRESHOLD_SECS=120

      /bin/ps -axo pid=,etime=,time=,command= \
        | awk -v etime_threshold="$ETIME_THRESHOLD_SECS" -v cpu_threshold="$CPU_THRESHOLD_SECS" '
          function to_sec(t,    days, rest, n, parts, dparts) {
            days = 0
            if (index(t, "-") > 0) {
              split(t, dparts, "-")
              days = dparts[1]
              rest = dparts[2]
            } else {
              rest = t
            }
            n = split(rest, parts, ":")
            if (n == 3) {
              return days * 86400 + parts[1] * 3600 + parts[2] * 60 + parts[3]
            }
            return days * 86400 + parts[1] * 60 + parts[2]
          }
          /mosh-server/ {
            etime_s = to_sec($2)
            cpu_s = to_sec($3)
            if (etime_s >= etime_threshold && cpu_s <= cpu_threshold) {
              printf "pid=%s etime=%s cpu=%s\n", $1, $2, $3
            }
          }
        ' \
        | while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            echo "$(date '+%Y-%m-%d %H:%M:%S') stale mosh-server candidate: $hit"
            /usr/bin/osascript -e "display notification \"$hit\" with title \"mosh watchdog: stale session?\"" || true
          done
    '';
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

    # 全シェル共通の環境変数。fish / zsh のいずれも home-manager が生成する
    # hm-session-vars を source するため (~/.config/fish/config.fish および
    # ~/.zshenv)、ここに 1 度書けば両方のシェルに届く。
    sessionVariables = {
      # gws (Google Workspace CLI) は既定で macOS Keychain (keyring backend) に
      # 資格情報を保存しようとするが、保存段階で
      #   Platform secure storage failure: User interaction is not allowed.
      # により失敗することがある。この失敗は OAuth 自体が成功した *後* に起きる
      # ため「login したのに資格情報が一度も更新されない」状態を作り、失効した
      # refresh_token を掴み続ける。2026-07-26 の hermes gws 障害
      # (container 内 gws が invalid_grant で全滅) の原因がこれで、Keychain の
      # 該当エントリは 2 か月以上更新されていなかった。
      # file backend を既定にして Keychain を経由させない。
      #
      # 注: GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE はここに追加しないこと。
      # credentials.enc より優先されるため、再 login しても古い認証情報を掴み
      # 続ける状態になる (hermes の container image でも同じ理由で設定していない)。
      GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file";
    };

    # 共通パッケージ + CLI tool 群 (host モード)
    # pkgs.flock (discoteq/flock, cross-platform flock(1)) — hermes/watchdog.sh
    # (S5) が多重run排除の flock -xn に使う。BSD/macOS には flock(1) が同梱され
    # ないため明示的に追加する (Linux util-linux 版と異なり file/fd# どちらの
    # ロック対象も -xn で扱える)。
    packages = packages.commonPackages ++ cliPackages ++ [ pkgs.flock ];

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
      # wrm / wrma / wrmn abbr (home-manager/programs/common.nix) の実体。
      # abbr は絶対パスで直接叩くため PATH には追加しない。
      ".local/bin/git-worktree-gc" = {
        source = ./file/bin/git-worktree-gc;
        executable = true;
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

    # Hermes-agent 設定を hermes リポジトリ (playpark-llc/hermes、独立repo) から
    # シンボリックリンクで参照
    # - config.yaml と plugins/* は symlink (上書き不可ファイルは事前削除)
    # - .env は初回のみ template から copy。既存があれば tokens 保護のため触らない
    activation.setupHermes = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      HERMES_REPO="${config.home.homeDirectory}/ghq/github.com/playpark-llc/hermes"
      HERMES_DIR="${config.home.homeDirectory}/.hermes"

      if [ ! -d "$HERMES_REPO" ]; then
        echo "Warning: $HERMES_REPO does not exist. Skipping hermes setup."
        exit 0
      fi

      mkdir -p "$HERMES_DIR/plugins" "$HERMES_DIR/logs"

      # claude_runner (S2) — per-job dispatch state dirs. workspaces/claude-state
      # are bind-mounted into the per-job container (see config.yaml
      # docker_volumes); jobs holds the host-side job manifests.
      mkdir -p "$HERMES_DIR/workspaces" "$HERMES_DIR/jobs" "$HERMES_DIR/claude-state"

      # config.yaml — symlink (上書き不可ファイルは事前削除)
      if [ -f "$HERMES_DIR/config.yaml" ] && [ ! -L "$HERMES_DIR/config.yaml" ]; then
        rm "$HERMES_DIR/config.yaml"
      fi
      ln -sf "$HERMES_REPO/config.yaml" "$HERMES_DIR/config.yaml"

      # repo_bindings.yaml — symlink (上書き不可ファイルは事前削除)
      if [ -f "$HERMES_DIR/repo_bindings.yaml" ] && [ ! -L "$HERMES_DIR/repo_bindings.yaml" ]; then
        rm "$HERMES_DIR/repo_bindings.yaml"
      fi
      ln -sf "$HERMES_REPO/repo_bindings.yaml" "$HERMES_DIR/repo_bindings.yaml"

      # hermes-wrapper.sh — 廃止。hermes 本体 (hermes_cli/env_loader.py) が
      # ~/.hermes/.env を override=True で load するため、wrapper による
      # `set -a; . .env` は二重かつ dotenv とパース結果が食い違う (値の空白・#・
      # クォートの扱い)。過去に張った symlink が残っていれば消す。
      rm -f "$HERMES_DIR/hermes-wrapper.sh"

      # watchdog.sh (S5) — symlink。~/.hermes/jobs/*.json を定期 reconcile する
      # launchd agent (com.playpark.hermes-watchdog) から起動される。
      if [ -f "$HERMES_DIR/watchdog.sh" ] && [ ! -L "$HERMES_DIR/watchdog.sh" ]; then
        rm "$HERMES_DIR/watchdog.sh"
      fi
      ln -sf "$HERMES_REPO/watchdog.sh" "$HERMES_DIR/watchdog.sh"

      # plugins — 各 plugin ディレクトリを symlink
      # NOTE: 末尾 / 付き plugin_dir + 既存 directory symlink に対する ln -sf は、
      # BSD ln (macOS) で symlink を dereference してその中に link を作る挙動を取り、
      # hermes/plugins/<name>/<name> という循環 symlink を量産する。
      # 末尾 / を剥がし、既存 symlink を rm -f で必ず消してから ln することで回避。
      for plugin_dir in "$HERMES_REPO/plugins/"*/; do
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
        cp "$HERMES_REPO/.env.template" "$HERMES_DIR/.env"
        chmod 600 "$HERMES_DIR/.env"
        echo "hermes: created ~/.hermes/.env from template — fill in tokens before running"
      fi

      # gateway service — hermes 標準の `hermes gateway install` に一本化する。
      # 標準側 (hermes_cli/gateway.py) が ai.hermes.gateway.plist を生成し、
      # PATH 合成・KeepAlive・ThrottleInterval・plist の陳腐化検知と自動更新
      # (launchd_plist_is_current / refresh_launchd_plist_if_needed) を持つため、
      # こちらで plist を書く必要がない。install は --force なしでも冪等で、
      # 既存 plist が古ければ自動で書き直す。
      #
      # macOS 側の分岐 (`elif is_macos(): launchd_install(force)`) は force しか
      # 見ない。`--start-on-login` / `--no-start-now` は systemd (Linux) /
      # gateway_windows 専用の実装で、macOS では無視される — このリポジトリは
      # macOS 専用なので付けても意味がなく、渡さない。
      # install (force なし) の実際の挙動:
      #   - plist 未設置 (初回 install): 新規生成して bootstrap。生成される plist は
      #     RunAtLoad=true なので、フラグの有無に関わらずここで即起動する。
      #   - plist が現行生成物と一致: 「既にインストール済み」で早期 return し、
      #     bootout/bootstrap は起きない (稼働中セッションは落ちない)。
      #   - plist が陳腐化: refresh_launchd_plist_if_needed() が書き直した上で
      #     bootout → bootstrap するため、稼働中の gateway はここで再起動される。
      # つまり「稼働中セッションを毎回落とさない」のは launchd_install 自身の
      # 早期 return によるもので、フラグでは制御できない。
      #
      # 二重起動防止の opt-in marker (~/.hermes/.gateway-primary) は標準側に
      # 無い概念なので、marker の有無で install / uninstall を出し分けて
      # 従来と同じ「primary 機でだけ起動する」意味を保つ。
      LEGACY_LABEL="com.playpark.hermes-gateway"
      LEGACY_PLIST="${config.home.homeDirectory}/Library/LaunchAgents/$LEGACY_LABEL.plist"

      # 旧 plist の残骸を確実に停止・削除する。launchd.agents から定義を消せば
      # home-manager が plist を消すが、load 済み job が残ると新旧 2 つの gateway が
      # 同じ App Token で multi-connect し二重応答になるため、明示的に bootout する。
      if [ -f "$LEGACY_PLIST" ] || launchctl print "gui/$(id -u)/$LEGACY_LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
        rm -f "$LEGACY_PLIST"
        echo "hermes: removed legacy launchd agent $LEGACY_LABEL"
      fi

      HERMES_BIN="${config.home.homeDirectory}/.local/bin/hermes"
      if [ ! -x "$HERMES_BIN" ]; then
        echo "hermes: $HERMES_BIN not found — skipping gateway service setup"
      elif [ -f "$HERMES_DIR/.gateway-primary" ]; then
        # 標準 plist は install 時点の PATH を焼き込むため、docker/node が
        # 解決できる PATH を明示してから install する (activation の PATH は
        # nix profile 中心で /opt/homebrew 等を含まないことがある)。
        # macOS では install に渡せる意味のあるフラグは --force のみなので
        # 付けない (上のコメント参照)。
        PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" \
          "$HERMES_BIN" gateway install
        # plist 未設置/陳腐化なら install が bootstrap まで済ませているので、
        # ここは主に「plist は既にあるが launchd job が unload されている」場合の
        # 保険 (gateway start は自己修復して bootstrap し直す)。稼働中セッションを
        # 毎回落とさないのは install の早期 return によるもので、start 自体は
        # 既に動いていれば何もしない (config.yaml 変更の反映は
        # `hermes gateway restart` を明示的に実行する)。
        "$HERMES_BIN" gateway start >/dev/null 2>&1 || true
      else
        echo "hermes: ~/.hermes/.gateway-primary not found on this host — gateway service not installed (opt-in via 'touch ~/.hermes/.gateway-primary')"
        "$HERMES_BIN" gateway uninstall >/dev/null 2>&1 || true
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

  # hermes gateway の launchd agent はここでは定義しない。
  # hermes 標準の `hermes gateway install` が生成する ai.hermes.gateway に一本化し、
  # 呼び出しは activation.setupHermes が担う (marker の有無で install/uninstall)。
  # 標準 plist は PATH 合成・KeepAlive・ThrottleInterval・陳腐化検知を自前で持つ。
  launchd.agents = lib.optionalAttrs pkgs.stdenv.isDarwin {
    # hermes watchdog (S5, AC-4/AC-5) — ~/.hermes/jobs/*.json を定期 reconcile し、
    # 完了ジョブを Slack 通知 (notified dedup 付き) した上で workspace clone +
    # manifest を cleanup する。StartInterval で周期起動 (launchd は毎回新プロセス
    # を起動するため、多重起動排除は watchdog.sh 冒頭の flock -xn が担う)。
    #
    # hermes-gateway と同じ opt-in marker `~/.hermes/.gateway-primary` を再利用する
    # (同一アカウントを複数 Mac で運用する場合の二重 reconcile/二重通知防止)。
    hermes-watchdog = {
      enable = true;
      config = {
        Label = "com.playpark.hermes-watchdog";
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''
            MARKER="${config.home.homeDirectory}/.hermes/.gateway-primary"
            if [ ! -f "$MARKER" ]; then
              echo "hermes-watchdog: $MARKER not found on this host — skipping (opt-in via 'touch $MARKER')" >&2
              exit 0
            fi
            /bin/wait4path "${config.home.homeDirectory}/.hermes/watchdog.sh" \
              && exec "${config.home.homeDirectory}/.hermes/watchdog.sh"
          ''
        ];
        EnvironmentVariables = {
          PATH = "${config.home.homeDirectory}/.local/share/mise/shims:${config.home.homeDirectory}/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${config.home.homeDirectory}/.local/bin";
          HOME = config.home.homeDirectory;
        };
        WorkingDirectory = "${config.home.homeDirectory}/.hermes";
        RunAtLoad = true;
        StartInterval = 120;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/.hermes/logs/watchdog.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/.hermes/logs/watchdog.err.log";
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

    # 30 分おきに stale な mosh-server プロセスを検出し macOS 通知するだけの watchdog。
    # 自動 kill はしない（誤検知時に稼働中セッションを壊すリスクがあるため）。
    mosh-watchdog = {
      enable = true;
      config = {
        Label = "com.playpark.mosh-watchdog";
        ProgramArguments = [ "${moshWatchdogScript}/bin/mosh-watchdog" ];
        EnvironmentVariables = {
          PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
        };
        StartInterval = 1800;
        RunAtLoad = false;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mosh-watchdog.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mosh-watchdog.log";
      };
    };
  };
}
