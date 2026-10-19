local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M
function M.new(config,inv,state,save,now,storage)
  if storage and storage.interface then return require("lib.scanner_me").new(config,inv,state,save,now,storage) end
  return setmetatable({config=config,inv=inv,state=state,save=save,now=now},M)
end
function M:step(items)
  local c=self.config; local q=self.state.scan
  if q then
    local returned=self.inv:get(c.storage,q.returnSlot)
    if returned and B.scanned(returned) and returned.name==q.name and returned.size==q.size and
      (not q.ident or returned.individual.ident==q.ident) and #self.inv:scan(c.input)==0 and #self.inv:scan(c.output)==0 then
      self.inv:release("scanner"); self.state.scan=nil; self.save(); return true
    end
    if returned and B.identity(returned)==q.original and #self.inv:scan(c.input)==0 and #self.inv:scan(c.output)==0 then
      -- Intent was persisted, but no physical scan insertion occurred.
      self.inv:release("scanner"); self.state.scan=nil; self.save(); return false,"Retrying proven untouched scanner source"
    end
    local results=self.inv:scan(c.output)
    if #results>1 then error("Scanner output contaminated; expected a single isolated stack") end
    local r=results[1]
    if r then
      assert(B.scanned(r.stack) and r.stack.name==q.name and r.stack.damage==q.damage and r.stack.size==q.size,
        "scanner output identity/count mismatch")
      -- Analysis changes NBT. A dedicated one-stack path establishes provenance.
      if q.ident then assert(r.stack.individual.ident==q.ident,"scanner changed species identity") end
      assert(not self.inv:get(c.storage,q.returnSlot),"original scanner source slot is occupied")
      self.inv:move(r,c.storage,q.returnSlot,r.stack.size,"scanner")
      self.inv:release("scanner"); self.state.scan=nil; self.save(); return true
    end
    assert(self.now()-q.started<(c.timeout or 600),"Scanner timeout: check honey, power, input and output; progress preserved")
    return false,"Scanner processing a reserved stack"
  end
  for _,i in ipairs(items) do if B.kind(i.stack) and not B.scanned(i.stack) then
    assert(c.enabled,"Unscanned bees: analyze with a Beealyzer or configure isolated automated scanner, then resume")
    assert(not i.network,"unscanned ME bee: export to archive chest and resume")
    assert(c.isolatedVerified,"verify dedicated scanner path before automation")
    assert(#self.inv:scan(c.input)==0 and #self.inv:scan(c.output)==0,"scanner path is not empty")
    local physical={endpoint=c.storage,slot=i.slot,stack=self.inv:get(c.storage,i.slot)}
    assert(i.endpoint.id==c.storage.id,"scanner cannot reach this inventory")
    self.state.scan={name=i.stack.name,damage=i.stack.damage,size=i.stack.size,
      ident=i.stack.individual and i.stack.individual.ident,started=self.now(),returnSlot=i.slot,original=B.identity(i.stack)}; self.save()
    self.inv:move(physical,c.input,c.inputSlot,i.stack.size,"scanner")
    return false,"Scanning "..tostring(i.stack.label or i.stack.name)
  end end
  return true
end
return M
