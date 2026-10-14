-- Run the host double under Neovim's bundled Lua without retaining its fake vim.
local native_vim, native_print = vim, print
print = function(...)
  local values = {...}
  for i, value in ipairs(values) do io.write(i > 1 and '\t' or '', tostring(value)) end
  io.write('\n')
end
local ok, err = xpcall(function() dofile('tests/host_spec.lua') end, debug.traceback)
vim, print = native_vim, native_print
if not ok then error(err) end
