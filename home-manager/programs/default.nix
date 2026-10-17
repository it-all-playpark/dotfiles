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
    ./cc-launch.nix
    ./uc-handoff.nix
    ./jev-broker.nix
    ./pg-broker.nix
    ./docker-proxy.nix
    ./agent-vault.nix
    ./lima-sandbox.nix
    ./sandbox-docker.nix
    ./vm-egress-proxy.nix
  ];
}
