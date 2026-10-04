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
      # x86_64-darwin (Intel Mac) は使用予定がなく、nixpkgs unstable (26.11) が
      # サポートを打ち切ったため対象外。
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # 各システム向けの関数を生成するヘルパー関数
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # 各システム用のnixpkgsインスタンスを生成
      # claude-code は mise で管理（home-manager/home/file/mise/config.toml）
      nixpkgsFor = forAllSystems (
        system:
        import nixpkgs {
          inherit system;
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

      # 一括アップデート用のスクリプトを定義（各システム向け）
      apps = forAllSystems (system: {
        update = {
          type = "app";
          program = toString (
            nixpkgsFor.${system}.writeShellScript "update-script" ''
              set -e
              # commit / push 前の検査（.githooks）を有効にする
              bash scripts/install-git-hooks.sh || echo "WARNING: git hooks を設置できなかった"
              # 引数: [username] [--full]
              # --full を付けたときだけ switch 後に Homebrew のパッケージも更新する
              FULL=0
              USERNAME=naramotoyuuji
              for arg in "$@"; do
                case "$arg" in
                  --full) FULL=1 ;;
                  -*) echo "Unknown option: $arg"; exit 1 ;;
                  *) USERNAME="$arg" ;;
                esac
              done
              BACKUP_EXT="backup-$(date +%Y%m%d%H%M%S)"

              echo "Updating flake for user: $USERNAME..."
              LOCK_BACKUP=$(mktemp)
              cp flake.lock "$LOCK_BACKUP"
              nix flake update

              # 更新後の入力でビルド検証し、失敗したら flake.lock をロールバックする。
              # nixos-unstable は darwin 全パッケージのビルド成功を保証しないため、
              # 壊れた rev を踏んだ場合は既知の正常な入力のまま switch を続行する。
              verify_or_rollback() {
                echo "Verifying build with updated inputs..."
                if nix build --no-link "$@"; then
                  rm -f "$LOCK_BACKUP"
                else
                  echo "WARNING: updated inputs failed to build. Rolling back flake.lock to the previous (working) revision..."
                  mv "$LOCK_BACKUP" flake.lock
                fi
              }

              # nix-darwin の switch では brew update / upgrade をしない (darwin/homebrew.nix)。
              # 更新は --full 指定時のここか、launchd の brew-upgrade (毎日 04:00) で行う
              brew_full_upgrade() {
                echo "Upgrading Homebrew packages..."
                brew update
                brew upgrade
              }

              # システムタイプに基づいて適切な設定を使用
              if [[ "$(uname)" == "Darwin" ]]; then
                # macOS系の場合
                echo "Detected macOS environment"
                verify_or_rollback \
                  ".#homeConfigurations.''${USERNAME}-darwin.activationPackage" \
                  ".#darwinConfigurations.MyMBP-''${USERNAME}.system"

                echo "Updating home-manager..."
                nix run home-manager -- -b "$BACKUP_EXT" --flake .#''${USERNAME}-darwin switch

                echo "Updating nix-darwin..."
                sudo nix --extra-experimental-features 'nix-command flakes' run nix-darwin -- switch --flake .#MyMBP-''${USERNAME}

                if [[ "$FULL" == 1 ]]; then
                  brew_full_upgrade
                fi
              else
                # Linux系の場合（WSLを含む）
                echo "Detected Linux environment"

                # アーキテクチャを検出
                ARCH=$(uname -m)
                if [[ "$ARCH" == "x86_64" ]]; then
                  SUFFIX="linux-x86"
                elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
                  SUFFIX="linux-arm"
                else
                  echo "Unsupported architecture: $ARCH"
                  exit 1
                fi

                verify_or_rollback ".#homeConfigurations.''${USERNAME}-$SUFFIX.activationPackage"

                echo "Updating home-manager..."
                nix run home-manager -- -b "$BACKUP_EXT" --flake .#''${USERNAME}-$SUFFIX switch
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
              # commit / push 前の検査（.githooks）を有効にする
              bash scripts/install-git-hooks.sh || echo "WARNING: git hooks を設置できなかった"
              # 引数: [--full]  (switch 後に Homebrew のパッケージも更新する)
              FULL=0
              for arg in "$@"; do
                case "$arg" in
                  --full) FULL=1 ;;
                  *) echo "Unknown option: $arg"; exit 1 ;;
                esac
              done
              # すべてのユーザー名を配列で定義
              USERNAMES=("naramotoyuuji" "yuji_naramoto")
              BACKUP_EXT="backup-$(date +%Y%m%d%H%M%S)"

              echo "Updating flake for all users..."
              LOCK_BACKUP=$(mktemp)
              cp flake.lock "$LOCK_BACKUP"
              nix flake update

              # 更新後の入力でビルド検証し、失敗したら flake.lock をロールバックする。
              # nixos-unstable は darwin 全パッケージのビルド成功を保証しないため、
              # 壊れた rev を踏んだ場合は既知の正常な入力のまま switch を続行する。
              verify_or_rollback() {
                echo "Verifying build with updated inputs..."
                if nix build --no-link "$@"; then
                  rm -f "$LOCK_BACKUP"
                else
                  echo "WARNING: updated inputs failed to build. Rolling back flake.lock to the previous (working) revision..."
                  mv "$LOCK_BACKUP" flake.lock
                fi
              }

              # nix-darwin の switch では brew update / upgrade をしない (darwin/homebrew.nix)。
              # 更新は --full 指定時のここか、launchd の brew-upgrade (毎日 04:00) で行う
              brew_full_upgrade() {
                echo "Upgrading Homebrew packages..."
                brew update
                brew upgrade
              }

              # システムタイプに基づいて処理
              if [[ "$(uname)" == "Darwin" ]]; then
                # macOS系の場合
                echo "Detected macOS environment"

                # 全ユーザー分のビルドをまとめて検証
                VERIFY_TARGETS=()
                for USERNAME in "''${USERNAMES[@]}"; do
                  VERIFY_TARGETS+=(".#homeConfigurations.''${USERNAME}-darwin.activationPackage")
                  VERIFY_TARGETS+=(".#darwinConfigurations.MyMBP-''${USERNAME}.system")
                done
                verify_or_rollback "''${VERIFY_TARGETS[@]}"

                # 各ユーザーのhome-managerとnix-darwin設定を更新
                for USERNAME in "''${USERNAMES[@]}"; do
                  echo "Updating home-manager for user: $USERNAME..."
                  nix run home-manager -- -b "$BACKUP_EXT" --flake .#''${USERNAME}-darwin switch
                  echo "Updating nix-darwin for user: $USERNAME..."
                  sudo nix --extra-experimental-features 'nix-command flakes' run nix-darwin -- switch --flake .#MyMBP-''${USERNAME}
                done

                if [[ "$FULL" == 1 ]]; then
                  brew_full_upgrade
                fi
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

                # 全ユーザー分のビルドをまとめて検証
                VERIFY_TARGETS=()
                for USERNAME in "''${USERNAMES[@]}"; do
                  VERIFY_TARGETS+=(".#homeConfigurations.''${USERNAME}-$SUFFIX.activationPackage")
                done
                verify_or_rollback "''${VERIFY_TARGETS[@]}"

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

      # 開発シェル（リンター・テスト依存 + .githooks の有効化）
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
              # tests/run-all.sh の依存（CI も pre-push もこの shell で走らせる）
              pkgs.bash
              pkgs.bats
              pkgs.git
              pkgs.jq
              pkgs.python3
              pkgs.yq-go
            ];
            # hook の本体は追跡している .githooks/（pre-commit: 整形 + shellcheck、pre-push: CI と同じ検査）。
            # Claude の sandbox からは .git/hooks に書けないので、Claude のセッションでは設置しない
            shellHook = ''
              if [ -z "''${CLAUDECODE:-}" ] && [ -f scripts/install-git-hooks.sh ]; then
                bash scripts/install-git-hooks.sh
              fi
            '';
          };
        }
      );
    };
}
