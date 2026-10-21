local B=require("lib.bees")
local M={}
local function beeInfo(individual,stack,role)
  if not individual and not stack then return nil end
  local ind=(stack and stack.individual) or individual or {}
  if not ind.active and individual and individual.active then ind=individual end
  local species=ind.active and ind.active.species
  local name=type(species)=="table" and (species.name or species.uid) or species
  return {kind=stack and B.kind(stack) or role,name=name or (stack and stack.label) or ind.ident or "unknown species",
    flowerProvider=ind.active and ind.active.flowerProvider,analysed=B.scanned({individual=ind})}
end
function M.observe(state,c,components,inv,now,observations,idleSeconds)
  local previous=state.housings or {}
  state.housings={}
  for _,a in ipairs(c.alvearies) do
    local seen=observations and observations[a.id]
    local old=previous[a.id]; local machine=(state.machines or {})[a.id]
    local age=old and old.observedAt and now-old.observedAt
    if idleSeconds and not seen and not (machine and machine.job) and age and age>=0 and age<idleSeconds then
      state.housings[a.id]=old
    else
      local ok,snapshot=pcall(function()
        if seen then return {queen=beeInfo(seen.queen,seen.princessStack,"princess/queen"),
          drone=beeInfo(seen.drone,seen.droneStack,"drone")} end
        local h=components:proxy(a.address,{"getQueen","getDrone"})
        local queen,qe=h.getQueen(); assert(not qe,tostring(qe))
        local drone,de=h.getDrone(); assert(not de,tostring(de))
        local qs,ds
        if not a.routing and a.backend~="routed" then
          local ep={id="breeder/"..a.id,transposer=a.transposer,side=a.side}
          local ps,dsSlot=a.slots and a.slots.princess or 1,a.slots and a.slots.drone or 2
          local inputs=inv:readSlots(ep,{ps,dsSlot}); qs=inputs[ps]; ds=inputs[dsSlot]
        end
        return {queen=beeInfo(queen,qs,"princess/queen"),drone=beeInfo(drone,ds,"drone")}
      end)
      state.housings[a.id]=ok and snapshot or {error=tostring(snapshot)}
      state.housings[a.id].observedAt=now
    end
  end
  state.housingObservedAt=now
end
local function speciesName(value)
  local name=tostring(value or "none"):gsub("^.*%.species", "")
  return (name:gsub("^%l",string.upper))
end
local activity={PREPARING="Loading bees",RUNNING="Breeding",COLLECTING="Collecting offspring",
  ASSESSING="Checking offspring",PAUSED="Paused",WAITING="Waiting",IDLE="Idle",DONE="Complete"}
-- These messages are normal scanner progress, despite being stored in state.error.
local function routine(message)
  return message=="Inspecting ME stock" or message=="Inspecting initial housing offspring"
    or message=="Scanner batch returned; rescanning ME stock"
    or message=="Waiting for analysed bees to return through ME"
    or message=="Shared scanner processing reserved batch"
    or message=="Scanner processing a reserved stack"
    or message=="Retrying proven untouched scanner source"
    or (message and (message:match("^Shared scanner analysing %d+ bees$") or message:match("^Scanning ")))
end
local function reason(message)
  if message=="Waiting for parent drone population and stable confirmation cycles" then
    return "Waiting for stable parent population"
  end
  -- Strip Lua source locations from the overview; verbose retains the original.
  return tostring(message):gsub("[^%s]+%.lua:%d+: ",""):gsub("\r\n","\n"):gsub("\r","\n")
end
local function parentWait(j)
  return j.state=="WAITING" and (j.error=="Waiting for stable parent population"
    or j.error=="Waiting for parent drone population and stable confirmation cycles")
end
local function rebreedWait(j)
  return j.state=="WAITING" and j.rebreeding and j.error and j.error:match("^Rebreeding ")
