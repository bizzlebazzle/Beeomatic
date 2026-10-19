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
