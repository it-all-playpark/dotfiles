# pglite-server: PGlite（WASM の Postgres）を TCP で公開する CLI。
#
# Claude Code の sandbox（Seatbelt）は SysV 共有メモリ（shmget）を塞ぐので、nix の postgresql は
# sandbox 内で起動できない（postmaster が interlock 用の SysV segment を必ず作る）。PGlite は Node の
# WASM で動くので sandbox 内で起動でき、127.0.0.1 の TCP だけで待ち受ける（allowLocalBinding の範囲）。
# dev-flow の実ブラウザ確認などで、使い捨ての DB を sandbox を弱めずに立てるために使う。
#
# 版は package.json / package-lock.json で固定する（npx / prisma dev のような実行時の取得をしない）。
# 更新: package.json の版を上げて `npm install --package-lock-only --ignore-scripts` → npmDepsHash を更新。
{
  lib,
  buildNpmPackage,
  nodejs,
  makeWrapper,
}:

buildNpmPackage {
  pname = "pglite-server";
  version = "0.2.11";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
    ];
  };

  npmDepsHash = "sha256-y8u6OlvfWxR3f1m229w3M6kAdwGpcIR3lu66EttEWzs=";
  dontNpmBuild = true;
  inherit nodejs;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/bin
    cp -r node_modules $out/lib/node_modules
    makeWrapper ${nodejs}/bin/node $out/bin/pglite-server \
      --add-flags $out/lib/node_modules/@electric-sql/pglite-socket/dist/scripts/server.js
    runHook postInstall
  '';

  meta = {
    description = "PGlite over TCP (Postgres that runs inside the Claude Code sandbox)";
    homepage = "https://github.com/electric-sql/pglite";
    license = lib.licenses.asl20;
    mainProgram = "pglite-server";
  };
}
