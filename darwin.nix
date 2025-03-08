{ config, pkgs, ... }:
{
  # システムで使用するパッケージ群
  environment.systemPackages = with pkgs; [
    curl
    git
    coreutils
    # ...必要に応じ追加
  ];

  # Homebrew 統合設定
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };
    casks = [
      "arc" "box-drive" "box-tools" "chatgpt" "cheatsheet" "coteditor"
      "cursor" "deepl" "docker" "font-hack-nerd-font" "google-chrome"
      "google-drive" "google-japanese-ime" "hhkb-keymap-tool" "lastpass"
      "monitorcontrol" "microsoft-teams" "onedrive" "postman" "raycast"
      "sequel-ace" "setapp" "slack" "warp"
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

  # Nix デーモンなどの設定
  services.nix-daemon.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # シェル設定
  programs.fish.enable = true;
  programs.zsh.enable = false;

  # Home Manager の設定
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.naramotoyuuji = let
    hm = import ./home.nix { inherit config pkgs; };
  in hm // {
    home.homeDirectory = "/Users/naramotoyuuji";
  };
}
