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
  local interval=require("lib.config").pollInterval({storage=self.config},"storage")
  local timeout=self.config.timeout or 60
  repeat
    local value=fn(); if value then return value end
    local remaining=timeout-(self.now()-start)
    assert(remaining>0,why.."; request preserved, inspect power/channels/capacity")
    -- React promptly when AE stocks/drains a slot; do not busy-poll OC calls.
    self.wait(math.min(interval,remaining))
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
    assert(size==9,"Interface port "..ep.id.." reports "..tostring(size).." slots through transposer "..ep.transposer..
      ", side "..ep.side.."; expected 9. Check the selected inventory connection, separately from the Interface adapter.")
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
function M:catalogue(stack,deferSave)
  if B.scanned(stack) then
    self.state.aeCatalog[B.identity(stack)]=U.copy(stack.individual)
    if not deferSave then self.inv.save() end
  end
end
function M:scan()
  local pooled={}
  local function add(s)
    if s and B.kind(s) and (s.size or 0)>0 then
      local key=B.identity(s); local entry=pooled[key]
      if entry then entry.size=entry.size+s.size else pooled[key]=U.copy(s) end
      if B.scanned(s) then self.state.aeCatalog[key]=U.copy(s.individual) end
    end
  end
  for _,s in pairs(assert(self:network().getItemsInNetwork(),"ME network unavailable")) do add(s) end
  -- Stocked Interface inventories are local buffers, not cells on this same grid.
  -- Never attach a storage bus to these ports: that would expose them twice.
  for _,ep in ipairs(self.config.endpoints) do for _,i in ipairs(self.inv:scan(ep)) do add(i.stack) end end
  -- Forget obsolete genotypes from previous analysis/breeding generations, but
  -- retain every genome still in stock or referenced by recoverable work.
  local keep={}
  for _,request in pairs(self.state.meRequests) do keep[request.identity]=true end
  for _,batch in pairs(self.state.meBatches) do keep[batch.identity]=true end
  for _,tx in ipairs({self.state.pending or {},self.state.pendingExternal or {}}) do
    if tx.identity then keep[tx.identity]=true end
  end
  local scan=self.state.scan
  if scan then
    if scan.identity then keep[scan.identity]=true end
    if scan.resultItem then keep[B.identity(scan.resultItem.stack)]=true end
  end
  for key in pairs(self.state.aeCatalog) do
    if not pooled[key] and not keep[key] then self.state.aeCatalog[key]=nil end
  end
  local result={}
  local batches={}
  for _,id in ipairs(U.keys(self.state.meBatches)) do
    local identity=self.state.meBatches[id].identity
    batches[identity]=batches[identity] or {}; local group=batches[identity]; group[#group+1]=id
  end
  for _,key in ipairs(U.keys(pooled)) do
    local s=pooled[key]; s.individual=s.individual or U.copy(self.state.aeCatalog[key])
    local remaining=s.size
    for _,id in ipairs(batches[key] or {}) do local batch=self.state.meBatches[id]
      if batch.identity==key then
        local q=self.state.scan
        local inScanner=q and q.batchId==id and q.identity==key and not q.returned and
          (q.phase=="PROCESSING" or q.phase=="RETURNING" or q.phase=="VERIFYING" or (q.phase=="INSERTING" and (q.inserted or (q.source and
            self.state.meRequests[U.location(q.source.endpoint,q.source.slot)] and
            self.state.meRequests[U.location(q.source.endpoint,q.source.slot)].consumed))))
        local available=batch.count-(inScanner and q.count or 0)
        local n=math.min(remaining,available)
        if n>0 then local copy=U.copy(s); copy.size=n
          result[#result+1]={network=true,endpoint={id="ME"},slot=id,batchId=id,root=batch.root,
            owner=batch.owner,stack=copy}; remaining=remaining-n
        end
        assert(n==available,"owned ME batch missing: "..id.."; audit stock before resuming")
      end
    end
    if remaining>0 then
      -- pooled already owns a private copy. Transfer it to the result instead
      -- of copying the complete genome a second time for unowned stock.
      s.size=remaining
      result[#result+1]={network=true,endpoint={id="ME"},slot=key,stack=s}
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
  local identity=B.identity(item.stack)
  local db=self.components:proxy(self.config.database,{"clear","get"})
  -- Keep only one reusable entry. Re-read its exact NBT before every reuse so
  -- an externally changed database can never select another bee genotype.
  local cached=self.databaseEntry
  if cached and cached.identity==identity and B.identity(db.get(cached.slot))==identity then return cached.slot end
  self.databaseEntry=nil
  local filter={name=item.stack.name,damage=item.stack.damage,label=item.stack.label}
  local matches=assert(self:network().getItemsInNetwork(filter),"ME unavailable")
  local n,total=0,0
  for _,s in pairs(matches) do n=n+1; if B.identity(s)==identity then total=total+s.size end end
  assert(total>0,"selected ME variant is unavailable")
  assert(n<=self.config.databaseSlots,"same-label variants exceed dedicated database capacity")
  -- store fills empty slots starting at one. Only the n slots we read need
  -- clearing; old entries above n are never considered for this request.
  for slot=1,n do db.clear(slot) end
  assert(self:network().store(filter,self.config.database,1,n),"ME database copy failed")
  for slot=1,n do local entry=db.get(slot)
    if entry and B.identity(entry)==identity then
      self.databaseEntry={identity=identity,slot=slot}; return slot
    end
  end
  error("database did not preserve exact bee NBT")
end
function M:materialize(item,ep,owner,count)
  assert(not self.state.pending and not self.state.pendingExternal,"reconcile unresolved movement before an Interface request")
  assert(item.network,"Interface storage requires a logical ME selection")
  count=count or 1; U.assertNumber(count,1,item.stack.maxSize or 64)
  assert(count<=item.stack.size,"requested more than selected quantity")
  local slot=B.kind(item.stack)=="princess" and (ep.princessSlot or 1) or (ep.droneSlot or 2)
  local key=U.location(ep,slot); local p=self:port(ep); local x=self.state.meRequests[key]
  if x then
    assert(x.owner==owner and x.identity==B.identity(item.stack) and x.count==count and x.batchId==item.batchId,
      "Interface slot has an unresolved request")
    assert(not x.consumed,"request already consumed; reconcile before reuse")
    local filter,err=p.getInterfaceConfiguration(slot); assert(not err,tostring(err))
    if x.phase=="INTENT" and not filter and not self.inv:get(ep,slot) then
      -- No physical extraction is possible before READY. An unset request with
      -- an empty local slot can be retried without repeating an item movement.
      local entry=self:selectEntry(item)
      local yes,why=p.setInterfaceConfiguration(slot,self.config.database,entry,count)
      assert(yes,"Interface configuration failed: "..tostring(why))
      x.phase="CONFIGURED"; self.inv.save()
    end
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
  -- Catalogue and READY form one durable checkpoint before the caller can move
  -- the stack. Avoid writing/reading the whole state twice for this receipt.
  self:catalogue(stack,true); x.phase="READY"; self.inv.save()
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
  assert(not self.state.pending and not self.state.pendingExternal,"reconcile unresolved movement before an Interface return")
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
    if x.consumed or x.phase=="RETURNING" or (x.owner=="scanner" and not self.state.scan) then self:clearRequest(x) end
  end
  return true
end
function M:releaseBatches(owner,keep)
  for id,batch in pairs(self.state.meBatches) do if batch.owner==owner and id~=keep then self.state.meBatches[id]=nil end end
  self.inv.save()
end
function M:probe(ep)
  self:validate()
  assert(not self.state.pending and not self.state.pendingExternal and not self.state.scan and not next(self.state.meRequests),
    "reconcile active transfers and scanner requests before probing")
  assert(#self.inv:scan(ep)==0,"empty this Interface inventory before probing")
  local item
  for _,i in ipairs(self:scan()) do
    if not i.owner and B.kind(i.stack)=="drone" and i.stack.size>=2 then item=i; break end
  end
  assert(item,"probe needs at least two identical analysed drones in ME")
  local before=0
  for _,s in pairs(self:network().getItemsInNetwork()) do if B.identity(s)==B.identity(item.stack) then before=before+s.size end end
  local success,err=pcall(function()
    local p=self:materialize(item,ep,"scanner",2)
    assert(B.scanned(p.stack),"probe sample is unanalysed; scan it first")
    self.inv:move(p,ep,ep.returnSlot or 9,1,"scanner",function(got,n) return not got and n==1 end)
    self:releasePort(ep)
    self:poll(function() return not self.inv:get(ep,ep.returnSlot or 9) end,"probe return blocked")
    self:poll(function()
      local count=0
      for _,s in pairs(self:network().getItemsInNetwork()) do if B.identity(s)==B.identity(item.stack) then count=count+s.size end end
      return count==before
    end,"probe exact ME count did not return to its starting value")
  end)
  if not success then
    if not self.state.pending then pcall(self.cancel,self,"scanner") end
    error(err,0)
  end
  self.state.interfaceProbes=self.state.interfaceProbes or {}
  self.state.interfaceProbes[ep.id]={identity=B.identity(item.stack),requested=2,extracted=1,returned=true,time=self.now()}
  self.inv.save(); return true
end
return M
