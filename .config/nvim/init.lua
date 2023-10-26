-- Specify that all required modules are in the `lua` directory
--vim.cmd([[set runtimepath=$VIMRUNTIME]])
--vim.cmd([[set runtimepath=/opt/homebrew/opt/neovim/share/nvim/runtime]])
vim.cmd([[set packpath=~/.local/share/nvim/site]])

-- Load settings
require("settings")

-- Load plugins
require("plugins")

-- Load key mappings
require("mappings")
