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
  # 設定は WorkingDirectory の .env から読む（repo には置かない。DB の暗号鍵を含む）:
  #   OPENPOST_PORT / OPENPOST_APP_URL / OPENPOST_PUBLIC_URL / OPENPOST_MEDIA_URL
  #   OPENPOST_DATABASE_PATH / OPENPOST_MEDIA_PATH（どちらも WorkingDirectory の data/ 配下）
  #   OPENPOST_JWT_SECRET / OPENPOST_ENCRYPTION_KEY（`openssl rand -base64 32`。再起動・復元をまたいで変えない）
  # .env が無いと起動に失敗し、ThrottleInterval ごとに再試行する
  launchd.agents.openpost = {
    enable = true;
    config = {
      Label = "com.playpark.openpost";
      ProgramArguments = [ "${openpost.server}/bin/openpost-server" ];
      WorkingDirectory = "${home}/.local/share/openpost";
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      StandardOutPath = "${home}/.local/state/openpost.out.log";
      StandardErrorPath = "${home}/.local/state/openpost.err.log";
    };
  };
}
