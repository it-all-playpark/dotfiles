vim.opt.termguicolors = true
require("bufferline").setup({})
local bufferline = require("bufferline")
bufferline.setup({
	options = {
		style_preset = bufferline.style_preset.no_italic,
		-- or you can combine these e.g.
		style_preset = {
			bufferline.style_preset.no_italic,
			bufferline.style_preset.no_bold,
		},
	},
})
