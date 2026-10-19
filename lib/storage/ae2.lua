local Chest=require("lib.storage.chest"); local B=require("lib.bees"); local U=require("lib.util")
local Export=require("lib.storage.ae2_export")
local M={}; M.__index=M
function M.new(config,inv,components,runtime)
  return setmetatable({config=config,inv=inv,components=components,chest=Chest.new(config,inv),
    exporter=Export.new(components,inv,runtime)},M)
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
  -- Stop a saved/current redstone export before network or inventory checks can fail.
  self:stopExport()
  self.chest:validate(); self:network()
  assert(self.config.storageBusVerified,"verify archive chest storage bus and dedicated subnet")
  self.exporter:validate(self.config)
  self.components:proxy(self.config.database,{"clear","get"})
  assert(self.config.exportIsolated,"disable autonomous export with redstone card; remove fuzzy cards")
  return true
end
function M:stopExport()
  local x=self.inv.state.pendingExternal
  if x and x.exportAddress then
    local ok,err=self.exporter:shutdown(x); assert(ok,err)
  elseif self.config.exportMode=="redstone" then
    self.exporter:off({mode="redstone",gate=self.config.exportGate})
  end
end
function M:networkCount(x)
  local n=0
  for _,s in pairs(assert(self:network().getItemsInNetwork(x.filter),"ME unavailable while reconciling export")) do
    if B.identity(s)==x.identity then n=n+(s.size or 0) end
  end
  return n
end
function M:archiveExport(x)
  local items=self.exporter:receipts(x); local first
  assert(x.bridge,"restore a reachable archive bridge before recovering export")
  for _,item in ipairs(items) do
    local physical=self.inv:move(item,x.bridge,self.inv:destination(x.bridge,item.stack),item.stack.size,x.owner)
    first=first or physical
    x.archivedCount=(x.archivedCount or 0)+item.stack.size; self.inv.save()
  end
  x.phase="ARCHIVED"; self.inv.state.lastExternalExport=U.copy(x)
  self.inv.state.pendingExternal=nil; self.inv.save(); return first
end
function M:materialize(item,endpoint,owner)
  if not item.network and item.endpoint.id==endpoint.id then return self.chest:materialize(item,endpoint) end
  self:validate()
  assert(not self.inv.state.pending and not self.inv.state.pendingExternal,"unresolved movement; reconcile before another export")
  assert(type(item.stack.tag)=="string","Exact AE2 export requires compressed NBT tags. Enable server OC allowItemStackNBTTags and probe first")
  local cfg=self.config; local buffer=assert(cfg.buffer,"register ME export buffer")
  local bridge
  for _,ep in ipairs(cfg.endpoints) do
    if ep.id==endpoint.id and ep.transposer==buffer.transposer then bridge=ep; break end
  end
  assert(bridge,"ME export buffer needs a transposer view of the selected physical archive")
  assert(buffer.id~=bridge.id and buffer.side~=bridge.side,"ME export buffer must be isolated from archive")
  local x={kind="ME_EXPORT",mode=cfg.exportMode or "callback",owner=owner,dest=U.copy(buffer),bridge=U.copy(bridge),
    slot=self.inv:empty(buffer),identity=B.identity(item.stack),exportAddress=cfg.exportAddress,exportSide=cfg.exportSide,
    gate=U.copy(cfg.exportGate),timeout=cfg.exportTimeout or 60,pollSeconds=cfg.exportPollSeconds or 1,
    transferAfter=self.inv.state.transferSequence or 0,phase="INTENT"}
  self.exporter:preflight(x)
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
  x.before=total; x.filter=filter
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
  -- Intent is durable BEFORE setting the filter or enabling any physical export.
  self.inv.state.pendingExternal=x
  self.inv.save()
  local _,count=self.exporter:run(x,cfg.database,selected)
  if x.mode=="redstone" then assert(self:networkCount(x)==x.before-count,"ME source delta disagrees with physical export receipts") end
  local deposited=assert(self:archiveExport(x))
  return {endpoint=endpoint,slot=deposited.slot,stack=self.inv:get(endpoint,deposited.slot)}
end
function M:deposit(item,endpoint,owner)
  -- Real inventory receipt, with ME storage bus exposing this exact physical archive.
  return self.chest:deposit(item,endpoint,owner)
end
function M:reconcile()
  local x=self.inv.state.pendingExternal
  if not x then self:stopExport(); return true end
  -- Older journals did not snapshot bridge/bus metadata. Never start a new export.
  x.exportAddress=x.exportAddress or self.config.exportAddress
  x.exportSide=x.exportSide or self.config.exportSide
  x.mode=x.mode or "callback"
  if not x.bridge then for _,ep in ipairs(self.config.endpoints) do
    if ep.transposer==x.dest.transposer then x.bridge=U.copy(ep); break end
  end end
  local stopped,err=self.exporter:shutdown(x); if not stopped then return false,err end
  local items,count=self.exporter:receipts(x)
  if x.mode=="redstone" and x.before then
    assert(self:networkCount(x)==x.before-count,"ME counts do not reconcile with isolated export buffer; audit actual stock")
  end
  local committed=0
  for _,tx in ipairs(self.inv.state.transactions or {}) do
    if x.transferAfter and tx.id and tx.id>x.transferAfter and tx.owner==x.owner and
      tx.source.id==x.dest.id and tx.identity==x.identity and x.bridge and tx.dest.id==x.bridge.id then
      committed=committed+tx.count
    end
  end
  local archived=math.max(x.archivedCount or 0,committed); x.archivedCount=archived
  if x.receivedCount then assert(count+archived==x.receivedCount,"export receipts disagree with saved archive movements; audit actual stock") end
  if #items>0 then self:archiveExport(x); return true end
  if archived>0 or x.mode=="redstone" then
    x.phase=archived>0 and "ARCHIVED_RECOVERED" or "NO_MOVEMENT_CONFIRMED"
    self.inv.state.lastExternalExport=U.copy(x); self.inv.state.pendingExternal=nil; self.inv.save(); return true
  end
  return false,"AE2 export receipt ambiguous; inspect isolated buffer, preserve stock"
end
return M
