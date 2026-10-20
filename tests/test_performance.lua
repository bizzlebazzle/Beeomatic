local W=require("tests.mocks.world"); local ME=require("tests.mocks.me")
local U=require("lib.util"); local B=require("lib.bees")

test("component capability checks are reused but disconnected and replacement components are checked",function()
  local calls=0; local proxy={read=function() end}
  local c=require("lib.components").new({proxy=function() return proxy end,
    methods=function() calls=calls+1; return {read=false} end})
  for _=1,20 do c:proxy("device",{"read"}) end
  eq(calls,1)
  raises(function() c:proxy("device",{"missing"}) end,"missing method")
  proxy=nil; raises(function() c:proxy("device",{"read"}) end,"component unavailable")
  proxy={read=function() end}; c:proxy("device",{"read"}); eq(calls,2)
end)

test("grouped slot reads validate once and never reuse item contents",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local p=w.proxies.tp1; local size=p.getInventorySize; local sizes,reads=0,0
  p.getInventorySize=function(side) sizes=sizes+1; return size(side) end
  local read=p.getStackInSlot
  p.getStackInSlot=function(side,slot) reads=reads+1; return read(side,slot) end
  local ep=w.c.storage.endpoints[1]
  w.inventories.hub[3]=W.bee("Forest","drone",4)
  local slots=w.inv:readSlots(ep,{1,3,8})
  eq(sizes,1); eq(reads,3); eq(slots[3].size,4); eq(slots[1],nil)
  w.inventories.hub[3].size=2; eq(w.inv:readSlots(ep,{3})[3].size,2)
  p.getInventorySize=function() return nil end
  raises(function() w.inv:readSlots(ep,{3}) end,"inventory unavailable")
end)

