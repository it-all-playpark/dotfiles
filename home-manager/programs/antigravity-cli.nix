{
  pkgs,
  lib,
  config,
  ...
}:
{
  home.activation.installAntigravityCli = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -x "${config.home.homeDirectory}/.local/bin/agy" ]; then
      export PATH="${
        lib.makeBinPath [
          pkgs.curl
          pkgs.coreutils
          pkgs.gnutar
          pkgs.gzip
          pkgs.perl
        ]
      }:$PATH"
      $DRY_RUN_CMD ${pkgs.curl}/bin/curl -fsSL https://antigravity.google/cli/install.sh \
        | ${pkgs.bash}/bin/bash
    fi
  '';
}
