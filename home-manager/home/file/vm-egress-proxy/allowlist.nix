# vm-egress-proxy の許可リスト（1 行 1 パターン）を nix の評価時に作る。
# 出典は claude-code/settings.json の sandbox.network.allowedDomains と、VM 専用の追加分（vm-domains.txt）の和。
# settings.json にドメインを足せば、次の apply で VM の許可リストにも入る（手で 2 か所に書かない）。
# 引数の settingsJson / vmDomains はテスト（tests/vm-egress-proxy.test.sh）が差し替える
{
  lib,
  writeText,
  settingsJson ? ../../../../claude-code/settings.json,
  vmDomains ? ./vm-domains.txt,
}:
let
  sandboxDomains = (lib.importJSON settingsJson).sandbox.network.allowedDomains;
  # 「#」から行末まではコメント。空行は飛ばす
  vmOnly = lib.filter (d: d != "") (
    map (line: lib.trim (builtins.head (lib.splitString "#" line))) (
      lib.splitString "\n" (builtins.readFile vmDomains)
    )
  );
in
writeText "vm-egress-allowlist" (lib.concatLines (lib.unique (sandboxDomains ++ vmOnly)))
