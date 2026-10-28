-- Fresh VM: no test framework or preloaded Beeomatic modules hide startup costs.
local root,compact,gcMode,command,profile,largeNetwork,planning=...
command=command or "resume"
local hostGC=collectgarbage
if gcMode=="missing" then collectgarbage=nil
elseif gcMode=="disabled" then collectgarbage=function() error("host collectgarbage unavailable") end end
package.path="./?.lua;"..package.path
local reserved=string.rep("O",384*1024) -- leave room for the host OS/runtime
local baseOpen=io.open
local journalStarted=false
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
  if path==root.."/data/state.lua" and mode=="rb" then journalStarted=true end
  local f,why=baseOpen(path,mode); if not f or not mode or not mode:find("w",1,true) then return f,why end
  return {write=function(self,chunk)
      local yes,err=f:write(chunk); if not yes then return nil,err end
      assert(f:flush()); assert(disk_used()<=4*1024*1024,"disk quota exceeded")
      return self
    end,flush=function() return f:flush() end,close=function() return f:close() end}
end
package.preload.filesystem=function() return fs end
package.preload.computer=function() return {uptime=function() return 10 end,address=function() return "limited" end,
  freeMemory=function() return 2*1024*1024-hostGC("count")*1024 end} end
package.preload.event=function() return {pull=function(seconds)
  if planning then
    local f=baseOpen(root.."/data/state.lua","rb")
    if f then local data=f:read("*a"); f:close()
      if not data:find('pendingRequest',1,true) and data:find('spirit',1,true) and
        (planning~="rebreed" or data:find('rebreeding',1,true)) then return "interrupted" end
    end
  end
  if seconds~=0 then error("blocked resume must return to shell") end
end} end
local devices={}
local phase="startup"
for _,address in ipairs({"tp1","tp2","tp-scan"}) do
  devices[address]={address=address,getInventorySize=function(side) return side==0 and 9 or 11 end,
    getStackInSlot=function() end,transferItem=function() error("unexpected transfer") end,
    getAllStacks=function() return setmetatable({count=function() return 11 end},{__call=function() end}) end}
end
for _,address in ipairs({"housing1","housing2"}) do
  devices[address]={address=address,getQueen=function() end,getDrone=function() end,
    canBreed=function() return true end,getBeeParents=function() return {} end}
end
if planning then
  for _,address in ipairs({"housing1","housing2"}) do
    devices[address].listAllSpecies=function()
      phase="species index"
      local species={}
      for n=1,500 do species[n]={name="Species "..n,uid="test.species"..n,temperature="NORMAL",humidity="NORMAL"} end
      species[#species+1]={name="Spirit",uid="magicbees.speciesspirit"}
      return species
    end
    devices[address].getBeeBreedingData=function()
      phase="full breeding list"
      local routes={}
      for n=1,900 do routes[n]={allele1="Forest",allele2="Meadows",result="Species "..n,chance=10,
        specialConditions={string.rep("Requires a special foundation. ",20)..n,
          string.rep("Requires a special climate. ",20)..n}} end
      return routes
    end
    devices[address].getBeeParents=function(name)
      phase="parent recipes"
      if name=="spirit" or name=="magicbees.speciesspirit" then
        return {{allele1={name="Forest",uid="test.speciesforest"},allele2={name="Meadows",uid="test.speciesmeadows"},
          chance=8,specialConditions={}}}
      end
      return {}
    end
  end
end
for _,address in ipairs({"if1","if2","if-scan"}) do
  devices[address]={getInterfaceConfiguration=function() end,setInterfaceConfiguration=function() return true end}
end
devices.me={getItemsInNetwork=function(filter)
  phase="network discovery "..tostring(filter and filter.name)
  if planning then return assert(require("lib.persistence").new(root.."/"..filter.name:match("bee(%a+)GE")..".lua",fs):readFile(root.."/"..filter.name:match("bee(%a+)GE")..".lua")) end
  if not largeNetwork then return {} end
  -- These items live in AE, not Lua RAM, until an unfiltered callback returns.
  local items={}
  if not filter then
    for n=1,3000 do items[n]={name="gregtech:machine",size=64,damage=n,
      tag=string.rep(string.char(n%256),600)..n} end
  end
  if not filter or filter.name=="Forestry:beeDroneGE" then
    for n=1,219 do items[#items+1]={name="Forestry:beeDroneGE",size=64,damage=0,maxSize=64,
      label="Forest Drone",tag=string.rep(string.char(n%256),600)..n} end
  end
  return items
end,store=function() error("unexpected export") end}
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
  assert(not compact or not journalStarted or (planning and (name=="lib.mutations" or name=="lib.planner")),"worker module loaded after journal: "..name)
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
local nbt=require("tests.fixtures.nbt_cache")(root.."/nbt-cache.bin")
if planning then hostGC("collect") end -- release only fixture-construction garbage
local messages=0
print=function() messages=messages+1 end
local args={command}
if planning and (command=="breed" or command=="imprint") then args[#args+1]="spirit" end
if profile then args[#args+1]="--profile" end
local _,why=require("lib.cli").main(root,args)
assert(not why,phase..": "..tostring(why))
assert(planning or messages>0)
local receipts=require("lib.storage.receipts")
local store=require("lib.persistence").new(root.."/data/state.lua",fs,receipts.decoded,receipts.skipField,root.."/data/catalogue.lua")
local restored=store:load({})
if planning then
  assert(not restored.pendingRequest and #restored.jobs>0,"Spirit plan was not committed")
  assert(restored.jobs[#restored.jobs].species=="spirit")
  if planning=="rebreed" then assert(restored.jobs[#restored.jobs].rebreeding,"saved conversion did not recover its mutation route") end
  assert(not exists(root.."/data/worker.lock"))
  hostGC("collect")
  return #reserved,(hostGC("count"))
end
if largeNetwork then assert(restored.storageCounts.drone==219*64,"filtered scan lost bee variants/counts") end
local entries=0; for _ in pairs(restored.aeCatalog) do entries=entries+1 end
assert(entries==(command=="cancel" and 16 or 0),"split catalogue was not restored")
store:save(restored) -- exercise a later checkpoint and the compact state's backup
assert(nbt.cache.bytes>125000,"NBT cache must remain full during startup and checkpoints")
for _,name in ipairs({"lib.planner","lib.mutations","lib.setup","lib.ui.diagnostics"}) do
  assert(not package.loaded[name],"resume eagerly loaded "..name)
end
assert(not exists(root.."/data/worker.lock"))
if profile then
  local f=assert(baseOpen(root.."/data/profile.log","rb"))
  local report=f:read("*a"); f:close()
  assert(#report<=32768 and report:find("checkpoint.state",1,true),"missing bounded profiling report")
else
  assert(not package.loaded["lib.profile"],"profiling module loaded without --profile")
end
hostGC("collect")
local live=hostGC("count")
return #reserved,live
