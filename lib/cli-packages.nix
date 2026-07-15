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
    ast-grep # 構文認識の検索・一括書き換え (codemod)。AI agent がコンテキスト外で安全に一括変更するための道具
    bat
    bun
    coreutils
    curl
    difftastic # 構文木ベースの構造 diff。--exit-code で「構造変化あり/フォーマットのみ」を機械判定できる
    eza
    fd
    fzf
    gh
    ghq
    git
    gron # JSON を grep 可能な行形式に展開。構造が未知の JSON を全読みせず `gron | rg` で探索できる
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
    tokei # コードベースの言語構成・規模を1コマンドで把握。AI agent が全ファイルを読まずに概観を得る
    turso-cli
    vips
    which
    yq-go # YAML/TOML/XML から必要部分だけ抽出 (jq の YAML 版)。設定ファイル全読みを避ける
    zellij
    zoxide
  ];

  # host のみ (開発マシン専用、container には不要)
  # NOTE: Node.js は host では mise ("node = lts") で管理。PATH 衝突を避けるためここには入れない。
  hostOnly = with pkgs; [
    act
    agent-browser
    dotenv-cli
    duckdb # CSV/Parquet/巨大 JSON を SQL で集計・抽出。AI agent がデータファイルを全読みせず必要行だけ取り出す
    fastfetch
    ffmpeg
    flyctl
    herdr
    hunk
    hyperfine # 統計的に妥当なベンチマーク CLI。性能主張を計測で裏付ける (Evidence > assumptions)
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
