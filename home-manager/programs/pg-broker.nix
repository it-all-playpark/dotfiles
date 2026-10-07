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
  # sandbox 内からの依頼口。permissions.deny の `Bash(curl *)` で curl は使えないので、
  # 宛先が broker.sock に固定されたこのコマンドで頼む（pg_broker_client.py 冒頭参照）
  home.packages = [
    (pkgs.writeShellScriptBin "pg-broker" ''
      exec ${pkgs.python3}/bin/python3 -I -B ${../home/file/pg-broker/pg_broker_client.py} "$@"
    '')
  ];

  # sandbox 内の Bash では Postgres を起動できない（initdb の shmget が EPERM）ので、
  # 依頼を受けて sandbox の外で使い捨ての cluster を起動する（pg_broker.py 冒頭参照）。
  # 依頼口 broker.sock と各 instance のソケット sock/<id>/ は
  # claude-code/settings.json の sandbox.network.allowUnixSockets と揃える。
  launchd.agents.pg-broker = {
    enable = true;
    config = {
      Label = "com.playpark.pg-broker";
      ProgramArguments = [
        "${pkgs.python3}/bin/python3"
        "-I"
        "-B"
        "${../home/file/pg-broker/pg_broker.py}"
      ];
      EnvironmentVariables = {
        HOME = home;
        PG_BROKER_ROOT = "${home}/.local/state/pg-broker";
        # pg_broker.py の VERSIONS の表と揃える。起動できるのはここに書いた nix store の binary だけ
        PG_BROKER_POSTGRESQL_17 = "${pkgs.postgresql_17}/bin";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      StandardOutPath = "${home}/.local/state/pg-broker.out.log";
      StandardErrorPath = "${home}/.local/state/pg-broker.err.log";
    };
  };
}
