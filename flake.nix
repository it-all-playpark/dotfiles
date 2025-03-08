{
  description = "Nix Darwin + Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    home-manager.url = "github:nix-community/home-manager";
    # 各入力は nixpkgs に従います
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }:
    let
      # システム指定 (Apple Silicon の場合 "aarch64-darwin")
      system = "aarch64-darwin";
      # 環境変数 DARWIN_USER / DARWIN_HOST が設定されていなければデフォルト値を使用
      darwinUser = "naramotoyuuji";
      darwinHost = "MyMBP";
      myDarwinConfig = nix-darwin.lib.darwinSystem {
        inherit system;
        modules = [
          ./configuration.nix
          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            # 属性名の補間には引用符を使用する必要があります
            home-manager.users."${darwinUser}" =
              (import ./home.nix {
                inherit nixpkgs system;
                lib = nixpkgs.lib;
                username = darwinUser;
              }) // {
                # home.homeDirectory は絶対パスで指定する
                home.homeDirectory = "/Users/" + darwinUser;
              };
          }
        ];
        specialArgs = {
          inherit (nixpkgs) lib;
          inherit system;
        };
      };
    in
    {
      darwinConfigurations = {
        "${darwinHost}" = myDarwinConfig;
      };
      # （任意）packages 出力としてシステム全体の成果物をラップする例
      packages = {
        "${system}" = {
          system = myDarwinConfig;
        };
      };
    };
}
