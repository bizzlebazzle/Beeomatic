local Profile=require("lib.profile"); local U=require("lib.util")
local W=require("tests.mocks.world"); local O=require("tests.mocks.openos")

test("profile reports encoding cache reuse without recording cached contents",function()
  local p=Profile.new("/profile.log",function() return 0 end,{})
  local cache=U.stringCache(); p.stringCache=cache
  local value={tag=string.rep("private-nbt",200)}
  for _=1,2 do U.write(value,function() end,cache) end
  local report=p:report()
  ok(cache.hits>0); ok(cache.misses>0)
  ok(report:find("Large-string cache: "..cache.hits.." hits, "..cache.misses.." misses",1,true))
  ok(report:find(cache.reused.." input bytes reused",1,true))
  ok(report:find(cache.bytes.."/65536 bytes retained",1,true))
  ok(not report:find("private-nbt",1,true))
end)

test("profile preserves nil returns and separates nested wall-clock timings",function()
  local time=0; local p=Profile.new("/profile.log",function() return time end,{})
  local result=table.pack(p:call("parent",nil,function(...)
    eq(select("#",...),3); time=time+2
    local child=table.pack(p:call("child",nil,function() time=time+3; return "ok",nil,7,nil end))
    eq(child.n,4); eq(child[3],7); time=time+5
    return table.unpack(child,1,child.n)
  end,1,nil,3))
  eq(result.n,4); eq(result[1],"ok"); eq(result[3],7)
  eq(p.rows.parent.total,10); eq(p.rows.parent.own,7); eq(p.rows.child.own,3)
  eq(p.rows.parent.max,10); eq(p.rows.parent.count,1); eq(p.frame,nil)
end)

test("profile permits yielding callbacks used by OpenOS component and filesystem calls",function()
  local time=0; local p=Profile.new("/profile.log",function() return time end,{})
  local thread=coroutine.create(function()
    return p:call("component",nil,function() coroutine.yield("synchronized call"); time=2; return nil,3 end)
  end)
  local success,value=coroutine.resume(thread); ok(success); eq(value,"synchronized call")
  local resumed=table.pack(coroutine.resume(thread)); ok(resumed[1]); eq(resumed.n,3)
  eq(resumed[2],nil); eq(resumed[3],3); eq(p.rows.component.total,2); eq(p.frame,nil)
end)

test("profile records failures while preserving the original error value and restoring wrappers",function()
  local time=0; local p=Profile.new("/profile.log",function() return time end,{})
  local failure={}; local object={call=function() time=time+1; error(failure) end}
  local original=object.call; p:wrap(object,"call","failure")
  local success,why=pcall(object.call); eq(success,false); ok(why==failure)
  eq(p.rows.failure.errors,1); eq(p.frame,nil)
  p.flush=function() end; p:finish(); eq(object.call,original)
end)

test("profile measures indirect callable component tables without modifying native proxies",function()
  local time=0
  local callback=setmetatable({},{__call=function(_,side,slot) time=time+0.5; return nil,"no inventory",side,slot end,__metatable="protected"})
  local raw={address="tp",getStackInSlot=callback}
  local components=require("lib.components").new({proxy=function() return raw end,
    methods=function() return {getStackInSlot=false} end})
  local p=Profile.new("/profile.log",function() return time end,{}); components.profile=p
  local proxy=components:proxy("tp",{"getStackInSlot"})
  local result=table.pack(proxy.getStackInSlot(0,2))
  eq(result.n,4); eq(result[1],nil); eq(result[2],"no inventory"); eq(result[4],2)
  eq(p.rows["tp.getStackInSlot"].total,0.5); eq(raw.getStackInSlot,callback)
  eq(proxy.address,"tp"); eq(components:proxy("tp",{"getStackInSlot"}),proxy)
  raw={getStackInSlot=function() time=time+2; return {name="replacement"} end}
  eq(components:proxy("tp",{"getStackInSlot"}).getStackInSlot().name,"replacement")
  eq(p.rows["tp.getStackInSlot"].count,2)
end)

