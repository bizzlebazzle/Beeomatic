local W=require("tests.mocks.world"); local O=require("tests.mocks.openos"); local U=require("lib.util")

test("startup analysis waits do not repeatedly checkpoint an unchanged progress message",function()
  local ME=require("tests.mocks.me"); local w=ME.new()
  w:addStock(ME.bee("Spirit","drone",8,true))
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local P=require("lib.persistence"); local save=P.save; local writes,waits,lastWrites=0,0
    P.save=function(self,...)
      if self.path=="/project/data/state.lua" then writes=writes+1 end
      return save(self,...)
    end
    require("event").pull=function(seconds)
      if seconds==0 then return end
      local source=files["/project/data/state.lua"]
      local state=source and assert(load(source))()
      if state and state.scan and state.scan.phase=="PROCESSING" and not next(state.meRequests)
        and state.error=="Shared scanner processing reserved batch" then
        waits=waits+1
        if waits>1 then eq(writes,lastWrites,"unchanged analysis wait wrote another checkpoint") end
        lastWrites=writes
        if waits==4 then return "interrupted" end
      end
      w:tick(); w.time=w.time+0.1
    end
    local success,_,why=pcall(require("lib.cli").main,"/project",{"benchmark"})
    P.save=save
    ok(success,why); eq(why,nil); eq(waits,4)
    local state=assert(load(files["/project/data/state.lua"]))()
    eq(state.scan.phase,"PROCESSING"); ok(state.pendingRequest)
  end)
end)
local function withAnswer(answer,fn)
  local read=io.read; io.read=function() return answer end
  local success,err=xpcall(fn,debug.traceback); io.read=read
  assert(success,err)
end

test("doctor confirmation prompts exclude optional moon bonuses",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local bonus="Better success between the Waxing Crescent and Waxing Gibbous."
  local req="Requires Diamond as a foundation"
  W.job(w,"one","Arcane","breed",W.route("Esoteric","Mysterious",8,{bonus,req}))
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    withAnswer("confirmed",function() require("lib.cli").main("/project",{"doctor","--confirm","a"}) end)
    local saved=assert(load(files["/project/data/config.lua"]))()
    eq(saved.alvearies[1].confirmed[req],true); eq(saved.alvearies[1].confirmed[bonus],nil)
    local text=table.concat(out,"\n")
    ok(text:find(req,1,true)); ok(not text:find(bonus,1,true),text); eq(w.moves,0)
  end)
end)

