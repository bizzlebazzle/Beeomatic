local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M; M.interface=true
function M.new(config,inv,components,runtime)
  runtime=runtime or {}
  local state=inv.state
  state.aeCatalog=state.aeCatalog or {}; state.meRequests=state.meRequests or {}; state.meBatches=state.meBatches or {}
  local self=setmetatable({config=config,inv=inv,components=components,state=state},M)
  self.now=runtime.now or function() return require("computer").uptime() end
  self.wait=runtime.wait or function(seconds)
    local name,_,char=require("event").pull(seconds)
    if name=="interrupted" then error("Interface wait interrupted; saved request preserved") end
    if name=="key_down" and (char==112 or char==113) then
      if char==112 then state.paused=true else state.stopping=true end
      inv.save(); error("Interface wait stopped; saved request preserved")
    end
  end
  return self
end
function M:network() return self.components:proxy(self.config.address,{"getItemsInNetwork","store"}) end
function M:port(ep)
  assert(ep.managed and ep.address,"register a full-block ME Interface port")
  return self.components:proxy(ep.address,{"getInterfaceConfiguration","setInterfaceConfiguration"})
end
function M:poll(fn,why)
  local start=self.now()
  repeat
    local value=fn(); if value then return value end
    assert(self.now()-start<(self.config.timeout or 60),why.."; request preserved, inspect power/channels/capacity")
    self.wait(1)
  until false
