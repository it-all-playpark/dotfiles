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

      # システムがDarwinかどうかを判定する関数
      isDarwin = system: builtins.match ".*-darwin" system != null;

      # 現在のシステム（実行環境）を取得
      currentSystem = builtins.currentSystem;
    in
    {
      # 各システム向けのホームマネージャー構成を出力
      homeConfigurations =
        let
          # ユーザー名を引数として受け取る関数を定義
          mkHomeConfig = username: {
            # macOS用の構成
            "${username}-darwin" = home-manager.lib.homeManagerConfiguration {
              pkgs = nixpkgsFor."aarch64-darwin";
              modules = [
                ./home-manager/default.nix
                { _module.args.username = username; }
              ];
            };

            # x86_64 Linux用の構成（WSLも含む）
            "${username}-linux-x86" = home-manager.lib.homeManagerConfiguration {
              pkgs = nixpkgsFor."x86_64-linux";
              modules = [
                ./home-manager/default.nix
                { _module.args.username = username; }
              ];
            };

            # ARM Linux用の構成
            "${username}-linux-arm" = home-manager.lib.homeManagerConfiguration {
              pkgs = nixpkgsFor."aarch64-linux";
              modules = [
                ./home-manager/default.nix
                { _module.args.username = username; }
              ];
            };
          };
        in
        # デフォルトのユーザー設定を含める
        mkHomeConfig "naramotoyuuji";

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
      });
    };
}
