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
  imports = [
    ./homebrew.nix
    ./nix.nix
    ./remote-access.nix
  ];

  # システムで使用するパッケージ群（Nix経由）
  environment.systemPackages =
    packages.commonPackages
    ++ swiftDevPackages
    ++ [
      # macOS専用のパッケージをここに追加
    ];

  # xcodegen は <bin>/../share/xcodegen/SettingPresets を探す。system profile に
  # リンクしないと SDKROOT / PRODUCT_NAME 等が抜けた .xcodeproj が生成される
  environment.pathsToLink = [ "/share/xcodegen" ];

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
  system.tools.darwin-uninstaller.enable = false;

  system.stateVersion = 4; # システムの状態バージョン（推奨値に更新）

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

  documentation.enable = false;
}
