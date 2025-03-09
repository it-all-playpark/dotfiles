{ config, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "naramotoyuuji";
  home.homeDirectory = "/Users/naramotoyuuji";

  home.stateVersion = "24.05"; # Please read the comment before changing.

  home.packages = with pkgs; [
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
    delta
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
    tree-sitter
    unar
    yazi
    zoxide
  ];

  # シェル有効化など
  programs.zsh.enable = false;
  programs.fish = {
    enable = true;
    shellInit = builtins.readFile ./programs/fish/shellInit.fish;
    functions = builtins.readFile ./programs/fish/functions.fish;
    shellAbbrs = builtins.readFile ./programs/fish/shellAbbrs.fish;
  };

  programs.neovim = {
    enable = true;
    vimAlias = true;
  };

  home.file = {
    ".gitconfig".source = ./settings/.gitconfig;
    ".gitconfig.local.template".source = ./settings/.gitconfig.local.template;
    ".zshrc".source = ./settings/.zshrc;
    ".tmux.conf".source = ./settings/.tmux.conf;
    ".myclirc".source = ./settings/.myclirc;
    ".myclirc.local.template".source = ./settings/.myclirc.local.template;
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

}
