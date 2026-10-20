local U=require("lib.util"); local Config=require("lib.config"); local P=require("lib.persistence")
local B=require("lib.bees"); local Jobs=require("lib.jobs")
local M={}
local help=[[Beeomatic setup [--reconfigure]
Beeomatic doctor [--probe | --interface PORT | --adopt JOB | --retry JOB | --confirm ALVEARY]
Beeomatic plan SPECIES [--verbose] [--no-pager]
Beeomatic breed SPECIES [--noFinalImprint | --onlyFinalImprint]
Beeomatic convert SPECIES | populate SPECIES COUNT | imprint SPECIES
Beeomatic status [--verbose] | logs [--crash]
Beeomatic pause [JOB] | resume [JOB] [--recover] | cancel
Beeomatic alveary list | add | remove ID | configure ID | rename ID NAME
Beeomatic storage scan | bees list | bees inspect SPECIES
Beeomatic help

Jobs run in the foreground. p pauses, r resumes, q cancels all work immediately.
cancel abandons the entire process; stop is an alias. Bees remain in place.
Ctrl+C exits with state preserved. Run resume after repairing a blocked job.
Other OpenOS shells can send pause/resume/cancel through a persistent mailbox.
Use resume --recover ONLY after stopping any old worker (stale lock after reboot).]]
function M.parse(args)
  local positional,flags={},{}
  for _,a in ipairs(args) do
    if a:sub(1,2)=="--" then flags[a:sub(3):lower()]=true else positional[#positional+1]=a end
  end; return positional,flags
end
function M.main(root,args)
  local fs=require("filesystem"); local computer=require("computer"); local event=require("event")
  local data=root.."/data"; fs.makeDirectory(data)
  local a,f=M.parse(args); local cmd=U.lower(a[1]); local sub=U.lower(a[2])
  if cmd=="stop" then cmd="cancel" end
  if cmd=="" or cmd=="help" then print(help); return end
  local crashPath=data.."/crash.log"
  -- Crash reports must remain readable even if loading configuration/state fails.
  if cmd=="logs" and f.crash then
    local report=io.open(crashPath,"r")
    if not report then print("No saved crash report. Older versions did not save tracebacks."); return end
    local text=report:read("*a"); report:close()
    require("lib.ui.pager").show(text,{enabled=not f["no-pager"]}); return
  end
  local cp=P.new(data.."/config.lua",fs)
  local receipts=require("lib.storage.receipts")
  local sp=P.new(data.."/state.lua",fs,receipts.decoded,receipts.skipField)
  local ctl=P.new(data.."/control.lua",fs); local lock=data.."/worker.lock"
  if fs.exists(lock) and (cmd=="pause" or cmd=="cancel" or (cmd=="resume" and not f.recover)) then
    ctl:save({action=cmd,id=a[2],requested=computer.uptime()})
    print("Requested "..cmd..(a[2] and " "..a[2] or "")); return
  end
  local state
  local function cancelWork(config)
    Jobs.cancel(state); sp:save(state)
    -- Stop dedicated pipe gates and clear saved Interface stock filters without
    -- waiting for inventories to drain. Failure cannot reinstate cancelled jobs.
    if not config then local ok,value=pcall(cp.load,cp,Config.defaults()); if ok then config=value end end
    local ok,api=pcall(require,"component")
    if ok then
      for _,machine in ipairs(config and config.alvearies or {}) do
        local gate=machine.routing and machine.routing.gate
        if gate then pcall(function() api.proxy(gate.address).setOutput(gate.side,gate.off) end) end
      end
      local export=state.pendingExternal
      if export then
        local gate=export.gate
        if gate then pcall(function() api.proxy(gate.address).setOutput(gate.side,gate.off) end) end
        if export.exportAddress then
          pcall(function() api.proxy(export.exportAddress).setExportConfiguration(export.exportSide,1) end)
        end
      end
      for _,request in pairs(state.meRequests or {}) do
        -- An unresolved transfer still needs its original slot contents as
        -- evidence. Its filters are cleared after reconciliation, not here.
        if not state.pending and request.ep and request.ep.managed then
          pcall(function() api.proxy(request.ep.address).setInterfaceConfiguration(request.slot) end)
        end
      end
    end
    if fs.exists(data.."/control.lua") then fs.remove(data.."/control.lua") end
    print("Cancelled all work. Bees remain in place; no cycles will be resumed.")
  end
  if cmd=="cancel" then
    state=sp:load({jobs={},reservations={},transactions={},events={}})
    cancelWork(); return
  end
  local c=cp:load(Config.defaults())
  local Components=require("lib.components"); local Inventory=require("lib.inventory")
  local Storage=require("lib.storage."..c.storage.kind)
  if cmd=="resume" or cmd=="breed" or cmd=="convert" or cmd=="populate" or cmd=="imprint" then
    -- OpenOS concatenates module source while loading it. Compile worker code
    -- before the large journal is resident, even when manual GC is unavailable.
    require("lib.scanner"); if c.storage.kind=="me_interface" then require("lib.scanner_me") end
    require("lib.scheduler"); require("lib.ui.status")
    for _,machine in ipairs(c.alvearies) do require("lib.breeders."..(machine.backend or "alveary")) end
  end
  state=sp:load({jobs={},reservations={},transactions={},events={}})
  U.collect()
  local function save() sp:save(state) end
  local components=Components.new(); local inv=Inventory.new(components,state,save)
  local function cancellationPending()
    if state.cancelRequested then return true end
    if not fs.exists(data.."/control.lua") then return false end
    local request=ctl:load({})
    return request.action=="cancel" or request.action=="stop"
  end
  local storage=Storage.new(c.storage,inv,components,{cancelled=cancellationPending})
  local scannerInstance,schedulerInstance
  local function scanner()
    if not scannerInstance then
      U.collect()
      scannerInstance=require("lib.scanner").new(c.scanner,inv,state,save,computer.uptime,storage)
    end
    return scannerInstance
  end
  local function scheduler()
    if not schedulerInstance then
      U.collect()
      schedulerInstance=require("lib.scheduler").new(c,state,components,inv,storage,scanner(),save,computer.uptime)
    end
    return schedulerInstance
  end
  local function scanInterval()
    return math.min(Config.pollInterval(c,"worker"),Config.pollInterval(c,"scanner"))
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
    local m=require("lib.mutations").new(source,c.aliases); m:index(items); return m
  end
  local function sendControl(action,id)
    ctl:save({action=action,id=id,requested=computer.uptime()}); print("Requested "..action..(id and " "..id or ""))
  end
  local function applyControl()
    if not fs.exists(data.."/control.lua") then return end
    local x=ctl:load({})
    if x.action=="cancel" or x.action=="stop" then cancelWork(c); return true end
    assert(fs.remove(data.."/control.lua"))
    if x.action=="pause" then
      if x.id then local j=assert(Jobs.find(state,x.id),"unknown job"); scheduler():pause(j,"Paused by user") else state.paused=true end
    elseif x.action=="resume" then scheduler():resume(x.id)
    end
    save()
  end
  local function run()
    if fs.exists(lock) then
      assert(f.recover,"Worker lock exists. Use resume --recover only after stopping the old process.")
      assert(fs.remove(lock))
    end
    local lf=assert(io.open(lock,"w")); lf:write(tostring(computer.address())); lf:close()
    local ok,err=xpcall(function()
      if cancellationPending() then cancelWork(c); return end
      Config.validate(c); storage:validate()
      if storage.interface then scanner():validate() end
      scheduler():recover()
      if state.pendingRequest then
        -- This request already passed the admission checks. Prepare its stock
        -- without resuming jobs from the previously drained plan.
        state.paused=false; state.stopped=false; state.stopping=false; save()
      else scheduler():resume(a[2] and cmd=="resume" and a[2] or nil) end
      local lastDisplay=""; local nextObservation=0
      while true do
        if applyControl() then break end
        local active,status
        if state.pendingRequest and not state.paused and not state.stopping then
          -- The saved batch carries its own exact source and return baseline.
          -- Its scanner phase checks returns directly; refresh global stock
          -- only when selecting a new batch, as in the standalone plan scanner.
          local items=state.scan and {} or storage:scan()
          do
            local success,ready,why=pcall(scheduler().prepareStock,scheduler(),items)
            if not success then status="BLOCKED"; state.error=tostring(ready); save()
            elseif not ready then status="SCANNING"; state.error=why; save()
            else
              state.error=nil
              Jobs.releaseCancelled(state)
              items=storage:scan()
              local req=state.pendingRequest; local m=mutations(items)
              local plan,e=require("lib.planner").plan(req.target,m,items,c); assert(plan,e)
              Jobs.create(state,plan,req.mode,req.count,req.flags,req); state.pendingRequest=nil; save()
              -- Planning is finished. Its graph/index and code need not compete
              -- with live storage/scanner snapshots for the rest of this run.
              m=nil; plan=nil; items=nil
              package.loaded["lib.planner"]=nil; package.loaded["lib.mutations"]=nil
              U.collect()
            end
          end
        else active,status=scheduler():step() end
        if cancellationPending() then cancelWork(c); break end
        -- Housing details are display data. Do not repeatedly query every
        -- housing or write a full recovery checkpoint just to redraw the UI.
        local now=computer.uptime()
        if now>=nextObservation or status=="DONE" or status=="STOPPED" or status=="BLOCKED" then
          require("lib.ui.status").observe(state,c,components,inv,now); nextObservation=now+1
        end
        local display=require("lib.ui.status").render(state,c,false)
        if display~=lastDisplay then require("lib.ui.status").show(display); lastDisplay=display end
        if status=="DONE" or status=="STOPPED" then break end
        if status=="BLOCKED" and not active and not state.paused then
          print("Progress saved. Repair the reported condition, then Beeomatic resume."); break
        end
        local scanning=not state.paused and (status=="SCANNING" or state.scan)
        local name,_,char=event.pull(scanning and scanInterval() or Config.pollInterval(c,"worker"))
        if name=="interrupted" then break end
        if name=="key_down" then
          if char==112 then state.paused=true elseif char==114 then scheduler():resume()
          elseif char==113 then cancelWork(c); break end
          save()
        end
      end
    end,debug.traceback)
    if cancellationPending() then cancelWork(c); ok=true; err=nil end
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
  if cmd=="status" then
    require("lib.ui.status").observe(state,c,components,inv,computer.uptime()); print(require("lib.ui.status").render(state,c,f.verbose)); return
  end
  if cmd=="logs" then for _,e in ipairs(state.events or {}) do print(tostring(e.time).." "..e.message) end; return end
  if cmd=="pause" then
    if fs.exists(lock) then sendControl(cmd,a[2])
    else
      if a[2] then scheduler():pause(assert(Jobs.find(state,a[2]),"unknown job"),"Paused by user") else state.paused=true end
      save()
      print("Saved "..cmd.." request") end
    return
  end
  if cmd=="resume" then
    if fs.exists(lock) and not f.recover then sendControl("resume",a[2]); return end
    assert(not state.cancelled or state.pendingRequest,"Work was cancelled. Start a new breed/convert/populate/imprint request.")
    assert(#state.jobs>0 or state.pendingRequest,"No saved work to resume")
    return run()
  end
  if cmd=="setup" or (cmd=="alveary" and sub=="add") then
    unlocked()
    if cmd=="setup" and f.reconfigure then
      assert(not state.pending and not state.pendingExternal and not state.scan and not next(state.meRequests or {}) and not next(state.meBatches or {}),
        "reconcile outstanding movements/scanning before reconfiguring storage")
      for _,j in ipairs(state.jobs) do
        assert(j.state=="DONE" or (state.stopped and not j.machine),"finish or cancel saved jobs before reconfiguring storage")
      end
    end
    local w=require("lib.setup").new(c,components,inv,function() cp:save(c) end)
    if cmd=="setup" then w:run(f.reconfigure) else w:addAlveary() end; return
  end
  if cmd=="alveary" then
    if sub=="list" then for _,x in ipairs(c.alvearies) do
      local e=x.environment or {}
      print(x.id.." "..x.name.." "..x.address.." | "..tostring(e.temperature).." / "..tostring(e.humidity)..
        " | priority "..tostring(x.priority or 99)..(x.enabled==false and " | disabled" or ""))
    end
    elseif sub=="configure" or sub=="edit" or sub=="rename" then
      unlocked()
      local machine; for _,x in ipairs(c.alvearies) do if x.id==a[3] then machine=x end end
      assert(machine,"unknown alveary ID; use Beeomatic alveary list")
      if sub=="rename" then
        local name=table.concat(a," ",4):match("^%s*(.-)%s*$")
        assert(name~="","Use alveary rename ID NAME")
        machine.name=name; cp:save(c); print("Renamed "..machine.id.." to "..name)
      else
        assert(not (state.machines and state.machines[machine.id] and state.machines[machine.id].job),"machine has saved work; finish or cancel it before reconfiguring")
        for _,j in ipairs(state.jobs) do assert(j.machine~=machine.id,"machine has saved work; finish or cancel it before reconfiguring") end
        require("lib.setup").new(c,components,inv,function() cp:save(c) end):editAlveary(machine)
      end
    elseif sub=="remove" then unlocked()
      for _,j in ipairs(state.jobs) do assert(j.machine~=a[3],"machine has saved work") end
      local found=false
      for n,x in ipairs(c.alvearies) do if x.id==a[3] then table.remove(c.alvearies,n); found=true; break end end
      assert(found,"unknown alveary ID"); Config.prunePorts(c); cp:save(c)
    else error("Use alveary list, add, remove ID, configure ID, or rename ID NAME") end; return
  end
  if cmd=="doctor" then
    if f.interface then
      unlocked(); assert(storage.interface,"Interface probe requires ME Interface storage mode")
      local port
      for _,ep in ipairs(c.storage.endpoints) do if ep.id==a[2] then port=ep end end
      assert(port,"Use doctor --interface PORT_ID from your configuration")
      storage:probe(port); print("PASS Interface exact-stock, partial extraction and return: "..port.id)
    end
    if f.probe then require("lib.ui.diagnostics").probe(components) end
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
      scheduler():adopt(j)
      print("Adopted observed machine state; resume will continue without repeating insertion")
    end
    if f.retry then
      unlocked(); local ok,err=inv:reconcile(); assert(ok,err)
      scheduler():retryInsertion(assert(Jobs.find(state,a[2]),"Use doctor --retry JOB_ID"))
    end
    if not fs.exists(lock) then
      local ok,why=inv:reconcile(); print(ok and "Transfer journal reconciled" or why)
      if storage.reconcile then local yes,e=storage:reconcile(); print(yes and "AE2 journal reconciled" or e) end
    end
    for _,r in ipairs(require("lib.ui.diagnostics").check(c,components,inv,storage)) do print((r.ok and "PASS " or "FAIL ")..r.name..(r.error and (": "..r.error) or "")) end
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
            if cancellationPending() then cancelWork(c); return end
            -- A pending scanner batch carries its own exact source/return state.
            -- Refresh all stock only when selecting the next batch.
            items=state.scan and {} or storage:scan()
            local ready,message
            if storage.prepare and not storage:prepare(items) then message="Inspecting ME stock"
            else ready,message=scanner():step(items) end
            if ready then break end
            if message and message~=lastMessage then print(message); lastMessage=message end
            local name,_,char=event.pull(scanInterval())
            if name=="key_down" and char==113 then cancelWork(c); return end
            if name=="interrupted" then
              error("Scanning stopped; progress saved. Run Beeomatic plan "..a[2].." again to continue.",0)
            end
          end
          items=storage:scan(); print("Scanning complete.")
        end)
        if cancellationPending() then cancelWork(c) end
        fs.remove(lock)
        if state.cancelled then return end
        if not ok then return blocked("Scanning paused: "..tostring(why).."\nProgress preserved; repair the scanner and rerun Beeomatic plan "..a[2]..".") end
      end
    end
    local m=mutations(items)
    local plan,reason=require("lib.planner").plan(a[2],m,items,c)
    if not plan then
      local message=reason or ("Not enough verified parent stock to reach "..a[2]..".")
      print(message); return nil,message
    end
    require("lib.ui.pager").show(require("lib.planner").render(plan,{verbose=f.verbose}),{enabled=not f["no-pager"]}); return
  end
  if cmd=="breed" or cmd=="convert" or cmd=="populate" or cmd=="imprint" then
    unlocked(); assert(a[2],"Specify a species")
    assert(not state.pendingRequest,"Saved request exists; use resume")
    assert(#state.jobs==0 or state.finished or state.stopped,"Existing work is preserved; use resume, or cancel to abandon it")
    local count=cmd=="populate" and U.assertNumber(a[3],1,1000000) or nil
    state.pendingRequest={target=a[2],mode=cmd,count=count,flags=f}; state.cancelled=nil; save(); return run()
  end
  error("Unknown command. Run Beeomatic help")
end
return M
