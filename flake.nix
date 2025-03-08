{
  description = "Nix Darwin + Home Manager configuration";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin"; # nix-darwinのソース
    home-manager.url = "github:nix-community/home-manager/release-25.05"; # Home Managerのソース
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs"; # nixpkgsに従う
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }:
    {
      darwinConfigurations = {
        MyMBP = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin"; # Apple Siliconの場合
          modules = [
            home-manager.darwinModules.home-manager # Home Managerを組み込む
            ./darwin.nix # システム用設定（別ファイルにしてもOK）
            {
              # 以下、インラインでモジュール記述も可能
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.naramotoyuuji = import ./home.nix;
            }
          ];
        };
      };
    };
}
