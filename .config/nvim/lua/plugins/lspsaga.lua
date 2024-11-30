local map = vim.api.nvim_set_keymap
map("n", "K", "<cmd>Lspsaga hover_doc<cr>", { silent = true, noremap = true })
map("n", "mh", "<cmd>Lspsaga diagnostic_jump_next<cr>", { silent = true, noremap = true })
map("n", "mk", "<cmd>Lspsaga diagnostic_jump_prev<cr>", { silent = true, noremap = true })
map("n", "mm", "<cmd>Lspsaga show_buf_diagnostics<cr>", { silent = true, noremap = true })
