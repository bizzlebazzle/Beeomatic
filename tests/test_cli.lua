local W=require("tests.mocks.world"); local O=require("tests.mocks.openos"); local U=require("lib.util")
local function withAnswer(answer,fn)
  local read=io.read; io.read=function() return answer end
  local success,err=xpcall(fn,debug.traceback); io.read=read
  assert(success,err)
end

test("cancel clears a stranded request and allows a new breeding request",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.confirmCycles=1; w.c.minDrones=2
  W.job(w,"old-plan","Forest","populate")
  w.state.pendingRequest={target="unwanted",mode="breed",flags={}}
  w.state.stopped=false
  w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",8)
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    require("lib.cli").main("/project",{"cancel"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    eq(state.pendingRequest,nil); ok(state.stopped); eq(state.jobs,w.state.jobs); eq(w.moves,0)
    ok(table.concat(out,"\n"):find("Cancelled pending request for unwanted",1,true))
    local _,err=require("lib.cli").main("/project",{"populate","spirit","2"})
    eq(err,nil,err)
    state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished); eq(state.target,"test.speciesspirit")
  end)
end)

test("cancel preserves pending scanner and transfer recovery records without moving bees",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.state.pendingRequest={target="unwanted",mode="breed"}
  w.state.scan={phase="PROCESSING",count=8,started=10}
  w.state.pending={phase="INTENT",owner="scanner"}
  w.state.pendingExternal={phase="INTENT"}
  w.state.meRequests={scanner={phase="READY"}}
  w.state.meBatches={batch={owner="scanner",count=8}}
  w.state.reservations={slot={owner="scanner"}}
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    require("lib.cli").main("/project",{"cancel"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    for _,key in ipairs({"scan","pending","pendingExternal","meRequests","meBatches","reservations","jobs","transactions"}) do
      eq(state[key],w.state[key],key)
    end
    eq(state.pendingRequest,nil); eq(w.moves,0)
    ok(table.concat(out,"\n"):find("recovery records retained",1,true))
  end)
end)

test("cancel refuses a running worker or live job assignment without rewriting state",function()
  for _,blocked in ipairs({"worker","machine","job"}) do
    local w=W.new(); w:addMachine("a"); w:build()
    w.state.pendingRequest={target="unwanted",mode="breed"}
    if blocked=="machine" then w.state.machines.a={job="old"} end
    if blocked=="job" then local j=W.job(w,"old","Forest"); j.machine="a" end
    O.with(w,function(files)
      files["/project/data/config.lua"]="return "..U.encode(w.c)
      local before="return "..U.encode(w.state); files["/project/data/state.lua"]=before
      if blocked=="worker" then files["/project/data/worker.lock"]="running" end
      local _,err=require("lib.cli").main("/project",{"cancel"})
      ok(err); eq(files["/project/data/state.lua"],before); eq(w.moves,0)
    end)
  end
end)

test("cancel discards an idle blocked plan and releases its logical ownership",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"old","Forest")
  w.state.reservations={slot={owner="old"},scan={owner="scanner"}}
  w.state.meBatches={batch={owner="old"},scan={owner="scanner"}}
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    require("lib.cli").main("/project",{"cancel"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    eq(#state.jobs,0); ok(state.stopped); eq(state.reservations.slot,nil)
    ok(state.reservations.scan); eq(w.moves,0)
    ok(table.concat(out,"\n"):find("Cancelled saved breeding plan",1,true))
  end)
end)

test("offline stop actually drains a blocked idle plan without dispatching it",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"old","Forest")
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local _,err=require("lib.cli").main("/project",{"stop"}); eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.stopped); eq(w.moves,0); eq(files["/project/data/worker.lock"],nil)
  end)
end)

test("cancel refuses unresolved transfers in an existing plan",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"old","Forest")
  w.state.pending={owner="old",phase="INTENT"}
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local before="return "..U.encode(w.state); files["/project/data/state.lua"]=before
    local _,err=require("lib.cli").main("/project",{"cancel"})
    ok(err); eq(files["/project/data/state.lua"],before); eq(w.moves,0)
  end)
end)

test("a new request after draining stopped jobs completes without resuming the old plan",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.confirmCycles=1; w.c.minDrones=2
  local old=W.job(w,"old-plan","Forest","populate")
  old.state="PAUSED"; old.previous="PREPARING"
  w.state.stopped=true; w.state.target="forest"
  w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",8)
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local _,err=require("lib.cli").main("/project",{"populate","spirit","2"})
    eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished,table.concat(out,"\n")); eq(state.target,"test.speciesspirit")
    eq(state.pendingRequest,nil); eq(require("lib.jobs").find(state,"old-plan"),nil)
    eq(files["/project/data/crash.log"],nil); eq(files["/project/data/worker.lock"],nil)
  end)
