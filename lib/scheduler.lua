local U=require("lib.util"); local B=require("lib.bees"); local G=require("lib.genetics")
local E=require("lib.environment"); local J=require("lib.jobs"); local T=require("lib.templates")
local Backend=require("lib.breeders.factory")
local M={}; M.__index=M
function M.new(c,state,components,inv,storage,scanner,save,now)
  state.jobs=state.jobs or {}; state.machines=state.machines or {}; state.events=state.events or {}
  return setmetatable({c=c,state=state,components=components,inv=inv,storage=storage,
    scanner=scanner,save=save,now=now,backends={}},M)
end
function M:log(s)
  self.state.events[#self.state.events+1]={time=self.now(),message=s}
  if #self.state.events>100 then table.remove(self.state.events,1) end
  self.save()
end
function M:pause(j,why)
  J.pause(j,why)
  if j.machine and self.state.machines[j.machine] then
    self.state.machines[j.machine].state="PAUSED"; self.state.machines[j.machine].error=tostring(why)
  end
end
function M:backend(id)
  if self.backends[id] then return self.backends[id] end
  for _,a in ipairs(self.c.alvearies) do if a.id==id then
    local b=Backend.new(a,self.inv,self.components); self.backends[id]=b; return b
  end end
  error("Registered machine missing: "..tostring(id)..". Restore its configuration; bees may still be inside.")
end
function M:items(owner)
  local all=self.storage:scan(); local items={}
  for _,i in ipairs(all) do
    local held=self.state.reservations[U.location(i.endpoint,i.slot)]
    if self.storage.interface and i.owner and i.owner~=owner then held=true end
    for _,j in ipairs(self.state.jobs) do
      local loc=j.lineage
      if j.id~=owner and j.state~="DONE" and loc and loc.endpoint.id==i.endpoint.id and loc.slot==i.slot and
        loc.identity==B.identity(i.stack) then held=true end
    end
    if not held then items[#items+1]=i end
  end
  return items
end
function M:template(j,items)
  local enabled=self.c.templates.enabled
  if j.mode=="imprint" then assert(enabled,"Register an analyzed reference drone with setup first") end
  if not enabled then return nil end
  local f=self.state.flags or {}
  if j.mode~="imprint" and ((j.species==self.state.target and f.nofinalimprint) or
    (j.species~=self.state.target and f.onlyfinalimprint)) then return nil end
  return T.get(self.c.templates,items)
end
function M:protected(i)
  local t=self.c.templates
  return t.enabled and ((t.identity and B.identity(i.stack)==t.identity) or
    (not t.identity and i.endpoint.id==t.endpointId and i.slot==t.slot))
end
function M:count(items,target,kind) return B.count(items,target,kind,true) end
function M:populationMinimum(items,target)
  local low=false
  for _,i in ipairs(items) do
    if B.kind(i.stack)=="princess" and not self:protected(i) and G.purity(i.stack,target)==2 then
      if G.fertility(i.stack)>1 then return self.c.minDrones end
      low=true
    end
  end
  -- A required fertility-one species cannot grow stock. Keep a spendable drone
  -- above the reserve, but do not demand an unreachable population target.
  return low and self.c.reserveDrones+1 or self.c.minDrones
end
function M:conversionDonor(i,items,target)
  return G.purity(i.stack,target)<2 and self:canSpend(i,items) and
    (G.purity(i.stack,target)>0 or G.fertileDonor(i.stack))
end
function M:canSpend(i,items,paired,templateUse)
  if (self:protected(i) and not templateUse) or not B.scanned(i.stack) then return false end
  local s=i.stack; local target=B.species(s.individual.active.species)
  if B.kind(s)=="drone" then
    if templateUse and s.size<=(self.c.templates.reserve or 1) then return false end
    -- Reserve at least one of this exact useful genotype, not merely visible species.
    local same=0
    for _,x in ipairs(items) do if B.kind(x.stack)=="drone" and B.identity(x.stack)==B.identity(s) then same=same+x.stack.size end end
    return same>self.c.reserveDrones
  end
  if B.kind(s)=="princess" then
    if paired and G.purity(s,paired)==2 then return true end -- closed same-species production returns the princess
    return self:count(items,target,"princess")>self.c.reservePrincesses or G.purity(s,target)<2
  end
  return false
end
function M:best(items,kind,target,predicate,template)
  local best,score=nil,-math.huge
  for _,i in ipairs(items) do if B.kind(i.stack)==kind and B.scanned(i.stack) and not self:protected(i) and
    (not predicate or predicate(i)) then
    local n=G.score(i.stack,target,self.c,template)
    if n>score then best,score=i,n end
  end end; return best
end
function M:stockJob(species,mode,count,parent)
  for _,j in ipairs(self.state.jobs) do
    if j.species==species and j.mode==mode and j.state~="DONE" then return j end
  end
  self.state.nextId=(self.state.nextId or 0)+1
  local j={id="job"..self.state.nextId,species=species,mode=mode,count=count,
    dependencies={},state="WAITING",cycles=0,confirmed=0,helper=true,parent=parent.id}
  self.state.jobs[#self.state.jobs+1]=j; self.save(); return j
end
function M:select(j,items,template)
  local target=j.species; local genes=template and template.stack.individual.active
  local p=self:best(items,"princess",target,function(i) return G.purity(i.stack,target)>0 end,genes)
  if j.mode=="populate" then
    p=self:best(items,"princess",target,function(i) return G.purity(i.stack,target)>0 and G.fertility(i.stack)>1 end,genes) or p
  end
  local d=self:best(items,"drone",target,function(i) return G.purity(i.stack,target)>0 and self:canSpend(i,items) end,genes)
  if j.lineage then
    local found=false
    for _,i in ipairs(items) do if i.endpoint.id==j.lineage.endpoint.id and i.slot==j.lineage.slot and B.kind(i.stack)=="princess" and
      B.identity(i.stack)==j.lineage.identity then p=i; found=true end end
    if not found then return nil,nil,"Tracked princess is missing or changed; reconcile the archive before resuming" end
  elseif j.mode=="convert" then
    p=self:best(items,"princess",target,function(i) return self:conversionDonor(i,items,target) end,genes)
  end
  if p and d then
    -- Same target stabilization may use its only princess, preserving reserve drones.
    if template and G.purity(p.stack,target)==2 and not G.templateMatch(p.stack,genes) and G.purity(d.stack,target)==2 then
      if self:canSpend(template,items,nil,true) and self:canSpend(p,items) then d=template
      else
        self:stockJob(target,"convert",nil,j)
        return nil,nil,"Waiting for a spare target princess before template crossing"
      end
    end
    return p,d,nil,target
  end
  if j.mode=="populate" then return nil,nil,"Need a target princess and at least two compatible drones; fertility must exceed one" end
  if j.mode=="convert" or j.mode=="imprint" then
    if not d then return nil,nil,"Need target drones above the exact-genotype reserve" end
    p=p or self:best(items,"princess",target,function(i) return self:conversionDonor(i,items,target) end,genes)
    return p,d,p and nil or "Add a spare princess with fertility > 1 in both alleles; last pure princesses are protected",target
  end
  if not j.route then return nil,nil,"No runtime mutation route and no usable target stock" end
  if p and not d then
    -- Preserve a new target princess while reintroducing a known parent drone.
    for _,parent in ipairs(j.route.parents) do
      d=self:best(items,"drone",target,function(i) return G.purity(i.stack,parent)==2 and self:canSpend(i,items) end,genes)
      if d then return p,d,nil,target end
    end
  end
  -- Keep using our own surviving princess when a mutation was lost. Convert her
  -- back to one known parent, then cross with the other, without touching reserves.
  if p and j.lineage then
    local left,right=j.route.parents[1],j.route.parents[2]
    local donor=G.purity(p.stack,left)==2 and right or left
    d=self:best(items,"drone",donor,function(i) return G.purity(i.stack,donor)==2 and self:canSpend(i,items) end)
    if d then return p,d,nil,donor end
  end
  -- Prepare both parent species before spending a princess on a new mutation.
  -- Available planner seeds skip breeding jobs, so they need this gate too.
  local preparing=false
  for _,parent in ipairs(j.route.parents) do
    local population
    for _,job in ipairs(self.state.jobs) do
      if job.species==parent and job.mode=="populate" and job.state~="DONE" then population=job; break end
    end
    if population then preparing=true
    elseif self:count(items,parent,"drone")<self:populationMinimum(items,parent) then
      preparing=true
      if self:count(items,parent,"princess")>0 and self:count(items,parent,"drone")>self.c.reserveDrones then
        self:stockJob(parent,"populate",self.c.minDrones,j)
      elseif self:count(items,parent,"drone")>self.c.reserveDrones then
        self:stockJob(parent,"convert",nil,j)
      end
    end
  end
  if preparing then return nil,nil,"Waiting for parent drone population and stable confirmation cycles" end
  -- Start/recover a mutation from actual parent stock. Try both directions.
  for n=1,2 do
    local left,right=j.route.parents[n],j.route.parents[3-n]
    p=self:best(items,"princess",left,function(i) return G.purity(i.stack,left)==2 and self:canSpend(i,items) end)
    d=self:best(items,"drone",right,function(i) return G.purity(i.stack,right)==2 and self:canSpend(i,items) end)
    if p and d then return p,d,nil,target end
  end
  -- Automatically create surplus stock using the same scheduler. No recursive restarts.
  for _,parent in ipairs(j.route.parents) do
    local drones=self:count(items,parent,"drone")
    local princesses=self:count(items,parent,"princess")
    if drones<self:populationMinimum(items,parent) and princesses>0 and drones>self.c.reserveDrones then
      self:stockJob(parent,"populate",self.c.minDrones,j)
    elseif drones>self.c.reserveDrones and princesses<=self.c.reservePrincesses then
      self:stockJob(parent,"convert",nil,j)
    end
  end
  return nil,nil,"Waiting for parent stock/reserves or a spare princess for automatic conversion"
end
function M:completion(j,items,template)
  local minimum=j.count or self:populationMinimum(items,j.species)
  if j.mode=="convert" then
    -- Conversion creates one additional stable princess; baseline is captured before work.
    return j.baseline and self:count(items,j.species,"princess")>j.baseline and j.confirmed>=self.c.confirmCycles and
      self:count(items,j.species,"drone")>=minimum
  end
  if self:count(items,j.species,"drone")<minimum then return false end
  for _,p in ipairs(items) do if B.kind(p.stack)=="princess" then
    for _,d in ipairs(items) do if B.kind(d.stack)=="drone" and
      G.complete(p.stack,d.stack,j.species,self.c,template and template.stack.individual.active) then
      return j.confirmed>=self.c.confirmCycles
    end end
  end end
  return false
end
function M:dispatch(j)
  local items=self:items(j.id); local template=self:template(j,items)
  if self:completion(j,items,template) then
    j.state="DONE"; j.error=nil
    if self.storage.releaseBatches then self.storage:releaseBatches(j.id) end
    self:log(j.species.." complete; stable stock archived"); return
  end
  if j.mode=="convert" and j.baseline==nil then j.baseline=self:count(items,j.species,"princess"); self.save() end
  local p,d,why,cycleTarget=self:select(j,items,template)
  if not p or not d then j.error=why; return end
  if j.mode=="populate" and G.fertility(p.stack)<=1 then
    self:pause(j,"Fertility <= 1 cannot grow drone reserves; improve fertility or add drones"); return
  end
  local busy={}; local running=0
  for id,m in pairs(self.state.machines) do if m.job then busy[id]=true; running=running+1 end end
  if running>=self.c.concurrency then return end
  local candidates,reason=E.select(self.c.alvearies,j.route,p.stack,d.stack,busy)
  local backend
  for _,a in ipairs(candidates) do
    local b=self:backend(a.id)
    local ok,ready,err=pcall(b.isReady,b)
    if ok and ready then backend=b; break else reason=(reason or "").." | "..a.id..": "..tostring(ok and err or ready) end
  end
  if not backend then j.error="No compatible available alveary. "..reason; return end
  assert(j.cycles<self.c.maxCycles,"Cycle limit reached; inspect genetic progress and replan")
  local a=backend.config
  -- Materialization can export a stack; reserve logical ME stack before exporting.
  for _,i in ipairs({p,d}) do
    if i.network then
      local k=U.location(i.endpoint,i.slot); assert(not self.state.reservations[k],"ME stack already leased")
      self.state.reservations[k]={owner=j.id,identity=B.identity(i.stack)}; self.save()
    else self.inv:reserve(i,j.id) end
  end
  j.machine=a.id; j.state="PREPARING"; j.expectedPrincess=U.copy(p.stack); j.cycleTarget=cycleTarget
  self.state.machines[a.id]={job=j.id,state="PREPARING",lastInteraction=self.now()}; self.save()
  p=self.storage:materialize(p,a.storage,j.id,1); self.inv:reserve(p,j.id)
  d=self.storage:materialize(d,a.storage,j.id,1); self.inv:reserve(d,j.id)
  -- Persist selection before insertion. Recovery never repeats PREPARING blindly.
  j.preparedPrincess={endpoint=p.endpoint,slot=p.slot,identity=B.identity(p.stack)}
  j.preparedDrone={endpoint=d.endpoint,slot=d.slot,identity=B.identity(d.stack)}; self.save()
  backend:insertPrincess(p,j.id); backend:insertDrone(d,j.id,p.stack)
  if self.storage.releasePort then self.storage:releasePort(a.storage); self.inv:release(j.id) end
  if backend.start then backend:start() end
  j.state="RUNNING"; j.started=self.now(); j.cycles=j.cycles+1; j.error=nil
  self.state.machines[a.id].state="RUNNING"; self.save()
  self:log(j.id..": cycle "..j.cycles.." in "..a.name)
end
function M:advance(j)
  local b=self:backend(j.machine); b:validate()
  local machine=self.state.machines[j.machine]
  if j.state=="RUNNING" then
    local status,why=b:getCycleState(); machine.lastInteraction=self.now()
    if status=="FINISHED" then
      j.state="COLLECTING"; j.collectionAfter=self.state.transferSequence or 0; j.resultLocations={}; self.save()
    elseif status=="UNCERTAIN" then error(why)
    elseif self.now()-(j.started or self.now())>self.c.cycleTimeout then error("Cycle timeout: "..tostring(why or "queen still present"))
    else j.error=why; return end
  end
  if j.state=="COLLECTING" then
    j.resultLocations=j.resultLocations or {}
    local function receipt(i)
      if i.batchId then
        for _,loc in ipairs(j.resultLocations) do if loc.root==i.root then return end end
        j.resultLocations[#j.resultLocations+1]={root=i.root}; self.save(); return
      end
      for _,loc in ipairs(j.resultLocations) do if loc.endpoint.id==i.endpoint.id and loc.slot==i.slot then return end end
      j.resultLocations[#j.resultLocations+1]={endpoint=i.endpoint,slot=i.slot}; self.save()
    end
    -- Reconstruct a receipt committed immediately before a crash in the collector.
    for _,tx in ipairs(self.state.transactions) do
      if tx.owner==j.id and tx.id and tx.id>(j.collectionAfter or math.huge) and tx.dest.id==b.config.storage.id then
        if tx.dest.managed then
          local id="receipt/"..tx.id
          if self.state.meBatches[id] then receipt({batchId=id,root=self.state.meBatches[id].root}) end
        else receipt({endpoint=tx.dest,slot=tx.destSlot}) end
      end
    end
    if self.storage.interface then for id,batch in pairs(self.state.meBatches) do
      local sequence=batch.sequence or tonumber((batch.root or id):match("^receipt/(%d+)")) or 0
      if batch.owner==j.id and sequence>(j.collectionAfter or math.huge) then receipt({batchId=id,root=batch.root}) end
    end end
    b:collectResults(self.storage,j.id,receipt)
    j.state="ASSESSING"; j.lastCycle=self.now(); self.state.lastCycle=j.lastCycle; self.save()
  end
  if j.state=="ASSESSING" then
    local all=self.storage:scan(); local scanned,why=self.scanner:step(all)
    if not scanned then j.error=why; return end
    self.inv:release(j.id)
    local items=self:items(j.id); local template=self:template(j,items)
    local own={}
    for _,i in ipairs(items) do for _,loc in ipairs(j.resultLocations or {}) do
      if (loc.root and i.root==loc.root) or (loc.endpoint and i.endpoint.id==loc.endpoint.id and i.slot==loc.slot) then own[#own+1]=i; break end
    end end
    local p=self:best(own,"princess",j.species)
    local d=self:best(own,"drone",j.species)
    assert(p,"No analyzed princess in this job's collected offspring; inspect archive")
    j.lineage={endpoint=p.endpoint,slot=p.slot,identity=B.identity(p.stack)}
    if self.storage.releaseBatches then self.storage:releaseBatches(j.id,p.batchId) end
    if p and d and G.complete(p.stack,d.stack,j.species,self.c,template and template.stack.individual.active) then
      j.confirmed=j.confirmed+1
    else j.confirmed=0 end
    j.progress=(p and G.purity(p.stack,j.species) or 0)+(d and G.purity(d.stack,j.species) or 0)
    machine.job=nil; machine.state="IDLE"; machine.lastSuccess=self.now()
    j.machine=nil; j.state="WAITING"; j.error=nil; j.resultLocations=nil; self.save()
  end
end
function M:resume(id)
  self.state.paused=false; self.state.stopped=false; self.state.stopping=false
  if self.storage.interface then self.state.stockReady=false; self.state.stockPhase="PREPARING_STOCK" end
  for _,j in ipairs(self.state.jobs) do if (not id or j.id==id) and j.state=="PAUSED" then
    assert(j.previous~="PREPARING","Partial insertion: inspect inputs and use doctor recovery before resuming")
    j.state=j.previous or "WAITING"; j.error=nil; j.previous=nil
    if j.state=="RUNNING" then j.started=self.now() end
    if j.machine and self.state.machines[j.machine] then
      self.state.machines[j.machine].state=j.state; self.state.machines[j.machine].error=nil
    end
  end end
  self.save()
end
function M:recover()
  local ok,why=self.inv:reconcile(); assert(ok,why)
  if self.storage.reconcile then local yes,err=self.storage:reconcile(); assert(yes,err) end
  self.storage:scan()
  if self.state.scan then self.state.scan.started=self.now() end
  if self.storage.interface then self.state.stockReady=false; self.state.stockPhase="PREPARING_STOCK" end
  for _,j in ipairs(self.state.jobs) do
    if j.machine then
      local success,err=pcall(function()
        local b=self:backend(j.machine); b:validate(); local status=b:getCycleState()
        if j.state=="PREPARING" then
          -- A completed insertion receipt is insufficient evidence of a full mating.
          error("Restart during insertion. Inspect actual inputs; use doctor --adopt "..j.id.." only after verifying a live queen or complete offspring pair")
        end
        if j.state=="RUNNING" then
          if status=="FINISHED" then
            j.state="COLLECTING"; j.collectionAfter=self.state.transferSequence or 0; j.resultLocations={}
          elseif status=="UNCERTAIN" then error("Saved running cycle has no inputs or offspring")
          else j.started=self.now() end -- uptime resets on restart; give bounded fresh observation window
        end
      end)
      if not success then self:pause(j,err) end
    end
  end
  -- Retain leases owned by active or interrupted jobs; remove only proven orphan leases.
  for k,v in pairs(self.state.reservations) do
    if v.owner~="scanner" and not J.find(self.state,v.owner) then self.state.reservations[k]=nil end
  end
  self.save()
end
function M:retryInsertion(j)
  assert(j.machine,"job has no reserved machine")
  assert(not self.state.pending and not self.state.pendingExternal,"reconcile transfers before retry")
  local b=self:backend(j.machine); assert(b:isReady(),"machine must be empty before retry")
  if self.storage.interface then
    self.storage:cancel(j.id); self.inv:release(j.id); self.state.machines[j.machine]={state="IDLE"}
    j.machine=nil; j.state="WAITING"; j.previous=nil; j.error=nil; self.save(); return
  end
  for _,source in ipairs({j.preparedPrincess,j.preparedDrone}) do
    local actual=self.inv:get(source.endpoint,source.slot)
    assert(actual and B.identity(actual)==source.identity,"restore the recorded source items before retrying insertion")
  end
  self.inv:release(j.id); self.state.machines[j.machine]={state="IDLE"}
  j.machine=nil; j.state="WAITING"; j.previous=nil; j.error=nil; self.save()
end
function M:adopt(j)
  assert(j.machine,"job has no reserved machine")
  local b=self:backend(j.machine); b:validate()
  local status=b:getCycleState(); local q=self.inv:get(b.endpoint,b:getSlots().princess)
  local routed=b.config.routing and #self.inv:scan(b.endpoint)==0 and b:housing().getQueen()
  assert(status=="FINISHED" or B.kind(q)=="queen" or routed,"adoption requires a live queen or complete offspring pair")
  assert(not self.state.pendingExternal,"reconcile external movement before adoption")
  local tx=self.state.pending
  if tx then
    assert(tx.owner==j.id and tx.dest.id==b.endpoint.id and tx.destSlot==b:getSlots().drone,
      "pending transfer is not this job's final drone insertion")
    local src=self.inv:get(tx.source,tx.slot)
    assert((tx.source.managed and tx.returned==tx.count) or (not src and tx.before==tx.count) or (src and src.size==tx.before-tx.count and B.identity(src)==tx.identity),
      "cannot prove source count decreased by intended drone count")
    assert(B.kind(q)=="queen" and B.scanned(q) and j.expectedPrincess and
      U.equal(q.individual.active,j.expectedPrincess.individual.active) and
      U.equal(q.individual.inactive,j.expectedPrincess.individual.inactive),"queen genome does not witness this insertion")
    tx.phase="ADOPTED_OBSERVED_MATING"; require("lib.storage.receipts").commit(self.state,tx)
    self.state.transactions[#self.state.transactions+1]=tx; self.state.pending=nil
  end
  j.state=status=="FINISHED" and "COLLECTING" or "RUNNING"
  if status=="FINISHED" then j.collectionAfter=self.state.transferSequence or 0; j.resultLocations={} end
  j.previous=nil; j.error=nil; j.started=self.now(); self.save()
  if self.storage.releasePort then self.storage:releasePort(b.config.storage) end
end
function M:prepareStock(items)
  if self.storage.interface and not self.state.stockReady then self.state.stockPhase="PREPARING_STOCK" end
  if self.storage.prepare and not self.storage:prepare(items) then return false,"Inspecting ME stock" end
  local ready,why=self.scanner:step(items)
  if self.storage.interface then
    local remaining=0
    for _,i in ipairs(items) do if B.kind(i.stack)=="drone" and not B.scanned(i.stack) then remaining=remaining+i.stack.size end end
    if self.state.scan then remaining=math.max(remaining,self.state.scan.count or 0) end
    self.state.stockRemaining=remaining
    if ready then
      -- Offspring left in registered housings must not bypass the initial gate.
      for _,a in ipairs(self.c.alvearies) do
        local backend=self:backend(a.id)
        local output=a.routing and a.routing.output or backend.endpoint
        for _,slot in ipairs(a.slots.outputs) do local s=self.inv:get(output,slot)
          if B.kind(s)=="drone" and not B.scanned(s) then
            local m=self.state.machines[a.id]
            if not (m and m.job) then self.storage:deposit({endpoint=output,slot=slot,stack=s},a.storage,"scanner") end
            ready=false; why="Inspecting initial housing offspring"; break
          end
        end
        if not ready then break end
      end
      if ready and self.c.scanner.enabled then
        assert(self.scanner:empty(),
          "untracked shared scanner contents; audit before starting")
      end
    end
    if ready then self.state.stockReady=true; self.state.stockPhase="READY"; self.state.stockRemaining=0
    else self.state.stockPhase=self.state.stockReady and "SCANNING" or "PREPARING_STOCK" end
    self.save()
  end
  return ready,why
end
function M:step()
  if self.state.paused then return false,"PAUSED" end
  local function progress()
    local pieces={tostring(#self.state.jobs),tostring(self.state.transferSequence or 0)}
    for _,j in ipairs(self.state.jobs) do pieces[#pieces+1]=j.state..":"..j.cycles..":"..j.confirmed end
    return table.concat(pieces,"|")
  end
  local before=progress()
  local ok,items=pcall(self.storage.scan,self.storage)
  if not ok then self.state.error=tostring(items); self.save(); return false,"BLOCKED" end
  self.state.error=nil
  self.state.storageCounts={princess=0,drone=0}
  for _,i in ipairs(items) do local kind=B.kind(i.stack)
    if self.state.storageCounts[kind] then self.state.storageCounts[kind]=self.state.storageCounts[kind]+i.stack.size end
  end
  local scanOk,scanned,reason=pcall(self.prepareStock,self,items)
  if not scanOk then self.state.error=tostring(scanned); scanned=false; self.save()
  elseif not scanned then self.state.error=reason end
  -- Advance machines even when a different scanner operation is outstanding.
  for _,j in ipairs(self.state.jobs) do
    if j.state=="RUNNING" or j.state=="COLLECTING" or j.state=="ASSESSING" then
      local success,err=pcall(self.advance,self,j); if not success then self:pause(j,err); self:log(j.id..": "..tostring(err)) end
    end
  end
  if scanned and not self.state.stopping and not self.state.pending and not self.state.pendingExternal then
    -- Rotate the starting job each tick to avoid starving independent prerequisites.
    local n=#self.state.jobs; local start=(self.state.cursor or 0)%math.max(1,n)
    for off=1,n do local j=self.state.jobs[(start+off-1)%n+1]
      if j.state=="WAITING" and J.ready(self.state,j) then
        local success,err=pcall(self.dispatch,self,j); if not success then self:pause(j,err); self:log(j.id..": "..tostring(err)) end
      end
    end
    self.state.cursor=start+1
  end
  local complete,active=true,false
  for _,j in ipairs(self.state.jobs) do
    if j.state~="DONE" then complete=false end
    if j.state=="RUNNING" or j.state=="COLLECTING" or j.state=="ASSESSING" then active=true end
  end
  complete=complete and scanned; self.state.finished=complete
  local reserved=false; for _,m in pairs(self.state.machines) do if m.job then reserved=true end end
  if self.state.stopping and not active and not reserved and not self.state.scan then
    self.state.stopped=true
    if self.storage.releaseBatches then for _,j in ipairs(self.state.jobs) do
      self.storage:releaseBatches(j.id); j.lineage=nil; self.inv:release(j.id)
    end end
  end
  self.save()
  return active,complete and "DONE" or self.state.stopped and "STOPPED" or active and "RUNNING" or
    (scanOk and not scanned and "SCANNING") or (progress()~=before and "PROGRESS") or "BLOCKED"
end
return M
