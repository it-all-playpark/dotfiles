local M = {}

function M.setup()
	local null_ls = require("null-ls")
	local augroup = vim.api.nvim_create_augroup("LspFormatting", {})
	null_ls.setup({
		sources = {
			null_ls.builtins.formatting.fish_indent,
			null_ls.builtins.formatting.stylua,
			null_ls.builtins.formatting.prettierd,
			null_ls.builtins.formatting.rustfmt.with({
				prefer_local = "~/.local/share/mise/installs/rust/latest/bin/rustfmt",
			}),
			null_ls.builtins.diagnostics.eslint.with({
				prefer_local = "node_modules/.bin", --プロジェクトローカルがある場合はそれを利用
			}),
			null_ls.builtins.diagnostics.hadolint,
			null_ls.builtins.completion.spell,
			null_ls.builtins.completion.luasnip,
			null_ls.builtins.formatting.ast_grep,
		},
		on_attach = function(client, bufnr)
			if client.supports_method("textDocument/formatting") then
				vim.api.nvim_clear_autocmds({ group = augroup })
				vim.api.nvim_create_autocmd("BufWritePre", {
					group = augroup,
					buffer = bufnr,
					callback = function()
						-- on 0.8, you should use vim.lsp.buf.format({ bufnr = bufnr }) instead
						vim.lsp.buf.format({ async = false })
						-- vim.lsp.buf.formatting_sync()
					end,
				})
			end
		end,
		debug = false,
	})
end

return M
