-- Forcefully disable fzf-lua due to spawn.lua errors
-- Multiple layers of disabling to prevent LazyVim from loading it
return {
  "ibhagwan/fzf-lua",
  enabled = false,
  cond = false,
  optional = true,
  init = function()
    -- Prevent any initialization
    return false
  end,
}
