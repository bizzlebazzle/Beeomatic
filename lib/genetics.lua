local B=require("lib.bees"); local U=require("lib.util")
local M={}
function M.fertility(s)
  return B.scanned(s) and tonumber(s.individual.active.fertility) or 0
end
function M.fertileDonor(s)
  return M.fertility(s)>1 and (tonumber(s.individual.inactive.fertility) or 0)>1
end
function M.purity(s,target)
  if not B.scanned(s) then return 0 end
  return (B.matches(s.individual.active.species,target) and 1 or 0)+
    (B.matches(s.individual.inactive.species,target) and 1 or 0)
end
function M.equivalent(p,d)
  if not B.scanned(p) or not B.scanned(d) then return false end
  return U.equal(p.individual.active,p.individual.inactive) and
    U.equal(p.individual.active,d.individual.active) and U.equal(p.individual.active,d.individual.inactive)
end
function M.templateMatch(s,genes)
  if not B.scanned(s) then return false end
  for k,v in pairs(genes) do if k~="species" then
    if not U.equal(s.individual.active[k],v) or not U.equal(s.individual.inactive[k],v) then return false end
  end end; return true
end
function M.score(s,target,c,template)
  if not B.scanned(s) then return -math.huge end
  local score=M.purity(s,target)*(c.weights.species or 1000)
  for k,v in pairs(template or c.desired or {}) do if k~="species" then
    local w=c.weights[k] or 1
    if U.equal(s.individual.active[k],v) then score=score+1.3*w end
    if U.equal(s.individual.inactive[k],v) then score=score+w end
  end end
  score=score+math.min(100,tonumber(s.individual.active.fertility) or 0)
  return score
end
function M.complete(p,d,target,c,template)
  return M.purity(p,target)==2 and M.purity(d,target)==2 and
    (not c.fullEquivalence or M.equivalent(p,d)) and
    (not template or (M.templateMatch(p,template) and M.templateMatch(d,template)))
end
return M
