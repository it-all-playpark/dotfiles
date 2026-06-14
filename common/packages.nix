{ pkgs }:

# 全プラットフォームで共通して使用するパッケージ
{
  commonPackages = with pkgs; [
    coreutils
    curl
    git
    mosh # 断続的接続・ローミングに強い SSH 代替。電車のトンネル等で回線が切れても再接続不要で復帰する
  ];
}
