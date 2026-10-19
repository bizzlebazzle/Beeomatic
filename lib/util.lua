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
-- Stream the same data-only Lua format without constructing the entire document
-- (or an escaped copy of a large binary NBT key) in memory. Identity encoding
-- above stays unchanged so saved reservations/receipts remain compatible.
function M.write(v,sink)
  local chunks,bytes={},0
  local function flush()
    if bytes>0 then sink(table.concat(chunks)); chunks={}; bytes=0 end
  end
  local function emit(s)
    if bytes+#s>4096 then flush() end
    chunks[#chunks+1]=s; bytes=bytes+#s
  end
  local function visit(x)
    local ty=type(x)
    if ty=="string" then
      emit('"')
      for first=1,#x,512 do
        emit((x:sub(first,first+511):gsub('[%z\1-\31\127"\\]',function(ch)
          if ch=='"' or ch=='\\' then return '\\'..ch end
          return string.format("\\%03d",ch:byte())
        end)))
      end
      emit('"')
    elseif ty=="table" then
      emit("{")
      for _,key in ipairs(M.keys(x)) do emit("["); visit(key); emit("]="); visit(x[key]); emit(",") end
      emit("}")
    elseif ty=="number" then
      assert(x==x and x~=math.huge and x~=-math.huge); emit(tostring(x))
    else
      assert(ty=="boolean" or ty=="nil","cannot persist "..ty); emit(tostring(x))
    end
  end
  emit("return "); visit(v); emit("\n"); flush()
end
function M.equal(a,b)
  if a==b then return true end
  if type(a)~="table" or type(b)~="table" then return false end
  for k,v in pairs(a) do if not M.equal(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
function M.assertNumber(v,lo,hi)
  local n=tonumber(v); assert(n and n%1==0 and n>=lo and n<=hi,"invalid number: "..tostring(v)); return n
end
function M.location(ep,slot) return tostring(ep.id)..":"..tostring(slot) end
return M