test("profile bounds counters proxy caching history and output size",function()
  local time=0; local p=Profile.new("/profile.log",function() return time end,{})
  for i=1,400 do
    p:call("operation"..i,string.rep("x",1000),function() time=time+1 end)
    p:proxy("address"..i,{},{} )
  end
  local rows,proxies=0,0
  for _ in pairs(p.rows) do rows=rows+1 end; for _ in pairs(p.proxies) do proxies=proxies+1 end
  eq(rows,128); eq(proxies,32); eq(#p.events,24); ok(#p.events[24]<320)
  ok(#p:report()<=32768); ok(p.rows.other.count>0)
end)

test("profile periodically replaces a bounded log and preserves it on disk-space failures",function()
  local w=W.new(); w:build()
  O.with(w,function(files,_,fs)
    local time=0; local p=Profile.new("/profile.log",function() return time end,fs,function() return 12345 end)
    p:flush(); eq(files["/profile.log"],nil)
    p:call("slow",nil,function() time=31 end); ok(p:flush())
    local report=files["/profile.log"]; ok(report:find("Free RAM bytes: 12345",1,true))
    eq(files["/profile.log.tmp"],nil); time=32; p:flush(); eq(files["/profile.log"],report)
    fs.get=function() return {spaceTotal=function() return 100 end,spaceUsed=function() return 100 end} end
    time=65; eq(p:flush(),false); eq(files["/profile.log"],report)
    local object={fn=function() end}; local original=object.fn; p:wrap(object,"fn","fn")
    p:finish(); eq(object.fn,original); eq(files["/profile.log"],report)
  end)
end)

test("profile separates checkpoint disk I/O from streaming serialization and leaves bytes unchanged",function()
  local w=W.new(); w:build()
  O.with(w,function(files,_,fs)
    local time=0; local open=io.open
    io.open=function(...)
      local f,why=open(...); if not f then return nil,why end
      for _,key in ipairs({"read","write","flush"}) do
        local fn=f[key]; f[key]=function(self,...) time=time+1; return fn(self,...) end
      end
      return f
    end
    local p=Profile.new("/profile.log",function() return time end,fs)
    local store=require("lib.persistence").new("/state.lua",fs); store.profile=p
    p:wrap(U,"write","serialize"); p:wrap(store,"save","checkpoint.state")
    local data={tag=string.rep("x",20000)}; store:save(data)
    eq(assert(load(files["/state.lua"]))(),data)
    eq(p.rows.serialize.own,0); ok(p.rows.serialize.total>0)
    ok(p.rows["disk.write"].count>0); eq(p.rows["disk.read"],nil); eq(p.rows.serialize.count,1)
    eq(p.rows["checkpoint.state"].own,0); p:finish()
  end)
end)

test("profile logs can be read without loading broken state or enabling profiling",function()
  local w=W.new(); w:build()
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="broken"; files["/project/data/state.lua"]="broken"
    files["/project/data/profile.log"]="example profile report"
    local identity=require("lib.bees").identity
    require("lib.cli").main("/project",{"logs","--profile","--no-pager"})
    eq(table.concat(out,"\n"),"example profile report"); eq(require("lib.bees").identity,identity)
  end)
end)

test("CLI profile restores shared APIs and reports startup failures without masking them",function()
  local w=W.new(); w:build()
  O.with(w,function(files)
    files["/project/data/config.lua"]="broken"
    local identity=require("lib.bees").identity; local write=U.write; local pull=require("event").pull
    raises(function() require("lib.cli").main("/project",{"resume","--profile"}) end,"Cannot load saved data")
    eq(require("lib.bees").identity,identity); eq(U.write,write); eq(require("event").pull,pull)
    ok(files["/project/data/profile.log"]:find("config.load",1,true))
  end)
end)

test("CLI profiling requires stopping the current worker and never sends a resume mailbox",function()
  local w=W.new(); w:build()
  O.with(w,function(files)
    files["/project/data/worker.lock"]="running"
    files["/project/data/profile.log"]="active worker report"
    raises(function() require("lib.cli").main("/project",{"resume","--profile"}) end,"Stop the running worker")
    eq(files["/project/data/control.lua"],nil); eq(files["/project/data/worker.lock"],"running")
    eq(files["/project/data/profile.log"],"active worker report")
  end)
end)

test("profile survives worker crashes and log-write failure without replacing the original error",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"job","Spirit")
  O.with(w,function(files,_,fs)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local Scheduler=require("lib.scheduler"); local recover=Scheduler.recover
    local identity=require("lib.bees").identity; local exists=fs.exists; local open=io.open
    Scheduler.recover=function() error("original recovery failure") end
    io.open=function(path,...)
      if path=="/project/data/profile.log.tmp" then return nil,"disk full" end
      return open(path,...)
    end
    local success,_,why=pcall(require("lib.cli").main,"/project",{"resume","--profile"})
    Scheduler.recover=recover
    ok(success); ok(why:find("original recovery failure",1,true))
    eq(require("lib.bees").identity,identity); eq(fs.exists,exists)
    eq(files["/project/data/worker.lock"],nil)
    ok(files["/project/data/crash.log"]:find("original recovery failure",1,true))
  end)
end)

