local B=require("lib.bees"); local E=require("lib.environment"); local U=require("lib.util")
local M={}
function M.plan(target,mutations,items,c,mutationOnly,mode)
  local requested=target
  target=mutations:resolve(target)
  local function display(name)
    return mutations.displayName and mutations:displayName(name) or B.displayName(name)
  end
  -- OpenOS resets the CPU watchdog when sleeping, even with a zero timeout.
  -- Count inner-loop work too: one route can inspect thousands of bee stacks.
  local work=0
  local function checkpoint()
    work=work+1
    if work>=128 then
      work=0
      if os.sleep then os.sleep(0) end
    end
  end
  local stockCache={}
  local function stock(name)
    if stockCache[name] then return stockCache[name] end
    local entry={princess={},drone={},counts={princess=0,drone=0},largest=0}
    local drones={}
    for _,item in ipairs(items) do
      checkpoint()
      local s=item.stack or item; local kind=B.kind(s)
      if kind=="princess" or kind=="drone" then
        local n=B.count({s},name,kind,true)
        entry.counts[kind]=entry.counts[kind]+n
        local t=c.templates or {}
        local protected=n>0 and t.enabled and ((t.identity and B.itemIdentity(item)==t.identity) or
          (not t.identity and item.endpoint and item.endpoint.id==t.endpointId and item.slot==t.slot))
        if n>0 and not protected then
          entry[kind][#entry[kind]+1]=s
          if kind=="drone" then
            local key=B.itemIdentity(item)
            drones[key]=(drones[key] or 0)+n
            entry.largest=math.max(entry.largest,drones[key])
          end
        end
      end
    end
    stockCache[name]=entry
    return entry
  end
  local function count(name,kind) return stock(name).counts[kind] end
  local function candidate(name,route,children)
    local cost=100/math.max(0.01,route.chance)
    local suitable,unresolved={},{}
    for _,a in ipairs(c.alvearies) do if a.enabled~=false then
      checkpoint()
      local ok,why=E.mutation(route,a)
      if ok then suitable[#suitable+1]=a.id else unresolved[#unresolved+1]=a.id..": "..why end
    end end
    -- When actual parent genomes exist, route ranking includes their survival
    -- requirements, not merely mutation condition descriptions.
    local knownPair=false; local climate={}; local climateFailures,climateSeen={},{}
    local function checkPairs(princessSpecies,droneSpecies)
      for _,ps in ipairs(stock(princessSpecies).princess) do
        for _,ds in ipairs(stock(droneSpecies).drone) do
          checkpoint()
          knownPair=true
          local compatible,why=E.select(c.alvearies,route,ps,ds,{})
          for _,a in ipairs(compatible) do climate[a.id]=true end
          if #compatible==0 and why~="" and not climateSeen[why] then
            climateSeen[why]=true
            if #climateFailures<6 then climateFailures[#climateFailures+1]=why end
          end
        end
      end
    end
    checkPairs(route.parents[1],route.parents[2])
    if route.parents[1]~=route.parents[2] then checkPairs(route.parents[2],route.parents[1]) end
    if knownPair then
      suitable=U.keys(climate)
      if #suitable==0 and #climateFailures>0 then unresolved=climateFailures end
    end
    if #suitable==0 then cost=cost+100000 end
    local pref=c.preferred[name]
    if not pref then
      for alias,p in pairs(c.preferred) do checkpoint(); if mutations:resolve(alias)==name then pref=p end end
    end
    if pref and ((mutations:resolve(pref[1])==route.parents[1] and mutations:resolve(pref[2])==route.parents[2]) or
      (mutations:resolve(pref[2])==route.parents[1] and mutations:resolve(pref[1])==route.parents[2])) then cost=math.max(0,cost-0.1) end
    for _,child in ipairs(children) do cost=cost+child.cost end
    return {species=name,route=route,children=children,cost=cost,suitable=suitable,
      unresolved=unresolved,environmentPending=true}
  end

  -- Discover the prerequisite graph once. Counting recursive visits made shared
  -- Forestry routes exhaust the old budget exponentially, even on small graphs.
  local nodes,queue={},{}
  local function node(name)
    if not nodes[name] then
      nodes[name]={species=name,routes={},dependents={}}
      queue[#queue+1]=nodes[name]
    end
    return nodes[name]
  end
  local targetNode=node(target)
  local index,limit=1,c.maxPlanExpansion or 20000
  while index<=#queue and index<=limit do
    checkpoint()
    local n=queue[index]; local name=n.species
    local seed=stock(name)
    local reserve=mode=="populate" and name==target and 0 or c.reserveDrones
    if not (mutationOnly and name==target) and #seed.princess>0 and seed.largest>reserve then
      n.seed={species=name,available=true,cost=0,children={}}
    elseif not (mutationOnly and name==target) and seed.largest>c.reserveDrones then
      -- Known species can be recovered from spare drones even when they also
      -- have mutation recipes; do not rebuild their entire ancestry first.
      n.seed={species=name,conversion=true,cost=5,children={}}
    else
      for _,route in ipairs(mutations:parents(name)) do
        checkpoint()
        local edge={result=n,route=route,remaining=#route.parents,children={},parents={}}
        n.routes[#n.routes+1]=edge
        for slot,parent in ipairs(route.parents) do
          local p=node(parent); edge.parents[slot]=p
          p.dependents[#p.dependents+1]={edge=edge,slot=slot}
        end
      end
      if #n.routes==0 then n.missing=true end
    end
    index=index+1
  end
  local limited=index<=#queue

  -- Settle plans in increasing cost, like Dijkstra with two-parent edges.
  -- Each species settles once; each route is scored once both parents settle.
  -- Costs are nonnegative, so selected children always precede their result
  -- and cycles without a route from verified stock cannot seed themselves.
  local heap,sequence={},0
  local function before(a,b)
    return a.plan.cost<b.plan.cost or (a.plan.cost==b.plan.cost and a.sequence<b.sequence)
  end
  local function offer(n,plan)
    if n.plan or (n.pending and n.pending.cost<=plan.cost) then return end
    n.pending=plan; sequence=sequence+1
    local entry={node=n,plan=plan,sequence=sequence}; local at=#heap+1
    while at>1 do
      checkpoint()
      local parent=math.floor(at/2)
      if not before(entry,heap[parent]) then break end
      heap[at]=heap[parent]; at=parent
    end
    heap[at]=entry
  end
  local function pop()
    local first=heap[1]; local last=table.remove(heap)
    if #heap>0 then
      local at=1
      while at*2<=#heap do
        checkpoint()
        local child=at*2
        if child<#heap and before(heap[child+1],heap[child]) then child=child+1 end
        if not before(heap[child],last) then break end
        heap[at]=heap[child]; at=child
      end
      heap[at]=last
    end
    return first
  end
  for _,n in ipairs(queue) do checkpoint(); if n.seed then offer(n,n.seed) end end
  local settled={}
  while #heap>0 do
    checkpoint()
    local entry=pop(); local n=entry.node
    if not n.plan and n.pending==entry.plan then
      n.plan=entry.plan; settled[#settled+1]=n.plan
      if n==targetNode then break end
      for _,dependent in ipairs(n.dependents) do
        checkpoint()
        local edge=dependent.edge
        edge.children[dependent.slot]=n.plan; edge.remaining=edge.remaining-1
        if edge.remaining==0 and not edge.result.plan then
          offer(edge.result,candidate(edge.result.species,edge.route,edge.children))
        end
      end
    end
  end
  local root=targetNode.plan
  if not root then
    local err={messages={},seen={}}
    local function failure(message)
      if not err.seen[message] then
        err.seen[message]=true
        if #err.messages<6 then err.messages[#err.messages+1]=message else err.omitted=true end
      end
    end
    if limited then failure("mutation graph exceeds unique-species search limit ("..limit.."); increase maxPlanExpansion") end
    -- Explain only unresolved dependencies, visiting each species/route once.
    local active,done={},{}
    local stack={{node=targetNode,route=1,parent=1}}; active[target]=true
    while #stack>0 do
      checkpoint()
      local frame=stack[#stack]; local n=frame.node
      if n.missing then
        failure(display(n.species)..": no mutation recipe reported; pure stock: "..
          count(n.species,"princess").." princesses, "..count(n.species,"drone").." drones."..
          (count(n.species,"drone")>0 and (" Largest identical group: "..stock(n.species).largest..".") or ""))
      end
      local edge=n.routes[frame.route]
      if not edge then
        active[n.species]=nil; done[n.species]=true; table.remove(stack)
      else
        local p=edge.parents[frame.parent]; frame.parent=frame.parent+1
        if not p then frame.route=frame.route+1; frame.parent=1
        elseif not p.plan then
          if active[p.species] then failure("dependency cycle at "..display(p.species))
          elseif not done[p.species] then
            active[p.species]=true; stack[#stack+1]={node=p,route=1,parent=1}
          end
        end
      end
    end
    local lines={"Cannot plan "..display(target).." from verified stock."}
    for _,message in ipairs(err.messages) do lines[#lines+1]="- "..message end
    if err.omitted then lines[#lines+1]="- Additional route failures omitted." end
    local unknown=0
    for _,item in ipairs(items) do local s=item.stack or item
      checkpoint()
      if B.kind(s) and not B.scanned(s) then unknown=unknown+(s.size or 1) end
    end
    if unknown>0 then lines[#lines+1]=tostring(unknown).." bees lack verified genes; analyse/inspect them before planning." end
    lines[#lines+1]="Recipes were followed back to these unresolved prerequisites."
    lines[#lines+1]="Supply a pure princess + spendable drones, or more than "..c.reserveDrones.." pure drones for princess conversion (one identical group)."
    lines[#lines+1]="Species with no mutation recipe may require hives, trades or other external sources. Check Beeomatic bees list."
    return nil,table.concat(lines,"\n")
  end
  -- Settlement order already places every prerequisite before its result.
  -- Keep only the selected target ancestry, not explored alternative routes.
  local needed,stack={}, {root}
  while #stack>0 do
    checkpoint()
    local n=table.remove(stack)
    if not needed[n.species] then
      needed[n.species]=true
      for _,child in ipairs(n.children) do stack[#stack+1]=child end
    end
  end
  local order={}
  for _,n in ipairs(settled) do checkpoint(); if needed[n.species] then order[#order+1]=n end end
  local names={}
  for _,n in ipairs(order) do
    checkpoint()
    names[n.species]=display(n.species)
  end
  return {target=target,requested=requested,root=root,order=order,names=names}
end
function M.render(plan,options)
  options=options or {}
  local function name(id) return (plan.names or {})[id] or B.displayName(id) end
  local stock,steps,checks={}, {}, {}
  local breeds,conversions=0,0
  for _,n in ipairs(plan.order) do
    if n.available then stock[#stock+1]=name(n.species)
    else
      steps[#steps+1]=n
      if n.conversion then conversions=conversions+1
      else
        breeds=breeds+1
        if #(n.suitable or {})==0 then checks[#checks+1]={step=#steps,node=n} end
      end
    end
  end
  local lines={"Breeding plan: "..name(plan.target),
    string.format("%d breeding step%s | %d princess conversion%s | %d species in stock",
      breeds,breeds==1 and "" or "s",conversions,conversions==1 and "" or "s",#stock)}
  if #checks>0 then
    lines[#lines+1]=""
    lines[#lines+1]="NEEDS ATTENTION: "..#checks..(#checks==1 and " step has" or " steps have").." no confirmed suitable alveary."
    for _,check in ipairs(checks) do
      lines[#lines+1]="  Step "..check.step.." - "..name(check.node.species)..":"
      local reasons=check.node.unresolved or {}
      if #reasons==0 then lines[#lines+1]="    Check registered alvearies and parent climate requirements."
      else for _,reason in ipairs(reasons) do lines[#lines+1]="    "..reason end end
    end
    lines[#lines+1]="  Review these requirements before starting breeding."
  end
  lines[#lines+1]=""
  if #stock>0 then table.sort(stock); lines[#lines+1]="Stock present: "..table.concat(stock,", ") end
  if #steps==0 then
    lines[#lines+1]="Target already has a verified princess and drones; no mutations needed."
  else
    lines[#lines+1]=""
    lines[#lines+1]="Steps in breeding order (shared prerequisites listed once):"
    for i,n in ipairs(steps) do
      if n.conversion then
        lines[#lines+1]=string.format("%2d. Recover %s princess from spare drones",i,name(n.species))
      else
        local parents={}; for _,id in ipairs(n.route.parents) do parents[#parents+1]=name(id) end
        lines[#lines+1]=string.format("%2d. %s <- %s (%g%% base)%s",i,name(n.species),table.concat(parents," + "),n.route.chance,
          #(n.suitable or {})==0 and " [CHECK]" or "")
        if options.verbose then lines[#lines+1]="    Alvearies: "..(#(n.suitable or {})>0 and table.concat(n.suitable,", ") or "none confirmed") end
      end
    end
    lines[#lines+1]=""
    lines[#lines+1]="Parent genes, spare princesses and drone reserves are checked before each step."
    local commandTarget=plan.requested or plan.target
    lines[#lines+1]="To start: Beeomatic breed "..(commandTarget:find("%s") and string.format("%q",commandTarget) or commandTarget)
  end
  if options.verbose then
    lines[#lines+1]=""; lines[#lines+1]="Species IDs:"
    for _,n in ipairs(plan.order) do lines[#lines+1]="  "..name(n.species).." = "..n.species end
  end
  return table.concat(lines,"\n")
end
return M
