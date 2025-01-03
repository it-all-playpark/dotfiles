-- Specify packer as a opt plugin
vim.cmd([[packadd packer.nvim]])

-- Auto install packer.nvim if not exists
local install_path = vim.fn.stdpath("data") .. "/site/pack/packer/opt/packer.nvim"
if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
  vim.fn.system({ "git", "clone", "https://github.com/wbthomason/packer.nvim", install_path })
end

return require("packer").startup(function()
  -- Packer can manage itself
  use({ "wbthomason/packer.nvim", opt = true })
  -- Add more plugins here
  use({
    "kylechui/nvim-surround",
    tag = "*",
  })
  use("nvim-tree/nvim-web-devicons")
  use("nvim-treesitter/nvim-treesitter")
  use("HiPhish/rainbow-delimiters.nvim")
  use({
    "ibhagwan/fzf-lua",
    requires = {
      "vijaymarupudi/nvim-fzf",
      "nvim-web-devicons", -- optional for icons
    },
  })
  use({
    "iamcco/markdown-preview.nvim",
    run = "cd app && npm install",
    setup = function()
      vim.g.mkdp_filetypes = { "markdown" }
    end,
    ft = { "markdown" },
  })

  use({
    "nvim-lualine/lualine.nvim",
    requires = { "nvim-web-devicons", opt = true },
  })
  use({
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    event = "InsertEnter",
    config = function()
      require("copilot").setup({
        suggestion = { enabled = false },
        panel = { enabled = false },
      })
    end,
  })
  use({
    "zbirenbaum/copilot-cmp",
    after = { "copilot.lua" },
    config = function()
      require("copilot_cmp").setup()
    end,
  })
  use("mfussenegger/nvim-dap")
  use({
    "glepnir/lspsaga.nvim",
    config = function()
      require("lspsaga").setup()
    end,
    requires = {
      { "nvim-web-devicons" },
      --Please make sure you install markdown and markdown_inline parser
      { "nvim-treesitter" },
    },
  })

  use({
    "williamboman/mason.nvim",
    run = ":MasonUpdate",
  })
  use("williamboman/mason-lspconfig.nvim")
  use({
    "neovim/nvim-lspconfig",
    run = ":MasonUpdate",
  })

  use("folke/trouble.nvim")
  use("hrsh7th/cmp-nvim-lsp")
  use("hrsh7th/cmp-buffer")
  use("hrsh7th/cmp-path")
  use("hrsh7th/cmp-cmdline")
  use("hrsh7th/nvim-cmp")

  -- For lua users.
  use("L3MON4D3/LuaSnip")
  use("saadparwaiz1/cmp_luasnip")

  use("nvim-lua/plenary.nvim")
  use("onsails/lspkind.nvim")
  use("stevearc/dressing.nvim")
  use({
    "akinsho/flutter-tools.nvim",
    requires = {
      "plenary.nvim",
      "dressing.nvim", -- optional for vim.ui.select
    },
  })

  use({
    "jose-elias-alvarez/null-ls.nvim",
    require("configs.null-ls").setup(),
    require("trouble").setup({
      icons = false,
      use_diagnostic_signs = true,
    }),
    requires = { "plenary.nvim" },
  })
  use({ "akinsho/bufferline.nvim", tag = "*", requires = "nvim-web-devicons" })
  use({ "MunifTanjim/nui.nvim" })
  use({
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    requires = {
      "plenary.nvim",
      "nvim-web-devicons", -- not strictly required, but recommended
      "nui.nvim",
      {
        "s1n7ax/nvim-window-picker",
        version = "2.*",
        config = function()
          require("window-picker").setup({
            filter_rules = {
              include_current_win = false,
              autoselect_one = true,
              -- filter using buffer options
              bo = {
                -- if the file type is one of following, the window will be ignored
                filetype = { "neo-tree", "neo-tree-popup", "notify" },
                -- if the buffer type is one of following, the window will be ignored
                buftype = { "terminal", "quickfix" },
              },
            },
          })
        end,
      },
    },
  })
  use({
    "numToStr/Comment.nvim",
    config = function()
      require("Comment").setup()
    end,
  })
  use({
    "phaazon/hop.nvim",
    branch = "v2", -- optional but strongly recommended
  })
  use({
    "Weissle/easy-action",
    requires = {
      {
        "kevinhwang91/promise-async",
        module = { "async" },
      },
    },
  })
  use({ "is0n/fm-nvim" })
  use({
    "yetone/avante.nvim",
    lazy = true,
    version = true, -- 常に最新の変更を取得
    build = "make", -- ビルドコマンド
    BUILD_FROM_SOURCE = true,
    requires = {
      "dressing.nvim",
      "plenary.nvim",
      "nui.nvim",
      "nvim-cmp", -- オプション依存関係
      "nvim-web-devicons",
      "copilot.lua",
      "HakonHarnes/img-clip.nvim",
      -- {
      "MeanderingProgrammer/render-markdown.nvim",
      -- ft = { "markdown", "Avante" },
      -- },
    },
    run = "make", -- Optional, only if yru want to use tiktoken_core to calculate tokens count
  })
end)
