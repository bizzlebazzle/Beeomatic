local U=require("lib.util"); local B=require("lib.bees")
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
  assert(not dst,"destination must be empty: "..dest.id..":"..slot)
  assert(count>0 and count<=src.size,"invalid transfer amount")
  local tx={source=U.copy(item.endpoint),slot=item.slot,dest=U.copy(dest),destSlot=slot,
    identity=B.identity(src),before=src.size,count=count,owner=owner,phase="INTENT"}
  self.state.pending=tx; self.save()
  local ok,n=pcall(self:proxy(item.endpoint).transferItem,item.endpoint.side,dest.side,count,item.slot,slot)
  local after=self:get(item.endpoint,item.slot); local got=self:get(dest,slot)
  local removed=src.size-(after and after.size or 0)
  local sameSource=not after or B.identity(after)==tx.identity
  local witnessed=got and B.identity(got)==tx.identity and got.size==removed
  if not witnessed and receipt then witnessed=receipt(got,removed) end
  if not ok or type(n)~="number" or n<=0 or removed~=n or n~=count or not sameSource or not witnessed then
    tx.phase="UNCERTAIN"; tx.returned=ok and n or tostring(n); self.save()
    error("transfer uncertain or rejected; inspect source/destination, run doctor: "..owner)
  end
  tx.phase="COMMITTED"; self.state.transactions[#self.state.transactions+1]=tx
  if #self.state.transactions>64 then table.remove(self.state.transactions,1) end
  self.state.pending=nil; self.save()
  return {endpoint=dest,slot=slot,stack=got}
end
function M:reconcile()
  local tx=self.state.pending; if not tx then return true end
  local src=self:get(tx.source,tx.slot); local dst=self:get(tx.dest,tx.destSlot)
  if src and src.size==tx.before and B.identity(src)==tx.identity and not dst then
    self.state.pending=nil; self.save(); return true -- proven no movement, scheduler can retry after rescan
  end
  if (not src or (src.size==tx.before-tx.count and B.identity(src)==tx.identity)) and
    dst and dst.size==tx.count and B.identity(dst)==tx.identity then
    tx.phase="COMMITTED_RECOVERED"; self.state.transactions[#self.state.transactions+1]=tx
    self.state.pending=nil; self.save(); return true
  end
  return false,"Ambiguous movement owned by "..tx.owner.."; preserve both inventories. No automatic replay."
end
return M
