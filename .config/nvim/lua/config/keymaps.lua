-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
--
local map = vim.api.nvim_set_keymap
local opt = { noremap = true, silent = true }
-- global
-- ノーマルモードのキーマッピング
map("n", "h", "n", opt) -- next
map("n", "H", "N", opt) -- previous
map("n", "t", "h", opt) -- left
map("n", "n", "j", opt) -- down
map("n", "r", "k", opt) -- up
map("n", "s", "l", opt) -- right
map("n", "U", "<C-r>", opt) -- redo
-- ビジュアルモードのキーマッピング
map("v", "t", "h", opt) -- left
map("v", "n", "j", opt) -- down
map("v", "r", "k", opt) -- up
map("v", "s", "l", opt) -- right
-- インサートモードのカーソル移動
map("i", "<C-t>", "<Left>", opt) -- left
map("i", "<C-n>", "<Down>", opt) -- down
map("i", "<C-r>", "<Up>", opt) -- up
map("i", "<C-s>", "<Right>", opt) -- right

map("n", "<leader>t", "<cmd>bp<CR>", opt)
map("n", "<leader>n", "<cmd>bd<CR>", opt)
map("n", "<leader>s", "<cmd>bn<CR>", opt)
map("n", "<leader>r", "<cmd>b#<CR>", opt)

-------------
-- plugins --
-------------
-- -- fm-nvim
-- map("n", "<leader>g", ":Lazygit<CR>", opt)
--
-- -- fzf-lua
-- map("n", "<leader>F", "<cmd>FzfLua<CR>", opt)
-- map("n", "<leader>pp", "<cmd>lua require('fzf-lua').files()<CR>", opt)
-- map("n", "<leader>p/", "<cmd>lua require('fzf-lua').live_grep()<CR>", opt)
-- map("n", "<leader>/", "<cmd>lua require('fzf-lua').blines()<CR>", opt)
-- map("n", "<leader>bb", "<cmd>lua require('fzf-lua').buffers()<CR>", opt)
-- map("n", "<leader>b/", "<cmd>lua require('fzf-lua').lines()<CR>", opt)
--
-- -- lsp
-- -- map("n", "gd", "<cmd>lua vim.lsp.buf.definition()<cr>", { silent = true, noremap = true, buffer = buffer })
-- map("n", "ca", "<cmd>lua vim.lsp.buf.code_acction()<cr>", opt)
-- map("n", "ca", "<cmd>lua vim.lsp.buf.range_code_action()<cr>", opt)
--
-- -- lspsaga
-- map("n", "gd", "<cmd>Lspsaga finder goto_definition<cr>", opt)
-- map("n", "K", "<cmd>Lspsaga finder hover_doc<cr>", opt)
-- map("n", "ms", "<cmd>Lspsaga diagnostic_jump_next<cr>", opt)
-- map("n", "mt", "<cmd>Lspsaga diagnostic_jump_prev<cr>", opt)
-- map("n", "mm", "<cmd>Lspsaga show_buf_diagnostics<cr>", opt)
--
-- -- trouble
-- map("n", "<leader>zz", "<cmd>TroubleToggle<cr>", opt)
-- map("n", "<leader>zw", "<cmd>TroubleToggle workspace_diagnostics<cr>", opt)
-- map("n", "<leader>zd", "<cmd>TroubleToggle document_diagnostics<cr>", opt)
-- map("n", "<leader>zl", "<cmd>TroubleToggle loclist<cr>", opt)
-- map("n", "<leader>zq", "<cmd>TroubleToggle quickfix<cr>", opt)
-- map("n", "<leader>zr", "<cmd>TroubleToggle lsp_references<cr>", opt)
--
-- -- -- hop
-- map("n", "<leader>hl", ":HopLineMW<cr>", opt)
-- map("n", "<leader>hc", ":HopChar2MW<cr>", opt)
--
-- neo-tree
map("n", "<Leader>e", ":Neotree focus toggle<CR>", opt)
map("n", "<Leader>w", "<C-w>w", opt)
--
-- -- flash
-- map("n", "j", function()
--   require("flash").jump()
-- end, opt)
-- -- { "S", mode = { "n", "x", "o" }, function() require("flash").treesitter() end, desc = "Flash Treesitter" },
-- -- { "r", mode = "o", function() require("flash").remote() end, desc = "Remote Flash" },
-- -- { "R", mode = { "o", "x" }, function() require("flash").treesitter_search() end, desc = "Treesitter Search" },
-- -- { "<c-s>", mode = { "c" }, function() require("flash").toggle() end, desc = "Toggle Flash Search" },

-- -- easy-action
-- map.set("n","<leader>e", "<cmd>BasicEasyAction<cr>", { silent=true, remap=false })
-- -- To insert something and jump back after you leave the insert mode
-- map.set("n","<leader>ei", function()
--   require("easy-action").base_easy_action("i", nil, "InsertLeave")
-- end, { silent=true, remap=false })
--
