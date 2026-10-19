local W=require("tests.mocks.world"); local B=require("lib.bees"); local U=require("lib.util")
test("Spirit plan executes missing prerequisites through stabilization and reserve conversion",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build()
  w.c.confirmCycles=2; w.c.minDrones=4
  for slot=1,10 do w.inventories.hub[slot]=W.bee(slot<=5 and "Forest" or "Meadows","princess") end
  w.inventories.hub[11]=W.bee("Forest","drone",64); w.inventories.hub[12]=W.bee("Meadows","drone",64)
  local recipes={spirit={W.route("Ethereal","Aware")},ethereal={W.route("Forest","Meadows")},aware={W.route("Forest","Meadows")}}
  local m=require("lib.mutations").new({getBeeParents=function(name) return recipes[name] or {} end},{})
  local plan=assert(require("lib.planner").plan("spirit",m,w.storage:scan(),w.c))
  require("lib.jobs").create(w.state,plan,"breed")
  local cycles=0
  for tick=1,150 do
    local _,status=w.scheduler:step()
    if status=="DONE" then break end
    for _,j in ipairs(w.state.jobs) do if j.state=="RUNNING" then
      local species=j.species:sub(1,1):upper()..j.species:sub(2)
      w:finish(j.machine,W.bee(species,"princess"),W.bee(species,"drone",4)); cycles=cycles+1
    end end
    w.time=w.time+5
  end
  if not w.state.finished then
    error(require("lib.ui.status").render(w.state,w.c,true))
  end
  ok(cycles>=6); ok(B.count(w.storage:scan(),"spirit","princess",true)>=1)
  ok(B.count(w.storage:scan(),"forest","princess",true)>=1)
  ok(B.count(w.storage:scan(),"meadows","drone",true)>=1)
end)
test("restart in collection restores a committed but unrecorded receipt",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.confirmCycles=1; w.c.minDrones=2
  local j=W.job(w,"one","Spirit","populate"); j.state="COLLECTING"; j.machine="a"; j.collectionAfter=0
  w.state.machines.a={job=j.id,state="COLLECTING"}
  w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.a[8]=W.bee("Spirit","drone",8)
  w.state.transferSequence=1
  w.state.transactions={{id=1,owner=j.id,dest=w.c.alvearies[1].storage,destSlot=1,phase="COMMITTED"}}
  w.scheduler:recover(); w.scheduler:step(); eq(j.state,"DONE")
end)
test("scanner restart after return receipt clears queue without repeating",function()
  local w=W.new(); w:addMachine("a"); w:inventory("input",5); w:inventory("output",5)
  w:addTransposer("tp1",{[0]="hub",[1]="input",[2]="output",[3]="a"})
  local storage={id="hub",transposer="tp1",side=0}
  w.c.scanner={enabled=true,isolatedVerified=true,input={id="input",transposer="tp1",side=1},output={id="output",transposer="tp1",side=2},storage=storage}
  w:build(); w.inventories.hub[7]=W.bee("Spirit","princess")
  w.state.scan={name="Forestry:beePrincessGE",size=1,ident="test.speciesspirit",returnSlot=7,started=0}
  ok(w.scanner:step(w.storage:scan())); eq(w.state.scan,nil); eq(w.moves,0)
end)
test("cycle timeout affects one operation while another keeps running",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build(); w.c.cycleTimeout=10
  for n,id in ipairs({"a","b"}) do local j=W.job(w,"j"..n,"Spirit","populate")
    j.state="RUNNING"; j.machine=id; j.started=n==1 and 0 or 15
    w.state.machines[id]={job=j.id,state="RUNNING"}; w.inventories[id][4]=W.bee("Spirit","queen")
  end
  w.time=20; w.scheduler:step(); eq(w.state.jobs[1].state,"PAUSED"); eq(w.state.jobs[2].state,"RUNNING")
end)
test("imprinting crosses a reserved reference genotype and preserves it",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.minDrones=2; w.c.confirmCycles=1
  w.c.templates={enabled=true,endpointId="hub",slot=20,reserve=1}
  w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","princess")
  w.inventories.hub[3]=W.bee("Spirit","drone",16)
  w.inventories.hub[20]=W.bee("Forest","drone",16,nil,{fertility=4})
  local j=W.job(w,"j","Spirit","imprint"); w.scheduler:step(); eq(j.state,"RUNNING")
  eq(w.inventories.hub[20].size,15)
  w:finish("a",W.bee("Spirit","princess",1,nil,{fertility=4}),W.bee("Spirit","drone",8,nil,{fertility=4}))
  w.scheduler:step(); eq(j.state,"DONE"); ok(w.inventories.hub[20])
end)
test("routed fallback stages receipts behind a gate and collects isolated outputs",function()
  local w=W.new(); local a=w:addMachine("a"); w:inventory("routed-output",11)
  w:addTransposer("tp1",{[0]="hub",[3]="a",[2]="routed-output"})
  local gate=0; w.proxies.gate={setOutput=function(_,value) gate=value end}
  w.proxies.housing1.getQueen=function() return nil end; w.proxies.housing1.getDrone=function() return nil end
  a.backend="routed"; a.routing={verified=true,gate={address="gate",side=5,off=0,on=15},
    output={id="routed-output",transposer="tp1",side=2},outputInventorySize=11}
  w:build(); w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","drone",8)
  local j=W.job(w,"j","Spirit","populate"); w.scheduler:step(); eq(j.state,"RUNNING"); eq(gate,15)
  -- Simulate the tested external routing path independently of inventory access.
  w.inventories.a[4]=nil; w.inventories.a[2]=nil
  w.inventories["routed-output"][6]=W.bee("Spirit","princess"); w.inventories["routed-output"][8]=W.bee("Spirit","drone",8)
  w.c.confirmCycles=1; w.scheduler:step(); eq(j.state,"DONE"); eq(gate,0)
end)
