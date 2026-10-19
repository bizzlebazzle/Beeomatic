local M={}; M.__index=M
function M.new(component) return setmetatable({api=component or require("component")},M) end
function M:proxy(address,methods)
  assert(address and address~="","explicit component address required")
  local p=self.api.proxy(address); assert(p,"component unavailable: "..address)
  -- OpenOS can expose callbacks as callable tables with protected metatables.
  -- component.methods is authoritative; false means indirect, not unavailable.
  local advertised=methods and #methods>0 and self.api.methods(address) or {}
  for _,m in ipairs(methods or {}) do
    assert(advertised[m]~=nil and p[m]~=nil,address.." missing method "..m)
  end
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
-- Small read-only previews for setup; do not print genetics or API documentation.
function M:inventorySummary(address)
  local sides={"down","up","north","south","west","east"}; local lines,choices={},{}
  local ok,p=pcall(self.proxy,self,address,{"getInventorySize","getStackInSlot"})
  if not ok then return {"Inventory preview unavailable"},choices end
  for side=0,5 do
    local yes,n=pcall(p.getInventorySize,side)
    if yes and type(n)=="number" and n>0 then
      local samples={}; local failed=false
      for slot=1,n do
        local readable,s=pcall(p.getStackInSlot,side,slot)
        if not readable then failed=true; break end
        if s then
          local label=tostring(s.label or s.name or "item"):gsub("[%c]"," "):sub(1,32)
          samples[#samples+1]="#"..slot.." "..label
          if #samples==2 then break end
        end
      end
      local line=sides[side+1].." ("..side.."): "..n.." slots | "..
        (#samples>0 and table.concat(samples,", ") or (failed and "contents unavailable" or "empty"))
      lines[#lines+1]=#line>72 and line:sub(1,69).."..." or line
      choices[#choices+1]={side=side,size=n,summary=lines[#lines]}
    elseif not yes then lines[#lines+1]=sides[side+1]..": unavailable" end
  end
  if #lines==0 then lines[1]="No adjacent inventories detected" end
  return lines,choices
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
