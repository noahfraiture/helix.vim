local core = require('helix.engine')
local M, api = {}, vim.api
local ns = api.nvim_create_namespace('helix.nvim')
local records, disabled = {}, {}
local options = {auto_enable = true, history_limit = 200}
local installed, original_paste, paste_hook, native_window
local cursor_windows, inherited_cursor_option = {}, nil
local flush, schedule_flush
local function text(buf) return table.concat(api.nvim_buf_get_lines(buf, 0, -1, true), '\n') end
local function eligible(buf)
  return api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == '' and vim.bo[buf].modifiable and not vim.bo[buf].readonly
end
local function cursor_offset(buf, value)
  if api.nvim_get_current_buf() ~= buf then return 0 end
  local cursor = api.nvim_win_get_cursor(0)
  return core.offset(value, cursor[1] - 1, cursor[2])
end
local function new_record(buf, value, register)
  local engine_options = vim.tbl_extend('force', options, {display_width = vim.fn.strdisplaywidth})
  local engine = core.new(value, cursor_offset(buf, value), engine_options)
  engine.register = register or {}
  return {engine = engine, committed = value, scheduled = false}
end
local function synchronize(buf, record)
  local value = text(buf)
  if value ~= record.committed then
    -- External edits form a new history boundary. Never overwrite them with stale text.
    local replacement = new_record(buf, value, record.engine.register)
    records[buf] = replacement
    return replacement
  end
  return record
end
local function restore_cursor_window(win)
  local saved = cursor_windows[win]
  if saved and api.nvim_win_is_valid(win) then
    local current = api.nvim_get_option_value('virtualedit', {win = win, scope = 'local'})
    if current == saved.applied then api.nvim_set_option_value('virtualedit', saved.previous, {win = win, scope = 'local'}) end
  end
  cursor_windows[win] = nil
