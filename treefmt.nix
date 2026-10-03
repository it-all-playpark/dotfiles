{ ... }:
{
  projectRootFile = "flake.nix";

  # npm が書いた形のまま保つ（buildNpmPackage は npmDeps に保存した lockfile と内容一致を要求する）
  settings.global.excludes = [ "**/package-lock.json" ];

  programs.nixfmt.enable = true;

  programs.ruff-check.enable = true;
  programs.ruff-format.enable = true;

  programs.stylua.enable = true;

  programs.shfmt.enable = true;

  programs.json-sort-cli = {
    enable = true;
    autofix = true;
    insert-final-newline = true;
  };
}