test("Ctrl+C saves a profile and restores event handling without cancelling breeding work",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"job","Spirit")
  w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","drone",64)
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local event=require("event"); local pull=function() return "interrupted" end; event.pull=pull
    local _,why=require("lib.cli").main("/project",{"resume","--profile"}); eq(why,nil,why)
    eq(event.pull,pull); eq(files["/project/data/worker.lock"],nil)
    local state=assert(load(files["/project/data/state.lua"]))(); ok(not state.cancelled)
    ok(files["/project/data/profile.log"]:find("checkpoint.state",1,true))
    eq(w.moves,0) -- stop at the first checkpoint, before any transfer
  end)
end)

test("profiled breeding produces the same finished jobs and movements as a normal run",function()
  local previous
  for _,profiling in ipairs({false,true}) do
    local w=W.new(); w:addMachine("a"); w:build()
    w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","drone",64)
    O.with(w,function(files)
      files["/project/data/config.lua"]="return "..U.encode(w.c)
      local args={"breed","spirit"}; if profiling then args[#args+1]="--profile" end
      local _,why=require("lib.cli").main("/project",args); eq(why,nil,why)
      local state=assert(load(files["/project/data/state.lua"]))(); ok(state.finished)
      if profiling then
        eq(w.moves,previous.moves); eq(state.jobs,previous.jobs)
        local report=files["/project/data/profile.log"]; ok(#report<=32768)
        for _,label in ipairs({"checkpoint.state","inventory.move","tp1.transferItem","disk.write","serialize","event.wait"}) do
          ok(report:find(label,1,true),"missing profile operation: "..label)
        end
      else eq(files["/project/data/profile.log"],nil); previous={moves=w.moves,jobs=state.jobs} end
      eq(files["/project/data/worker.lock"],nil)
    end)
  end
end)

test("profiled ME breeding covers Interface waits scanner stock and transfers",function()
  local ME=require("tests.mocks.me"); local w=ME.new(); w.c.confirmCycles=1; w.c.minDrones=2
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8,true))
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    local _,why=require("lib.cli").main("/project",{"populate","spirit","2","--profile"}); eq(why,nil,why)
    local state=assert(load(files["/project/data/state.lua"]))(); ok(state.finished)
    eq(state.scan,nil); eq(state.pending,nil); eq(next(state.meRequests),nil)
    local report=files["/project/data/profile.log"]
    for _,label in ipairs({"storage.poll","storage.wait","storage.scan","scanner.step","storage.materialize","transferItem"}) do
      ok(report:find(label,1,true),"missing ME profiling operation: "..label)
    end
  end)
end)

