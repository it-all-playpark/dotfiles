{ pkgs, ... }:
let
  common = import ./common.nix;
in
{
  programs.fish = {
    enable = true;
    shellInit = ''
      # PATH設定
      fish_add_path $HOME/.nix-profile/bin
      ${if pkgs.stdenv.isDarwin then "fish_add_path /opt/homebrew/bin" else ""}
      ${if pkgs.stdenv.isLinux then "fish_add_path /usr/local/bin" else ""}

      starship init fish | source
      zoxide init fish | source
      mise activate fish | source
      
      # ローカル設定を読み込む
      if test -f ~/.config/fish/config.fish.local
          source ~/.config/fish/config.fish.local
      end
    '';
    functions = {
      # yaziでカレントディレクトリを変更
      yy = ''
        set tmp (mktemp -t "yazi-cwd.XXXXXX")
        yazi $argv --cwd-file="$tmp"
        if set cwd (cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
          cd -- "$cwd"
        end
        rm -f -- "$tmp"
      '';
    };
    shellAbbrs = common.shellSortcuts;
  };
}
