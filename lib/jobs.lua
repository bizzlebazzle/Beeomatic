local M={}
function M.create(state,plan,mode,count,flags)
  assert(not state.jobs or #state.jobs==0 or state.finished or state.stopped,"Existing work is preserved; use resume or stop before replacing it")
  for _,m in pairs(state.machines or {}) do assert(not m.job,"A machine is still reserved; recover its job before starting new work") end
  state.jobs={}; state.target=plan.target; state.finished=false; state.paused=false; state.stopping=false; state.stopped=false
  state.flags=flags or {}; state.reservations={}; state.machines={}; state.nextId=0
  local bySpecies={}
  for _,node in ipairs(plan.order) do
    if not node.available or node.species==plan.target then
      local conversion
      if node.species==plan.target and node.conversion and mode~="convert" then
        -- Recover the target princess before breeding/populating/imprinting it.
        state.nextId=state.nextId+1
        conversion={id="job"..state.nextId,species=node.species,mode="convert",
          dependencies={},state="WAITING",cycles=0,confirmed=0}
        state.jobs[#state.jobs+1]=conversion
      end
      state.nextId=state.nextId+1
      local job={id="job"..state.nextId,species=node.species,
        mode=node.species==plan.target and mode or (node.conversion and "convert" or "breed"),
        route=node.route,dependencies={},state="WAITING",cycles=0,confirmed=0,
        count=node.species==plan.target and count or nil}
      for _,ch in ipairs(node.children) do if bySpecies[ch.species] then job.dependencies[#job.dependencies+1]=bySpecies[ch.species] end end
      if conversion then job.dependencies[#job.dependencies+1]=conversion.id end
      state.jobs[#state.jobs+1]=job; bySpecies[node.species]=job.id
    end
  end
end
function M.find(state,id) for _,j in ipairs(state.jobs or {}) do if j.id==id then return j end end end
function M.ready(state,j)
  for _,id in ipairs(j.dependencies or {}) do local dep=M.find(state,id); if not dep or dep.state~="DONE" then return false end end
  return true
end
function M.pause(j,why)
  if j.state~="PAUSED" then j.previous=j.state end
  j.state="PAUSED"; j.error=tostring(why)
end
return M
