local M = {}

function M.setup()
  local lspconfig = require("lspconfig")
  local capabilities = require("cmp_nvim_lsp").default_capabilities()

  -- masonとmason-lspconfigの設定
  require("mason").setup()
  require("mason-lspconfig").setup()
  require("mason-lspconfig").setup_handlers({
    function(server_name)
      lspconfig[server_name].setup({
        on_attach = on_attach,
        capabilities = capabilities,
      })
    end,
  })
end

return M
