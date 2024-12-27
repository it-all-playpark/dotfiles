local map = vim.api.nvim_set_keymap
-- global
-- ノーマルモードのキーマッピング
map("n", "h", "n", { noremap = true, silent = true })           -- next
map("n", "H", "N", { noremap = true, silent = true })           -- previous
map("n", "t", "h", { noremap = true, silent = true })           -- left
map("n", "n", "j", { noremap = true, silent = true })           -- down
map("n", "r", "k", { noremap = true, silent = true })           -- up
map("n", "s", "l", { noremap = true, silent = true })           -- right
map("n", "U", "<C-r>", { noremap = true, silent = true })       -- redo
-- ビジュアルモードのキーマッピング
map("v", "t", "h", { noremap = true, silent = true })           -- left
map("v", "n", "j", { noremap = true, silent = true })           -- down
map("v", "r", "k", { noremap = true, silent = true })           -- up
map("v", "s", "l", { noremap = true, silent = true })           -- right
-- インサートモードのカーソル移動
map("i", "<C-t>", "<Left>", { noremap = true, silent = true })  -- left
map("i", "<C-n>", "<Down>", { noremap = true, silent = true })  -- down
map("i", "<C-r>", "<Up>", { noremap = true, silent = true })    -- up
map("i", "<C-s>", "<Right>", { noremap = true, silent = true }) -- right

map("n", "<leader>t", "<cmd>bp<CR>", { noremap = true, silent = true })
map("n", "<leader>n", "<cmd>bd<CR>", { noremap = true, silent = true })
map("n", "<leader>s", "<cmd>bn<CR>", { noremap = true, silent = true })
map("n", "<leader>r", "<cmd>b#<CR>", { noremap = true, silent = true })

-------------
-- plugins --
-------------
-- fm-nvim
map("n", "<leader>g", ":Lazygit<CR>", { noremap = true, silent = true })

-- fzf-lua
map("n", "<leader>F", "<cmd>FzfLua<CR>", { noremap = true, silent = true })
map("n", "<leader>pp", "<cmd>lua require('fzf-lua').files()<CR>", { noremap = true, silent = true })
map("n", "<leader>p/", "<cmd>lua require('fzf-lua').live_grep()<CR>", { noremap = true, silent = true })
map("n", "<leader>/", "<cmd>lua require('fzf-lua').blines()<CR>", { noremap = true, silent = true })
map("n", "<leader>bb", "<cmd>lua require('fzf-lua').buffers()<CR>", { noremap = true, silent = true })
map("n", "<leader>b/", "<cmd>lua require('fzf-lua').lines()<CR>", { noremap = true, silent = true })

-- lsp
-- map("n", "gd", "<cmd>lua vim.lsp.buf.definition()<cr>", { silent = true, noremap = true, buffer = buffer })
map("n", "ca", "<cmd>lua vim.lsp.buf.code_acction()<cr>", { silent = true, noremap = true })
map("n", "ca", "<cmd>lua vim.lsp.buf.range_code_action()<cr>", { silent = true, noremap = true })

-- lspsaga
map("n", "gd", "<cmd>Lspsaga finder goto_definition<cr>", { silent = true, noremap = true })
map("n", "K", "<cmd>Lspsaga finder hover_doc<cr>", { silent = true, noremap = true })
map("n", "ms", "<cmd>Lspsaga diagnostic_jump_next<cr>", { silent = true, noremap = true })
map("n", "mt", "<cmd>Lspsaga diagnostic_jump_prev<cr>", { silent = true, noremap = true })
map("n", "mm", "<cmd>Lspsaga show_buf_diagnostics<cr>", { silent = true, noremap = true })

-- trouble
map("n", "<leader>zz", "<cmd>TroubleToggle<cr>", { silent = true, noremap = true })
map("n", "<leader>zw", "<cmd>TroubleToggle workspace_diagnostics<cr>", { silent = true, noremap = true })
map("n", "<leader>zd", "<cmd>TroubleToggle document_diagnostics<cr>", { silent = true, noremap = true })
map("n", "<leader>zl", "<cmd>TroubleToggle loclist<cr>", { silent = true, noremap = true })
map("n", "<leader>zq", "<cmd>TroubleToggle quickfix<cr>", { silent = true, noremap = true })
map("n", "<leader>zr", "<cmd>TroubleToggle lsp_references<cr>", { silent = true, noremap = true })

-- hop
map("n", "<leader>hl", ":HopLineMW<cr>", { silent = true, noremap = false })
map("n", "<leader>hc", ":HopChar2MW<cr>", { silent = true, noremap = false })

-- -- easy-action
-- map.set("n","<leader>e", "<cmd>BasicEasyAction<cr>", { silent=true, remap=false })
-- -- To insert something and jump back after you leave the insert mode
-- map.set("n","<leader>ei", function()
--   require("easy-action").base_easy_action("i", nil, "InsertLeave")
-- end, { silent=true, remap=false })
--