test("species commands accept quoted and unquoted multiword names and preserve flags",function()
  local CLI=require("lib.cli")
  for _,cmd in ipairs({"plan","breed","convert","imprint","populate"}) do
    for _,words in ipairs({{"End","Dust"},{"End Dust"},{"Spirit"},{"test.speciesenddust"}}) do
      local args={cmd,"--verbose"}
      for _,word in ipairs(words) do args[#args+1]=word end
      args[#args+1]="--noFinalImprint"
      if cmd=="populate" then args[#args+1]="32" end
      args[#args+1]="--no-pager"
      local a,f=CLI.parse(args)
      local expected={cmd,table.concat(words," ")}
      if cmd=="populate" then expected[3]="32" end
      eq(a,expected); ok(f.verbose); ok(f.nofinalimprint); ok(f["no-pager"])
    end
  end
  eq(CLI.parse({"bees","inspect","End","Dust"}),{"bees","inspect","End Dust"})
  eq(CLI.parse({"PLAN","END","DUST"}),{"PLAN","END DUST"})
  eq(CLI.parse({"plan"}),{"plan"})
  eq(CLI.parse({"populate","End Dust"}),{"populate","End Dust"})
  eq(CLI.parse({"alveary","rename","a","Cold","room"}),{"alveary","rename","a","Cold","room"})
  eq(CLI.parse({"doctor","--interface","scanner_port"}),{"doctor","scanner_port"})
end)

test("plan resolves the full unquoted End Dust species from verified stock",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.inventories.hub[1]=W.bee("End Dust","princess")
  w.inventories.hub[2]=W.bee("End Dust","drone",64)
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local _,err=require("lib.cli").main("/project",{"plan","end","dust","--no-pager"})
    eq(err,nil,err)
    local text=table.concat(out,"\n")
    ok(text:find("End Dust",1,true)); ok(not text:find("Cannot plan",1,true)); eq(w.moves,0)
  end)
end)

test("bees inspect matches a full multiword name and excludes other species",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.inventories.hub[1]=W.bee("End Dust","princess")
  w.inventories.hub[2]=W.bee("End","drone",8)
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("lib.cli").main("/project",{"bees","inspect","end","dust"})
    eq(#out,1); ok(out[1]:find("End Dust",1,true)); eq(w.moves,0)
  end)
end)

test("worker requests retain the full multiword target and population count",function()
  for _,cmd in ipairs({"breed","convert","imprint","populate"}) do
    local w=W.new(); w:addMachine("a"); w:build()
    O.with(w,function(files)
      files["/project/data/config.lua"]="return "..U.encode(w.c)
      -- Stop during recovery so the persisted request can be checked before planning.
      local Scheduler=require("lib.scheduler"); local recover=Scheduler.recover
      Scheduler.recover=function() error("test recovery interruption") end
      local args={cmd,"end","dust","--noFinalImprint"}
      if cmd=="populate" then args[#args+1]="32" end
      local success,why=pcall(require("lib.cli").main,"/project",args)
      Scheduler.recover=recover; assert(success,why)
      local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
      eq(state.pendingRequest.target,"end dust"); eq(state.pendingRequest.mode,cmd)
      eq(state.pendingRequest.count,cmd=="populate" and 32 or nil)
      ok(state.pendingRequest.flags.nofinalimprint)
    end)
  end
end)

test("doctor NBT check reports a blocked selection without running recovery or moving stock",function()
  local ME=require("tests.mocks.me"); local w=ME.new(); local s=ME.bee("Spirit","drone",8); w:addStock(s)
  w.state.scan={phase="REQUESTING",item={stack=s}}
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local before=files["/project/data/state.lua"]
    require("lib.cli").main("/project",{"doctor","--nbt"})
    ok(table.concat(out,"\n"):find("NBT=true identity=true",1,true))
    eq(files["/project/data/state.lua"],before); eq(w.moves,0)
    files["/project/data/worker.lock"]="busy"
    raises(function() require("lib.cli").main("/project",{"doctor","--nbt"}) end,"worker")
  end)
end)

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
    eq(state.pendingRequest,nil); ok(state.cancelled); eq(#state.jobs,0); eq(w.moves,0)
    ok(table.concat(out,"\n"):find("Cancelled all work",1,true))
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
    for _,key in ipairs({"scan","pending","pendingExternal","meBatches","reservations","transactions"}) do
      eq(state[key],w.state[key],key)
    end
    eq(state.pendingRequest,nil); eq(w.moves,0)
    eq(state.meRequests.scanner.phase,"RETURNING"); ok(state.cancelled)
    ok(table.concat(out,"\n"):find("Cancelled all work",1,true))
  end)
end)

test("cancel sends a mailbox request to a running worker without loading its state",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="unreadable config"
    files["/project/data/state.lua"]="unreadable state"
    files["/project/data/worker.lock"]="running"
    require("lib.cli").main("/project",{"cancel"})
    eq(files["/project/data/state.lua"],"unreadable state")
    local request=assert(load(files["/project/data/control.lua"],"=control","t",{}))()
    eq(request.action,"cancel"); ok(table.concat(out,"\n"):find("Requested cancel",1,true))
  end)
end)

test("cancel abandons every assigned job state without requiring a working queen",function()
  for _,phase in ipairs({"WAITING","PREPARING","RUNNING","COLLECTING","ASSESSING","PAUSED"}) do
    local w=W.new(); w:addMachine("a"); w:build()
    local j=W.job(w,"old","Attuned"); j.state=phase; j.machine="a"; j.previous="RUNNING"
    w.state.machines.a={job=j.id,state=phase}; w.state.error="database did not preserve exact bee NBT"
    w.state.pendingRequest={target="unwanted",mode="breed"}
    w.proxies.housing1.canBreed=function() error("missing dragon egg flower") end
    O.with(w,function(files,out)
      files["/project/data/config.lua"]="return "..U.encode(w.c)
      files["/project/data/state.lua"]="return "..U.encode(w.state)
      local _,err=require("lib.cli").main("/project",{"cancel"}); eq(err,nil,err)
      local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
      eq(#state.jobs,0); eq(state.machines,{}); eq(state.pendingRequest,nil); eq(state.error,nil)
      ok(state.cancelled); ok(state.stopped); eq(w.moves,0)
      local text=table.concat(out,"\n"); ok(text:find("Cancelled all work",1,true))
      ok(not text:find("BEEOMATIC |",1,true)); ok(not text:find("use Beeomatic stop",1,true))
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
    eq(state.reservations,{}); eq(state.meBatches,{}); eq(w.moves,0)
    ok(table.concat(out,"\n"):find("Cancelled all work",1,true))
  end)
end)

test("stop is an immediate cancel alias and never opens a worker screen",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"old","Forest")
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local _,err=require("lib.cli").main("/project",{"stop"}); eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.cancelled); eq(#state.jobs,0); eq(w.moves,0); eq(files["/project/data/worker.lock"],nil)
  end)
end)

