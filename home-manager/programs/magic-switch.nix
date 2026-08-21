{
  config,
  lib,
  pkgs,
  ...
}:
let
  magicSwitch = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "magic-switch";
    version = "2.25.7";

    src = pkgs.fetchurl {
      url = "https://github.com/MegaManSec/magic-switch/releases/download/v${finalAttrs.version}/app.zip";
      hash = "sha256-vuDAotfATy0PCd9D5mIgOHrYAOUKjyHMvtm62BVF/2I=";
    };

    nativeBuildInputs = [ pkgs.unzip ];

    # zip の中身は "Magic Switch.app" ひとつ。ラッパーディレクトリの有無が
    # リリースごとに変わっても壊れないよう、installPhase 側で探す。
    sourceRoot = ".";

    dontConfigure = true;
    dontBuild = true;

    # 配布されているのは ad-hoc 署名済みのバイナリ。nix の darwin fixup (strip 等) を
    # 通すと署名が壊れ、TCC がアプリを別物として扱って権限が失われる。触らせない。
    dontFixup = true;

    installPhase = ''
      runHook preInstall

      app="$(find . -maxdepth 3 -type d -name 'Magic Switch.app' | head -n 1)"
      if [ -z "$app" ]; then
        echo "magic-switch: 'Magic Switch.app' がアーカイブ内に見つからない" >&2
        exit 1
      fi

      mkdir -p "$out/Applications"
      cp -R "$app" "$out/Applications/"

      runHook postInstall
    '';

    meta = {
      description = "Magic Keyboard / Trackpad / Mouse を 2 台の Mac 間で切り替える";
      homepage = "https://github.com/MegaManSec/magic-switch";
      license = lib.licenses.gpl3Only;
      platforms = lib.platforms.darwin;
    };
  });

  appName = "Magic Switch.app";
  appDest = "/Applications/${appName}";

  # コピー済みの世代を指す symlink。これと突き合わせて、変わっていなければ
  # 何もしない。起動中のメニューバーアプリを apply のたびに差し替えないため。
  stampLink = "${config.home.homeDirectory}/.local/state/magic-switch.store";
in
lib.mkIf pkgs.stdenv.isDarwin {
  # TCC (Bluetooth / ローカルネットワークの許可) はアプリのパスに紐づく。
  # nix store のパスは世代ごとに変わるうえ、symlink を置いても TCC が実体解決して
  # store パスを記録するため、許可が世代交代で切れる。uc-handoff.nix と同じ理由で
  # 実体コピーを固定パスに置く。
  #
  # /Applications は drwxrwxr-x root:admin なので、admin ユーザーなら sudo 不要。
  home.activation.magicSwitchApp = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # `exit` の影響をこのブロック内に閉じ込めるためのサブシェル。
    # home-manager は全 activation ブロックを 1 本のシェルスクリプトに連結する。
    # 素の exit は後続ブロックごと落とすうえ、終了コード 0 なので switch は
    # 成功として報告され気づけない。
    (
    src="${magicSwitch}/Applications/${appName}"
    dest="${appDest}"
    stamp="${stampLink}"
    # 入れ替え用の組み立て先。dest と同じボリュームでないと mv が rename にならず、
    # コピーへ落ちて中途半端な dest を作りうるので /Applications 直下に置く。
    staging="/Applications/.${appName}.new"

    if [ -d "$dest" ] && [ "$(${pkgs.coreutils}/bin/readlink "$stamp" 2>/dev/null)" = "${magicSwitch}" ]; then
      exit 0
    fi

    if [ ! -w /Applications ]; then
      echo "Warning: /Applications に書き込めません。Magic Switch の配置をスキップします。" >&2
      exit 0
    fi

    # 起動中のバンドルを消してはいけない。実体を失ったプロセスは終了要求に
    # まともに応答できなくなりうる。差し替えは次の apply に回し、この回は
    # 何も触らない。詳細と、2026-08-22 の強制再起動がこれとは無関係だった
    # 実測結果は docs/specs/2026-07-30-uc-handoff-design.md §13.7。
    if [ -d "$dest" ] && /usr/bin/pgrep -f "${appDest}/Contents/MacOS/" >/dev/null 2>&1; then
      echo "magic-switch: 起動中のため差し替えをスキップしました (${magicSwitch.version} は未適用)。" >&2
      echo "              メニューバーの Magic Switch を終了してから 'nix run .#update' を再実行してください。" >&2
      exit 0
    fi

    echo "magic-switch: ${appDest} を ${magicSwitch.version} に更新します" >&2

    # dest へ直接 cp すると、途中で失敗したときに壊れたバンドルがその場に残り、
    # stamp も無いまま起動不能なアプリだけが居座る。同じボリューム上で組み立てて
    # から rename で入れ替え、コピーが失敗しても既存の dest を壊さない。
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -rf "$staging"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/cp -R "$src" "$staging"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -rf "$dest"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv "$staging" "$dest"

    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$stamp")"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/ln -sfn "${magicSwitch}" "$stamp"

    # ad-hoc 署名なので、バージョンが変わると cdhash も変わる。TCC はアプリを
    # 別物として扱うため、Bluetooth とローカルネットワークの許可を取り直す必要がある。
    echo "magic-switch: アプリを差し替えました。" >&2
    echo "magic-switch: 権限が外れていたら、システム設定 > プライバシーとセキュリティ の" >&2
    echo "              Bluetooth とローカルネットワークで Magic Switch を許可し直してください。" >&2
    )
  '';
}
