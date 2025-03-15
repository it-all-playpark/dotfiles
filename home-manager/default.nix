{ pkgs, username ? "naramotoyuuji", ... }:
let
  home-default = import ./home/default.nix { inherit pkgs username; };
  programs-default = import ./programs/default.nix;
in
{
  imports = [
    home-default
    programs-default
  ];

}
