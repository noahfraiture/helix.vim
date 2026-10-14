-- A deliberately small host double. This tests adapter logic, NOT Neovim itself.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local core = require('helix.engine')
local valid_utf8 = dofile('tests/support.lua').valid_utf8
local buffers, current, cursor, mode, locked = {}, 1, {1, 0}, 'n', false
local scheduled, events, listener, commands, notices, writes = {}, {}, nil, {}, {}, {}
local passed = 0
local function split(value)
  local lines, p = {}, 1
  while true do
    local a = value:find('\n', p, true)
    if not a then lines[#lines + 1] = value:sub(p); return lines end
    lines[#lines + 1], p = value:sub(p, a - 1), a + 1
  end
end
local function eq(a, b) assert(a == b, ('expected %q, got %q'):format(tostring(b), tostring(a))) end
local function fire(name, buf)
  for _, event in ipairs(events) do
    for _, eventname in ipairs(event.names) do if eventname == name then event.fn({buf = buf or current}) end end
  end
end
local function drain()
  local n = 0
  while #scheduled > 0 do
    n = n + 1; assert(n < 1000, 'non-terminating scheduling')
    local fn = table.remove(scheduled, 1); fn()
  end
end
local function options_table(defaults)
  return setmetatable({}, {__index = function(t, k) local out = core.copy(defaults); rawset(t, k, out); return out end})
end
vim = {
  api = {}, bo = options_table({buftype = '', modifiable = true, readonly = false}), b = options_table({}),
  log = {levels = {WARN = 2, ERROR = 3}}, fn = {}, ui = {},
  schedule = function(fn) scheduled[#scheduled + 1] = fn end,
  notify = function(msg) notices[#notices + 1] = msg end,
  split = split,
  tbl_extend = function(_, ...)
    local result = {}; for _, t in ipairs({...}) do for k, v in pairs(t) do result[k] = v end end; return result
  end,
  on_key = function(fn) listener = fn end,
  paste = function() return 'original' end,
}
local api = vim.api
api.nvim_create_namespace = function() return 1 end
api.nvim_buf_is_valid = function(buf) return buffers[buf] ~= nil end
api.nvim_buf_is_loaded = api.nvim_buf_is_valid
api.nvim_get_current_buf = function() return current end
api.nvim_win_get_cursor = function() return {cursor[1], cursor[2]} end
api.nvim_win_set_cursor = function(_, pos) cursor = {pos[1], pos[2]} end
api.nvim_buf_get_lines = function(buf) return split(buffers[buf].text) end
api.nvim_buf_clear_namespace = function(buf) buffers[buf].marks = {} end
api.nvim_buf_set_extmark = function(buf, _, row, col, opts)
  local lines = split(buffers[buf].text)
  assert(row >= 0 and row < #lines and col <= #lines[row + 1], 'extmark outside buffer')
  buffers[buf].marks[#buffers[buf].marks + 1] = {row, col, opts}
end
api.nvim_buf_set_text = function(buf, row, col, erow, ecol, lines)
  assert(not locked, 'attempted buffer write under textlock')
  local before = buffers[buf].text
  local a, b = core.offset(before, row, col), core.offset(before, erow, ecol)
  assert(core.boundary(before, a) == a and core.boundary(before, b) == b)
  local replacement = table.concat(lines, '\n')
  buffers[buf].text = before:sub(1, a) .. replacement .. before:sub(b + 1)
  buffers[buf].edits = buffers[buf].edits + 1
  assert(valid_utf8(buffers[buf].text), 'adapter produced invalid UTF-8')
end
api.nvim_set_hl = function() end
api.nvim_exec_autocmds = function() end
api.nvim_create_augroup = function() return 1 end
api.nvim_del_augroup_by_name = function() events = {} end
api.nvim_create_autocmd = function(names, opts)
  events[#events + 1] = {names = type(names) == 'table' and names or {names}, fn = opts.callback}
end
api.nvim_create_user_command = function(name, fn) commands[name] = fn end
api.nvim_del_user_command = function(name) commands[name] = nil end
vim.fn.has = function() return 1 end
vim.fn.mode = function() return mode end
vim.fn.keytrans = function(key) return key end
-- Only literal strings and ^ are needed to test matcher offset handling here.
vim.regex = function(pattern) if pattern == '[' then error('invalid regex') end; return {} end
vim.fn.matchstrpos = function(value, pattern, offset)
  if pattern == '^' then return offset == 0 and {'', 0, 0} or {'', -1, -1} end
  local a, b = value:find(pattern, offset + 1, true)
  return a and {value:sub(a, b), a - 1, b} or {'', -1, -1}
end
vim.ui.input = function(_, callback) callback('cat') end
local helix = require('helix')
local native_command = ''
local function key(input)
  local consumed
  locked = true
  if listener then consumed = listener(input, input) end
  locked = false
  if consumed == '' then return end
  if mode == 'c' then
    if input == '<CR>' then
      if native_command == 'w' then fire('BufWritePre'); writes[#writes + 1] = buffers[current].text end
      mode, native_command = 'n', ''
    elseif input == '<Esc>' then mode, native_command = 'n', ''
    else native_command = native_command .. input end
  elseif input == ':' then mode = 'c'; fire('CmdlineEnter') end
end
local function keys(...)
  for _, input in ipairs({...}) do key(input) end
  drain()
end
local function reset(value, col)
  helix.teardown()
  current, cursor, mode, locked = 1, {1, col or 0}, 'n', false
  buffers, scheduled, notices, writes = {[1] = {text = value, marks = {}, edits = 0}}, {}, {}, {}
  vim.bo = options_table({buftype = '', modifiable = true, readonly = false}); vim.b = options_table({})
  helix.setup({auto_enable = false}); assert(helix.enable())
end
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error(name .. ': ' .. tostring(err)) end
  passed = passed + 1; print('ok ' .. passed .. ' - ' .. name)
end

test('rapid insert handles colon and punctuation without command leakage', function()
  reset(''); keys('i', ':', '<lt>', '>', 'é', '🙂', '<Esc>')
  eq(buffers[1].text, ':<>é🙂'); eq(mode, 'n'); eq(buffers[1].edits, 1)
end)
test('mim works through the input listener and commits outside textlock', function()
  reset('outer([hello])', 8); keys('m', 'i', 'm', 'c', 'w', 'o', 'r', 'l', 'd', '<Esc>')
  eq(buffers[1].text, 'outer([world])')
end)
test('ma/ deletes a slash textobject', function()
  reset('let r = /abc/;', 10); keys('m', 'a', '/', 'd'); eq(buffers[1].text, 'let r = ;')
end)
test('ma/ finds path segments between adjacent slashes', function()
  reset('/usr/local/bin', 7); keys('m', 'a', '/', 'd'); eq(buffers[1].text, '/usrbin')
end)
test('colon can itself be a surround object', function()
  reset(':hello:', 3); keys('m', 'a', ':', 'd'); eq(buffers[1].text, '')
end)
test('multicursor edits, selection rendering and undo', function()
  reset('abc\ndef\nghi', 1); keys('C', 'C', 'i', 'X', 'Y', '<Esc>')
  eq(buffers[1].text, 'aXYbc\ndXYef\ngXYhi'); eq(#helix.get_state().selections, 3)
  assert(#buffers[1].marks >= 3)
  keys('u'); eq(buffers[1].text, 'abc\ndef\nghi'); keys('U'); eq(buffers[1].text, 'aXYbc\ndXYef\ngXYhi')
end)
test('pending text is flushed before a native write command', function()
  reset('abc'); keys('i', 'X', '<Esc>', ':', 'w', '<CR>'); eq(writes[1], 'Xabc')
end)
test('pending edits are committed on disable', function()
  reset('abc'); key('i'); key('X'); helix.disable(); drain(); eq(buffers[1].text, 'Xabc'); eq(helix.get_state(), nil)
end)
test('external edits form a safe history boundary', function()
  reset('abc'); keys('d'); buffers[1].text = 'external'; fire('TextChanged')
  keys('u'); eq(buffers[1].text, 'external')
end)
test('external edits cannot be overwritten by an old scheduled commit', function()
  reset('abc'); key('i'); key('X'); buffers[1].text = 'external'; drain()
  eq(buffers[1].text, 'external'); assert(#notices > 0)
end)
test('Neovim paste distributes multiline Unicode input to every cursor', function()
  reset('a\nb'); keys('C', 'i'); vim.paste({'é🙂', ''}, -1); keys('<Esc>')
  eq(buffers[1].text, 'é🙂\na\né🙂\nb')
end)
test('streamed paste and ordinary pending typing retain their order', function()
  reset('abc'); key('i'); key('X'); vim.paste({'Y'}, 1); vim.paste({'Z'}, 3); keys('<Esc>')
  eq(buffers[1].text, 'XYZabc'); keys('u'); eq(buffers[1].text, 'abc')
end)
test('Unicode diff boundaries do not split a shared character prefix', function()
  reset('á'); keys('r', 'â'); eq(buffers[1].text, 'â')
  reset('xá'); keys('l', 'r', 'â'); eq(buffers[1].text, 'xâ')
end)
test('regex match offsets are relative to the original selection', function()
  reset('cat dog cat'); keys('%'); assert(helix.select_regex('cat')); eq(#helix.get_state().selections, 2)
  keys('c', 'x', '<Esc>'); eq(buffers[1].text, 'x dog x')
end)
test('invalid regex leaves selections intact', function()
  reset('abc'); eq(helix.select_regex('['), false); eq(#helix.get_state().selections, 1)
end)
test('readonly buffers bypass the editing engine', function()
  reset('abc'); helix.disable(); vim.bo[1].readonly = true; eq(helix.enable(), false)
end)
test('buffer switching preserves per-buffer state', function()
  reset('abc'); keys('i', 'X', '<Esc>'); fire('BufLeave', 1)
  buffers[2], current, cursor = {text = 'def', marks = {}, edits = 0}, 2, {1, 0}
  helix.enable(); keys('d'); eq(buffers[2].text, 'ef')
  current = 1; fire('BufEnter', 1); eq(helix.get_state().text, 'Xabc')
end)
test('explicit disable survives auto-enable buffer reentry', function()
  reset('abc'); helix.setup({auto_enable = true}); helix.disable(); fire('BufEnter'); eq(helix.get_state(), nil)
end)
test('teardown restores the paste handler and removes commands', function()
  reset('abc'); helix.teardown(); eq(listener, nil); eq(commands.HelixEnable, nil); eq(vim.paste({}, -1), 'original')
end)
test('get_state returns independent selection tables', function()
  reset('abc'); local snap = helix.get_state(); snap.selections[1].start = 999; eq(helix.get_state().selections[1].start, 0)
end)
test('batched random input matches the engine without corrupting buffer bytes', function()
  local seed = 41
  local function random(n) seed = (seed * 48271) % 2147483647; return seed % n + 1 end
  local inputs = {'h','j','k','l','w','b','e','v','C','i','a','c','d','y','p','P','u','U',
    'r','m','(',')','/','%',';',',','<Esc>','<BS>','<CR>','é','🙂','X'}
  for _ = 1, 20 do
    reset('(aé🙂) /bc/\nxy\nz')
    local reference = core.new('(aé🙂) /bc/\nxy\nz')
    for _ = 1, 100 do
      local input = inputs[random(#inputs)]
      reference:input(input); key(input)
      if random(5) == 1 then drain(); eq(buffers[1].text, reference.text) end
      assert(#notices == 0, table.concat(notices, '\n'))
    end
    drain(); eq(buffers[1].text, reference.text)
  end
end)
print(passed .. ' simulated-host adapter tests passed (not real Neovim)')
