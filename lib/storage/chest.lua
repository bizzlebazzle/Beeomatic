local M={}; M.__index=M
function M.new(config,inventory) return setmetatable({config=config,inv=inventory},M) end
function M:scan()
  local r,seen={},{}
  for _,ep in ipairs(self.config.endpoints) do if not seen[ep.id] then
    seen[ep.id]=true; for _,i in ipairs(self.inv:scan(ep)) do r[#r+1]=i end
  end end; return r
end
function M:validate() assert(#self.config.endpoints>0,"register storage endpoint"); self:scan(); return true end
function M:materialize(item,endpoint)
  assert(item.endpoint.id==endpoint.id,"species is in an unreachable storage inventory: "..item.endpoint.id)
  -- Same physical shared inventory, viewed from this machine's transposer.
  return {endpoint=endpoint,slot=item.slot,stack=self.inv:get(endpoint,item.slot)}
end
function M:deposit(item,endpoint,owner)
  return self.inv:move(item,endpoint,self.inv:destination(endpoint,item.stack),item.stack.size,owner)
end
return M
