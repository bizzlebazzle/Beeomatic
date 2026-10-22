local ME=require("tests.mocks.me"); local B=require("lib.bees"); local U=require("lib.util")
local function select(w,s)
  return {network=true,endpoint={id="ME"},slot=B.identity(s),stack=U.copy(s)}
end

test("ME discovery filters all castes before fetching NBT and keeps every genotype",function()
  local w=ME.new(); w.hideGenomes=false
  for _,kind in ipairs({"princess","drone","queen"}) do
    for n=1,3 do w:addStock(ME.bee("Spirit",kind,n,false,{fertility=n})) end
  end
  w.cells.junk={name="gregtech:machine",size=64,tag=string.rep("x",10000)}
  local get=w.proxies.me.getItemsInNetwork; local calls={}
  w.proxies.me.getItemsInNetwork=function(filter)
    ok(filter and filter.name,"unfiltered network fetch")
    eq(filter.label,nil); eq(filter.damage,nil)
    calls[#calls+1]=filter.name; return get(filter)
  end
  local items=w.storage:scan(); eq(#items,9)
  eq(calls,{"Forestry:beePrincessGE","Forestry:beeDroneGE","Forestry:beeQueenGE"})
  local counts={}
  for _,i in ipairs(items) do
    local kind=B.kind(i.stack); counts[kind]=(counts[kind] or 0)+i.stack.size
    ok(B.scanned(i.stack)); eq(i.stack.individual.active.fertility,i.stack.size)
  end
  eq(counts,{princess=6,drone=6,queen=6})
end)

test("failed caste query preserves catalogue entries instead of treating stock as absent",function()
  local w=ME.new(); local bee=ME.bee("Spirit","drone",8)
  w.state.aeCatalog[B.identity(bee)]=U.copy(bee.individual)
  w.proxies.me.getItemsInNetwork=function(filter)
    if filter.name==bee.name then return nil,"network unavailable during scan" end
    return {}
  end
  raises(function() w.storage:scan() end,"network unavailable during scan")
  ok(w.state.aeCatalog[B.identity(bee)])
end)

test("NBT diagnostics and Interface probes never fetch unrelated network items",function()
  local w=ME.new(); w.hideGenomes=false; w:addStock(ME.bee("Spirit","drone",8))
  local get=w.proxies.me.getItemsInNetwork
  w.proxies.me.getItemsInNetwork=function(filter)
    ok(filter and filter.name,"unfiltered network fetch"); return get(filter)
  end
  require("lib.ui.diagnostics").nbt(w.storage,function() end)
  ok(w.storage:probe(w.c.scanner.storage))
end)
test("Interface recovery rebreeds fragmented target stock and scans offspring to stable 32 drones",function()
  local w=ME.new(); w.hideGenomes=false; w.c.storage.databaseSlots=16; w.state.nextId=1
  for _,species in ipairs({"Forest","Meadows"}) do
    w:addStock(ME.bee(species,"princess",3)); w:addStock(ME.bee(species,"drone",64))
  end
  local variants={}
  for n=1,9 do
    local s=ME.bee("Charmed","drone",1,false,{lifespan=n})
    if n%2==0 then s.individual.inactive.species=ME.bee("Forest","drone").individual.active.species; s.tag=U.encode(s.individual) end
    variants[#variants+1]=B.identity(s); w:addStock(s)
  end
  w.recipes={charmed={require("tests.mocks.world").route("Forest","Meadows")}}
  w.recipes["test.speciescharmed"]=w.recipes.charmed
  local j=require("tests.mocks.world").job(w,"job1","Charmed","convert")
  for tick=1,150 do
    if w.inventories.analyser[1] then w:finishScan() end
    local _,status=w.scheduler:step(); if status=="DONE" then break end
    if j.state=="RUNNING" then w:finish(j.machine,ME.bee("Charmed","princess"),ME.bee("Charmed","drone",8,true)) end
    w:tick()
  end
  ok(w.state.finished,require("lib.ui.status").render(w.state,w.c,true))
  ok(j.rebreeding); ok(j.confirmed>=w.c.confirmCycles)
  ok(B.count(w.storage:scan(),"charmed","drone",true)>=32)
  eq(w.state.scan,nil); eq(w.state.pending,nil); eq(next(w.state.meRequests),nil)
  for _,identity in ipairs(variants) do eq(w.cells[identity].size,1) end
end)

test("Interface deposits compact completed identities but preserve pending proof and returned ownership",function()
  for _,owner in ipairs({"scanner","job"}) do
    local w=ME.new(); w.immediate=true
    local s=ME.bee("Spirit","drone",4); local identity=B.identity(s); local expected=U.copy(s)
    w.inventories["scan-output"][1]=s
    local pending={}
    w.inv.save=function()
      if w.state.pending then pending[#pending+1]=U.copy(w.state.pending) end
    end
    local receipt=w.storage:deposit({endpoint=w.c.scanner.output,slot=1,stack=s},w.c.scanner.storage,owner)
    eq(#pending,2)
    for _,tx in ipairs(pending) do eq(tx.identity,identity); eq(tx.stack,expected) end
    eq(w.state.transactions[1].identity,nil); eq(w.state.transactions[1].stack,nil)
    eq(w.state.pending,nil); eq(B.identity(receipt.stack),identity)
    if owner=="scanner" then eq(receipt.slot,identity); eq(receipt.batchId,nil)
    else eq(w.state.meBatches[receipt.batchId].identity,identity); eq(receipt.slot,receipt.batchId) end
    eq(w.cells[identity].size,4)
  end
end)

test("Interface stocking and consumed cleanup need only intent ready and cleared checkpoints",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local saved={}; w.inv.save=function() saved[#saved+1]=U.copy(w.state) end
  local ep=w.c.alvearies[1].storage
  local p=w.storage:materialize(select(w,s),ep,"job",1)
  eq(#saved,2); eq(saved[1].meRequests["port1:2"].phase,"INTENT")
  eq(saved[2].meRequests["port1:2"].phase,"READY")
  w.inv:move(p,{id="destination",transposer="tp1",side=3},10,1,"job")
  eq(#saved,5); ok(saved[5].meRequests["port1:2"].consumed)
  w.storage:releasePort(ep); eq(#saved,6); eq(next(saved[6].meRequests),nil)
end)

test("a crash after filter configuration resumes saved intent without configuring or extracting twice",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local saved; w.inv.save=function() saved=U.copy(w.state) end
  local ep=w.c.alvearies[1].storage; local port=w.proxies[ep.address]
  local configure=port.setInterfaceConfiguration
  port.setInterfaceConfiguration=function(...) configure(...); w:tick(); error("power cut") end
  raises(function() w.storage:materialize(select(w,s),ep,"job",1) end,"power cut")
  eq(saved.meRequests["port1:2"].phase,"INTENT")
  w.state.meRequests=U.copy(saved.meRequests)
  port.setInterfaceConfiguration=function() error("must reuse configured filter") end
  local p=w.storage:materialize(select(w,s),ep,"job",1)
  eq(p.stack.size,1); eq(w.cells[B.identity(s)].size,7); eq(w.moves,0)
end)

test("consumed cleanup recovers from a crash after clearing the filter using the committed receipt",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local saved; w.inv.save=function() saved=U.copy(w.state) end
  local ep=w.c.alvearies[1].storage
  local p=w.storage:materialize(select(w,s),ep,"job",1)
  w.inv:move(p,{id="destination",transposer="tp1",side=3},10,1,"job")
  local port=w.proxies[ep.address]; local configure=port.setInterfaceConfiguration
  port.setInterfaceConfiguration=function(...) configure(...); error("power cut") end
  raises(function() w.storage:releasePort(ep) end,"power cut")
  ok(saved.meRequests["port1:2"].consumed)
  w.state.meRequests=U.copy(saved.meRequests); port.setInterfaceConfiguration=configure
  w.storage:reconcile(); eq(next(w.state.meRequests),nil)
  eq(w.moves,1); eq(w.cells[B.identity(s)].size,7)
end)

test("unconsumed cancellations persist intent before clearing and retries reuse that intent",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local ep=w.c.alvearies[1].storage
  w.storage:materialize(select(w,s),ep,"job",1)
  local saved={}; w.inv.save=function() saved[#saved+1]=U.copy(w.state) end
  local port=w.proxies[ep.address]; local configure=port.setInterfaceConfiguration
  port.setInterfaceConfiguration=function(...) configure(...); error("power cut") end
  raises(function() w.storage:cancel("job") end,"power cut")
  eq(#saved,1); eq(saved[1].meRequests["port1:2"].phase,"RETURNING")
  w.state.meRequests=U.copy(saved[1].meRequests); port.setInterfaceConfiguration=configure
  w.storage:reconcile(); eq(#saved,2); eq(next(w.state.meRequests),nil)
  eq(w.cells[B.identity(s)].size,8); eq(w.moves,0)
end)

test("Interface stocks the exact bee when database and physical NBT use different compound order",function()
  local F=require("tests.fixtures.nbt"); local w=ME.new(); local s=ME.bee("End","queen",1); s.tag=F.a; w:addStock(s)
  local store=w.proxies.me.store
  w.proxies.me.store=function(...) local yes=store(...); w.database[1].tag=F.b; return yes end
  local read=w.proxies["tp-scan"].getStackInSlot
  w.proxies["tp-scan"].getStackInSlot=function(...)
    local stack=read(...); if stack and stack.tag==F.a then stack=U.copy(stack); stack.tag=F.b end; return stack
  end
  local p=w.storage:materialize(select(w,s),w.c.scanner.storage,"scanner",1)
  eq(B.identity(p.stack),B.identity(s)); eq(p.stack.tag,F.b)
  eq(w.state.meRequests["scan-port:2"].phase,"READY"); eq(w.moves,0)
  w.storage:cancel("scanner"); eq(w.cells[B.identity(s)].size,1)
end)

test("Interface still blocks a genuinely different complete NBT payload",function()
  local F=require("tests.fixtures.nbt"); local w=ME.new(); local s=ME.bee("End","queen",1); s.tag=F.a; w:addStock(s)
  local store=w.proxies.me.store
  w.proxies.me.store=function(...) local yes=store(...); w.database[1].tag=F.changed; return yes end
  raises(function() w.storage:materialize(select(w,s),w.c.scanner.storage,"scanner",1) end,"after 3 automatic rebuilds")
  eq(next(w.state.meRequests),nil); eq(w.moves,0); eq(w.cells[B.identity(s)].size,1)
end)

test("an old compressed-byte stock request resumes after migration without another configuration",function()
  local F=require("tests.fixtures.nbt"); local w=ME.new(); local s=ME.bee("End","queen",1); s.tag=F.a; w:addStock(s)
  local item=select(w,s)
  w.storage:materialize(item,w.c.scanner.storage,"scanner",1)
  local old=U.encode({name=s.name,damage=s.damage,tag=s.tag})
  w.state.meRequests["scan-port:2"].identity=old
  w.state.aeCatalog={[old]=U.copy(s.individual)}
  w.state.scan={phase="REQUESTING",identity=old,item=item,count=1}
  w.filters["scan-port"][2].tag=F.b; w.inventories["scan-port"][2].tag=F.b
  require("lib.inventory").new(w.components,w.state,w.save)
  w.proxies["if-scan"].setInterfaceConfiguration=function() error("must reuse saved request") end
  w.storage:validate()
  local p=w.storage:materialize(item,w.c.scanner.storage,"scanner",1)
  eq(p.stack.tag,F.b); eq(w.state.scan.identity,B.identity(s)); eq(w.state.meRequests["scan-port:2"].identity,B.identity(s))
  eq(w.cells[B.identity(s)],nil); eq(w.moves,0)
end)

test("NBT diagnostic inspects the blocked scanner selection without moving bees or saving",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  w.state.scan={phase="REQUESTING",item=select(w,s)}
  local before=U.copy(w.state); w.inv.save=function() error("must not save") end
  local store=w.proxies.me.store
  w.proxies.me.store=function(...) local result=store(...); w.database[1].tag="different"; return result end
  local lines={}
  require("lib.ui.diagnostics").nbt(w.storage,function(line) lines[#lines+1]=line end)
  local report=table.concat(lines,"\n")
  ok(report:find("exact matches=1",1,true)); ok(report:find("NBT=false",1,true))
  ok(report:find("first NBT difference=",1,true)); eq(w.state,before); eq(w.moves,0)
  eq(next(w.filters["scan-port"]),nil); eq(w.cells[B.identity(s)].size,8)
end)

test("NBT diagnostic distinguishes empty copies and refuses unresolved transfers",function()
  local w=ME.new(); w:addStock(ME.bee("Spirit","drone",8))
  w.proxies.me.store=function() return true end
  local lines={}; local diagnostic=require("lib.ui.diagnostics").nbt
  diagnostic(w.storage,function(line) lines[#lines+1]=line end)
  ok(table.concat(lines,"\n"):find("Entry 1: EMPTY",1,true))
  w.state.pending={phase="INTENT"}
  raises(function() diagnostic(w.storage,function() end) end,"unresolved movement")
end)

test("Interface automatically rebuilds a mismatched database before stocking",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local store=w.proxies.me.store; local copies=0
  w.proxies.me.store=function(...)
    copies=copies+1; local result=store(...)
    if copies<3 then w.database[1]=ME.bee("Spirit","drone",8,nil,{fertility=4}) end
    return result
  end
  local p=w.storage:materialize(select(w,s),w.c.scanner.storage,"scanner",1)
  eq(copies,3); eq(B.identity(p.stack),B.identity(s)); eq(p.stack.size,1)
  eq(w.cells[B.identity(s)].size,7); eq(w.moves,0)
end)

test("persistent database mismatch stops bounded repair without configuring stock",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local copies=0
  w.proxies.me.store=function()
    copies=copies+1; w.database[1]=ME.bee("Spirit","drone",8,nil,{fertility=4}); return true
  end
  raises(function() w.storage:materialize(select(w,s),w.c.scanner.storage,"scanner",1) end,"after 3 automatic rebuilds")
  eq(copies,3); eq(w.storage.databaseEntry,nil); eq(next(w.state.meRequests),nil)
  eq(next(w.filters["scan-port"]),nil); eq(w.moves,0); eq(w.cells[B.identity(s)].size,8)
end)

test("database repair honours interruption before another copy",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s); w.interrupt=true
  local copies=0
  w.proxies.me.store=function() copies=copies+1; return true end
  raises(function() w.storage:materialize(select(w,s),w.c.scanner.storage,"scanner",1) end,"interrupted")
  eq(copies,1); eq(next(w.state.meRequests),nil); eq(w.moves,0)
end)

test("Interface stocking and cleanup react within a tenth second of a ready grid",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local started=w.time
  local physical=w.storage:materialize(select(w,s),w.c.scanner.storage,"scanner",8)
  eq(physical.stack.size,8); ok(w.time-started<=0.1)
  w.storage:cancel("scanner")
  ok(w.time-started<=0.2); eq(next(w.state.meRequests),nil)
  eq(B.count(w.storage:scan(),"Spirit","drone",true),8)
end)

test("Interface polling remains bounded and preserves requests when stock never arrives",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s); w.noStock=true
  w.c.storage.timeout=1; local waits=0; local wait=w.storage.wait
  w.storage.wait=function(seconds) waits=waits+1; return wait(seconds) end
  raises(function() w.storage:materialize(select(w,s),w.c.scanner.storage,"scanner",8) end,"timeout waiting for Interface stock")
  ok(waits>=10 and waits<=11); eq(w.time,1); ok(next(w.state.meRequests)); eq(w.moves,0)
end)
test("ME stock drops obsolete cached genomes but retains recoverable request references",function()
  local w=ME.new(); local live=ME.bee("Spirit","drone",8); w:addStock(live)
  local B=require("lib.bees"); local old=ME.bee("Forest","drone",8)
  w.state.aeCatalog[B.identity(live)]=U.copy(live.individual)
  w.state.aeCatalog[B.identity(old)]=U.copy(old.individual)
  w.state.aeCatalog.protected={species="retained"}
  w.state.meRequests.test={identity="protected"}
  local items=w.storage:scan()
  eq(w.state.aeCatalog[B.identity(old)],nil); ok(w.state.aeCatalog[B.identity(live)])
  ok(w.state.aeCatalog.protected); ok(B.scanned(items[1].stack))
end)

local function bufferedScanner(count)
  local w=ME.new(); w:addStock(ME.bee("Spirit","drone",count or 8,true)); return w
end

test("buffered scanner verifies output chest and requests AE stock only once",function()
  local w=bufferedScanner(); w.storage:validate(); w.scanner:validate(); require("lib.config").validate(w.c)
  local materialize=w.storage.materialize; local requests=0
  w.storage.materialize=function(self,...) requests=requests+1; return materialize(self,...) end
  eq(w.scheduler:prepareStock(w.storage:scan()),false); eq(w.moves,1)
  w:finishScan()
  -- No ME inventory or database queries are needed to verify and deposit output.
  w.proxies.me.getItemsInNetwork=function() error("must inspect chest directly") end
  w.proxies.me.store=function() error("must not request returned bees") end
  w.scanner:step({}); eq(w.moves,2); eq(requests,1); eq(w.state.scan,nil)
  eq(next(w.state.meRequests),nil); eq(w.cells[B.identity(ME.bee("Spirit","drone",8))].size,8)
end)

test("buffered scanner drains all initial drones across batches",function()
  local w=bufferedScanner(130); local count=0
  for _=1,12 do
    if w.scheduler:prepareStock(w.storage:scan()) then break end
    if w.inventories.analyser[1] then count=count+w.inventories.analyser[1].size; w:finishScan() end
  end
  eq(count,130); eq(w.moves,6); eq(w.state.stockPhase,"READY")
  eq(B.count(w.storage:scan(),"Spirit","drone",true),130)
end)

test("buffered returns preserve ownership across batch splits and merged ME stock",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8,true); w.inventories.a[8]=s
  local receipt=w.storage:deposit({endpoint={id="a",transposer="tp1",side=3},slot=8,stack=s},w.c.alvearies[1].storage,"job")
  w:addStock(ME.bee("Spirit","drone",12)); w.c.scanner.batchSize=3
  for _=1,12 do
    if w.scanner:step(w.storage:scan()) then break end
    if w.inventories.analyser[1] then w:finishScan() end
  end
  local owned,free=0,0
  for _,item in ipairs(w.storage:scan()) do
    ok(B.scanned(item.stack))
    if item.owner then eq(item.owner,"job"); eq(item.root,receipt.root); owned=owned+item.stack.size
    else free=free+item.stack.size end
  end
  eq(owned,8); eq(free,12)
end)

test("buffered scanner waits for complete output and preserves timed out batch",function()
  local w=bufferedScanner(); w.scanner:step(w.storage:scan()); w:finishScan()
  w.inventories["scan-output"][1].size=3
  eq(w.scanner:step({}),false); eq(w.moves,1)
  w.time=601; raises(function() w.scanner:step({}) end,"batch preserved")
  eq(w.state.scan.count,8); w.scheduler:recover(); w.inventories["scan-output"][1].size=8
  w.scanner:step({}); eq(w.state.scan,nil); eq(w.moves,2)
end)

test("buffered scanner rejects raw wrong caste wrong species and excess output",function()
  for _,s in ipairs({ME.bee("Spirit","drone",8,true),ME.bee("Spirit","princess",8),
    ME.bee("Forest","drone",8),ME.bee("Spirit","drone",9)}) do
    local w=bufferedScanner(); w.scanner:step(w.storage:scan()); w:finishScan(); w.inventories["scan-output"][1]=s
    raises(function() w.scanner:step({}) end,"scanner")
    eq(w.state.scan.phase,"PROCESSING"); eq(w.moves,1)
  end
end)

test("buffered scanner rejects contaminated output and untracked startup stock",function()
  local w=bufferedScanner(); w.scanner:step(w.storage:scan()); w:finishScan()
  w.inventories["scan-output"][2]=ME.bee("Forest","drone",1)
  raises(function() w.scanner:step({}) end,"contaminated"); eq(w.moves,1)
  local other=bufferedScanner(); other.inventories["scan-output"][4]=ME.bee("Spirit","drone",1)
  local _,status=other.scheduler:step(); eq(status,"BLOCKED"); eq(other.moves,0)
end)

test("unrelated AE changes cannot satisfy or contaminate buffered scanner output",function()
  local w=bufferedScanner(); w.scanner:step(w.storage:scan())
  w:addStock(ME.bee("Spirit","drone",9)); w:addStock(ME.bee("Forest","drone",32,true))
  eq(w.scanner:step({}),false); eq(w.moves,1)
  w:finishScan(); w.scanner:step({}); eq(w.state.scan,nil)
  eq(B.count(w.storage:scan(),"Spirit","drone",true),17)
  w.scanner:step(w.storage:scan()); eq(w.state.scan.name,ME.bee("Forest","drone").name)
end)

test("buffered scanner restarts after input acceptance without reinserting",function()
  local w=bufferedScanner(); local save=w.inv.save; local cut=false
  w.inv.save=function()
    save(); if w.state.scan and w.state.scan.inserted and not cut then cut=true; error("input power cut") end
  end
  raises(function() w.scanner:step(w.storage:scan()) end,"input power cut")
  w.inv.save=save; w:finishScan(); w.scheduler:recover()
  w.scanner:step(w.storage:scan()); w.scanner:step(w.storage:scan())
  eq(w.moves,2); eq(w.state.scan,nil)
end)

test("buffered scanner can finish immediately after input extraction",function()
  local w=bufferedScanner()
  w.afterTransfer=function() if w.inventories.analyser[1] then w:finishScan() end; w:tick() end
  w.scanner:step(w.storage:scan()); w.scanner:step({})
  eq(w.moves,2); eq(w.state.scan,nil); eq(w.state.pending,nil)
end)

test("buffered scanner chooses an empty input slot automatically",function()
  local w=bufferedScanner(); w.inventories.analyser[1]={name="marker",size=1}
  w.scanner:step(w.storage:scan()); eq(w.state.scan.inputSlot,2)
  eq(w.inventories.analyser[2].size,8); eq(w.inventories.analyser[1].name,"marker")
end)

test("Interface requests exact NBT and only the requested drone quantity",function()
  local w=ME.new(); local right=ME.bee("Spirit","drone",8); local wrong=ME.bee("Spirit","drone",7,nil,{fertility=4})
  w:addStock(wrong); w:addStock(right); w.storage:validate()
  local p=w.storage:materialize(select(w,right),w.c.alvearies[1].storage,"j",2)
  eq(p.stack.tag,right.tag); eq(p.stack.size,2); eq(w.cells[B.identity(right)].size,6)
  eq(w.filters.port1[2].size,2); eq(w.state.meRequests["port1:2"].phase,"READY")
end)
test("Interface source refill does not invalidate a witnessed destination",function()
  local w=ME.new(); w.immediate=true; local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local p=w.storage:materialize(select(w,s),w.c.alvearies[1].storage,"j",1)
  local dest={id="destination",transposer="tp1",side=3}
  w.inv:move(p,dest,10,1,"j"); eq(w.inventories.port1[2].size,1)
  w.storage:releasePort(p.endpoint); eq(w.filters.port1[2],nil); eq(w.inventories.port1[2],nil)
  eq(w.cells[B.identity(s)].size,7); eq(w.state.pending,nil)
end)
test("Interface return may drain before readback without losing ownership receipt",function()
  local w=ME.new(); w.immediate=true; local s=ME.bee("Spirit","princess",1); w.inventories.a[6]=s
  local receipt=w.storage:deposit({endpoint={id="breeder/a",transposer="tp1",side=3},slot=6,stack=s},w.c.alvearies[1].storage,"job")
  eq(w.inventories.port1[9],nil); ok(receipt.batchId); eq(w.state.meBatches[receipt.batchId].count,1)
  local items=w.storage:scan(); eq(#items,1); eq(items[1].owner,"job"); ok(B.scanned(items[1].stack))
end)
test("Interface full ME preserves local return and committed batch for recovery",function()
  local w=ME.new(); w.full=true; local s=ME.bee("Spirit","drone",8); w.inventories.a[8]=s
  raises(function() w.storage:deposit({endpoint={id="breeder/a",transposer="tp1",side=3},slot=8,stack=s},w.c.alvearies[1].storage,"job") end,"full/offline")
  eq(w.inventories.a[8],nil); eq(w.inventories.port1[9].size,8); eq(w.state.meBatches["receipt/1"].count,8)
  eq(#w.storage:scan(),1); w.full=false; w:tick(); eq(#w.storage:scan(),1)
end)
test("Interface crash after accepted return is reconciled without a second deposit",function()
  local w=ME.new(); local s=ME.bee("Spirit","princess"); w.inventories.a[6]=s
  local saved=w.save; local cut=false
  w.inv.save=function() saved(); if w.state.pending and w.state.pending.phase=="MOVED" and not cut then cut=true; error("power cut") end end
  raises(function() w.storage:deposit({endpoint={id="breeder/a",transposer="tp1",side=3},slot=6,stack=s},w.c.alvearies[1].storage,"job") end,"power cut")
  w:tick(); local moves=w.moves; w.inv.save=saved; ok(w.inv:reconcile()); eq(w.moves,moves)
  eq(w.state.meBatches["receipt/1"].count,1); eq(w.state.pending,nil)
end)
test("Interface restart without return acceptance proof pauses an ambiguous drain",function()
  local w=ME.new(); w.immediate=true; local s=ME.bee("Spirit","princess"); w.inventories.a[6]=s; w.throwAfterMove=true
  raises(function() w.storage:deposit({endpoint={id="breeder/a",transposer="tp1",side=3},slot=6,stack=s},w.c.alvearies[1].storage,"job") end,"uncertain")
  local moves=w.moves; local yes=w.inv:reconcile(); eq(yes,false); eq(w.moves,moves); ok(w.state.pending)
end)
test("Interface refuses fuzzy identity substitutions and undersized database",function()
  local w=ME.new(); local a=ME.bee("Spirit","drone",8); local b=ME.bee("Spirit","drone",8,nil,{fertility=4})
  w:addStock(a); w:addStock(b); w.c.storage.databaseSlots=1
  raises(function() w.storage:materialize(select(w,a),w.c.alvearies[1].storage,"j",1) end,"database capacity")
  eq(w.filters.port1[2],nil)
end)
test("Interface interruption retains bounded stock request for inspection",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s); w.interrupt=true
  raises(function() w.storage:materialize(select(w,s),w.c.alvearies[1].storage,"j",1) end,"interrupted")
  ok(w.state.meRequests["port1:2"]); eq(w.moves,0)
end)
test("startup inspects analysed network drones without consuming analyser supplies",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local ready=w.scheduler:prepareStock(w.storage:scan()); eq(ready,false); eq(w.state.scan,nil)
  eq(w.inventories.analyser[1],nil); ok(w.state.aeCatalog[B.identity(s)])
  ok(w.scheduler:prepareStock(w.storage:scan())); eq(w.state.stockPhase,"READY")
end)
test("startup analyses every drone unit across multiple stack-sized batches",function()
  local w=ME.new(); w:addStock(ME.bee("Spirit","drone",130,true)); local analysed=0
  for _=1,15 do
    local ready=w.scheduler:prepareStock(w.storage:scan())
    if ready then break end
    if w.inventories.analyser[1] then analysed=analysed+w.inventories.analyser[1].size; w:finishScan() end
  end
  eq(analysed,130); eq(w.state.stockPhase,"READY"); eq(w.state.scan,nil)
  for _,item in ipairs(w.storage:scan()) do ok(B.scanned(item.stack)) end
end)
test("startup cannot dispatch while raw drones or an interrupted scanner batch remain",function()
  local w=ME.new(); w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8,true))
  local j=require("tests.mocks.world").job(w,"job","Spirit","populate")
  for _=1,3 do w.scheduler:step() end
  eq(j.state,"WAITING"); eq(w.state.stockReady,nil); eq(w.state.stockPhase,"PREPARING_STOCK")
  ok(w.state.scan); eq(w.inventories.a[4],nil)
  w.scheduler:recover(); eq(w.state.stockReady,false); w:finishScan()
  for _=1,5 do w.scheduler:step(); if j.state=="RUNNING" then break end end
  eq(j.state,"RUNNING"); eq(w.state.stockReady,true)
end)
test("scanner unavailable blocks initial raw drones and preserves error text",function()
  local w=ME.new(); w.c.scanner.enabled=false; w:addStock(ME.bee("Spirit","drone",8,true))
  local _,status=w.scheduler:step(); eq(status,"BLOCKED"); ok(w.state.error:find("Shared scanner required",1,true))
  eq(w.state.stockReady,nil); eq(w.moves,0)
end)
test("unknown same-label variants are each inspected before initial readiness",function()
  local w=ME.new(); local a=ME.bee("Spirit","drone",8); local b=ME.bee("Spirit","drone",8,nil,{fertility=4})
  w:addStock(a); w:addStock(b)
  eq(w.scheduler:prepareStock(w.storage:scan()),false)
  eq(w.scheduler:prepareStock(w.storage:scan()),false)
  ok(w.scheduler:prepareStock(w.storage:scan())); ok(w.state.aeCatalog[B.identity(a)]); ok(w.state.aeCatalog[B.identity(b)])
end)
test("shared scanner changes NBT while retaining batch ownership across ME merges",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8,true); w.inventories.a[8]=s
  local receipt=w.storage:deposit({endpoint={id="breeder/a",transposer="tp1",side=3},slot=8,stack=s},w.c.alvearies[1].storage,"job")
  w:addStock(ME.bee("Spirit","drone",12))
  for _=1,5 do w.scanner:step(w.storage:scan()); if w.inventories.analyser[1] then w:finishScan() end end
  local batch=w.state.meBatches[receipt.batchId]; eq(batch.owner,"job"); eq(batch.count,8); ok(batch.identity~=B.identity(s))
  local owned,free=0,0
  for _,i in ipairs(w.storage:scan()) do ok(B.scanned(i.stack)); if i.owner then owned=owned+i.stack.size else free=free+i.stack.size end end
  eq(owned,8); eq(free,12)
end)
test("two alvearies draw independently from ME and keep their own offspring",function()
  local w=ME.new(); w.hideGenomes=false; w.c.minDrones=2; w.c.confirmCycles=1
  w:addStock(ME.bee("Spirit","princess",2)); w:addStock(ME.bee("Spirit","drone",16))
  local W=require("tests.mocks.world"); local a=W.job(w,"first","Spirit","populate"); local b=W.job(w,"second","Spirit","populate")
  w.scheduler:step(); eq(a.state,"RUNNING"); eq(b.state,"RUNNING"); ok(a.machine~=b.machine)
  local ma,mb=a.machine,b.machine
  w:finish(ma,ME.bee("Spirit","princess"),ME.bee("Spirit","drone",4,true))
  w:finish(mb,ME.bee("Spirit","princess"),ME.bee("Spirit","drone",6,true))
  for _=1,20 do
    w.scheduler:step(); if w.inventories.analyser[1] then w:finishScan() end
    if a.state=="DONE" and b.state=="DONE" then break end
  end
  eq(a.state,"DONE",require("lib.ui.status").render(w.state,w.c,true)); eq(b.state,"DONE")
  eq(w.state.pending,nil); eq(w.state.scan,nil); eq(next(w.state.meBatches),nil)
end)
test("shared scanner restart after committed return does not analyse twice",function()
  local w=ME.new(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); w:finishScan()
  local save=w.inv.save; local cut=false
  w.inv.save=function()
    save()
    if not w.state.pending and w.state.scan and w.state.scan.phase=="RETURNING" and #w.state.transactions>=2 and not cut then
      cut=true; error("power cut")
    end
  end
  raises(function() w.scanner:step(w.storage:scan()) end,"power cut")
  w.inv.save=save; w:tick(); local moves=w.moves
  w.scanner:step(w.storage:scan()); eq(w.state.scan,nil); eq(w.moves,moves)
end)
test("new external raw drone variants close dispatch until inspected",function()
  local w=ME.new(); w.hideGenomes=false; w:addStock(ME.bee("Spirit","drone",8))
  ok(w.scheduler:prepareStock(w.storage:scan())); w:addStock(ME.bee("Forest","drone",3,true))
  eq(w.scheduler:prepareStock(w.storage:scan()),false); eq(w.state.stockPhase,"SCANNING")
  ok(w.state.scan); w:finishScan(); w.scheduler:prepareStock(w.storage:scan())
  ok(w.scheduler:prepareStock(w.storage:scan())); eq(w.state.stockPhase,"READY")
end)

test("running alveary is monitored and collected while newly added bees scan in the background",function()
  local w=ME.new(); w.hideGenomes=false; w.c.minDrones=2; w.c.confirmCycles=1
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8))
  local j=require("tests.mocks.world").job(w,"job","Spirit","populate")
  w.scheduler:step(); eq(j.state,"RUNNING"); local machine=j.machine
  w:addStock(ME.bee("Forest","drone",3,true)); w.scheduler:step()
  eq(w.state.scan,nil); eq(j.state,"RUNNING")
  w.time=w.scheduler.nextStockScan; w.scheduler:step()
  eq(j.state,"RUNNING"); eq(w.state.scan.phase,"PROCESSING"); eq(w.state.stockPhase,"SCANNING")
  w:addStock(ME.bee("Meadows","drone",32,true)); w.scheduler:step()
  eq(j.state,"RUNNING"); eq(w.state.error,"Shared scanner waiting for output: 0/3 analysed bees in scan-output")
  w:finish(machine,ME.bee("Spirit","princess"),ME.bee("Spirit","drone",4,true))
  w.scheduler:step(); eq(j.state,"ASSESSING"); eq(w.state.pending,nil)
  for _=1,20 do
    if w.inventories.analyser[1] then w:finishScan() end
    w.scheduler:step()
    if j.state=="DONE" and not w.state.scan then break end
  end
  eq(j.state,"DONE"); eq(w.state.scan,nil); eq(w.state.error,nil)
  eq(B.count(w.storage:scan(),"Forest","drone",true),3)
  eq(B.count(w.storage:scan(),"Meadows","drone",true),32)
end)
test("untracked initial analyser contents cannot bypass startup",function()
  local w=ME.new(); w.inventories.analyser[1]=ME.bee("Spirit","drone",1,true)
  local _,status=w.scheduler:step(); eq(status,"BLOCKED"); eq(w.state.stockReady,nil)
  ok(w.state.error:find("untracked shared scanner",1,true))
end)
test("startup collects and scans initial drones left in an idle alveary",function()
  local w=ME.new(); w.inventories.a[8]=ME.bee("Spirit","drone",3,true)
  eq(w.scheduler:prepareStock(w.storage:scan()),false); eq(w.inventories.a[8],nil)
  eq(w.scheduler:prepareStock(w.storage:scan()),false); w:finishScan()
  w.scheduler:prepareStock(w.storage:scan()); ok(w.scheduler:prepareStock(w.storage:scan()))
  eq(B.count(w.storage:scan(),"Spirit","drone",true),3)
end)
test("Interface doctor probe verifies partial extraction and returns all test stock",function()
  local w=ME.new(); w.immediate=true; local s=ME.bee("Spirit","drone",8); w:addStock(s)
  ok(w.storage:probe(w.c.alvearies[1].storage)); eq(w.cells[B.identity(s)].size,8)
  eq(next(w.state.meRequests),nil); eq(next(w.state.meBatches),nil)
  eq(w.state.interfaceProbes.port1.extracted,1); eq(w.state.interfaceProbes.port1.requested,2)
end)
test("scanner restart immediately after input receipt does not insert twice",function()
  local w=ME.new(); w:addStock(ME.bee("Spirit","drone",8,true))
  local save=w.inv.save; local cut=false
  w.inv.save=function()
    save()
    if w.state.scan and w.state.scan.phase=="INSERTING" and w.state.scan.inserted and not cut then
      cut=true; error("input power cut")
    end
  end
  raises(function() w.scanner:step(w.storage:scan()) end,"input power cut")
  eq(w.state.scan.phase,"INSERTING"); w.inv.save=save; local moves=w.moves
  w.scheduler:recover(); w.scanner:step(w.storage:scan()); eq(w.moves,moves); eq(w.state.scan.phase,"PROCESSING")
  w:finishScan(); w.scanner:step(w.storage:scan()); eq(w.state.scan,nil)
end)
test("startup detects an untracked specimen outside configured analyser input slot",function()
  local w=ME.new(); w.inventories.analyser[4]=ME.bee("Spirit","drone",1,true)
  local _,status=w.scheduler:step(); eq(status,"BLOCKED"); ok(w.state.error:find("untracked shared scanner",1,true))
end)
test("collection reconstructs logical roots after physical history has expired",function()
  local w=ME.new(); w.hideGenomes=false; w.c.minDrones=2; w.c.confirmCycles=1
  local j=require("tests.mocks.world").job(w,"job","Spirit","populate")
  j.machine="a"; j.state="COLLECTING"; j.collectionAfter=0; w.state.machines.a={job=j.id,state="COLLECTING"}
  for slot,s in pairs({[6]=ME.bee("Spirit","princess"),[8]=ME.bee("Spirit","drone",4)}) do
    w.inventories.a[slot]=s
    w.storage:deposit({endpoint={id="breeder/a",transposer="tp1",side=3},slot=slot,stack=s},w.c.alvearies[1].storage,j.id)
  end
  w.state.transactions={}
  w.scheduler:step(); eq(j.state,"DONE",require("lib.ui.status").render(w.state,w.c,true))
end)
test("a proven partial Interface return records only accepted units",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w.inventories.a[8]=s
  local transfer=w.proxies.tp1.transferItem
  w.proxies.tp1.transferItem=function(from,to,count,src,dst) return transfer(from,to,math.min(3,count),src,dst) end
  raises(function() w.storage:deposit({endpoint={id="breeder/a",transposer="tp1",side=3},slot=8,stack=s},w.c.alvearies[1].storage,"job") end,"uncertain")
  eq(w.inventories.a[8].size,5); ok(w.inv:reconcile())
  eq(w.state.meBatches["receipt/1"].count,3); eq(w.state.transactions[1].phase,"PARTIAL_RECOVERED")
  w.proxies.tp1.transferItem=transfer; w:tick()
  w.storage:deposit({endpoint={id="breeder/a",transposer="tp1",side=3},slot=8,stack=w.inventories.a[8]},w.c.alvearies[1].storage,"job")
  eq(B.count(w.storage:scan(),"Spirit","drone",true),8)
end)
test("partial scanner acceptance resumes the accepted batch and later scans the remainder",function()
  local w=ME.new(); w:addStock(ME.bee("Spirit","drone",8,true))
  local transfer=w.proxies["tp-scan"].transferItem
  w.proxies["tp-scan"].transferItem=function(from,to,count,src,dst) return transfer(from,to,math.min(3,count),src,dst) end
  raises(function() w.scanner:step(w.storage:scan()) end,"uncertain")
  w.proxies["tp-scan"].transferItem=transfer
  w.scheduler:recover(); eq(w.state.scan.count,3); ok(w.state.scan.inserted)
  for _=1,8 do
    local ready=w.scheduler:prepareStock(w.storage:scan())
    if ready then break end
    if w.inventories.analyser[1] then w:finishScan() end
  end
  eq(w.state.stockPhase,"READY"); eq(B.count(w.storage:scan(),"Spirit","drone",true),8)
end)
test("rejected Interface movement reconciles zero accepted units without spending stock",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  local p=w.storage:materialize(select(w,s),w.c.alvearies[1].storage,"job",1); w.failTransfer=true
  raises(function() w.inv:move(p,{id="destination",transposer="tp1",side=3},10,1,"job") end,"uncertain")
  ok(w.inv:reconcile()); eq(w.state.pending,nil); eq(w.state.meRequests["port1:2"].consumed,nil)
  eq(w.inventories.port1[2].size,1); eq(w.inventories.a[10],nil)
end)
test("an unset failed stock intent can retry configuration without replaying a transfer",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s); w.failConfig=true
  raises(function() w.storage:materialize(select(w,s),w.c.alvearies[1].storage,"job",1) end,"configuration failed")
  eq(w.state.meRequests["port1:2"].phase,"INTENT"); eq(w.moves,0)
  w.failConfig=false; local p=w.storage:materialize(select(w,s),w.c.alvearies[1].storage,"job",1)
  eq(p.stack.size,1); eq(w.moves,0); eq(w.cells[B.identity(s)].size,7)
end)

test("partial scanner deposits recover remaining output and convert ownership once",function()
  local w=ME.new(); local s=ME.bee("Spirit","drone",8,true); w.inventories.a[8]=s
  w.storage:deposit({endpoint={id="a",transposer="tp1",side=3},slot=8,stack=s},w.c.alvearies[1].storage,"job")
  w.scanner:step(w.storage:scan()); w:finishScan()
  local proxy=w.proxies["tp-scan"]; local transfer=proxy.transferItem
  proxy.transferItem=function(from,to,count,src,dst) return transfer(from,to,math.min(3,count),src,dst) end
  raises(function() w.scanner:step({}) end,"uncertain")
  proxy.transferItem=transfer; w.scheduler:recover()
  eq(w.state.scan.returnedCount,3); ok(not w.state.scan.returned)
  w.scanner:step({}); eq(w.state.scan,nil)
  local count=0; for _,i in ipairs(w.storage:scan()) do eq(i.owner,"job"); ok(B.scanned(i.stack)); count=count+i.stack.size end
  eq(count,8)
end)

test("scanner restart before output transfer resumes its saved verification",function()
  local w=bufferedScanner(); w.scanner:step(w.storage:scan()); w:finishScan()
  local save=w.inv.save; local saved
  w.inv.save=function()
    save()
    if w.state.scan and w.state.scan.phase=="RETURNING" and w.state.pending and w.state.pending.phase=="INTENT" then
      saved=U.copy(w.state); error("output power cut")
    end
  end
  raises(function() w.scanner:step({}) end,"output power cut")
  eq(w.moves,1); eq(saved.scan.outputSlot,1); ok(B.scanned(saved.scan.result))
  w.inv.save=save
  for key in pairs(w.state) do w.state[key]=nil end
  for key,value in pairs(saved) do w.state[key]=value end
  w.scheduler:recover(); w.scanner:step({})
  eq(w.moves,2); eq(w.state.scan,nil)
end)

test("combined scanner insertion intent retains source data and never replays an ambiguous transfer",function()
  local w=bufferedScanner(); local save=w.inv.save; local saved
  w.inv.save=function()
    save()
    if w.state.scan and w.state.scan.phase=="INSERTING" and w.state.pending and w.state.pending.phase=="INTENT" then
      saved=U.copy(w.state); error("input intent power cut")
    end
  end
  raises(function() w.scanner:step(w.storage:scan()) end,"input intent power cut")
  eq(w.moves,0); eq(saved.scan.source.endpoint.id,"scan-port"); eq(saved.scan.inputSlot,1)
  eq(saved.meRequests["scan-port:2"].phase,"READY")
  w.inv.save=save
  for key in pairs(w.state) do w.state[key]=nil end
  for key,value in pairs(saved) do w.state[key]=value end
  -- An Interface can refill after extraction while the analyser consumes input.
  -- The original recovery rule therefore needs a returned count before retry.
  raises(function() w.scheduler:recover() end,"Ambiguous Interface movement")
  eq(w.moves,0); eq(w.state.scan.phase,"INSERTING"); eq(w.state.pending.phase,"INTENT")
end)