test("cancel retains unresolved transfer evidence while discarding the plan",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"old","Forest")
  w.state.pending={owner="old",phase="INTENT"}
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local before="return "..U.encode(w.state); files["/project/data/state.lua"]=before
    local _,err=require("lib.cli").main("/project",{"cancel"})
    eq(err,nil); local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    eq(#state.jobs,0); ok(state.cancelled); eq(state.pending,w.state.pending); eq(w.moves,0)
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
    require("event").pull=function(seconds) if seconds~=0 then error("simulated foreground failure") end end
    local result,err=require("lib.cli").main("/project",{"breed","spirit"})
    eq(result,nil); ok(err:find("simulated foreground failure",1,true))
    local report=files["/project/data/crash.log"]
    ok(report:find("Phase: ",1,true),report)
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
    eq(result,nil); ok(err:find("Cannot plan Spirit from verified stock.",1,true))
    local text=table.concat(out,"\n"); ok(not text:find("stack traceback",1,true))
    ok(text:find("Unusual: no mutation recipe reported",1,true)); eq(w.moves,0)
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

test("public CLI completes startup and breeding with input/output chests and verified ME scanner deposits",function()
  local ME=require("tests.mocks.me"); local B=require("lib.bees"); local w=ME.new()
  w.c.confirmCycles=1; w.c.minDrones=2
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


test("alveary rename and list expose the saved name and climate",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local id=w.c.alvearies[1].id
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("lib.cli").main("/project",{"alveary","rename",id,"Cold","room"})
    local c=assert(load(files["/project/data/config.lua"],"=config","t",{}))()
    eq(c.alvearies[1].name,"Cold room"); eq(c.alvearies[1].address,w.c.alvearies[1].address)
    require("lib.cli").main("/project",{"alveary","list"})
    local text=table.concat(out,"\n")
    ok(text:find("Cold room",1,true)); ok(text:find("NORMAL / NORMAL",1,true))
  end)
end)

test("alveary configure refuses an assigned machine or running worker",function()
  for _,blocked in ipairs({"job","machine","worker"}) do
    local w=W.new(); w:addMachine("a"); w:build()
    local id=w.c.alvearies[1].id
    if blocked=="job" then W.job(w,"old","Forest").machine=id end
    if blocked=="machine" then w.state.machines[id]={job="old"} end
    O.with(w,function(files)
      local before="return "..U.encode(w.c); files["/project/data/config.lua"]=before
      files["/project/data/state.lua"]="return "..U.encode(w.state)
      if blocked=="worker" then files["/project/data/worker.lock"]="running" end
      raises(function() require("lib.cli").main("/project",{"alveary","configure",id}) end,blocked=="worker" and "worker lock" or "machine has saved work")
      eq(files["/project/data/config.lua"],before); eq(w.moves,0)
    end)
  end
end)


test("alveary configure persists changed climate and resume uses it",function()
  local w=W.new(); w:addMachine("a","HOT"); w:build(); w.c.confirmCycles=1; w.c.minDrones=2
  local id=w.c.alvearies[1].id
  W.job(w,"old","Spirit","populate")
  w.inventories.hub[1]=W.bee("Spirit","princess")
  w.inventories.hub[2]=W.bee("Spirit","drone",8)
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local answers={"Working room","NORMAL","","",""}; local n=0; local read=io.read
    io.read=function() n=n+1; return answers[n] end
    local success,why=pcall(require("lib.cli").main,"/project",{"alveary","configure",id})
    io.read=read; assert(success,why)
    local c=assert(load(files["/project/data/config.lua"],"=config","t",{}))()
    eq(c.alvearies[1].name,"Working room"); eq(c.alvearies[1].environment.temperature,"NORMAL")
    local _,err=require("lib.cli").main("/project",{"resume"}); eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished)
  end)
