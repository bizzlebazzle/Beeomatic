local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M
function M.new(config,inv,state,save,now,storage)
  return setmetatable({config=config,inv=inv,state=state,save=save,now=now,storage=storage},M)
end
function M:outputs()
  local c=self.config; local items={}
  if c.outputSlots then
    for _,slot in ipairs(c.outputSlots) do local stack=self.inv:get(c.output,slot)
      if stack then items[#items+1]={endpoint=c.output,slot=slot,stack=stack} end
    end
  else items=self.inv:scan(c.output) end
  return items
end
function M:empty()
  local seen={}
  for _,ep in ipairs({self.config.input,self.config.output}) do
    local key=ep.transposer..":"..ep.side
    if not seen[key] then for _,item in ipairs(self.inv:scan(ep)) do if B.kind(item.stack) then return false end end end
    seen[key]=true
  end
  return true
end
function M:validate()
  local c=self.config
  assert(c.enabled,"Shared scanner required: configure it to inspect all initial drone variants")
  if c.mode=="external" then
    self.storage:port(c.storage); self.inv:size(c.input)
    assert(c.storage.transposer==c.input.transposer and c.storage.side~=c.input.side,
      "scanner input chest and Interface need separate sides of the same transposer")
    return
  end
  assert(c.isolatedVerified,"verify isolated shared scanner input/output and equal-count analysis")
  self.storage:port(c.storage); local size=self.inv:size(c.input); self.inv:size(c.output)
  U.assertNumber(c.inputSlot,1,size)
  assert(c.storage.side~=c.input.side and c.storage.side~=c.output.side,"scanner input/output cannot use its Interface inventory")
  if c.outputSlots then
    assert(#c.outputSlots>0,"scanner output slots required")
    local seen={}
    for _,slot in ipairs(c.outputSlots) do
      U.assertNumber(slot,1,self.inv:size(c.output)); assert(not seen[slot],"duplicate scanner output slot"); seen[slot]=true
    end
  end
  if c.input.transposer==c.output.transposer and c.input.side==c.output.side then
    assert(c.outputSlots and #c.outputSlots>0,"direct analyser access needs explicit output slots")
    local seen={}
    for _,slot in ipairs(c.outputSlots) do
      U.assertNumber(slot,1,self.inv:size(c.output)); assert(slot~=c.inputSlot and not seen[slot],"scanner input/output slots overlap"); seen[slot]=true
    end
  end
  assert(c.input.transposer==c.storage.transposer and c.output.transposer==c.storage.transposer,
    "shared scanner and Interface need the same transposer")
end
function M:finish()
  self.inv:release("scanner"); self.state.scan=nil; self.save()
  return false,"Scanner batch returned; rescanning ME stock"
end
-- Count both cells and local Interface buffers so refill/cleanup cannot look like
-- a new analysed return. Other raw insertions are filtered by physical inspection;
-- external pipes must remain the sole producer of analysed returns on this path.
function M:snapshot(name,damage)
  local result={}
  local function add(s)
    if s and B.kind(s) and (not name or (s.name==name and s.damage==damage)) then
      local key=B.identity(s)
      if result[key] then result[key].size=result[key].size+s.size else result[key]=U.copy(s) end
    end
  end
  local filter=name and {name=name,damage=damage} or nil
  for _,s in pairs(assert(self.storage:network().getItemsInNetwork(filter),"ME network unavailable")) do add(s) end
  for _,ep in ipairs(self.storage.config.endpoints) do for _,i in ipairs(self.inv:scan(ep)) do add(i.stack) end end
  return result
end
-- ME omits individual data on many installations. Inspect one exact-NBT bee
-- before treating a new variant as an analysed return. Raw additions stay in ME
-- for a later batch; analysis changes their identity so this cache cannot hide
-- the eventual analysed return. Persist the probe so restart reuses its request.
function M:inspectReturn(q)
  local probe=q.returnProbe
  if probe.phase~="CLEANUP" then
    local physical=self.storage:materialize(probe.item,self.config.storage,"scanner",1)
    q.returnChecks=q.returnChecks or {}
    q.returnChecks[B.identity(probe.item.stack)]=B.scanned(physical.stack)
    probe.phase="CLEANUP"; self.save()
  end
  self.storage:cancel("scanner")
  q.returnProbe=nil; self.save()
end
function M:externalResult(q)
  if q.returnProbe then self:inspectReturn(q) end
  local result
  for key,s in pairs(self:snapshot(q.name,q.damage)) do
    local before=q.before[key] or 0
    local delta=s.size-before
    if key~=q.identity and s.name==q.name and s.damage==q.damage and delta>0 then
      if not q.returnChecks or q.returnChecks[key]==nil then
        q.returnProbe={item={network=true,endpoint={id="ME"},slot=key,stack=U.copy(s)}}; self.save()
        self:inspectReturn(q)
      end
      -- Analysis preserves species identity. A different physically inspected
      -- species cannot be this batch's return, even if it was added analysed.
      -- Use the existing catalogue so interrupted batches with boolean checks
      -- from earlier versions recover without resetting their saved baseline.
      local genome=self.state.aeCatalog[key]
      local wrongSpecies=q.ident and genome and genome.ident and genome.ident~=q.ident
      if q.returnChecks[key] and not wrongSpecies then
        assert(not result,"multiple possible scanner returns; preserve stock and audit the external path")
        assert(delta<=q.count,"scanner return count exceeds the reserved batch; audit external insertions")
        result={network=true,endpoint={id="ME"},slot=key,stack=U.copy(s)}
        result.stack.size=delta
      end
    end
  end
  if not result or result.stack.size<q.count then
    assert(self.now()-q.started<(self.config.timeout or 600),
      "Shared scanner timeout: check chest extraction, honey/power and return pipes to ME; batch preserved")
    return false,"Waiting for analysed bees to return through ME"
  end
  assert(self:empty(),"external scanner input still contains bees after a complete return; audit the path")
  -- Preserve the exact return identity before requesting it for inspection.
  q.resultItem=result; q.before=nil; q.returnChecks=nil; q.phase="VERIFYING"; self.save()
  return self:verifyExternal(q)
end
function M:verifyExternal(q)
  local physical=self.storage:materialize(q.resultItem,self.config.storage,"scanner",q.count)
  local s=physical.stack
  assert(B.scanned(s) and s.name==q.name and s.damage==q.damage and B.kind(s)==B.kind(q.item.stack),
    "external scanner returned an unanalysed or wrong-caste bee; batch preserved")
  if q.ident then assert(s.individual.ident==q.ident,"external scanner changed bee species identity") end
  if q.batchId then
    local old=assert(self.state.meBatches[q.batchId],"scanner batch disappeared")
    assert(old.identity==q.identity and old.count>=q.count,"scanner provenance changed")
    if old.count==q.count then old.identity=B.identity(s); old.stack=U.copy(s)
    else
      old.count=old.count-q.count
      local split=U.copy(old); split.identity=B.identity(s); split.count=q.count; split.stack=U.copy(s)
      self.state.meBatches[q.batchId.."/external/"..q.sequence]=split
    end
  end
  q.returned=true; q.phase="EXTERNAL_RETURNED"; self.save()
  self.storage:cancel("scanner"); return self:finish()
end
function M:step(items)
  local c=self.config; local q=self.state.scan
  if not q then
    local candidate
    for _,i in ipairs(items) do if B.kind(i.stack) and not B.scanned(i.stack) then candidate=i; break end end
    if not candidate then return true end
    self:validate()
    assert(self:empty(),"shared scanner contains unrelated stock; audit before starting")
    local count=math.min(candidate.stack.size,candidate.stack.maxSize or 64,c.batchSize or 64)
    q={phase="REQUESTING",item=U.copy(candidate),identity=B.identity(candidate.stack),batchId=candidate.batchId,
      name=candidate.stack.name,damage=candidate.stack.damage,count=count,
      ident=candidate.stack.individual and candidate.stack.individual.ident,started=self.now()}
    if c.mode=="external" then
      self.state.scannerSequence=(self.state.scannerSequence or 0)+1; q.sequence=self.state.scannerSequence
      q.before={}; for key,s in pairs(self:snapshot(q.name,q.damage)) do q.before[key]=s.size end
    end
    self.state.scan=q; self.save()
  end
  if q.phase=="EXTERNAL_RETURNED" then self.storage:cancel("scanner"); return self:finish() end
  if q.phase=="VERIFYING" then return self:verifyExternal(q) end
  if q.phase=="INSPECTED" then
    self.storage:cancel("scanner"); return self:finish()
  end
  if q.phase=="REQUESTING" then
    self:validate()
    local physical=self.storage:materialize(q.item,c.storage,"scanner",q.count)
    q.ident=q.ident or (physical.stack.individual and physical.stack.individual.ident)
    if B.scanned(physical.stack) then
      -- An ME record without chromosomes is not proof the item needs analysis.
      -- materialize already persisted the physical genome with its receipt.
      q.phase="INSPECTED"; self.save()
      self.storage:cancel("scanner"); return self:finish()
    end
    q.source={endpoint=U.copy(physical.endpoint),slot=physical.slot}
    q.inputSlot=c.mode=="external" and self.inv:empty(c.input) or c.inputSlot
    q.phase="INSERTING"; self.save()
  end
  if q.phase=="INSERTING" then
    local request=self.state.meRequests[U.location(q.source.endpoint,q.source.slot)]
    if not q.inserted and not (request and request.consumed) then
      local stack=assert(self.inv:get(q.source.endpoint,q.source.slot),"scanner source disappeared; audit before retry")
      assert(B.identity(stack)==q.identity and stack.size==q.count,"scanner source changed")
      assert(self:empty(),"scanner input insertion ambiguous")
      self.inv:move({endpoint=q.source.endpoint,slot=q.source.slot,stack=stack,batchId=q.batchId,scanning=true},
        c.input,q.inputSlot or c.inputSlot,q.count,"scanner",function(got,n)
          -- The analyser may consume its input immediately; its isolated output
          -- is verified later. A persisted positive transfer count witnesses input acceptance.
          return not got and n==q.count
        end)
    end
    q.phase="PROCESSING"; q.started=self.now(); self.save()
    self.storage:releasePort(c.storage)
    return false,"Shared scanner analysing "..q.count.." bees"
  end
  if q.phase=="PROCESSING" then
    self.storage:releasePort(c.storage)
    if c.mode=="external" then return self:externalResult(q) end
    local results=self:outputs(); assert(#results<=1,"scanner output contaminated; expected one isolated stack")
    local r=results[1]
    if not r then
      assert(self.now()-q.started<(c.timeout or 600),"Shared scanner timeout: check honey/power; batch preserved")
      return false,"Shared scanner processing reserved batch"
    end
    assert(not self.inv:get(c.input,c.inputSlot),"scanner still contains input when output appeared")
    assert(B.scanned(r.stack) and r.stack.name==q.name and r.stack.damage==q.damage and r.stack.size==q.count,
      "scanner output identity/count mismatch")
    if q.ident then assert(r.stack.individual.ident==q.ident,"scanner changed bee species identity") end
    q.outputSlot=r.slot; q.result=U.copy(r.stack); q.returnAfter=self.state.transferSequence or 0
    q.phase="RETURNING"; self.save()
  end
  if q.phase=="RETURNING" then
    for _,tx in ipairs(self.state.transactions) do
      if tx.owner=="scanner" and tx.id>q.returnAfter and tx.dest.managed and tx.identity==B.identity(q.result) and tx.count==q.count then
        return self:finish()
      end
    end
    local stack=assert(self.inv:get(c.output,q.outputSlot),"scanner return ambiguous; preserve ME stock and audit")
    assert(B.identity(stack)==B.identity(q.result) and stack.size==q.count,"scanner output changed before return")
    self.storage:deposit({endpoint=c.output,slot=q.outputSlot,stack=stack,
      transform={batchId=q.batchId,identity=q.identity}},c.storage,"scanner")
    return self:finish()
  end
  error("unknown shared scanner phase; audit saved scanner state")
end
return M
