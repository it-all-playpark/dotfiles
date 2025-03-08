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
    let
      system = "aarch64-darwin";
    in
    {
      darwinConfigurations = {
        MyMBP = nix-darwin.lib.darwinSystem {
          inherit system;
          modules = [
            home-manager.darwinModules.home-manager
            ./darwin.nix
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.naramotoyuuji = import ./home.nix;
            }
          ];
        };
      };

      # ← 追加：packages 出力として darwinConfigurations をラップ
      packages = {
        "${system}" = {
          darwinConfigurations = self.darwinConfigurations;
        };
      };
    };
}

