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
  };
}