end)

test("stop cancels an active queen immediately and leaves the bee untouched",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","drone",8)
  local j=W.job(w,"old","Spirit","populate"); j.count=64
  w.scheduler:dispatch(j); eq(j.state,"RUNNING")
  local moves=w.moves; local queen=U.copy(w.inventories.a[4])
  w.proxies.housing1.canBreed=function() error("cannot work without dragon egg") end
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local _,err=require("lib.cli").main("/project",{"stop"}); eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.cancelled); eq(#state.jobs,0); eq(w.moves,moves); eq(w.inventories.a[4],queen)
    raises(function() require("lib.cli").main("/project",{"resume"}) end,"Work was cancelled")
  end)
end)

test("worker mailbox commands avoid loading the full saved state",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/project/data/config.lua"]="broken config that must not be read"
    files["/project/data/state.lua"]="broken journal that must not be read"
    files["/project/data/worker.lock"]="active"
    for _,action in ipairs({"pause","stop","resume"}) do
      require("lib.cli").main("/project",{action})
      local request=assert(load(files["/project/data/control.lua"],"=control","t",{}))()
      eq(request.action,action=="stop" and "cancel" or action)
    end
    eq(files["/project/data/state.lua"],"broken journal that must not be read")
  end)
end)


test("standalone cancel permits watchdog yields and preserves unresolved transfers",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"job","Spirit")
  w.state.pending={phase="INTENT",owner="job",identity="saved evidence"}
  w.state.padding=string.rep("x",339000)
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local sleep=os.sleep; local now,yields=0,0
    require("computer").uptime=function() now=now+0.1; return now end
    require("computer").freeMemory=function() return 1360217 end
    os.sleep=function(seconds) ok(seconds>0); yields=yields+1; coroutine.yield("watchdog") end
    local thread=coroutine.create(function() require("lib.cli").main("/project",{"cancel"}) end)
    local success,why
    repeat success,why=coroutine.resume(thread) until not success or coroutine.status(thread)=="dead"
    os.sleep=sleep
    ok(success,why); ok(yields>1); eq(w.moves,0)
    local state=assert(load(files["/project/data/state.lua"]))()
    ok(state.cancelled); eq(#state.jobs,0); eq(state.pending,w.state.pending)
    eq(files["/project/data/worker.lock"],nil)
  end)
end)

test("running worker accepts cancel stop and q without draining its queen",function()
  for _,action in ipairs({"cancel","stop","q"}) do
    local w=W.new(); w:addMachine("a"); w:build()
    w.inventories.hub[1]=W.bee("Attuned","princess"); w.inventories.hub[2]=W.bee("Attuned","drone",8)
    local j=W.job(w,"old","Attuned","populate"); j.count=64; w.scheduler:dispatch(j)
    local queen=U.copy(w.inventories.a[4]); local moves=w.moves; w.obstructed=true
    O.with(w,function(files,out)
      files["/project/data/config.lua"]="return "..U.encode(w.c)
      files["/project/data/state.lua"]="return "..U.encode(w.state)
      local pulls=0
      require("event").pull=function()
        pulls=pulls+1; eq(pulls,1,"cancel should exit on the next safe point")
        if action=="q" then return "key_down",nil,113 end
        require("lib.cli").main("/project",{action}); return nil
      end
      local _,err=require("lib.cli").main("/project",{"resume"}); eq(err,nil,err)
      local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
      eq(#state.jobs,0); ok(state.cancelled); eq(state.machines,{})
      eq(w.inventories.a[4],queen); eq(w.moves,moves)
      eq(files["/project/data/worker.lock"],nil); eq(files["/project/data/control.lua"],nil)
      eq(files["/project/data/crash.log"],nil)
      ok(table.concat(out,"\n"):find("Cancelled all work",1,true))
    end)
  end
end)

test("cancel interrupts Interface stock waits and permits a fresh request after cleanup",function()
  local ME=require("tests.mocks.me"); local w=ME.new(); w.noStock=true
  w.c.confirmCycles=1; w.c.minDrones=2
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8,true))
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local event=require("event"); local pull=event.pull; local calls=0
    event.pull=function(seconds)
      if seconds==0 then return end -- target the stock wait, not startup checkpoints
      calls=calls+1; eq(calls,1)
      require("lib.cli").main("/project",{"cancel"}); return nil
    end
    local _,err=require("lib.cli").main("/project",{"populate","spirit","2"}); eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.cancelled); eq(state.pendingRequest,nil); eq(#state.jobs,0); eq(state.scan,nil)
    ok(next(state.meRequests)); for _,request in pairs(state.meRequests) do eq(request.phase,"RETURNING") end
    eq(files["/project/data/worker.lock"],nil); eq(files["/project/data/crash.log"],nil)
    w.noStock=false; event.pull=pull
    _,err=require("lib.cli").main("/project",{"populate","spirit","2"}); eq(err,nil,err)
    state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished); eq(state.cancelled,nil); eq(state.cancelCleanup,nil)
  end)
