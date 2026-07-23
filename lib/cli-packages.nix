# 開発マシン用 CLI tool 一覧
#
# 使用例:
#   home-manager/home/default.nix:
#     cliPackages = import ../../lib/cli-packages.nix { inherit pkgs; };
{
  pkgs,
}:

with pkgs; [
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

  # host のみ (開発マシン専用)
  # NOTE: Node.js は host では mise ("node = lts") で管理。PATH 衝突を避けるためここには入れない。
  act
  agent-browser
  bats # bats-core。skills repo の tests/run-all-bats.sh 等スクリプト隣接テストの実行に必要
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
]
