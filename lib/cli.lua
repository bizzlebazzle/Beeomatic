local U=require("lib.util"); local Config=require("lib.config"); local P=require("lib.persistence")
local B=require("lib.bees"); local Jobs=require("lib.jobs")
local M={}
local help=[[Beeomatic setup [--reconfigure]
Beeomatic doctor [--probe | --adopt JOB | --confirm ALVEARY]
Beeomatic plan SPECIES
Beeomatic breed SPECIES [--noFinalImprint | --onlyFinalImprint]
Beeomatic convert SPECIES | populate SPECIES COUNT | imprint SPECIES
Beeomatic status [--verbose] | logs
Beeomatic pause [JOB] | resume [JOB] [--recover] | stop
Beeomatic alveary list | add | remove ID
Beeomatic storage scan | bees list | bees inspect SPECIES
Beeomatic help

Jobs run in the foreground. p pauses, r resumes, q drains active cycles and stops.
Ctrl+C exits with state preserved. Run resume after repairing a blocked job.
Other OpenOS shells can send pause/resume/stop through a persistent mailbox.
Use resume --recover ONLY after stopping any old worker (stale lock after reboot).]]
function M.parse(args)
  local positional,flags={},{}
  for _,a in ipairs(args) do
    if a:sub(1,2)=="--" then flags[a:sub(3):lower()]=true else positional[#positional+1]=a end
  end; return positional,flags
end
function M.main(root,args)
  local fs=require("filesystem"); local computer=require("computer"); local event=require("event")
  local Components=require("lib.components"); local Inventory=require("lib.inventory")
  local Planner=require("lib.planner"); local Mutations=require("lib.mutations")
  local Status=require("lib.ui.status"); local Diagnostics=require("lib.ui.diagnostics")
  local data=root.."/data"; fs.makeDirectory(data)
  local cp=P.new(data.."/config.lua",fs); local sp=P.new(data.."/state.lua",fs)
  local ctl=P.new(data.."/control.lua",fs); local lock=data.."/worker.lock"
  local c=cp:load(Config.defaults()); local state=sp:load({jobs={},reservations={},transactions={},events={}})
  local function save() sp:save(state) end
  local components=Components.new(); local inv=Inventory.new(components,state,save)
  local Storage=require("lib.storage."..c.storage.kind); local storage=Storage.new(c.storage,inv,components)
  local scanner=require("lib.scanner").new(c.scanner,inv,state,save,computer.uptime)
  local scheduler=require("lib.scheduler").new(c,state,components,inv,storage,scanner,save,computer.uptime)
  local a,f=M.parse(args); local cmd=U.lower(a[1]); local sub=U.lower(a[2])
  local function unlocked() assert(not fs.exists(lock),"A worker lock exists. Stop the running worker before changing configuration.") end
  local function mutations(items)
    local source
    -- Only explicitly registered addresses; fallback between registered healthy housings.
    for _,machine in ipairs(c.alvearies) do if machine.enabled~=false then
      local ok,p=pcall(components.proxy,components,machine.address,{"getBeeParents"})
      if ok then source=p; break end
    end end
    assert(source,"No registered accessible housing provides getBeeParents. Run setup/doctor.")
    local m=Mutations.new(source,c.aliases); m:index(items); return m
  end
  local function sendControl(action,id)
    ctl:save({action=action,id=id,requested=computer.uptime()}); print("Requested "..action..(id and " "..id or ""))
  end
  local function applyControl()
    if not fs.exists(data.."/control.lua") then return end
    local x=ctl:load({}); assert(fs.remove(data.."/control.lua"))
    if x.action=="pause" then
      if x.id then local j=assert(Jobs.find(state,x.id),"unknown job"); Jobs.pause(j,"Paused by user") else state.paused=true end
    elseif x.action=="resume" then scheduler:resume(x.id)
    elseif x.action=="stop" then state.paused=false; state.stopping=true end
    save()
  end
  local function run()
    Config.validate(c); storage:validate()
    if fs.exists(lock) then
      assert(f.recover,"Worker lock exists. Use resume --recover only after stopping the old process.")
      assert(fs.remove(lock))
    end
    local lf=assert(io.open(lock,"w")); lf:write(tostring(computer.address())); lf:close()
    local ok,err=xpcall(function()
      scheduler:recover(); scheduler:resume(a[2] and cmd=="resume" and a[2] or nil)
      local lastDisplay=""
      while true do
        applyControl()
        local active,status
        if state.pendingRequest and not state.paused then
          local items=storage:scan()
          if storage.prepare and not storage:prepare(items) then status="INSPECTING_ME"
          else
            local ready,why=scanner:step(items)
            if not ready then status="SCANNING"; state.error=why; save()
            else
              local req=state.pendingRequest; local m=mutations(items)
              local plan,e=Planner.plan(req.target,m,items,c); assert(plan,e)
              Jobs.create(state,plan,req.mode,req.count,req.flags); state.pendingRequest=nil; save()
              print(Planner.render(plan))
            end
          end
        else active,status=scheduler:step() end
        local display=Status.render(state,c,false)
        if display~=lastDisplay then print(display); lastDisplay=display end
        if status=="DONE" or status=="STOPPED" then break end
        if status=="BLOCKED" and not active and not state.paused then
          print("Progress saved. Repair the reported condition, then Beeomatic resume."); break
        end
        local name,_,char=event.pull(c.pollSeconds)
        if name=="interrupted" then break end
        if name=="key_down" then
          if char==112 then state.paused=true elseif char==114 then scheduler:resume()
          elseif char==113 then state.paused=false; state.stopping=true end
          save()
        end
      end
    end,debug.traceback)
    fs.remove(lock)
    if not ok then error(err,0) end
  end
  if cmd=="" or cmd=="help" then print(help); return end
  if cmd=="status" then print(Status.render(state,c,f.verbose)); return end
  if cmd=="logs" then for _,e in ipairs(state.events or {}) do print(tostring(e.time).." "..e.message) end; return end
  if cmd=="pause" or cmd=="stop" then
    if fs.exists(lock) then sendControl(cmd,a[2])
    else if cmd=="pause" then
      if a[2] then Jobs.pause(assert(Jobs.find(state,a[2]),"unknown job"),"Paused by user") else state.paused=true end
    else state.stopping=true; state.paused=false end; save(); print("Saved "..cmd.." request") end
    return
  end
  if cmd=="resume" then
    if fs.exists(lock) and not f.recover then sendControl("resume",a[2]); return end
    assert(#state.jobs>0 or state.pendingRequest,"No saved work to resume")
    run(); return
  end
  if cmd=="setup" or (cmd=="alveary" and sub=="add") then
    unlocked(); local w=require("lib.setup").new(c,components,inv,function() cp:save(c) end)
    if cmd=="setup" then w:run(f.reconfigure) else w:addAlveary() end; return
  end
  if cmd=="alveary" then
    if sub=="list" then for _,x in ipairs(c.alvearies) do print(x.id.." "..x.name.." "..x.address) end
    elseif sub=="remove" then unlocked()
      for _,j in ipairs(state.jobs) do assert(j.machine~=a[3],"machine has saved work") end
      local found=false
      for n,x in ipairs(c.alvearies) do if x.id==a[3] then table.remove(c.alvearies,n); found=true; break end end
      assert(found,"unknown alveary ID"); cp:save(c)
    else error("Use alveary list, add, or remove ID") end; return
  end
  if cmd=="doctor" then
    if f.probe then Diagnostics.probe(components) end
    if f.confirm then
      unlocked(); local id=a[2]; local machine
      for _,x in ipairs(c.alvearies) do if x.id==id then machine=x end end
      assert(machine,"Use doctor --confirm ALVEARY_ID")
      local requirements={}
      for _,j in ipairs(state.jobs) do for _,req in ipairs(j.route and j.route.specialConditions or {}) do requirements[req]=true end end
      for _,req in ipairs(U.keys(requirements)) do
        print(id..": "..req)
        print("Type confirmed only after verifying this exact condition at this alveary:")
        if io.read()=="confirmed" then machine.confirmed=machine.confirmed or {}; machine.confirmed[req]=true; cp:save(c) end
      end
    end
    if f.adopt then
      unlocked(); local j=assert(Jobs.find(state,a[2]),"Use doctor --adopt JOB_ID")
      assert(j.machine,"job has no reserved machine")
      local b=scheduler:backend(j.machine); b:validate()
      local status=b:getCycleState()
      local input=inv:get(b.endpoint,b:getSlots().princess)
      assert(status=="FINISHED" or B.kind(input)=="queen","adoption needs a live queen or a full completed offspring pair")
      assert(not state.pending and not state.pendingExternal,"reconcile ambiguous transfers before adoption")
      j.state=status=="FINISHED" and "COLLECTING" or "RUNNING"; j.previous=nil; j.error=nil; j.started=computer.uptime(); save()
      print("Adopted observed machine state; resume will continue without repeating insertion")
    end
    if not fs.exists(lock) then
      local ok,why=inv:reconcile(); print(ok and "Transfer journal reconciled" or why)
      if storage.reconcile then local yes,e=storage:reconcile(); print(yes and "AE2 journal reconciled" or e) end
    end
    for _,r in ipairs(Diagnostics.check(c,components,inv,storage)) do print((r.ok and "PASS " or "FAIL ")..r.name..(r.error and (": "..r.error) or "")) end
    return
  end
  if (cmd=="storage" and sub=="scan") or cmd=="bees" then
    local items=storage:scan(); local m=mutations(items); local target=m:resolve(a[3] or "")
    for _,i in ipairs(items) do
      if cmd~="bees" or sub~="inspect" or (B.scanned(i.stack) and
        (B.matches(i.stack.individual.active.species,target) or B.matches(i.stack.individual.inactive.species,target))) then
        if B.kind(i.stack) then print(i.endpoint.id..":"..tostring(i.slot).." "..U.encode(i.stack)) end
      end
    end; return
  end
  if cmd=="plan" then
    assert(a[2],"Specify a species"); local items=storage:scan(); local m=mutations(items)
    local plan,err=Planner.plan(a[2],m,items,c); assert(plan,err); print(Planner.render(plan)); return
  end
  if cmd=="breed" or cmd=="convert" or cmd=="populate" or cmd=="imprint" then
    unlocked(); assert(a[2],"Specify a species")
    assert(not state.pendingRequest,"Saved request exists; use resume")
    assert(#state.jobs==0 or state.finished or state.stopped,"Existing work is preserved; use resume or drain with stop")
    local count=cmd=="populate" and U.assertNumber(a[3],1,1000000) or nil
    state.pendingRequest={target=a[2],mode=cmd,count=count,flags=f}; save(); run(); return
  end
  error("Unknown command. Run Beeomatic help")
end
return M