end)

test("cancel stops routing gates even with missing hardware or invalid configuration",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.c.alvearies[1].routing={gate={address="gate",side=2,off=0,on=15}}
  local output=15; w.proxies.gate={setOutput=function(side,value) eq(side,2); output=value end}
  local exportLevel=15; local filterCleared=false
  w.proxies.exportGate={setOutput=function(side,value) eq(side,1); exportLevel=value end}
  w.proxies.exportBus={setExportConfiguration=function(side,slot) eq(side,4); eq(slot,1); filterCleared=true end}
  w.state.pendingExternal={gate={address="exportGate",side=1,off=0},exportAddress="exportBus",exportSide=4}
  W.job(w,"old","Attuned").machine="a"
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    require("lib.cli").main("/project",{"cancel"}); eq(output,0); eq(exportLevel,0); ok(filterCleared)
    files["/project/data/config.lua"]="invalid config"
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    require("lib.cli").main("/project",{"cancel"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.cancelled); eq(#state.jobs,0)
  end)
end)

test("cancel is repeatable and status never presents inactive scanner recovery as work",function()
  local w=W.new(); w:addMachine("a"); w:build()
  W.job(w,"old","Attuned").machine="a"
  w.state.scan={phase="PROCESSING",count=1,identity="exact-bee",inserted=true}
  w.state.pending={owner="scanner",scanning=true,identity="exact-bee",phase="UNCERTAIN"}
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    require("lib.cli").main("/project",{"cancel"})
    local first=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    require("lib.cli").main("/project",{"cancel"})
    local second=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    eq(first,second); eq(second.scan,w.state.scan); eq(second.pending,w.state.pending)
    local text=require("lib.ui.status").render(second,w.c,false)
    ok(text:find("BEEOMATIC | Cancelled",1,true)); ok(text:find("no saved work",1,true))
    ok(not text:find("Scanner:",1,true)); ok(not text:find("Attention:",1,true))
  end)
end)


test("cancel does not require a healthy database or storage scan to abandon fetching",function()
  local ME=require("tests.mocks.me"); local w=ME.new()
  w.proxies.db.get=function() error("database did not preserve exact bee NBT") end
  w.proxies.me.getItemsInNetwork=function() error("network offline") end
  W.job(w,"old","Attuned").machine="a"
  w.state.scan={phase="REQUESTING",count=1,identity="recorded-nbt"}
  w.state.meRequests.old={phase="READY",owner="scanner",ep=w.c.scanner.storage,slot=2,identity="recorded-nbt",count=1}
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local _,err=require("lib.cli").main("/project",{"cancel"}); eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.cancelled); eq(#state.jobs,0); eq(state.scan,nil)
    eq(state.meRequests.old.phase,"RETURNING"); eq(state.meRequests.old.identity,"recorded-nbt")
  end)
end)

test("cancel preserves an inserted scanner batch until a new request reconciles its return",function()
  local ME=require("tests.mocks.me"); local B=require("lib.bees"); local w=ME.new()
  w.c.confirmCycles=1; w.c.minDrones=2
  local raw=ME.bee("Spirit","drone",8,true)
  w:addStock(ME.bee("Spirit","princess")); w:addStock(raw)
  w.state.meBatches.old={root="old",identity=B.identity(raw),owner="old-job",count=8,stack=U.copy(raw)}
  w.state.pendingRequest={target="spirit",mode="populate",count=2,flags={}}
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local event=require("event"); local pull=event.pull; local calls=0
    event.pull=function(...)
      local current=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
      if current.scan and current.scan.phase=="PROCESSING" then
        calls=calls+1; eq(calls,1)
        require("lib.cli").main("/project",{"cancel"}); return nil
      end
      return pull(...)
    end
    local _,err=require("lib.cli").main("/project",{"resume"}); eq(err,nil,err)
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.cancelled); eq(state.scan.phase,"PROCESSING"); eq(state.scan.batchId,"old")
    ok(state.meBatches.old); eq(state.pendingRequest,nil)
    event.pull=pull
    _,err=require("lib.cli").main("/project",{"populate","spirit","2"}); eq(err,nil,err)
    state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished); eq(state.scan,nil); eq(state.cancelCleanup,nil); eq(state.meBatches.old,nil)
  end)