end
local function restore_cursor_buffer(buf)
  local windows = {}
  for win, saved in pairs(cursor_windows) do if saved.buf == buf then windows[#windows + 1] = win end end
  for _, win in ipairs(windows) do restore_cursor_window(win) end
end
local function prepare_cursor_window(buf)
  local win = api.nvim_get_current_win()
  local local_value = api.nvim_get_option_value('virtualedit', {win = win, scope = 'local'})
  local saved = cursor_windows[win]
  if saved and (saved.buf ~= buf or local_value ~= saved.applied) then
    restore_cursor_window(win)
    local_value = api.nvim_get_option_value('virtualedit', {win = win, scope = 'local'})
  end
  if cursor_windows[win] then return end
  local effective = api.nvim_get_option_value('virtualedit', {win = win})
  local flags = ',' .. effective .. ','
  if flags:find(',all,', 1, true) or flags:find(',onemore,', 1, true) then return end
  local applied = effective == '' and 'onemore' or effective .. ',onemore'
  cursor_windows[win] = {buf = buf, previous = local_value, applied = applied}
  api.nvim_set_option_value('virtualedit', applied, {win = win, scope = 'local'})
end
local function render(buf, record)
  if not api.nvim_buf_is_valid(buf) then return end
  local engine = record.engine
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, s in ipairs(engine.selections) do
    local row, col = core.position(engine.text, s.start)
    local erow, ecol = core.position(engine.text, s.finish)
    if s.finish > s.start then
      api.nvim_buf_set_extmark(buf, ns, row, col, {end_row = erow, end_col = ecol,
        hl_group = 'HelixSelection', hl_eol = erow > row, priority = 150, strict = false})
    end
    local p = engine.mode == 'insert' and s.start or engine:head(s)
    local crow, ccol = core.position(engine.text, p)
    local nrow, ncol = core.position(engine.text, core.next(engine.text, p))
    local mark = {priority = 200, strict = false}
    local group = i == engine.primary and 'HelixPrimaryCursor' or 'HelixCursor'
    if crow == nrow and ncol > ccol then mark.end_row, mark.end_col, mark.hl_group = nrow, ncol, group
    else mark.virt_text, mark.virt_text_pos = {{' ', group}}, 'overlay' end
    -- The primary insertion point is drawn by Neovim itself. A second full-cell
    -- mark makes the next character look selected, especially with a bar cursor.
    if engine.mode ~= 'insert' or i ~= engine.primary then api.nvim_buf_set_extmark(buf, ns, crow, ccol, mark) end
  end
  if api.nvim_get_current_buf() == buf then
    -- Normal mode otherwise clamps an insertion point at EOL to the last
    -- character, leaving a native cursor beside the plugin's virtual cursor.
    prepare_cursor_window(buf)
    local s = engine.selections[engine.primary]
    local row, col = core.position(engine.text, engine.mode == 'insert' and s.start or engine:head(s))
    api.nvim_win_set_cursor(0, {row + 1, col})
    record.cursor = api.nvim_win_get_cursor(0)
  end
  vim.b[buf].helix_mode, vim.b[buf].helix_selections = engine.mode, #engine.selections
  if record.rendered_mode ~= engine.mode then
    record.rendered_mode = engine.mode
    api.nvim_exec_autocmds('User', {pattern = 'HelixModeChanged', modeline = false})
  end
end
-- Find the smallest byte-safe spanning change. Apply it in one buffer operation.
local function commit(buf, before, after)
  if before == after then return end
  local first, suffix = 0, 0
  while first < math.min(#before, #after) and before:byte(first + 1) == after:byte(first + 1) do first = first + 1 end
  first = core.boundary(before, first)
  while suffix < math.min(#before, #after) - first and before:byte(#before - suffix) == after:byte(#after - suffix) do suffix = suffix + 1 end
  -- A common UTF-8 suffix can begin midway through a character; shrink that suffix.
  while suffix > 0 and core.boundary(before, #before - suffix) ~= #before - suffix do suffix = suffix - 1 end
  local row, col = core.position(before, first)
  local erow, ecol = core.position(before, #before - suffix)
  api.nvim_buf_set_text(buf, row, col, erow, ecol,
    vim.split(after:sub(first + 1, #after - suffix), '\n', {plain = true}))
end
flush = function(buf)
  local record = records[buf]
  if not record or record.applying then return true end
  if not eligible(buf) then
    restore_cursor_buffer(buf)
    if api.nvim_buf_is_valid(buf) then
      records[buf] = new_record(buf, text(buf), record.engine.register)
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
    return false
  end
  local current = text(buf)
  if current ~= record.committed then
    local pending = record.engine.text ~= record.committed
    record = synchronize(buf, record)
    if pending then vim.notify('Helix: external buffer edit canceled uncommitted input', vim.log.levels.WARN) end
  end
  record.applying = true
  local ok, err = pcall(function()
    commit(buf, record.committed, record.engine.text)
    record.committed = record.engine.text
    render(buf, record)
  end)
  record.applying = false
  if not ok then return false, err end
  return true
end
schedule_flush = function(buf)
  local record = records[buf]
  if not record or record.scheduled then return end
  record.scheduled = true
  vim.schedule(function()
    if records[buf] ~= record then return end
    record.scheduled = false
    local ok, err = flush(buf)
    if not ok and err then
      records[buf] = new_record(buf, text(buf), record.engine.register)
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      vim.notify('Helix: input could not be applied: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end
local function consume(buf, key)
  local record = records[buf]
  if not record or not eligible(buf) then return end
  record = synchronize(buf, record)
  local ok, action = pcall(record.engine.input, record.engine, key)
  if not ok then
    records[buf] = new_record(buf, text(buf), record.engine.register)
    vim.schedule(function() vim.notify('Helix: ' .. tostring(action), vim.log.levels.ERROR) end)
    return
  end
  schedule_flush(buf)
  if action == 'select_regex' or action == 'split_regex' then
    vim.schedule(function()
      if records[buf] ~= record or api.nvim_get_current_buf() ~= buf then return end
      vim.ui.input({prompt = action == 'select_regex' and 'Select (Vim regex): ' or 'Split (Vim regex): '}, function(pattern)
        if pattern and records[buf] == record then M.select_regex(pattern, buf, action == 'split_regex') end
      end)
    end)
  end
end
function M.feed(key, buf)
  buf = buf or api.nvim_get_current_buf()
  consume(buf, key)
  local ok, err = flush(buf)
  if not ok and err then error(err) end
end
function M.select_regex(pattern, buf, split)
  buf = buf or api.nvim_get_current_buf()
  local record = records[buf]
  if not record then return false end
  local ok, err = pcall(vim.regex, pattern)
  if not ok then vim.notify('Helix: invalid regex: ' .. tostring(err), vim.log.levels.WARN); return false end
  record = synchronize(buf, record)
  record.engine:matches(function(value, offset)
    -- Keep the whole string: slicing would make ^ match again at every offset.
    -- The count argument makes start an offset into the original string;
    -- without it Vim treats start as a sliced-string beginning for ^ anchors.
    local result = vim.fn.matchstrpos(value, pattern, offset, 1)
    if result[2] >= 0 then return result[2], result[3] end
  end, split)
  flush(buf)
  return true
end
function M.enable(buf)
  buf = buf or api.nvim_get_current_buf()
  if not installed then M.setup({auto_enable = false}) end
  if not eligible(buf) then return false end
  disabled[buf] = nil
  if not records[buf] then records[buf] = new_record(buf, text(buf)) end
  flush(buf)
  return true
end
function M.disable(buf)
  buf = buf or api.nvim_get_current_buf()
  flush(buf)
  restore_cursor_buffer(buf)
  records[buf], disabled[buf], native_window = nil, true, nil
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.b[buf].helix_mode, vim.b[buf].helix_selections = nil, nil
  end
end
function M.get_state(buf)
  local record = records[buf or api.nvim_get_current_buf()]
  if not record then return nil end
  local engine = record.engine
  return {text = engine.text, selections = core.copy(engine.selections), primary = engine.primary,
    mode = engine.mode, pending = engine.pending, count = engine.count}
end
function M.statusline()
  local record = records[api.nvim_get_current_buf()]
  if not record then return '' end
  local e = record.engine
  return string.format('HELIX %s [%d] %s%s', e.mode:upper(), #e.selections, e.count, e.pending)
end
local function key_name(key)
  local name = vim.fn.keytrans(key)
  name = name:gsub('^<C%-(%u)>$', function(c) return '<C-' .. c:lower() .. '>' end)
  if name == '<lt>' then return '<' elseif name == '<Space>' then return ' ' end
  return name
end
local function typed_keys(typed)
  local translated, out, offset = vim.fn.keytrans(typed), {}, 0
  while offset < #translated do
    local finish
    if translated:sub(offset + 1, offset + 1) == '<' then finish = translated:find('>', offset + 2, true) end
    finish = finish or core.next(translated, offset)
    local name = translated:sub(offset + 1, finish)
    name = name:gsub('^<C%-(%u)>$', function(c) return '<C-' .. c:lower() .. '>' end)
    if name == '<lt>' then name = '<' elseif name == '<Space>' then name = ' ' end
    out[#out + 1], offset = name, finish
  end
  return out
end
function M.setup(opts)
  options = vim.tbl_extend('force', options, opts or {})
  assert(type(options.history_limit) == 'number' and options.history_limit >= 1
    and options.history_limit % 1 == 0, 'history_limit must be a positive integer')
  if not installed then
    assert(vim.fn.has('nvim-0.11') == 1, 'helix.nvim requires Neovim 0.11+')
    installed = true
    for name, target in pairs({HelixSelection = 'Visual', HelixCursor = 'Cursor', HelixPrimaryCursor = 'IncSearch'}) do
      api.nvim_set_hl(0, name, {default = true, link = target})
    end
    vim.on_key(function(key, typed)
      local buf = api.nvim_get_current_buf()
      if not records[buf] or not eligible(buf) or vim.fn.mode(1) ~= 'n' then return end
      local name = key_name(key)
      if native_window then
        -- Ctrl-W counts and Ctrl-W g-prefixed commands are native window commands.
        if name:match('^%d$') then return end
        if native_window == 'prefix' and name == 'g' then native_window = 'g'; return end
        native_window = nil; return
      end
      -- Mappings have already expanded. The first generated key carries the
      -- original typed input; the rest have typed == ''. Route that original
      -- input once so Neovim's default Y -> y$ cannot leak into engine insertion.
      if typed == '' then return '' end
      local inputs = typed_keys(typed or key)
      if #inputs == 1 then
        name = inputs[1]
        local engine = records[buf].engine
        if engine.mode ~= 'insert' and engine.pending == '' then
          if name == ':' then engine.count = ''; return end
          if name == '<C-w>' then engine.count = ''; native_window = 'prefix'; return end
          if name == '<C-l>' then return end
        end
      end
      -- Only pure Lua state changes happen under on_key's textlock. Unlike a
      -- deferred parser, this handles fast sequences and literal ':' correctly.
      for _, input in ipairs(inputs) do consume(buf, input) end
      return ''
    end, ns)
    original_paste = vim.paste
    paste_hook = function(lines, phase)
      local buf = api.nvim_get_current_buf()
      if not records[buf] or not eligible(buf) or vim.fn.mode(1) ~= 'n' then return original_paste(lines, phase) end
      local record = synchronize(buf, records[buf])
      local engine = record.engine
      if engine.mode ~= 'insert' then engine:insert(false, false) end
      engine:replace(table.concat(lines, '\n'), true)
      local ok, err = flush(buf)
      if not ok and err then schedule_flush(buf) end
      return true
    end
    vim.paste = paste_hook
    local group = api.nvim_create_augroup('HelixMode', {clear = true})
    api.nvim_create_autocmd('BufEnter', {group = group, callback = function(event)
      native_window = nil
      if options.auto_enable and not disabled[event.buf] then M.enable(event.buf) end
      if records[event.buf] then flush(event.buf) end
    end})
    api.nvim_create_autocmd({'BufLeave', 'BufWritePre', 'CmdlineEnter'}, {group = group, callback = function(event)
      local buf = event.buf ~= 0 and event.buf or api.nvim_get_current_buf()
      if records[buf] then local ok = flush(buf); if not ok then schedule_flush(buf) end end
      if event.event == 'BufLeave' then restore_cursor_window(api.nvim_get_current_win()) end
    end})
    api.nvim_create_autocmd('WinLeave', {group = group, callback = function()
      local win = api.nvim_get_current_win()
      inherited_cursor_option = cursor_windows[win]
      restore_cursor_window(win)
    end})
    api.nvim_create_autocmd('WinNew', {group = group, callback = function(event)
      -- Splits copy local options before WinLeave runs. Remove that inherited
      -- temporary value so the new window also restores the user's original.
      local source = api.nvim_get_current_win()
      local win = tonumber(event.match) or source
      local saved = cursor_windows[source] or inherited_cursor_option
      if saved and api.nvim_win_is_valid(win)
          and api.nvim_get_option_value('virtualedit', {win = win, scope = 'local'}) == saved.applied then
        api.nvim_set_option_value('virtualedit', saved.previous, {win = win, scope = 'local'})
      end
    end})
    api.nvim_create_autocmd('WinEnter', {group = group, callback = function()
      inherited_cursor_option = nil
      local buf = api.nvim_get_current_buf()
      if records[buf] then flush(buf) end
    end})
    api.nvim_create_autocmd('WinClosed', {group = group, callback = function(event)
      cursor_windows[tonumber(event.match)] = nil
    end})
    api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {group = group, callback = function(event)
      if records[event.buf] and not records[event.buf].applying then flush(event.buf) end
    end})
    api.nvim_create_autocmd('CursorMoved', {group = group, callback = function(event)
      local record = records[event.buf]
      if not record or record.applying or record.scheduled or record.engine.mode == 'insert' then return end
      local cursor = api.nvim_win_get_cursor(0)
      if record.cursor and (cursor[1] ~= record.cursor[1] or cursor[2] ~= record.cursor[2]) then
        record.engine:cursor(core.offset(record.engine.text, cursor[1] - 1, cursor[2]))
        render(event.buf, record)
      end
    end})
    api.nvim_create_autocmd('BufWipeout', {group = group, callback = function(event)
      restore_cursor_buffer(event.buf)
      records[event.buf], disabled[event.buf] = nil, nil
    end})
    for name, callback in pairs({HelixEnable = M.enable, HelixDisable = M.disable,
      HelixToggle = function() if records[api.nvim_get_current_buf()] then M.disable() else M.enable() end end}) do
      api.nvim_create_user_command(name, function() callback() end, {})
    end
    api.nvim_create_user_command('HelixSelect', function(args) M.select_regex(args.args) end, {nargs = 1})
    api.nvim_create_user_command('HelixSplit', function(args) M.select_regex(args.args, nil, true) end, {nargs = 1})
  end
  if options.auto_enable and not disabled[api.nvim_get_current_buf()] then M.enable() end
end
function M.teardown()
  local buffers = {}
  for buf in pairs(records) do buffers[#buffers + 1] = buf end
  for _, buf in ipairs(buffers) do M.disable(buf) end
  vim.on_key(nil, ns)
  if vim.paste == paste_hook then vim.paste = original_paste end
  if installed then
    api.nvim_del_augroup_by_name('HelixMode')
    for _, name in ipairs({'HelixEnable', 'HelixDisable', 'HelixToggle', 'HelixSelect', 'HelixSplit'}) do api.nvim_del_user_command(name) end
  end
  local windows = {}
  for win in pairs(cursor_windows) do windows[#windows + 1] = win end
  for _, win in ipairs(windows) do restore_cursor_window(win) end
  records, disabled, installed, native_window, inherited_cursor_option = {}, {}, false, nil, nil
  options = {auto_enable = true, history_limit = 200}
end
return M
