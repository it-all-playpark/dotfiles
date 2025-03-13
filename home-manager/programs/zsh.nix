{ pkgs, ... }:
let
  common = import ./common.nix;
in
{
  programs.zsh = {
    enable = true;
    loginExtra = ''
      # PATH設定
      export PATH= "$HOME/.nix-profile/bin"
      ${if pkgs.stdenv.isDarwin then "PATH=\"/opt/homebrew/bin\"" else ""}
      ${if pkgs.stdenv.isLinux then "PATH=\"/usr/local/bin\"" else ""}
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
