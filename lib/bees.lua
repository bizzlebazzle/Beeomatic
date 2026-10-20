local U=require("lib.util")
local M={}
function M.displayName(v)
  local name=type(v)=="table" and (v.name or v.uid) or v
  name=tostring(name or "unknown")
  local suffix=name:match("^.-%.species[%.:_]?(.+)$")
  if suffix then name=suffix:gsub("(%l)(%u)","%1 %2"):gsub("[_%-]"," ") end
  return (name:gsub("^%l",string.upper))
end
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
  return i and i.isAnalyzed~=false and i.active and i.inactive and i.active.species and i.inactive.species and true or false
end
function M.identity(s)
  if not s then return nil end
  if type(s.tag)=="string" then
    local nbt=s.tag:sub(1,2)=="\31\139" and require("lib.nbt").canonical(s.tag)
    if nbt then return U.encode({name=s.name,damage=s.damage,nbt=nbt}) end
    return U.encode({name=s.name,damage=s.damage,tag=s.tag})
  end
  -- NBT hash when exposed; complete individual data otherwise. Never visible species alone.
  return U.encode({name=s.name,damage=s.damage,tag=s.tag,nbt_hash=s.nbt_hash,
    individual=s.individual})
end
-- Old checkpoints contain identities made from compressed bytes. Upgrade both
-- references and dictionary keys before reconciliation; raw stack tags stay
-- intact for OC callbacks. The next ordinary checkpoint persists the upgrade.
function M.upgradeIdentity(value)
  if type(value)~="string" or value:sub(1,1)~="{" or not value:find('["tag"]=',1,true) then return value end
  local used=false
  local yes,stack=pcall(require("lib.state_codec").read,function()
    if not used then used=true; return "return "..value end
  end)
  if not yes or type(stack)~="table" or type(stack.name)~="string" or type(stack.tag)~="string" then return value end
  for key in pairs(stack) do if key~="name" and key~="damage" and key~="tag" then return value end end
  -- Only gzip tags changed identity format. Re-encoding opaque tags creates
  -- another large string per receipt and needlessly fills the migration cache.
  if stack.tag:sub(1,2)~="\31\139" then return value end
  return M.identity(stack)
end
function M.migrateIdentities(state)
  local converted={}
  local function identity(value)
    if type(value)~="string" or value:sub(1,1)~="{" or not value:find('["tag"]=',1,true) then return value end
    local cached=converted[value]; if cached then return cached end
    local result=M.upgradeIdentity(value); converted[value]=result; return result
  end
  local function visit(t,sumCounts)
    local changes={}
    for key,value in pairs(t) do
      if type(value)=="table" then visit(value,t==state.scan and key=="before") else value=identity(value) end
      local newKey=identity(key)
      if newKey~=key then changes[#changes+1]={old=key,key=newKey,value=value} else t[key]=value end
    end
    for _,change in ipairs(changes) do
      local previous=t[change.key]
      if previous~=nil then
        if sumCounts and type(previous)=="number" and type(change.value)=="number" then
          change.value=previous+change.value
        else assert(U.equal(previous,change.value),"conflicting saved NBT identities; saved files preserved") end
      end
      t[change.old]=nil; t[change.key]=change.value
    end
  end
  visit(state)
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
