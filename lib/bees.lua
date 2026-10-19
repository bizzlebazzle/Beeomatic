local U=require("lib.util")
local M={}
function M.species(v) if type(v)=="table" then return U.lower(v.uid or v.name) end; return U.lower(v) end
function M.matches(v,target)
  target=U.lower(target)
  return type(v)=="table" and (U.lower(v.name)==target or U.lower(v.uid)==target) or M.species(v)==target
end
function M.kind(s)
  if not s then return nil end
  local n=U.lower(s.name)
  if n:find("beeprincess",1,true) then return "princess" end
  if n:find("beedrone",1,true) then return "drone" end
  if n:find("beequeen",1,true) then return "queen" end
  return nil -- Labels are localized and cannot establish caste reliably.
end
function M.scanned(s)
  local i=s and s.individual
  return i and i.active and i.inactive and i.active.species and i.inactive.species and true or false
end
function M.identity(s)
  if not s then return nil end
  -- NBT hash when exposed; complete individual data otherwise. Never visible species alone.
  return U.encode({name=s.name,damage=s.damage,tag=s.tag,nbt_hash=s.nbt_hash,
    individual=s.individual})
end
function M.count(items,target,kind,pure)
  local n=0
  for _,b in ipairs(items) do local s=b.stack or b
    if M.kind(s)==kind and M.scanned(s) and M.matches(s.individual.active.species,target)
      and (not pure or M.matches(s.individual.inactive.species,target)) then n=n+(s.size or 1) end
  end
  return n
end
return M
