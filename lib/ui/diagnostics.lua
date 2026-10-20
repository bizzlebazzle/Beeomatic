local U=require("lib.util"); local Backend=require("lib.breeders.factory")
local M={}
-- Only scratch database entries change. Never configure an Interface or move
-- bees while investigating an identity failure.
function M.nbt(storage,out)
  out=out or print
  local B=require("lib.bees")
  assert(storage.interface,"NBT check requires ME Interface storage mode")
  local state=storage.state
  assert(not state.pending and not state.pendingExternal,"reconcile unresolved movement before an NBT check")
  local q=state.scan
  local item=q and ((q.returnProbe and q.returnProbe.item) or q.resultItem or q.item)
  if not item then
    for _,s in pairs(assert(storage:network().getItemsInNetwork(),"ME unavailable")) do
      if B.kind(s) and (s.size or 0)>0 then item={stack=s}; break end
    end
  end
  local s=assert(item and item.stack,"no network bee available for NBT check")
  local function hex(tag)
    if type(tag)~="string" then return type(tag) end
    return (tag:sub(1,16):gsub(".",function(ch) return string.format("%02x",ch:byte()) end))
  end
  local function describe(label,stack)
    if not stack then out(label..": EMPTY"); return end
    out(label..": "..tostring(stack.name).." damage="..U.encode(stack.damage)..
      " tag="..type(stack.tag).." bytes="..(type(stack.tag)=="string" and #stack.tag or 0).." head="..hex(stack.tag))
  end
  out("Database: "..storage.config.database.." configured slots="..storage.config.databaseSlots)
  describe("Requested",s)
  local filter={name=s.name,damage=s.damage,label=s.label}
  local matches=assert(storage:network().getItemsInNetwork(filter),"ME unavailable")
  local n,exact=0,0
  for _,entry in pairs(matches) do n=n+1; if B.identity(entry)==B.identity(s) then exact=exact+1 end end
  out("Network variants="..n.." exact matches="..exact)
  assert(n>0 and n<=storage.config.databaseSlots,"matching variants missing or exceed configured database capacity")
  local db=storage.components:proxy(storage.config.database,{"clear","get"})
  storage.databaseEntry=nil
  for slot=1,n do db.clear(slot) end
  local yes,why=storage:network().store(filter,storage.config.database,1,n)
  out("Copy result="..tostring(yes).." "..tostring(why or ""))
  for slot=1,n do
    local entry=db.get(slot); describe("Entry "..slot,entry)
    if entry then
      out("  name="..tostring(entry.name==s.name).." damage="..tostring(entry.damage==s.damage)..
        " NBT="..tostring(entry.tag==s.tag).." identity="..tostring(B.identity(entry)==B.identity(s)))
      local again=db.get(slot)
      out("  stable read="..tostring(B.identity(entry)==B.identity(again)))
      if type(entry.tag)=="string" and type(s.tag)=="string" and entry.tag~=s.tag then
        local pos=1
        while pos<=math.min(#entry.tag,#s.tag) and entry.tag:byte(pos)==s.tag:byte(pos) do pos=pos+1 end
        out("  first NBT difference="..pos.." requested="..tostring(s.tag:byte(pos)).." copied="..tostring(entry.tag:byte(pos)))
      end
    end
  end
  out("NBT check complete; no bees moved and saved progress unchanged.")
end
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
