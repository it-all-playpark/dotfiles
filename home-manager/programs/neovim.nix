{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    vimAlias = true;
    withPython3 = true;
    withRuby = true;
    # nvim-treesitter (main) は :TSUpdate で parser を tree-sitter CLI でビルドする。
    # 無いとクエリだけ更新されて古い parser と食い違い、"Invalid node type" になる
    extraPackages = [ pkgs.tree-sitter ];
  };
}
