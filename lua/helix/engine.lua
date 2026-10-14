-- Selection-first editing. All positions are zero-based half-open UTF-8 byte ranges.
local M, Engine = {}, {}
Engine.__index = Engine
local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = type(v) == 'table' and copy(v) or v end
  return out
end
M.copy = copy
local indexed_text, line_starts
local function index(text)
  if indexed_text == text then return line_starts end
  indexed_text, line_starts = text, {0}
  local p = 1
  while true do
    local newline = text:find('\n', p, true)
    if not newline then break end
    line_starts[#line_starts + 1], p = newline, newline + 1
  end
  return line_starts
end
local function continuation(b) return b and b >= 128 and b < 192 end
function M.next(text, p)
  p = math.min(#text, p + 1)
  while p < #text and continuation(text:byte(p + 1)) do p = p + 1 end
  return p
end
function M.prev(text, p)
  p = math.max(0, p - 1)
  while p > 0 and continuation(text:byte(p + 1)) do p = p - 1 end
  return p
end
function M.boundary(text, p)
  p = math.min(#text, math.max(0, p))
  while p > 0 and continuation(text:byte(p + 1)) do p = p - 1 end
  return p
end
function M.position(text, p)
  p = math.min(#text, math.max(0, p))
  local starts = index(text)
  local left, right = 1, #starts
  while left < right do
    local middle = math.floor((left + right + 1) / 2)
    if starts[middle] <= p then left = middle else right = middle - 1 end
  end
  return left - 1, p - starts[left]
end
function M.offset(text, row, col)
  local starts = index(text)
  row = math.max(0, row)
  local start = starts[row + 1]
  if not start then return #text end
  local finish = starts[row + 2] and starts[row + 2] - 1 or #text
  return M.boundary(text, math.min(start + math.max(0, col), finish))
end
local function line_bounds(text, p)
  local row = M.position(text, p)
  local first = M.offset(text, row, 0)
  local newline = text:find('\n', first + 1, true)
  return first, newline and newline - 1 or #text, newline or #text
end
local function class(text, p, long)
  local c = text:sub(p + 1, M.next(text, p))
  if c == '' or c:match('%s') then return 0 end
  if long or #c > 1 or c:match('[%w_]') then return 1 end
  return 2
end
function M.new(text, position, opts)
  opts = opts or {}
  local self = setmetatable({text = text or '', selections = {}, primary = 1,
    mode = 'normal', pending = '', count = '', register = {}, undo_stack = {}, redo_stack = {},
    history_limit = opts.history_limit or 200, display_width = opts.display_width}, Engine)
  self:cursor(position or 0)
  return self
end
function Engine:cursor(p)
  p = M.boundary(self.text, p)
  self.selections, self.primary = {{start = p, finish = M.next(self.text, p)}}, 1
end
function Engine:head(s)
  return s.backward and s.start or (s.finish > s.start and M.prev(self.text, s.finish) or s.start)
end
function Engine:normalize()
  local primary = self.selections[self.primary]
  table.sort(self.selections, function(a, b)
    if a.start == b.start then return a.finish < b.finish end
    return a.start < b.start
  end)
  local out = {}
  for _, s in ipairs(self.selections) do
    s.start, s.finish = M.boundary(self.text, s.start), M.boundary(self.text, s.finish)
    s.finish = math.max(s.start, s.finish)
    local last = out[#out]
    if last and (s.start < last.finish or s.start == last.start) then
      last.finish = math.max(last.finish, s.finish)
      if primary == s then primary = last end
    else out[#out + 1] = s end
  end
  if #out == 0 then out = {{start = 0, finish = M.next(self.text, 0)}} end
  self.selections, self.primary = out, 1
  for i, s in ipairs(out) do if primary == s then self.primary = i end end
end
function Engine:snapshot()
  return {text = self.text, selections = copy(self.selections), primary = self.primary}
end
function Engine:checkpoint(snap)
  local stack = self.undo_stack
  stack[#stack + 1] = snap or self:snapshot()
  if #stack > self.history_limit then table.remove(stack, 1) end
  self.redo_stack = {}
end
function Engine:history(redo)
  local source = redo and self.redo_stack or self.undo_stack
  if #source == 0 then return end
  local target = redo and self.undo_stack or self.redo_stack
  target[#target + 1] = self:snapshot()
  local snap = table.remove(source)
  self.text, self.selections, self.primary = snap.text, snap.selections, snap.primary
  self.mode, self.pending, self.count, self.insert_before = 'normal', '', '', nil
end
-- Edits are computed against one snapshot, sorted once, and applied together.
-- Optional ranges permit paste/backspace without mutating the undo selections.
function Engine:replace(values, insertion, ranges)
  self:normalize()
  local edits = {}
  for i, s in ipairs(ranges or self.selections) do
    edits[#edits + 1] = {start = s.start, finish = s.finish,
      value = type(values) == 'table' and (values[i] or values[1] or '') or values,
      primary = i == self.primary}
  end
  table.sort(edits, function(a, b) return a.start < b.start end)
  local combined = {}
  for _, e in ipairs(edits) do
    local last = combined[#combined]
    if last and (e.start < last.finish or e.start == last.start) then
      -- Deletions may overlap after adjacent insertion points backspace together.
      assert(e.value == '' and last.value == '', 'overlapping replacement ranges')
      last.finish, last.primary = math.max(last.finish, e.finish), last.primary or e.primary
    else combined[#combined + 1] = e end
  end
  local chunks, sels, previous, delta, primary = {}, {}, 0, 0, 1
  for i, e in ipairs(combined) do
    chunks[#chunks + 1] = self.text:sub(previous + 1, e.start)
    chunks[#chunks + 1] = e.value
    local p = e.start + delta
    sels[i] = insertion and {start = p + #e.value, finish = p + #e.value}
      or {start = p, finish = p + #e.value}
    if e.primary then primary = i end
    delta, previous = delta + #e.value - (e.finish - e.start), e.finish
  end
  chunks[#chunks + 1] = self.text:sub(previous + 1)
  local text = table.concat(chunks)
  if text ~= self.text then
    if self.mode == 'insert' then
      if self.insert_before then self:checkpoint(self.insert_before); self.insert_before = nil end
    else self:checkpoint() end
  end
  self.text, self.selections, self.primary = text, sels, primary
  if not insertion then
    for _, s in ipairs(sels) do if s.start == s.finish then s.finish = M.next(text, s.start) end end
  end
  self:normalize()
end
function Engine:yank()
  self.register = {}
  for i, s in ipairs(self.selections) do self.register[i] = self.text:sub(s.start + 1, s.finish) end
end
function Engine:paste_values()
  if #self.register == #self.selections then return self.register end
  return table.concat(self.register, '\n')
end
function Engine:insert(after, change)
  self.insert_before = self:snapshot()
  self.mode = 'insert'
  if change then self:yank(); self:replace('', true)
  else
    for _, s in ipairs(self.selections) do
      local p = after and s.finish or s.start
      s.start, s.finish, s.backward, s.goal = p, p, nil, nil
    end
    self:normalize()
  end
end
function Engine:backspace(forward, word)
  local ranges = {}
  for i, s in ipairs(self.selections) do
    local a, b = s.start, s.start
    if forward then b = M.next(self.text, b)
    else
      a = M.prev(self.text, a)
      if word then
        while a > 0 and class(self.text, a) == 0 do a = M.prev(self.text, a) end
        local cls = class(self.text, a)
        while a > 0 and class(self.text, M.prev(self.text, a)) == cls do a = M.prev(self.text, a) end
      end
    end
    ranges[i] = {start = a, finish = b}
  end
  self:replace('', true, ranges)
end
function Engine:column(p)
  local first = line_bounds(self.text, p)
  if self.display_width then return self.display_width(self.text:sub(first + 1, p)) end
  local col = 0
  while first < p do first, col = M.next(self.text, first), col + 1 end
  return col
end
function Engine:offset_column(row, column)
  local first = M.offset(self.text, row, 0)
  local _, last = line_bounds(self.text, first)
  local p, col = first, 0
  while p < last do
    local nextp = M.next(self.text, p)
    local nextcol = self.display_width and self.display_width(self.text:sub(first + 1, nextp)) or col + 1
    if nextcol > column then break end
    p, col = nextp, nextcol
  end
  return p
end
function Engine:move(key, count)
  local text = self.text
  for _, s in ipairs(self.selections) do
    local original, p = self:head(s), self:head(s)
    local goal = s.goal
    for _ = 1, count or 1 do
      if key == 'h' then p = M.prev(text, p)
      elseif key == 'l' then p = M.next(text, p)
      elseif key == 'j' or key == 'k' then
        local row = M.position(text, p)
        goal = goal or self:column(p)
        local targetrow = row + (key == 'j' and 1 or -1)
        if targetrow >= 0 then
          local target = self:offset_column(targetrow, goal)
          if M.position(text, target) == targetrow then p = target end
        end
      elseif key == 'w' or key == 'W' then
        local cls = class(text, p, key == 'W')
        while p < #text and class(text, p, key == 'W') == cls do p = M.next(text, p) end
        while p < #text and class(text, p, key == 'W') == 0 do p = M.next(text, p) end
      elseif key == 'b' or key == 'B' then
        p = M.prev(text, p)
        while p > 0 and class(text, p, key == 'B') == 0 do p = M.prev(text, p) end
        local cls = class(text, p, key == 'B')
        while p > 0 and class(text, M.prev(text, p), key == 'B') == cls do p = M.prev(text, p) end
      elseif key == 'e' or key == 'E' then
        p = M.next(text, p)
        while p < #text and class(text, p, key == 'E') == 0 do p = M.next(text, p) end
        local cls = class(text, p, key == 'E')
        while p < #text and class(text, M.next(text, p), key == 'E') == cls do p = M.next(text, p) end
      elseif key == 'gh' or key == '<Home>' then p = line_bounds(text, p)
      elseif key == 'gl' or key == '<End>' then
        local a, b = line_bounds(text, p); p = b > a and M.prev(text, b) or a
      elseif key == 'gg' then p = 0
      elseif key == 'ge' then p = M.prev(text, #text) end
    end
    local extend, word = self.mode == 'select', key:match('^[wWbBeE]$')
    if extend or word then
      local anchor = extend and (s.backward and M.prev(text, s.finish) or s.start) or original
      local finish = M.next(text, math.max(anchor, p))
      -- Helix's next-word-start range stops before the next word.
      if not extend and (key == 'w' or key == 'W') and p > original then finish = p end
      s.start, s.finish, s.backward = math.min(anchor, p), finish, p < anchor or nil
    else s.start, s.finish, s.backward = p, M.next(text, p), nil end
    s.goal = (key == 'j' or key == 'k') and goal or nil
  end
  self:normalize()
end
local opens = {['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>'}
local closes = {[')'] = '(', [']'] = '[', ['}'] = '{', ['>'] = '<'}
local function escaped(text, index)
  local n = 0
  index = index - 1
  while index > 0 and text:sub(index, index) == '\\' do n, index = n + 1, index - 1 end
  return n % 2 == 1
end
local function surrounds(text, key)
  local open = closes[key] or key
  local close = opens[open] or open
  local stack, out, p = {}, {}, 0
  while p < #text do
    local nextp = M.next(text, p)
    local c = text:sub(p + 1, nextp)
    if not escaped(text, p + 1) then
      if c == close and #stack > 0 then out[#out + 1] = {start = table.remove(stack), finish = nextp}
      elseif c == open then stack[#stack + 1] = p end
    end
    p = nextp
  end
  return out, #open, #close
end
local function enclosing(text, s, key, count)
  local all = {}
  local open = closes[key] or key
  if key ~= 'm' and not opens[open] then
    -- Symmetric delimiters surround the cursor, not every other delimiter from
    -- the beginning of the document. This matters for /usr/local/bin and quotes.
    local p = s.backward and s.start or (s.finish > s.start and M.prev(text, s.finish) or s.start)
    local before, after, on_delimiter = {}, {}, false
    local offset = 0
    while offset < #text do
      local nextp = M.next(text, offset)
      if text:sub(offset + 1, nextp) == key and not escaped(text, offset + 1) then
        if offset < p then before[#before + 1] = offset
        elseif offset > p then after[#after + 1] = offset
        else on_delimiter = true end
      end
      offset = nextp
    end
    if not on_delimiter then
      local n = count or 1
      local left, right = before[#before - n + 1], after[n]
      if left and right then return {start = left, finish = right + #key, left = #key, right = #key} end
      return nil
    end
  end
  if key == 'm' then
    for _, pair in ipairs({'(', '[', '{', '<', '"', "'", '`'}) do
      local ranges, left, right = surrounds(text, pair)
      for _, range in ipairs(ranges) do range.left, range.right = left, right; all[#all + 1] = range end
    end
  else
    local ranges, left, right = surrounds(text, key)
    for _, range in ipairs(ranges) do range.left, range.right = left, right; all[#all + 1] = range end
  end
  local candidates = {}
  for _, range in ipairs(all) do
    if range.start <= s.start and s.finish <= range.finish then candidates[#candidates + 1] = range end
  end
  table.sort(candidates, function(a, b)
    local alen, blen = a.finish - a.start, b.finish - b.start
    return alen < blen or (alen == blen and a.start > b.start)
  end)
  return candidates[count or 1]
end
function Engine:textobject(key, around, count)
  for _, s in ipairs(self.selections) do
    local p = self:head(s)
    local backward = s.backward
    if key == 'w' or key == 'W' then
      local a, b, cls = p, M.next(self.text, p), class(self.text, p, key == 'W')
      while a > 0 and class(self.text, M.prev(self.text, a), key == 'W') == cls do a = M.prev(self.text, a) end
      while b < #self.text and class(self.text, b, key == 'W') == cls do b = M.next(self.text, b) end
      if around then
        local original = b
        while b < #self.text and class(self.text, b, true) == 0 do b = M.next(self.text, b) end
        if original == b then while a > 0 and class(self.text, M.prev(self.text, a), true) == 0 do a = M.prev(self.text, a) end end
      end
      s.start, s.finish = a, b
    elseif key == 'p' then
      local a, _, b = line_bounds(self.text, p)
      while a > 0 do
        local pa, pb = line_bounds(self.text, M.prev(self.text, a))
        if self.text:sub(pa + 1, pb):match('^%s*$') then break end
        a = pa
      end
      while b < #self.text do
        local _, nb, nextb = line_bounds(self.text, b)
        if self.text:sub(b + 1, nb):match('^%s*$') then break end
        b = nextb
      end
      if around then
        while b < #self.text do
          local _, nb, nextb = line_bounds(self.text, b)
          if not self.text:sub(b + 1, nb):match('^%s*$') then break end
          b = nextb
        end
      end
      s.start, s.finish = a, b
    else
      local found = enclosing(self.text, s, key, count)
      if found then s.start, s.finish = found.start + (around and 0 or found.left), found.finish - (around and 0 or found.right) end
    end
    s.backward, s.goal = (key ~= 'w' and key ~= 'W' and key ~= 'p') and backward or nil, nil
  end
  self:normalize()
end
function Engine:add_cursor(direction)
  local source = self.selections[self.primary]
  local row = M.position(self.text, source.start)
  local erow = M.position(self.text, source.finish)
  local col, ecol = self:column(source.start), self:column(source.finish)
  local targetrow = row + direction
  if targetrow < 0 then return end
  local a = self:offset_column(targetrow, col)
  if M.position(self.text, a) ~= targetrow then return end
  local b = self:offset_column(erow + direction, ecol)
  if b == a and source.finish > source.start then b = M.next(self.text, a) end
  local added = {start = a, finish = math.max(a, b), backward = source.backward}
  self.selections[#self.selections + 1] = added
  self.primary = #self.selections
  self:normalize()
end
function Engine:matches(matcher, split)
  local out = {}
  for _, s in ipairs(self.selections) do
    local text, p, previous = self.text:sub(s.start + 1, s.finish), 0, 0
    while p <= #text do
      local a, b = matcher(text, p)
      if a == nil then break end
      assert(a >= p and b >= a and b <= #text, 'invalid matcher offsets')
      if split then
        if a > previous then out[#out + 1] = {start = s.start + previous, finish = s.start + a} end
        previous = b
      elseif b > a then out[#out + 1] = {start = s.start + a, finish = s.start + b} end
      if b == a then
        if b == #text then break end
        p = M.next(text, b)
      else p = b end
    end
    if split and previous < #text then out[#out + 1] = {start = s.start + previous, finish = s.finish} end
  end
  if #out > 0 then self.selections, self.primary = out, 1; self:normalize() end
end
function Engine:find(key, character, count)
  local text = self.text
  for _, s in ipairs(self.selections) do
    local original, p = self:head(s), self:head(s)
    local direction = (key == 'f' or key == 't') and 1 or -1
    local found = true
    for _ = 1, count do
      local match
      if direction == 1 then
        local a = text:find(character, M.next(text, p) + 1, true)
        match = a and a - 1
      else
        local search = 1
        while search <= p do
          local a = text:find(character, search, true)
          if not a or a - 1 >= p then break end
          match, search = a - 1, a + #character
        end
      end
      if match == nil then found = false; break end
      p = match
    end
    if found then
      if key == 't' then p = M.prev(text, p) elseif key == 'T' then p = M.next(text, p) end
      local anchor = self.mode == 'select' and (s.backward and M.prev(text, s.finish) or s.start) or original
      s.start, s.finish, s.backward = math.min(anchor, p), M.next(text, math.max(anchor, p)), p < anchor or nil
      s.goal = nil
    end
  end
  self:normalize()
end
function Engine:surround(key)
  local open = closes[key] or key
  local close = opens[open] or open
  local values = {}
  for i, s in ipairs(self.selections) do values[i] = open .. self.text:sub(s.start + 1, s.finish) .. close end
  self:replace(values)
end
function Engine:line_insert(key)
  self.insert_before, self.mode = self:snapshot(), 'insert'
  local ranges = {}
  for i, s in ipairs(self.selections) do
    local a, b = line_bounds(self.text, self:head(s))
    local p = (key == 'A' or key == 'o') and b or a
    if key == 'I' then
      local whitespace = self.text:sub(a + 1, b):match('^%s*')
      p = a + #whitespace
    end
    ranges[i] = {start = p, finish = p}
  end
  -- Cursors on the same line share an insertion point.
  local old = self.selections
  self.selections = ranges; self:normalize(); ranges = copy(self.selections)
  self.selections = old
  local value = (key == 'o' or key == 'O') and '\n' or ''
  self:replace(value, true, ranges)
  if key == 'O' then
    for _, s in ipairs(self.selections) do s.start, s.finish = s.start - 1, s.finish - 1 end
  end
end
function Engine:input(key)
  if key == '<Esc>' or key == '<C-c>' then
    if self.mode == 'insert' then
      for _, s in ipairs(self.selections) do
        s.start = M.prev(self.text, s.start); s.finish = M.next(self.text, s.start)
      end
    end
    self.mode, self.pending, self.count, self.insert_before = 'normal', '', '', nil
    self:normalize(); return
  end
  local arrows = {['<Left>'] = 'h', ['<Right>'] = 'l', ['<Up>'] = 'k', ['<Down>'] = 'j'}
  if self.mode == 'insert' then
    if key == '<BS>' or key == '<C-h>' then self:backspace(false)
    elseif key == '<C-w>' then self:backspace(false, true)
    elseif key == '<Del>' or key == '<C-d>' then self:backspace(true)
    elseif key == '<CR>' or key == '<C-j>' then self:replace('\n', true)
    elseif key == '<Tab>' then self:replace('\t', true)
    elseif arrows[key] or key == '<Home>' or key == '<End>' then
      -- Move insertion points without leaving insert mode.
      if key == '<Home>' or key == '<End>' then
        for _, s in ipairs(self.selections) do
          local a, b = line_bounds(self.text, s.start)
          local p = key == '<Home>' and a or b
          s.start, s.finish = p, p
        end
      else
        for _, s in ipairs(self.selections) do s.finish = s.start end
        self:move(arrows[key], 1)
        for _, s in ipairs(self.selections) do local p = self:head(s); s.start, s.finish = p, p end
      end
    elseif key:sub(1, 1) ~= '<' or #key == 1 then self:replace(key, true) end
    return
  end
  local count = math.min(tonumber(self.count) or 1, 10000)
  if self.pending == 'mi' or self.pending == 'ma' then
    self:textobject(key, self.pending == 'ma', count)
  elseif self.pending == 'ms' then self:surround(key)
  elseif self.pending == 'm' then
    if key == 'i' or key == 'a' or key == 's' then self.pending = 'm' .. key; return end
  elseif self.pending == 'g' then self:move('g' .. key, count)
  elseif self.pending:match('^[fFtT]$') then self:find(self.pending, key, count)
  elseif self.pending == 'r' then
    if key:sub(1, 1) ~= '<' or #key == 1 then
      local values = {}
      for i, s in ipairs(self.selections) do
        local p, n = s.start, 0
        while p < s.finish do p, n = M.next(self.text, p), n + 1 end
        values[i] = key:rep(n)
      end
      self:replace(values)
    end
  elseif self.pending ~= '' then
    -- Unknown prefixes are canceled; they never become native Vim operators.
  else
    if key:match('^%d$') then
      self.count = tostring(math.min((tonumber(self.count) or 0) * 10 + tonumber(key), 10000)); return
    end
    if key == 'm' or key == 'g' or key == 'r' or key:match('^[fFtT]$') then self.pending = key; return end
    key = arrows[key] or key
    if key:match('^[hjklwWbBeE]$') or key == '<Home>' or key == '<End>' then self:move(key, count)
    elseif key == 'v' then self.mode = self.mode == 'select' and 'normal' or 'select'
    elseif key == 'i' or key == 'a' or key == 'c' then self:insert(key == 'a', key == 'c')
    elseif key == 'I' or key == 'A' or key == 'o' or key == 'O' then self:line_insert(key)
    elseif key == 'd' then self:yank(); self:replace('')
    elseif key == 'y' then self:yank()
    elseif key == 'p' or key == 'P' then
      if #self.register > 0 then
        local ranges = {}
        for i, s in ipairs(self.selections) do
          local p = key == 'p' and s.finish or s.start
          ranges[i] = {start = p, finish = p}
        end
        self:replace(self:paste_values(), false, ranges)
      end
    elseif key == 'R' then if #self.register > 0 then self:replace(self:paste_values()) end
    elseif key == 'u' then self:history(false)
    elseif key == 'U' then self:history(true)
    elseif key == 'C' or key == '<A-C>' or key == '<M-C>' then
      for _ = 1, count do self:add_cursor(key == 'C' and 1 or -1) end
    elseif key == ',' then self.selections, self.primary = {self.selections[self.primary]}, 1
    elseif key == '<A-,>' or key == '<M-,>' then
      if #self.selections > 1 then table.remove(self.selections, self.primary); self.primary = math.min(self.primary, #self.selections) end
    elseif key == ';' then
      for _, s in ipairs(self.selections) do local p = self:head(s); s.start, s.finish, s.backward = p, M.next(self.text, p), nil end
    elseif key == '<A-;>' or key == '<M-;>' then
      for _, s in ipairs(self.selections) do s.backward = not s.backward or nil end
    elseif key == '(' or key == ')' then self.primary = (self.primary - 1 + (key == ')' and count or -count)) % #self.selections + 1
    elseif key == '%' then self.selections, self.primary = {{start = 0, finish = #self.text}}, 1
    elseif key == 'x' then
      for _, s in ipairs(self.selections) do
        local a = line_bounds(self.text, s.start)
        local _, _, b = line_bounds(self.text, self:head(s))
        for _ = 1, count do
          if s.start == a and s.finish == b and b < #self.text then local _, _, nextb = line_bounds(self.text, b); b = nextb end
          s.start, s.finish = a, b
        end
        s.backward, s.goal = nil, nil
      end
      self:normalize()
    elseif key == 's' or key == 'S' then
      self.count = ''; return key == 's' and 'select_regex' or 'split_regex'
    elseif key == '<A-s>' or key == '<M-s>' then
      self:matches(function(text, p)
        local a = text:find('\n', p + 1, true)
        if a then return a - 1, a end
      end, true)
    elseif key == '~' or key == '`' or key == '<A-`>' or key == '<M-`>' then
      local values = {}
      for i, s in ipairs(self.selections) do
        local value = self.text:sub(s.start + 1, s.finish)
        if key == '~' then value = value:gsub('%a', function(c) return c:match('%l') and c:upper() or c:lower() end)
        elseif key == '`' then value = value:lower() else value = value:upper() end
        values[i] = value
      end
      self:replace(values)
    end
  end
  self.pending, self.count = '', ''
end
function Engine:validate()
  assert(#self.selections > 0 and self.primary >= 1 and self.primary <= #self.selections)
  local finish = -1
  for _, s in ipairs(self.selections) do
    assert(s.start >= 0 and s.start <= s.finish and s.finish <= #self.text)
    assert(M.boundary(self.text, s.start) == s.start and M.boundary(self.text, s.finish) == s.finish)
    assert(s.start >= finish, 'overlapping selections')
    finish = s.finish
  end
  return true
end
return M