end)


test("cancel abandons a prepared scanner insertion but retains uncertain insertion evidence",function()
  for _,uncertain in ipairs({false,true}) do
    local state={jobs={},meRequests={['port:2']={owner="scanner",phase="READY",consumed=false}},
      scan={phase="INSERTING",count=1,source={endpoint={id="port"},slot=2}},reservations={},meBatches={}}
    if uncertain then state.pending={owner="scanner",scanning=true,phase="INTENT"} end
    require("lib.jobs").cancel(state)
    ok(state.cancelled); eq(state.meRequests['port:2'].phase,"RETURNING")
    if uncertain then ok(state.scan); ok(state.pending) else eq(state.scan,nil) end
  end
end)


test("cancel preserves managed slot evidence while a transfer is unresolved",function()
  local ME=require("tests.mocks.me"); local w=ME.new()
  local ep=w.c.scanner.storage; local cleared=0
  w.proxies[ep.address].setInterfaceConfiguration=function() cleared=cleared+1; return true end
  w.state.meRequests.slot={owner="scanner",phase="READY",ep=ep,slot=2,identity="exact-nbt",count=1}
  w.state.pending={owner="scanner",source=ep,slot=2,dest=w.c.scanner.input,destSlot=1,
    identity="exact-nbt",before=1,count=1,returned=0,phase="UNCERTAIN"}
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    require("lib.cli").main("/project",{"cancel"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.cancelled); eq(#state.jobs,0); eq(state.pending,w.state.pending)
    eq(cleared,0); eq(state.meRequests.slot.phase,"RETURNING")
  end)
end)

test("ordinary setup refuses retired scanner migration with unresolved work",function()
  local cases={
    {pending={phase="INTENT"}}, {pendingExternal={kind="ME_EXPORT"}}, {scan={phase="PROCESSING"}},
    {meRequests={scanner={phase="READY"}}}, {meBatches={owned={count=8}}},
    {jobs={{id="job",state="RUNNING",machine="a"}}}
  }
  for _,state in ipairs(cases) do
    local w=require("tests.mocks.me").new(); w.c.setupStep=5; w.c.scanner.mode="external"; w.c.scanner.output=nil
    O.with(w,function(files)
      local config="return "..U.encode(w.c); local saved="return "..U.encode(state)
      files["/project/data/config.lua"]=config; files["/project/data/state.lua"]=saved
      raises(function() require("lib.cli").main("/project",{"setup"}) end,
        state.jobs and "finish or cancel" or "reconcile outstanding")
      eq(files["/project/data/config.lua"],config); eq(files["/project/data/state.lua"],saved); eq(w.moves,0)
    end)
  end
end)

test("public setup replaces a completed retired scanner configuration",function()
  local w=require("tests.mocks.me").new(); w.c.setupStep=5; w.c.scanner.mode="external"; w.c.scanner.output=nil
  for _,component in ipairs(w.components:discover()) do
    w.c.componentNames[component.address]={name=component.address,kind=component.kind}
  end
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local read=io.read; local answers={"1","1","1","2","3","no"}; local n=0
    io.read=function() n=n+1; return answers[n] end
    local success,err=pcall(function() require("lib.cli").main("/project",{"setup"}) end)
    io.read=read; ok(success,err)
    local c=assert(load(files["/project/data/config.lua"],"=config","t",{}))()
    eq(c.scanner.mode,"buffered"); eq(c.scanner.output.side,2); eq(c.setupStep,5)
    eq(c.alvearies,w.c.alvearies); require("lib.config").validate(c); eq(w.moves,0)
    ok(table.concat(out,"\n"):find("Configuration saved",1,true))
  end)
end)
