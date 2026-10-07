# agent-vault: Infisical の credential proxy（https://github.com/Infisical/agent-vault）。
#
# Claude Code 本体の HTTPS_PROXY に置き、sandbox 内の git / gh の通信に GitHub の認証を付ける
# （home-manager/programs/agent-vault.nix 参照）。sandbox 内のコマンドは資格情報を持たない。
#
# release の prebuilt binary を版と hash で固定する（nixpkgs に無い。frontend を埋め込んだ binary なので
# source build は npm の build まで要る）。README 上 Preview 版で CLI・API が版ごとに変わるので、
# `nix flake update` では動かない形にしておき、更新は確かめてから行う:
#   1. release notes で server の flag（--password-stdin / --mitm-port）と services の YAML 形式の変更を確かめる
#   2. version を上げ、hash を release の checksums.txt の darwin_arm64 行（hex）から SRI に直して書き換える
#      （`nix store prefetch-file <url>` の hash と一致すること）
#   3. `nix build` して `agent-vault version` を確かめ、apply 後に launchd agent を再起動する
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "agent-vault";
  version = "0.40.0";

  src = fetchurl {
    url = "https://github.com/Infisical/agent-vault/releases/download/v${finalAttrs.version}/agent-vault_${finalAttrs.version}_darwin_arm64.tar.gz";
    hash = "sha256-NW5u4Eu4h7r0fxZ4Dg1EYBSGTg/Gxsl2wbSL+0FvIaA=";
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 agent-vault $out/bin/agent-vault
    runHook postInstall
  '';

  meta = {
    description = "HTTP credential proxy and vault for AI agents";
    homepage = "https://github.com/Infisical/agent-vault";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "agent-vault";
  };
})
