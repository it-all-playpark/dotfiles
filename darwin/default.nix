{ pkgs, ... }:
let
  packages = import ../common/packages.nix { inherit pkgs; };
in
{
  # システムで使用するパッケージ群（Nix経由）
  environment.systemPackages = packages.commonPackages ++ [
    # macOS専用のパッケージをここに追加
  ];

  # Homebrewの統合設定
  homebrew = {
    enable = true; # Homebrewを有効化
    onActivation = {
      # Homebrew有効化時の挙動設定
      autoUpdate = true; # brewの自動更新を有効化
      upgrade = true; # 古いバージョンがあれば自動でアップグレード
      cleanup = "uninstall"; # casksにないものをアンインストール
    };
    casks = [
      # インストールするCaskアプリケーションのリスト
      "arc"
      "box-drive"
      "box-tools"
      "chatgpt"
      "claude"
      "coteditor"
      "cursor"
      "deepl"
      "font-hack-nerd-font"
      "google-chrome"
      "google-drive"
      "google-japanese-ime"
      "hhkb-keymap-tool"
      "lastpass"
      "monitorcontrol"
      "microsoft-excel"
      "microsoft-teams"
      "microsoft-powerpoint"
      "microsoft-word"
      "onedrive"
      "orbstack"
      "postman"
      "raycast"
      "repo-prompt"
      "sequel-ace"
      "setapp"
      "slack"
      "warp"
      "zed"
      "zoom"
    ];
    masApps = {
      # Mac App Storeからインストールするアプリケーションのリスト
      Xcode = 497799835;
    };
  };
  # NixデーモンやNixコマンドの設定
  system.stateVersion = 6; # システムの状態バージョン
  nix.settings.experimental-features = [ "nix-command" "flakes" ]; # 実験的機能を有効化

  # シェルの有効化設定
  programs.fish.enable = true; # デフォルトシェルとしてfishを有効化
  programs.zsh.enable = false; # zshは無効化
}
