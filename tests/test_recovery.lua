local W=require("tests.mocks.world"); local U=require("lib.util")
test("restart after successful movement reconciles without replay",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.inventories.hub[1]=W.bee("Forest","drone",8)
  w.throwAfterMove=true
  raises(function() w.inv:move(w.storage:scan()[1],{id="a",transposer="tp1",side=3},10,2,"one") end,"uncertain")
  eq(w.moves,1); ok(w.inv:reconcile()); eq(w.moves,1); eq(w.inventories.a[10].size,2)
end)
test("ambiguous movement never replays or deletes stock",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.inventories.hub[1]=W.bee("Forest","drone",8)
  w.throwAfterMove=true
  raises(function() w.inv:move(w.storage:scan()[1],{id="a",transposer="tp1",side=3},10,2,"one") end)
  w.inventories.a[10]=nil; local yes=w.inv:reconcile(); ok(not yes); eq(w.moves,1)
end)
test("restart during active queen resumes observation, not insertion",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local j=W.job(w,"one","Spirit","populate"); j.state="RUNNING"; j.machine="a"; j.started=1000
  w.state.machines.a={job=j.id,state="RUNNING"}; w.inventories.a[4]=W.bee("Spirit","queen")
  w.scheduler:recover(); eq(j.state,"RUNNING"); eq(j.started,0); eq(w.moves,0)
end)
test("restart during partial insertion requests explicit adoption",function()
  local w=W.new(); w:addMachine("a"); w:build(); local j=W.job(w,"one","Spirit"); j.state="PREPARING"; j.machine="a"
  w.state.machines.a={job=j.id}; w.inventories.a[4]=W.bee("Spirit","princess")
  w.scheduler:recover(); eq(j.state,"PAUSED"); ok(j.error:find("insertion",1,true)); eq(w.moves,0)
end)
test("missing registered machine pauses only its operation",function()
  local w=W.new(); w:addMachine("a"); w:build(); local j=W.job(w,"one","Spirit"); j.state="RUNNING"; j.machine="a"
  w.state.machines.a={job=j.id}; w.proxies.housing1=nil
  w.scheduler:recover(); eq(j.state,"PAUSED"); eq(w.moves,0)
end)
test("persistence retains backup and binary strings",function()
  local P=require("lib.persistence"); local path="tests/state-test.lua"
  local fs={exists=function(p) local f=io.open(p,"r"); if f then f:close(); return true end; return false end,rename=os.rename,remove=os.remove}
  os.remove(path); os.remove(path..".bak"); local p=P.new(path,fs)
  p:save({revision=1,tag=string.char(0,1,127,255)}); p:save({revision=2})
  eq(p:load().revision,2)
  local f=assert(io.open(path,"w")); f:write("corrupt"); f:close()
  local recovered=p:load(); eq(recovered.revision,1); eq(recovered.tag,string.char(0,1,127,255)); ok(recovered.recoveredBackup)
  os.remove(path); os.remove(path..".bak")
end)
test("partial receipt is reconciled from actual source and destination deltas",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.inventories.hub[1]=W.bee("Forest","drone",8)
  w.afterTransfer=function() w.inventories.hub[1].size=7; w.inventories.a[10].size=1 end
  raises(function() w.inv:move(w.storage:scan()[1],{id="a",transposer="tp1",side=3},10,2,"j") end)
  ok(w.inv:reconcile()); eq(w.state.transactions[1].count,1); eq(w.state.transactions[1].requested,2)
  eq(w.state.transactions[1].phase,"PARTIAL_RECOVERED")
end)
test("repeated pause retains the resumable previous state",function()
  local w=W.new(); w:addMachine("a"); w:build(); local j=W.job(w,"j","Spirit","populate")
  j.state="RUNNING"; j.machine="a"; w.state.machines.a={job=j.id,state="RUNNING"}
  w.scheduler:pause(j,"first"); w.scheduler:pause(j,"second"); eq(j.previous,"RUNNING")
  w.scheduler:resume("j"); eq(j.state,"RUNNING"); eq(w.state.machines.a.state,"RUNNING")
end)
