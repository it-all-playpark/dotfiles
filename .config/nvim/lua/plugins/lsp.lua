-- Keymapping for lsp
local map = vim.api.nvim_set_keymap
-- Jump to definition
map("n", "gd", "<cmd>lua vim.lsp.buf.definition()<cr>", { silent = true, noremap = true })
-- Open code actions using the default lsp UI, if you want to change this please see the plugins above
map("n", "ca", "<cmd>lua vim.lsp.buf.code_acction()<cr>", { silent = true, noremap = true })
-- Open code actions for the selected visual range
map("n", "ca", "<cmd>lua vim.lsp.buf.range_code_action()<cr>", { silent = true, noremap = true })
