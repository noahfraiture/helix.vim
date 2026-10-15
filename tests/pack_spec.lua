-- Isolated CI smoke test. Installs the actual GitHub repo through vim.pack.
assert(vim.pack, 'vim.pack smoke test requires Neovim 0.12+')
vim.pack.add({
  {src = 'https://github.com/noahfraiture/helix.vim', version = vim.env.GITHUB_SHA or 'main'},
}, {confirm = false})
local helix = require('helix')
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'outer([hello])'})
vim.api.nvim_win_set_cursor(0, {1, 8})
helix.setup({auto_enable = true})
assert(helix.get_state(), 'installed plugin did not enable')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('mimcworld<Esc>', true, false, true), 'xt', false)
vim.wait(20, function() return false end, 1)
assert(vim.api.nvim_get_current_line() == 'outer([world])', 'installed plugin failed textobject change')
helix.teardown()
print('vim.pack installation smoke test passed')
vim.cmd('qa!')
