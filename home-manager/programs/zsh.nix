{ ... }:
let
  common = import ./common.nix;
in
{
  programs.zsh = {
    enable = true;
    loginExtra = ''
      # PATH設定
      export PATH="~/.nix-profile/bin /nix/var/nix/profiles/default/bin /opt/homebrew/bin /opt/homebrew/sbin /usr/bin/php ~/ghq/github.com/astj/ghq-migrator ~/google-cloud-sdk/bin ~/Library/Android/sdk ~/.local/share/mise/shims"

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
