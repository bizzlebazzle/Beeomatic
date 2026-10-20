-- Fresh VM: no test framework or preloaded Beeomatic modules hide startup costs.
local root,compact=...
package.path="./?.lua;"..package.path
local reserved=string.rep("O",384*1024) -- leave room for the host OS/runtime
local baseOpen=io.open
local function exists(path)
  local f=baseOpen(path,"rb"); if f then f:close(); return true end; return false
end
local fs={exists=exists,makeDirectory=function() end,remove=os.remove,rename=os.rename}
fs.size=function(path)
  local f=baseOpen(path,"rb"); if not f then return nil end
  local size=f:seek("end"); f:close(); return size
end
fs.get=function() return {spaceTotal=function() return 4*1024*1024 end,spaceUsed=function() return disk_used() end} end
io.open=function(path,mode)
  local f,why=baseOpen(path,mode); if not f or not mode or not mode:find("w",1,true) then return f,why end
  return {write=function(self,chunk)
      local yes,err=f:write(chunk); if not yes then return nil,err end
      assert(f:flush()); assert(disk_used()<=4*1024*1024,"disk quota exceeded")
      return self
    end,flush=function() return f:flush() end,close=function() return f:close() end}
end
package.preload.filesystem=function() return fs end
package.preload.computer=function() return {uptime=function() return 10 end,address=function() return "limited" end} end
package.preload.event=function() return {pull=function() error("blocked resume must return to shell") end} end
local devices={}
for _,address in ipairs({"tp1","tp2","tp-scan"}) do
  devices[address]={address=address,getInventorySize=function(side) return side==0 and 9 or 11 end,
    getStackInSlot=function() end,transferItem=function() error("unexpected transfer") end,
    getAllStacks=function() return setmetatable({count=function() return 11 end},{__call=function() end}) end}
end
for _,address in ipairs({"housing1","housing2"}) do
  devices[address]={address=address,getQueen=function() end,getDrone=function() end,
    canBreed=function() return true end,getBeeParents=function() return {} end}
end
for _,address in ipairs({"if1","if2","if-scan"}) do
  devices[address]={getInterfaceConfiguration=function() end,setInterfaceConfiguration=function() return true end}
end
devices.me={getItemsInNetwork=function() return {} end,store=function() error("unexpected export") end}
devices.db={clear=function() end,get=function() end}
package.preload.component=function()
  return {proxy=function(address) return assert(devices[address],address) end,
    methods=function(address) local methods={}; for k,v in pairs(devices[address]) do
      if type(v)=="function" then methods[k]=false end
    end; return methods end}
end
-- OpenOS loadfile reads chunks, then table.concat allocates a full source buffer.
-- Model that peak, rather than relying on native Lua's streaming file loader.
local native=package.searchers[2]
package.searchers[2]=function(name)
  if name:sub(1,4)~="lib." then return native(name) end
  local path=name:gsub("%.","/")..".lua"
  local f=assert(baseOpen(path,"rb")); local chunks={}
  while true do local chunk=f:read(1024); if not chunk then break end; chunks[#chunks+1]=chunk end
  f:close()
  return assert(load(table.concat(chunks),"="..path,"t",_G))
end
if not compact then
  -- Control case retains legacy full receipt stacks with the same allocator.
  local P=require("lib.persistence")
  local state=P.new(root.."/data/state.lua",fs):load({})
  require("lib.scheduler")
  assert(state.transactions[64].stack)
  return #reserved
end
local messages=0
print=function() messages=messages+1 end
local _,why=require("lib.cli").main(root,{"resume"})
assert(not why,why)
assert(messages>0)
for _,name in ipairs({"lib.planner","lib.mutations","lib.setup","lib.ui.diagnostics"}) do
  assert(not package.loaded[name],"resume eagerly loaded "..name)
end
assert(not exists(root.."/data/worker.lock"))
collectgarbage("collect")
local live=collectgarbage("count")
return #reserved,live
