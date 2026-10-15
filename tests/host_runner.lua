-- Run the host double under Neovim's bundled Lua without retaining its fake vim.
local native_vim, native_print = vim, print
-- The host double replaces _G.vim. Neovim's runtime module loader reads that
-- global, so resolve the plugin explicitly instead of invoking that loader.
local previous_preload = package.preload.helix
package.preload.helix = function() return dofile('lua/helix/init.lua') end
print = function(...)
  local values = {...}
  for i, value in ipairs(values) do io.write(i > 1 and '\t' or '', tostring(value)) end
  io.write('\n')
end
local ok, err = xpcall(function() dofile('tests/host_spec.lua') end, debug.traceback)
vim, print = native_vim, native_print
package.preload.helix = previous_preload
if not ok then error(err) end
