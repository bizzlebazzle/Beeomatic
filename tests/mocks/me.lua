local W=require("tests.mocks.world"); local U=require("lib.util"); local B=require("lib.bees")
local M={}
function M.bee(species,kind,count,raw,overrides)
  local s=W.bee(species,kind,count,nil,overrides)
  if raw then s.individual.active=nil; s.individual.inactive=nil; s.individual.isAnalyzed=false end
  s.tag=U.encode(s.individual); return s
end
function M.new()
  local w=W.new(); w.cells={}; w.filters={}; w.database={}; w.hideGenomes=true
  w.c.storage={kind="me_interface",address="me",database="db",databaseSlots=9,verified=true,timeout=3,endpoints={}}
  for n,id in ipairs({"a","b"}) do
    local a=w:addMachine(id); local portId="port"..n; w:inventory(portId,9); w.filters[portId]={}
    w:addTransposer("tp"..n,{[0]=portId,[3]=id})
    local ep={id=portId,transposer="tp"..n,side=0,address="if"..n,managed=true,princessSlot=1,droneSlot=2,returnSlot=9}
    a.storage=ep; w.c.storage.endpoints[n]=ep
  end
  w:inventory("scan-port",9); w.filters["scan-port"]={}; w:inventory("analyser",5)
  w:addTransposer("tp-scan",{[0]="scan-port",[1]="analyser"})
  local ep={id="scan-port",transposer="tp-scan",side=0,address="if-scan",managed=true,princessSlot=1,droneSlot=2,returnSlot=9}
  w.c.storage.endpoints[3]=ep
  w.c.scanner={enabled=true,isolatedVerified=true,storage=ep,input={id="analyser",transposer="tp-scan",side=1},
    output={id="analyser",transposer="tp-scan",side=1},inputSlot=1,outputSlots={2},timeout=10}
  function w:addStock(s)
    local k=B.identity(s); local old=self.cells[k]
    if old then old.size=old.size+s.size else self.cells[k]=U.copy(s) end
  end
  function w:tick()
    if self.offline then return end
    for id,filters in pairs(self.filters) do local inventory=self.inventories[id]
      for slot=1,9 do local filter=filters[slot]; local existing=inventory[slot]
        if existing and (not filter or B.identity(existing)~=B.identity(filter) or existing.size>filter.size) and not self.full then
          local n=filter and B.identity(existing)==B.identity(filter) and (existing.size-filter.size) or existing.size
          local returned=U.copy(existing); returned.size=n; self:addStock(returned)
          existing.size=existing.size-n; if existing.size==0 then inventory[slot]=nil; existing=nil end
        end
        if filter and not self.noStock and (not existing or existing.size<filter.size) then
          local source=self.cells[B.identity(filter)]
          if source and source.size>0 then
            local n=math.min(source.size,filter.size-(existing and existing.size or 0))
            local copy=U.copy(source); copy.size=n+(existing and existing.size or 0); inventory[slot]=copy
            source.size=source.size-n; if source.size==0 then self.cells[B.identity(filter)]=nil end
          end
        end
      end
    end
  end
  function w:finishScan()
    local source=assert(self.inventories.analyser[1],"no scanner input")
    local species=source.label:match("^(.-) %w+$")
    self.inventories.analyser[2]=M.bee(species,B.kind(source),source.size)
    self.inventories.analyser[1]=nil
  end
  for _,port in ipairs(w.c.storage.endpoints) do
    local id=port.id
    w.proxies[port.address]={getInterfaceConfiguration=function(slot) return U.copy(w.filters[id][slot]) end,
      setInterfaceConfiguration=function(slot,db,entry,count)
        if w.failConfig then return nil,"configuration unavailable" end
        local s=db and U.copy(w.database[entry]) or nil
        if s then s.size=count or 1 end
        w.filters[id][slot]=s; return true
      end}
  end
  w.proxies.me={getItemsInNetwork=function(filter)
    assert(not w.offline,"ME network offline")
    local r={}; for _,key in ipairs(U.keys(w.cells)) do local s=w.cells[key]
      if not filter or (s.name==filter.name and s.damage==filter.damage and s.label==filter.label) then
        local copy=U.copy(s); if w.hideGenomes then copy.individual=nil end; r[#r+1]=copy
      end
    end; return r
  end,store=function(filter,_,start,count)
    local n=0; for _,key in ipairs(U.keys(w.cells)) do local s=w.cells[key]
      if s.name==filter.name and s.damage==filter.damage and s.label==filter.label and n<count then
        w.database[start+n]=U.copy(s); n=n+1
      end
    end; return n==count
  end}
  w.proxies.db={get=function(slot) return U.copy(w.database[slot]) end,clear=function(slot) w.database[slot]=nil end}
  w:build()
  w.afterTransfer=function() if w.immediate then w:tick() end end
  w.runtime={now=function() return w.time end,wait=function(seconds)
    w.time=w.time+seconds; if w.interrupt then error("interrupted") end; w:tick()
  end}
  w.storage=require("lib.storage.me_interface").new(w.c.storage,w.inv,w.components,w.runtime)
  w.scanner=require("lib.scanner").new(w.c.scanner,w.inv,w.state,w.save,function() return w.time end,w.storage)
  w.scheduler=require("lib.scheduler").new(w.c,w.state,w.components,w.inv,w.storage,w.scanner,w.save,function() return w.time end)
  return w
end
return M
