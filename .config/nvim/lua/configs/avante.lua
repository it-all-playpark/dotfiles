local M = {}

function M.setup()
  require("avante_lib").load()
  require("avante").setup({
    -- 必要なオプションをここに記述
    default = {
      -- カスタム設定例
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
