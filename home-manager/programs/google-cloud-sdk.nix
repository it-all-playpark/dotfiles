{ pkgs, ... }:
{
  home.packages = [
    (pkgs.google-cloud-sdk.withExtraComponents (
      with pkgs.google-cloud-sdk.components; [
        config-connector
      ]
    ))
  ];
}