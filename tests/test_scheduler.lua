local W=require("tests.mocks.world"); local B=require("lib.bees")
local function stocked(two)
  local w=W.new(); w:addMachine("a"); if two then w:addMachine("b") end
  w:build(); w.c.confirmCycles=1; w.c.minDrones=2
  w.inventories.hub[1]=W.bee("Forest","princess")
  w.inventories.hub[2]=W.bee("Meadows","drone",8)
  w.inventories.hub[10]=W.bee("Forest","princess")
  w.inventories.hub[12]=W.bee("Forest","drone",8)
  return w
end

test("saved mutation route with an optional lunar bonus dispatches without confirmation",function()
  local w=stocked(); local route=W.route("Forest","Meadows",8,
    {"Better success between the Waxing Crescent and Waxing Gibbous."})
  local j=W.job(w,"one","Arcane","breed",route)
  w.scheduler:dispatch(j); eq(j.state,"RUNNING"); eq(j.error,nil); eq(j.machine,"a")
end)
test("lunar mutations for different species wait automatically without leasing parents",function()
  for _,case in ipairs({{"Vis","Occurs between the Waxing Half and Waning Half",4,6},
    {"Wispy","Occurs between the Waning Crescent and Waxing Crescent",0,3},
    {"Pure","During the New Moon",0,4},{"Big Bad","During the Full Moon",4,0},
    {"Arbitrary Species","During the Waxing Gibbous",0,7}}) do
    local w=stocked(); local req=case[2]; local ticks=6000+case[3]*24000
    w.c.alvearies[1].confirmed[req]=true -- legacy confirmation cannot bypass live time
    local j=W.job(w,"lunar",case[1],"breed",W.route("Forest","Meadows",8,{req}))
    W.withWorldTime(function() return ticks end,function()
      local active,status=w.scheduler:step()
      eq(active,false); eq(status,"WAITING"); eq(j.state,"WAITING"); eq(w.moves,0)
      ok(j.error:find("Waiting for moon phase:",1,true),j.error)
      eq(j.machine,nil); eq(next(w.state.reservations),nil)
      local saves=w.saves
      _,status=w.scheduler:step(); eq(status,"WAITING"); eq(w.saves,saves)
      ticks=6000+case[4]*24000
      w.scheduler:step(); eq(j.state,"RUNNING"); eq(j.cycles,1); eq(j.error,nil)
      local moves=w.moves; ticks=6000+case[3]*24000
      w.scheduler:step(); eq(j.state,"RUNNING"); eq(w.moves,moves)
    end)
  end
end)
test("lunar mutation waiting does not block independent breeding",function()
  local w=stocked(true)
  local lunar=W.job(w,"lunar","Vis","breed",W.route("Forest","Meadows",8,{"During the New Moon"}))
  local ordinary=W.job(w,"ordinary","Forest","populate")
  W.withWorldTime(6000,function()
    local active,status=w.scheduler:step()
    ok(active); eq(status,"RUNNING"); eq(lunar.state,"WAITING"); eq(ordinary.state,"RUNNING")
  end)
end)
test("inherited target bees do not wait for an unnecessary mutation phase",function()
  for _,hybrid in ipairs({false,true}) do
    local w=stocked()
    w.inventories.hub[1]=W.bee("Spirit","princess",1,hybrid and "Forest" or nil)
    w.inventories.hub[10]=W.bee("Spirit","princess",1,hybrid and "Forest" or nil)
    if not hybrid then w.inventories.hub[12]=W.bee("Spirit","drone",8) end
    local j=W.job(w,"one","Spirit","breed",W.route("Forest","Meadows",8,{"During the New Moon"}))
    W.withWorldTime(6000,function() w.scheduler:step(); eq(j.state,"RUNNING") end)
  end
end)

test("blocked mutation explains the requirement and how to confirm it",function()
  local w=stocked(); local route=W.route("Forest","Meadows",8,
    {"Better success during the Full Moon.","Requires Diamond as a foundation"})
  local j=W.job(w,"one","Arcane","breed",route)
  w.scheduler:dispatch(j); eq(j.state,"WAITING"); eq(w.moves,0)
  ok(j.error:find("Unconfirmed mutation requirement: Requires Diamond as a foundation",1,true),j.error)
  ok(j.error:find("Beeomatic doctor --confirm a",1,true),j.error)
  ok(not j.error:find("Better success",1,true),j.error)
  w.c.alvearies[1].confirmed["Requires Diamond as a foundation"]=true
  w.scheduler:dispatch(j); eq(j.state,"RUNNING"); eq(j.error,nil)
end)

