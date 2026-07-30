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
      # -Werror はテスト側 (tests/uc-handoff.test.sh) だけに置く。ここに入れると
      # nixpkgs の bump で clang が新しい警告を出した瞬間、dotfiles 全体の
      # apply が落ちる (この derivation は activation の依存にいる)。
      $CC -O2 -Wall -Wextra \
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
    # plist は世代が変わっても不変なので home-manager は agent を reload しない。
    # バイナリを差し替えたら明示的に蹴り直さないと古いプロセスが残る。
    $DRY_RUN_CMD /bin/launchctl kickstart -k "gui/$(id -u)/com.playpark.uc-handoff" || true
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
      # exit 0 (方向未設定) では再起動しない。spec §7.2 の「設定を書き忘れた機体では
      # 起動しない」を launchd 側でも守る。クラッシュとシグナル死だけ拾い、
      # 権限未許可の exit 1 は 60 秒間隔で自己回復させる。
      KeepAlive = {
        SuccessfulExit = false;
      };
      ThrottleInterval = 60;
      ProcessType = "Interactive";
      StandardOutPath = "${config.home.homeDirectory}/.local/state/uc-handoff.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.local/state/uc-handoff.err.log";
    };
  };
}
