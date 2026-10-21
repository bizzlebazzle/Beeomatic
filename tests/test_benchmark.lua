local W=require("tests.mocks.world"); local ME=require("tests.mocks.me")
local O=require("tests.mocks.openos"); local U=require("lib.util"); local B=require("lib.bees")

local function seed(w,species)
  w:addStock(ME.bee(species,"princess")); w:addStock(ME.bee(species,"drone"))
end
local function driver(w,files,interrupt)
  local cycles,pulls=0,0
  require("event").pull=function(seconds)
    if seconds==0 then return end
    pulls=pulls+1; assert(pulls<100,"benchmark did not terminate")
    local state=assert(load(files["/project/data/state.lua"]))()
    for _,j in ipairs(state.jobs or {}) do if j.state=="RUNNING" then
      if interrupt then return "interrupted" end
      local name=j.expectedPrincess.individual.active.species.name
      w:finish(j.machine,ME.bee(name,"princess",1,true),ME.bee(name,"drone",4,true)); cycles=cycles+1
    end end
    if w.inventories.analyser[1] then w:finishScan() end
    w:tick(); w.time=w.time+1
  end
  return function() return cycles end
end

test("benchmark automatically profiles exactly one stable cycle and scans both offspring castes back into ME",function()
  for _,species in ipairs({"Forest","Spirit"}) do
    local w=ME.new(); seed(w,species)
    w.c.minDrones=1000; w.c.confirmCycles=7
    O.with(w,function(files)
      files["/project/data/config.lua"]="return "..U.encode(w.c)
      local cycles=driver(w,files)
      local _,why=require("lib.cli").main("/project",{"benchmark"}); eq(why,nil,why)
      local state=assert(load(files["/project/data/state.lua"]))()
      ok(state.finished); eq(#state.jobs,1); eq(state.jobs[1].mode,"benchmark")
      eq(state.jobs[1].cycles,1); eq(state.jobs[1].state,"DONE"); eq(cycles(),1)
      eq(state.target,"test.species"..species:lower())
      eq(state.scan,nil); eq(state.pending,nil); eq(next(state.meRequests),nil); eq(next(state.meBatches),nil)
      local princess,drones=0,0
      for _,s in pairs(w.cells) do
        ok(B.scanned(s)); eq(s.individual.active.species.name,species)
        if B.kind(s)=="princess" then princess=princess+s.size else drones=drones+s.size end
      end
      eq(princess,1); eq(drones,4)
      for _,inventory in ipairs({w.inventories.a,w.inventories.b,w.inventories.analyser}) do
        for slot=1,inventory.size do eq(inventory[slot],nil) end
      end
      local report=assert(files["/project/data/profile.log"])
      for _,label in ipairs({"Command: benchmark","Outcome: returned","scanner.step","inventory.move","transferItem","Large-string cache:","NBT cache:","checkpoint.catalogue"}) do
        ok(report:find(label,1,true),label)
      end
      eq(state.aeCatalog,nil)
      ok(next(assert(load(files["/project/data/catalogue.lua"]))()))
      eq(files["/project/data/worker.lock"],nil); eq(files["/project/data/crash.log"],nil)
    end)
  end
end)

test("known-catalogue benchmark combines checkpoints and saves intent before every transfer",function()
  local w=ME.new(); seed(w,"Forest")
  w.state.aeCatalog={}
  for key,stack in pairs(w.cells) do w.state.aeCatalog[key]=U.copy(stack.individual) end
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local cycles=driver(w,files)
    for _,address in ipairs({"tp1","tp2","tp-scan"}) do
      local proxy=w.proxies[address]; local transfer=proxy.transferItem
      proxy.transferItem=function(from,to,count,slot,destSlot)
        local saved=assert(load(files["/project/data/state.lua"]))(); local tx=saved.pending
        ok(tx); eq(tx.phase,"INTENT"); eq(tx.source.side,from); eq(tx.dest.side,to)
        eq(tx.slot,slot); eq(tx.destSlot,destSlot); eq(tx.count,count)
        if tx.scanning then eq(saved.scan.phase,"INSERTING")
        elseif tx.owner=="scanner" then eq(saved.scan.phase,"RETURNING") end
        return transfer(from,to,count,slot,destSlot)
      end
    end
    local P=require("lib.persistence"); local save=P.save; local writes=0
    P.save=function(self,value)
      if self.path=="/project/data/state.lua" then writes=writes+1 end
      return save(self,value)
    end
    local success,result,why=pcall(require("lib.cli").main,"/project",{"benchmark"})
    P.save=save
    ok(success,result); eq(why,nil,why)
    local state=assert(load(files["/project/data/state.lua"]))()
    eq(writes,58); eq(w.moves,8); eq(cycles(),1); ok(state.finished)
  end)
end)

