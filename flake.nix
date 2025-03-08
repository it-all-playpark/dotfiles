{
  description = "Home Manager configuration only";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    # home-manager は nixpkgs に従うように
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      # ご自身のシステムに合わせて指定してください (例: Apple Silicon の場合 "aarch64-darwin")
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
      # homeManagerConfiguration で home.nix を読み込む
      homeConfig = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home.nix ];
      };
    in {
      homeConfigurations = {
        naramotoyuuji = homeConfig;
      };
    };
}
