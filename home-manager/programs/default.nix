{ pkgs, ... }:
{
  imports = [
    (import ./fish.nix { inherit pkgs; })
    (import ./zsh.nix { inherit pkgs; })
    (import ./google-cloud-sdk.nix { inherit pkgs; })
    ./antigravity-cli.nix
    ./git.nix
    ./yazi.nix
    ./neovim.nix
  ];
}
