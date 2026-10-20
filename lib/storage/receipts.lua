-- Apply logical ME ownership in the same save as a verified physical receipt.
local B=require("lib.bees"); local U=require("lib.util")
local M={}
function M.skipField(key,field,parent)
  -- Consume obsolete payloads without building them. This does not depend on
  -- manual garbage collection being available in the host sandbox.
  return parent=="transactions" and type(field)=="number" and (key=="stack" or key=="transform")
end
function M.compact(tx)
  -- Completed receipt consumers use identity/count/endpoints, never the full
  -- bee genome or the already-applied ownership transform. Pending intent keeps both.
  tx.stack=nil; tx.transform=nil
end
function M.decoded(value,field,parent)
  if parent=="transactions" and type(field)=="number" then
    local bulky=value.stack or value.transform
    M.compact(value)
    -- Large legacy NBT strings otherwise survive until the next collector cycle,
    -- colliding with the following record's string-concatenation buffer.
    if bulky then bulky=nil; U.collect() end
  elseif parent=="jobs" and type(field)=="number" and not value.machine and
    (value.state=="WAITING" or value.state=="DONE") then
    value.expectedPrincess=nil; value.preparedPrincess=nil; value.preparedDrone=nil
  end
end
function M.archive(state,tx)
  M.compact(tx)
  local history=state.transactions
  history[#history+1]=tx
  if #history>64 then table.remove(history,1) end
end
function M.commit(state,tx)
  if tx.meApplied then return end
  if not tx.source.managed and not tx.dest.managed then return end
  state.meBatches=state.meBatches or {}; state.meRequests=state.meRequests or {}; state.aeCatalog=state.aeCatalog or {}
  if tx.source.managed then
    local request=state.meRequests[U.location(tx.source,tx.slot)]
    assert(request and request.owner==tx.owner and request.identity==tx.identity,"missing managed source request")
    request.consumed=true
    if tx.scanning and state.scan then state.scan.inserted=true; state.scan.count=tx.count end
    if tx.batchId and not tx.scanning then
      local batch=assert(state.meBatches[tx.batchId],"selected batch disappeared")
      batch.count=batch.count-tx.count; assert(batch.count>=0,"batch overspent")
      if batch.count==0 then state.meBatches[tx.batchId]=nil end
    end
  end
  if tx.dest.managed then
    local stack=U.copy(assert(tx.stack)); stack.size=tx.count
    if B.scanned(stack) then state.aeCatalog[tx.identity]=U.copy(stack.individual) end
    if tx.transform and tx.transform.batchId then
      local id=tx.transform.batchId; local old=assert(state.meBatches[id],"scanner batch disappeared")
      assert(old.identity==tx.transform.identity and old.count>=tx.count,"scanner provenance changed")
      if old.count==tx.count then old.identity=tx.identity; old.stack=U.copy(stack)
      else
        old.count=old.count-tx.count
        local split=U.copy(old); split.identity=tx.identity; split.count=tx.count; split.stack=U.copy(stack)
        state.meBatches[id.."/"..tx.id]=split
      end
    elseif B.kind(stack) and tx.owner~="scanner" then
      local id="receipt/"..tx.id
      state.meBatches[id]={root=id,sequence=tx.id,owner=tx.owner,identity=tx.identity,count=tx.count,stack=U.copy(stack)}
    end
    if tx.owner=="scanner" and tx.transform and state.scan then state.scan.returned=true end
  end
  tx.meApplied=true
end
return M
