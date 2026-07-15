# CLI tool 一覧の単一ソース化
#
# mode = "host"      → 開発マシン用フルセット (host common + host-only)
# mode = "container" → hermes-agent 用 Docker image 向けのセット (common + containerOnly)
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
    which
    zellij
    zoxide
  ];

  # host のみ (開発マシン専用、container には不要)
  # NOTE: Node.js は host では mise ("node = lts") で管理。PATH 衝突を避けるためここには入れない。
  hostOnly = with pkgs; [
    act
    agent-browser
    dotenv-cli
    fastfetch
    ffmpeg
    flyctl
    herdr
    hunk
    mariadb
    marp-cli
    netlify-cli
    ollama
    opentofu
    postgresql_17
    procs
    python313Packages.deepl
    rclone
    tbls
  ];

  # container のみ (hermes-tools Docker image 向け)
  # Node.js v24 (Active LTS) を同梱し、Claude Code CLI を動かすための runtime を提供する。
  # host では mise で "node = lts" 管理しているため containerOnly に分離して PATH 衝突を防ぐ。
  containerOnly = with pkgs; [
    nodejs_24
  ];
in
if mode == "host" then
  common ++ hostOnly
else if mode == "container" then
  common ++ containerOnly
else
  throw "cli-packages.nix: unknown mode '${mode}', expected 'host' or 'container'"
