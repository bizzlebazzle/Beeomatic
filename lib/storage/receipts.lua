-- Apply logical ME ownership in the same save as a verified physical receipt.
local B=require("lib.bees"); local U=require("lib.util")
local M={}
function M.commit(state,tx)
  if tx.meApplied then return end
  state.meBatches=state.meBatches or {}; state.meRequests=state.meRequests or {}; state.aeCatalog=state.aeCatalog or {}
  if tx.source.managed then
    local request=state.meRequests[U.location(tx.source,tx.slot)]
    assert(request and request.owner==tx.owner and request.identity==tx.identity,"missing managed source request")
    request.consumed=true
    if tx.batchId and not tx.scanning then
      local batch=assert(state.meBatches[tx.batchId],"selected batch disappeared")
      batch.count=batch.count-tx.count; assert(batch.count>=0,"batch overspent")
      if batch.count==0 then state.meBatches[tx.batchId]=nil end
    end
  end
  if tx.dest.managed then
    local stack=assert(tx.stack)
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
      state.meBatches[id]={root=id,owner=tx.owner,identity=tx.identity,count=tx.count,stack=U.copy(stack)}
    end
  end
  tx.meApplied=true
end
return M
