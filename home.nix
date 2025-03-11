{ config, pkgs, ... }:
let
  home-default = import ./home/default.nix { inherit pkgs; };
in
{
  imports = [
    home-default
    ./programs/fish.nix
    ./programs/zsh.nix
    ./programs/git.nix
    ./programs/yazi.nix
    ./programs/neovim.nix
  ];

}
