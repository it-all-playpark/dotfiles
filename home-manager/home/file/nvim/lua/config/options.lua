-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Force LazyVim to use telescope instead of fzf-lua
vim.g.lazyvim_picker = "telescope"

-- クリップボード: mosh 越しでも手元の端末(ghostty)へ OSC52 で転送する。
-- neovim/LazyVim は $SSH_TTY でリモート判定して OSC52 を有効化するが、mosh は
-- SSH_TTY をセットしないため pbcopy(=リモートホストのクリップボード)に
-- フォールバックして手元に届かない。SSH_TTY に依存せず常に OSC52 を使う。
vim.opt.clipboard = "unnamedplus"

local osc52 = require("vim.ui.clipboard.osc52")
vim.g.clipboard = {
  name = "OSC 52",
  copy = {
    ["+"] = osc52.copy("+"),
    ["*"] = osc52.copy("*"),
  },
  -- OSC52 のペースト(端末への問い合わせ)は mosh 越しで応答が返らずハングし得るので、
  -- nvim 内のレジスタを返してローカルなペーストだけ成立させる。
  paste = {
    ["+"] = function()
      return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
    end,
    ["*"] = function()
      return { vim.fn.split(vim.fn.getreg(""), "\n"), vim.fn.getregtype("") }
    end,
  },
}
