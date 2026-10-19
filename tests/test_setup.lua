local W=require("tests.mocks.world"); local U=require("lib.util")
local tpMethods={"getInventorySize","getStackInSlot","transferItem"}
local function picker(w,answers)
  local output,snapshots={},{}; local n=0
  local wizard=require("lib.setup").new(w.c,w.components,w.inv,
    function() snapshots[#snapshots+1]=U.copy(w.c) end,
    function()
      n=n+1; local answer=answers[n]
      if type(answer)=="function" then return answer() end
      return answer
    end,function(s) output[#output+1]=s end)
  return wizard,output,snapshots
end

test("component picker filters capabilities and persists friendly names across reloads",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build()
  local wizard,out,saved=picker(w,{"2","Second transposer"})
  eq(wizard:address("Transposer",tpMethods),"tp2")
  eq(saved[1].componentNames.tp2.name,"Second transposer")
  local text=table.concat(out,"\n")
  ok(text:find("Unnamed",1,true)); ok(text:find("tp1",1,true))
  ok(not text:find("housing1",1,true)); eq(w.moves,0)
  w.c=assert(load("return "..U.encode(saved[1]),"=saved config","t",{}))()
  local again,display,changes=picker(w,{""})
  eq(again:address("Transposer",tpMethods,"tp2"),"tp2")
  ok(table.concat(display,"\n"):find("Second transposer",1,true)); eq(#changes,0)
end)

test("component picker retries invalid input and refresh discovers newly available hardware",function()
  local w=W.new(); w:build()
  local wizard,out=picker(w,{"bogus",function()
    w:addTransposer("tp-new",{[0]="hub"}); return "r"
  end,"1","Archive hub"})
  eq(wizard:address("Transposer",tpMethods),"tp-new")
  local text=table.concat(out,"\n")
  ok(text:find("No compatible components",1,true)); ok(text:find("Choose a listed number",1,true))
end)

test("connect new lists only new compatible components and requires selection",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local wizard,out=picker(w,{"n",function()
    w:addTransposer("tp2",{[0]="hub"}); w:addTransposer("tp3",{[0]="hub"}); return ""
  end,"2","New third transposer"})
  eq(wizard:address("Transposer",tpMethods),"tp3")
  local text=table.concat(out,"\n"); local _,start=text:find("Connect the new component",1,true)
  ok(start); ok(not text:sub(start+1):find("tp1",1,true))
  eq(w.c.componentNames.tp1,nil); eq(w.c.componentNames.tp2,nil)
end)

test("component picker paginates and retains stable selection numbers",function()
  local w=W.new(); for i=1,5 do w:addTransposer("tp"..i,{[0]="hub"}) end; w:build()
  local wizard,out=picker(w,{">","<",">",">","5","Last"})
  eq(wizard:address("Transposer",tpMethods),"tp5")
  local text=table.concat(out,"\n"); ok(text:find("page 3/3",1,true))
  local first=text:match("^(.-)R refresh"); ok(not first:find("tp3",1,true))
end)

test("component picker tolerates unavailable saved address and interruption preserves names",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.componentNames=nil
  local wizard=picker(w,{"1","Archive hub"})
  eq(wizard:address("Transposer",tpMethods,"missing-address"),"tp1")
  raises(function() wizard:address("Housing",{"getQueen"}) end,"Setup interrupted")
  eq(w.c.componentNames.tp1.name,"Archive hub")
end)

test("inventory preview is bounded read-only and tolerates failing inventory reads",function()
  local w=W.new(); w:addMachine("a"); w:build()
  for slot=1,10 do w.inventories.hub[slot]={label="Marker "..slot,name="test",size=1} end
  local text=table.concat(w.components:inventorySummary("tp1"),"\n")
  ok(text:find("down (0): 100 slots",1,true)); ok(text:find("Marker 1",1,true))
  ok(text:find("Marker 2",1,true)); ok(not text:find("Marker 3",1,true))
  w.proxies.tp1.getStackInSlot=function() error("unloaded") end
  text=table.concat(w.components:inventorySummary("tp1"),"\n")
  ok(text:find("contents unavailable",1,true)); eq(w.moves,0)
end)

test("normal setup does not dump diagnostic method documentation",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.setupStep=5
  w.components.api.doc=function() error("setup must not request method documentation") end
  local wizard,out=picker(w,{})
  wizard:run(false)
  ok(#out<5); ok(table.concat(out,"\n"):find("Configuration saved",1,true))
end)

test("setup checkpoint persists completed sections",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.setupStep=3
  local answers={"no","no","no"}; local n=0; local snapshots={}
  local wizard=require("lib.setup").new(w.c,w.components,w.inv,function() snapshots[#snapshots+1]=U.copy(w.c) end,
    function() n=n+1; return answers[n] end,function() end)
  wizard:run(false); eq(w.c.setupStep,5); ok(#snapshots>=3); eq(snapshots[#snapshots].scanner.enabled,false)
end)
test("configuration rejects duplicated machine identity",function()
  local w=W.new(); w:addMachine("a"); local copy=U.copy(w.c.alvearies[1]); copy.id="other"; w.c.alvearies[2]=copy
  raises(function() require("lib.config").validate(w.c) end,"duplicate bee housing")
end)
test("probe inspects all component addresses and side views",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build(); local out={}
  require("lib.ui.diagnostics").probe(w.components,function(s) out[#out+1]=s end)
  local text=table.concat(out,"\n"); ok(text:find("tp1",1,true)); ok(text:find("tp2",1,true)); ok(text:find("side 3",1,true))
end)
test("component validation accepts callable tables and indirect method metadata",function()
  local w=W.new(); w:addMachine("a"); w:build()
  eq(type(w.proxies.tp1.getInventorySize),"table")
  eq(w.components.api.methods("tp1").getInventorySize,false)
  local p=w.components:proxy("tp1",{"getInventorySize"})
  eq(p.getInventorySize(0),100)
end)
test("component validation still rejects absent methods",function()
  local w=W.new(); w:addMachine("a"); w:build()
  raises(function() w.components:proxy("tp1",{"notAnInventoryMethod"}) end,"missing method notAnInventoryMethod")
end)
