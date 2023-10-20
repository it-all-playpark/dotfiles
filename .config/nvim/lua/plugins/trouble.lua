local map = vim.api.nvim_set_keymap
map("n", "<leader>zz", "<cmd>TroubleToggle<cr>", { silent = true, noremap = true })
map("n", "<leader>zw", "<cmd>TroubleToggle workspace_diagnostics<cr>", { silent = true, noremap = true })
map("n", "<leader>zd", "<cmd>TroubleToggle document_diagnostics<cr>", { silent = true, noremap = true })
map("n", "<leader>zl", "<cmd>TroubleToggle loclist<cr>", { silent = true, noremap = true })
map("n", "<leader>zq", "<cmd>TroubleToggle quickfix<cr>", { silent = true, noremap = true })
map("n", "<leader>zr", "<cmd>TroubleToggle lsp_references<cr>", { silent = true, noremap = true })
