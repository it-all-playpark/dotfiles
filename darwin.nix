{ pkgs, ... }:

{
  # システムで使用するパッケージ群（Nix経由）
  environment.systemPackages = with pkgs; [
    curl
    git
    coreutils
    # 必要に応じて追加可能（例: batやfdなどもNix経由でインストール可能）
  ];

  # Homebrewの統合設定
  homebrew = {
    enable = true; # Homebrewを有効化
    onActivation = {
      # Homebrew有効化時の挙動設定
      autoUpdate = true; # brewの自動更新を有効化
      upgrade = true; # 古いバージョンがあれば自動でアップグレード
      # cleanup = "zap"; # アンインストール時に設定も含めて削除（コメントアウト中）
    };
    casks = [
      # インストールするCaskアプリケーションのリスト
      "arc"
      "box-drive"
      "box-tools"
      "chatgpt"
      "coteditor"
      "cursor"
      "deepl"
      "docker"
      "font-hack-nerd-font"
      "google-chrome"
      "google-drive"
      "google-japanese-ime"
      "hhkb-keymap-tool"
      "lastpass"
      "monitorcontrol"
      "microsoft-teams"
      "onedrive"
      "postman"
      "raycast"
      "sequel-ace"
      "setapp"
      "slack"
      "warp"
    ];
    masApps = {
      # Mac App Storeからインストールするアプリケーションのリスト
      Xcode = 497799835;
      "Microsoft Word" = 462054704;
      "Microsoft Excel" = 462058435;
      "Microsoft PowerPoint" = 462062816;
      "Microsoft OneNote" = 784801555;
      "Microsoft Outlook" = 985367838;
      # "Windows App" = 1295203466; # コメントアウト中のアプリ
    };
  };
  # NixデーモンやNixコマンドの設定
  system.stateVersion = 6; # システムの状態バージョン
  nix.settings.experimental-features = [ "nix-command" "flakes" ]; # 実験的機能を有効化

  # シェルの有効化設定
  programs.fish.enable = true; # デフォルトシェルとしてfishを有効化
  programs.zsh.enable = false; # zshは無効化
}
