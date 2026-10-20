local U=require("lib.util"); local B=require("lib.bees")
local M={}
local temps={ICY=1,COLD=2,NORMAL=3,WARM=4,HOT=5,HELLISH=6}
local hums={ARID=1,NORMAL=2,DAMP=3}
local function upper(v) return tostring(v or ""):upper() end
local function accepted(preference,tolerance,levels)
  local values={}
  for value,rank in pairs(levels) do
    if M.tolerance(preference,value,tolerance,levels) then values[#values+1]={value=value,rank=rank} end
  end
  table.sort(values,function(a,b) return a.rank<b.rank end)
  local names={}; for _,v in ipairs(values) do names[#names+1]=v.value end
  return #names>0 and table.concat(names,"/") or "unknown (analyse bee)"
end
function M.parent(s,role)
  local g=s and s.individual and s.individual.active
  return B.displayName(g and g.species).." "..role
end
function M.tolerance(preference,actual,tolerance,levels)
  local p,a=levels[upper(preference)],levels[upper(actual)]
  if not p or not a then return false end
  if p==a then return true end
  local dir,n=upper(tolerance):match("^(%u+)_(%d+)$"); n=tonumber(n) or 0
  return math.abs(a-p)<=n and (dir=="BOTH" or (dir=="UP" and a>p) or (dir=="DOWN" and a<p))
end
function M.bee(s,e)
  if not B.scanned(s) then return false,"scan bee to obtain active/inactive genes" end
  if not e or not e.verified then return false,"verify configured operating environment" end
  local g=s.individual.active; local species=g.species
  if not M.tolerance(species.temperature,e.temperature,g.temperatureTolerance,temps) then
    return false,"needs temperature "..accepted(species.temperature,g.temperatureTolerance,temps)..
      " (active genes: "..upper(species.temperature)..", "..upper(g.temperatureTolerance)..")"
  end
  if not M.tolerance(species.humidity,e.humidity,g.humidityTolerance,hums) then
    return false,"needs humidity "..accepted(species.humidity,g.humidityTolerance,hums)..
      " (active genes: "..upper(species.humidity)..", "..upper(g.humidityTolerance)..")"
  end
  -- Day/night, rain and sky workability are observed through the housing. Lighting
  -- and rain shields are installed in-world and need no setup declarations.
  -- Flower requirements come from bee genetics and are displayed with the live
  -- housing. Actual availability is checked by the housing, not a setup list.
  return true
end
function M.mutation(route,a)
  local e=a.environment or {}; local missing={}
  for _,req in ipairs(route and route.specialConditions or {}) do
    if not (a.confirmed and a.confirmed[req]) then missing[#missing+1]=req end
  end
  if route and route.environment then
    for k,v in pairs(route.environment) do if upper(e[k])~=upper(v) then missing[#missing+1]=k.."="..tostring(v) end end
  end
  return #missing==0,table.concat(missing,"; ")
end
function M.select(alvearies,route,p,d,busy)
  local candidates,errors={},{}
  for _,a in ipairs(alvearies) do if a.enabled~=false and not (busy or {})[a.id] then
    local ok,why=M.mutation(route,a)
    if ok then
      ok,why=M.bee(p,a.environment)
      if not ok then why=M.parent(p,"princess").." "..tostring(why) end
    end
    -- Drone genome matters for future offspring; revalidate each actual princess every cycle.
    if ok and d then
      ok,why=M.bee(d,a.environment)
      if not ok then why=M.parent(d,"drone").." "..tostring(why) end
    end
    if ok then candidates[#candidates+1]=a else
      local e=a.environment or {}
      local label=a.id..(a.name and a.name~=a.id and (" ("..a.name..")") or "")
      errors[#errors+1]=label.." [temp "..upper(e.temperature)..", humidity "..upper(e.humidity).."]:\n  "..tostring(why)
    end
  end end
  table.sort(candidates,function(a,b) return (a.priority or 99)<(b.priority or 99) end)
  return candidates,table.concat(errors,"\n")
end
return M
