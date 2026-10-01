{ lib, ... }:
{
  # Nixビルドユーザーグループの設定（GID不一致エラー対応）
  ids.gids.nixbld = 350;

  # NixデーモンやNixコマンドの設定
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ]; # 実験的機能を有効化
    trusted-users = [ "@admin" ]; # 管理者ユーザーを信頼
  };

  # Nix store の自動 GC（毎週日曜 5:00、mise upgrade の 04:30 と競合しない時間帯）
  # --delete-older-than 14d により直近 2 週間の generation は保持し、rollback 可能性を確保
  nix.gc = {
    automatic = true;
    interval = {
      Weekday = 0;
      Hour = 5;
      Minute = 0;
    };
    options = "--delete-older-than 14d";
  };

  # store 内の同一内容ファイルを hardlink 化してディスク使用量を削減
  nix.optimise.automatic = true;

  # Linux builder（macOS 上で linux 用 derivation を build する VM）
  # hermes-agent 用 Docker image (dockerTools.buildLayeredImage) は Linux 専用のため
  # darwin から build するには linux-builder が必須。
  # ephemeral = true は「起動のたびにディスクを初期化する」意味で、起動タイミングは変えない。
  # nix-darwin 標準の launchd daemon は RunAtLoad + KeepAlive で常駐するため、
  # 滅多に使わない VM が常時メモリを握る。下の launchd.daemons.linux-builder で
  # 常駐を外し、Linux 向け build の前後だけ手動で起動・停止する:
  #   sudo launchctl kickstart system/org.nixos.linux-builder   # 起動（ssh 待受まで数十秒）
  #   sudo launchctl kill TERM system/org.nixos.linux-builder   # 停止
  nix.linux-builder = {
    enable = true;
    ephemeral = true;
    maxJobs = 4;
    config = {
      virtualisation.cores = 6;
      virtualisation.darwin-builder = {
        memorySize = 6144;
        diskSize = 40960;
      };
      # qemu 11.1 以降、HVF は GICv2 エミュレーションを拒否して起動直後に落ちる
      # (qemu-system-aarch64: HVF does not support GICv2 emulation)。
      # nixpkgs の nixos/lib/qemu-common.nix が aarch64-darwin ホスト向けに
      # `-machine virt,gic-version=2,accel=hvf:tcg` を固定で渡しており NixOS
      # オプションからは差し替えられないため、コマンドラインの後段に置かれる
      # qemu.options で gic-version だけ上書きする
      # （qemu の -machine は merge_lists なので同じキーは後勝ちになる）。
      virtualisation.qemu.options = [ "-machine gic-version=3" ];
    };
  };

  # linux-builder モジュールが true で定義するため mkForce で上書きする
  launchd.daemons.linux-builder.serviceConfig = {
    RunAtLoad = lib.mkForce false;
    KeepAlive = lib.mkForce false;
  };
}
