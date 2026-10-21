local M = {}
function M.collect()
  -- OpenOS may omit this function or expose a wrapper whose host API is absent.
  if type(collectgarbage)=="function" then pcall(collectgarbage,"collect") end
end
function M.lower(s) return tostring(s or ""):lower() end
function M.copy(v,seen)
  if type(v) ~= "table" then return v end
  seen=seen or {}; if seen[v] then return seen[v] end
  local t = {}; seen[v]=t
  for k,x in pairs(v) do t[k] = M.copy(x,seen) end; return t
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
-- Exact size of write()'s format, without sorting keys or escaping a document.
function M.size(v)
  local function count(x)
    local ty=type(x)
    if ty=="string" then
      local bytes=#x+2
      for first=1,#x,512 do
        local chunk=x:sub(first,first+511)
        local _,quotes=chunk:gsub('["\\]',"")
        local _,controls=chunk:gsub('[%z\1-\31\127]',"")
        bytes=bytes+quotes+3*controls
      end
      return bytes
    elseif ty=="table" then
      local bytes=2
      for key,value in pairs(x) do bytes=bytes+4+count(key)+count(value) end
      return bytes
    elseif ty=="number" then
      assert(x==x and x~=math.huge and x~=-math.huge); return #tostring(x)
    end
    assert(ty=="boolean" or ty=="nil","cannot persist "..ty); return #tostring(x)
  end
  return 8+count(v) -- "return " and the final newline
end
local escapes={['"']='\\"',['\\']='\\\\'}
for byte=0,31 do escapes[string.char(byte)]=string.format("\\%03d",byte) end
escapes[string.char(127)]="\\127"
function M.stringCache() return {values={},queue={},bytes=0,hits=0,misses=0,reused=0} end
local function trim(cache,extra)
  while #cache.queue>0 and (#cache.queue>=256 or cache.bytes+extra>(cache.limit or 262144)) do
    local old=table.remove(cache.queue,1)
    cache.bytes=cache.bytes-#old-#cache.values[old]-128; cache.values[old]=nil
  end
end
-- Stream data-only Lua without sorting tables or constructing the entire document
-- (or an escaped copy of a large binary NBT key) in memory. Identity encoding
-- above stays unchanged so saved reservations/receipts remain compatible.
function M.write(v,sink,cache)
  if cache then trim(cache,0) end
  local chunks,bytes={},0
  local function flush()
    if bytes>0 then sink(table.concat(chunks)); chunks={}; bytes=0 end
  end
  local function emit(s)
    if bytes+#s>4096 then flush() end
    chunks[#chunks+1]=s; bytes=bytes+#s
  end
  -- Cache bounded pieces, so similar NBT identities can share their encoding
  -- without retaining a second full document or caching mutable tables.
  local function escape(s)
    local encoded=cache and cache.values[s]
    if encoded then cache.hits=cache.hits+1; cache.reused=cache.reused+#s; return encoded end
    encoded=s:gsub('[%z\1-\31\127"\\]',escapes)
    if cache then
      cache.misses=cache.misses+1
      local cost=#s+#encoded+128 -- include room for string/table entries
      if cost<=(cache.limit or 262144) then
        trim(cache,cost)
        cache.queue[#cache.queue+1]=s; cache.values[s]=encoded; cache.bytes=cache.bytes+cost
      end
    end
    return encoded
  end
  local function visit(x)
    local ty=type(x)
    if ty=="string" then
      if #x<=512 then emit('"'..x:gsub('[%z\1-\31\127"\\]',escapes)..'"'); return end
      emit('"')
      for first=1,#x,512 do
        emit(escape(x:sub(first,first+511)))
      end
      emit('"')
    elseif ty=="table" then
      emit("{")
      for key,value in pairs(x) do
        if type(key)=="string" and #key<=512 then
          emit('["'..key:gsub('[%z\1-\31\127"\\]',escapes)..'"]=')
        else emit("["); visit(key); emit("]=") end
        visit(value); emit(",")
      end
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
