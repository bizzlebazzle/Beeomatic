local ME=require("tests.mocks.me"); local B=require("lib.bees"); local U=require("lib.util")
local function select(w,s)
  return {network=true,endpoint={id="ME"},slot=B.identity(s),stack=U.copy(s)}
end

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
local function externalScanner()
  local w=ME.new(); local c=w.c.scanner
  c.mode="external"; c.output=nil; c.outputSlots=nil; c.inputSlot=nil; c.isolatedVerified=nil
  function w:returnExternal(count,species,raw)
    local source=assert(self.inventories.analyser[1],"no external input")
    count=count or source.size
    self:addStock(ME.bee(species or source.label:match("^(.-) %w+$"),B.kind(source),count,raw))
    source.size=source.size-count; if source.size==0 then self.inventories.analyser[1]=nil end
  end
  return w
end

test("external scanner uses one chest transfer and verifies automatic AE returns",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.storage:validate(); w.scanner:validate(); require("lib.config").validate(w.c)
  eq(w.scheduler:prepareStock(w.storage:scan()),false); eq(w.moves,1)
  eq(w.state.scan.inputSlot,1); w:returnExternal()
  eq(w.scheduler:prepareStock(w.storage:scan()),false)
  eq(w.moves,1); eq(w.state.scan,nil); eq(next(w.state.meRequests),nil)
  ok(w.scheduler:prepareStock(w.storage:scan())); eq(w.state.stockPhase,"READY")
end)

test("external scanner baseline excludes unrelated castes and releases it after return detection",function()
  local w=externalScanner(); local raw=ME.bee("Spirit","drone",8,true)
  w:addStock(raw); w:addStock(ME.bee("Forest","princess")); w:addStock(ME.bee("Forest","queen"))
  w.scanner:step(w.storage:scan())
  local count=0; for _ in pairs(w.state.scan.before) do count=count+1 end
  eq(count,1); eq(w.state.scan.before[B.identity(raw)],8)
  w:returnExternal()
  local materialize=w.storage.materialize
  w.storage.materialize=function(self,item,...)
    if w.state.scan.phase=="VERIFYING" then eq(w.state.scan.before,nil) end
    return materialize(self,item,...)
  end
  w.scanner:step({}); eq(w.state.scan,nil)
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

test("external scanner drains every initial drone across multiple batches",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",130,true)); local count=0
  for _=1,12 do
    if w.scheduler:prepareStock(w.storage:scan()) then break end
    if w.inventories.analyser[1] then count=count+w.inventories.analyser[1].size; w:returnExternal() end
  end
  eq(count,130); eq(w.moves,3); eq(w.state.stockPhase,"READY")
  eq(B.count(w.storage:scan(),"Spirit","drone",true),130)
end)

test("external returns preserve ownership when merging with existing analysed stock",function()
  local w=externalScanner(); local s=ME.bee("Spirit","drone",8,true); w.inventories.a[8]=s
  local receipt=w.storage:deposit({endpoint={id="a",transposer="tp1",side=3},slot=8,stack=s},w.c.alvearies[1].storage,"job")
  w:addStock(ME.bee("Spirit","drone",12)); w.c.scanner.batchSize=3
  for _=1,12 do
    if w.scanner:step(w.storage:scan()) then break end
    if w.inventories.analyser[1] then w:returnExternal() end
  end
  local owned,free=0,0
  for _,item in ipairs(w.storage:scan()) do
    ok(B.scanned(item.stack))
    if item.owner then eq(item.owner,"job"); eq(item.root,receipt.root); owned=owned+item.stack.size
    else free=free+item.stack.size end
  end
  eq(owned,8); eq(free,12)
end)

test("external scanner waits for all units of a split return and preserves timeout progress",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); w:returnExternal(3)
  eq(w.scanner:step(w.storage:scan()),false); eq(w.state.scan.phase,"PROCESSING")
  w.time=601
  raises(function() w.scanner:step(w.storage:scan()) end,"batch preserved")
  eq(w.state.scan.count,8); w.scheduler:recover(); w:returnExternal()
  w.scanner:step(w.storage:scan()); eq(w.state.scan,nil); eq(w.moves,1)
end)

test("external scanner ignores a wrong-species return without granting readiness",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); w:returnExternal(nil,"Forest")
  eq(w.scanner:step(w.storage:scan()),false)
  eq(w.state.scan.phase,"PROCESSING"); eq(w.state.stockReady,nil)
  w.time=601
  raises(function() w.scanner:step(w.storage:scan()) end,"batch preserved")
end)