test("quit at transfer checkpoints preserves recovery evidence without another movement",function()
  for _,phase in ipairs({"INTENT","MOVED","COMMITTED"}) do
    for _,key in ipairs({"interrupted","q"}) do
      local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"job","Spirit")
      w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","drone",8)
      O.with(w,function(files,_,fs)
        files["/project/data/config.lua"]="return "..U.encode(w.c)
        files["/project/data/state.lua"]="return "..U.encode(w.state)
        local stopped=false; local moves
        require("event").pull=function(seconds)
          eq(seconds,0,"must stop before the scheduler's regular wait")
          local state=assert(load(files["/project/data/state.lua"]))()
          local current=state.pending and state.pending.phase or
            ((state.transferSequence or 0)>0 and "COMMITTED")
          if current==phase then
            ok(not stopped); stopped=true; moves=w.moves
            if key=="q" then return "key_down",nil,113 end
            return "interrupted"
          end
        end
        local _,why=require("lib.cli").main("/project",{"resume","--profile"}); eq(why,nil,why)
        ok(stopped); eq(w.moves,moves); eq(moves,phase=="INTENT" and 0 or 1)
        eq(files["/project/data/worker.lock"],nil); eq(files["/project/data/crash.log"],nil)
        local state=assert(load(files["/project/data/state.lua"]))()
        eq(not not state.cancelled,key=="q")
        if phase~="COMMITTED" then eq(state.pending.phase,phase) else eq(state.pending,nil) end
        local inv=require("lib.inventory").new(w.components,state,function() end)
        local reconciled,err=inv:reconcile(); ok(reconciled,err); eq(w.moves,moves)
        eq(state.pending,nil)
      end)
    end
  end
end)

test("worker forwards host coroutine yields and their nil-containing results",function()
  local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"job","Spirit")
  w.inventories.hub[1]=W.bee("Spirit","princess"); w.inventories.hub[2]=W.bee("Spirit","drone",8)
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode(w.state)
    local original=w.proxies.tp1.getInventorySize; local calls=0
    w.proxies.tp1.getInventorySize=function(...)
      calls=calls+1
      local a,b,c=coroutine.yield("host call",nil,42)
      eq(a,nil); eq(b,"host result"); eq(c,23)
      return original(...)
    end
    local thread=coroutine.create(function() return require("lib.cli").main("/project",{"resume"}) end)
    local result=table.pack(coroutine.resume(thread))
    while coroutine.status(thread)~="dead" do
      ok(result[1],result[2]); eq(result.n,4); eq(result[2],"host call"); eq(result[3],nil); eq(result[4],42)
      result=table.pack(coroutine.resume(thread,nil,"host result",23))
    end
    ok(result[1],result[2]); eq(result[3],nil); ok(calls>0)
    eq(files["/project/data/worker.lock"],nil)
  end)
end)

test("quit keys received during checkpoint watchdog waits survive until the safe boundary",function()
  for _,key in ipairs({"q","interrupted"}) do
    local w=W.new(); w:addMachine("a"); w:build(); W.job(w,"job","Spirit")
    O.with(w,function(files)
      files["/project/data/config.lua"]="return "..U.encode(w.c)
      files["/project/data/state.lua"]="return "..U.encode(w.state)
      local now,waits=0,0; local sleep=os.sleep
      require("computer").uptime=function() return now end
      os.sleep=function(seconds) now=now+seconds end
      require("event").pull=function(seconds)
        ok(seconds>0,"quit must be remembered before the zero-time checkpoint poll")
        now=now+seconds; waits=waits+1
        if key=="q" then return "key_down",nil,113 end
        return "interrupted"
      end
      local success,_,why=pcall(require("lib.cli").main,"/project",{"resume"})
      os.sleep=sleep
      ok(success,why); eq(why,nil); eq(waits,1); eq(w.moves,0)
      local state=assert(load(files["/project/data/state.lua"]))()
      eq(not not state.cancelled,key=="q")
      eq(files["/project/data/worker.lock"],nil); eq(files["/project/data/crash.log"],nil)
    end)
  end
end)
