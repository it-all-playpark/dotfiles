{ pkgs, ... }:
{
  home = {
    username = "naramotoyuuji";
    homeDirectory = if pkgs.stdenv.isDarwin then "/Users/naramotoyuuji" else "/home/naramotoyuuji";

    stateVersion = "24.05"; # Please read the comment before changing.

    packages = with pkgs; [
      act
      bat
      python313Packages.deepl
      eza
      fastfetch
      fd
      ffmpegthumbnailer
      ffmpeg
      fzf
      gh
      ghq
      google-cloud-sdk
      jq
      lastpass-cli
      lazydocker
      lazygit
      mise
      mycli
      pandoc
      poppler
      procs
      rip2
      ripgrep
      ripgrep-all
      sd
      starship
      tbls
      tldr
      zoxide
    ];

    file = {
      ".tmux.conf".source = ./file/.tmux.conf;
      ".myclirc".source = ./file/.myclirc;
      ".myclirc.local.template".source = ./file/.myclirc.local.template;
      ".config/git/config.local.template".source = ./file/git/config.local.template;
      ".config/fish/config.fish.local.template".source = ./file/fish/config.fish.local.template;
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
      ".warp" = {
        source = ./file/.warp;
        recursive = true;
      };
    };
  };
}
