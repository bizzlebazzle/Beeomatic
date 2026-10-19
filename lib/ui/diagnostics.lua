local U=require("lib.util"); local Backend=require("lib.breeders.factory")
local M={}
function M.probe(components,out)
  out=out or print
  for _,c in ipairs(components:discover()) do
    out(c.address.." "..c.kind)
    for _,m in ipairs(U.keys(c.methods)) do
      local ok,doc=pcall(components.api.doc,c.address,m)
      out("  "..m.." "..(ok and tostring(doc or "") or ""))
    end
    if c.methods.getInventorySize~=nil and c.methods.getStackInSlot~=nil then
      local ok,invs=pcall(components.inventories,components,c.address)
      if ok then for _,i in ipairs(invs) do
        out("  side "..i.side.." inventory size "..i.size)
        for slot,s in ipairs(i.slots) do if s then out("    "..slot.." "..U.encode(s)) end end
      end else out("  inventory inspection failed: "..tostring(invs)) end
    end
  end
end
function M.check(c,components,inv,storage)
  local results={}
  local function check(name,fn)
    local ok,err=pcall(fn); results[#results+1]={name=name,ok=ok,error=ok and nil or tostring(err)}
  end
  check("storage",function() storage:validate() end)
  for _,a in ipairs(c.alvearies) do check(a.id,function() Backend.new(a,inv,components):validate() end) end
  if c.scanner.enabled then check("scanner",function()
    if storage.interface then require("lib.scanner_me").new(c.scanner,inv,inv.state,inv.save,function() return 0 end,storage):validate()
    else
      assert(c.scanner.isolatedVerified,"scanner provenance unverified")
      inv:size(c.scanner.input); inv:size(c.scanner.output); inv:size(c.scanner.storage)
    end
  end) end
  return results
end
return M
