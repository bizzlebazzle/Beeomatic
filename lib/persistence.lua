local U=require("lib.util")
local M={}; M.__index=M
-- Buffered filesystem operations may never yield. Bound CPU time for both
-- parsing and encoding, including legacy records discarded by the reader.
local function cooperation(store,delay)
  local computer=package.loaded.computer
  local nextYield=computer and computer.uptime and delay and computer.uptime()+delay or 0
  return function()
    if computer and computer.uptime and os.sleep and computer.uptime()>=nextYield then
      if store.wait then store.wait(0.05)
      else os.sleep(0.05) end -- zero sleeps do not yield on some OpenOS versions
      nextYield=computer.uptime()+0.5
    end
  end
end
local function index(value,skip)
  local copy={}; for key,v in pairs(value) do if key~=skip then copy[key]=v end end; return copy
end
function M.new(path,fs,onTable,skipField,cataloguePath)
  local self=setmetatable({path=path,fs=fs or require("filesystem"),onTable=onTable,skipField=skipField,cache=U.stringCache()},M)
  if cataloguePath then
    self.catalogue=M.new(cataloguePath,self.fs,function(genes)
      -- Homozygous chromosomes are read-only catalogue data. Share their
      -- tables; snapshots still deep-copy them before exposing mutable genes.
      if type(genes.active)=="table" and U.equal(genes.active,genes.inactive) then genes.inactive=genes.active end
    end)
    self.catalogue.cache=self.cache -- one bounded encoding cache for both files
  end
  return self
end
function M:readFile(path)
  local read=require("lib.state_codec").read
  local f,why=io.open(path,"rb"); if not f then return nil,why or "cannot open file" end
  if self.profile then f=self.profile:file(f) end
  local cooperate=cooperation(self,0.5) -- small control/config reads need no sleep
  local ok,v=pcall(read,function()
    cooperate()
    local chunk,err=f:read(4096); assert(not err,err); return chunk
  end,self.onTable,self.skipField)
  f:close()
  if ok then return v end
  return nil,tostring(v)
end
function M:load(default)
  -- Encoded save pieces are disposable; release them before parsing another state.
  self.cache.values={}; self.cache.queue={}; self.cache.bytes=0
  local function loaded(value)
    self.savedCatalogue=nil
    if self.catalogue and value.aeCatalog==nil then
      value.aeCatalog=self.catalogue:load({})
      value.aeCatalog.recoveredBackup=nil -- the catalogue contains genomes only
      self.savedCatalogue=index(value.aeCatalog)
    end -- inline legacy catalogues migrate at the next successful save
    return value
  end
  local v,primaryError=self:readFile(self.path)
  if v then self.primaryVerified=true; return loaded(v) end
  U.collect() -- release a partial parse before trying the backup when supported
  local backupError
  v,backupError=self:readFile(self.path..".bak")
  if v then self.primaryVerified=false; v.recoveredBackup=true; return loaded(v) end
  assert(not self.fs.exists(self.path) and not self.fs.exists(self.path..".bak"),
    "Cannot load saved data; files preserved.\n"..self.path..": "..tostring(primaryError)..
    "\n"..self.path..".bak: "..tostring(backupError))
  return loaded(U.copy(default or {}))
end
function M:save(value)
  if self.catalogue then
    local catalogue=value.aeCatalog or {}
    if not self.savedCatalogue or not U.equal(catalogue,self.savedCatalogue) then
      self.catalogue.wait=self.wait; self.catalogue.profile=self.profile
      self.catalogue:save(catalogue) -- durable before state can reference new genes
      -- Writers replace complete genome entries. Retain just their index, not
      -- another copy of all gene tables or a serialized catalogue in RAM.
      self.savedCatalogue=index(catalogue)
    end
    value=index(value,"aeCatalog")
  end
  local tmp=self.path..".tmp"
  local computer=package.loaded.computer
  if computer and computer.freeMemory then
    self.cache.limit=math.max(4096,math.min(262144,math.floor(computer.freeMemory()/4)))
  end
  local cooperate=cooperation(self)
  cooperate()
  -- Check space as chunks arrive, without a sizing/encoding pass or a second
  -- document in RAM. A failed write leaves the primary in place.
  local free,bytes=nil,0
  if self.fs.get then
    local disk=self.fs.get(self.path)
    if disk and disk.spaceTotal and disk.spaceUsed then
      local previous=self.fs.size and self.fs.size(tmp) or 0
      free=disk.spaceTotal()-disk.spaceUsed()+(previous or 0)
    end
  end
  local f=assert(io.open(tmp,"wb"))
  if self.profile then f=self.profile:file(f) end
  local ok,why=pcall(function()
    U.write(value,function(chunk)
      cooperate(); bytes=bytes+#chunk
      if free and bytes+4096>free then
        local backup=self.path..".bak"
        local reclaim=self.primaryVerified and self.fs.size and self.fs.size(backup) or 0
        if reclaim and reclaim>0 then assert(self.fs.remove(backup)); free=free+reclaim end
        assert(bytes+4096<=free,"Not enough disk space for checkpoint. Saved primary preserved.")
      end
      assert(f:write(chunk))
    end,self.cache)
    assert(f:flush())
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
