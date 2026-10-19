local W=require("tests.mocks.world"); local B=require("lib.bees"); local U=require("lib.util")
local function world()
  local w=W.new(); w:addMachine("a"); w:build(); w.inventories.hub[1]=W.bee("Forest","drone",8); return w
end

test("bulk inventory scan preserves empty slots and avoids per-slot world calls",function()
  local w=world(); w.inventories.hub[1]=nil; w.inventories.hub[87]=W.bee("Forest","drone",8)
  local ep=w.c.storage.endpoints[1]; local p=w.proxies[ep.transposer]
  local bulk=p.getAllStacks; local calls=0
  p.getAllStacks=function(side) calls=calls+1; return bulk(side) end
  p.getInventorySize=function() error("bulk scan should not query size separately") end
  p.getStackInSlot=function() error("bulk scan should not read individual slots") end
  local items=w.inv:scan(ep)
  eq(calls,1); eq(#items,1); eq(items[1].slot,87); eq(items[1].stack.size,8)
end)

test("inventory scan fallback validates size once and keeps physical slot numbers",function()
  local w=world(); w.inventories.hub[87]=W.bee("Meadows","princess")
  local ep=w.c.storage.endpoints[1]; local p=w.proxies[ep.transposer]; p.getAllStacks=nil
  local size,read=p.getInventorySize,p.getStackInSlot; local sizes,reads=0,0
  p.getInventorySize=function(side) sizes=sizes+1; return size(side) end
  p.getStackInSlot=function(side,slot) reads=reads+1; return read(side,slot) end
  local items=w.inv:scan(ep)
  eq(sizes,1); eq(reads,100); eq(#items,2); eq(items[2].slot,87)
end)

test("bulk inventory read failures do not masquerade as empty inventories",function()
  local w=world(); local ep=w.c.storage.endpoints[1]
  w.proxies[ep.transposer].getAllStacks=function() return nil,"inventory offline" end
  raises(function() w.inv:scan(ep) end,"inventory offline")
end)
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
test("AE2 selects the second same-label genetic variant by exact database NBT",function()
  local w=world(); w:inventory("buffer",10); w:addTransposer("tp1",{[0]="hub",[3]="a",[1]="buffer"})
  local a=W.bee("Spirit","drone",8,"Aware"); a.tag="wrong-nbt"
  local b=W.bee("Spirit","drone",8,"Ethereal"); b.tag="right-nbt"
  local db,selected={},nil
  w.proxies.me={getItemsInNetwork=function() return {U.copy(a),U.copy(b)} end,
    store=function(_,_,_,n) eq(n,2); db={U.copy(a),U.copy(b)}; return true end}
  w.proxies.db={clear=function(n) db[n]=nil end,get=function(n) return U.copy(db[n]) end}
  w.proxies.bus={setExportConfiguration=function(_,_,address,slot) selected=address and slot or nil; return true end,
    exportIntoSlot=function(_,slot) eq(selected,2); w.inventories.buffer[slot]=U.copy(db[selected]); return true end}
  local s=require("lib.storage.ae2").new({address="me",database="db",databaseSlots=2,exportAddress="bus",exportSide=4,
    storageBusVerified=true,exportIsolated=true,endpoints=w.c.storage.endpoints,buffer={id="buffer",transposer="tp1",side=1}},w.inv,w.components)
  local got=s:materialize({network=true,endpoint={id="ME"},slot="chosen",stack=b},w.c.storage.endpoints[1],"j")
  eq(got.stack.tag,"right-nbt"); eq(got.stack.individual.inactive.species.name,"Ethereal")
end)
test("shared archive falls back to another registered transposer view",function()
  local w=world(); w:addMachine("b"); w.proxies.tp1=nil
  eq(#w.storage:scan(),1)
end)
test("AE2 config-null callback failure preserves detail and clears the filter",function()
  local w,raw=aeWorld(false); local cleared=false
  local set=w.proxies.bus.setExportConfiguration
  w.proxies.bus.setExportConfiguration=function(side,slot,address,...)
    if not address then cleared=true end; return set(side,slot,address,...)
  end
  w.proxies.bus.exportIntoSlot=function() return nil,'Cannot invoke inventory method because "config" is null' end
  raises(function() w.ae:materialize({network=true,endpoint={id="ME"},slot="x",stack=raw},w.c.storage.endpoints[1],"j") end,
    "known GTNH exportIntoSlot config=null incompatibility")
  ok(cleared); ok(w.state.pendingExternal.lastError:find('"config" is null',1,true))
  ok(w.state.pendingExternal.compatibilityIssue); eq(w.inventories.buffer[1],nil)
end)
test("AE2 preserves secondary return errors from non-throwing callbacks",function()
  local w,raw=aeWorld(false)
  w.proxies.bus.exportIntoSlot=function() return nil,"no inventory" end
  raises(function() w.ae:materialize({network=true,endpoint={id="ME"},slot="x",stack=raw},w.c.storage.endpoints[1],"j") end,"no inventory")
  eq(w.state.pendingExternal.lastError,"no inventory"); eq(w.state.pendingExternal.compatibilityIssue,nil)
end)
local function redstoneWorld(options)
  options=options or {}
  local w,raw=aeWorld(false); local sample=W.bee("Spirit","drone",8); sample.tag=raw.tag
  local cfg=w.ae.config; cfg.exportMode="redstone"; cfg.exportTimeout=options.timeout or 60; cfg.exportPollSeconds=1
  cfg.exportGate={address="redstone",side=2,on=15,off=0,verified=true}
  local signal,configured=0,nil; w.polls=0; w.callbackCalls=0
  local current=W.bee("Spirit","drone",8); current.tag=raw.tag; current.individual=nil
  local entry
  w.proxies.me.store=function() entry=U.copy(current); return true end
  w.proxies.db.get=function() return U.copy(entry) end
  w.proxies.me.getItemsInNetwork=function()
    local result={}
    if current.size>0 then result[#result+1]=U.copy(current) end
    -- The archive is exposed by the configured ME storage bus.
    for _,s in pairs(w.inventories.hub) do if type(s)=="table" and s.tag==raw.tag then result[#result+1]=U.copy(s) end end
    return result
  end
  w.proxies.bus.setExportConfiguration=function(_,_,db)
    if not db and options.cleanupFails then return nil,"filter clear failed" end
    configured=db and U.copy(entry) or nil; return true
  end
  w.proxies.bus.getExportConfiguration=function() return U.copy(configured) end
  w.proxies.bus.getExportSlotSize=function() return 1 end
  w.proxies.bus.exportIntoSlot=function() w.callbackCalls=w.callbackCalls+1; error("callback must not be used") end
  w.proxies.redstone={getOutput=function() return signal end,setOutput=function(_,n)
    local old=signal; signal=n
    if n==15 then ok(w.state.pendingExternal,"journal intent must precede gate enable") end
    return old
  end}
  local wait=function(seconds)
    w.polls=w.polls+1; w.time=w.time+seconds
    if options.interruptAt and w.polls==options.interruptAt then error("interrupted") end
    if signal==15 and configured and w.polls>=(options.delay or 5) and not options.noReceipt and current.size>0 then
      local stack=U.copy(sample); stack.size=options.multiple and 4 or 8
      if options.wrongNBT then stack.tag="wrong-genotype" end
      w.inventories.buffer[options.receiptSlot or 1]=stack
      if options.multiple then w.inventories.buffer[2]=U.copy(stack) end
      current.size=0
    end
  end
  w.ae=require("lib.storage.ae2").new(cfg,w.inv,w.components,{now=function() return w.time end,wait=wait})
  function w:signal() return signal end
  function w:configured() return configured end
  function w:restoreReceipt(slot) w.inventories.buffer[slot or 1]=U.copy(sample); current.size=0 end
  return w,raw
end
local function materialize(w,raw)
  return w.ae:materialize({network=true,endpoint={id="ME"},slot=B.identity(raw),stack=raw},w.c.storage.endpoints[1],"j")
end
test("redstone export waits through slow bus startup and verifies the receipt",function()
  local w,raw=redstoneWorld({delay=15}); local got=materialize(w,raw)
  eq(w.polls,15); eq(got.stack.tag,raw.tag); eq(w:signal(),0); eq(w:configured(),nil)
  eq(w.callbackCalls,0); eq(w.state.pendingExternal,nil); eq(w.state.lastExternalExport.phase,"ARCHIVED")
end)
test("redstone export inspects all buffer slots instead of assuming slot one",function()
  local w,raw=redstoneWorld({receiptSlot=7}); local got=materialize(w,raw)
  eq(got.stack.tag,raw.tag); eq(#w.inv:scan(w.ae.config.buffer),0)
end)
test("redstone export archives every exact receipt when the bus sends multiple stacks",function()
  local w,raw=redstoneWorld({multiple=true}); materialize(w,raw)
  eq(B.count(w.storage:scan(),"spirit","drone",true),8); eq(w.state.lastExternalExport.archivedCount,8)
  eq(#w.inv:scan(w.ae.config.buffer),0)
end)
test("redstone export timeout disables signal and clears the filter",function()
  local w,raw=redstoneWorld({noReceipt=true,timeout=3})
  raises(function() materialize(w,raw) end,"timeout waiting for receipt")
  eq(w.time,3); eq(w:signal(),0); eq(w:configured(),nil); ok(w.state.pendingExternal)
  ok(w.ae:reconcile()); eq(w.state.pendingExternal,nil); eq(w.state.lastExternalExport.phase,"NO_MOVEMENT_CONFIRMED")
end)
test("redstone export interruption shuts down before propagating the error",function()
  local w,raw=redstoneWorld({interruptAt=2})
  raises(function() materialize(w,raw) end,"interrupted")
  eq(w:signal(),0); eq(w:configured(),nil); ok(w.state.pendingExternal)
end)
test("redstone export rejects a wrong-NBT receipt and preserves it for audit",function()
  local w,raw=redstoneWorld({wrongNBT=true})
  raises(function() materialize(w,raw) end,"wrong-NBT")
  eq(w:signal(),0); eq(w:configured(),nil); eq(w.inventories.buffer[1].tag,"wrong-genotype")
  ok(w.state.pendingExternal)
end)
test("redstone recovery archives a late receipt without issuing another export",function()
  local w,raw=redstoneWorld({noReceipt=true,timeout=2})
  raises(function() materialize(w,raw) end,"timeout")
  w:restoreReceipt(); local polls=w.polls
  ok(w.ae:reconcile()); eq(w.polls,polls); eq(w.callbackCalls,0); eq(w:signal(),0)
  eq(#w.inv:scan(w.ae.config.buffer),0); eq(B.count(w.storage:scan(),"spirit","drone",true),8)
end)
test("redstone export requires an entirely empty isolated buffer",function()
  local w,raw=redstoneWorld(); w.inventories.buffer[5]=W.bee("Forest","drone")
  raises(function() materialize(w,raw) end,"completely empty")
  eq(w.polls,0); eq(w:signal(),0)
end)
test("redstone filter cleanup failure leaves recoverable export state",function()
  local w,raw=redstoneWorld({cleanupFails=true})
  raises(function() materialize(w,raw) end,"filter clear failed")
  eq(w:signal(),0); ok(w.state.pendingExternal); ok(w.inventories.buffer[1])
end)
test("redstone restart after archive movement reconciles without a second withdrawal",function()
  local w,raw=redstoneWorld(); w.throwAfterMove=true
  raises(function() materialize(w,raw) end,"transfer uncertain")
  eq(w:signal(),0); ok(w.state.pendingExternal); ok(w.state.pending)
  local moves=w.moves; ok(w.inv:reconcile()); w.throwAfterMove=false
  ok(w.ae:reconcile()); eq(w.moves,moves); eq(w.state.pendingExternal,nil)
  eq(w.state.lastExternalExport.phase,"ARCHIVED_RECOVERED")
  eq(w.state.lastExternalExport.archivedCount,8)
  eq(B.count(w.storage:scan(),"spirit","drone",true),8)
end)
test("redstone source-count mismatch retains buffer stock for reconciliation",function()
  local w,raw=redstoneWorld()
  w.proxies.me.getItemsInNetwork=function() return {U.copy(raw)} end
  raises(function() materialize(w,raw) end,"source delta disagrees")
  eq(w:signal(),0); eq(w:configured(),nil); ok(w.state.pendingExternal)
  eq(w.inventories.buffer[1].size,8); eq(B.count(w.storage:scan(),"spirit","drone",true),0)
end)
test("redstone export rejects another configured filter before enabling",function()
  local w,raw=redstoneWorld(); w.proxies.bus.getExportSlotSize=function() return 5 end
  w.proxies.bus.getExportConfiguration=function(_,slot) if slot==2 then return W.bee("Forest","drone") end end
  raises(function() materialize(w,raw) end,"clear all existing export filters")
  eq(w.polls,0); eq(w:signal(),0); eq(w.callbackCalls,0)
end)
