{ config, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home = {
    username = "naramotoyuuji";
    homeDirectory = "/Users/naramotoyuuji";

    stateVersion = "24.05"; # Please read the comment before changing.

    packages = with pkgs; [
      act
      bat
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
      yazi
      zoxide
    ];

    file = {
      # ".zshrc".source = ./settings/.zshrc;
      ".tmux.conf".source = ./settings/.tmux.conf;
      ".myclirc".source = ./settings/.myclirc;
      ".myclirc.local.template".source = ./settings/.myclirc.local.template;
      ".config/git/config.local.template".source = ./settings/git/config.local.template;
      ".config/fish/config.fish.local.template".source = ./settings/fish/config.fish.local.template;
      ".config/nvim" = {
        source = ./settings/nvim;
        recursive = true;
      };
      ".config/mise" = {
        source = ./settings/mise;
        recursive = true;
      };
      ".config/yazi" = {
        source = ./settings/yazi;
        recursive = true;
      };
      ".warp" = {
        source = ./settings/.warp;
        recursive = true;
      };
    };
  };

  imports = [
    ./programs/fish.nix
    ./programs/zsh.nix
    ./programs/git.nix
  ];

  programs = {
    zsh.enable = false;
    neovim = {
      enable = true;
      vimAlias = true;
    };
  };


}