test("external scanner refuses ambiguous return variants",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); w:returnExternal()
  w:addStock(ME.bee("Spirit","drone",1,nil,{fertility=4}))
  raises(function() w.scanner:step(w.storage:scan()) end,"multiple possible scanner returns")
  eq(w.state.scan.phase,"PROCESSING")
end)

test("analysed unrelated species cannot compete with the expected scanner return",function()
  local w=externalScanner(); w:addStock(ME.bee("Common","drone",1,true))
  w.scanner:step(w.storage:scan()); w:returnExternal()
  local unrelated=ME.bee("Ocean","drone",32); w:addStock(unrelated)
  w.scanner:step(w.storage:scan()); eq(w.state.scan,nil)
  eq(B.count(w.storage:scan(),"Common","drone",true),1)
  eq(w.cells[B.identity(unrelated)].size,32); eq(next(w.state.meRequests),nil)
end)

test("saved boolean return checks recover owned Common batch despite an Ocean candidate",function()
  local w=externalScanner(); local raw=ME.bee("Common","drone",1,true)
  w.inventories.a[8]=raw
  local receipt=w.storage:deposit({endpoint={id="a",transposer="tp1",side=3},slot=8,stack=raw},
    w.c.alvearies[1].storage,"job1")
  w.scanner:step(w.storage:scan()); w:returnExternal()
  local common=ME.bee("Common","drone",1); local ocean=ME.bee("Ocean","drone",1)
  w:addStock(ocean); w.storage:catalogue(common); w.storage:catalogue(ocean)
  w.state.scan.returnChecks={[B.identity(common)]=true,[B.identity(ocean)]=true}
  w.scheduler:recover(); local moves=w.moves
  w.scanner:step(w.storage:scan()); eq(w.state.scan,nil); eq(w.moves,moves)
  local batch=w.state.meBatches[receipt.batchId]
  eq(batch.owner,"job1"); eq(batch.count,1); eq(batch.identity,B.identity(common))
  eq(w.cells[B.identity(ocean)].size,1); eq(next(w.state.meRequests),nil)
end)

test("unknown source species still requires an audit between different analysed returns",function()
  local w=externalScanner(); w:addStock(ME.bee("Common","drone",1,true))
  w.scanner:step(w.storage:scan()); w:returnExternal(); w.state.scan.ident=nil
  w:addStock(ME.bee("Ocean","drone",1))
  raises(function() w.scanner:step(w.storage:scan()) end,"multiple possible scanner returns")
  eq(w.state.scan.phase,"PROCESSING")
end)

test("new raw bees larger than the scanner batch are queued without becoming returns",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan())
  local added=ME.bee("Forest","drone",32,true); w:addStock(added)
  eq(w.scanner:step(w.storage:scan()),false)
  eq(w.state.scan.phase,"PROCESSING"); eq(w.state.scan.returnChecks[B.identity(added)],false)
  eq(next(w.state.meRequests),nil); eq(w.cells[B.identity(added)].size,32)
  w:returnExternal(); w.scanner:step(w.storage:scan()); eq(w.state.scan,nil)
  -- The ignored variant is still queued, and is analysed by the next batch.
  w.scanner:step(w.storage:scan()); eq(w.state.scan.identity,B.identity(added))
  w:returnExternal(); w.scanner:step(w.storage:scan()); eq(w.state.scan,nil)
  eq(B.count(w.storage:scan(),"Spirit","drone",true),8)
  eq(B.count(w.storage:scan(),"Forest","drone",true),32)
end)

test("new raw genotype of the same species does not contaminate a completed return",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); w:returnExternal()
  local added=ME.bee("Spirit","drone",20,true); added.tag=added.tag.."wild-genotype"
  w:addStock(added); w.scanner:step(w.storage:scan()); eq(w.state.scan,nil)
  eq(w.cells[B.identity(added)].size,20); eq(next(w.state.meRequests),nil)
end)

test("raw additions do not satisfy missing scanner returns or reset their timeout",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); w:addStock(ME.bee("Forest","drone",32,true))
  w.time=601
  raises(function() w.scanner:step(w.storage:scan()) end,"batch preserved")
  eq(w.state.scan.phase,"PROCESSING"); eq(w.state.scan.count,8)
end)

test("analysed excess returns still require an audit",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); w:returnExternal()
  w:addStock(ME.bee("Spirit","drone",1))
  raises(function() w.scanner:step(w.storage:scan()) end,"return count exceeds")
  eq(w.state.scan.phase,"PROCESSING"); eq(next(w.state.meRequests),nil)
end)

