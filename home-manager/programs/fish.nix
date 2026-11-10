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
      # zsh と同じ shims 方式。PATH には mise の shims を 1 つ置くだけで、プロンプトごとの hook-env は走らない。
      # 非 shims の activate は、プロンプトや cd のたびに hook-env が mise のツール（installs）を
      # ~/.claude/bin より前に戻し、claude が wrapper を通らなくなる（activate_aggressive=false でも、
      # activate の前に PATH から外しても同じ。2026-10-08 実測）。shims 方式ではシェルに JAVA_HOME / GOROOT /
      # CARGO_HOME 等が入らない（shims 経由で起動したツールには付く）。mise 外で足したコマンドは mise reshim が要る
      mise activate fish --shims | source
      # mise の data / state / config を既定の場所の絶対パスで固定する（zsh.nix の envExtra と同じ値・同じ規則）。
      # すでに値があれば上書きしない
      set -q MISE_DATA_DIR; or set -gx MISE_DATA_DIR $HOME/.local/share/mise
      set -q MISE_STATE_DIR; or set -gx MISE_STATE_DIR $HOME/.local/state/mise
      set -q MISE_CONFIG_DIR; or set -gx MISE_CONFIG_DIR $HOME/.config/mise

      # gh / gcloud / tofu の cwd 連動アカウント shim と claude の wrapper (~/.claude/bin)。
      # mise の shims より前に置く（後ろだと mise の claude-code が wrapper より先に見つかる）。
      # 設計: docs/specs/2026-09-19-claude-account-env-design.md
      fish_add_path --path --move $HOME/.claude/bin

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
      terraform = "tofu";
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
