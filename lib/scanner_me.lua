local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M
function M.new(config,inv,state,save,now,storage)
  return setmetatable({config=config,inv=inv,state=state,save=save,now=now,storage=storage},M)
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
  assert(c.mode=="buffered" and c.input and c.output,
    "scanner layout retired: finish outstanding work with the previous version, then run setup for input/output chests")
  self.storage:port(c.storage); self.inv:size(c.input); self.inv:size(c.output)
  assert(c.input.transposer==c.storage.transposer and c.output.transposer==c.storage.transposer,
    "scanner chests and Interface need the same transposer")
  assert(c.storage.side~=c.input.side and c.storage.side~=c.output.side and c.input.side~=c.output.side,
    "scanner input chest, output chest and Interface need separate sides")
end
function M:finish()
  self.inv:release("scanner"); self.state.scan=nil; self.save()
  return false,"Scanner batch returned; rescanning ME stock"
end
function M:step(items)
  local c=self.config; local q=self.state.scan
  assert(c.mode=="buffered","scanner layout retired: run setup for input/output chests after resolving old scanner work")
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
    self.state.scan=q -- materialize saves this batch with its Interface intent
  end
  if q.phase=="INSPECTED" then
    self.storage:cancel("scanner"); return self:finish()
  end
  if q.phase=="REQUESTING" then
    local physical=self.storage:materialize(q.item,c.storage,"scanner",q.count)
    q.ident=q.ident or (physical.stack.individual and physical.stack.individual.ident)
    if B.scanned(physical.stack) then
      -- An ME record without chromosomes is not proof the item needs analysis.
      -- materialize already persisted the physical genome with its receipt.
      q.phase="INSPECTED" -- cancel saves this with its filter-clearing intent
      self.storage:cancel("scanner"); return self:finish()
    end
    q.source={endpoint=U.copy(physical.endpoint),slot=physical.slot}
    q.inputSlot=self.inv:empty(c.input)
    q.phase="INSERTING" -- move saves this phase with its transfer intent
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
    q.phase="PROCESSING"; q.started=self.now()
    if not self.storage:releasePort(c.storage) then self.save() end
    return false,"Shared scanner analysing "..q.count.." bees"
  end
  if q.phase=="PROCESSING" then
    self.storage:releasePort(c.storage)
    local results=self.inv:scan(c.output); assert(#results<=1,"scanner output contaminated; expected one isolated stack")
    local r=results[1]
    if r then
      assert(B.scanned(r.stack) and r.stack.name==q.name and r.stack.damage==q.damage and
        B.kind(r.stack)==B.kind(q.item.stack) and r.stack.size<=q.count,"scanner output identity/count mismatch")
      if q.ident then assert(r.stack.individual.ident==q.ident,"scanner changed bee species identity") end
    end
    if not r or r.stack.size<q.count then
      local message="Shared scanner waiting for output: "..(r and r.stack.size or 0).."/"..q.count.." analysed bees in "..c.output.id
      assert(self.now()-q.started<(c.timeout or 600),message.."; timeout: check input chest, pipes, scanner power/honey and output route; batch preserved")
      return false,message
    end
    for _,i in ipairs(self.inv:scan(c.input)) do assert(not B.kind(i.stack),"scanner still contains input when output appeared") end
    q.outputSlot=r.slot; q.result=U.copy(r.stack)
    q.phase="RETURNING" -- deposit saves the verified result with its transfer intent
  end
  if q.phase=="RETURNING" then
    if q.returned then return self:finish() end
    local remaining=q.count-(q.returnedCount or 0)
    local stack=assert(self.inv:get(c.output,q.outputSlot),"scanner return ambiguous; preserve ME stock and audit")
    assert(B.identity(stack)==B.identity(q.result) and stack.size==remaining,"scanner output changed before return")
    self.storage:deposit({endpoint=c.output,slot=q.outputSlot,stack=stack,
      transform={batchId=q.batchId,identity=q.identity}},c.storage,"scanner")
    return self:finish()
  end
  error("unknown shared scanner phase; audit saved scanner state")
end
return M
