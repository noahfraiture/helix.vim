local M = {}
function M.valid_utf8(text)
  local p = 1
  while p <= #text do
    local b, width = text:byte(p), 1
    if b >= 194 and b <= 223 then width = 2
    elseif b >= 224 and b <= 239 then width = 3
    elseif b >= 240 and b <= 244 then width = 4
    elseif b >= 128 then return false end
    if p + width - 1 > #text then return false end
    for j = p + 1, p + width - 1 do local c = text:byte(j); if c < 128 or c > 191 then return false end end
    local second = text:byte(p + 1)
    if width == 3 and ((b == 224 and second < 160) or (b == 237 and second >= 160)) then return false end
    if width == 4 and ((b == 240 and second < 144) or (b == 244 and second >= 144)) then return false end
    p = p + width
  end
  return true
end
return M
