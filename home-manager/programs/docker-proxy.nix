{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  socket = "${home}/.local/state/docker-proxy/docker.sock";
in
lib.mkIf pkgs.stdenv.isDarwin {
  # sandbox 内からの依頼口。読み取り専用の調査（ps / inspect / logs / stats / top / images / info /
  # system df）をこのソケット経由で行う。書き込み系は docker-proxy が 403 を返すので host-exec で行う
  home.packages = [
    (pkgs.writeShellScriptBin "docker-sb" ''
      exec docker --host unix://${socket} "$@"
    '')
  ];

  # docker.sock を sandbox に通すとホストの root 相当になるので、読み取り専用の GET だけを
  # allowlist で中継する（docker_proxy.py 冒頭参照）。
  # 待ち受けるソケットは claude-code/settings.json の sandbox.network.allowUnixSockets と揃える。
  # 上流の docker.sock は allowUnixSockets に足さない。
  launchd.agents.docker-proxy = {
    enable = true;
    config = {
      Label = "com.playpark.docker-proxy";
      ProgramArguments = [
        "${pkgs.python3}/bin/python3"
        "-I"
        "-B"
        "${../home/file/docker-proxy/docker_proxy.py}"
      ];
      EnvironmentVariables = {
        HOME = home;
        DOCKER_PROXY_SOCKET = socket;
        DOCKER_PROXY_UPSTREAM = "${home}/.orbstack/run/docker.sock";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      StandardOutPath = "${home}/.local/state/docker-proxy.out.log";
      StandardErrorPath = "${home}/.local/state/docker-proxy.err.log";
    };
  };
}
