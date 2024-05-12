local map = vim.keymap.set
local opts = { silent = true, remap = false }

-- trigger easy-action.
map("n", "<leader>e", "<cmd>BasicEasyAction<cr>", opts)

-- To insert something and jump back after you leave the insert mode
map("n", "<leader>ei", function()
  require("easy-action").base_easy_action("i", nil, "InsertLeave")
end, opts)
