local Chest=require("lib.storage.chest"); local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M
function M.new(config,inv,components)
  return setmetatable({config=config,inv=inv,components=components,chest=Chest.new(config,inv)},M)
end
function M:network()
  return self.components:proxy(self.config.address,{"getItemsInNetwork","store"})
end
function M:scan()
  local localItems=self.chest:scan(); local counts={}
  self.inv.state.aeCatalog=self.inv.state.aeCatalog or {}
  -- Archive chest is exposed by an ME storage bus. Deduplicate its exact stacks.
  for _,i in ipairs(localItems) do
    local k=B.identity(i.stack); counts[k]=(counts[k] or 0)+i.stack.size
    if B.scanned(i.stack) then self.inv.state.aeCatalog[k]=U.copy(i.stack.individual) end
  end
  for _,s in pairs(assert(self:network().getItemsInNetwork(),"ME subnet offline")) do
    if (s.size or 0)>0 then
      local k=B.identity(s); local used=math.min(counts[k] or 0,s.size)
      counts[k]=(counts[k] or 0)-used
      if s.size>used then local copy=U.copy(s); copy.size=s.size-used
        copy.individual=copy.individual or U.copy(self.inv.state.aeCatalog[k])
        localItems[#localItems+1]={network=true,slot=k,endpoint={id="ME"},stack=copy}
      end
    end
  end
  return localItems
end
function M:prepare(items)
  for _,i in ipairs(items) do if i.network and B.kind(i.stack) and not B.scanned(i.stack) then
    self:materialize(i,assert(self.config.endpoints[1]),"ae-inspection")
    self.inv:release("ae-inspection"); return false
  end end
  return true
end
function M:validate()
  self.chest:validate(); self:network()
  assert(self.config.storageBusVerified,"verify archive chest storage bus and dedicated subnet")
  self.components:proxy(self.config.exportAddress,{"setExportConfiguration","exportIntoSlot"})
  self.components:proxy(self.config.database,{"clear","get"})
  assert(self.config.exportIsolated,"disable autonomous export with redstone card; remove fuzzy cards")
  return true
end
function M:materialize(item,endpoint,owner)
  if not item.network and item.endpoint.id==endpoint.id then return self.chest:materialize(item,endpoint) end
  self:validate()
  assert(not self.inv.state.pending,"unresolved movement")
  assert(type(item.stack.tag)=="string","Exact AE2 export requires compressed NBT tags. Enable server OC allowItemStackNBTTags and probe first")
  local cfg=self.config; local buffer=assert(cfg.buffer,"register ME export buffer")
  local bridge
  for _,ep in ipairs(cfg.endpoints) do
    if ep.id==endpoint.id and ep.transposer==buffer.transposer then bridge=ep; break end
  end
  assert(bridge,"ME export buffer needs a transposer view of the selected physical archive")
  assert(buffer.id~=bridge.id and buffer.side~=bridge.side,"ME export buffer must be isolated from archive")
  local dstSlot=self.inv:empty(buffer)
  -- Legacy GTNH compares byte-array filters by Java object string, so do not
  -- depend on tag filtering. Copy the finite candidate group into a dedicated
  -- database and select the exact compressed-NBT entry after verifying it.
  local filter={name=item.stack.name,damage=item.stack.damage,label=item.stack.label}
  local matches=self:network().getItemsInNetwork(filter)
  local total,variants=0,0
  for _,s in pairs(matches or {}) do
    variants=variants+1
    if B.identity(s)==B.identity(item.stack) then total=total+s.size end
  end
  assert(total>0,"reserved ME item disappeared")
  local db=self.components:proxy(cfg.database,{"clear","get"})
  local capacity=cfg.databaseSlots or 1
  assert(variants<=capacity,"Too many same-label genetic variants for configured database capacity; enlarge dedicated database or move some stock to archive")
  for slot=1,capacity do db.clear(slot) end
  assert(self:network().store(filter,cfg.database,1,variants),"ME database copy failed")
  local selected
  for slot=1,variants do local entry=db.get(slot)
    if entry and B.identity(entry)==B.identity(item.stack) then selected=slot; break end
  end
  assert(selected,"database changed bee NBT; export blocked")
  local bus=self.components:proxy(cfg.exportAddress,{"setExportConfiguration","exportIntoSlot"})
  assert(bus.setExportConfiguration(cfg.exportSide,1,cfg.database,selected),"cannot configure export bus")
  -- The bus may export a whole stack; keep the exact excess in the local hub.
  self.inv.state.pendingExternal={kind="ME_EXPORT",owner=owner,dest=buffer,slot=dstSlot,identity=B.identity(item.stack)}
  self.inv.save()
  local ok,result=pcall(bus.exportIntoSlot,cfg.exportSide,dstSlot)
  bus.setExportConfiguration(cfg.exportSide,1) -- clear even on failed export
  local got=self.inv:get(buffer,dstSlot)
  assert(ok and result and got and B.identity(got)==B.identity(item.stack),"AE2 export failed/uncertain; inspect buffer and run doctor")
  self.inv.state.pendingExternal=nil; self.inv.save()
  local physical={endpoint=buffer,slot=dstSlot,stack=got}
  local deposited=self.inv:move(physical,bridge,self.inv:destination(bridge,got),got.size,owner)
  return {endpoint=endpoint,slot=deposited.slot,stack=self.inv:get(endpoint,deposited.slot)}
end
function M:deposit(item,endpoint,owner)
  -- Real inventory receipt, with ME storage bus exposing this exact physical archive.
  return self.chest:deposit(item,endpoint,owner)
end
function M:reconcile()
  local x=self.inv.state.pendingExternal
  if not x then return true end
  local b=self.components:proxy(self.config.exportAddress,{"setExportConfiguration"})
  b.setExportConfiguration(self.config.exportSide,1)
  local got=self.inv:get(x.dest,x.slot)
  if got and B.identity(got)==x.identity then
    self.inv.state.pendingExternal=nil; self.inv.save(); return true
  end
  return false,"AE2 export receipt ambiguous; inspect isolated buffer, preserve stock"
end
return M
