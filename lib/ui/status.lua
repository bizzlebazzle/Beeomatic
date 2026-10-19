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
function M.observe(state,c,components,inv,now)
  state.housings={}
  for _,a in ipairs(c.alvearies) do
    local ok,snapshot=pcall(function()
      local h=components:proxy(a.address,{"getQueen","getDrone"})
      local queen,qe=h.getQueen(); assert(not qe,tostring(qe))
      local drone,de=h.getDrone(); assert(not de,tostring(de))
      local qs,ds
      if not a.routing and a.backend~="routed" then
        local ep={id="breeder/"..a.id,transposer=a.transposer,side=a.side}
        qs=inv:get(ep,a.slots and a.slots.princess or 1)
        ds=inv:get(ep,a.slots and a.slots.drone or 2)
      end
      return {queen=beeInfo(queen,qs,"princess/queen"),drone=beeInfo(drone,ds,"drone")}
    end)
    state.housings[a.id]=ok and snapshot or {error=tostring(snapshot)}
  end
  state.housingObservedAt=now
end
function M.render(state,c,verbose)
  local r={"========== BEEOMATIC ==========","Target: "..tostring(state.target or "none"),
    "State: "..(state.paused and "PAUSED" or state.finished and "DONE" or state.stopping and "DRAINING" or "ACTIVE")}
  local done=0; for _,j in ipairs(state.jobs or {}) do if j.state=="DONE" then done=done+1 end end
  if state.stockPhase then r[#r+1]="Stock: "..state.stockPhase.."; drones awaiting inspection/analysis="..(state.stockRemaining or 0) end
  if state.scan and state.scan.phase then r[#r+1]="Shared scanner: "..state.scan.phase.." ("..state.scan.count.." bees)" end
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
      r[#r+1]="  "..tostring(e.temperature).." + "..tostring(e.humidity).." (configured/attested)"
      r[#r+1]="  last success: "..tostring(m.lastSuccess or "none")
    end
  end
  for _,j in ipairs(state.jobs or {}) do if j.state~="DONE" or verbose then
    r[#r+1]=j.id.." "..j.species.." "..j.mode.." "..j.state.." cycles="..j.cycles.." alleles="..(j.progress or 0).."/4 stable="..j.confirmed
    if j.error then r[#r+1]="  "..j.error end
  end end
  if state.storageCounts then r[#r+1]="Storage: princesses="..state.storageCounts.princess.." drones="..state.storageCounts.drone end
  if state.error then r[#r+1]="Intervention: "..state.error end
  r[#r+1]="Last completed cycle: "..tostring(state.lastCycle or "none")
  local last=(state.events or {})[#(state.events or {})]; if last then r[#r+1]="Recent: "..last.message end
  r[#r+1]="Foreground keys: p pause | r resume | q drain/stop"
  return table.concat(r,"\n")
end
return M
