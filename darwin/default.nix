{ pkgs, username, ... }:
let
  packages = import ../common/packages.nix { inherit pkgs; };
  # Swift/iOS 開発ツール (macOS 専用)
  swiftDevPackages = with pkgs; [
    xcodegen # project.yml から .xcodeproj を生成
    swiftlint # Swift Lint
    swiftformat # Swift Formatter
    fastlane # iOS ビルド/署名/TestFlight・App Store 提出の自動化 (Ruby 同梱の hermetic closure)
  ];
in
{
  # システムで使用するパッケージ群（Nix経由）
  environment.systemPackages =
    packages.commonPackages
    ++ swiftDevPackages
    ++ [
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
      InitialKeyRepeat = 10; # キーリピート開始までの時間（最速）
      KeyRepeat = 1; # キーリピート速度
    };
    trackpad = {
      Clicking = true; # タップでクリック
      TrackpadThreeFingerDrag = true; # 3本指ドラッグ
    };
  };

  # プライマリユーザーの設定（システムデフォルト設定の適用対象）
  system.primaryUser = username;

  # Nixビルドユーザーグループの設定（GID不一致エラー対応）
  ids.gids.nixbld = 350;

  # Homebrewの統合設定
  homebrew = {
    enable = true; # Homebrewを有効化
    onActivation = {
      # Homebrew有効化時の挙動設定
      autoUpdate = true; # brewの自動更新を有効化
      upgrade = true; # 古いバージョンがあれば自動でアップグレード
      cleanup = "uninstall"; # Brewfileにないものをアンインストール
      extraFlags = [ "--force-cleanup" ]; # cleanup実行時の確認を明示的に許可
    };
    casks = [
      # インストールするCaskアプリケーションのリスト
      "antigravity"
      "blackhole-2ch"
      "box-drive"
      "box-tools"
      "chatgpt"
      "claude"
      "deepl"
      "font-hack-nerd-font"
      "google-chrome"
      "google-drive"
      "google-japanese-ime"
      "ghostty"
      "hhkb"
      "jump-desktop-connect"
      "monitorcontrol"
      "microsoft-excel"
      "microsoft-teams"
      "microsoft-powerpoint"
      "microsoft-word"
      "obsidian"
      "onedrive"
      "orbstack"
      "postman"
      "raycast"
      "sequel-ace"
      "setapp"
      "slack"
      "zed"
      "zoom"
      "1password"
      "1password-cli"
    ];
    masApps = {
      # Mac App Storeからインストールするアプリケーションのリスト
      "1Password for Safari" = 1569813296;
      LINE = 539883307;
      Xcode = 497799835;
    };
  };
  # NixデーモンやNixコマンドの設定
  system.stateVersion = 4; # システムの状態バージョン（推奨値に更新）
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ]; # 実験的機能を有効化
    trusted-users = [ "@admin" ]; # 管理者ユーザーを信頼
  };

  # Linux builder（macOS 上で linux 用 derivation を build する VM）
  # hermes-agent 用 Docker image (dockerTools.buildLayeredImage) は Linux 専用のため
  # darwin から build するには linux-builder が必須。
  # ephemeral = true により VM は必要時のみ起動しリソース消費を抑える。
  nix.linux-builder = {
    enable = true;
    ephemeral = true;
    maxJobs = 4;
    config = {
      virtualisation.cores = 6;
      virtualisation.darwin-builder = {
        memorySize = 12288;
        diskSize = 40960;
      };
    };
  };

  # シェルの有効化設定
  programs.fish.enable = true; # デフォルトシェルとしてfishを有効化
  programs.zsh.enable = false; # zshは無効化

  # ログインシェルを fish に変更（$SHELL=fish になる）
  users.users.${username} = {
    shell = pkgs.fish;
    home = "/Users/${username}";
  };

  # セキュリティ設定
  security.pam.services.sudo_local.touchIdAuth = true; # Touch IDでsudoを有効化
  security.pam.services.sudo_local.reattach = true; # tmuxなどでTouch IDを動作させるためのpam_reattachを有効化

  # Tailscale VPN（CLIのみ、インターネット越しSSH用）
  services.tailscale.enable = true;
  documentation.enable = false;
}
