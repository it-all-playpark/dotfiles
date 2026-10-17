{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  # lib/lima-sandbox/deny.go の proxySocket と揃える。claude-code/settings.json の allowUnixSockets には
  # 足さない（sandbox から直接繋がると、VM 専用の追加分のホストに sandbox から直接出られる）
  socket = "${home}/.local/state/vm-egress-proxy/proxy.sock";
  allowlist = import ../home/file/vm-egress-proxy/allowlist.nix {
    inherit lib;
    inherit (pkgs) writeText;
  };
in
lib.mkIf pkgs.stdenv.isDarwin {
  # VM sandbox-docker の外向き通信の唯一の出口（vm_egress_proxy.py 冒頭参照）。パッチ版 Lima の forwarder が
  # VM の 192.168.5.2:3128 宛てをこのソケットに繋ぐ。許可リストに無いホストは 403 にし、
  # StandardErrorPath に denied の行を残す
  launchd.agents.vm-egress-proxy = {
    enable = true;
    config = {
      Label = "com.playpark.vm-egress-proxy";
      ProgramArguments = [
        "${pkgs.python3}/bin/python3"
        "-I"
        "-B"
        "${../home/file/vm-egress-proxy/vm_egress_proxy.py}"
      ];
      EnvironmentVariables = {
        HOME = home;
        VM_EGRESS_PROXY_SOCKET = socket;
        VM_EGRESS_PROXY_ALLOWLIST = "${allowlist}";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      StandardOutPath = "${home}/.local/state/vm-egress-proxy.out.log";
      StandardErrorPath = "${home}/.local/state/vm-egress-proxy.err.log";
    };
  };
}
