local M = {}

function M.setup()
  require("fzf-lua").setup({
    live_grep_git = {
      cmd = "rg",
      args = '--color=never --no-heading --with-filename --line-number --column --smart-case --hidden -g "!.git/"',
    },
  })
end

return M
