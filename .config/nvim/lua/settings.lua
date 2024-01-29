-- オプション設定
vim.g.mapleader = " "
vim.o.clipboard = "unnamedplus"
vim.wo.number = true
vim.wo.cursorline = true
vim.wo.cursorcolumn = true
vim.cmd([[colorscheme desert]])

-- tab周りdafault
vim.opt.expandtab = true   -- タブをスペースに変換
vim.opt.tabstop = 2        -- タブの幅を2スペース
vim.opt.shiftwidth = 2     -- インデントレベルを2スペース
vim.opt.smartindent = true -- 自動インデントを有効

-- エイリアス
vim.api.nvim_exec(
  [[
    command! Filepath echo expand('%:p')
]],
  false
)

-- tabの各言語ごとの設定
local indentations = {
  { filetypes = { "python", "rust", "go" },                                        ts = 4, sw = 4, et = true },
  { filetypes = { "javascript", "typescript", "dart", "ruby", "lua", "markdown" }, ts = 2, sw = 2, et = true },
}

for _, indent in pairs(indentations) do
  for _, filetype in pairs(indent.filetypes) do
    vim.cmd(
      string.format(
        "autocmd FileType %s lua vim.api.nvim_buf_set_option(0, 'tabstop', %s); vim.api.nvim_buf_set_option(0, 'shiftwidth', %s); vim.api.nvim_buf_set_option(0, 'expandtab', %s)",
        filetype,
        indent.ts,
        indent.sw,
        tostring(indent.et)
      )
    )
  end
end