test("working queens do not raise false housing alerts and real obstructions clear after recovery",function()
  local w=stocked(); local j=W.job(w,"one","Cultivated","populate")
  j.state="RUNNING"; j.machine="a"; j.started=w.time
  w.state.machines.a={job=j.id,state="RUNNING"}
  w.inventories.a[4]=W.bee("Cultivated","queen")
  w.scheduler:advance(j)
  eq(j.state,"RUNNING"); eq(j.error,nil)
  local Status=require("lib.ui.status")
  ok(not Status.render(w.state,w.c,false):find("Attention:",1,true))
  w.obstructed=true; w.scheduler:advance(j)
  ok(j.error:find("housing reports it cannot work",1,true))
  ok(Status.render(w.state,w.c,false):find("Attention:\n  Cultivated: housing reports it cannot work",1,true))
  w.obstructed=false; w.scheduler:advance(j)
  eq(j.error,nil); eq(j.state,"RUNNING"); eq(w.moves,0)
  ok(not Status.render(w.state,w.c,false):find("Attention:",1,true))
end)
test("concurrent independent operations use separate machines and items",function()
  local w=stocked(true)
  w.inventories.hub[3]=W.bee("Aware","princess")
  w.inventories.hub[4]=W.bee("Ethereal","drone",8)
  w.inventories.hub[11]=W.bee("Aware","princess")
  w.inventories.hub[13]=W.bee("Aware","drone",8)
  local j1=W.job(w,"one","Common","breed",W.route("Forest","Meadows"))
  local j2=W.job(w,"two","Spirit","breed",W.route("Aware","Ethereal"))
  w.scheduler:step(); eq(j1.state,"RUNNING"); eq(j2.state,"RUNNING"); ok(j1.machine~=j2.machine)
end)
test("sequentially committed withdrawals allocate distinct units of a shared stack",function()
  local w=stocked(true); w.inventories.hub[3]=W.bee("Forest","princess")
  local r=W.route("Forest","Meadows"); local j1=W.job(w,"one","Common","breed",r); local j2=W.job(w,"two","Cultivated","breed",r)
  w.scheduler:step(); local n=(j1.state=="RUNNING" and 1 or 0)+(j2.state=="RUNNING" and 1 or 0)
  eq(n,2); eq(w.inventories.hub[2].size,6)
end)
test("configured alveary map ignores apiary slot numbers",function()
  local w=stocked(); local j=W.job(w,"one","Common","breed",W.route("Forest","Meadows"))
  -- A pure spare parent is required when starting a mutation.
  w.inventories.hub[1]=W.bee("Forest","princess"); w.inventories.hub[3]=W.bee("Forest","princess")
  w.scheduler:step(); eq(j.state,"RUNNING"); eq(B.kind(w.inventories.a[4]),"queen"); eq(w.inventories.a[1],nil)
  w:finish("a",W.bee("Common","princess"),W.bee("Common","drone",8)); w.scheduler:step()
  ok(j.state=="DONE" or j.state=="WAITING"); ok(w.state.lastCycle)
end)
test("base parents populate before mutation even when a spendable pair exists",function()
  local w=stocked(); w.c.minDrones=32; w.c.confirmCycles=3
  w.inventories.hub[12].size=16
  w.inventories.hub[2].size=32
  local j=W.job(w,"one","Common","breed",W.route("Forest","Meadows"))
  w.scheduler:step(); eq(j.state,"WAITING"); eq(w.moves,0)
  eq(w.state.parentStock.forest,{count=16,minimum=32})
  eq(w.state.parentStock.meadows,{count=32,minimum=32})
  local helper=w.state.jobs[2]; eq(helper.mode,"populate"); eq(helper.species,"forest"); eq(helper.count,32)
  for cycle=1,3 do
    w.scheduler:step(); eq(helper.state,"RUNNING"); eq(j.state,"WAITING")
    w:finish("a",W.bee("Forest","princess"),W.bee("Forest","drone",20))
    w.scheduler:step()
    eq(helper.confirmed,cycle)
    if cycle<3 then eq(j.state,"WAITING") end
  end
  for tick=1,3 do if j.state~="RUNNING" then w.scheduler:step() end end
  eq(helper.state,"DONE"); eq(j.state,"RUNNING")
  eq(w.state.parentStock,{})
end)

