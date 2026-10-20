local U=require("lib.util")
local M={}; M.__index=M
function M.new(path,fs,onTable,skipField)
  return setmetatable({path=path,fs=fs or require("filesystem"),onTable=onTable,skipField=skipField},M)
end
function M:readFile(path)
  local read=require("lib.state_codec").read
  local f,why=io.open(path,"rb"); if not f then return nil,why or "cannot open file" end
  if self.profile then f=self.profile:file(f) end
  local ok,v=pcall(read,function()
    local chunk,err=f:read(4096); assert(not err,err); return chunk
  end,self.onTable,self.skipField)
  f:close()
  if ok then return v end
  return nil,tostring(v)
end
function M:load(default)
  local v,primaryError=self:readFile(self.path)
  if v then self.primaryVerified=true; return v end
  U.collect() -- release a partial parse before trying the backup when supported
  local backupError
  v,backupError=self:readFile(self.path..".bak")
  if v then self.primaryVerified=false; v.recoveredBackup=true; return v end
  assert(not self.fs.exists(self.path) and not self.fs.exists(self.path..".bak"),
    "Cannot load saved data; files preserved.\n"..self.path..": "..tostring(primaryError)..
    "\n"..self.path..".bak: "..tostring(backupError))
  return U.copy(default or {})
end
function M:save(value)
  local tmp=self.path..".tmp"
  local bytes=U.size(value)
  -- Check space for the complete new generation before opening the temporary
  -- file. Never sacrifice the only verified generation to make room.
  if self.fs.get then
    local disk=self.fs.get(self.path)
    if disk and disk.spaceTotal and disk.spaceUsed then
      local previous=self.fs.size and self.fs.size(tmp) or 0
      local free=disk.spaceTotal()-disk.spaceUsed()
      local needed=math.max(0,bytes-(previous or 0))+4096
      -- An old, bloated backup can block the second compact save after upgrade.
      -- Reclaim it only if a valid primary is known and doing so is sufficient.
      local backup=self.path..".bak"
      local reclaim=self.primaryVerified and self.fs.size and self.fs.size(backup) or 0
      if free<needed and reclaim and reclaim>0 and free+reclaim>=needed then
        assert(self.fs.remove(backup)); free=free+reclaim
      end
      assert(free>=needed,
        "Not enough disk space for checkpoint ("..bytes.." bytes; "..free.." free). Saved files preserved.")
    end
  end
  -- Small checkpoints (including control/config files) fit a bounded buffer.
  -- Serialize once, then write and compare the same bytes. Large states stream.
  local chunks
  if bytes<=16384 then
    chunks={}; U.write(value,function(chunk) chunks[#chunks+1]=chunk end)
  end
  local function each(sink)
    if chunks then for _,chunk in ipairs(chunks) do sink(chunk) end
    else U.write(value,sink) end
  end
  local f=assert(io.open(tmp,"wb"))
  if self.profile then f=self.profile:file(f) end
  local ok,why=pcall(function()
    each(function(chunk) assert(f:write(chunk)) end)
    assert(f:flush())
  end)
  f:close(); assert(ok,why)
  -- Compare the exact written bytes in bounded chunks. Loading the temporary
  -- document would allocate a second complete state while the live one exists.
  f=assert(io.open(tmp,"rb"))
  if self.profile then f=self.profile:file(f) end
  ok,why=pcall(function()
    each(function(chunk)
      local offset=1
      while offset<=#chunk do
        local actual=f:read(#chunk-offset+1)
        assert(actual and #actual>0 and actual==chunk:sub(offset,offset+#actual-1),"state verification failed")
        offset=offset+#actual
      end
    end)
    assert(f:read(1)==nil,"state verification failed")
  end)
  f:close(); assert(ok,why)
  if self.fs.exists(self.path) then
    if self.fs.exists(self.path..".bak") then assert(self.fs.remove(self.path..".bak")) end
    assert(self.fs.rename(self.path,self.path..".bak"))
  end
  assert(self.fs.rename(tmp,self.path),"atomic replacement failed; backup retained")
  self.primaryVerified=true
end
return M
