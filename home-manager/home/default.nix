{ pkgs, username ? "naramotoyuuji", ... }:
let
  packages = import ../../common/packages.nix { inherit pkgs; };
in
{
  home = {
    username = username;
    homeDirectory = pkgs.lib.strings.concatStringsSep "" [
      (pkgs.lib.optionalString pkgs.stdenv.isDarwin "/Users/")
      (pkgs.lib.optionalString (!pkgs.stdenv.isDarwin) "/home/")
      username
    ];
    stateVersion = "24.05"; # Please read the comment before changing.

    # 共通パッケージを全プラットフォームでインストール
    packages = packages.commonPackages ++ (with pkgs; [
      act
      bat
      python313Packages.deepl
      devcontainer
      eza
      fastfetch
      fd
      flyctl
      fzf
      gh
      ghq
      jq
      lazydocker
      lazygit
      mariadb
      marp-cli
      mise
      # mycli  # TODO: 一時的に無効化 - llm 0.28 のテスト失敗 (nixpkgs upstream issue)
      opentofu
      postgresql_17
      procs
      rip2
      ripgrep
      ripgrep-all
      sd
      starship
      stripe-cli
      tbls
      tldr
      tmux
      vips
      zoxide
    ]);

    file = {
      ".tmux.conf".source = ./file/.tmux.conf;
      ".myclirc".source = ./file/.myclirc;
      ".ripgreprc".source = ./file/.ripgreprc;
      ".mcpservers.json.template".source = ./file/.mcpservers.json.template;
      ".myclirc.local.template".source = ./file/.myclirc.local.template;
      ".config/git/config.local.template".source = ./file/git/config.local.template;
      ".config/fish/config.fish.local.template".source = ./file/fish/config.fish.local.template;
      ".claude" = {
        source = ./file/claude;
        recursive = true;
      };
      ".config/nvim" = {
        source = ./file/nvim;
        recursive = true;
      };
      ".config/mise" = {
        source = ./file/mise;
        recursive = true;
      };
      ".config/zed" = {
        source = ./file/zed;
        recursive = true;
      };
      "Library/Application Support/lazygit" = {
        source = ./file/lazygit;
        recursive = true;
      };
      ".warp" = {
        source = ./file/.warp;
        recursive = true;
      };
    };
  };
}