end)

test("resume recovers a pending request stranded by the old stopped-work replacement bug",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.confirmCycles=1; w.c.minDrones=2
  W.job(w,"old-plan","Forest","populate")
  w.state.target="forest"; w.state.stopped=false; w.state.finished=false
  w.state.pendingRequest={target="spirit",mode="populate",count=2,flags={}}
  w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",8)
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local _,err=require("lib.cli").main("/project",{"resume"})
    eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished,table.concat(out,"\n")); eq(state.target,"test.speciesspirit"); eq(state.pendingRequest,nil)
    eq(require("lib.jobs").find(state,"old-plan"),nil); eq(files["/project/data/worker.lock"],nil)
  end)
end)

test("worker crashes save a traceback and keep the original error visible without scrolling",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",8)
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("event").pull=function() error("simulated foreground failure") end
    local result,err=require("lib.cli").main("/project",{"breed","spirit"})
    eq(result,nil); ok(err:find("simulated foreground failure",1,true))
    local report=files["/project/data/crash.log"]
    ok(report:find("Command: breed spirit",1,true)); ok(report:find("simulated foreground failure",1,true))
    ok(report:find("stack traceback:",1,true)); eq(files["/project/data/worker.lock"],nil)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(#state.jobs>0); ok(not state.finished)
    local text=table.concat(out,"\n")
    ok(text:find("Beeomatic stopped:",1,true)); ok(text:find("Beeomatic logs --crash",1,true))
    ok(not text:find("stack traceback:",1,true))
    -- Reading diagnostics never depends on successfully loading breeding data.
    files["/project/data/state.lua"]="invalid"; files["/project/data/state.lua.bak"]="invalid"
    require("lib.cli").main("/project",{"logs","--crash","--no-pager"})
    eq(out[#out],report)
  end)
end)

test("failure to write a crash report does not mask the worker error or keep its lock",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",8)
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("event").pull=function() error("original worker failure") end
    local open=io.open
    io.open=function(path,mode)
      if path=="/project/data/crash.log" then return nil,"disk full" end
      return open(path,mode)
    end
    local success,result,err=pcall(require("lib.cli").main,"/project",{"breed","spirit"})
    io.open=open
    ok(success); eq(result,nil); ok(err:find("original worker failure",1,true))
    eq(files["/project/data/worker.lock"],nil)
    local text=table.concat(out,"\n")
    ok(text:find("original worker failure",1,true)); ok(text:find("Could not save crash report:",1,true))
    ok(text:find("disk full",1,true))
  end)
end)

test("crash logs explain when no crash report exists",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(_,out)
    require("lib.cli").main("/project",{"logs","--crash"})
    ok(table.concat(out,"\n"):find("Older versions did not save tracebacks.",1,true))
  end)
end)
test("plan reports unavailable stock without throwing a traceback or moving bees",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.recipes={spirit={W.route("Unusual","Aware"),W.route("Unusual","Mystical")}}
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local result,err=require("lib.cli").main("/project",{"plan","spirit"})
    eq(result,nil); ok(err:find("Cannot plan spirit from verified stock.",1,true))
    local text=table.concat(out,"\n"); ok(not text:find("stack traceback",1,true))
    ok(text:find("species: unusual",1,true)); eq(w.moves,0)
    eq(files["/project/data/worker.lock"],nil)
  end)
end)

test("plan prompts for raw bees even when verified target stock is sufficient and decline moves nothing",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",8)
  local raw=W.bee("Forest","drone",16); raw.individual=nil; w.inventories.hub[3]=raw
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    withAnswer("n",function() require("lib.cli").main("/project",{"plan","spirit"}) end)
    local text=table.concat(out,"\n")
    ok(text:find("scan all unscanned bees now? [y/N]",1,true)); ok(text:find("Stock present: Spirit",1,true))
    eq(w.moves,0); eq(files["/project/data/state.lua"],nil)
  end)
end)

