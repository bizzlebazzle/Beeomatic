local ME=require("tests.mocks.me"); local B=require("lib.bees"); local U=require("lib.util")
local function select(w,s)
  return {network=true,endpoint={id="ME"},slot=B.identity(s),stack=U.copy(s)}
end
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
