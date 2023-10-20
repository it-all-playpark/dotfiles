-- ~/.config/nvim/lua/plugins/fzf-lua.lua
local map = vim.api.nvim_set_keymap

-- require the fzf-lua plugin
require("fzf-lua").setup({
  live_grep_git = {
    cmd = "rg",
    args = '--color=never --no-heading --with-filename --line-number --column --smart-case --hidden -g "!.git/"',
  },
})

-- Set up some keybindings for fzf-lua actions
map("n", "<leader>F", "<cmd>FzfLua<CR>", { noremap = true, silent = true })
map("n", "<leader>pp", "<cmd>lua require('fzf-lua').files()<CR>", { noremap = true, silent = true })
map("n", "<leader>p/", "<cmd>lua require('fzf-lua').live_grep()<CR>", { noremap = true, silent = true })
map("n", "<leader>gg", "<cmd>lua require('fzf-lua').git_files()<CR>", { noremap = true, silent = true })
map("n", "<leader>gs", "<cmd>lua require('fzf-lua').git_status()<CR>", { noremap = true, silent = true })
map("n", "<leader>gb", "<cmd>lua require('fzf-lua').git_branches()<CR>", { noremap = true, silent = true })
map("n", "<leader>/", "<cmd>lua require('fzf-lua').blines()<CR>", { noremap = true, silent = true })
map("n", "<leader>bb", "<cmd>lua require('fzf-lua').buffers()<CR>", { noremap = true, silent = true })
map("n", "<leader>b/", "<cmd>lua require('fzf-lua').lines()<CR>", { noremap = true, silent = true })
