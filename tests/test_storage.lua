local W=require("tests.mocks.world"); local B=require("lib.bees"); local U=require("lib.util")
local function world()
  local w=W.new(); w:addMachine("a"); w:build(); w.inventories.hub[1]=W.bee("Forest","drone",8); return w
end
test("verified transfer records exact receipt",function()
  local w=world(); local item=w.storage:scan()[1]; local dest={id="a",transposer="tp1",side=3}
  w.inv:move(item,dest,10,2,"job"); eq(w.inventories.hub[1].size,6); eq(w.inventories.a[10].size,2)
  eq(w.state.pending,nil); eq(w.state.transactions[1].phase,"COMMITTED")
end)
test("failed transfer never assumed successful",function()
  local w=world(); w.failTransfer=true
  raises(function() w.inv:move(w.storage:scan()[1],{id="a",transposer="tp1",side=3},10,1,"job") end,"uncertain")
  eq(w.inventories.hub[1].size,8); ok(w.state.pending); ok(w.inv:reconcile()); eq(w.state.pending,nil)
end)
test("full output inventory preserves source",function()
  local w=world(); for i=1,100 do w.inventories.hub[i]=W.bee("Forest","drone",64) end
  w.inventories.a[6]=W.bee("Spirit","princess")
  raises(function() w.scheduler:backend("a"):collectResults(w.storage,"j") end,"full")
  ok(w.inventories.a[6]); eq(w.moves,0)
end)
test("exclusive item lease prevents double allocation",function()
  local w=world(); local i=w.storage:scan()[1]; w.inv:reserve(i,"first")
  raises(function() w.inv:reserve(i,"second") end,"already reserved")
end)
test("NBT identities differ despite same visible species",function()
  local a=W.bee("Spirit","drone"); local b=U.copy(a); a.tag="tag1"; b.tag="tag2"
  ok(B.identity(a)~=B.identity(b))
end)
test("AE2 tag filter uses Java signed byte string",function()
  eq(require("lib.storage.ae2").tagFilter(string.char(31,139,255,0)),"31-117-10")
end)
local function aeWorld(fail)
  local w=world(); w:inventory("buffer",10); w:addTransposer("tp1",{[0]="hub",[3]="a",[1]="buffer"})
  local sample=W.bee("Spirit","drone",8); sample.tag="opaque-nbt"; local raw=U.copy(sample); raw.individual=nil
  local network={raw}; local db,selected
  local AE=require("lib.storage.ae2")
  w.proxies.me={getItemsInNetwork=function(filter)
    if not filter then return U.copy(network) end
    if filter.name==raw.name then return U.copy(network) end; return {}
  end,store=function(filter) if filter.name~=raw.name then return false end; db=U.copy(raw); return true end}
  w.proxies.db={clear=function() db=nil end,get=function() return U.copy(db) end}
  w.proxies.bus={setExportConfiguration=function(_,_,address) selected=address and db or nil; return true end,
    exportIntoSlot=function(_,slot)
      if fail then return false end
      if not selected then return false end
      w.inventories.buffer[slot]=U.copy(sample); network={}; return true
    end}
  local cfg={address="me",database="db",exportAddress="bus",exportSide=4,storageBusVerified=true,exportIsolated=true,
    endpoints=w.c.storage.endpoints,buffer={id="buffer",transposer="tp1",side=1}}
  w.ae=AE.new(cfg,w.inv,w.components); return w,raw
end
test("AE2 exact export hydrates real physical genetics",function()
  local w,raw=aeWorld(false)
  local item={network=true,endpoint={id="ME"},slot=B.identity(raw),stack=raw}
  local p=w.ae:materialize(item,w.c.storage.endpoints[1],"j")
  ok(B.scanned(p.stack)); eq(p.stack.tag,"opaque-nbt"); eq(w.state.pendingExternal,nil)
end)
test("AE2 export failure leaves journal for reconciliation",function()
  local w,raw=aeWorld(true)
  raises(function() w.ae:materialize({network=true,endpoint={id="ME"},slot="x",stack=raw},w.c.storage.endpoints[1],"j") end,"export failed")
  ok(w.state.pendingExternal); local yes=w.ae:reconcile(); ok(not yes)
end)
test("AE2 missing exact NBT refuses selection",function()
  local w,raw=aeWorld(false); raw.tag=nil
  raises(function() w.ae:materialize({network=true,endpoint={id="ME"},slot="x",stack=raw},w.c.storage.endpoints[1],"j") end,"compressed NBT")
  eq(w.moves,0)
end)
