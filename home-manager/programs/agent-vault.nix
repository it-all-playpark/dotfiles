{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
  agentVault = pkgs.callPackage ../../lib/agent-vault { };
in
lib.mkIf pkgs.stdenv.isDarwin {
  # vault の操作（credential・services・agent の登録）に使う CLI。server と同じ固定版
  home.packages = [ agentVault ];

  # Claude Code 本体の上流 proxy。sandbox 内の git / gh → Claude Code の proxy（allowedDomains）→
  # agent-vault（127.0.0.1:14322 で GitHub の認証を付与）→ GitHub の順に流れる。
  # 起動は agent-vault-server.sh（マスターパスワードを Keychain から読み --password-stdin で渡す）。
  # gui ドメインに載せるのは、Aqua セッションでしか login keychain の解除が効かないため。
  # CA bundle のパスは claude-code/bin/claude の AGENT_VAULT_CA_BUNDLE の既定値と揃える。
  launchd.agents.agent-vault = {
    enable = true;
    config = {
      Label = "com.playpark.agent-vault";
      ProgramArguments = [
        "${pkgs.bash}/bin/bash"
        "${../home/file/agent-vault/agent-vault-server.sh}"
      ];
      EnvironmentVariables = {
        HOME = home;
        AGENT_VAULT_BIN = "${agentVault}/bin/agent-vault";
        AGENT_VAULT_KEYCHAIN_SERVICE = "agent-vault";
        AGENT_VAULT_KEYCHAIN_ACCOUNT = "master-password";
        AGENT_VAULT_CA_BUNDLE = "${home}/.local/state/agent-vault/ca-bundle.pem";
        SYSTEM_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        # 既定は true（コマンド実行・機能利用のイベントを外部に送る）
        AGENT_VAULT_TELEMETRY = "false";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30;
      StandardOutPath = "${home}/.local/state/agent-vault.out.log";
      StandardErrorPath = "${home}/.local/state/agent-vault.err.log";
    };
  };
}
