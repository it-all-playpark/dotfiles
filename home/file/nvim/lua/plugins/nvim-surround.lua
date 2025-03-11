return {
  "kylechui/nvim-surround",
  version = "*", -- Use for stability; omit to use `main` branch for the latest features
  event = "VeryLazy",
  config = function()
    require("nvim-surround").setup({
      -- Configuration here, or leave empty to use defaults
      keymaps = {
        inmert = "<C-g>m",
        inmert_line = "<C-g>M",
        normal = "ym",
        normal_cur = "ymm",
        normal_line = "yM",
        normal_cur_line = "yMM",
        vimual = "M",
        vimual_line = "gM",
        delete = "dm",
        change = "cm",
        change_line = "cM",
      },
    })
  end,
}
