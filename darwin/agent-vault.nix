{ pkgs, username, ... }:
let
  # claude-code/bin/claude と home-manager/programs/agent-vault.nix の既定値と揃える
  home = "/Users/${username}";
  tokenFile = "${home}/.agent-vault/proxy-token";
  caBundle = "${home}/.local/state/agent-vault/ca-bundle.pem";
in
{
  # wrapper（claude-code/bin/claude）を通らない起動（Desktop の Code タブ・scheduled task・IDE）にも
  # agent-vault の env を渡す。wrapper と同じ判定で managed settings の drop-in
  # （/Library/Application Support/ClaudeCode/managed-settings.d/50-agent-vault.json）を書き直す。
  # /Library に書くので root（system ドメイン）で動かす。agent-vault が落ちたら StartInterval 以内に
  # proxy 抜きの内容へ戻し、proxy token・CA bundle の書き換えは WatchPaths で拾う。
  launchd.daemons.agent-vault-managed-env = {
    serviceConfig = {
      Label = "com.playpark.agent-vault-managed-env";
      ProgramArguments = [
        "${pkgs.bash}/bin/bash"
        "${../home-manager/home/file/agent-vault/agent-vault-managed-env.sh}"
      ];
      EnvironmentVariables = {
        PATH = "${pkgs.jq}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        AGENT_VAULT_PROXY_TOKEN_FILE = tokenFile;
        AGENT_VAULT_CA_BUNDLE = caBundle;
      };
      RunAtLoad = true;
      StartInterval = 30;
      WatchPaths = [
        tokenFile
        caBundle
      ];
      StandardOutPath = "/var/log/agent-vault-managed-env.log";
      StandardErrorPath = "/var/log/agent-vault-managed-env.log";
    };
  };
}
