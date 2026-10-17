{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  socket = "${home}/.lima/sandbox-docker/sock/docker.sock";
  # VM から Mac・LAN に届かないパッチ版 Lima（lib/lima-sandbox 冒頭参照）。素の pkgs.lima は使わない
  limactl = "${pkgs.callPackage ../../lib/lima-sandbox { }}/bin/limactl";
  # Ubuntu 26.04 の cloud image。Lima の templates/_images/ubuntu-lts.yaml の aarch64 と同じ release・digest
  image = pkgs.fetchurl {
    url = "https://cloud-images.ubuntu.com/releases/resolute/release-20260720/ubuntu-26.04-server-cloudimg-arm64.img";
    hash = "sha256-e88VnimtAAC/7ZxXh1kIw5Jo9e0SV/SVj6ap9fYO3VQ=";
  };
  limaYaml = pkgs.replaceVars ../home/file/sandbox-docker/lima.yaml { inherit image; };
in
lib.mkIf pkgs.stdenv.isDarwin {
  # sandbox 内から書き込み系も含めて使う docker。VM sandbox-docker の rootless docker に繋ぐ。
  # VM に mount しているのは /private/tmp/claude だけなので、repo のファイルは docker build の context や
  # docker cp で渡す（lima.yaml 冒頭参照）。OrbStack 側の読み取り専用は docker-sb（docker-proxy.nix）
  home.packages = [
    (pkgs.writeShellScriptBin "docker-vm" ''
      exec docker --host unix://${socket} "$@"
    '')
  ];

  # ログイン時に VM を（無ければ作って）起動する（start.sh 参照）。
  # socket は claude-code/settings.json の sandbox.network.allowUnixSockets と揃える。
  # ~/.lima 配下のほかの socket（ha.sock・ssh.sock 等）は allowUnixSockets に足さない
  launchd.agents.sandbox-docker = {
    enable = true;
    config = {
      Label = "com.playpark.sandbox-docker";
      ProgramArguments = [
        "${pkgs.bash}/bin/bash"
        "${../home/file/sandbox-docker/start.sh}"
      ];
      EnvironmentVariables = {
        HOME = home;
        LIMACTL = limactl;
        SANDBOX_DOCKER_YAML = "${limaYaml}";
      };
      RunAtLoad = true;
      # limactl start は hostagent を残して終わる。job の終了で launchd に hostagent ごと止められないようにする
      AbandonProcessGroup = true;
      StandardOutPath = "${home}/.local/state/sandbox-docker.out.log";
      StandardErrorPath = "${home}/.local/state/sandbox-docker.err.log";
    };
  };
}
