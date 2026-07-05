{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "cca";
      runtimeInputs = with pkgs; [ jq fzf lsof zellij coreutils gnugrep gnused gawk procps ];
      text = builtins.readFile ../../scripts/cca;
      # 本体末尾の `if [ "${BASH_SOURCE[0]}" = "$0" ]` ガードにより cca_main が実行される
    })
  ];
}
