# OpenPost: SNS の予約投稿サーバーと、その CLI（https://github.com/getopenpost/openpost）。
#
# server は launchd agent で常駐させ、予約時刻に各 SNS へ投稿する（home-manager/programs/openpost.nix 参照）。
# cli は server の API を叩いて予約・編集・取消・確認をする。SNS には直接繋がない。
#
# release の prebuilt binary を版と hash で固定する（nixpkgs に無い。server は web の frontend を埋め込んだ
# 約 500MB の binary）。server と cli は同じ release から取り、版を揃える。更新は確かめてから行う:
#   1. release notes で server の設定（.env の変数名）と DB の migration の変更を確かめる
#   2. version を上げ、hash を `nix store prefetch-file <url>` の結果に書き換える
#      （cli は release の .sha256 と一致すること。server には checksum の配布が無い）
#   3. `nix build` して `openpost version` を確かめ、DB を退避してから apply する
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "7.41.6";

  mkBinary =
    {
      pname,
      asset,
      hash,
      description,
    }:
    stdenvNoCC.mkDerivation {
      inherit pname version;

      src = fetchurl {
        url = "https://github.com/getopenpost/openpost/releases/download/v${version}/${asset}";
        inherit hash;
      };

      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;

      installPhase = ''
        runHook preInstall
        install -Dm755 $src $out/bin/${pname}
        runHook postInstall
      '';

      meta = {
        inherit description;
        homepage = "https://github.com/getopenpost/openpost";
        license = lib.licenses.agpl3Only;
        platforms = [ "aarch64-darwin" ];
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        mainProgram = pname;
      };
    };
in
{
  server = mkBinary {
    pname = "openpost-server";
    asset = "openpost-server-darwin-arm64";
    hash = "sha256-xpolcQsZEqqzy+SVpKwJ1HQhV2WiwafFck/gOK1NZgE=";
    description = "Self-hosted social media scheduler (web app, API and worker)";
  };

  cli = mkBinary {
    pname = "openpost";
    asset = "openpost-cli-darwin-arm64";
    hash = "sha256-Dz3lEApGlECA+FK2YAfhd3DXbDqVj4DbpcpknTT0AP0=";
    description = "Command-line client for the OpenPost social media scheduler";
  };
}
