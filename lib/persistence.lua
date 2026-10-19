local U=require("lib.util")
local M={}; M.__index=M
function M.new(path,fs)
  return setmetatable({path=path,fs=fs or require("filesystem")},M)
end
function M:readFile(path)
  local f=io.open(path,"r"); if not f then return nil end
  local s=f:read("*a"); f:close()
  local fn=load(s,"="..path,"t",{})
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
  local f=assert(io.open(tmp,"w")); assert(f:write("return "..U.encode(value).."\n")); assert(f:close())
  assert(self:readFile(tmp),"state verification failed")
  if self.fs.exists(self.path) then
    if self.fs.exists(self.path..".bak") then assert(self.fs.remove(self.path..".bak")) end
    assert(self.fs.rename(self.path,self.path..".bak"))
  end
  assert(self.fs.rename(tmp,self.path),"atomic replacement failed; backup retained")
end
return M
