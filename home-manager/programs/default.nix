{ pkgs, ... }:
{
  imports = [
    (import ./fish.nix { inherit pkgs; })
    (import ./zsh.nix { inherit pkgs; })
    ./git.nix
    ./google-cloud-sdk.nix
    ./yazi.nix
    ./neovim.nix
  ];
}
