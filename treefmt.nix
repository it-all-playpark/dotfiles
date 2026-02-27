{ ... }:
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;

  programs.ruff-check.enable = true;
  programs.ruff-format.enable = true;

  programs.stylua.enable = true;

  programs.shfmt.enable = true;
}
