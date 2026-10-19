local U=require("lib.util"); local Config=require("lib.config")
local M={}
local function callable(v)
  local mt=type(v)=="table" and getmetatable(v)
  return type(v)=="function" or (type(mt)=="table" and type(mt.__call)=="function")
end
local function callback(fn)
  return setmetatable({}, {__call=function(_,...) return fn(...) end})
end
function M.bee(species,kind,n,inactive,overrides)
  local sp={name=species,uid="test.species"..species:lower(),temperature="Normal",humidity="Normal"}
  local g={species=sp,fertility=3,temperatureTolerance="NONE",humidityTolerance="NONE",nocturnal=false,
    tolerantFlyer=false,caveDwelling=false,flowerProvider="flowers",lifespan=20,territory={9,6,9}}
  for k,v in pairs(overrides or {}) do g[k]=U.copy(v) end
  local ig=U.copy(g)
  if inactive then ig.species={name=inactive,uid="test.species"..inactive:lower(),temperature="Normal",humidity="Normal"} end
  return {name="Forestry:bee"..kind:sub(1,1):upper()..kind:sub(2).."GE",damage=0,size=n or 1,maxSize=kind=="drone" and 64 or 1,
    label=species.." "..kind,individual={type="bee",isAnalyzed=true,ident=sp.uid,active=g,inactive=ig}}
end
function M.environment(temp,hum)
  return {temperature=temp or "NORMAL",humidity=hum or "NORMAL",verified=true,
    daylightManaged=true,rainProtected=true,skyAccess=true,flowers={flowers=true}}
end
function M.new()
  local w={inventories={},proxies={},time=0,saves=0,moves=0,state={jobs={},reservations={},transactions={}},c=Config.defaults()}
  w.c.storage={kind="chest",endpoints={}}
  function w:inventory(id,size)
    local t={size=size}; self.inventories[id]=t; return t
  end
  function w:addTransposer(address,sides)
    local proxy={address=address}
    proxy.getInventorySize=function(side) local t=self.inventories[sides[side]]; return t and t.size end
    proxy.getStackInSlot=function(side,slot)
      local t=self.inventories[sides[side]]; assert(t,"unloaded inventory"); return U.copy(t[slot])
    end
    proxy.transferItem=function(from,to,count,src,dst)
      self.moves=self.moves+1
      if self.failTransfer then return 0 end
      local a,b=assert(self.inventories[sides[from]]),assert(self.inventories[sides[to]])
      local s=a[src]; if not s then return 0 end
      local B=require("lib.bees"); local existing=b[dst]
      if existing and B.identity(existing)~=B.identity(s) then return 0 end
      local n=math.min(count,s.size,(s.maxSize or 64)-(existing and existing.size or 0))
      b[dst]=U.copy(s); b[dst].size=n+(existing and existing.size or 0); s.size=s.size-n
      if s.size==0 then a[src]=nil end
      if self.afterTransfer then self.afterTransfer(from,to,src,dst) end
      for _,machine in ipairs(self.c.alvearies) do
        if machine.transposer==address and machine.side==to and machine.backend~="routed" then
          local slots=machine.slots
          if b[slots.princess] and b[slots.drone] then
            b[slots.princess].name="Forestry:beeQueenGE"; b[slots.drone]=nil
          end
        end
      end
      if self.throwAfterMove then error("power cut after movement") end
      return n
    end
    self.proxies[address]=proxy; return proxy
  end
  w:inventory("hub",100)
  function w:addMachine(id,temp)
    local index=#self.c.alvearies+1; local t="tp"..index; local addr="housing"..index
    self:inventory(id,11); self:addTransposer(t,{[0]="hub",[3]=id})
    local ep={id="hub",transposer=t,side=0}
    local a={id=id,name=id,address=addr,transposer=t,side=3,storage=ep,enabled=true,priority=index,
      slots={princess=4,drone=2,outputs={6,8,10},inventorySize=11,verified=true},
      environment=M.environment(temp),confirmed={}}
    self.c.alvearies[#self.c.alvearies+1]=a
    self.c.storage.endpoints[#self.c.storage.endpoints+1]=ep
    self.proxies[addr]={address=addr,getQueen=function() local x=self.inventories[id][4]; return x and U.copy(x.individual) end,
      getDrone=function() local x=self.inventories[id][2]; return x and U.copy(x.individual) end,
      canBreed=function() return not self.obstructed end,
      getBeeParents=function(name) return U.copy((self.recipes or {})[name:lower()] or {}) end,
      getBeeBreedingData=function() return {} end,listAllSpecies=function() return {} end}
    return a
  end
  function w:finish(id,p,d)
    local t=self.inventories[id]; t[4]=nil; t[2]=nil; t[6]=U.copy(p); t[8]=U.copy(d)
  end
  function w:build()
    -- Real OpenOS proxy callbacks are callable tables, not necessarily functions.
    for _,proxy in pairs(self.proxies) do for name,value in pairs(proxy) do
      if type(value)=="function" then proxy[name]=callback(value) end
    end end
    local api={proxy=function(address) assert(self.proxies[address],"component missing "..address); return self.proxies[address] end,
      list=function()
        local kinds={}; for address in pairs(self.proxies) do kinds[address]=address:match("^tp") and "transposer" or "bee_housing" end
        return pairs(kinds)
      end,methods=function(address)
        local r={}; for k,v in pairs(self.proxies[address]) do if callable(v) then r[k]=false end end; return r
      end,doc=function() return "mock callback" end}
    self.components=require("lib.components").new(api)
    self.save=function() self.saves=self.saves+1 end
    self.inv=require("lib.inventory").new(self.components,self.state,self.save)
    self.storage=require("lib.storage.chest").new(self.c.storage,self.inv)
    self.scanner=require("lib.scanner").new(self.c.scanner,self.inv,self.state,self.save,function() return self.time end)
    self.scheduler=require("lib.scheduler").new(self.c,self.state,self.components,self.inv,self.storage,self.scanner,self.save,function() return self.time end)
    return self
  end
  return w
end
function M.route(a,b,chance,req)
  return {allele1={name=a},allele2={name=b},parents={a:lower(),b:lower()},chance=chance or 10,specialConditions=req or {}}
end
function M.job(w,id,species,mode,route)
  local j={id=id,species=species:lower(),mode=mode or "breed",route=route,dependencies={},state="WAITING",cycles=0,confirmed=0}
  w.state.jobs[#w.state.jobs+1]=j; return j
end
return M
