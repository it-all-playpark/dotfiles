{
  lib,
  pkgs,
  ...
}:
lib.mkIf pkgs.stdenv.isDarwin {
  # sandbox 内から使い捨ての Postgres を頼むコマンド。sandbox-docker VM（sandbox-docker.nix の docker-vm）で
  # digest 固定の postgres コンテナを起動する（pg_broker_client.py 冒頭参照）。
  # 実体を nix store に置くので、起動できる image・label・port の範囲を sandbox から書き換えられない
  home.packages = [
    (pkgs.writeShellScriptBin "pg-broker" ''
      exec ${pkgs.python3}/bin/python3 -I -B ${../home/file/pg-broker/pg_broker_client.py} "$@"
    '')
  ];
}
