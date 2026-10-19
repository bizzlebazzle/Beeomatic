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
