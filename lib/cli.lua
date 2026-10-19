local U=require("lib.util"); local Config=require("lib.config"); local P=require("lib.persistence")
local B=require("lib.bees"); local Jobs=require("lib.jobs")
local M={}
local help=[[Beeomatic setup [--reconfigure]
Beeomatic doctor [--probe | --interface PORT | --adopt JOB | --retry JOB | --confirm ALVEARY | --robot ALVEARY]
Beeomatic plan SPECIES [--verbose] [--no-pager]
Beeomatic breed SPECIES [--noFinalImprint | --onlyFinalImprint]
Beeomatic convert SPECIES | populate SPECIES COUNT | imprint SPECIES
Beeomatic status [--verbose] | logs [--crash]
Beeomatic pause [JOB] | resume [JOB] [--recover] | stop | cancel
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
  local a,f=M.parse(args); local cmd=U.lower(a[1]); local sub=U.lower(a[2])
  local crashPath=data.."/crash.log"
  -- Crash reports must remain readable even if loading configuration/state fails.
  if cmd=="logs" and f.crash then
    local report=io.open(crashPath,"r")
    if not report then print("No saved crash report. Older versions did not save tracebacks."); return end
    local text=report:read("*a"); report:close()
    require("lib.ui.pager").show(text,{enabled=not f["no-pager"]}); return
  end
  local cp=P.new(data.."/config.lua",fs); local sp=P.new(data.."/state.lua",fs)
  local ctl=P.new(data.."/control.lua",fs); local lock=data.."/worker.lock"
  local c=cp:load(Config.defaults()); local state=sp:load({jobs={},reservations={},transactions={},events={}})
  local function save() sp:save(state) end
  local components=Components.new(); local inv=Inventory.new(components,state,save)
  local Storage=require("lib.storage."..c.storage.kind); local storage=Storage.new(c.storage,inv,components)
  local scanner=require("lib.scanner").new(c.scanner,inv,state,save,computer.uptime,storage)
  local scheduler=require("lib.scheduler").new(c,state,components,inv,storage,scanner,save,computer.uptime)
  local function scanInterval()
    return math.min(c.pollSeconds,math.max(0.1,tonumber(c.scanner.pollSeconds) or 0.5))
  end
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
      if x.id then local j=assert(Jobs.find(state,x.id),"unknown job"); scheduler:pause(j,"Paused by user") else state.paused=true end
    elseif x.action=="resume" then scheduler:resume(x.id)
    elseif x.action=="stop" then state.paused=false; state.stopping=true end
    save()
  end
  local function run()
    Config.validate(c); storage:validate()
    if storage.interface then scanner:validate() end
    if fs.exists(lock) then
      assert(f.recover,"Worker lock exists. Use resume --recover only after stopping the old process.")
      assert(fs.remove(lock))
    end
    local lf=assert(io.open(lock,"w")); lf:write(tostring(computer.address())); lf:close()
    local ok,err=xpcall(function()
      scheduler:recover()
      if state.pendingRequest then
        -- This request already passed the admission checks. Prepare its stock
        -- without resuming jobs from the previously drained plan.
        state.paused=false; state.stopped=false; state.stopping=false; save()
      else scheduler:resume(a[2] and cmd=="resume" and a[2] or nil) end
      local lastDisplay=""
      while true do
        applyControl()
        local active,status
        if state.pendingRequest and not state.paused then
          local items=storage:scan()
          do
            local success,ready,why=pcall(scheduler.prepareStock,scheduler,items)
            if not success then status="BLOCKED"; state.error=tostring(ready); save()
            elseif not ready then status="SCANNING"; state.error=why; save()
            else
              state.error=nil
              items=storage:scan()
              local req=state.pendingRequest; local m=mutations(items)
              local plan,e=Planner.plan(req.target,m,items,c); assert(plan,e)
              Jobs.create(state,plan,req.mode,req.count,req.flags,req); state.pendingRequest=nil; save()
            end
          end
        else active,status=scheduler:step() end
        Status.observe(state,c,components,inv,computer.uptime()); save()
        local display=Status.render(state,c,false)
        if display~=lastDisplay then Status.show(display); lastDisplay=display end
        if status=="DONE" or status=="STOPPED" then break end
        if status=="BLOCKED" and not active and not state.paused then
          print("Progress saved. Repair the reported condition, then Beeomatic resume."); break
        end
        local scanning=not state.paused and (status=="SCANNING" or state.scan)
        local name,_,char=event.pull(scanning and scanInterval() or c.pollSeconds)
        if name=="interrupted" then break end
        if name=="key_down" then
          if char==112 then state.paused=true elseif char==114 then scheduler:resume()
          elseif char==113 then state.paused=false; state.stopping=true end
          save()
        end
      end
    end,debug.traceback)
    fs.remove(lock)
    if not ok then
      -- Keep crash diagnostics separate from the breeding journal. A full disk
      -- or failed report write must never replace the original worker error.
      local report
      local written,writeError=pcall(function()
        report=assert(io.open(crashPath,"w"))
        assert(report:write("Beeomatic worker crash\nCommand: "..table.concat(args," ").."\n\n"..tostring(err).."\n"))
        assert(report:flush())
        report:close(); report=nil
      end)
      if report then pcall(report.close,report) end
      local first=tostring(err):match("^[^\r\n]+") or tostring(err)
      print("Beeomatic stopped: "..first)
      if written then print("Crash report: "..crashPath.."\nRead it with: Beeomatic logs --crash")
      else print("Could not save crash report: "..tostring(writeError)) end
      return nil,err
    end
  end
  if cmd=="" or cmd=="help" then print(help); return end
  if cmd=="cancel" then
    local function refused(message) print(message); return nil,message end
    if fs.exists(lock) then return refused("A worker lock exists. Exit the running worker with Ctrl+C before cancelling its pending request.") end
    if not state.pendingRequest then print("No pending request to cancel. Saved jobs remain; use stop to drain active work."); return end
    for _,m in pairs(state.machines or {}) do
      if m.job then return refused("A machine is still assigned; recover/drain existing work before cancelling the pending request.") end
    end
    for _,j in ipairs(state.jobs) do
      if j.machine or j.state=="RUNNING" or j.state=="COLLECTING" or j.state=="ASSESSING" or j.state=="PREPARING" then
        return refused("A job still has active work; recover/drain it before cancelling the pending request.")
      end
    end
    local target=state.pendingRequest.target
    -- The pending request passed admission after the previous plan was drained.
    -- Restore that plan's stopped status, including requests stranded by old code.
    -- Keep all scanner, transfer, ownership and job records for reconciliation.
    state.pendingRequest=nil; state.stopped=true; state.stopping=false; save()
    print("Cancelled pending request for "..tostring(target)..". You can start a new request.")
    if state.scan or state.pending or state.pendingExternal or next(state.meRequests or {}) then
      print("Scanner/transfer recovery records retained; they will be reconciled before new breeding starts.")
    end
    return
  end
  if cmd=="status" then
    Status.observe(state,c,components,inv,computer.uptime()); print(Status.render(state,c,f.verbose)); return
  end
  if cmd=="logs" then for _,e in ipairs(state.events or {}) do print(tostring(e.time).." "..e.message) end; return end
  if cmd=="pause" or cmd=="stop" then
    if fs.exists(lock) then sendControl(cmd,a[2])
    else if cmd=="pause" then
      if a[2] then scheduler:pause(assert(Jobs.find(state,a[2]),"unknown job"),"Paused by user") else state.paused=true end
    else state.stopping=true; state.paused=false end; save(); print("Saved "..cmd.." request") end
    return
  end
  if cmd=="resume" then
    if fs.exists(lock) and not f.recover then sendControl("resume",a[2]); return end
    assert(#state.jobs>0 or state.pendingRequest,"No saved work to resume")
    return run()
  end
  if cmd=="setup" or (cmd=="alveary" and sub=="add") then
    unlocked()
    if cmd=="setup" and f.reconfigure then
      assert(not state.pending and not state.pendingExternal and not state.scan and not next(state.meRequests or {}) and not next(state.meBatches or {}),
        "reconcile outstanding movements/scanning before reconfiguring storage")
      for _,j in ipairs(state.jobs) do
        assert(j.state=="DONE" or (state.stopped and not j.machine),"finish/drain saved jobs before reconfiguring storage")
      end
    end
    local w=require("lib.setup").new(c,components,inv,function() cp:save(c) end)
    if cmd=="setup" then w:run(f.reconfigure) else w:addAlveary() end; return
  end
  if cmd=="alveary" then
    if sub=="list" then for _,x in ipairs(c.alvearies) do print(x.id.." "..x.name.." "..x.address) end
    elseif sub=="remove" then unlocked()
      for _,j in ipairs(state.jobs) do assert(j.machine~=a[3],"machine has saved work") end
      local found=false
      for n,x in ipairs(c.alvearies) do if x.id==a[3] then table.remove(c.alvearies,n); found=true; break end end
      assert(found,"unknown alveary ID"); Config.prunePorts(c); cp:save(c)
    else error("Use alveary list, add, or remove ID") end; return
  end
  if cmd=="doctor" then
    if f.interface then
      unlocked(); assert(storage.interface,"Interface probe requires ME Interface storage mode")
      local port
      for _,ep in ipairs(c.storage.endpoints) do if ep.id==a[2] then port=ep end end
      assert(port,"Use doctor --interface PORT_ID from your configuration")
      storage:probe(port); print("PASS Interface exact-stock, partial extraction and return: "..port.id)
    end
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
      scheduler:adopt(j)
      print("Adopted observed machine state; resume will continue without repeating insertion")
    end
    if f.retry then
      unlocked(); local ok,err=inv:reconcile(); assert(ok,err)
      scheduler:retryInsertion(assert(Jobs.find(state,a[2]),"Use doctor --retry JOB_ID"))
    end
    if f.robot then
      unlocked(); local machine
      for _,x in ipairs(c.alvearies) do if x.id==a[2] then machine=x end end
      assert(machine,"Use doctor --robot ALVEARY_ID")
      assert(c.robot.alvearyId==machine.id,"Robot is registered to a different alveary foundation position")
      local requests={}
      for _,j in ipairs(state.jobs) do for _,req in ipairs(j.route and j.route.specialConditions or {}) do
        if req:lower():find("foundation",1,true) then requests[req]=true end
      end end
      for _,req in ipairs(U.keys(requests)) do
        local nonce=computer.address()..":"..computer.uptime()..":"..req
        local yes,message=require("lib.robot").request(c.robot,components,req,nonce,event)
        print(message)
        if yes then print("Inspect "..machine.id.." and use doctor --confirm "..machine.id.." to attest that exact condition") end
      end
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
    assert(a[2],"Specify a species"); local items=storage:scan()
    local unscanned=0
    for _,i in ipairs(items) do if B.kind(i.stack) and not B.scanned(i.stack) then unscanned=unscanned+(i.stack.size or 1) end end
    if unscanned>0 or state.scan then
      print(tostring(unscanned).." bees in storage lack verified genes.")
      print("Would you like to scan all unscanned bees now? [y/N]")
      local answer=U.lower(io.read() or "")
      if answer=="y" or answer=="yes" then
        local function blocked(message) print(message); return nil,message end
        if fs.exists(lock) then return blocked("A worker is running. Stop it before scanning from plan.") end
        if state.pendingRequest then return blocked("Saved breeding work exists. Use Beeomatic resume to scan and continue it.") end
        for _,j in ipairs(state.jobs) do
          if j.state~="DONE" and not (state.stopped and not j.machine) then
            return blocked("Saved breeding work exists. Use Beeomatic resume to scan and continue it.")
          end
        end
        local ok,why=pcall(function()
          storage:validate()
          local ready,reason=inv:reconcile(); assert(ready,reason)
          if storage.reconcile then local yes,e=storage:reconcile(); assert(yes,e) end
        end)
        if not ok then return blocked("Cannot scan: "..tostring(why)) end
        local lf,reason=io.open(lock,"w")
        if not lf then return blocked("Cannot start scanner: "..tostring(reason)) end
        lf:write(tostring(computer.address())); lf:close()
        ok,why=pcall(function()
          local lastMessage
          while true do
            -- A pending scanner batch carries its own exact source/return state.
            -- Refresh all stock only when selecting the next batch.
            items=state.scan and {} or storage:scan()
            local ready,message
            if storage.prepare and not storage:prepare(items) then message="Inspecting ME stock"
            else ready,message=scanner:step(items) end
            if ready then break end
            if message and message~=lastMessage then print(message); lastMessage=message end
            local name,_,char=event.pull(scanInterval())
            if name=="interrupted" or (name=="key_down" and char==113) then
              error("Scanning stopped; progress saved. Run Beeomatic plan "..a[2].." again to continue.",0)
            end
          end
          items=storage:scan(); print("Scanning complete.")
        end)
        fs.remove(lock)
        if not ok then return blocked("Scanning paused: "..tostring(why).."\nProgress preserved; repair the scanner and rerun Beeomatic plan "..a[2]..".") end
      end
    end
    local m=mutations(items)
    local plan,reason=Planner.plan(a[2],m,items,c)
    if not plan then
      local message=reason or ("Not enough verified parent stock to reach "..a[2]..".")
      print(message); return nil,message
    end
    require("lib.ui.pager").show(Planner.render(plan,{verbose=f.verbose}),{enabled=not f["no-pager"]}); return
  end
  if cmd=="breed" or cmd=="convert" or cmd=="populate" or cmd=="imprint" then
    unlocked(); assert(a[2],"Specify a species")
    assert(not state.pendingRequest,"Saved request exists; use resume")
    assert(#state.jobs==0 or state.finished or state.stopped,"Existing work is preserved; use resume or drain with stop")
    local count=cmd=="populate" and U.assertNumber(a[3],1,1000000) or nil
    state.pendingRequest={target=a[2],mode=cmd,count=count,flags=f}; save(); return run()
  end
  error("Unknown command. Run Beeomatic help")
end
return M