test("plan scans all raw castes then plans from refreshed ME stock without creating jobs",function()
  local ME=require("tests.mocks.me"); local w=ME.new()
  w:addStock(ME.bee("Spirit","princess",1,true)); w:addStock(ME.bee("Spirit","drone",8,true))
  w:addStock(ME.bee("Forest","queen",1,true))
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local event=require("event"); local pull=event.pull; local waits=0
    event.pull=function(seconds)
      ok(seconds<=0.5,"scan loop should not use the five-second worker delay")
      waits=waits+1; return pull(seconds)
    end
    withAnswer("yes",function() require("lib.cli").main("/project",{"plan","spirit"}) end)
    local text=table.concat(out,"\n")
    ok(text:find("Scanning complete.",1,true),text); ok(text:find("Stock present: Spirit",1,true),text)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    eq(#state.jobs,0); eq(state.pendingRequest,nil); eq(state.scan,nil); eq(files["/project/data/worker.lock"],nil); ok(waits>0)
    for _,s in pairs(w.cells) do ok(require("lib.bees").scanned(s)) end
  end)
end)

test("plan scan failure preserves progress and can continue on a later plan",function()
  local ME=require("tests.mocks.me"); local w=ME.new(); w.c.scanner.timeout=1
  w:addStock(ME.bee("Spirit","princess",1,true)); w:addStock(ME.bee("Spirit","drone",8,true))
  local finish=w.finishScan; w.finishScan=function() end
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    withAnswer("y",function() require("lib.cli").main("/project",{"plan","spirit"}) end)
    ok(table.concat(out,"\n"):find("Scanning paused:",1,true))
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.scan); eq(files["/project/data/worker.lock"],nil); eq(#state.jobs,0)
    w.finishScan=finish; w:finishScan()
    withAnswer("y",function() require("lib.cli").main("/project",{"plan","spirit"}) end)
    local text=table.concat(out,"\n"); ok(text:find("Scanning complete.",1,true),text)
    ok(text:find("Stock present: Spirit",1,true),text)
  end)
end)

test("plan cannot scan while another worker holds the lock",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local raw=W.bee("Forest","drone",16); raw.individual=nil; w.inventories.hub[1]=raw
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/worker.lock"]="other-worker"
    withAnswer("y",function() require("lib.cli").main("/project",{"plan","spirit"}) end)
    ok(table.concat(out,"\n"):find("A worker is running",1,true)); eq(w.moves,0)
    eq(files["/project/data/worker.lock"],"other-worker")
  end)
end)

test("status reads each housing's live flower requirements without rewriting worker state",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build()
  w.inventories.a[4]=W.bee("Forest","queen",1,nil,{flowerProvider="flowers"})
  w.inventories.a[2]=W.bee("Wintry","drone",2,nil,{flowerProvider="snow"})
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return {jobs={},machines={}}"
    require("lib.cli").main("/project",{"status","--verbose"})
    local text=table.concat(out,"\n")
    ok(text:find("queen: Forest | Flowers required: flowers",1,true))
    ok(text:find("drone: Wintry | Flowers required: snow",1,true))
    ok(text:find("Bees: empty",1,true)); eq(w.moves,0)
    eq(files["/project/data/state.lua"],"return {jobs={},machines={}}")
  end)
end)
test("status reports unknown flowers for raw bees and isolates missing housings",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build()
  local s=W.bee("Forest","princess"); s.individual.active=nil; s.individual.inactive=nil; s.individual.isAnalyzed=false
  w.inventories.a[4]=s; w.proxies.housing2=nil
  local status=require("lib.ui.status")
  status.observe(w.state,w.c,w.components,w.inv,0)
  local text=status.render(w.state,w.c,true)
  ok(text:find("Flowers required: unknown (analyse bee)",1,true))
  ok(text:find("Bee information unavailable:",1,true)); eq(w.moves,0)
end)
test("public CLI Interface workflow scans initial drones and offspring through one station",function()
  local ME=require("tests.mocks.me"); local w=ME.new(); w.c.confirmCycles=1; w.c.minDrones=2
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8,true))
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("lib.cli").main("/project",{"populate","spirit","2"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished,require("lib.ui.status").render(state,w.c,true)); eq(state.stockPhase,"READY")
    eq(state.scan,nil); eq(state.pending,nil); eq(next(state.meRequests),nil)
    ok(table.concat(out,"\n"):find("preparing stock before planning",1,true))
  end)
end)
test("reconfiguration refuses to migrate saved unresolved movements",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode({jobs={},pendingExternal={kind="ME_EXPORT"}})
    raises(function() require("lib.cli").main("/project",{"setup","--reconfigure"}) end,"reconcile outstanding")
    eq(files["/project/data/config.lua"],"return "..U.encode(w.c))
  end)
end)

