{ ... }:
{
  projectRootFile = "flake.nix";

  # npm が書いた形のまま保つ（buildNpmPackage は npmDeps に保存した lockfile と内容一致を要求する）
  settings.global.excludes = [ "**/package-lock.json" ];

  programs.nixfmt.enable = true;

  programs.ruff-check.enable = true;
  programs.ruff-format.enable = true;

  programs.stylua.enable = true;

  # treefmt-nix は indent_size（旧既定 2）と simplify（旧既定 true）の既定を外したので、
  # 明示しないとタブ字下げに変わり、既存の .sh がすべて未整形扱いになる
  programs.shfmt = {
    enable = true;
    indent_size = 2;
    simplify = true;
  };

  programs.json-sort-cli = {
    enable = true;
    autofix = true;
    insert-final-newline = true;
  };
}
