local U=require("lib.util"); local B=require("lib.bees"); local G=require("lib.genetics")
local E=require("lib.environment"); local J=require("lib.jobs"); local T=require("lib.templates")
local Backend=require("lib.breeders.factory")
local M={}; M.__index=M
-- Only lifecycle and diagnostic fields need an end-of-step checkpoint.
local function saveStatus(state)
  local jobs={}
  for n,j in ipairs(state.jobs) do jobs[n]={id=j.id,state=j.state,cycles=j.cycles,confirmed=j.confirmed,error=j.error} end
  return {jobs=jobs,sequence=state.transferSequence or 0,error=state.error,
    finished=not not state.finished,stopped=not not state.stopped}
end
function M.new(c,state,components,inv,storage,scanner,save,now)
  state.jobs=state.jobs or {}; state.machines=state.machines or {}; state.events=state.events or {}
  state.parentStock=state.parentStock or {}
  local self=setmetatable({c=c,state=state,components=components,inv=inv,storage=storage,
    scanner=scanner,now=now,backends={}},M)
  self.save=function()
    local snapshot=saveStatus(state); save(); self.savedStatus=snapshot
  end
  -- Include checkpoints made inside scanner, storage and inventory operations.
  inv.save=self.save; scanner.save=self.save
  return self
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
function M:items(owner,snapshot)
  local all=snapshot or self.storage:scan(); local items={}
  local lineages={}
  for _,j in ipairs(self.state.jobs) do local loc=j.lineage
    if j.id~=owner and j.state~="DONE" and loc and loc.identity then
      local bySlot=lineages[loc.endpoint.id] or {}; lineages[loc.endpoint.id]=bySlot
      local identities=bySlot[loc.slot] or {}; bySlot[loc.slot]=identities; identities[loc.identity]=true
    end
  end
  for _,i in ipairs(all) do
    local held=self.state.reservations[U.location(i.endpoint,i.slot)]
    if self.storage.interface and i.owner and i.owner~=owner then held=true end
    local bySlot=lineages[i.endpoint.id]; local identities=bySlot and bySlot[i.slot]
    if identities and identities[B.identity(i.stack)] then held=true end
    if not held then items[#items+1]=i end
  end
  return items
end
function M:template(j,items)
  if j.mode=="benchmark" then return nil end
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
function M:observeParentStock(items,allWaiting)
  -- Use the same whole-storage snapshot as storageCounts, including stock owned
  -- by population helpers. Selection still applies its usual ownership rules.
  self.state.parentStock={}
  for _,j in ipairs(self.state.jobs) do
    if j.state=="WAITING" and (allWaiting or j.error=="Waiting for stable parent population") then
      for _,parent in ipairs(j.route and j.route.parents or {}) do
        if not self.state.parentStock[parent] then
          self.state.parentStock[parent]={count=self:count(items,parent,"drone"),minimum=self:populationMinimum(items,parent)}
        end
      end
    end
  end
end
function M:conversionDonor(i,items,target)
  return G.purity(i.stack,target)<2 and self:canSpend(i,items) and
    (G.purity(i.stack,target)>0 or G.fertileDonor(i.stack))
end
function M:canSpend(i,items,paired,templateUse,droneCounts)
  if (self:protected(i) and not templateUse) or not B.scanned(i.stack) then return false end
  local s=i.stack; local target=B.species(s.individual.active.species)
  if B.kind(s)=="drone" then
    if templateUse and s.size<=(self.c.templates.reserve or 1) then return false end
    -- Reserve at least one of this exact useful genotype, not merely visible species.
    local identity=B.identity(s); local same=droneCounts and droneCounts[identity] or 0
    if not droneCounts then
      for _,x in ipairs(items) do if B.kind(x.stack)=="drone" and B.identity(x.stack)==identity then same=same+x.stack.size end end
    end
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
function M:droneShortage(j,items,counts)
  local total,largest,protected=0,0,0
  for _,i in ipairs(items) do if B.kind(i.stack)=="drone" and G.purity(i.stack,j.species)>0 then
    if self:protected(i) then protected=protected+i.stack.size else
      total=total+i.stack.size; largest=math.max(largest,counts[B.identity(i.stack)] or 0)
    end
  end end
  local name=B.displayName(j.species); local reserve=self.c.reserveDrones; local minimum=reserve+1
  local goal=j.mode=="convert" and ("Cannot recover a "..name.." princess") or ("Cannot breed "..name)
  local missing=minimum-largest
  local action=largest>0 and ("Add "..missing.." more matching "..(missing==1 and "drone" or "drones").." to an existing group") or
    ("Add at least "..minimum.." identical analysed "..name.." drones")
  return goal..": no spendable target drone.\n"..
    "Analysed target drones available to this job: "..total.."; largest identical group: "..largest..".\n"..
    "Need "..minimum.." in one identical group: 1 to breed + "..reserve.." kept as reserve.\n"..
    "Different variants cannot share a reserve."..
    (protected>0 and (" "..protected.." reference-template drones excluded.") or "").."\n"..
    action..", then Beeomatic resume."
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
function M:rebreed(j,items)
  local source
  for _,a in ipairs(self.c.alvearies) do if a.enabled~=false then
    local yes,h=pcall(self.components.proxy,self.components,a.address,{"getBeeParents"})
    if yes then source=h; break end
  end end
  if not source then return false,"No accessible housing provides mutation recipes." end
  -- Avoid loading a graph/index for founders with no runtime mutation recipe.
  local routes,err=source.getBeeParents(j.species)
  if not routes then return false,"Cannot read mutation recipes: "..tostring(err) end
  if not next(routes) then return false,"No mutation recipe reported for "..B.displayName(j.species).."." end
  local mutations=require("lib.mutations").new(source,self.c.aliases); mutations:index(items)
  local plan,why=require("lib.planner").plan(j.species,mutations,items,self.c,true)
  mutations=nil; package.loaded["lib.planner"]=nil; package.loaded["lib.mutations"]=nil
  if not plan then U.collect(); return false,why end
  local bySpecies={}; local dependencies={}
  for _,node in ipairs(plan.order) do if not node.available then
    local job=j
    if node~=plan.root then
      self.state.nextId=(self.state.nextId or 0)+1
      job={id="job"..self.state.nextId,species=node.species,mode=node.conversion and "convert" or "breed",
        dependencies={},state="WAITING",cycles=0,confirmed=0,helper=true,parent=j.id,route=node.route}
      self.state.jobs[#self.state.jobs+1]=job
    end
    local deps=job==j and dependencies or job.dependencies
    for _,child in ipairs(node.children) do if bySpecies[child.species] then deps[#deps+1]=bySpecies[child.species] end end
    bySpecies[node.species]=job.id
  end end
  j.dependencies=j.dependencies or {}
  for _,id in ipairs(dependencies) do j.dependencies[#j.dependencies+1]=id end
  j.route=plan.root.route; j.rebreeding=true
  plan=nil; U.collect()
  j.error="Rebreeding "..B.displayName(j.species).." from mutation parents to restore stable drone stock"
  self:log(j.id..": "..j.error)
  return true
end
function M:select(j,items,template)
  if j.mode=="benchmark" then
    for _,p in ipairs(items) do if B.kind(p.stack)=="princess" and not self:protected(p) then
      for _,d in ipairs(items) do if B.kind(d.stack)=="drone" and not self:protected(d) and G.equivalent(p.stack,d.stack) then
        local candidates=E.select(self.c.alvearies,nil,p.stack,d.stack)
        if #candidates>0 then
          j.species=B.species(p.stack.individual.active.species)
          self.state.target=j.species
          return p,d,nil,j.species
        end
      end end
    end end
    return nil,nil,"Benchmark needs a stable princess/drone pair with identical homozygous genes, compatible with a registered housing"
  end
  local target=j.species; local genes=template and template.stack.individual.active
  -- Only this immutable selection snapshot uses these totals. A later dispatch
  -- scans again so a committed withdrawal cannot be spent a second time.
  local droneCounts={}
  for _,i in ipairs(items) do if B.kind(i.stack)=="drone" then
    local key=B.identity(i.stack); droneCounts[key]=(droneCounts[key] or 0)+i.stack.size
  end end
  local function spend(i,paired,templateUse)
    return self:canSpend(i,items,paired,templateUse,droneCounts)
  end
  local p=self:best(items,"princess",target,function(i) return G.purity(i.stack,target)>0 end,genes)
  if j.mode=="populate" then
    p=self:best(items,"princess",target,function(i) return G.purity(i.stack,target)==2 and G.fertility(i.stack)>1 end,genes) or
      self:best(items,"princess",target,function(i) return G.purity(i.stack,target)>0 and G.fertility(i.stack)>1 end,genes) or p
  end
  if j.lineage then
    local found=false
    for _,i in ipairs(items) do if i.endpoint.id==j.lineage.endpoint.id and i.slot==j.lineage.slot and B.kind(i.stack)=="princess" and
      B.identity(i.stack)==j.lineage.identity then p=i; found=true end end
    if not found then return nil,nil,"Tracked princess is missing or changed; reconcile the archive before resuming" end
  elseif j.mode=="convert" then
    -- A mutation recovery must create an additional princess, rather than use
    -- an existing pure target princess and invalidate the conversion baseline.
    p=not j.rebreeding and self:best(items,"princess",target,function(i) return self:conversionDonor(i,items,target) end,genes) or nil
  end
  local d=self:best(items,"drone",target,function(i)
    -- Closed pure-species population grows its starting pair, even its last
    -- drone. Hybrid crosses and protected/other-job stock retain their rules.
    return G.purity(i.stack,target)>0 and (spend(i) or
      (j.mode=="populate" and p and G.purity(p.stack,target)==2 and G.purity(i.stack,target)==2))
  end,genes)
  if p and d then
    -- Template crossings still need spare stock even during population.
    if template and G.purity(p.stack,target)==2 and not G.templateMatch(p.stack,genes) and G.purity(d.stack,target)==2 then
      if spend(template,nil,true) and spend(p) then d=template
      else
        self:stockJob(target,"convert",nil,j)
        return nil,nil,"Waiting for a spare target princess before template crossing"
      end
    end
    return p,d,nil,target
  end
  if (j.mode=="populate" or j.mode=="convert" or j.mode=="imprint" or not j.route) and not j.rebreeding and (not p or not d) then
    local recovered,why=self:rebreed(j,items)
    if recovered then
      if J.ready(self.state,j) then return self:select(j,items,template) end
      return nil,nil,j.error
    end
    if not d then return nil,nil,self:droneShortage(j,items,droneCounts).."\nAutomatic rebreeding unavailable: "..why end
  end
  if j.mode=="populate" and not j.rebreeding then
    return nil,nil,"Need a target princess; fertility must exceed one"
  end
  if (j.mode=="convert" or j.mode=="imprint") and not j.rebreeding then
    p=p or self:best(items,"princess",target,function(i) return self:conversionDonor(i,items,target) end,genes)
    return p,d,p and nil or "Add a spare princess with fertility > 1 in both alleles; last pure princesses are protected",target
  end
  if not j.route then return nil,nil,"No runtime mutation route and no usable target stock" end
  if p and not d then
    -- Preserve a new target princess while reintroducing a known parent drone.
    for _,parent in ipairs(j.route.parents) do
      d=self:best(items,"drone",target,function(i) return G.purity(i.stack,parent)==2 and spend(i) end,genes)
      if d then return p,d,nil,target end
    end
  end
  -- Keep using our own surviving princess when a mutation was lost. Convert her
  -- back to one known parent, then cross with the other, without touching reserves.
  if p and j.lineage then
    local left,right=j.route.parents[1],j.route.parents[2]
    local donor=G.purity(p.stack,left)==2 and right or left
    d=self:best(items,"drone",donor,function(i) return G.purity(i.stack,donor)==2 and spend(i) end)
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
  if preparing then return nil,nil,"Waiting for stable parent population" end
  -- Start/recover a mutation from actual parent stock. Try both directions.
  for n=1,2 do
    local left,right=j.route.parents[n],j.route.parents[3-n]
    p=self:best(items,"princess",left,function(i) return G.purity(i.stack,left)==2 and spend(i) end)
    d=self:best(items,"drone",right,function(i) return G.purity(i.stack,right)==2 and spend(i) end)
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
  if j.mode=="benchmark" then return j.cycles>=1 end
  -- No stock combination can complete before its stable-cycle requirement.
  if j.confirmed<self.c.confirmCycles then return false end
  local minimum=j.count or self:populationMinimum(items,j.species)
  if j.mode=="convert" then
    -- Conversion creates one additional stable princess; baseline is captured before work.
    return j.baseline and self:count(items,j.species,"princess")>j.baseline and j.confirmed>=self.c.confirmCycles and
      self:count(items,j.species,"drone")>=minimum
  end
  if self:count(items,j.species,"drone")<minimum then return false end
  if not self.c.fullEquivalence then
    -- With equivalence disabled the two candidates have independent purity
    -- and template requirements. Check each item once, rather than comparing
    -- every princess against every drone in the inventory.
    local princess,drone=false,false
    local genes=template and template.stack.individual.active
    for _,i in ipairs(items) do
      local kind=B.kind(i.stack)
      if ((kind=="princess" and not princess) or (kind=="drone" and not drone)) and
        G.purity(i.stack,j.species)==2 and (not genes or G.templateMatch(i.stack,genes)) then
        if kind=="princess" then princess=true else drone=true end
        if princess and drone then return true end
      end
    end
    return false
  end
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
    if self.storage.releaseBatches then self.storage:releaseBatches(j.id,nil,true) end
    self:log(j.species.." complete; stable stock archived"); return
  end
  if j.mode=="convert" and j.baseline==nil then j.baseline=self:count(items,j.species,"princess"); self.save() end
  local p,d,why,cycleTarget=self:select(j,items,template)
  if not p or not d then j.error=why; return end
  -- Selection is complete. Keep only the two parents while reading housings,
  -- rebuilding database entries and checkpointing physical transfers.
  items=nil; template=nil
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
    if ok and ready then backend=b; break else reason=(reason~="" and reason.."\n" or "")..a.id..": "..tostring(ok and err or ready) end
  end
  if not backend then
    local goal=j.mode=="convert" and ("Recover "..B.displayName(j.species).." princess.\n") or ""
    j.error=goal.."Cannot start this pairing in any available alveary.\n"..
      "Selected parents: "..E.parent(p.stack,"princess").." + "..E.parent(d.stack,"drone")..".\n"..
      (reason~="" and reason or "All registered alvearies are busy or disabled.")
    return
  end
  assert(j.cycles<self.c.maxCycles,"Cycle limit reached; inspect genetic progress and replan")
  local a=backend.config
  if self.observations then self.observations[a.id]=nil end
  if j.mode=="benchmark" then print("Benchmark: one "..B.displayName(j.species).." cycle in "..a.name) end
  -- Materialization can export a stack; reserve logical ME stack before exporting.
  for _,i in ipairs({p,d}) do
    if i.network then
      local k=U.location(i.endpoint,i.slot); assert(not self.state.reservations[k],"ME stack already leased")
      self.state.reservations[k]={owner=j.id,identity=B.identity(i.stack)}
    else self.inv:reserve(i,j.id,true) end
  end
  j.machine=a.id; j.state="PREPARING"; j.expectedPrincess=U.copy(p.stack); j.cycleTarget=cycleTarget
  self.state.machines[a.id]={job=j.id,state="PREPARING",lastInteraction=self.now()}; self.save()
  p=self.storage:materialize(p,a.storage,j.id,1); self.inv:reserve(p,j.id,true)
  d=self.storage:materialize(d,a.storage,j.id,1); self.inv:reserve(d,j.id,true)
  -- Persist selection before insertion. Recovery never repeats PREPARING blindly.
  j.preparedPrincess={endpoint=p.endpoint,slot=p.slot,identity=B.identity(p.stack)}
  j.preparedDrone={endpoint=d.endpoint,slot=d.slot,identity=B.identity(d.stack)}; self.save()
  backend:insertPrincess(p,j.id); backend:insertDrone(d,j.id,p.stack)
  if self.storage.releasePort then self.storage:releasePort(a.storage); self.inv:release(j.id) end
  if backend.start then backend:start() end
  j.state="RUNNING"; j.started=self.now(); j.cycles=j.cycles+1; j.error=nil
  self.state.machines[a.id].state="RUNNING"
  self:log(j.id..": cycle "..j.cycles.." in "..a.name)
end
function M:advance(j,stockReady,stockReason)
  local b=self:backend(j.machine); b:validate()
  local machine=self.state.machines[j.machine]
  if j.state=="RUNNING" then
    local status,why,observation=b:getCycleState(); machine.lastInteraction=self.now()
    if self.observations then self.observations[j.machine]=observation end
    if status=="FINISHED" then
      j.state="COLLECTING"; j.collectionAfter=self.state.transferSequence or 0; j.resultLocations={}
    elseif status=="UNCERTAIN" then error(why)
    elseif self.now()-(j.started or self.now())>self.c.cycleTimeout then error("Cycle timeout: "..tostring(why or "queen still present"))
    else j.error=why; return end
  end
  if j.state=="COLLECTING" then
    j.resultLocations=j.resultLocations or {}
    local function receipt(i)
      if i.batchId then
        for _,loc in ipairs(j.resultLocations) do if loc.root==i.root then return end end
        j.resultLocations[#j.resultLocations+1]={root=i.root}; return
      end
      for _,loc in ipairs(j.resultLocations) do if loc.endpoint.id==i.endpoint.id and loc.slot==i.slot then return end end
      j.resultLocations[#j.resultLocations+1]={endpoint=i.endpoint,slot=i.slot}
    end
    -- Moves durably save COLLECTING and their receipts. Save result locations
    -- with the next move/assessment, reconstructing any missing ones on restart.
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
    if stockReady==false then j.error=stockReason; return end
    local all=self.storage:scan(); local scanned,why=self.scanner:step(all)
    if not scanned then j.error=why; return end
    self.inv:release(j.id)
    -- In Interface mode a true scanner result means no batch or movement was
    -- needed. The snapshot just checked is still current; releasing a lease
    -- changes selection permissions, not physical stock.
    local items=self:items(j.id,self.storage.interface and all or nil); local template=self:template(j,items)
    local own={}
    for _,i in ipairs(items) do for _,loc in ipairs(j.resultLocations or {}) do
      if (loc.root and i.root==loc.root) or (loc.endpoint and i.endpoint.id==loc.endpoint.id and i.slot==loc.slot) then own[#own+1]=i; break end
    end end
    local p=self:best(own,"princess",j.species)
    local d=self:best(own,"drone",j.species)
    assert(p,"No analyzed princess in this job's collected offspring; inspect archive")
    if j.mode=="benchmark" then assert(d,"No analyzed drone in benchmark offspring; inspect archive") end
    j.lineage={endpoint=p.endpoint,slot=p.slot,identity=B.identity(p.stack)}
    if self.storage.releaseBatches then self.storage:releaseBatches(j.id,p.batchId,true) end
    if p and d and G.complete(p.stack,d.stack,j.species,self.c,template and template.stack.individual.active) then
      j.confirmed=j.confirmed+1
    else j.confirmed=0 end
    j.progress=(p and G.purity(p.stack,j.species) or 0)+(d and G.purity(d.stack,j.species) or 0)
    machine.job=nil; machine.state="IDLE"; machine.lastSuccess=self.now()
    j.machine=nil; j.state="WAITING"; j.error=nil; j.resultLocations=nil
    j.expectedPrincess=nil; j.preparedPrincess=nil; j.preparedDrone=nil; self.save()
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
  J.releaseCancelled(self.state)
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
    require("lib.storage.receipts").archive(self.state,tx); self.state.pending=nil
  end
  j.state=status=="FINISHED" and "COLLECTING" or "RUNNING"
  if status=="FINISHED" then j.collectionAfter=self.state.transferSequence or 0; j.resultLocations={} end
  j.previous=nil; j.error=nil; j.started=self.now(); self.save()
  if self.storage.releasePort then self.storage:releasePort(b.config.storage) end
end
function M:prepareStock(items)
  local oldReady,oldPhase,oldRemaining=self.state.stockReady,self.state.stockPhase,self.state.stockRemaining
  if self.storage.interface and not self.state.stockReady then self.state.stockPhase="PREPARING_STOCK" end
  if self.storage.prepare and not self.storage:prepare(items) then return false,"Inspecting ME stock" end
  local ready,why=self.scanner:step(items)
  if self.storage.interface then
    local remaining=0
    for _,i in ipairs(items) do if B.kind(i.stack)=="drone" and not B.scanned(i.stack) then remaining=remaining+i.stack.size end end
    if self.state.scan then remaining=math.max(remaining,self.state.scan.count or 0) end
    self.state.stockRemaining=remaining
    if ready and not self.state.stockReady then
      -- Check housing leftovers once at startup/resume. Later offspring are
      -- collected by their jobs; new network stock still passes scanner:step.
      for _,a in ipairs(self.c.alvearies) do
        local backend=self:backend(a.id)
        local output=a.routing and a.routing.output or backend.endpoint
        local stacks=self.inv:readSlots(output,a.slots.outputs)
        for _,slot in ipairs(a.slots.outputs) do local s=stacks[slot]
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
    if oldReady~=self.state.stockReady or oldPhase~=self.state.stockPhase or oldRemaining~=self.state.stockRemaining then self.save() end
  end
  return ready,why
end
function M:step()
  self.observations={}
  if self.state.paused then return false,"PAUSED" end
  local function progress()
    local pieces={tostring(#self.state.jobs),tostring(self.state.transferSequence or 0)}
    for _,j in ipairs(self.state.jobs) do pieces[#pieces+1]=j.state..":"..j.cycles..":"..j.confirmed end
    return table.concat(pieces,"|")
  end
  local before=progress()
  self.savedStatus=saveStatus(self.state)
  -- While queens are breeding, discover external stock every five seconds.
  -- Ready jobs and assessment still obtain fresh stock before using any bees.
  local breeding=self.storage.interface and self.state.stockReady and self.state.stockPhase~="SCANNING" and
    not self.state.scan and not self.state.pending and not self.state.pendingExternal
  local running=false
  for _,j in ipairs(self.state.jobs) do
    if j.state=="RUNNING" then running=true
    elseif j.state~="DONE" and (j.state~="WAITING" or J.ready(self.state,j)) then breeding=false end
  end
  local skipStock=breeding and running and self.nextStockScan and self.now()<self.nextStockScan
  -- A saved Interface scanner batch already knows its source and expected
  -- return. Refresh whole-network stock after it finishes, before selection.
  local ok,items=true,nil
  if not skipStock and not (self.storage.interface and self.state.scan) then
    ok,items=pcall(self.storage.scan,self.storage)
    if ok then self.nextStockScan=self.now()+5 end
  end
  if not ok then self.state.error=tostring(items); self.save(); return false,"BLOCKED" end
  self.state.error=nil
  if items then
    self.state.storageCounts={princess=0,drone=0}
    for _,i in ipairs(items) do local kind=B.kind(i.stack)
      if self.state.storageCounts[kind] then self.state.storageCounts[kind]=self.state.storageCounts[kind]+i.stack.size end
    end
    self:observeParentStock(items,true)
  end
  local scanOk,scanned,reason=true,true,nil
  if not skipStock then scanOk,scanned,reason=pcall(self.prepareStock,self,items or {}) end
  if not scanOk then self.state.error=tostring(scanned); scanned=false; self.save()
  elseif not scanned then self.state.error=reason end
  -- Only small counts are needed for display. Do not retain this whole-network
  -- snapshot while assessment/dispatch obtain fresh stock after movements.
  items=nil
  -- Advance machines even when a different scanner operation is outstanding.
  for _,j in ipairs(self.state.jobs) do
    if self.state.cancelRequested then break end
    if j.state=="RUNNING" or j.state=="COLLECTING" or j.state=="ASSESSING" then
      local success,err=pcall(self.advance,self,j,scanned,reason or self.state.error)
      if not success then self:pause(j,err); self:log(j.id..": "..tostring(err)) end
    end
  end
  if scanned and not self.state.stopping and not self.state.pending and not self.state.pendingExternal then
    -- Rotate the starting job each tick to avoid starving independent prerequisites.
    local n=#self.state.jobs; local start=(self.state.cursor or 0)%math.max(1,n)
    for off=1,n do local j=self.state.jobs[(start+off-1)%n+1]
      if self.state.cancelRequested then break end
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
  local needed={}
  for _,j in ipairs(self.state.jobs) do
    if j.state=="WAITING" and j.error=="Waiting for stable parent population" then
      for _,parent in ipairs(j.route and j.route.parents or {}) do needed[parent]=true end
    end
  end
  for species in pairs(self.state.parentStock) do if not needed[species] then self.state.parentStock[species]=nil end end
  -- Cursor position, observation timestamps and fresh stock counts can be
  -- recomputed after restart. Idle polls need no disk write. Physical/lifecycle
  -- transitions retain their own durable checkpoints; persist new diagnostics
  -- and terminal flags here as well.
  if not U.equal(saveStatus(self.state),self.savedStatus) then self.save() end
  return active,complete and "DONE" or self.state.stopped and "STOPPED" or active and "RUNNING" or
    (scanOk and not scanned and "SCANNING") or (progress()~=before and "PROGRESS") or "BLOCKED"
end
return M