test("public CLI completes startup and breeding with chest input and automatic ME scanner returns",function()
  local ME=require("tests.mocks.me"); local B=require("lib.bees"); local w=ME.new()
  w.c.confirmCycles=1; w.c.minDrones=2
  local c=w.c.scanner; c.mode="external"; c.output=nil; c.outputSlots=nil; c.inputSlot=nil; c.isolatedVerified=nil
  w.finishScan=function(self)
    local s=assert(self.inventories.analyser[1]); self.inventories.analyser[1]=nil
    self:addStock(ME.bee(s.label:match("^(.-) %w+$"),B.kind(s),s.size))
  end
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8,true))
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("lib.cli").main("/project",{"populate","spirit","2"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished,require("lib.ui.status").render(state,w.c,true))
    eq(state.stockPhase,"READY"); eq(state.scan,nil); eq(state.pending,nil); eq(next(state.meRequests),nil)
  end)
end)
test("installer retires obsolete program files while preserving backups and user files",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/home/Test/lib/storage/base.lua"]="old storage contract"
    files["/home/Test/lib/breeders/base.lua"]="old breeder contract"
    files["/home/Test/tools/probe.lua"]="old probe"
    files["/home/Test/tools/custom.lua"]="user helper"
    files["/home/Test/data/state.lua"]="user state"
    assert(loadfile("install.lua"))("/home/Test")
    eq(files["/home/Test/lib/storage/base.lua"],nil)
    eq(files["/home/Test/lib/storage/base.lua.previous"],"old storage contract")
    eq(files["/home/Test/lib/breeders/base.lua.previous"],"old breeder contract")
    eq(files["/home/Test/tools/probe.lua.previous"],"old probe")
    eq(files["/home/Test/tools/custom.lua"],"user helper"); eq(files["/home/Test/data/state.lua"],"user state")
  end)
end)
test("public Beeomatic breed spirit completes through CLI persistence and foreground events",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build(); w.c.minDrones=4
  for slot=1,10 do w.inventories.hub[slot]=W.bee(slot<=5 and "Forest" or "Meadows","princess") end
  w.inventories.hub[11]=W.bee("Forest","drone",64); w.inventories.hub[12]=W.bee("Meadows","drone",64)
  w.recipes={spirit={W.route("Ethereal","Aware")},ethereal={W.route("Forest","Meadows")},aware={W.route("Forest","Meadows")}}
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("lib.cli").main("/project",{"BrEeD","SpIrIt"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished,require("lib.ui.status").render(state,w.c,true)); eq(state.pending,nil); eq(files["/project/data/worker.lock"],nil)
    ok(table.concat(out,"\n"):find("BEEOMATIC | Complete",1,true))
    require("lib.cli").main("/project",{"logs"})
    ok(table.concat(out,"\n"):find("stable stock archived",1,true))
    require("lib.cli").main("/project",{"STATUS","--VERBOSE"})
  end)
end)
test("installer copies manifest, preserves data and creates valid command launcher",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/home/Test/data/state.lua"]="user state"
    assert(loadfile("install.lua"))("/home/Test")
    eq(files["/home/Test/data/state.lua"],"user state")
    for _,path in ipairs(assert(loadfile("manifest.lua"))()) do ok(files["/home/Test/"..path],"missing installed "..path) end
    local destination,arguments
    local launcherPackage={path="/lib/?.lua"}
    local launcher=assert(load(files["/usr/bin/Beeomatic"],"=launcher","t",{
      package=launcherPackage,require=function(name)
        eq(name,"lib.cli")
        return {main=function(root,args) destination=root; arguments=args end}
      end}))
    launcher("breed","spirit"); eq(destination,"/home/Test"); eq(arguments,{"breed","spirit"})
    eq(launcherPackage.path,"/home/Test/?.lua;/home/Test/?/init.lua;/lib/?.lua")
    files["/home/Test/lib/cli.lua"]="older CLI"
    assert(loadfile("install.lua"))("/home/Test")
    eq(files["/home/Test/data/state.lua"],"user state"); eq(files["/home/Test/lib/cli.lua.previous"],"older CLI")
  end)
end)
test("installer refuses to overwrite a running installation",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/home/Test/data/worker.lock"]="active"
    raises(function() assert(loadfile("install.lua"))("/home/Test") end,"stop Beeomatic")
    eq(files["/home/Test/Beeomatic.lua"],nil)
  end)
end)

