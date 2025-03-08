{ pkgs, ... }:

{
  # システムで使用するパッケージ群（Nix経由）
  environment.systemPackages = with pkgs; [
    curl
    git
    coreutils
    # ...必要に応じ追加（batやfd等もNix経由で入れられる）
  ];

  # Homebrew統合設定（上記で解説したもの）
  homebrew = {
    enable = true;
    onActivation = {
      # 有効化時の挙動
      autoUpdate = true; # brewの自動更新を有効化
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
  # NixデーモンやNixコマンドの設定
  services.nix-daemon.enable = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # （上記は [oai_citation_attribution:32‡carlosvaz.com](https://carlosvaz.com/posts/declarative-macos-management-with-nix-darwin-and-home-manager/#:~:text=,daemon.enable%20%3D%20true)を参考に設定）

  # Shellの有効化（デフォルトshellとしてfishを使う例）
  programs.fish.enable = true; # fishシェルを有効化 [oai_citation_attribution:33‡davi.sh](https://davi.sh/til/nix/nix-macos-setup/#:~:text=,programs.fish.enable%20%3D%20true)
  programs.zsh.enable = false; # zshはオフにする（お好みで）

  # ユーザー（yourname）のHome Manager設定をここで有効化
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.naramotoyuuji = { pkgs, ... }: import ./home.nix;
}
