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

      # /etc/paths・/etc/paths.d（/usr/local/bin・/opt/homebrew/bin 等）を PATH に入れる。入れるのは /etc/zprofile の
      # path_helper だが、非対話 zsh は読まず、上の unsetopt GLOBAL_RCS で対話 zsh も読まない。launchd 由来の
      # セッション（claude --bg・host-exec の子）でも PATH から実体を探す道具（docker-vm 等）が対話シェルと同じ実体に届く。
      # 下の nix・mise の shims・~/.claude/bin より先に組む。-U は .zprofile の /opt/homebrew/bin 等との重複を外す
      if [[ -x /usr/libexec/path_helper ]]; then
        eval "$(/usr/libexec/path_helper -s)"
        typeset -U path PATH
      fi

      # SSH remote commands such as mosh-server run under non-interactive zsh.
      export PATH="$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"

      # mise の shims。.zshrc を読まない非対話 zsh（launchd 由来の Claude Code セッションの Bash 等）でも
      # node などの mise のツールを見つけられるようにする。fish.nix と同じ shims 方式（理由は fish.nix のコメント）
      export PATH="$HOME/.local/share/mise/shims:$PATH"
      # mise の data / state / config を既定の場所の絶対パスで固定する。HOME を一時ディレクトリに差し替えるテストの
      # 子プロセスでも、shims の python3 / node が本物のホームの設定・trust・installs を使う。すでに値があれば
      # 上書きしない（HOME を差し替えた子の zsh が .zshenv を読み直しても、親が渡した値を保つ）
      export MISE_DATA_DIR="''${MISE_DATA_DIR:-$HOME/.local/share/mise}"
      export MISE_STATE_DIR="''${MISE_STATE_DIR:-$HOME/.local/state/mise}"
      export MISE_CONFIG_DIR="''${MISE_CONFIG_DIR:-$HOME/.config/mise}"

      # gh / gcloud / tofu の cwd 連動アカウント shim (dotfiles/claude-code/bin → ~/.claude/bin)。
      # nix-profile の実体より前に置く。設計: docs/specs/2026-09-19-claude-account-env-design.md
      export PATH="$HOME/.claude/bin:$PATH"
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

      # .zshenv でも入れているが、.zprofile が足す /opt/homebrew/bin 等より前へ移す（重複は外す）
      path=("$HOME/.local/share/mise/shims" ''${path:#$HOME/.local/share/mise/shims})
      # ~/.claude/bin（gh / gcloud / tofu の shim と claude の wrapper）は mise の shims より前に置く。
      # .zshenv でも先頭に入れているが、上の行が shims をその前に入れるので、ここで先頭へ移し直す
      path=("$HOME/.claude/bin" ''${path:#$HOME/.claude/bin})
    '';
    shellAliases = common.shellSortcuts;
  };
}
