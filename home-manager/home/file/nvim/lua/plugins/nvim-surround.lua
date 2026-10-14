return {
  "kylechui/nvim-surround",
  version = "*", -- Use for stability; omit to use `main` branch for the latest features
  event = "VeryLazy",
  -- v4 から setup() の keymaps は使えない。デフォルトのキーマップを止め、<Plug> に割り当てる
  -- (:h nvim-surround.migrating.v3_to_v4)。plugin/ が読まれる前に設定するため init で行う
  init = function()
    vim.g.nvim_surround_no_mappings = true
  end,
  config = function()
    require("nvim-surround").setup({})
    local keymaps = {
      { "i", "<C-g>m", "insert" },
      { "i", "<C-g>M", "insert-line" },
      { "n", "ym", "normal" },
      { "n", "ymm", "normal-cur" },
      { "n", "yM", "normal-line" },
      { "n", "yMM", "normal-cur-line" },
      { "x", "M", "visual" },
      { "x", "gM", "visual-line" },
      { "n", "dm", "delete" },
      { "n", "cm", "change" },
      { "n", "cM", "change-line" },
    }
    for _, k in ipairs(keymaps) do
      vim.keymap.set(k[1], k[2], "<Plug>(nvim-surround-" .. k[3] .. ")")
    end
  end,
}
