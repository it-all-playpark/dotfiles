{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
in
lib.mkIf pkgs.stdenv.isDarwin {
  # Jev の API 鍵を Keychain から読み、Unix ソケットで中継する（jev_broker.py 冒頭参照）。
  # gui ドメインに載せるのは、Aqua セッションでしか login keychain の解除が効かないため。
  # bg job・sandbox 内の Bash は jev-classify.sh からこのソケット経由で Jev を呼ぶ。
  # ソケットのパスは claude-code/settings.json の sandbox.network.allowUnixSockets と揃える。
  launchd.agents.jev-broker = {
    enable = true;
    config = {
      Label = "com.playpark.jev-broker";
      ProgramArguments = [
        "${pkgs.python3}/bin/python3"
        "-I"
        "-B"
        "${../home/file/jev-broker/jev_broker.py}"
      ];
      EnvironmentVariables = {
        HOME = home;
        JEV_BROKER_SOCKET = "${home}/.local/state/jev-broker/jev.sock";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      StandardOutPath = "${home}/.local/state/jev-broker.out.log";
      StandardErrorPath = "${home}/.local/state/jev-broker.err.log";
    };
  };
}
