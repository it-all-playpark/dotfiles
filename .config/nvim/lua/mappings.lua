local map = vim.api.nvim_set_keymap
-- global
-- ノーマルモードのキーマッピング
map("n", "h", "n", { noremap = true, silent = true })           -- next
map("n", "H", "N", { noremap = true, silent = true })           -- previous
map("n", "k", "h", { noremap = true, silent = true })           -- left
map("n", "t", "j", { noremap = true, silent = true })           -- down
map("n", "n", "k", { noremap = true, silent = true })           -- up
map("n", "s", "l", { noremap = true, silent = true })           -- right
-- ビジュアルモードのキーマッピング
map("v", "k", "h", { noremap = true, silent = true })           -- left
map("v", "t", "j", { noremap = true, silent = true })           -- down
map("v", "n", "k", { noremap = true, silent = true })           -- up
map("v", "s", "l", { noremap = true, silent = true })           -- right
-- インサートモードのカーソル移動
map("i", "<C-k>", "<Left>", { noremap = true, silent = true })  -- left
map("i", "<C-t>", "<Down>", { noremap = true, silent = true })  -- down
map("i", "<C-n>", "<Up>", { noremap = true, silent = true })    -- up
map("i", "<C-s>", "<Right>", { noremap = true, silent = true }) -- right

map("n", "<leader>k", "<cmd>bp<CR>", { noremap = true, silent = true })
map("n", "<leader>t", "<cmd>bd<CR>", { noremap = true, silent = true })
map("n", "<leader>s", "<cmd>bn<CR>", { noremap = true, silent = true })
map("n", "<leader>n", "<cmd>b#<CR>", { noremap = true, silent = true })
