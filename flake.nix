{
  # このファイルは、Home Manager の設定を定義します。
  description = "Home Manager configuration only";

  inputs = {
    # NixOS の不安定版チャンネルを使用
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Home Manager のリポジトリを指定し、nixpkgs を追従
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Nix-Darwin のリポジトリを指定し、nixpkgs を追従
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # treefmt-nix - フォーマッター統合（nix fmt）
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nix-darwin,
      treefmt-nix,
      ...
    }:
    let
      # サポートするシステムのリスト
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # 各システム向けの関数を生成するヘルパー関数
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # 各システム用のnixpkgsインスタンスを生成
      # claude-code は mise で管理（home-manager/home/file/mise/config.toml）
      # ただし hermes-image (container) では pkgs.claude-code を同梱するため、
      # nixpkgs 上で unfree license の claude-code を allowUnfreePredicate で許可する。
      nixpkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          config = {
            # 全体 allowUnfree を開かず、対象 package のみ name で絞って許可。
            allowUnfreePredicate =
              pkg:
              builtins.elem (nixpkgs.lib.getName pkg) [
                "claude-code"
              ];
          };
          overlays = [
            # direnv の checkPhase は macOS Nix サンドボックス内でハングするため無効化
            (_final: prev: {
              direnv = prev.direnv.overrideAttrs (_: {
                doCheck = false;
              });
            })
            # mise の checkPhase は Nix サンドボックスが setuid bit 付与を許可しないため
            # oci::layer::tests::preserve_metadata_dir_layer_keeps_special_permission_bits が失敗する。
            # nixpkgs 側でこのテストが skip されたら削除可。
            (_final: prev: {
              mise = prev.mise.overrideAttrs (_: {
                doCheck = false;
              });
            })
            # ollama 0.30.5 は macOS arm64 で MLX backend がデフォルト有効になり、
            # Nix サンドボックスに存在しない Xcode の Metal toolchain を要求してビルドに失敗する。
            # nixpkgs master (0.30.6) と同じく -DOLLAMA_MLX_BACKENDS="" で無効化する。
            # nixpkgs 更新で 0.30.6 以降が入ったら削除可。
            (_final: prev: {
              ollama = prev.ollama.overrideAttrs (old: {
                preBuild =
                  builtins.replaceStrings [ "cmake -B build" ] [ "cmake -B build -DOLLAMA_MLX_BACKENDS=\"\"" ]
                    old.preBuild;
              });
            })
          ];
        }
      );

      # サポートするユーザーのリスト
      usernames = [
        "naramotoyuuji"
        "yuji_naramoto"
        # 他のユーザー名を追加できます
      ];
    in
    {
      # 各システム向けのホームマネージャー構成を出力
      homeConfigurations =
        let
          # ユーザー名を引数として受け取る関数を定義
          # 共通モジュールを定義
          commonModules = username: [
            ./home-manager/default.nix
            { _module.args.username = username; }
          ];

          # システムごとの設定を生成する関数
          mkHomeConfig = username: {
            # macOS用の構成
            "${username}-darwin" = home-manager.lib.homeManagerConfiguration {
              pkgs = nixpkgsFor."aarch64-darwin";
              modules = commonModules username;
            };

            # x86_64 Linux用の構成（WSLも含む）
            "${username}-linux-x86" = home-manager.lib.homeManagerConfiguration {
              pkgs = nixpkgsFor."x86_64-linux";
              modules = commonModules username;
            };

            # ARM Linux用の構成
            "${username}-linux-arm" = home-manager.lib.homeManagerConfiguration {
              pkgs = nixpkgsFor."aarch64-linux";
              modules = commonModules username;
            };
          };

          # 複数ユーザーの設定をマージ
          mergeConfigs = configs: username: configs // (mkHomeConfig username);
        in
        # すべてのユーザー設定をマージして含める
        nixpkgs.lib.foldl mergeConfigs { } usernames;

      # Darwinの構成を出力に追加（macOSのみ）
      # ユーザーごとにdarwin構成を生成
      darwinConfigurations = nixpkgs.lib.foldl (
        configs: username:
        configs
        // {
          "MyMBP-${username}" = nix-darwin.lib.darwinSystem {
            system = "aarch64-darwin"; # Apple Silicon MacBook用
            modules = [
              ./darwin/default.nix
              { _module.args.username = username; }
            ];
          };
        }
      ) { } usernames;

      # hermes-agent 用 Docker image を含む packages 出力（各システム向け）
      # linux-* システムのみ hermes-image を生成（dockerTools は Linux 専用）。
      # darwin 上では nix.linux-builder 経由で aarch64-linux 用 image を build できる。
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          cliPackages = import ./lib/cli-packages.nix {
            inherit pkgs;
            mode = "container";
          };
          # @anthropic-ai/claude-code derivation
          # 案A: pkgs.claude-code (nixpkgs に存在する場合、推奨)
          # 案B: pkgs.buildNpmPackage fallback (lib/hermes-claude-code-pkg.nix 内で定義)
          # 案C (禁止): extraCommands 内 npm install -g は hermetic ではないため不可
          claudeCodePkg = import ./lib/hermes-claude-code-pkg.nix { inherit pkgs; };
        in
        nixpkgs.lib.optionalAttrs (nixpkgs.lib.hasSuffix "-linux" system) {
          hermes-image = pkgs.dockerTools.buildLayeredImage {
            name = "hermes-tools";
            tag = "latest";
            contents =
              cliPackages
              ++ [ claudeCodePkg ]
              ++ (with pkgs; [
                bashInteractive
                cacert
                dockerTools.fakeNss
                findutils
                gawk
                gnugrep
                gnused
                gnutar
                gzip
                iana-etc
                less
                shadow
              ]);
            # claude が起動時に ~/.claude/ への書き込みを試みる場合に備え、
            # /root を作成して writable にする。
            # fakeNss は /etc/passwd の root entry のみ作るため /root 自体は別途保証が必要。
            extraCommands = ''
              mkdir -p root
              chmod 700 root
            '';
            config = {
              Cmd = [ "${pkgs.bashInteractive}/bin/bash" ];
              WorkingDir = "/workspace";
              Env = [
                "PATH=/bin:/usr/bin"
                "LANG=C.UTF-8"
                "LC_ALL=C.UTF-8"
                "HOME=/root"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                # gws は default で keyring (macOS Keychain) を使うため container では復号不可。
                # gws auth export で生成した token.json を file backend 経由で読む。
                "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file"
                "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/root/.config/gws/token.json"
              ];
            };
          };
        }
      );

      # 一括アップデート用のスクリプトを定義（各システム向け）
      apps = forAllSystems (system: {
        update = {
          type = "app";
          program = toString (
            nixpkgsFor.${system}.writeShellScript "update-script" ''
              set -e
              # デフォルトユーザー名を設定
              USERNAME=''${1:-naramotoyuuji}
              BACKUP_EXT="backup-$(date +%Y%m%d%H%M%S)"

              echo "Updating flake for user: $USERNAME..."
              nix flake update

              # システムタイプに基づいて適切な設定を使用
              if [[ "$(uname)" == "Darwin" ]]; then
                # macOS系の場合
                echo "Detected macOS environment"
                echo "Updating home-manager..."
                nix run home-manager -- -b "$BACKUP_EXT" --flake .#''${USERNAME}-darwin switch

                echo "Updating nix-darwin..."
                sudo nix --extra-experimental-features 'nix-command flakes' run nix-darwin -- switch --flake .#MyMBP-''${USERNAME}
              else
                # Linux系の場合（WSLを含む）
                echo "Detected Linux environment"
                echo "Updating home-manager..."

                # アーキテクチャを検出
                ARCH=$(uname -m)
                if [[ "$ARCH" == "x86_64" ]]; then
                  nix run home-manager -- -b "$BACKUP_EXT" --flake .#''${USERNAME}-linux-x86 switch
                elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
                  nix run home-manager -- -b "$BACKUP_EXT" --flake .#''${USERNAME}-linux-arm switch
                else
                  echo "Unsupported architecture: $ARCH"
                  exit 1
                fi
              fi

              echo "Update complete!"
            ''
          );
        };

        # すべてのユーザーを更新するスクリプト
        "update-all" = {
          type = "app";
          program = toString (
            nixpkgsFor.${system}.writeShellScript "update-all-script" ''
              set -e
              # すべてのユーザー名を配列で定義
              USERNAMES=("naramotoyuuji" "yuji_naramoto")
              BACKUP_EXT="backup-$(date +%Y%m%d%H%M%S)"

              echo "Updating flake for all users..."
              nix flake update

              # システムタイプに基づいて処理
              if [[ "$(uname)" == "Darwin" ]]; then
                # macOS系の場合
                echo "Detected macOS environment"

                # 各ユーザーのhome-managerとnix-darwin設定を更新
                for USERNAME in "''${USERNAMES[@]}"; do
                  echo "Updating home-manager for user: $USERNAME..."
                  nix run home-manager -- -b "$BACKUP_EXT" --flake .#''${USERNAME}-darwin switch
                  echo "Updating nix-darwin for user: $USERNAME..."
                  sudo nix --extra-experimental-features 'nix-command flakes' run nix-darwin -- switch --flake .#MyMBP-''${USERNAME}
                done
              else
                # Linux系の場合
                echo "Detected Linux environment"

                # アーキテクチャを検出
                ARCH=$(uname -m)
                SUFFIX=""

                if [[ "$ARCH" == "x86_64" ]]; then
                  SUFFIX="linux-x86"
                elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
                  SUFFIX="linux-arm"
                else
                  echo "Unsupported architecture: $ARCH"
                  exit 1
                fi

                # 各ユーザーのhome-manager設定を更新
                for USERNAME in "''${USERNAMES[@]}"; do
                  echo "Updating home-manager for user: $USERNAME..."
                  nix run home-manager -- -b "$BACKUP_EXT" --flake .#''${USERNAME}-$SUFFIX switch
                done
              fi

              echo "All updates complete!"
            ''
          );
        };

        # hermes-agent 用 Docker image を build して docker load まで一括実行
        # darwin host では nix.linux-builder 経由で aarch64-linux 用 image を build する
        "hermes-image-load" = {
          type = "app";
          program = toString (
            nixpkgsFor.${system}.writeShellScript "hermes-image-load" ''
              set -e

              # build 対象システムを決定
              # - darwin host: aarch64-linux (linux-builder 経由)
              # - linux host: 現在のシステム
              if [[ "$(uname)" == "Darwin" ]]; then
                TARGET_SYSTEM="aarch64-linux"
              else
                ARCH=$(uname -m)
                if [[ "$ARCH" == "x86_64" ]]; then
                  TARGET_SYSTEM="x86_64-linux"
                elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
                  TARGET_SYSTEM="aarch64-linux"
                else
                  echo "Unsupported architecture: $ARCH"
                  exit 1
                fi
              fi

              echo "Building hermes-image for $TARGET_SYSTEM..."
              IMAGE_PATH=$(nix build --no-link --print-out-paths ".#packages.''${TARGET_SYSTEM}.hermes-image")

              echo "Loading $IMAGE_PATH into docker..."
              docker load < "$IMAGE_PATH"

              echo "Done. Image available as: hermes-tools:latest"
              echo ""
              echo "Test with:"
              echo "  docker run --rm hermes-tools:latest /bin/bash -c \"gh --version && git --version && vips --version\""
            ''
          );
        };
      });

      # フォーマッター（nix fmt で実行）
      formatter = forAllSystems (
        system:
        let
          treefmtEval = treefmt-nix.lib.evalModule nixpkgsFor.${system} ./treefmt.nix;
        in
        treefmtEval.config.build.wrapper
      );

      # フォーマットチェック（nix flake check で実行）
      checks = forAllSystems (
        system:
        let
          treefmtEval = treefmt-nix.lib.evalModule nixpkgsFor.${system} ./treefmt.nix;
        in
        {
          formatting = treefmtEval.config.build.check self;
        }
      );

      # 開発シェル（リンター等の追加ツール + pre-commit hook 自動設置）
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          treefmtEval = treefmt-nix.lib.evalModule nixpkgsFor.${system} ./treefmt.nix;
          treefmtWrapper = treefmtEval.config.build.wrapper;
        in
        {
          default = pkgs.mkShell {
            packages = [
              treefmtWrapper
              pkgs.shellcheck
            ];
            shellHook = ''
                            if [ -d .git ]; then
                              mkdir -p .git/hooks
                              cat > .git/hooks/pre-commit << 'HOOK'
              #!/usr/bin/env bash
              set -euo pipefail

              # Get staged files
              STAGED=$(git diff --cached --name-only --diff-filter=ACM)
              [ -z "$STAGED" ] && exit 0

              # Format staged files with treefmt (skip if not in devShell)
              if command -v treefmt &>/dev/null; then
                echo "$STAGED" | xargs treefmt
                echo "$STAGED" | xargs git add
              else
                echo "pre-commit: treefmt not found, skipping format (run 'nix develop' first)"
              fi

              # Lint: shellcheck
              SH_FILES=$(echo "$STAGED" | grep '\.sh$' || true)
              if [ -n "$SH_FILES" ] && command -v shellcheck &>/dev/null; then
                echo "$SH_FILES" | xargs shellcheck
              fi
              HOOK
                              chmod +x .git/hooks/pre-commit
                            fi
            '';
          };
        }
      );
    };
}
