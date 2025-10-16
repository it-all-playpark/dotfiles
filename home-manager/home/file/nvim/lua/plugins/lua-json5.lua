return {
  "Joakker/lua-json5",
  build = "./install.sh",
  lazy = false, -- Must load immediately to be available for other plugins
  priority = 1000, -- Load before other plugins
  config = function()
    -- Add lua-json5 library path to package search paths
    local plugin_path = vim.fn.stdpath("data") .. "/lazy/lua-json5/lua"

    -- Add .lua file path
    package.path = package.path .. ";" .. plugin_path .. "/?.lua"

    -- Add .so/.dylib path for macOS and Linux
    package.cpath = package.cpath .. ";" .. plugin_path .. "/?.so"
    if vim.fn.has("mac") == 1 then
      package.cpath = package.cpath .. ";" .. plugin_path .. "/?.dylib"
      table.insert(vim._so_trails, "/?.dylib")
    end
  end,
}