test("both base parents schedule population and duplicate requests share helpers",function()
  local w=stocked(); w.c.minDrones=32
  local j=W.job(w,"one","Common","breed",W.route("Forest","Meadows"))
  for n=1,2 do
    local p,d=w.scheduler:select(j,w.scheduler:items(j.id))
    eq(p,nil); eq(d,nil)
  end
  eq(#w.state.jobs,3)
  eq(w.state.jobs[2].species,"forest"); eq(w.state.jobs[3].species,"meadows")
  eq(w.moves,0)
end)

test("last pure parent princess is protected and conversion helper scheduled",function()
  local w=stocked(); w.inventories.hub[1]=W.bee("Forest","princess"); w.inventories.hub[10]=nil; w.inventories.hub[3]=W.bee("Forest","drone",16)
  local j=W.job(w,"one","Common","breed",W.route("Forest","Meadows"))
  w.scheduler:step(); eq(j.state,"WAITING"); ok(w.inventories.hub[1]); ok(#w.state.jobs>1)
end)
test("princess conversion uses spare rather than existing target princess",function()
  local w=stocked(); w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",16)
  w.inventories.hub[3]=W.bee("Forest","princess",1,"Meadows")
  local j=W.job(w,"one","Spirit","convert")
  w.scheduler:step(); eq(j.state,"RUNNING"); ok(w.inventories.hub[1]); eq(j.expectedPrincess.individual.active.species.name,"Forest")
  w:finish("a",W.bee("Spirit","princess"),W.bee("Spirit","drone",8)); w.scheduler:step()
  eq(j.state,"DONE"); eq(B.count(w.storage:scan(),"spirit","princess",true),2)
end)
test("missing target drones report species counts reserve and exact action in both status views",function()
  local w=stocked(); local j=W.job(w,"one","Charmed","convert")
  w.scheduler:dispatch(j); eq(j.state,"WAITING"); eq(w.moves,0)
  for _,message in ipairs({"Cannot recover a Charmed princess", "Analysed target drones available to this job: 0",
    "largest identical group: 0", "Need 2 in one identical group: 1 to breed + 1 kept as reserve",
    "Add at least 2 identical analysed Charmed drones, then Beeomatic resume."}) do
    ok(j.error:find(message,1,true),j.error)
    for _,verbose in ipairs({false,true}) do
      ok(require("lib.ui.status").render(w.state,w.c,verbose):find(message,1,true))
    end
  end
end)
test("nine separate target variants including hybrids do not count as a spendable identical group",function()
  local w=stocked(); local j=W.job(w,"one","Charmed","convert")
  for n=1,9 do w.inventories.hub[20+n]=W.bee("Charmed","drone",1,n%2==0 and "Forest" or nil,{lifespan=n}) end
  w.scheduler:dispatch(j); eq(j.state,"WAITING"); eq(w.moves,0)
  ok(j.error:find("Analysed target drones available to this job: 9; largest identical group: 1",1,true),j.error)
  ok(j.error:find("Add 1 more matching drone to an existing group",1,true),j.error)
  w.inventories.hub[21].size=2
  w.scheduler:dispatch(j); eq(j.state,"RUNNING"); eq(w.inventories.hub[21].size,1)
end)
test("reserve diagnostics use configured counts and sum split identical stacks",function()
  local w=stocked(); w.c.reserveDrones=3
  w.inventories.hub[20]=W.bee("Charmed","drone",1)
  w.inventories.hub[21]=W.bee("Charmed","drone",2)
  local j=W.job(w,"one","Charmed","convert")
  w.scheduler:dispatch(j); eq(j.state,"WAITING"); eq(w.moves,0)
  ok(j.error:find("largest identical group: 3",1,true),j.error)
  ok(j.error:find("Need 4 in one identical group: 1 to breed + 3 kept as reserve",1,true),j.error)
  w.inventories.hub[21].size=3
  w.scheduler:dispatch(j); eq(j.state,"RUNNING")
  eq(w.scheduler:count(w.scheduler:items(j.id),"charmed","drone"),3)
end)
test("drone shortage excludes template raw and other-job stock but includes target hybrids",function()
  local w=stocked(); w.c.templates={enabled=true,endpointId="hub",slot=20,reserve=1}
  w.inventories.hub[20]=W.bee("Charmed","drone",16)
  w.inventories.hub[21]=W.bee("Charmed","drone",32); w.inventories.hub[21].individual.isAnalyzed=false
  w.inventories.hub[22]=W.bee("Charmed","drone",64)
  w.state.reservations["hub:22"]={owner="other"}
  w.inventories.hub[23]=W.bee("Forest","drone",1,"Charmed")
  local j=W.job(w,"one","Charmed","convert")
  w.scheduler:dispatch(j); eq(j.state,"WAITING"); eq(w.moves,0)
  ok(j.error:find("Analysed target drones available to this job: 1; largest identical group: 1",1,true),j.error)
  ok(j.error:find("16 reference-template drones excluded",1,true),j.error)
end)
test("population and imprint share precise drone reserve diagnostics",function()
  for _,mode in ipairs({"populate","imprint"}) do
    local w=stocked(); w.inventories.hub[20]=W.bee("Charmed","drone",1)
    local j=W.job(w,"one","Charmed",mode)
    local p,d,why=w.scheduler:select(j,w.scheduler:items(j.id))
    eq(p,nil); eq(d,nil); eq(w.moves,0)
    ok(why:find("Cannot breed Charmed",1,true),why)
    ok(why:find("largest identical group: 1",1,true),why)
  end
end)
test("population completes from offspring count and stable pair",function()
  local w=stocked(); w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","drone",8)
  local j=W.job(w,"one","Spirit","populate"); j.count=12
  w.scheduler:step(); eq(j.state,"RUNNING")
  w:finish("a",W.bee("Spirit","princess"),W.bee("Spirit","drone",8)); w.scheduler:step()
  eq(j.state,"DONE"); ok(B.count(w.storage:scan(),"spirit","drone",true)>=12)
end)
test("fertility one population pauses safely",function()
  local w=stocked(); w.inventories.hub[1]=W.bee("Spirit","princess",1,nil,{fertility=1}); w.inventories.hub[2]=W.bee("Spirit","drone",1)
  local j=W.job(w,"one","Spirit","populate"); w.scheduler:step(); eq(j.state,"PAUSED"); eq(w.moves,0)
  ok(j.error:find("Fertility <= 1",1,true),j.error)
end)

test("population spends its last pure drone and continues after restart",function()
  local w=stocked(); w.c.reserveDrones=8; w.c.confirmCycles=1
  w.inventories.hub[1]=W.bee("Steadfast","princess"); w.inventories.hub[2]=W.bee("Steadfast","drone")
  local j=W.job(w,"one","Steadfast","populate"); j.count=5
  w.scheduler:step(); eq(j.state,"RUNNING"); eq(w.inventories.hub[2],nil)
  w:finish(j.machine,W.bee("Steadfast","princess"),W.bee("Steadfast","drone",3)); w.scheduler:advance(j)
  eq(j.state,"WAITING"); ok(j.lineage)
  w.state=assert(load("return "..require("lib.util").encode(w.state)))(); w:build(); w.scheduler:recover()
  j=w.state.jobs[1]; w.scheduler:step(); eq(j.state,"RUNNING")
  w:finish(j.machine,W.bee("Steadfast","princess"),W.bee("Steadfast","drone",3)); w.scheduler:step()
  w.scheduler:step(); eq(j.state,"DONE"); eq(B.count(w.storage:scan(),"steadfast","drone",true),5)
end)

test("population cannot bypass protected reserved or hybrid drone stock",function()
  for _,blocked in ipairs({"template","reserved","hybridDrone","hybridPrincess"}) do
    local w=stocked(); w.inventories.hub[1]=W.bee("Steadfast","princess",1,blocked=="hybridPrincess" and "Forest" or nil)
    w.inventories.hub[2]=W.bee("Steadfast","drone",1,blocked=="hybridDrone" and "Forest" or nil)
    if blocked=="template" then w.c.templates={enabled=true,endpointId="hub",slot=2,reserve=1}
    elseif blocked=="reserved" then w.state.reservations["hub:2"]={owner="other"} end
    local j=W.job(w,"one","Steadfast","populate")
    local p,d=w.scheduler:select(j,w.scheduler:items(j.id))
    eq(p,nil,blocked); eq(d,nil,blocked); eq(w.moves,0)
  end
end)

test("generic conversion excludes active and recessive fertility one donors",function()
  for _,inactiveOnly in ipairs({false,true}) do
    local w=stocked()
    w.inventories.hub[1]=W.bee("Rocky","princess",1,"Forest",{fertility=inactiveOnly and 3 or 1})
    w.inventories.hub[1].individual.inactive.fertility=1
    w.inventories.hub[10]=nil
    w.inventories.hub[2]=W.bee("Spirit","drone",32)
    local j=W.job(w,"one","Spirit","convert")
    w.scheduler:step(); eq(j.state,"WAITING"); eq(w.moves,0)
    ok(j.error:find("fertility",1,true))
    w.inventories.hub[3]=W.bee("Meadows","princess",1,"Forest")
    w.scheduler:step(); eq(j.state,"RUNNING")
    eq(j.expectedPrincess.individual.active.species.name,"Meadows")
    ok(w.inventories.hub[1])
  end
end)

test("imprint conversion also excludes unrelated fertility one princesses",function()
  local w=stocked(); w.inventories.hub[1]=W.bee("Rocky","princess",1,"Forest",{fertility=1})
  w.inventories.hub[10]=nil; w.inventories.hub[2]=W.bee("Spirit","drone",32)
  local j=W.job(w,"one","Spirit","imprint")
  local p=w.scheduler:select(j,w.scheduler:items(j.id))
  eq(p,nil); eq(w.moves,0)
end)

test("required fertility one parent bypasses impossible population target",function()
  local w=stocked(); w.c.minDrones=32
  for _,slot in ipairs({1,10}) do w.inventories.hub[slot]=W.bee("Rocky","princess",1,nil,{fertility=1}) end
  w.inventories.hub[12]=W.bee("Rocky","drone",2,nil,{fertility=1})
  w.inventories.hub[2].size=32
  local j=W.job(w,"one","Common","breed",W.route("Rocky","Meadows"))
  w.scheduler:step(); eq(j.state,"RUNNING"); eq(#w.state.jobs,1)
  eq(j.expectedPrincess.individual.active.species.name,"Rocky")
end)

test("required fertility one drone parent preserves exact genotype reserve",function()
  local w=stocked(); w.c.minDrones=32
  w.inventories.hub[12].size=32
  w.inventories.hub[2]=W.bee("Rocky","drone",2,nil,{fertility=1})
  w.inventories.hub[3]=W.bee("Rocky","princess",1,nil,{fertility=1})
  local j=W.job(w,"one","Common","breed",W.route("Forest","Rocky"))
  w.scheduler:step(); eq(j.state,"RUNNING"); eq(w.inventories.hub[2].size,1)
end)

test("fertility one target completes confirmations without demanding 32 drones",function()
  local w=stocked(); w.c.minDrones=32; w.c.confirmCycles=3
  w.inventories.hub[1]=W.bee("Rocky","princess",1,nil,{fertility=1})
  w.inventories.hub[2]=W.bee("Rocky","drone",2,nil,{fertility=1})
  local j=W.job(w,"one","Rocky","breed")
  for cycle=1,3 do
    w.scheduler:step(); eq(j.state,"RUNNING")
    w:finish("a",W.bee("Rocky","princess",1,nil,{fertility=1}),W.bee("Rocky","drone",1,nil,{fertility=1}))
    w.scheduler:step(); eq(j.confirmed,cycle)
  end
  w.scheduler:step(); eq(j.state,"DONE")
  eq(B.count(w.storage:scan(),"rocky","drone",true),2)
  local explicit=W.job(w,"two","Rocky","populate"); explicit.count=32
  w.scheduler:step(); eq(explicit.state,"PAUSED")
end)

test("population prefers growing princess even when fertility one scores higher",function()
  local w=stocked(); w.c.minDrones=32; w.c.desired={nocturnal=true}; w.c.weights.nocturnal=100
  w.inventories.hub[1]=W.bee("Spirit","princess",1,nil,{fertility=1,nocturnal=true})
  w.inventories.hub[3]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",8)
  local j=W.job(w,"one","Spirit","populate"); j.count=32
  eq(w.scheduler:populationMinimum(w.scheduler:items(j.id),"spirit"),32)
  w.scheduler:step(); eq(j.state,"RUNNING"); eq(j.expectedPrincess.individual.active.fertility,3)
end)

test("required fertility one parent cannot consume its last reserved drone",function()
  local w=stocked(); w.c.minDrones=32
  w.inventories.hub[1]=W.bee("Rocky","princess",1,nil,{fertility=1})
  w.inventories.hub[10]=W.bee("Rocky","princess",1,nil,{fertility=1})
  w.inventories.hub[12]=W.bee("Rocky","drone",1,nil,{fertility=1})
  w.inventories.hub[2].size=32
  local j=W.job(w,"one","Common","breed",W.route("Rocky","Meadows"))
  w.scheduler:step(); eq(j.state,"WAITING"); eq(w.moves,0); eq(#w.state.jobs,1)
end)
test("cycle completion requires both input absence and offspring",function()
  local w=stocked(); local b=w.scheduler:backend("a"); eq(b:getCycleState(),"UNCERTAIN")
  w.inventories.a[6]=W.bee("Spirit","princess"); eq(b:getCycleState(),"UNCERTAIN")
  w.inventories.a[8]=W.bee("Spirit","drone"); eq(b:getCycleState(),"FINISHED")
  w.inventories.a[4]=W.bee("Forest","queen"); eq(b:getCycleState(),"RUNNING")
end)
test("cycle limit bounds unsuccessful mutation attempts",function()
  local w=stocked(); local j=W.job(w,"one","Common","breed",W.route("Forest","Meadows")); j.cycles=w.c.maxCycles
  w.inventories.hub[1]=W.bee("Forest","princess"); w.inventories.hub[3]=W.bee("Forest","princess")
  w.scheduler:step(); eq(j.state,"PAUSED"); eq(w.moves,0)
end)


test("cross-climate conversion uses the princess climate then rechecks inherited offspring",function()
  for _,target in ipairs({"Attuned","Cultivated"}) do
    local w=W.new(); w:addMachine("alveary_1","NORMAL"); w:addMachine("alveary_2","COLD"); w:build()
    local p=W.bee("Wintry","princess",1,nil,{temperatureTolerance="UP_1"})
    p.individual.active.species.temperature="Icy"
    p.individual.inactive.species.temperature="Icy"
    w.inventories.hub[1]=p; w.inventories.hub[2]=require("lib.util").copy(p)
    w.inventories.hub[3]=W.bee(target,"drone",8)
    local j=W.job(w,"recover",target,"convert")
    w.scheduler:dispatch(j)
    eq(j.state,"RUNNING"); eq(j.machine,"alveary_2"); eq(j.error,nil)
    local queen=w.inventories.alveary_2[4]
    eq(require("lib.bees").kind(queen),"queen")
    eq(queen.individual.active.species.name,"Wintry")
    eq(queen.individual.active.temperatureTolerance,"UP_1")
    -- A possible inherited result now has Normal active genes. The following
    -- cycle must be dispatched from these observed genes, not the donor's.
    w:finish("alveary_2",W.bee(target,"princess"),W.bee(target,"drone",4))
    w.scheduler:advance(j); eq(j.state,"WAITING")
    w.scheduler:dispatch(j)
    eq(j.state,"RUNNING"); eq(j.machine,"alveary_1"); eq(j.error,nil)
    eq(w.inventories.alveary_1[4].individual.active.species.name,target)
  end
end)

test("blocked conversion explains the princess climate without rejecting its drone",function()
  local w=W.new(); w:addMachine("normal","NORMAL"); w:build()
  local p=W.bee("Wintry","princess",1,nil,{temperatureTolerance="UP_1"})
  p.individual.active.species.temperature="Icy"; p.individual.inactive.species.temperature="Icy"
  w.inventories.hub[1]=p; w.inventories.hub[2]=require("lib.util").copy(p)
  w.inventories.hub[3]=W.bee("Attuned","drone",8)
  local j=W.job(w,"recover","Attuned","convert"); w.scheduler:dispatch(j)
  eq(j.state,"WAITING"); eq(w.moves,0)
  ok(j.error:find("Cannot start this pairing in any available alveary.",1,true),j.error)
  ok(j.error:find("Selected parents: Wintry princess + Attuned drone.",1,true),j.error)
  ok(j.error:find("Wintry princess needs temperature ICY/COLD",1,true),j.error)
  ok(not j.error:find("drone needs",1,true),j.error)
end)
