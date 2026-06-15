{ pkgs, ... }:
let
  common = import ./common.nix;
  shellCommon = import ./shell-common.nix { inherit pkgs; };
in
{
  programs.zsh = {
    enable = true;
    loginExtra = ''
      ${shellCommon.getPathConfig.zshDarwin}
      ${shellCommon.getPathConfig.zshLinux}
    '';
    envExtra = ''
      unsetopt GLOBAL_RCS

      # SSH remote commands such as mosh-server run under non-interactive zsh.
      export PATH="$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"
    '';
    initContent = ''
      # terraformをopenTofuで代用
      function terraform() tofu

      function __zoxide_hook() {
        command zoxide add -- "$PWD" >/dev/null 2>&1
      }
      function z() {
        if [[ "$#" -eq 0 ]]; then
          builtin cd -- "$HOME"
        elif [[ "$#" -eq 1 && ( -d "$1" || "$1" == "-" || "$1" =~ ^[-+][0-9]+$ ) ]]; then
          builtin cd -- "$1"
        else
          local result
          result="$(command zoxide query --exclude "$PWD" -- "$@")" && builtin cd -- "$result"
        fi
      }
      function zi() {
        local result
        result="$(command zoxide query --interactive -- "$@")" && builtin cd -- "$result"
      }
      typeset -ga chpwd_functions
      chpwd_functions=("''${(@)chpwd_functions:#__zoxide_hook}" __zoxide_hook)

      path=("$HOME/.local/share/mise/shims" $path)
    '';
    shellAliases = common.shellSortcuts;
  };
}
