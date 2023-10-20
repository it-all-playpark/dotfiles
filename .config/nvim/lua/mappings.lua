-- fzf-lua
local map = vim.api.nvim_set_keymap
-- global
map("n", "<leader>l", "<cmd>bn<CR>", { noremap = true, silent = true })
map("n", "<leader>h", "<cmd>bp<CR>", { noremap = true, silent = true })
map("n", "<leader>k", "<cmd>b#<CR>", { noremap = true, silent = true })
map("n", "<leader>j", "<cmd>bd<CR>", { noremap = true, silent = true })
