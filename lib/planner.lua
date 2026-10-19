local B=require("lib.bees"); local E=require("lib.environment"); local U=require("lib.util")
local M={}
function M.plan(target,mutations,items,c)
  target=mutations:resolve(target)
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
    local entry={princess={},drone={},counts={princess=0,drone=0}}
    for _,item in ipairs(items) do
      checkpoint()
      local s=item.stack or item; local kind=B.kind(s)
      if kind=="princess" or kind=="drone" then
        local n=B.count({s},name,kind,true)
        entry.counts[kind]=entry.counts[kind]+n
        if n>0 then entry[kind][#entry[kind]+1]=s end
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
    local knownPair=false; local climate={}
    local function checkPairs(princessSpecies,droneSpecies)
      for _,ps in ipairs(stock(princessSpecies).princess) do
        for _,ds in ipairs(stock(droneSpecies).drone) do
          checkpoint()
          knownPair=true
          for _,a in ipairs(E.select(c.alvearies,route,ps,ds,{})) do climate[a.id]=true end
        end
      end
    end
    checkPairs(route.parents[1],route.parents[2])
    if route.parents[1]~=route.parents[2] then checkPairs(route.parents[2],route.parents[1]) end
    if knownPair then suitable=U.keys(climate) end
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
    if count(name,"princess")>0 and count(name,"drone")>0 then
      n.seed={species=name,available=true,cost=0,children={}}
    elseif count(name,"drone")>c.reserveDrones then
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
      if n.missing then failure("missing hive stock or unknown/unobtainable species: "..n.species) end
      local edge=n.routes[frame.route]
      if not edge then
        active[n.species]=nil; done[n.species]=true; table.remove(stack)
      else
        local p=edge.parents[frame.parent]; frame.parent=frame.parent+1
        if not p then frame.route=frame.route+1; frame.parent=1
        elseif not p.plan then
          if active[p.species] then failure("dependency cycle at "..p.species)
          elseif not done[p.species] then
            active[p.species]=true; stack[#stack+1]={node=p,route=1,parent=1}
          end
        end
      end
    end
    local lines={"Cannot plan "..target.." from verified stock."}
    for _,message in ipairs(err.messages) do lines[#lines+1]="- "..message end
    if err.omitted then lines[#lines+1]="- Additional route failures omitted." end
    local unknown=0
    for _,item in ipairs(items) do local s=item.stack or item
      checkpoint()
      if B.kind(s) and not B.scanned(s) then unknown=unknown+(s.size or 1) end
    end
    if unknown>0 then lines[#lines+1]=tostring(unknown).." bees lack verified genes; analyse/inspect them before planning." end
    lines[#lines+1]="Check Beeomatic bees list for recognised stock; hive founders need a pure princess and drones."
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
  return {target=target,root=root,order=order}
end
function M.render(plan)
  local lines={"Target: "..plan.target}; local seen={}
  local function walk(n,depth)
    local label=n.available and " [stock present]" or n.conversion and " [convert spare princess]" or
      (" ["..tostring(n.route.chance).."% base; alvearies: "..table.concat(n.suitable,",").."]")
    lines[#lines+1]=string.rep("  ",depth)..n.species..label
    if n.environmentPending then lines[#lines+1]=string.rep("  ",depth+1).."Actual parent genes checked at dispatch" end
    for _,r in ipairs(n.unresolved or {}) do lines[#lines+1]=string.rep("  ",depth+1).."requires "..r end
    if not seen[n.species] then seen[n.species]=true; for _,ch in ipairs(n.children) do walk(ch,depth+1) end end
  end
  walk(plan.root,0); return table.concat(lines,"\n")
end
return M
