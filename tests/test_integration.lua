local W=require("tests.mocks.world"); local B=require("lib.bees"); local U=require("lib.util")
local function charmedWorld(nested)
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build()
  for slot=1,5 do w.inventories.hub[slot]=W.bee(slot<=2 and "Forest" or "Meadows","princess") end
  w.inventories.hub[6]=W.bee("Forest","drone",64); w.inventories.hub[7]=W.bee("Meadows","drone",64)
  for n=1,9 do w.inventories.hub[20+n]=W.bee("Charmed","drone",1,n%2==0 and "Forest" or nil,{lifespan=n}) end
  w.recipes={charmed={W.route(nested and "Middle" or "Forest","Meadows")},middle={W.route("Forest","Meadows")}}
  w.recipes["test.speciescharmed"]=w.recipes.charmed; w.recipes["test.speciesmiddle"]=w.recipes.middle
  return w
end
local function finishRecovery(w,j)
  local name=B.displayName(j.species)
  -- Observe a failed/hybrid first mutation before stable pure offspring.
  local hybrid=j.cycles==1 and name=="Charmed" and "Forest" or nil
  w:finish(j.machine,W.bee(name,"princess",1,hybrid),W.bee(name,"drone",8,hybrid))
end
test("saved blocked conversion rebreeds Charmed to stable 32 drones before its dependent runs",function()
  local w=charmedWorld(); w.state.nextId=2; w.state.target="spirit"
  local j=W.job(w,"job1","Charmed","convert"); j.error="Need target drones above the exact-genotype reserve"
  local downstream=W.job(w,"job2","Spirit","breed",W.route("Charmed","Meadows")); downstream.dependencies={j.id}
  local verified=false
  for tick=1,100 do
    w.scheduler:step()
    if downstream.state=="RUNNING" then
      eq(j.state,"DONE"); ok(j.confirmed>=w.c.confirmCycles)
      ok(w.scheduler:count(w.scheduler:items(j.id),"charmed","drone")>=32)
      verified=true; break
    end
    for _,job in ipairs(w.state.jobs) do if job.state=="RUNNING" then finishRecovery(w,job) end end
  end
  ok(verified,require("lib.ui.status").render(w.state,w.c,true)); ok(j.rebreeding)
  for slot=21,29 do eq(w.inventories.hub[slot].size,1) end
end)
test("breed populate and imprint jobs rebuild fragmented target stock from natural parents",function()
  for _,mode in ipairs({"breed","populate","imprint"}) do
    local w=charmedWorld(); w.state.nextId=1; w.state.target="charmed"
    if mode=="imprint" then
      w.inventories.hub[40]=W.bee("Forest","drone",2)
      w.c.templates={enabled=true,endpointId="hub",slot=40,reserve=1}
    end
    local j=W.job(w,"job1","Charmed",mode)
    for tick=1,100 do
      local _,status=w.scheduler:step(); if status=="DONE" then break end
      for _,job in ipairs(w.state.jobs) do if job.state=="RUNNING" then finishRecovery(w,job) end end
    end
    ok(w.state.finished,mode..": "..require("lib.ui.status").render(w.state,w.c,true))
    ok(w.scheduler:count(w.scheduler:items(j.id),"charmed","drone")>=32)
    ok(j.confirmed>=w.c.confirmCycles); ok(j.rebreeding)
    for slot=21,29 do eq(w.inventories.hub[slot].size,1) end
    if mode=="imprint" then eq(w.inventories.hub[40].size,2) end
  end
end)
test("automatic rebreeding adds prerequisite jobs and survives restart without duplicating them",function()
  local w=charmedWorld(true); w.state.nextId=1
  local j=W.job(w,"job1","Charmed","convert")
  local _,status=w.scheduler:step(); eq(status,"PROGRESS"); eq(#w.state.jobs,2)
  eq(j.dependencies,{"job2"}); ok(j.route); ok(j.rebreeding); eq(j.state,"WAITING")
  -- Restart from saved table data before the new prerequisite dispatches.
  w.state=assert(load("return "..U.encode(w.state)))(); w:build(); w.scheduler:recover()
  for tick=1,150 do
    local _,result=w.scheduler:step(); if result=="DONE" then break end
    for _,job in ipairs(w.state.jobs) do if job.state=="RUNNING" then finishRecovery(w,job) end end
  end
  ok(w.state.finished,require("lib.ui.status").render(w.state,w.c,true)); eq(#w.state.jobs,2)
  eq(w.state.jobs[1].id,"job1"); ok(w.scheduler:count(w.scheduler:items("job1"),"charmed","drone")>=32)
end)
test("failed automatic rebreeding retains the reserve shortage and explains missing founders",function()
  local w=charmedWorld(); w.recipes.charmed={W.route("Missing","Impossible")}
  w.recipes["test.speciescharmed"]=w.recipes.charmed
  local j=W.job(w,"job1","Charmed","convert")
  w.scheduler:step(); eq(j.state,"WAITING"); eq(w.moves,0)
  ok(j.error:find("largest identical group: 1",1,true),j.error)
  ok(j.error:find("Automatic rebreeding unavailable:",1,true),j.error)
  ok(j.error:find("Missing: no mutation recipe reported",1,true),j.error)
  ok(not j.rebreeding); eq(#w.state.jobs,1)
end)
test("conversion by mutation creates an additional target princess and respects mutation requirements",function()
  local w=charmedWorld(); w.state.nextId=1
  w.inventories.hub[40]=W.bee("Charmed","princess")
  local j=W.job(w,"job1","Charmed","convert")
  w.recipes.charmed[1].specialConditions={"Requires Diamond as a foundation"}
  w.scheduler:step(); eq(j.state,"WAITING"); eq(w.moves,0); eq(j.baseline,1)
  ok(j.error:find("Unconfirmed mutation requirement",1,true),j.error)
  for _,a in ipairs(w.c.alvearies) do a.confirmed["Requires Diamond as a foundation"]=true end
  for tick=1,100 do
    local _,status=w.scheduler:step(); if status=="DONE" then break end
    for _,job in ipairs(w.state.jobs) do if job.state=="RUNNING" then finishRecovery(w,job) end end
  end
  ok(w.state.finished,require("lib.ui.status").render(w.state,w.c,true))
  ok(w.scheduler:count(w.scheduler:items(j.id),"charmed","princess")>=2)
  eq(w.inventories.hub[40].individual.active.species.name,"Charmed")
end)
test("breeding a known mutated target recovers its princess from drones before stabilization",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.c.confirmCycles=1; w.c.minDrones=2
  w.inventories.hub[1]=W.bee("Forest","princess")
  w.inventories.hub[2]=W.bee("Forest","princess")
  w.inventories.hub[3]=W.bee("Spirit","drone",32)
  local m=require("lib.mutations").new({getBeeParents=function()
    return {W.route("Missing","Impossible")}
  end},{})
  local plan=assert(require("lib.planner").plan("spirit",m,w.storage:scan(),w.c))
  require("lib.jobs").create(w.state,plan,"breed")
  for tick=1,40 do
    local _,status=w.scheduler:step()
    if status=="DONE" then break end
    for _,j in ipairs(w.state.jobs) do if j.state=="RUNNING" then
      w:finish(j.machine,W.bee("Spirit","princess"),W.bee("Spirit","drone",4))
    end end
    w.time=w.time+5
  end
  ok(w.state.finished,require("lib.ui.status").render(w.state,w.c,true))
  eq(w.state.jobs[1].mode,"convert"); eq(w.state.jobs[2].mode,"breed")
  ok(B.count(w.storage:scan(),"spirit","princess",true)>=1)
  ok(B.count(w.storage:scan(),"forest","princess",true)>=1)
end)

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
test("imprint spare helper converts without consuming the reference and survives restart",function()
  local ME=require("tests.mocks.me"); local w=ME.new(); w.hideGenomes=false
  w.c.minDrones=2; w.c.confirmCycles=1; w.state.nextId=1; w.state.target="spirit"
  local reference=ME.bee("Forest","drone",2,false,{nocturnal=true})
  w.c.templates={enabled=true,identity=B.identity(reference),reserve=1}; w:addStock(reference)
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",16))
  for n=1,2 do w:addStock(ME.bee("Meadows","princess",1,false,{lifespan=n})) end
  for n=1,24 do
    local s=ME.bee("Unrelated","drone",32,false,{lifespan=n})
    s.tag=string.rep(string.char(n+32),600)..n; w:addStock(s)
  end
  local j=W.job(w,"job1","Spirit","imprint")
  w.scheduler:step(); eq(j.state,"WAITING"); eq(#w.state.jobs,2)
  local helper=w.state.jobs[2]; eq(helper.mode,"convert"); eq(helper.parent,j.id)
  eq(w.scheduler:template(helper,w.storage:scan()),nil)
  w.scheduler:step(); eq(helper.state,"RUNNING"); eq(j.cycles,0)
  eq(w.cells[B.identity(reference)].size,2)
  -- Recreate the worker from saved job data while the helper's queen is live.
  local state=U.copy(w.state); for k in pairs(w.state) do w.state[k]=nil end
  for k,v in pairs(state) do w.state[k]=v end; state=nil
  local Scheduler=require("lib.scheduler")
  w.scheduler=Scheduler.new(w.c,w.state,w.components,w.inv,w.storage,w.scanner,w.save,function() return w.time end)
  w.scheduler:recover(); j=w.state.jobs[1]; helper=w.state.jobs[2]
  w:finish(helper.machine,ME.bee("Spirit","princess"),ME.bee("Spirit","drone",8))
  w.scheduler:step(); w.scheduler:step()
  eq(helper.state,"DONE"); eq(j.state,"RUNNING"); eq(#w.state.jobs,2)
  eq(w.cells[B.identity(reference)].size,1)
  w:finish(j.machine,ME.bee("Spirit","princess",1,false,{nocturnal=true}),
    ME.bee("Spirit","drone",8,false,{nocturnal=true}))
  for _=1,4 do w.scheduler:step(); if w.state.finished then break end end
  ok(w.state.finished,require("lib.ui.status").render(w.state,w.c,true))
  eq(j.state,"DONE"); eq(#w.state.jobs,2); eq(w.cells[B.identity(reference)].size,1)
end)

test("imprinting crosses a reserved reference genotype and preserves it",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.minDrones=2; w.c.confirmCycles=1
  w.c.templates={enabled=true,endpointId="hub",slot=20,reserve=1}
  w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","princess")
  w.inventories.hub[3]=W.bee("Spirit","drone",16)
  w.inventories.hub[20]=W.bee("Forest","drone",2,nil,{fertility=4})
  local j=W.job(w,"j","Spirit","imprint"); w.scheduler:step(); eq(j.state,"RUNNING")
  eq(w.inventories.hub[20].size,1)
  w:finish("a",W.bee("Spirit","princess",1,nil,{fertility=4}),W.bee("Spirit","drone",8,nil,{fertility=4}))
  w.scheduler:step(); eq(j.state,"DONE"); ok(w.inventories.hub[20])
end)
test("routed fallback stages receipts behind a gate and collects isolated outputs",function()
  local w=W.new(); local a=w:addMachine("a"); w:inventory("routed-output",11)
  w.c.minDrones=8
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
