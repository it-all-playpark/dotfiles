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
  # メモリが逼迫したら mem-triage の safe_kill（親を失った stdio サーバー）だけを SIGTERM し、それでも逼迫が
  # 続けば候補を通知する（resource_watchdog.py 冒頭参照）。止めるには ~/.config/resource-watchdog/config に
  # enabled=false と書く。この module の import を外して apply すれば agent ごと消える。
  # sandbox の外で動くので、実体は nix store に置き、sandbox から書ける場所のものは実行しない
  launchd.agents.resource-watchdog = {
    enable = true;
    config = {
      Label = "com.playpark.resource-watchdog";
      ProgramArguments = [
        "${pkgs.python3}/bin/python3"
        "-I"
        "-B"
        "${../home/file/resource-watchdog/resource_watchdog.py}"
      ];
      EnvironmentVariables = {
        HOME = home;
        # mem-triage は `#!/usr/bin/env bash` で起動し、jq を bare 名で呼ぶ
        PATH = "${pkgs.bash}/bin:${pkgs.jq}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      StartInterval = 120;
      StandardOutPath = "${home}/.local/state/resource-watchdog.out.log";
      StandardErrorPath = "${home}/.local/state/resource-watchdog.err.log";
    };
  };
}