end
function M.render(state,c,verbose)
  if verbose then return M.details(state,c,true) end
  local done,queued,paused,busy=0,0,0,0
  local jobs={}; local warnings={}
  if state.error and not routine(state.error) then warnings[#warnings+1]=reason(state.error) end
  for _,j in ipairs(state.jobs or {}) do
    jobs[j.id]=j
    if j.state=="DONE" then done=done+1
    elseif j.state=="WAITING" then queued=queued+1
    elseif j.state=="PAUSED" then paused=paused+1
    else busy=busy+1 end
    if j.error and not parentWait(j) and not rebreedWait(j) then warnings[#warnings+1]=speciesName(j.species)..": "..reason(j.error) end
  end
  for _,a in ipairs(c.alvearies or {}) do
    local housing=(state.housings or {})[a.id]
    if housing and housing.error and not state.cancelled then
      warnings[#warnings+1]=(a.name or a.id)..": cannot read housing"
    end
  end
  local status=state.cancelled and "Cancelled" or state.paused and "Paused" or state.finished and "Complete" or state.stopped and "Stopped"
    or state.stopping and "Stopping after active work" or (#warnings>0 or paused>0) and "Needs attention" or "Working"
  local target=state.pendingRequest and state.pendingRequest.target or state.target
  local r={"BEEOMATIC | "..status,"Target: "..speciesName(target)}
  if #(state.jobs or {})>0 then
    r[#r+1]=string.format("Progress: %d/%d steps complete | %d active | %d queued%s",
      done,#state.jobs,busy,queued,paused>0 and (" | "..paused.." paused") or "")
  else r[#r+1]=state.pendingRequest and "Progress: preparing stock before planning" or "Progress: no saved work" end
  local q=not state.cancelled and state.scan
  if q then
    local scanner={REQUESTING="Fetching bees",INSERTING="Sending bees for analysis",PROCESSING="Analysing bees",
      VERIFYING="Checking returned bees",RETURNING="Returning analysed bees",EXTERNAL_RETURNED="Finishing analysis",
      INSPECTED="Finishing inspection"}
    r[#r+1]="Scanner: "..(scanner[q.phase or "PROCESSING"] or "Inspecting bees").." ("..(q.count or q.size or 1)..")"
  elseif state.error and routine(state.error) then
    r[#r+1]="Now: "..state.error
  elseif state.stockPhase=="PREPARING_STOCK" or state.stockPhase=="SCANNING" then
    r[#r+1]="Now: Checking stock"..((state.stockRemaining or 0)>0 and (" ("..state.stockRemaining.." drones remaining)") or "")
  end
  local idle=0
  for _,a in ipairs(c.alvearies or {}) do
    local m=(state.machines or {})[a.id] or {}; local j=jobs[m.job]
    if m.job or (m.state and m.state~="IDLE") then
      r[#r+1]=(a.name or a.id)..": "..(activity[m.state] or "Checking")..(j and (" - "..speciesName(j.species)) or "")
    else idle=idle+1 end
  end
  if idle>0 then r[#r+1]="Alvearies idle: "..idle end
  for _,j in ipairs(state.jobs or {}) do if rebreedWait(j) then r[#r+1]="Planned: "..reason(j.error) end end
  for _,j in ipairs(state.jobs or {}) do if parentWait(j) then
    r[#r+1]="Planned: "..speciesName(j.species).." - Waiting for stable parent population"
    for _,parent in ipairs(j.route and j.route.parents or {}) do
      local stock=(state.parentStock or {})[parent] or {}
      local stable=""
      for _,helper in ipairs(state.jobs or {}) do
        if helper.species==parent and helper.mode=="populate" and helper.state~="DONE" then
          stable=" | stable cycles "..(helper.confirmed or 0).."/"..(c.confirmCycles or 2)
          break
        end
      end
      r[#r+1]="  "..speciesName(parent)..": "..tostring(stock.count or "?").."/"..tostring(stock.minimum or c.minDrones or "?").." drones"..stable
    end
  end end
  if #warnings>0 then
    r[#r+1]="Attention:"
    for _,warning in ipairs(warnings) do r[#r+1]="  "..warning:gsub("\n","\n    ") end
    r[#r+1]="Details: Beeomatic status --verbose"
  end
  r[#r+1]=state.cancelled and "All work cancelled. Bees remain in place." or "p pause | r resume | q cancel all work"
  return table.concat(r,"\n")
end
-- Refresh the foreground dashboard instead of printing a new report every tick.
-- Redirected output and hosts without a terminal keep ordinary printable reports.
function M.show(text)
  -- Screen/GPU calls can fail even after isAvailable succeeds (for example,
  -- when a screen disconnects). Refreshing is optional; never abort the worker.
  pcall(function()
    local term=require("term")
    if term.isAvailable and term.isAvailable() and term.clear and term.setCursor
      and (not io.output or not io.stdout or io.output()==io.stdout) then
      term.clear(); term.setCursor(1,1)
    end
  end)
  print(text)
end
function M.details(state,c,verbose)
  local r={"========== BEEOMATIC ==========","Target: "..tostring(state.target or "none"),
    "State: "..(state.cancelled and "CANCELLED" or state.paused and "PAUSED" or state.finished and "DONE" or state.stopping and "DRAINING" or "ACTIVE")}
  local done=0; for _,j in ipairs(state.jobs or {}) do if j.state=="DONE" then done=done+1 end end
  if state.stockPhase then r[#r+1]="Stock: "..state.stockPhase.."; drones awaiting inspection/analysis="..(state.stockRemaining or 0) end
  if state.scan and state.scan.phase then r[#r+1]=(state.cancelled and "Inactive scanner recovery: " or "Shared scanner: ")..state.scan.phase.." ("..state.scan.count.." bees)" end
  r[#r+1]="Completed operations: "..done.."/"..#(state.jobs or {})
  for _,a in ipairs(c.alvearies) do
    local m=(state.machines or {})[a.id] or {}
    r[#r+1]=a.id.."  "..(m.state or "IDLE").."  "..(m.job or "")
    local housing=(state.housings or {})[a.id]
    if housing then
      if housing.error then r[#r+1]="  Bee information unavailable: "..housing.error
      elseif not housing.queen and not housing.drone then r[#r+1]="  Bees: empty"
      else
        for _,bee in ipairs({housing.queen or false,housing.drone or false}) do if bee then
          local flower=bee.flowerProvider or (bee.analysed and "unknown (not exposed)" or "unknown (analyse bee)")
          r[#r+1]="  "..bee.kind..": "..bee.name.." | Flowers required: "..flower
        end end
      end
    end
    if verbose then
      local e=a.environment or {}
      r[#r+1]="  Configured climate: temperature "..tostring(e.temperature).."; humidity "..tostring(e.humidity)
      r[#r+1]="  last success: "..tostring(m.lastSuccess or "none")
    end
  end
  for _,j in ipairs(state.jobs or {}) do if j.state~="DONE" or verbose then
    r[#r+1]=j.id.." "..j.species.." "..j.mode.." "..j.state.." cycles="..j.cycles.." alleles="..(j.progress or 0).."/4 stable="..j.confirmed
    if j.error then r[#r+1]="  "..j.error:gsub("\n","\n  ") end
  end end
  if state.storageCounts then r[#r+1]="Storage: princesses="..state.storageCounts.princess.." drones="..state.storageCounts.drone end
  if state.error then r[#r+1]="Intervention: "..state.error end
  r[#r+1]="Last completed cycle: "..tostring(state.lastCycle or "none")
  local last=(state.events or {})[#(state.events or {})]; if last then r[#r+1]="Recent: "..last.message end
  r[#r+1]="Foreground keys: p pause | r resume | q cancel all work"
  return table.concat(r,"\n")
end
return M
