{ pkgs, ... }:
let
  common = import ./common.nix;
  shellCommon = import ./shell-common.nix { inherit pkgs; };
in
{
  programs.fish = {
    enable = true;
    shellInit = ''
      # PATH設定
      fish_add_path $HOME/.nix-profile/bin
      ${shellCommon.getPathConfig.darwin}
      ${shellCommon.getPathConfig.linux}

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
      # terraformをopenTofuで代用
      terraform = ''tofu'';
      # rembg: 専用venv環境で実行 (numba互換性問題の回避)
      rembg = ''
        set -l venv_path "$HOME/.local/share/rembg-env"
        if not test -f "$venv_path/bin/rembg"
          echo "Setting up rembg environment (first time only)..."
          rm -rf "$venv_path"
          uv venv "$venv_path" --python 3.12
          VIRTUAL_ENV="$venv_path" uv pip install "rembg[cli]" onnxruntime "numba>=0.60.0" "numpy<2.0"
          echo "Setup complete!"
        end
        "$venv_path/bin/rembg" $argv
      '';
    };
    shellAbbrs = common.shellSortcuts;
  };
}
