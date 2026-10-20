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

test("setup headings colour only the heading and restore palette colours after output errors",function()
  local oldPrint,oldTerm=print,package.loaded.term
  local foreground,palette=3,true; local calls={}
  local gpu={getDepth=function() return 8 end,getForeground=function() return foreground,palette end,
    setForeground=function(value,index) foreground,palette=value,index; calls[#calls+1]={value,index} end}
  package.loaded.term={gpu=function() return gpu end}
  local success,err=pcall(function()
    print=function(text) eq(foreground,0x55FFFF); eq(text,"== Components ==") end
    local wizard=require("lib.setup").new({},nil,nil,function() end)
    wizard:heading("Components"); eq(foreground,3); eq(palette,true)
    print=function() error("output interrupted") end; wizard.out=print
    raises(function() wizard:heading("Components") end,"output interrupted")
    eq(foreground,3); eq(palette,true); eq(#calls,4)
  end)
  print=oldPrint; package.loaded.term=oldTerm
  assert(success,err)
end)

test("setup headings remain readable on monochrome and unavailable terminals",function()
  local oldPrint,oldTerm=print,package.loaded.term; local output={}
  local success,err=pcall(function()
    print=function(text) output[#output+1]=text end
    local wizard=require("lib.setup").new({},nil,nil,function() end)
    package.loaded.term={gpu=function() return {getDepth=function() return 1 end,
      setForeground=function() error("must not change monochrome colour") end} end}
    wizard:heading("Mono")
    package.loaded.term={gpu=function() error("no GPU") end}
    wizard:heading("Plain")
    eq(output,{"== Mono ==","== Plain =="})
  end)
  print=oldPrint; package.loaded.term=oldTerm
  assert(success,err)
end)

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

test("endpoint skips a lone named transposer and advances through distinct inventory roles",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.c.componentNames.tp1={name="Bee hub",kind="transposer"}
  local wizard,out=picker(w,{"1","2"})
  local archive=wizard:endpoint("Archive chest")
  local buffer=wizard:endpoint("Second inventory")
  eq(archive,{id="hub",transposer="tp1",side=0})
  eq(buffer,{id="a",transposer="tp1",side=3})
  local text=table.concat(out,"\n")
  ok(text:find("Selected Archive chest:",1,true))
  ok(text:find("Inventory number for Second inventory",1,true))
  ok(not text:find("Component number",1,true))
  ok(not text:find("distinctive item",1,true)); eq(w.moves,0)
end)

test("inventory refresh stays on the target and saved world side maps to a menu number",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.c.componentNames.tp1={name="Bee hub",kind="transposer"}
  local wizard,out=picker(w,{"0","r",""})
  local ep=wizard:endpoint("Alveary inventory",{transposer="tp1",side=3,id="alveary_1"})
  eq(ep.side,3); eq(ep.id,"a")
  local text=table.concat(out,"\n")
  ok(text:find("That inventory number is not listed",1,true))
  ok(text:find("Inventory number for Alveary inventory [2]",1,true))
  eq(w.moves,0)
end)

test("inventory selection can refresh after initially finding no inventories",function()
  local w=W.new(); w:addTransposer("tp1",{}); w:build()
  w.c.componentNames.tp1={name="Bee hub",kind="transposer"}
  local wizard,out=picker(w,{function()
    w:addTransposer("tp1",{[5]="hub"}); return "r"
  end,"1"})
  local ep=wizard:endpoint("Archive chest")
  eq(ep.side,5)
  ok(table.concat(out,"\n"):find("No inventories detected",1,true))
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
test("fresh setup defaults to ME Interfaces without export-bus prompts",function()
  local w=W.new(); w:build(); local wizard,out=picker(w,{"me","9","60","yes"})
  wizard.address=function(_,label) return label:find("database",1,true) and "db" or "me" end
  wizard:storage(); eq(w.c.storage.kind,"me_interface"); eq(w.c.storage.database,"db")
  eq(#w.c.storage.endpoints,0); eq(w.c.storage.exportAddress,nil)
  local text=table.concat(out,"\n"):lower(); ok(not text:find("export bus",1,true)); ok(not text:find("redstone",1,true))
  eq(require("lib.config").defaults().storage.kind,"me_interface")
end)
test("setup binds a local Interface to the known transposer without asking again",function()
  local w=require("tests.mocks.me").new(); local wizard=picker(w,{})
  local ep=w.c.alvearies[1].storage
  wizard.endpoint=function(_,_,default,fixed) eq(fixed,"tp1"); return U.copy(ep) end
  wizard.address=function(_,_,methods) eq(methods,{"getInterfaceConfiguration","setInterfaceConfiguration"}); return "if1" end
  local selected=wizard:port("Local Interface",ep,"tp1"); eq(selected.managed,true); eq(selected.returnSlot,9)
end)
test("scanner setup asks for Interface and both chests and discards old slot settings",function()
  local w=require("tests.mocks.me").new(); local wizard,out=picker(w,{})
  local s=w.c.scanner; w.inventories.analyser[3]={name="honey",size=64}
  wizard.port=function() return s.storage end
  wizard.endpoint=function(_,label,default,fixed) eq(fixed,"tp-scan"); return default end
  wizard:scanner(); eq(s.mode,"buffered"); eq(s.output.side,2); eq(s.outputSlots,nil); eq(s.inputSlot,nil)
  eq(s.isolatedVerified,nil); eq(s.timeout,600)
  eq(w.inventories.analyser[3].size,64); eq(#w.c.storage.endpoints,3)
  local text=table.concat(out,"\n")
  ok(not text:find("Witnessed",1,true)); ok(not text:find("Scanner timeout in seconds",1,true))
  ok(not text:find("Have you tested",1,true))
  require("lib.config").validate(w.c); w.scanner:validate()
end)

test("ME scanner setup completes with five hardware choices and no slot or confirmation answers",function()
  local w=require("tests.mocks.me").new()
  for _,component in ipairs(w.components:discover()) do
    w.c.componentNames[component.address]={name=component.address,kind=component.kind}
  end
  local wizard,out=picker(w,{"1","1","1","2","3"})
  wizard:scanner()
  eq(w.c.scanner.storage.address,"if-scan"); eq(w.c.scanner.input.side,1)
  eq(w.c.scanner.mode,"buffered"); eq(w.c.scanner.output.side,2)
  local text=table.concat(out,"\n")
  ok(not text:find("Witnessed",1,true)); ok(not text:find("Have you tested",1,true))
  w.scanner:validate(); require("lib.config").validate(w.c)
end)
test("setup back returns to the previous section and preserves checkpoints",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.setupStep=3
  local wizard=picker(w,{"back","no"}); local visits={}
  wizard.scanner=function(self)
    visits[#visits+1]="scanner"
    if #visits==1 then self:ask("Go back") end
  end
  wizard.optional=function() visits[#visits+1]="optional" end
  wizard:run(false); eq(visits,{"scanner","scanner","optional"}); eq(w.c.setupStep,5)
end)
test("interrupted alveary registration resumes at saved environment stage",function()
  local w=W.new(); local machine=w:addMachine("a"); table.remove(w.c.alvearies)
  w.c.alvearyDraft={stage=4,machine=machine}; w:build()
  local wizard,out=picker(w,{"NORMAL","NORMAL"})
  wizard.address=function() error("must not repeat hardware selection") end
  wizard:addAlveary(); eq(#w.c.alvearies,1); eq(w.c.alvearyDraft,nil); ok(machine.environment.verified)
  local text=table.concat(out,"\n")
  ok(not text:find("Biome:",1,true)); ok(not text:find("Dimension:",1,true))
  ok(not text:find("Verified flower-provider IDs",1,true)); eq(machine.environment.flowers,nil)
  ok(not text:find("day/night schedule",1,true)); ok(not text:find("protected from rain",1,true))
  ok(not text:find("lighting",1,true)); ok(not text:find("rain shield",1,true))
  eq(machine.environment.daylightManaged,nil); eq(machine.environment.rainProtected,nil)
  ok(not text:find("sky access",1,true)); eq(machine.environment.skyAccess,nil)
  ok(not text:find("Have you verified this operating environment",1,true))
  eq(machine.environment.provenance,"setup-entered climate")
end)
test("pruning removed alvearies retains the shared scanner port",function()
  local w=require("tests.mocks.me").new(); table.remove(w.c.alvearies,1)
  require("lib.config").prunePorts(w.c); eq(#w.c.storage.endpoints,2)
  eq(w.c.storage.endpoints[1].id,"port2"); eq(w.c.storage.endpoints[2].id,"scan-port")
  require("lib.config").validate(w.c)
end)
test("native registration fixes all slots and retries an empty witness without requiring analysis",function()
  local w=W.new(); local a=w:addMachine("a"); table.remove(w.c.alvearies)
  w.inventories.a.size=9
  w.proxies.housing1.getQueen=function() local s=w.inventories.a[1]; return s and U.copy(s.individual) end
  w.proxies.housing1.getDrone=function() local s=w.inventories.a[2]; return s and U.copy(s.individual) end
  w.c.alvearyDraft={stage=3,machine=a}; w:build()
  local function raw(kind)
    local s=W.bee("Spirit",kind); s.individual.active=nil; s.individual.inactive=nil; s.individual.isAnalyzed=false; return s
  end
  local wizard,out=picker(w,{"",function() w.inventories.a[2]=raw("drone"); return "" end,
    function() w.inventories.a[2]=nil; w.inventories.a[1]=raw("princess"); return "" end,
    "NORMAL","NORMAL"})
  wizard:addAlveary()
  eq(a.slots,{inventorySize=9,princess=1,drone=2,outputs={3,4,5,6,7,8,9},verified=true})
  local text=table.concat(out,"\n")
  ok(text:find("Slot 2 is empty through transposer tp1, side 3",1,true))
  ok(text:find("Analysis is not required",1,true)); ok(not text:find("Product/offspring output staging slots",1,true))
  eq(w.moves,0); eq(w.c.alvearyDraft,nil)
end)
test("direct registration detects its inventory and reuses the drone for housing verification",function()
  local w=W.new(); local a=w:addMachine("a"); table.remove(w.c.alvearies)
  w.inventories.a.size=9; w.inventories.a[2]=W.bee("Spirit","drone")
  w.proxies.housing1.getQueen=function() local s=w.inventories.a[1]; return s and U.copy(s.individual) end
  w.c.alvearyDraft={stage=2,machine=a}; w:build()
  local wizard,out=picker(w,{"alveary","","",function()
    w.inventories.a[2]=nil; w.inventories.a[1]=W.bee("Spirit","princess"); return ""
  end,"NORMAL","NORMAL"})
  wizard.address=function(_,label) return label=="Housing component address" and "housing1" or "tp1" end
  wizard.endpoint=function(_,label) eq(label,"Archive for a"); return a.storage end
  wizard:addAlveary()
  eq(#w.c.alvearies,1); eq(a.side,3); eq(a.slots.verified,true); eq(w.moves,0)
  local text=table.concat(out,"\n")
  ok(text:find("Detected a: south (3)",1,true)); ok(text:find("Confirmed drone",1,true))
  ok(not text:find("Inventory number for Alveary",1,true))
end)

test("alveary detection ignores registered neighbours and drones in other slots",function()
  local w=W.new(); w:addMachine("old"); w.inventories.old.size=9
  w.inventories.old[2]=W.bee("Spirit","drone")
  w:inventory("new",9); w.inventories.new[2]={name="Forestry:beeDroneGE",size=1}
  w:inventory("port",9); w.inventories.port[1]=W.bee("Spirit","drone")
  w:addTransposer("tp1",{[0]="port",[2]="old",[5]="new"})
  w.c.alvearies[1].side=2; w:build()
  local wizard,out=picker(w,{""}); wizard.address=function() return "tp1" end
  local ep=wizard:alvearyEndpoint("Alveary 2",{id="alveary_2"})
  eq(ep,{id="alveary_2",transposer="tp1",side=5}); eq(w.moves,0)
  ok(table.concat(out,"\n"):find("Detected Alveary 2: east (5)",1,true))
end)

test("alveary detection retries missing and ambiguous drones without selecting a default",function()
  local w=W.new(); w:inventory("a",9); w:inventory("b",9)
  w:addTransposer("tp1",{[2]="a",[5]="b"}); w:build()
  local wizard,out=picker(w,{"",function()
    w.inventories.a[2]=W.bee("Spirit","drone"); w.inventories.b[2]=W.bee("Spirit","drone"); return ""
  end,function() w.inventories.a[2]=nil; return "" end})
  wizard.address=function() return "tp1" end
  local ep=wizard:alvearyEndpoint("Second",{id="second",side=2})
  eq(ep.side,5); eq(w.moves,0)
  local text=table.concat(out,"\n")
  ok(text:find("No unregistered alveary found",1,true)); ok(text:find("More than one inventory matches",1,true))
end)

test("alveary detection rejects occupied queen slots and retries failed reads",function()
  local w=W.new(); w:inventory("a",9); w.inventories.a[1]=W.bee("Spirit","queen")
  w.inventories.a[2]=W.bee("Spirit","drone"); w:addTransposer("tp1",{[3]="a"})
  local get=w.proxies.tp1.getStackInSlot; local failing=false
  w.proxies.tp1.getStackInSlot=function(side,slot) if failing then error("unloaded") end; return get(side,slot) end
  w:build()
  local wizard,out=picker(w,{"",function() w.inventories.a[1]=nil; failing=true; return "" end,
    function() failing=false; return "" end})
  wizard.address=function() return "tp1" end
  eq(wizard:alvearyEndpoint("New",{id="new"}).side,3); eq(w.moves,0)
  ok(table.concat(out,"\n"):find("Cannot read south",1,true))
end)

test("alveary detection supports back and interrupted checks without saving a connection",function()
  local w=W.new(); w:addTransposer("tp1",{}); w:build()
  local wizard=picker(w,{"back"}); wizard.address=function() return "tp1" end
  local success,err=pcall(function() wizard:alvearyEndpoint("New",{id="new"}) end)
  eq(success,false); eq(err.setupBack,true); eq(w.c.inventoryIds,nil)
  local resumed=picker(w,{}); resumed.address=wizard.address
  raises(function() resumed:alvearyEndpoint("New",{id="new"}) end,"Setup interrupted")
  eq(w.c.inventoryIds,nil); eq(w.moves,0)
end)

test("bee placement check distinguishes a queen from a princess and retries",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.inventories.a[1]=W.bee("Spirit","queen")
  local ep={id="a",transposer="tp1",side=3}
  local wizard,out=picker(w,{"",function() w.inventories.a[1]=W.bee("Spirit","princess"); return "" end})
  wizard:beeWitness(ep,1,"princess",2)
  ok(table.concat(out,"\n"):find("Use a princess for this check",1,true)); eq(w.moves,0)
end)
test("bee placement check explains a mismatched housing adapter",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.inventories.a[1]=W.bee("Spirit","princess")
  local h={getQueen=function() return nil end,getDrone=function() return nil end}
  local wizard,out=picker(w,{"",function() h.getQueen=function() return w.inventories.a[1].individual end; return "" end})
  wizard:beeWitness({id="a",transposer="tp1",side=3},1,"princess",2,h)
  ok(table.concat(out,"\n"):find("transposer sees the princess, but the housing adapter does not",1,true))
end)

test("automatic alveary identity survives interruption and skips existing IDs",function()
  local w=W.new(); w:addMachine("alveary_1"); w:build()
  local wizard,out=picker(w,{"West pair"})
  wizard.address=function() error("hardware interrupted") end
  raises(function() wizard:addAlveary() end,"hardware interrupted")
  eq(w.c.alvearyDraft.machine.id,"alveary_2")
  eq(w.c.alvearyDraft.machine.name,"West pair")
  local resumed=picker(w,{})
  resumed.address=function() error("still disconnected") end
  raises(function() resumed:addAlveary() end,"still disconnected")
  eq(w.c.alvearyDraft.machine.id,"alveary_2")
  eq(resumed:autoId("alveary_"),"alveary_3")
  ok(not table.concat(out,"\n"):find("Unique alveary ID",1,true))
end)

test("new inventory IDs persist and analyser input and output reuse one ID",function()
  local w=W.new(); w:addTransposer("tp",{[0]="hub"}); w:build()
  local wizard=picker(w,{})
  local input=wizard:inventoryId("tp",0)
  eq(input,"inventory_1")
  w.c=assert(load("return "..U.encode(w.c),"=saved config","t",{}))()
  local resumed=picker(w,{})
  eq(resumed:inventoryId("tp",0),input)
  eq(resumed:inventoryId("tp",1),"inventory_2")
end)

test("archive default preserves its identity through a second transposer",function()
  local w=W.new(); w:addMachine("a"); w:addTransposer("tp2",{[5]="hub"}); w:build()
  local wizard=picker(w,{})
  eq(wizard:inventoryId("tp2",5,w.c.storage.endpoints[1]),"hub")
end)

test("scanner Interface selection diagnoses the actual inventory and retries before asking for its adapter",function()
  local w=require("tests.mocks.me").new(); local wizard,out=picker(w,{})
  local calls,adapters=0,0
  wizard.endpoint=function()
    calls=calls+1
    if calls==1 then return U.copy(w.c.scanner.input) end
    return U.copy(w.c.scanner.storage)
  end
  wizard.address=function() adapters=adapters+1; eq(calls,2); return "if-scan" end
  local port=wizard:port("Shared scanner ME Interface")
  eq(port.id,"scan-port"); eq(adapters,1); eq(w.moves,0)
  local text=table.concat(out,"\n")
  ok(text:find("5 slots through transposer tp-scan, side 1",1,true))
  ok(text:find("not the OC Interface adapter",1,true))
end)

test("shared Interface reuses its port ID without an identity question",function()
  local w=require("tests.mocks.me").new()
  local wizard,out=picker(w,{"1"})
  wizard.address=function() return "if1" end
  local ep=wizard:port("Second alveary shared Interface",{id="port_new"},"tp1")
  eq(ep,w.c.storage.endpoints[1])
  wizard:registerEndpoint(ep); eq(#w.c.storage.endpoints,3)
  ok(not table.concat(out,"\n"):find("Inventory ID",1,true))
end)

test("Interface adapter cannot be paired with another inventory view",function()
  local w=require("tests.mocks.me").new(); local wizard=picker(w,{})
  wizard.endpoint=function() return U.copy(w.c.storage.endpoints[2]) end
  wizard.address=function() return "if1" end
  raises(function() wizard:port("Wrong view") end,"different inventory connection")
end)

test("optional setup completes without a robot configuration",function()
  local w=W.new(); w:build()
  local wizard,out=picker(w,{"no"})
  wizard:optional(); eq(w.c.robot,nil)
  ok(table.concat(out,"\n"):find("Offspring and products are retained",1,true))
end)


test("alveary settings edit keeps connections and validates climate before saving",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local a=w.c.alvearies[1]; local connection=U.copy(a)
  a.confirmed={foundation=true}
  local wizard,out,saved=picker(w,{"Cold room","typo","cold","damp","2","no"})
  wizard:editAlveary(a)
  eq(a.name,"Cold room"); eq(a.environment.temperature,"COLD"); eq(a.environment.humidity,"DAMP")
  eq(a.priority,2); eq(a.enabled,false); eq(a.confirmed,{})
  for _,key in ipairs({"id","address","transposer","side","storage","slots"}) do eq(a[key],connection[key],key) end
  eq(#saved,1); eq(w.moves,0)
  ok(table.concat(out,"\n"):find("Choose one of the listed climate values",1,true))
end)

test("interrupted alveary settings edit leaves the registered settings intact",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local a=w.c.alvearies[1]; local original=U.copy(a)
  local wizard,_,saved=picker(w,{"Changed name","HOT"})
  raises(function() wizard:editAlveary(a) end,"Setup interrupted")
  eq(a,original); eq(#saved,0)
end)

test("keeping the climate preserves existing mutation confirmations",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local a=w.c.alvearies[1]; a.confirmed={foundation=true}
  local wizard=picker(w,{"","","","",""})
  wizard:editAlveary(a)
  ok(a.confirmed.foundation)
end)
