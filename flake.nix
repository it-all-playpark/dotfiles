{
  description = "Nix Darwin + Home Manager configuration";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    home-manager.url = "github:nix-community/home-manager";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }:
    {
      darwinConfigurations = {
        MyMBP = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin"; # Apple Siliconの場合
          modules = [
            home-manager.darwinModules.home-manager
            ./darwin.nix
            {
              # Home Manager の基本設定
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.naramotoyuuji = import ./home.nix;
            }
            # 最後に強制的に home.homeDirectory を上書き
            { config, lib, ... }: {
              config.home.homeDirectory = "/Users/naramotoyuuji";
            }
          ];
        };
      };
    };
}
