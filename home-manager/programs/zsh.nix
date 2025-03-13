{ pkgs, ... }:
let
  common = import ./common.nix;
  shellCommon = import ./shell-common.nix { inherit pkgs; };
in
{
  programs.zsh = {
    enable = true;
    loginExtra = ''
      # PATH設定
      export $HOME/.nix-profile/bin
      ${shellCommon.getPathConfig.zshDarwin}
      ${shellCommon.getPathConfig.zshLinux}
    '';
    envExtra = ''
      # yaziでカレントディレクトリを変更
      function yy() {
      	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
      	yazi "$@" --cwd-file="$tmp"
      	if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
      		cd -- "$cwd"
      	fi
      	rm -f -- "$tmp"
      }

      eval "$(zoxide init zsh)"
      eval "$(starship init zsh)"
      eval "$(mise activate zsh)"
    '';
    shellAliases = common.shellSortcuts;
  };
}