test("return candidate inspection resumes after a crash before probe cleanup",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); local added=ME.bee("Forest","drone",32,true); w:addStock(added)
  local save=w.scanner.save; local cut=false
  w.scanner.save=function()
    save()
    if not cut and w.state.scan.returnProbe and w.state.scan.returnProbe.phase=="CLEANUP" then
      cut=true; error("probe power cut")
    end
  end
  raises(function() w.scanner:step(w.storage:scan()) end,"probe power cut")
  w.scanner.save=save; w.scheduler:recover()
  eq(w.scanner:step(w.storage:scan()),false); eq(w.state.scan.returnProbe,nil)
  eq(next(w.state.meRequests),nil); eq(w.cells[B.identity(added)].size,32)
  w:returnExternal(); w.scanner:step(w.storage:scan()); eq(w.state.scan,nil); eq(w.moves,1)
end)

test("external scanner restart after input acceptance never reinserts the batch",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  local save=w.inv.save; local cut=false
  w.inv.save=function()
    save()
    if w.state.scan and w.state.scan.inserted and not cut then cut=true; error("input power cut") end
  end
  raises(function() w.scanner:step(w.storage:scan()) end,"input power cut")
  w.inv.save=save; w:returnExternal(); w.scheduler:recover()
  w.scanner:step(w.storage:scan()); w.scanner:step(w.storage:scan())
  eq(w.moves,1); eq(w.state.scan,nil)
end)

test("external scanner restart after ownership conversion never converts twice",function()
  local w=externalScanner(); local s=ME.bee("Spirit","drone",8,true); w.inventories.a[8]=s
  local receipt=w.storage:deposit({endpoint={id="a",transposer="tp1",side=3},slot=8,stack=s},w.c.alvearies[1].storage,"job")
  w.scanner:step(w.storage:scan()); w:returnExternal()
  local save=w.scanner.save; local cut=false
  w.scanner.save=function()
    save()
    if w.state.scan and w.state.scan.phase=="EXTERNAL_RETURNED" and not cut then cut=true; error("return power cut") end
  end
  raises(function() w.scanner:step(w.storage:scan()) end,"return power cut")
  w.scanner.save=save; w.scheduler:recover(); w.scanner:step(w.storage:scan())
  eq(w.state.scan,nil); eq(w.state.meBatches[receipt.batchId].count,8)
  eq(w.moves,2); eq(next(w.state.meRequests),nil)
end)

test("external input may be extracted and returned immediately during transfer",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.afterTransfer=function() w:returnExternal(); w:tick() end
  w.scanner:step(w.storage:scan()); w.scanner:step(w.storage:scan())
  eq(w.moves,1); eq(w.state.scan,nil); eq(w.state.pending,nil)
  eq(B.count(w.storage:scan(),"Spirit","drone",true),8)
end)

test("external return inspection resumes its exact request after restart",function()
  local w=externalScanner(); w:addStock(ME.bee("Spirit","drone",8,true))
  w.scanner:step(w.storage:scan()); w:returnExternal()
  local save=w.inv.save; local cut=false
  w.inv.save=function()
    save()
    if w.state.scan and w.state.scan.phase=="VERIFYING" then
      local request=w.state.meRequests["scan-port:2"]
      if request and request.phase=="READY" and not cut then cut=true; error("inspection power cut") end
    end
  end
  raises(function() w.scanner:step(w.storage:scan()) end,"inspection power cut")
  w.inv.save=save; w.scheduler:recover(); w.scanner:step(w.storage:scan())
  eq(w.moves,1); eq(w.state.scan,nil); eq(next(w.state.meRequests),nil)
end)

test("external chest slot is chosen automatically around unrelated non-bee contents",function()
  local w=externalScanner(); w.inventories.analyser[1]={name="marker",size=1}
  w:addStock(ME.bee("Spirit","drone",8,true))
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
  local w=externalScanner(); w.hideGenomes=false; w.c.minDrones=2; w.c.confirmCycles=1
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8))
  local j=require("tests.mocks.world").job(w,"job","Spirit","populate")
  w.scheduler:step(); eq(j.state,"RUNNING"); local machine=j.machine
  w:addStock(ME.bee("Forest","drone",3,true)); w.scheduler:step()
  eq(j.state,"RUNNING"); eq(w.state.scan.phase,"PROCESSING"); eq(w.state.stockPhase,"SCANNING")
  w:addStock(ME.bee("Meadows","drone",32,true)); w.scheduler:step()
  eq(j.state,"RUNNING"); eq(w.state.error,"Waiting for analysed bees to return through ME")
  w:finish(machine,ME.bee("Spirit","princess"),ME.bee("Spirit","drone",4,true))
  w.scheduler:step(); eq(j.state,"ASSESSING"); eq(w.state.pending,nil)
  for _=1,20 do
    if w.inventories.analyser[1] then w:returnExternal() end
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
