{ pkgs, ... }:
let
  packages = import ../common/packages.nix { inherit pkgs; };
in
{
  # システムで使用するパッケージ群（Nix経由）
  environment.systemPackages = packages.commonPackages ++ [
    # macOS専用のパッケージをここに追加
  ];

  # macOSシステム設定
  system.defaults = {
    dock = {
      autohide = true; # Dockの自動非表示
      orientation = "bottom"; # Dockの位置
      tilesize = 50; # アイコンサイズ
    };
    finder = {
      FXPreferredViewStyle = "clmv"; # カラム表示をデフォルトに
      ShowPathbar = true; # パスバーを表示
      ShowStatusBar = true; # ステータスバーを表示
    };
    NSGlobalDomain = {
      AppleShowAllExtensions = true; # 全ての拡張子を表示
      InitialKeyRepeat = 14; # キーリピート開始までの時間
      KeyRepeat = 1; # キーリピート速度
    };
    trackpad = {
      Clicking = true; # タップでクリック
      TrackpadThreeFingerDrag = true; # 3本指ドラッグ
    };
  };

  # プライマリユーザーの設定（システムデフォルト設定の適用対象）
  system.primaryUser = "naramotoyuuji";

  # Nixビルドユーザーグループの設定（GID不一致エラー対応）
  ids.gids.nixbld = 350;

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
      "1password"
      "1password-cli"
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
  system.stateVersion = 4; # システムの状態バージョン（推奨値に更新）
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ]; # 実験的機能を有効化
    trusted-users = [ "@admin" ]; # 管理者ユーザーを信頼
  };

  # シェルの有効化設定
  programs.fish.enable = true; # デフォルトシェルとしてfishを有効化
  programs.zsh.enable = false; # zshは無効化

  # セキュリティ設定
  security.pam.services.sudo_local.touchIdAuth = true; # Touch IDでsudoを有効化
}
