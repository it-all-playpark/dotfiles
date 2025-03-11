{ pkgs, ... }:
let
  home-default = import ./home/default.nix { inherit pkgs; };
  programs-default = import ./programs/default.nix;
in
{
  imports = [
    home-default
    programs-default
  ];

}
