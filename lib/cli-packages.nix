# CLI tool 一覧の単一ソース化
#
# mode = "host"      → 開発マシン用フルセット (host common + host-only)
# mode = "container" → hermes-agent 用 Docker image 向けの最小セット (host common のみ)
#
# 使用例:
#   home-manager/home/default.nix:
#     cliPackages = import ../../lib/cli-packages.nix { inherit pkgs; mode = "host"; };
#
#   flake.nix (dockerTools.buildLayeredImage):
#     cliPackages = import ./lib/cli-packages.nix { inherit pkgs; mode = "container"; };
{
  pkgs,
  mode ? "host",
}:

let
  # 共通 (host / container 両方)
  common = with pkgs; [
    bat
    bun
    coreutils
    curl
    eza
    fd
    fzf
    gh
    ghq
    git
    gws
    jq
    lazygit
    mise
    rip2
    ripgrep
    ripgrep-all
    sd
    starship
    stripe-cli
    tldr
    turso-cli
    vips
    zellij
    zoxide
  ];

  # host のみ (開発マシン専用、container には不要)
  hostOnly = with pkgs; [
    act
    fastfetch
    ffmpeg
    flyctl
    mariadb
    marp-cli
    ollama
    opentofu
    postgresql_17
    procs
    python313Packages.deepl
    rclone
    tbls
  ];
in
if mode == "host" then
  common ++ hostOnly
else if mode == "container" then
  common
else
  throw "cli-packages.nix: unknown mode '${mode}', expected 'host' or 'container'"
