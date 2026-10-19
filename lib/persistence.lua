local U=require("lib.util")
local M={}; M.__index=M
function M.new(path,fs)
  return setmetatable({path=path,fs=fs or require("filesystem")},M)
end
function M:readFile(path)
  local f,why=io.open(path,"rb"); if not f then return nil,why or "cannot open file" end
  local ok,v=pcall(require("lib.state_codec").read,function()
    local chunk,err=f:read(4096); assert(not err,err); return chunk
  end)
  f:close()
  if ok then return v end
  return nil,tostring(v)
end
function M:load(default)
  local v,primaryError=self:readFile(self.path)
  if v then return v end
  local backupError
  v,backupError=self:readFile(self.path..".bak")
  if v then v.recoveredBackup=true; return v end
  assert(not self.fs.exists(self.path) and not self.fs.exists(self.path..".bak"),
    "Cannot load saved data; files preserved.\n"..self.path..": "..tostring(primaryError)..
    "\n"..self.path..".bak: "..tostring(backupError))
  return U.copy(default or {})
end
function M:save(value)
  local tmp=self.path..".tmp"
  local f=assert(io.open(tmp,"wb"))
  local ok,why=pcall(function()
    U.write(value,function(chunk) assert(f:write(chunk)) end)
    assert(f:flush())
  end)
  f:close(); assert(ok,why)
  -- Compare the exact written bytes in bounded chunks. Loading the temporary
  -- document would allocate a second complete state while the live one exists.
  f=assert(io.open(tmp,"rb"))
  ok,why=pcall(function()
    U.write(value,function(chunk)
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
end
return M
