local M={}; M.__index=M
function M.new(component) return setmetatable({api=component or require("component")},M) end
function M:proxy(address,methods)
  assert(address and address~="","explicit component address required")
  local p=self.api.proxy(address); assert(p,"component unavailable: "..address)
  for _,m in ipairs(methods or {}) do assert(type(p[m])=="function",address.." missing method "..m) end
  return p
end
function M:discover()
  local all={}
  for address,kind in self.api.list() do
    local ok,methods=pcall(self.api.methods,address)
    all[#all+1]={address=address,kind=kind,methods=ok and methods or {},error=not ok and tostring(methods) or nil}
  end
  table.sort(all,function(a,b) return a.address<b.address end); return all
end
function M:inventories(address)
  local p=self:proxy(address,{"getInventorySize","getStackInSlot"}); local r={}
  for side=0,5 do
    local ok,n=pcall(p.getInventorySize,side)
    if ok and n then
      local slots={}; for s=1,n do slots[s]=p.getStackInSlot(side,s) or false end
      r[#r+1]={side=side,size=n,slots=slots}
    end
  end
  return r
end
return M
