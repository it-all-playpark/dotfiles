{
  config,
  lib,
  pkgs,
  ...
}:
let
  ucHandoff = pkgs.stdenv.mkDerivation {
    pname = "uc-handoff";
    version = "0.1.0";
    src = ../home/file/uc-handoff;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      $CC -O2 -Wall -Wextra -Werror \
        -framework ApplicationServices \
        -o uc-handoff uc-handoff.c
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -D -m 555 uc-handoff "$out/bin/uc-handoff"
      runHook postInstall
    '';
    meta.platforms = lib.platforms.darwin;
  };

  # TCC はバイナリのパスに紐づく。nix store のパスは世代ごとに変わるため、
  # そこを直接 launchd から起動するとアクセシビリティ許可が毎回切れる。
  # symlink も不可 (TCC が実体解決して store パスを記録する)。
  # deskflowServerConfig と同じく実体コピーで固定パスに置く。
  ucHandoffBin = "${config.home.homeDirectory}/.local/bin/uc-handoff";
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.activation.ucHandoffBinary = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # 555 のまま install すると dest を開けず EACCES になるので先に消す。
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "${ucHandoffBin}"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m 555 \
      ${ucHandoff}/bin/uc-handoff "${ucHandoffBin}"
  '';

  launchd.agents.uc-handoff = {
    enable = true;
    config = {
      Label = "com.playpark.uc-handoff";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        ''
          DIRECTION="${config.home.homeDirectory}/.config/uc-handoff/direction"
          if [ ! -f "$DIRECTION" ]; then
            echo "uc-handoff: $DIRECTION not found on this host — skipping (write 'left' or 'right')" >&2
            exit 0
          fi
          /bin/wait4path "${ucHandoffBin}" && exec "${ucHandoffBin}"
        ''
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
      };
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Interactive";
      StandardOutPath = "${config.home.homeDirectory}/.local/state/uc-handoff.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.local/state/uc-handoff.err.log";
    };
  };
}
