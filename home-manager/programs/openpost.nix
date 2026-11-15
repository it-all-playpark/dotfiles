{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  openpost = pkgs.callPackage ../../lib/openpost { };
in
lib.mkIf pkgs.stdenv.isDarwin {
  # server の API を叩く CLI（予約・編集・取消・確認）。server と同じ固定版
  home.packages = [ openpost.cli ];

  # SNS の予約投稿サーバー。予約時刻に投稿するのはこのプロセスなので常駐させる。
  # 動かすのは 24/7 稼働のサーバー機（Mac Studio）だけ。対象の判定は openpost-server.sh が実行時に行い
  # （darwin/remote-access.nix と同じ基準）、対象外のマシンでは exit 0 する。KeepAlive を
  # SuccessfulExit = false にして、その正常終了では再起動させない。
  #
  # 設定は OPENPOST_SERVER_DIR の .env から読む（repo には置かない。DB の暗号鍵を含む）:
  #   OPENPOST_PORT / OPENPOST_APP_URL / OPENPOST_PUBLIC_URL / OPENPOST_MEDIA_URL
  #   OPENPOST_DATABASE_PATH / OPENPOST_MEDIA_PATH（どちらも OPENPOST_SERVER_DIR の data/ 配下）
  #   OPENPOST_JWT_SECRET / OPENPOST_ENCRYPTION_KEY（`openssl rand -base64 32`。再起動・復元をまたいで変えない）
  # 対象のマシンで .env が無いと起動に失敗し、ThrottleInterval ごとに再試行する
  launchd.agents.openpost = {
    enable = true;
    config = {
      Label = "com.playpark.openpost";
      ProgramArguments = [
        "${pkgs.bash}/bin/bash"
        "${../home/file/openpost/openpost-server.sh}"
      ];
      EnvironmentVariables = {
        OPENPOST_SERVER_BIN = "${openpost.server}/bin/openpost-server";
        OPENPOST_SERVER_DIR = "${home}/.local/share/openpost";
        OPENPOST_SERVER_MARKER = "${home}/.config/dotfiles/.no-sleep-server";
      };
      RunAtLoad = true;
      KeepAlive = {
        Crashed = true;
        SuccessfulExit = false;
      };
      ThrottleInterval = 30;
      StandardOutPath = "${home}/.local/state/openpost.out.log";
      StandardErrorPath = "${home}/.local/state/openpost.err.log";
    };
  };
}
