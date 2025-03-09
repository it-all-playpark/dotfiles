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
      # 使用するシステムのアーキテクチャを指定
      system = "aarch64-darwin";
      # 指定したシステムで nixpkgs をインポート
      pkgs = import nixpkgs { inherit system; };
      # home.nix をモジュールとして読み込み、Home Manager の設定を定義
      homeConfig = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home.nix ];
      };
      # darwin.nix をモジュールとして読み込み、Nix-Darwin の設定を定義
      darwinConfig = nix-darwin.lib.darwinSystem {
        system = system;
        modules = [ ./darwin.nix ];
      };
    in
    {
      # ユーザー naramotoyuuji の Home Manager 設定を適用
      homeConfigurations.naramotoyuuji = homeConfig;
      # MyMBP の Nix-Darwin 設定を適用
      darwinConfigurations.MyMBP = darwinConfig;
    };
}
