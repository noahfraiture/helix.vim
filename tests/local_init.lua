-- Test the checkout without changing the user's config or downloading the plugin.
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)
require('helix').setup({auto_enable = true})
