local M = {}

function M.setup()
  require("nvim-treesitter.configs").setup({
    rainbow = {
      enable = true,
      -- list of languages you want to disable the plugin for
      disable = { "jsx", "cpp" },
      -- Which query to use for finding delimiters
      query = "rainbow-parens",
      -- Highlight the entire buffer all at once
      strategy = require("rainbow-delimiters").strategy.global,
    },
  })
end

return M
