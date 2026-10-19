local U=require("lib.util"); local B=require("lib.bees")
local M={}
local temps={ICY=1,COLD=2,NORMAL=3,WARM=4,HOT=5,HELLISH=6}
local hums={ARID=1,NORMAL=2,DAMP=3}
local function upper(v) return tostring(v or ""):upper() end
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
  if not M.tolerance(species.temperature,e.temperature,g.temperatureTolerance,temps) then return false,"temperature "..tostring(species.temperature).." tolerance "..tostring(g.temperatureTolerance) end
  if not M.tolerance(species.humidity,e.humidity,g.humidityTolerance,hums) then return false,"humidity "..tostring(species.humidity).." tolerance "..tostring(g.humidityTolerance) end
  -- Permanent all-day/all-weather installation must support these traits or be explicitly attested.
  if not g.nocturnal and not e.daylightManaged then return false,"day/night operation not verified" end
  if not g.tolerantFlyer and not e.rainProtected then return false,"rain protection not verified" end
  if not g.caveDwelling and not e.skyAccess then return false,"sky access required" end
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
    if ok then ok,why=M.bee(p,a.environment) end
    -- Drone genome matters for future offspring; revalidate each actual princess every cycle.
    if ok and d then ok,why=M.bee(d,a.environment) end
    if ok then candidates[#candidates+1]=a else errors[#errors+1]=a.id..": "..tostring(why) end
  end end
  table.sort(candidates,function(a,b) return (a.priority or 99)<(b.priority or 99) end)
  return candidates,table.concat(errors," | ")
end
return M
