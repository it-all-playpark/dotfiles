{ pkgs, ... }:
{
  getPathConfig = {
    darwin = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
      fish_add_path /opt/homebrew/bin
    '';

    linux = pkgs.lib.optionalString pkgs.stdenv.isLinux ''
      fish_add_path /usr/local/bin
    '';

    zshDarwin = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
      PATH="/opt/homebrew/bin:$PATH"
    '';

    zshLinux = pkgs.lib.optionalString pkgs.stdenv.isLinux ''
      PATH="/usr/local/bin:$PATH"
    '';
  };
}