test("installed command loads real modules from its recorded root outside the install directory",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out)
    local root="/home/Custom Bees"
    assert(loadfile("install.lua"))(root)
    local env=setmetatable({package={path="/lib/?.lua",loaded={}}},{__index=_G})
    env.require=function(name)
      if name:sub(1,4)~="lib." then return require(name) end
      if env.package.loaded[name] then return env.package.loaded[name] end
      local modulePath=name:gsub("%.","/")
      for pattern in env.package.path:gmatch("[^;]+") do
        local path=pattern:gsub("%?",modulePath)
        -- Model an OpenOS shell whose working directory is /home.
        if path:sub(1,1)~="/" then path="/home/"..path end
        if files[path] then
          local result=assert(load(files[path],"="..path,"t",env))(name)
          env.package.loaded[name]=result
          return result
        end
      end
      error("module not found in installed files: "..name)
    end
    assert(load(files["/usr/bin/Beeomatic"],"=launcher","t",env))("help")
    ok(env.package.loaded["lib.cli"])
    ok(table.concat(out,"\n"):find("Beeomatic setup",1,true))
  end)
end)

local function failFlush()
  local previous=io.open
  io.open=function(path,mode)
    local f,err=previous(path,mode)
    if f and path:sub(-4)==".tmp" then
      f.flush=function() return nil,"disk full" end
    end
    return f,err
  end
end

test("installer preserves the previous program when flushing fails",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/home/Test/Beeomatic.lua"]="previous program"
    failFlush()
    raises(function() assert(loadfile("install.lua"))("/home/Test") end,"disk full")
    eq(files["/home/Test/Beeomatic.lua"],"previous program")
    eq(files["/home/Test/Beeomatic.lua.previous"],nil)
  end)
end)

test("state saver preserves the previous generation when flushing fails",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out,fs)
    local path="/home/Test/data/state.lua"
    files[path]='return {marker="previous"}'
    failFlush()
    raises(function() require("lib.persistence").new(path,fs):save({marker="next"}) end,"disk full")
    eq(files[path],'return {marker="previous"}')
    eq(files[path..".bak"],nil)
  end)
end)

test("offline installer locates manifest from an absolute OpenOS chunk name",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    for _,path in ipairs(assert(loadfile("manifest.lua"))()) do
      local f=assert(io.open(path,"rb")); files["/release/"..path]=f:read("*a"); f:close()
    end
    assert(loadfile("/release/install.lua"))("/home/Test")
    ok(files["/home/Test/lib/cli.lua"]); ok(files["/usr/bin/Beeomatic"])
  end)
end)

test("application launcher resolves both OpenOS and native Lua source prefixes",function()
  local f=assert(io.open("Beeomatic.lua","rb")); local code=f:read("*a"); f:close()
  for _,prefix in ipairs({"=","@"}) do
    local root,args
    local env=setmetatable({package={path="original"},require=function(name)
      eq(name,"lib.cli")
      return {main=function(r,a) root=r; args=a end}
    end},{__index=_G})
    assert(load(code,prefix.."/home/Beeomatic/Beeomatic.lua","t",env))("doctor")
    eq(root,"/home/Beeomatic"); eq(args,{"doctor"})
    ok(env.package.path:sub(1,6)=="/home/")
  end
end)

test("saved five-second configurations run the foreground worker at half-second intervals",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.confirmCycles=1
  w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","drone",8)
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local event=require("event"); local pull=event.pull; local waits=0
    event.pull=function(seconds)
      ok(seconds<=0.5,"worker still sleeping for the old general polling interval")
      waits=waits+1; return pull(seconds)
    end
    local _,err=require("lib.cli").main("/project",{"populate","spirit","16"})
    eq(err,nil,err); ok(waits>0)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished)
  end)
end)

test("pending-request scanner polls do not rescan global ME stock for an existing batch",function()
  local ME=require("tests.mocks.me"); local w=ME.new(); w.c.confirmCycles=1; w.c.minDrones=2
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8,true))
  local Storage=require("lib.storage.me_interface"); local scan=Storage.scan; local pendingScans=0
  Storage.scan=function(self)
    if self.state.pendingRequest and self.state.scan then pendingScans=pendingScans+1 end
    return scan(self)
  end
  local success,why=pcall(function()
    O.with(w,function(files)
      files["/project/data/config.lua"]="return "..U.encode(w.c)
      local _,err=require("lib.cli").main("/project",{"populate","spirit","2"}); eq(err,nil,err)
      local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
      ok(state.finished); eq(pendingScans,0)
    end)
  end)
  Storage.scan=scan; assert(success,why)
end)
