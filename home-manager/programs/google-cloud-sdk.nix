{ pkgs, ... }:
{
  programs.google-cloud-sdk = {
    enable = true;
    withExtraComponents = [ pkgs.google-cloud-sdk.components.config-connector ];
  };
}

