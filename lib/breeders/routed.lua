-- Fallback when an alveary's inventory cannot be accessed directly. A verified
-- redstone gate holds BOTH caste paths until staging receipts commit. A separate
-- isolated output chest receives only this housing's products and offspring.
local Base=require("lib.breeders.alveary"); local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M; setmetatable(M,{__index=Base})
function M.new(config,inv,components)
  local self=Base.new(config,inv,components)
  self.endpoint.id="routing-input/"..config.id
  self.output=assert(config.routing and config.routing.output,"register routing output endpoint")
  return setmetatable(self,M)
end
function M:gate(value)
  local g=self.config.routing.gate
  self.components:proxy(g.address,{"setOutput"}).setOutput(g.side,value)
end
function M:validate()
  self:housing(); local r=self.config.routing; local s=self:getSlots()
  assert(r and r.verified and s and s.verified,"verify isolated caste routing, output provenance and gate")
  assert(r.gate and r.gate.off~=r.gate.on,"separate gate on/off levels required")
  self.components:proxy(r.gate.address,{"setOutput"})
  local n=self.inv:size(self.endpoint); local out=self.inv:size(self.output)
  assert(n==s.inventorySize and out==r.outputInventorySize,"staging inventory size changed")
  U.assertNumber(s.princess,1,n); U.assertNumber(s.drone,1,n)
  assert(s.princess~=s.drone,"staging caste slots overlap")
  assert(self.output.transposer==self.endpoint.transposer and self.output.side~=self.endpoint.side,"separate reachable staging chests required")
  assert(self.output.side~=self.config.storage.side and self.output.id~=self.config.storage.id,"routing output must be isolated from archive")
  local seen={}; for _,slot in ipairs(s.outputs) do U.assertNumber(slot,1,out); assert(not seen[slot],"duplicate output slot"); seen[slot]=true end
  assert(#s.outputs>0,"routing output slots required")
  assert(self.config.environment.verified,"operating climate unverified"); return true
end
function M:isReady()
  self:validate(); self:gate(self.config.routing.gate.off)
  local h=self:housing()
  if h.getQueen() or h.getDrone() or #self.inv:scan(self.endpoint)>0 or #self.inv:scan(self.output)>0 then
    return false,"routing path or housing occupied"
  end
  return true
end
function M:insertDrone(item,owner)
  assert(B.kind(item.stack)=="drone","drone required")
  return self.inv:move(item,self.endpoint,self:getSlots().drone,1,owner)
end
function M:start() self:gate(self.config.routing.gate.on) end
function M:getCycleState()
  local h=self:housing()
  if h.getQueen() or h.getDrone() or #self.inv:scan(self.endpoint)>0 then return "RUNNING" end
  local princess,drones=0,0
  for _,slot in ipairs(self:getSlots().outputs) do local s=self.inv:get(self.output,slot)
    if B.kind(s)=="princess" then princess=princess+s.size end
    if B.kind(s)=="drone" then drones=drones+s.size end
  end
  if princess==1 and drones>0 then self:gate(self.config.routing.gate.off); return "FINISHED" end
  return "RUNNING","Awaiting isolated routed offspring or queen; verify pipe power and gate"
end
function M:collectResults(storage,owner,onReceipt)
  self:gate(self.config.routing.gate.off); local results={}
  for _,slot in ipairs(self:getSlots().outputs) do local stack=self.inv:get(self.output,slot)
    if stack then
      local i=storage:deposit({endpoint=self.output,slot=slot,stack=stack},self.config.storage,owner)
      results[#results+1]=i; if onReceipt then onReceipt(i) end
    end
  end; return results
end
return M
