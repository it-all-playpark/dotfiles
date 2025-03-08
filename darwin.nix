{ config, pkgs, ... }:
{
  # システムで使用するパッケージ群（Nix経由）
  environment.systemPackages = with pkgs; [
    curl
    git
    coreutils
    # ...必要に応じ追加（bat や fd 等も Nix 経由で入れられる）
  ];

  # Homebrew統合設定（上記で解説したもの）
  homebrew = {
    enable = true;
    onActivation = {
      # 有効化時の挙動
      autoUpdate = true; # brew の自動更新を有効化
      upgrade = true; # 古いバージョンがあればアップグレード
      cleanup = "zap"; # アンインストール時に設定も含め削除
    };
    casks = [
      "arc"
      "box-drive"
      "box-tools"
      "chatgpt"
      "cheatsheet"
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
      Xcode = "497799835";
      "Microsoft Word" = "462054704";
      "Microsoft Excel" = "462058435";
      "Microsoft PowerPoint" = "462062816";
      "Microsoft OneNote" = "784801555";
      "Microsoft Outlook" = "985367838";
      "Windows App" = "1295203466";
    };
  };

  # Nixデーモンや Nix コマンドの設定
  services.nix-daemon.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Shell の有効化（デフォルト shell として fish を使う例）
  programs.fish.enable = true;
  programs.zsh.enable = false;

  # ユーザー（naramotoyuuji）の Home Manager 設定をここで有効化
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.naramotoyuuji = import ./home.nix;
}