test("interrupted benchmark resumes the same cycle without another mating",function()
  local w=ME.new(); seed(w,"Forest")
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    driver(w,files,true)
    local _,why=require("lib.cli").main("/project",{"benchmark"}); eq(why,nil,why)
    local state=assert(load(files["/project/data/state.lua"]))()
    eq(state.jobs[1].state,"RUNNING"); eq(state.jobs[1].cycles,1)
    local cycles=driver(w,files)
    _,why=require("lib.cli").main("/project",{"resume","--profile"}); eq(why,nil,why)
    state=assert(load(files["/project/data/state.lua"]))()
    ok(state.finished); eq(state.jobs[1].cycles,1); eq(cycles(),1)
  end)
end)

test("benchmark rejects mixed genes protected templates and incompatible climates",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local ep=w.c.storage.endpoints[1]
  local p=W.bee("Forest","princess"); local d=W.bee("Forest","drone")
  local j=W.job(w,"bench","benchmark","benchmark")
  local items={{endpoint=ep,slot=1,stack=p},{endpoint=ep,slot=2,stack=d}}
  for _,change in ipairs({"mixed","different","climate","template"}) do
    local bad=U.copy(items)
    if change=="mixed" then bad[2].stack.individual.inactive.fertility=2
    elseif change=="different" then
      bad[2].stack.individual.active.fertility=2; bad[2].stack.individual.inactive.fertility=2
    elseif change=="climate" then w.c.alvearies[1].environment.temperature="HELLISH"
    else w.c.templates={enabled=true,identity=B.identity(d),reserve=1} end
    local princess,drone,why=w.scheduler:select(j,bad)
    eq(princess,nil); eq(drone,nil); ok(why:find("stable",1,true))
    w.c.alvearies[1].environment.temperature="NORMAL"; w.c.templates={enabled=false}
  end
  local princess,drone=w.scheduler:select(j,items); eq(princess,items[1]); eq(drone,items[2])
end)

test("benchmark refuses unfinished work and requires an automated scanner",function()
  local w=ME.new(); seed(w,"Forest"); W.job(w,"existing","Forest")
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local before=files["/project/data/state.lua"]
    raises(function() require("lib.cli").main("/project",{"benchmark"}) end,"Existing work")
    eq(files["/project/data/state.lua"],before); eq(w.moves,0)
  end)
  w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    raises(function() require("lib.cli").main("/project",{"benchmark"}) end,"automated scanner")
    eq(w.moves,0)
  end)
end)

test("benchmark reports missing stable stock without breeding an incompatible pair",function()
  local w=ME.new(); w.hideGenomes=false
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Forest","drone",8))
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    driver(w,files)
    local _,why=require("lib.cli").main("/project",{"benchmark"}); eq(why,nil,why)
    local state=assert(load(files["/project/data/state.lua"]))()
    ok(not state.finished); eq(state.jobs[1].cycles,0)
    ok(state.jobs[1].error:find("stable princess/drone pair",1,true))
    eq(w.moves,0); eq(files["/project/data/worker.lock"],nil)
    ok(files["/project/data/profile.log"])
  end)
end)
