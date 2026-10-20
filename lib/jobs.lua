local M={}
function M.releaseCancelled(state)
  if not state.cancelCleanup or state.pending or state.pendingExternal or state.scan or next(state.meRequests or {}) then return end
  state.reservations={}; state.meBatches={}; state.cancelCleanup=nil
end
function M.cancel(state)
  -- Discard scheduling, not unresolved physical receipts. No component call or
  -- healthy queen/scanner is required to abandon the breeding process.
  state.jobs={}; state.machines={}; state.pendingRequest=nil; state.target=nil
  state.error=nil; state.parentStock=nil; state.stockPhase=nil; state.stockRemaining=nil; state.stockReady=nil
  state.finished=false; state.paused=false; state.stopping=false; state.stopped=true
  state.cancelled=true; state.cancelCleanup=true; state.cancelRequested=nil
  local q=state.scan
  local source=q and q.source
  local request=source and (state.meRequests or {})[tostring(source.endpoint.id)..":"..tostring(source.slot)]
  local unstarted=q and (q.phase=="REQUESTING" or q.phase=="INSPECTED" or
    (q.phase=="INSERTING" and request and not request.consumed))
  if unstarted and not q.inserted and not (state.pending and state.pending.scanning) then
    state.scan=nil -- no scanner insertion was started in these phases
  end
  for _,request in pairs(state.meRequests or {}) do request.phase="RETURNING" end
  M.releaseCancelled(state)
end
function M.create(state,plan,mode,count,flags,acceptedRequest)
  -- CLI requests are saved only after checking that previous work is finished
  -- or stopped. Stock preparation/restart may have since cleared those flags.
  local accepted=acceptedRequest~=nil and acceptedRequest==state.pendingRequest
  assert(not state.jobs or #state.jobs==0 or state.finished or state.stopped or accepted,"Existing work is preserved; use resume or cancel before replacing it")
  for _,m in pairs(state.machines or {}) do assert(not m.job,"A machine is still reserved; recover its job before starting new work") end
  for _,j in ipairs(state.jobs or {}) do assert(not j.machine,"A job still has a machine; recover it before starting new work") end
  state.jobs={}; state.target=plan.target; state.finished=false; state.paused=false; state.stopping=false; state.stopped=false
  state.cancelled=nil
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
