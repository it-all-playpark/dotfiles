{ ... }:
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;

  programs.ruff-check.enable = true;
  programs.ruff-format.enable = true;

  programs.stylua.enable = true;

  programs.shfmt.enable = true;

  programs.json-sort-cli = {
    enable = true;
    autofix = true;
    insert-final-newline = true;
    # Zed の keymap.json / settings.json はコメント付き JSON (JSONC) のため
    # 厳密な JSON パーサーを使うフォーマッタにかけるとコメントが消えてしまう
    excludes = [ "home-manager/home/file/zed/*.json" ];
  };
}
