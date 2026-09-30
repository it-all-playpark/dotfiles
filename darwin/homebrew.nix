_: {
  # Homebrewの統合設定
  homebrew = {
    enable = true; # Homebrewを有効化
    onActivation = {
      # Homebrew有効化時の挙動設定
      autoUpdate = true; # brewの自動更新を有効化
      upgrade = true; # 古いバージョンがあれば自動でアップグレード
      # Brewfileにないものをアンインストール。
      # nix-darwin が `--force-cleanup` を自動で付けるので extraFlags での指定は不要
      cleanup = "uninstall";
    };
    taps = [
      "rjyo/moshi" # moshi-hook 配布用 tap (formula は moshi-hook のみで、完全修飾名により trust 済み)
    ];
    brews = [
      {
        # コーディングエージェント(Claude Code等)のイベントを iOS アプリ Moshi に中継する常駐デーモン
        # brew の tap trust は完全修飾名の formula にしか効かない (非修飾名だと
        # trusted: true が無視され、bundle cleanup が trust store を Brewfile 由来で
        # 全置換するため手動 `brew trust` も activation の度に消される)。
        name = "rjyo/moshi/moshi-hook";
        start_service = true;
        restart_service = "changed";
      }
    ];
    casks = [
      # インストールするCaskアプリケーションのリスト
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
      "microsoft-teams"
      "obsidian"
      "onedrive"
      "orbstack"
      "postman"
      "raycast"
      "sequel-ace"
      "setapp"
      "slack"
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
}
