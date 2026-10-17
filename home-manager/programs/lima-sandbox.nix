{ lib, pkgs, ... }:
lib.mkIf pkgs.stdenv.isDarwin {
  # VM から Mac・LAN に届かないパッチ版 Lima（lib/lima-sandbox 冒頭参照）。
  # usernet が Mac の 127.0.0.1 と LAN に通すので、素の pkgs.lima は入れない
  home.packages = [ (pkgs.callPackage ../../lib/lima-sandbox { }) ];
}
