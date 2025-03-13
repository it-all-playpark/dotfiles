{ pkgs }:

# 全プラットフォームで共通して使用するパッケージ
{
  commonPackages = with pkgs; [
    coreutils
    curl
    git
  ];
}

