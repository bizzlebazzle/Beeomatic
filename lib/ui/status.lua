local M={}
function M.render(state,c,verbose)
  local r={"========== BEEOMATIC ==========","Target: "..tostring(state.target or "none"),
    "State: "..(state.paused and "PAUSED" or state.finished and "DONE" or state.stopping and "DRAINING" or "ACTIVE")}
  local done=0; for _,j in ipairs(state.jobs or {}) do if j.state=="DONE" then done=done+1 end end
  r[#r+1]="Completed operations: "..done.."/"..#(state.jobs or {})
  for _,a in ipairs(c.alvearies) do
    local m=(state.machines or {})[a.id] or {}
    r[#r+1]=a.id.."  "..(m.state or "IDLE").."  "..(m.job or "")
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
