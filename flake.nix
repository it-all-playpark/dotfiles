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
  };

  outputs =
    { nixpkgs
    , home-manager
    , nix-darwin
    , ...
    }:
    let
      # サポートするシステムのリスト
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      # 各システム向けの関数を生成するヘルパー関数
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # 各システム用のnixpkgsインスタンスを生成
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
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

          # サポートするユーザーのリスト
          usernames = [
            "naramotoyuuji"
            "yuji_naramoto"
            # 他のユーザー名を追加できます
          ];

          # 複数ユーザーの設定をマージ
          mergeConfigs = configs: username:
            configs // (mkHomeConfig username);
        in
        # すべてのユーザー設定をマージして含める
        nixpkgs.lib.foldl mergeConfigs { } usernames;

      # Darwinの構成を出力に追加（macOSのみ）
      darwinConfigurations."MyMBP" = nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin"; # Apple Silicon MacBook用
        modules = [ ./darwin/default.nix ];
      };

      # 一括アップデート用のスクリプトを定義（各システム向け）
      apps = forAllSystems (system: {
        update = {
          type = "app";
          program = toString (nixpkgsFor.${system}.writeShellScript "update-script" ''
            set -e
            # デフォルトユーザー名を設定
            USERNAME=''${1:-naramotoyuuji}
            
            echo "Updating flake for user: $USERNAME..."
            nix flake update
            
            # システムタイプに基づいて適切な設定を使用
            if [[ "$(uname)" == "Darwin" ]]; then
              # macOS系の場合
              echo "Detected macOS environment"
              echo "Updating home-manager..."
              nix run home-manager -- switch --flake .#''${USERNAME}-darwin
              
              echo "Updating nix-darwin..."
              nix run nix-darwin -- switch --flake .#MyMBP
            else
              # Linux系の場合（WSLを含む）
              echo "Detected Linux environment"
              echo "Updating home-manager..."
              
              # アーキテクチャを検出
              ARCH=$(uname -m)
              if [[ "$ARCH" == "x86_64" ]]; then
                nix run home-manager -- switch --flake .#''${USERNAME}-linux-x86
              elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
                nix run home-manager -- switch --flake .#''${USERNAME}-linux-arm
              else
                echo "Unsupported architecture: $ARCH"
                exit 1
              fi
            fi
            
            echo "Update complete!"
          '');
        };

        # すべてのユーザーを更新するスクリプト
        "update-all" = {
          type = "app";
          program = toString (nixpkgsFor.${system}.writeShellScript "update-all-script" ''
            set -e
            # すべてのユーザー名を配列で定義
            USERNAMES=("naramotoyuuji" "yuji_naramoto")
            
            echo "Updating flake for all users..."
            nix flake update
            
            # システムタイプに基づいて処理
            if [[ "$(uname)" == "Darwin" ]]; then
              # macOS系の場合、nix-darwinを一度だけ更新
              echo "Detected macOS environment"
              echo "Updating nix-darwin..."
              nix run nix-darwin -- switch --flake .#MyMBP
              
              # 各ユーザーのhome-manager設定を更新
              for USERNAME in "''${USERNAMES[@]}"; do
                echo "Updating home-manager for user: $USERNAME..."
                nix run home-manager -- switch --flake .#''${USERNAME}-darwin
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
                nix run home-manager -- switch --flake .#''${USERNAME}-$SUFFIX
              done
            fi
            
            echo "All updates complete!"
          '');
        };
      });
    };
}