test("transfer saves reservation with intent and keeps movement and receipt checkpoints",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.inventories.hub[1]=W.bee("Forest","drone",8)
  local snapshots={}
  w.inv.save=function() snapshots[#snapshots+1]=U.copy(w.state) end
  w.inv:move(w.storage:scan()[1],{id="a",transposer="tp1",side=3},10,2,"job")
  eq(#snapshots,3); eq(snapshots[1].pending.phase,"INTENT")
  eq(snapshots[1].reservations["hub:1"].owner,"job")
  eq(snapshots[2].pending.phase,"MOVED"); eq(snapshots[3].pending,nil)
  eq(snapshots[3].transactions[1].phase,"COMMITTED")
end)

test("transfer uses four fresh slot reads and no redundant size callbacks",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local ep=w.c.storage.endpoints[1]; local stack=W.bee("Forest","drone",8)
  w.inventories.hub[1]=stack
  local p=w.proxies.tp1; local read=p.getStackInSlot; local reads=0
  p.getInventorySize=function() error("redundant synchronized size callback") end
  p.getStackInSlot=function(...) reads=reads+1; return read(...) end
  w.inv:move({endpoint=ep,slot=1,stack=stack},{id="a",transposer="tp1",side=3},10,2,"job")
  eq(reads,4); eq(w.moves,1)
  eq(w.inventories.hub[1].size,6)
end)

test("slot reads distinguish empty inventory slots from OC error returns",function()
  local w=W.new(); w:addMachine("a"); w:build(); local ep=w.c.storage.endpoints[1]
  eq(w.inv:get(ep,1),nil)
  for _,reason in ipairs({"no inventory","not enabled in config"}) do
    w.proxies.tp1.getStackInSlot=function() return nil,reason end
    raises(function() w.inv:get(ep,1) end,reason)
    raises(function()
      w.inv:move({endpoint=ep,slot=1,stack=W.bee("Forest","drone",8)},
        {id="a",transposer="tp1",side=3},10,2,"job")
    end,reason)
    eq(w.moves,0); eq(w.state.pending,nil)
  end
end)

test("failed destination read after movement preserves the saved recovery receipt",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local ep=w.c.storage.endpoints[1]; local stack=W.bee("Forest","drone",8)
  w.inventories.hub[1]=stack
  local p=w.proxies.tp1; local read=p.getStackInSlot
  p.getStackInSlot=function(side,slot)
    if side==3 and w.moves>0 then return nil,"no inventory" end
    return read(side,slot)
  end
  raises(function()
    w.inv:move({endpoint=ep,slot=1,stack=stack},{id="a",transposer="tp1",side=3},10,2,"job")
  end,"no inventory")
  eq(w.moves,1); eq(w.state.pending.phase,"MOVED"); eq(w.state.pending.returned,2)
  p.getStackInSlot=read; ok(w.inv:reconcile()); eq(w.state.pending,nil); eq(w.moves,1)
end)

test("power failure at combined transfer intent moves nothing and reconciles",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.inventories.hub[1]=W.bee("Forest","drone",8)
  w.inv.save=function() error("power cut") end
  raises(function() w.inv:move(w.storage:scan()[1],{id="a",transposer="tp1",side=3},10,2,"job") end,"power cut")
  eq(w.moves,0); eq(w.state.pending.phase,"INTENT")
  w.inv.save=w.save; ok(w.inv:reconcile()); eq(w.state.pending,nil); eq(w.moves,0)
end)

test("ME entry selection clears only required slots and reuses a verified exact entry",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local clears,stores=0,0; local clear=w.proxies.db.clear; local store=w.proxies.me.store
  w.proxies.db.clear=function(slot) clears=clears+1; return clear(slot) end
  w.proxies.me.store=function(...) stores=stores+1; return store(...) end
  local item={stack=s}
  local slot=w.storage:selectEntry(item); eq(clears,1); eq(stores,1)
  eq(w.storage:selectEntry(item),slot); eq(clears,1); eq(stores,1)
  w.database[slot]=ME.bee("Forest","drone",8)
  slot=w.storage:selectEntry(item); eq(clears,2); eq(stores,2)
  eq(B.identity(w.database[slot]),B.identity(s))
end)

test("ME entry reuse still rejects missing stock through bounded receipt polling",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  w.storage:selectEntry({stack=s}); w.cells={}
  raises(function() w.storage:materialize({network=true,stack=s},w.c.scanner.storage,"scanner",1) end,"timeout waiting for Interface stock")
  eq(w.moves,0); ok(next(w.state.meRequests))
end)

test("structural equality compares all genes without allocating serialized copies",function()
  local encode=U.encode; U.encode=function() error("must not serialize") end
  local success,why=pcall(function()
    ok(U.equal({a={b=false,c=3}},{a={c=3,b=false}}))
    ok(not U.equal({a={b=false}},{a={}}))
    ok(not U.equal({a=1},{a="1"})); ok(not U.equal({},{extra=true}))
  end)
  U.encode=encode; assert(success,why)
end)

test("selection reserve accounting is linear and rebuilt after stock changes",function()
  local w=W.new(); w:build()
  local items={{endpoint={id="hub"},slot=1,stack=W.bee("Spirit","princess")}}
  for n=1,80 do
    local stack=W.bee("Spirit","drone",2); stack.tag="variant"..n
    items[#items+1]={endpoint={id="hub"},slot=n+1,stack=stack}
  end
  local job={species="spirit",mode="populate"}
  local identity=B.identity; local calls=0
  B.identity=function(stack) calls=calls+1; return identity(stack) end
  local success,p,d=pcall(w.scheduler.select,w.scheduler,job,items)
  B.identity=identity
  ok(success,p); ok(p); ok(d); ok(calls<=3*#items,"selection repeated full genotype scans: "..calls)
  for n=2,#items do items[n].stack.size=1 end
  local _,nextDrone=w.scheduler:select(job,items)
  eq(nextDrone,nil)
end)

test("selection adds split stacks of the same exact genotype before protecting reserves",function()
  local w=W.new(); w:build()
  local drone=W.bee("Spirit","drone",1); drone.tag="same-genotype"
  local items={{endpoint={id="hub"},slot=1,stack=W.bee("Spirit","princess")},
    {endpoint={id="hub"},slot=2,stack=drone},{endpoint={id="hub"},slot=3,stack=U.copy(drone)}}
  local _,selected=w.scheduler:select({species="spirit",mode="populate"},items)
  ok(selected)
  items[3].stack.tag="other-genotype"
  local _,protected=w.scheduler:select({species="spirit",mode="populate"},items)
  eq(protected,nil)
end)

test("network leases and PREPARING assignment are saved before materialization",function()
  local w=ME.new(); w.hideGenomes=false; w.c.minDrones=2
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8))
  local job=W.job(w,"job","Spirit","populate"); job.count=32
  local saved; w.scheduler.save=function() saved=U.copy(w.state) end
  local materialize=w.storage.materialize; local checked=0
  w.storage.materialize=function(self,item,...)
    eq(saved.jobs[1].state,"PREPARING"); ok(saved.jobs[1].machine)
    if checked==0 then
      local leases=0; for _,lease in pairs(saved.reservations) do if lease.owner==job.id then leases=leases+1 end end
      eq(leases,2)
    end
    checked=checked+1; return materialize(self,item,...)
  end
  w.scheduler:dispatch(job); eq(checked,2); eq(job.state,"RUNNING")
end)

test("fast polling fallbacks apply to saved five-second configurations with bounded overrides",function()
  local C=require("lib.config"); local c={pollSeconds=5,storage={},scanner={}}
  eq(C.pollInterval(c,"worker"),0.5); eq(C.pollInterval(c,"storage"),0.1); eq(C.pollInterval(c,"scanner"),0.1)
  c.workerPollSeconds=0.2; c.storage.pollSeconds=0.01; c.scanner.pollSeconds=2
  eq(C.pollInterval(c,"worker"),0.2); eq(C.pollInterval(c,"storage"),0.05); eq(C.pollInterval(c,"scanner"),2)
  c.workerPollSeconds=math.huge; raises(function() C.pollInterval(c,"worker") end,"invalid worker")
end)

test("unchanged stock preparation does not write another readiness checkpoint",function()
  local w=ME.new()
  ok(w.scheduler:prepareStock(w.storage:scan())); local saved=w.saves
  ok(w.scheduler:prepareStock(w.storage:scan())); eq(w.saves,saved)
  w:addStock(ME.bee("Spirit","drone",8,true))
  eq(w.scheduler:prepareStock(w.storage:scan()),false); ok(w.saves>saved); ok(w.state.scan)
end)

test("unchanged running polls write no checkpoints but changed obstruction diagnostics do",function()
  local w=ME.new(); w.hideGenomes=false; w.c.minDrones=2
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8))
  local job=W.job(w,"job","Spirit","populate"); job.count=32
  w.scheduler:step(); eq(job.state,"RUNNING")
  w.scheduler:step(); local saved=w.saves
  for _=1,10 do w.time=w.time+0.1; w.scheduler:step() end
  eq(w.saves,saved)
  w.obstructed=true; w.scheduler:step(); ok(w.saves>saved); ok(job.error)
  saved=w.saves; w.scheduler:step(); eq(w.saves,saved)
  w.obstructed=false; w.scheduler:step(); ok(w.saves>saved); eq(job.error,nil)
end)

