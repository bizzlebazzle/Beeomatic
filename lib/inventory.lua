local U=require("lib.util"); local B=require("lib.bees"); local Receipts=require("lib.storage.receipts")
local M={}; M.__index=M
function M.new(components,state,save)
  state.transactions=state.transactions or {}; state.reservations=state.reservations or {}
  return setmetatable({components=components,state=state,save=save},M)
end
function M:proxy(ep) return self.components:proxy(ep.transposer,{"getInventorySize","getStackInSlot","transferItem"}) end
function M:size(ep) return assert(self:proxy(ep).getInventorySize(ep.side),"inventory unavailable: "..ep.id) end
function M:get(ep,slot) self:size(ep); return self:proxy(ep).getStackInSlot(ep.side,slot) end
function M:scan(ep)
  local r={}; for s=1,self:size(ep) do local stack=self:get(ep,s)
    if stack then r[#r+1]={endpoint=ep,slot=s,stack=stack} end
  end; return r
end
function M:empty(ep)
  for s=1,self:size(ep) do if not self:get(ep,s) then return s end end
  error("inventory full: "..ep.id)
end
function M:destination(ep,stack)
  if (not B.kind(stack) or B.scanned(stack) or type(stack.tag)=="string") then
    for _,i in ipairs(self:scan(ep)) do
      if B.identity(i.stack)==B.identity(stack) and i.stack.size+stack.size<=(i.stack.maxSize or 1) and
        not self.state.reservations[U.location(ep,i.slot)] then return i.slot end
    end
  end
  return self:empty(ep)
end
function M:reserve(item,owner)
  local k=U.location(item.endpoint,item.slot); local old=self.state.reservations[k]
  assert(not old or old.owner==owner,"item already reserved: "..k)
  local actual=self:get(item.endpoint,item.slot)
  assert(actual and B.identity(actual)==B.identity(item.stack),"source identity changed")
  self.state.reservations[k]={owner=owner,identity=B.identity(actual)}; self.save(); return k
end
function M:release(owner)
  for k,v in pairs(self.state.reservations) do if v.owner==owner then self.state.reservations[k]=nil end end
  self.save()
end
function M:move(item,dest,slot,count,owner,receipt)
  assert(not self.state.pending,"unresolved transfer; reconcile before moving anything")
  assert(item.endpoint.transposer==dest.transposer,"transfer endpoints must share a transposer")
  self:reserve(item,owner)
  local src=self:get(item.endpoint,item.slot); local dst=self:get(dest,slot)
  assert(not dst or (B.identity(dst)==B.identity(src) and dst.size+count<=(dst.maxSize or 1)),
    "destination is incompatible/full: "..dest.id..":"..slot)
  assert(count>0 and count<=src.size,"invalid transfer amount")
  local tx={source=U.copy(item.endpoint),slot=item.slot,dest=U.copy(dest),destSlot=slot,
    identity=B.identity(src),before=src.size,destBefore=dst and dst.size or 0,count=count,owner=owner,phase="INTENT",
    stack=(item.endpoint.managed or dest.managed) and U.copy(src) or nil,
    batchId=item.batchId,scanning=item.scanning,transform=U.copy(item.transform)}
  self.state.transferSequence=(self.state.transferSequence or 0)+1; tx.id=self.state.transferSequence
  self.state.pending=tx; self.save()
  local ok,n=pcall(self:proxy(item.endpoint).transferItem,item.endpoint.side,dest.side,count,item.slot,slot)
  if ok and type(n)=="number" then tx.returned=n; tx.phase="MOVED"; self.save() end
  local after=self:get(item.endpoint,item.slot); local got=self:get(dest,slot)
  local removed=src.size-(after and after.size or 0)
  local sameSource=not after or B.identity(after)==tx.identity
  local received=item.endpoint.managed and type(n)=="number" and n or removed
  local witnessed=got and B.identity(got)==tx.identity and got.size==tx.destBefore+received
  if not witnessed and receipt then witnessed=receipt(got,received) end
  if dest.managed and not got and ok and removed==n then witnessed=true end
  local sourceProven=removed==n or (item.endpoint.managed and n==count)
  if not ok or type(n)~="number" or n<=0 or not sourceProven or n~=count or not sameSource or not witnessed then
    tx.phase="UNCERTAIN"; tx.returned=ok and n or tostring(n); self.save()
    error("transfer uncertain or rejected; inspect source/destination, run doctor: "..owner)
  end
  tx.phase="COMMITTED"; Receipts.commit(self.state,tx); self.state.transactions[#self.state.transactions+1]=tx
  if #self.state.transactions>64 then table.remove(self.state.transactions,1) end
  -- Source slot numbers may immediately be reused by unrelated offspring. The
  -- selected units have moved; do not lease that location through an entire cycle.
  self.state.reservations[U.location(item.endpoint,item.slot)]=nil
  self.state.pending=nil; self.save()
  if dest.managed then
    local stack=U.copy(src); stack.size=count
    local id=self.state.meBatches["receipt/"..tx.id] and ("receipt/"..tx.id) or nil
    return {network=true,endpoint={id="ME"},slot=id or tx.identity,batchId=id,root=id,owner=owner,stack=stack}
  end
  return {endpoint=dest,slot=slot,stack=got}
end
function M:reconcile()
  local tx=self.state.pending; if not tx then return true end
  local src=self:get(tx.source,tx.slot); local dst=self:get(tx.dest,tx.destSlot)
  local oldDest=(not dst and (tx.destBefore or 0)==0) or (dst and dst.size==tx.destBefore and B.identity(dst)==tx.identity)
  if tx.source.managed or tx.dest.managed then
    -- A saved callback count is a physical acceptance receipt. Without it, only
    -- a stable ordinary destination/source can independently prove the movement.
    local sourceProof=(not src and tx.before==tx.count) or
      (src and src.size==tx.before-tx.count and B.identity(src)==tx.identity)
    local destProof=dst and dst.size==(tx.destBefore or 0)+tx.count and B.identity(dst)==tx.identity
    if (tx.returned==tx.count and ((tx.dest.managed and sourceProof) or (tx.source.managed and (destProof or tx.scanning or tx.dest.managed)))) or
      (tx.source.managed and destProof) or (tx.dest.managed and sourceProof and destProof) then
      tx.phase="COMMITTED_RECOVERED"; Receipts.commit(self.state,tx)
      self.state.transactions[#self.state.transactions+1]=tx; self.state.pending=nil
      self.state.reservations[U.location(tx.source,tx.slot)]=nil; self.save(); return true
    end
    if not tx.returned and not tx.source.managed and src and src.size==tx.before and B.identity(src)==tx.identity and oldDest then
      self.state.pending=nil; self.state.reservations[U.location(tx.source,tx.slot)]=nil; self.save(); return true
    end
    return false,"Ambiguous Interface movement owned by "..tx.owner.."; audit before replay"
  end
  if src and src.size==tx.before and B.identity(src)==tx.identity and oldDest then
    self.state.pending=nil; self.state.reservations[U.location(tx.source,tx.slot)]=nil
    self.save(); return true -- proven no movement, scheduler can retry after rescan
  end
  if (not src or (src.size==tx.before-tx.count and B.identity(src)==tx.identity)) and
    dst and dst.size==(tx.destBefore or 0)+tx.count and B.identity(dst)==tx.identity then
    tx.phase="COMMITTED_RECOVERED"; self.state.transactions[#self.state.transactions+1]=tx
    self.state.pending=nil; self.state.reservations[U.location(tx.source,tx.slot)]=nil; self.save(); return true
  end
  local removed=tx.before-(src and src.size or 0)
  if removed>0 and removed<tx.count and (not src or B.identity(src)==tx.identity) and
    dst and B.identity(dst)==tx.identity and dst.size==(tx.destBefore or 0)+removed then
    tx.requested=tx.count; tx.count=removed; tx.phase="PARTIAL_RECOVERED"
    self.state.transactions[#self.state.transactions+1]=tx; self.state.pending=nil
    self.state.reservations[U.location(tx.source,tx.slot)]=nil; self.save(); return true
  end
  return false,"Ambiguous movement owned by "..tx.owner.."; preserve both inventories. No automatic replay."
end
return M
