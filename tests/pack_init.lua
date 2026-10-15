-- Isolated vim.pack smoke-test config: nvim -i NONE -u tests/pack_init.lua tests/demo.txt
assert(vim.pack, 'This config requires Neovim 0.12+ for vim.pack')
vim.pack.add({
  { src = 'https://github.com/noahfraiture/helix.vim', version = 'main' },
})
require('helix').setup({auto_enable = true})
