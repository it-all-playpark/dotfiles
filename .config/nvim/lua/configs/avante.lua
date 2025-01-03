local M = {}

function M.setup()
  require("avante_lib").load()
  require("avante").setup({
    -- 必要なオプションをここに記述
    -- カスタム設定例
    provider = "copilot",
    -- provider = "claude",
    -- provider = "openai",
    auto_suggestions_provider = "copilot",
    behaviour = {
      auto_suggestions = true,
      auto_set_highlight_group = true,
      auto_set_keymaps = true,
      auto_apply_diff_after_generation = true,
      support_paste_from_clipboard = true,
    },
    windows = {
      position = "right",
      width = 30,
      sidebar_header = {
        align = "center",
        rounded = false,
      },
      ask = {
        floating = true,
        start_insert = true,
        border = "rounded",
      },
    },
    -- providers-setting
    claude = {
      model = "claude-3-5-sonnet-latest",
      -- model = "claude-3-5-sonnet-20240620", -- $3/$15, maxtokens=8000
      -- model = "claude-3-opus-20240229",  -- $15/$75
      -- model = "claude-3-haiku-20240307", -- $0.25/1.25
      max_tokens = 8000,
    },
    copilot = {
      endpoint = "https://api.githubcopilot.com",
      model = "gpt-4o-2024-08-06",
      -- model = "gpt-o1-mini",
      proxy = nil,         -- [protocol://]host[:port] Use this proxy
      allow_insecure = false, -- Allow insecure server connections
      timeout = 30000,     -- Timeout in milliseconds
      temperature = 0,
      max_tokens = 4096,
    },
    openai = {
      model = "gpt-4o", -- $2.5/$10
      -- model = "gpt-4o-mini", -- $0.15/$0.60
      max_tokens = 4096,
    },
    mappings = {
      diff = {
        ours = "co",
        theirs = "ct",
        all_theirs = "ca",
        both = "cb",
        cursor = "cc",
        next = "]x",
        prev = "[x",
      },
      suggestion = {
        accept = "<M-l>",
        next = "<M-]>",
        prev = "<M-[>",
        dismiss = "<C-]>",
      },
      jump = {
        next = "]]",
        prev = "[[",
      },
      submit = {
        normal = "<CR>",
        insert = "<C-s>",
      },
      -- NOTE: The following will be safely set by avante.nvim
      ask = "<leader>aa",
      edit = "<leader>ae",
      refresh = "<leader>ar",
      focus = "<leader>af",
      toggle = {
        default = "<leader>at",
        debug = "<leader>ad",
        hint = "<leader>ah",
        suggestion = "<leader>as",
        repomap = "<leader>aR",
      },
      sidebar = {
        apply_all = "A",
        apply_cursor = "a",
        switch_windows = "<Tab>",
        reverse_switch_windows = "<S-Tab>",
        remove_file = "d",
        add_file = "@",
      },
      files = {
        add_current = "<leader>ac", -- Add current buffer to selected files
      },
    },
  })

  -- 画像貼り付け用設定
  require("img-clip").setup({
    default = {
      embed_image_as_base64 = false,
      prompt_for_file_name = false,
      drag_and_drop = {
        insert_mode = true,
      },
      use_absolute_path = true, -- Windows用
    },
  })

  -- Markdownレンダリング設定
  require("render-markdown").setup({
    file_types = { "markdown", "Avante" },
  })
end

return M
