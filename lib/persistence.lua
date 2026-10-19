local U=require("lib.util")
local M={}; M.__index=M
function M.new(path,fs)
  return setmetatable({path=path,fs=fs or require("filesystem")},M)
end
function M:readFile(path)
  local f=io.open(path,"r"); if not f then return nil end
  local fn=load(function() return f:read(4096) end,"="..path,"t",{}); f:close()
  if not fn then return nil end
  local ok,v=pcall(fn); if ok and type(v)=="table" then return v end
end
function M:load(default)
  local v=self:readFile(self.path)
  if v then return v end
  v=self:readFile(self.path..".bak")
  if v then v.recoveredBackup=true; return v end
  assert(not self.fs.exists(self.path) and not self.fs.exists(self.path..".bak"),
    "Both state generations are unreadable; restore backup, do not start new jobs")
  return U.copy(default or {})
end
function M:save(value)
  local tmp=self.path..".tmp"
  local f=assert(io.open(tmp,"w"))
  local ok,why=pcall(function()
    U.write(value,function(chunk) assert(f:write(chunk)) end)
    assert(f:flush())
  end)
  f:close(); assert(ok,why)
  -- Compare the exact written bytes in bounded chunks. Loading the temporary
  -- document would allocate a second complete state while the live one exists.
  f=assert(io.open(tmp,"r"))
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