end
function M:validate()
  self:network(); self.components:proxy(self.config.database,{"clear","get"})
  U.assertNumber(self.config.databaseSlots,1,4096)
  assert(self.config.verified,"verify Interface stock/return operation and remove fuzzy/crafting upgrades")
  local ids,addresses,locations={},{},{}
  assert(#self.config.endpoints>0,"register at least one Interface port")
  for _,ep in ipairs(self.config.endpoints) do
    assert(not ids[ep.id] and not addresses[ep.address],"Interface ports must have unique IDs and component addresses")
    ids[ep.id]=true; addresses[ep.address]=true
    local loc=ep.transposer..":"..ep.side; assert(not locations[loc],"duplicate Interface inventory"); locations[loc]=true
    local p=self:port(ep); local size=self.inv:size(ep)
    assert(size==9,"expected full-block Interface with nine slots")
    local seen={}
    for _,slot in ipairs({ep.princessSlot or 1,ep.droneSlot or 2,ep.returnSlot or 9}) do
      U.assertNumber(slot,1,size); assert(not seen[slot],"overlapping Interface role slots"); seen[slot]=true
    end
    for slot=1,size do
      local request=self.state.meRequests[U.location(ep,slot)]
      local configured,err=p.getInterfaceConfiguration(slot); assert(not err,tostring(err))
      assert(not configured or request,"unexpected Interface stock filter; clear manual filters before use")
      if configured and request then
        assert(B.identity(configured)==request.identity and configured.size==request.count,"Interface filter changed; audit before resuming")
      end
    end
  end
  return true
end
function M:catalogue(stack)
  if B.scanned(stack) then self.state.aeCatalog[B.identity(stack)]=U.copy(stack.individual); self.inv.save() end
end
function M:scan()
  local pooled={}
  local function add(s)
    if s and (s.size or 0)>0 then
      local key=B.identity(s); local entry=pooled[key]
      if entry then entry.size=entry.size+s.size else pooled[key]=U.copy(s) end
      if B.scanned(s) then self.state.aeCatalog[key]=U.copy(s.individual) end
    end
  end
  for _,s in pairs(assert(self:network().getItemsInNetwork(),"ME network unavailable")) do add(s) end
  -- Stocked Interface inventories are local buffers, not cells on this same grid.
  -- Never attach a storage bus to these ports: that would expose them twice.
  for _,ep in ipairs(self.config.endpoints) do for _,i in ipairs(self.inv:scan(ep)) do add(i.stack) end end
  local result={}
  for _,key in ipairs(U.keys(pooled)) do
    local s=pooled[key]; s.individual=s.individual or U.copy(self.state.aeCatalog[key])
    local remaining=s.size
    for _,id in ipairs(U.keys(self.state.meBatches)) do local batch=self.state.meBatches[id]
      if batch.identity==key then
        local n=math.min(remaining,batch.count)
        if n>0 then local copy=U.copy(s); copy.size=n
          result[#result+1]={network=true,endpoint={id="ME"},slot=id,batchId=id,root=batch.root,
            owner=batch.owner,stack=copy}; remaining=remaining-n
        end
        local scanning=self.state.scan and self.state.scan.batchId==id
        assert(n==batch.count or scanning,"owned ME batch missing: "..id.."; audit stock before resuming")
      end
    end
    if remaining>0 then local copy=U.copy(s); copy.size=remaining
      result[#result+1]={network=true,endpoint={id="ME"},slot=key,stack=copy}
    end
  end
  for id,batch in pairs(self.state.meBatches) do
    assert(pooled[batch.identity] or (self.state.scan and self.state.scan.batchId==id),
      "owned ME batch missing: "..id.."; audit stock before resuming")
  end
  return result
end
function M:selectEntry(item)
  assert(type(item.stack.tag)=="string","Exact ME requests require compressed NBT: enable OC allowItemStackNBTTags")
  local filter={name=item.stack.name,damage=item.stack.damage,label=item.stack.label}
  local matches=assert(self:network().getItemsInNetwork(filter),"ME unavailable")
  local n,total=0,0
  for _,s in pairs(matches) do n=n+1; if B.identity(s)==B.identity(item.stack) then total=total+s.size end end
  assert(total>0,"selected ME variant is unavailable")
  assert(n<=self.config.databaseSlots,"same-label variants exceed dedicated database capacity")
  local db=self.components:proxy(self.config.database,{"clear","get"})
  for slot=1,self.config.databaseSlots do db.clear(slot) end
  assert(self:network().store(filter,self.config.database,1,n),"ME database copy failed")
  for slot=1,n do local entry=db.get(slot)
    if entry and B.identity(entry)==B.identity(item.stack) then return slot end
  end
  error("database did not preserve exact bee NBT")
end
function M:materialize(item,ep,owner,count)
  assert(item.network,"Interface storage requires a logical ME selection")
  count=count or 1; U.assertNumber(count,1,item.stack.maxSize or 64)
  assert(count<=item.stack.size,"requested more than selected quantity")
  local slot=B.kind(item.stack)=="princess" and (ep.princessSlot or 1) or (ep.droneSlot or 2)
  local key=U.location(ep,slot); local p=self:port(ep); local x=self.state.meRequests[key]
  if x then
    assert(x.owner==owner and x.identity==B.identity(item.stack) and x.count==count and x.batchId==item.batchId,
      "Interface slot has an unresolved request")
    assert(not x.consumed,"request already consumed; reconcile before reuse")
  else
    local filter,err=p.getInterfaceConfiguration(slot); assert(not err,tostring(err))
    assert(not filter and not self.inv:get(ep,slot),"Interface stock slot is occupied/configured")
    local entry=self:selectEntry(item)
    x={owner=owner,identity=B.identity(item.stack),count=count,ep=U.copy(ep),slot=slot,
      batchId=item.batchId,phase="INTENT"}
    self.state.meRequests[key]=x; self.inv.save()
    local yes,why=p.setInterfaceConfiguration(slot,self.config.database,entry,count)
    assert(yes,"Interface configuration failed: "..tostring(why))
    x.phase="CONFIGURED"; self.inv.save()
  end
  local configured,err=p.getInterfaceConfiguration(slot)
  assert(not err and configured and B.identity(configured)==x.identity and configured.size==count,
    "Interface stock configuration does not match saved exact request")
  local stack=self:poll(function()
    local s=self.inv:get(ep,slot)
    if s then assert(B.identity(s)==x.identity and s.size<=count,"wrong Interface stock receipt")
      if s.size==count then return s end
    end
  end,"timeout waiting for Interface stock")
  self:catalogue(stack); x.phase="READY"; self.inv.save()
  return {endpoint=ep,slot=slot,stack=stack,batchId=item.batchId}
end
function M:clearRequest(x)
  x.phase="RETURNING"; self.inv.save()
  local p=self:port(x.ep); local yes,why=p.setInterfaceConfiguration(x.slot)
  assert(yes,"Interface request cleanup failed: "..tostring(why))
  local filter,err=p.getInterfaceConfiguration(x.slot); assert(not err and not filter,"Interface filter did not clear")
  self:poll(function() return not self.inv:get(x.ep,x.slot) end,"timeout returning Interface refill to ME")
  self.state.meRequests[U.location(x.ep,x.slot)]=nil; self.inv.save()
end
function M:releasePort(ep)
  for _,key in ipairs(U.keys(self.state.meRequests)) do local x=self.state.meRequests[key]
    if x.ep.id==ep.id and x.consumed then self:clearRequest(x) end
  end
end
function M:cancel(owner)
  for _,key in ipairs(U.keys(self.state.meRequests)) do local x=self.state.meRequests[key]
    if x.owner==owner then self:clearRequest(x) end
  end
end
function M:deposit(item,ep,owner)
  local slot=ep.returnSlot or 9; local p=self:port(ep)
  local filter,err=p.getInterfaceConfiguration(slot); assert(not err and not filter,"Interface return slot must be unconfigured")
  self:poll(function() return not self.inv:get(ep,slot) end,"Interface return slot blocked")
  local receipt=self.inv:move(item,ep,slot,item.stack.size,owner)
  self:poll(function() return not self.inv:get(ep,slot) end,"ME full/offline while draining return slot")
  return receipt
end
function M:reconcile()
  assert(not self.state.pendingExternal,"legacy export journal exists; reconcile with the previous installation before migration")
  for _,key in ipairs(U.keys(self.state.meRequests)) do local x=self.state.meRequests[key]
    if x.consumed or x.phase=="RETURNING" then self:clearRequest(x) end
  end
  return true
end
function M:releaseBatches(owner,keep)
  for id,batch in pairs(self.state.meBatches) do if batch.owner==owner and id~=keep then self.state.meBatches[id]=nil end end
  self.inv.save()
end
return M