test("indexed lineage protection respects genotype, slot type, owner and completed jobs",function()
  local w=W.new(); w:build()
  local p=W.bee("Spirit","princess"); local other=W.bee("Forest","princess")
  local snapshot={{endpoint={id="hub"},slot=1,stack=p},{endpoint={id="hub"},slot="1",stack=other}}
  w.state.jobs={{id="first",state="WAITING",lineage={endpoint={id="hub"},slot=1,identity=B.identity(p)}},
    {id="done",state="DONE",lineage={endpoint={id="hub"},slot="1",identity=B.identity(other)}}}
  local available=w.scheduler:items("second",snapshot); eq(#available,1); eq(available[1].slot,"1")
  eq(#w.scheduler:items("first",snapshot),2)
  snapshot[1].stack=other; eq(#w.scheduler:items("second",snapshot),2)
end)

test("Interface assessment reuses its verified stock snapshot without another scan",function()
  local w=ME.new(); w.hideGenomes=false; w.c.minDrones=2
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8))
  local job=W.job(w,"job","Spirit","populate"); job.count=32
  w.scheduler:dispatch(job); local machine=job.machine
  w:finish(machine,ME.bee("Spirit","princess"),ME.bee("Spirit","drone",4))
  -- Collect first, but leave assessment pending without changing scanner logic.
  local step=w.scanner.step; w.scanner.step=function() return false,"waiting" end
  w.scheduler:advance(job); eq(job.state,"ASSESSING")
  w.scanner.step=step
  local scan=w.storage.scan; local scans=0
  w.storage.scan=function(self) scans=scans+1; return scan(self) end
  w.scheduler:advance(job)
  eq(job.state,"WAITING"); eq(scans,1); ok(job.lineage)
end)

test("destination search reuses one bulk snapshot and prefers an exact merge beyond empty gaps",function()
  local w=W.new(); w:addMachine("a"); w:build(); local ep=w.c.storage.endpoints[1]
  local bee=W.bee("Spirit","drone",4); bee.tag="exact"; w.inventories.hub[87]=U.copy(bee)
  local proxy=w.proxies.tp1; local bulk=proxy.getAllStacks; local snapshots=0
  proxy.getAllStacks=function(side) snapshots=snapshots+1; return bulk(side) end
  proxy.getInventorySize=function() error("destination must use snapshot size") end
  proxy.getStackInSlot=function() error("destination must not reread slots") end
  eq(w.inv:destination(ep,bee),87); eq(snapshots,1)
  w.state.reservations["hub:87"]={owner="other"}
  eq(w.inv:destination(ep,bee),1); eq(snapshots,2)
  w.state.reservations={}; w.inventories.hub[87].tag="different"
  eq(w.inv:destination(ep,bee),1); eq(snapshots,3)
end)

test("fallback destination search reads each slot once and reports full inventories",function()
  local w=W.new(); w:addMachine("a"); w:build(); local ep=w.c.storage.endpoints[1]
  local proxy=w.proxies.tp1; proxy.getAllStacks=nil
  for slot=1,100 do w.inventories.hub[slot]=W.bee("Forest","drone",64) end
  w.inventories.hub[93]=nil
  local read,size=proxy.getStackInSlot,proxy.getInventorySize; local reads,sizes=0,0
  proxy.getStackInSlot=function(side,slot) reads=reads+1; return read(side,slot) end
  proxy.getInventorySize=function(side) sizes=sizes+1; return size(side) end
  local item=W.bee("Spirit","princess")
  eq(w.inv:destination(ep,item),93); eq(reads,100); eq(sizes,1)
  w.inventories.hub[93]=W.bee("Forest","drone",64)
  raises(function() w.inv:destination(ep,item) end,"inventory full")
  eq(reads,200); eq(sizes,2)
end)

test("ME unowned stock avoids another stack copy while returned genomes stay isolated",function()
  local w=ME.new(); w.hideGenomes=false; local bee=ME.bee("Spirit","drone",8); w:addStock(bee)
  local copy=U.copy; local stackCopies=0
  U.copy=function(value)
    if type(value)=="table" and value.name==bee.name and value.tag==bee.tag then stackCopies=stackCopies+1 end
    return copy(value)
  end
  local success,items=pcall(w.storage.scan,w.storage); U.copy=copy; ok(success,items)
  eq(stackCopies,2); eq(#items,1)
  items[1].stack.individual.active.fertility=99; items[1].stack.size=1
  eq(w.cells[B.identity(bee)].size,8); eq(w.cells[B.identity(bee)].individual.active.fertility,3)
  eq(w.state.aeCatalog[B.identity(bee)].active.fertility,3)
end)

test("ME owned splits and unowned remainder have independent returned genomes",function()
  local w=ME.new(); w.hideGenomes=false; local bee=ME.bee("Spirit","drone",8); w:addStock(bee)
  w.state.meBatches.owned={identity=B.identity(bee),count=3,owner="job",root="owned",stack=U.copy(bee)}
  local items=w.storage:scan(); eq(#items,2); eq(items[1].stack.size,3); eq(items[2].stack.size,5)
  items[1].stack.individual.active.fertility=99
  eq(items[2].stack.individual.active.fertility,3)
end)

test("completion skips stock and genotype work before stable confirmations",function()
  local w=W.new(); w:build()
  w.scheduler.populationMinimum=function() error("must not inspect stock before confirmations") end
  w.scheduler.count=function() error("must not count stock before confirmations") end
  for _,mode in ipairs({"breed","populate","convert","imprint"}) do
    eq(w.scheduler:completion({species="spirit",mode=mode,confirmed=2},{},nil),false)
  end
end)

test("default completion checks template candidates in one pass",function()
  local w=W.new(); w:build(); local items={}
  for n=1,40 do items[#items+1]={stack=W.bee("Spirit","princess",1,nil,{nocturnal=false})} end
  for n=1,40 do items[#items+1]={stack=W.bee("Forest","drone",32)} end
  items[#items+1]={stack=W.bee("Spirit","drone",32,nil,{nocturnal=false})}
  local template={stack=W.bee("Spirit","drone",1,nil,{nocturnal=true})}
  local job={species="spirit",mode="breed",confirmed=3,count=32}
  local G=require("lib.genetics"); local purity=G.purity; local calls=0
  G.purity=function(...) calls=calls+1; return purity(...) end
  local success,result=pcall(w.scheduler.completion,w.scheduler,job,items,template)
  G.purity=purity; ok(success,result); eq(result,false); ok(calls<=#items)
  for _,index in ipairs({1,#items}) do
    items[index].stack.individual.active.nocturnal=true; items[index].stack.individual.inactive.nocturnal=true
  end
  ok(w.scheduler:completion(job,items,template))
end)

test("optimized completion agrees with pairwise rules across stock, template and equivalence cases",function()
  local w=W.new(); w:build(); local G=require("lib.genetics")
  local function reference(job,items,template)
    local minimum=job.count or w.scheduler:populationMinimum(items,job.species)
    if job.mode=="convert" then
      return job.baseline and w.scheduler:count(items,job.species,"princess")>job.baseline and
        job.confirmed>=w.c.confirmCycles and w.scheduler:count(items,job.species,"drone")>=minimum
    end
    if w.scheduler:count(items,job.species,"drone")<minimum then return false end
    for _,p in ipairs(items) do if B.kind(p.stack)=="princess" then
      for _,d in ipairs(items) do if B.kind(d.stack)=="drone" and
        G.complete(p.stack,d.stack,job.species,w.c,template and template.stack.individual.active) then
        return job.confirmed>=w.c.confirmCycles
      end end
    end end
    return false
  end
  for n=1,144 do
    local items={}
    for i=1,6 do
      local species=(n+i)%3==0 and "Forest" or "Spirit"
      local kind=i%2==0 and "drone" or "princess"
      local stack=W.bee(species,kind,kind=="drone" and (n+i)%20+1 or 1,
        (n+i)%4==0 and "Forest" or nil,{fertility=(n+i)%3+1,nocturnal=(n+i)%2==0})
      if (n+i)%7==0 then stack.individual.isAnalyzed=false end
      items[#items+1]={stack=stack}
    end
    local modes={"breed","populate","convert","imprint"}
    local job={species="spirit",mode=modes[n%4+1],confirmed=n%5,count=n%2==0 and 8 or nil,baseline=n%3}
    local template=n%3==0 and {stack=W.bee("Spirit","drone",1,nil,{nocturnal=true})} or nil
    w.c.fullEquivalence=n%2==1
    eq(not not w.scheduler:completion(job,items,template),not not reference(job,items,template),"completion case "..n)
  end
end)


test("completed receipt history remains compact and bounded on every archive path",function()
  local receipts=require("lib.storage.receipts"); local state={transactions={}}
  for n=1,80 do
    receipts.archive(state,{id=n,identity="exact-nbt-"..n,stack={individual={large=string.rep("x",1000)}},
      transform={batchId="old"},source={id="source"},dest={id="archive"},count=2})
  end
  eq(#state.transactions,64); eq(state.transactions[1].id,17)
  for _,tx in ipairs(state.transactions) do
    eq(tx.stack,nil); eq(tx.transform,nil); eq(tx.count,2); eq(tx.identity,"exact-nbt-"..tx.id)
  end
end)

test("scheduler releases its observation inventory before obtaining a dispatch snapshot",function()
  local w=W.new(); w:build(); W.job(w,"job","Spirit","populate")
  local weak=setmetatable({},{__mode="v"}); local scans=0
  w.storage.scan=function()
    scans=scans+1
    if scans==1 then
      local items={{stack=W.bee("Spirit","drone",8),endpoint={id="hub"},slot=1}}
      weak[1]=items; return items
    end
    collectgarbage("collect"); eq(weak[1],nil,"observation retained full stock during dispatch")
    return {}
  end
  w.scheduler:step(); ok(scans>=2)
end)


test("optional memory collection tolerates missing and disabled host APIs",function()
  local native=collectgarbage
  local success,why=pcall(function()
    collectgarbage=nil; U.collect()
    collectgarbage=function() error("host collectgarbage unavailable") end; U.collect()
    local calls=0; collectgarbage=function(mode) eq(mode,"collect"); calls=calls+1 end
    U.collect(); eq(calls,1)
  end)
  collectgarbage=native; assert(success,why)
end)
