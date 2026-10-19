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
function M:validate()
  local c=self.config
  assert(c.enabled,"Shared scanner required: configure it to inspect all initial drone variants")
  assert(c.isolatedVerified,"verify isolated shared scanner input/output and equal-count analysis")
  self.storage:port(c.storage); local size=self.inv:size(c.input); self.inv:size(c.output)
  U.assertNumber(c.inputSlot,1,size)
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
function M:step(items)
  local c=self.config; local q=self.state.scan
  if not q then
    local candidate
    for _,i in ipairs(items) do if B.kind(i.stack) and not B.scanned(i.stack) then candidate=i; break end end
    if not candidate then return true end
    self:validate()
    assert(not self.inv:get(c.input,c.inputSlot) and #self:outputs()==0,"shared scanner contains unrelated stock; audit before starting")
    local count=math.min(candidate.stack.size,candidate.stack.maxSize or 64,c.batchSize or 64)
    q={phase="REQUESTING",item=U.copy(candidate),identity=B.identity(candidate.stack),batchId=candidate.batchId,
      name=candidate.stack.name,damage=candidate.stack.damage,count=count,
      ident=candidate.stack.individual and candidate.stack.individual.ident,started=self.now()}
    self.state.scan=q; self.save()
  end
  if q.phase=="INSPECTED" then
    self.storage:cancel("scanner"); return self:finish()
  end
  if q.phase=="REQUESTING" then
    self:validate()
    local physical=self.storage:materialize(q.item,c.storage,"scanner",q.count)
    q.ident=q.ident or (physical.stack.individual and physical.stack.individual.ident)
    if B.scanned(physical.stack) then
      -- An ME record without chromosomes is not proof the item needs analysis.
      self.storage:catalogue(physical.stack); q.phase="INSPECTED"; self.save()
      self.storage:cancel("scanner"); return self:finish()
    end
    q.source={endpoint=U.copy(physical.endpoint),slot=physical.slot}; q.phase="INSERTING"; self.save()
  end
  if q.phase=="INSERTING" then
    local request=self.state.meRequests[U.location(q.source.endpoint,q.source.slot)]
    if not (request and request.consumed) then
      local stack=assert(self.inv:get(q.source.endpoint,q.source.slot),"scanner source disappeared; audit before retry")
      assert(B.identity(stack)==q.identity and stack.size==q.count,"scanner source changed")
      assert(not self.inv:get(c.input,c.inputSlot) and #self:outputs()==0,"scanner input insertion ambiguous")
      self.inv:move({endpoint=q.source.endpoint,slot=q.source.slot,stack=stack,batchId=q.batchId,scanning=true},
        c.input,c.inputSlot,q.count,"scanner",function(got,n)
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
