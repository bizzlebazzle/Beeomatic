local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M
function M.new(housing,aliases)
  return setmetatable({housing=housing,aliases=aliases or {},names={},labels={},cache={}},M)
end
function M:index(items)
  local function add(s)
    if type(s)=="table" and s.name then
      local id=U.lower(s.uid or s.name); self.names[U.lower(s.name)]=id; self.names[id]=id
      self.labels[id]=s.name
    end
  end
  -- Learn names from stock and queried parents. The global species and recipe
  -- lists can exhaust 2 MiB before any target-specific planning can begin.
  for _,b in ipairs(items or {}) do local s=b.stack or b; if B.scanned(s) then
    add(s.individual.active.species); add(s.individual.inactive.species)
  end end
end
function M:resolve(name)
  local n=U.lower(name); n=U.lower(self.aliases[n] or n)
  return self.names[n] or n
end
function M:parents(name)
  name=self:resolve(name)
  if self.cache[name] then return self.cache[name] end
  local r={}
  for _,p in pairs(assert(self.housing.getBeeParents(name),"Forestry returned no mutation data")) do
    assert(p.allele1 and p.allele2 and tonumber(p.chance),"unrecognized Forestry mutation shape")
    local q=U.copy(p)
    local function id(s)
      local resolved=self:resolve(type(s)=="table" and (s.uid or s.name) or s)
      if type(s)=="table" and s.name then
        self.labels[resolved]=s.name; self.names[U.lower(s.name)]=resolved; self.names[resolved]=resolved
      end
      return resolved
    end
    q.parents={id(p.allele1),id(p.allele2)}; r[#r+1]=q
  end
  table.sort(r,function(a,b) return table.concat(a.parents,"+")<table.concat(b.parents,"+") end)
  self.cache[name]=r; return r
end
function M:displayName(name)
  local label=self.labels[self:resolve(name)]
  if label then return B.displayName(label) end
  return (B.displayName(name):gsub("(%s)(%l)",function(space,ch) return space..ch:upper() end))
end
return M
