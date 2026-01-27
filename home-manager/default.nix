{ pkgs, lib, config, username ? "naramotoyuuji", ... }:
let
  home-default = import ./home/default.nix { inherit pkgs lib config username; };
  programs-default = import ./programs/default.nix;
in
{
  imports = [
    home-default
    programs-default
  ];

}
