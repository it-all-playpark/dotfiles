{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  socket = "${home}/.lima/sandbox-docker/sock/docker.sock";
  # VM からの外向き通信を vm-egress-proxy（vm-egress-proxy.nix）だけに絞るパッチ版 Lima
  # （lib/lima-sandbox 冒頭参照）。素の pkgs.lima は使わない
  limactl = "${pkgs.callPackage ../../lib/lima-sandbox { }}/bin/limactl";
  # Ubuntu 26.04 の cloud image。Lima の templates/_images/ubuntu-lts.yaml の aarch64 と同じ release・digest
  image = pkgs.fetchurl {
    url = "https://cloud-images.ubuntu.com/releases/resolute/release-20260720/ubuntu-26.04-server-cloudimg-arm64.img";
    hash = "sha256-e88VnimtAAC/7ZxXh1kIw5Jo9e0SV/SVj6ap9fYO3VQ=";
  };
  limaYaml = pkgs.replaceVars ../home/file/sandbox-docker/lima.yaml { inherit image; };
  # docker-vm の DOCKER_CONFIG。docker-vm は Mac の docker CLI なので、コンテナと build の RUN に入るプロキシは
  # この config.json の proxies から決まる（VM 側の ~/.docker/config.json は読まれない）。値は lima.yaml の
  # param.egressProxy / egressNoProxy と同じ（tests/sandbox-docker.test.sh で突き合わせる）。
  # Mac の ~/.docker/config.json（OrbStack 用）は使わないので、buildx はそこの cli-plugins から探させる
  dockerConfig = pkgs.writeTextDir "config.json" (
    builtins.toJSON {
      proxies.default = {
        httpProxy = "http://192.168.5.2:3128";
        httpsProxy = "http://192.168.5.2:3128";
        noProxy = "localhost,127.0.0.1,::1";
      };
      cliPluginsExtraDirs = [ "${home}/.docker/cli-plugins" ];
    }
  );
in
lib.mkIf pkgs.stdenv.isDarwin {
  # sandbox 内から書き込み系も含めて使う docker。VM sandbox-docker の rootless docker に繋ぐ。
  # VM に mount しているのは /private/tmp/claude だけなので、repo のファイルは docker build の context や
  # docker cp で渡す（lima.yaml 冒頭参照）。OrbStack 側の読み取り専用は docker-sb（docker-proxy.nix）。
  # buildx は ~/.docker/buildx に状態を書くが sandbox 内からは書けないので、呼び出し側が BUILDX_CONFIG を
  # 決めていなければ sandbox の内外どちらからも書ける /private/tmp/claude 配下に向ける。
  # VM の外向き通信は vm-egress-proxy だけを通るので、DOCKER_CONFIG（dockerConfig）は常に差し替える
  home.packages = [
    (pkgs.writeShellScriptBin "docker-vm" ''
      export BUILDX_CONFIG="''${BUILDX_CONFIG:-/private/tmp/claude/docker-vm-buildx}"
      export DOCKER_CONFIG="${dockerConfig}"
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
