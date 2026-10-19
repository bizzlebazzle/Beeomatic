local B=require("lib.bees"); local E=require("lib.environment"); local U=require("lib.util")
local M={}
function M.plan(target,mutations,items,c)
  target=mutations:resolve(target)
  local expanded=0
  local function count(name,kind) return B.count(items,name,kind,true) end
  local function visit(name,path)
    expanded=expanded+1
    if expanded>(c.maxPlanExpansion or 20000) then return nil,"mutation search budget exceeded; narrow preferred routes or provide prerequisite stock" end
    if count(name,"princess")>0 and count(name,"drone")>0 then
      return {species=name,available=true,cost=0,children={}}
    end
    if path[name] then return nil,"dependency cycle at "..name end
    local nextPath=U.copy(path); nextPath[name]=true
    local routes=mutations:parents(name)
    if #routes==0 then
      if count(name,"drone")>c.reserveDrones then return {species=name,conversion=true,cost=5,children={}} end
      return nil,"missing hive stock or unknown/unobtainable species: "..name
    end
    local best,failures=nil,{}
    for _,route in ipairs(routes) do
      local children,cost,valid={},100/math.max(0.01,route.chance),true
      for _,parent in ipairs(route.parents) do
        local child,err=visit(parent,nextPath)
        if not child then failures[#failures+1]=err; valid=false; break end
        children[#children+1]=child; cost=cost+child.cost
      end
      if valid then
        local suitable,unresolved={},{}
        for _,a in ipairs(c.alvearies) do if a.enabled~=false then
          local ok,why=E.mutation(route,a)
          if ok then suitable[#suitable+1]=a.id else unresolved[#unresolved+1]=a.id..": "..why end
        end end
        -- When actual parent genomes exist, route ranking includes their survival
        -- requirements, not merely mutation condition descriptions.
        local knownPair=false; local climate={}
        for _,p in ipairs(items) do local ps=p.stack or p
          if B.kind(ps)=="princess" then for _,d in ipairs(items) do local ds=d.stack or d
            if B.kind(ds)=="drone" and
              ((B.count({ps},route.parents[1],"princess",true)>0 and B.count({ds},route.parents[2],"drone",true)>0) or
               (B.count({ps},route.parents[2],"princess",true)>0 and B.count({ds},route.parents[1],"drone",true)>0)) then
              knownPair=true
              for _,a in ipairs(E.select(c.alvearies,route,ps,ds,{})) do climate[a.id]=true end
            end
          end end
        end
        if knownPair then suitable=U.keys(climate) end
        if #suitable==0 then cost=cost+100000 end
        local pref=c.preferred[name]
        if not pref then
          for alias,p in pairs(c.preferred) do if mutations:resolve(alias)==name then pref=p end end
        end
        if pref and ((mutations:resolve(pref[1])==route.parents[1] and mutations:resolve(pref[2])==route.parents[2]) or
          (mutations:resolve(pref[2])==route.parents[1] and mutations:resolve(pref[1])==route.parents[2])) then cost=cost-0.1 end
        local candidate={species=name,route=route,children=children,cost=cost,suitable=suitable,
          unresolved=unresolved,environmentPending=true}
        if not best or cost<best.cost then best=candidate end
      end
    end
    return best,best and nil or table.concat(failures,"; ")
  end
  local root,err=visit(target,{})
  if not root then return nil,err end
  local order,seen={},{}
  local function flatten(n)
    if seen[n.species] then return end
    for _,ch in ipairs(n.children) do flatten(ch) end
    seen[n.species]=true; order[#order+1]=n
  end
  flatten(root)
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
