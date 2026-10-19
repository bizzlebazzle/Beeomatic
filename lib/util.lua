local M = {}
function M.lower(s) return tostring(s or ""):lower() end
function M.copy(v)
  if type(v) ~= "table" then return v end
  local t = {}; for k,x in pairs(v) do t[k] = M.copy(x) end; return t
end
function M.keys(t)
  local r = {}; for k in pairs(t or {}) do r[#r+1] = k end
  table.sort(r, function(a,b) return tostring(a)<tostring(b) end); return r
end
-- Deterministic, data-only Lua representation; no userdata or executable functions.
function M.encode(v)
  local ty = type(v)
  if ty == "string" then return string.format("%q",v) end
  if ty == "number" then assert(v==v and v~=math.huge and v~=-math.huge); return tostring(v) end
  if ty == "boolean" or ty == "nil" then return tostring(v) end
  assert(ty=="table", "cannot persist "..ty)
  local r={"{"}; for _,k in ipairs(M.keys(v)) do
    r[#r+1]="["..M.encode(k).."]="..M.encode(v[k])..","
  end
  r[#r+1]="}"; return table.concat(r)
end
function M.equal(a,b) return M.encode(a)==M.encode(b) end
function M.assertNumber(v,lo,hi)
  local n=tonumber(v); assert(n and n%1==0 and n>=lo and n<=hi,"invalid number: "..tostring(v)); return n
end
function M.location(ep,slot) return tostring(ep.id)..":"..tostring(slot) end
return M
