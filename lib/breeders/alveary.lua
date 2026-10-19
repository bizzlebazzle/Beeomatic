local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M
function M.new(config,inv,components)
  return setmetatable({config=config,inv=inv,components=components,
    endpoint={id="breeder/"..config.id,transposer=config.transposer,side=config.side}},M)
end
function M:discover() return self.components:discover() end
function M:housing() return self.components:proxy(self.config.address,{"getQueen","getDrone","getBeeParents","canBreed"}) end
function M:getEnvironment() return U.copy(self.config.environment) end
function M:getSlots() return self.config.slots end
function M:inspect()
  local p=self:housing()
  return {items=self.inv:scan(self.endpoint),queen=p.getQueen(),drone=p.getDrone(),canBreed=p.canBreed()}
end
function M:validate()
  self:housing(); local size=self.inv:size(self.endpoint); local s=self:getSlots()
  assert(s and s.verified,"verify this alveary's individual slot map with doctor")
  local seen={}
  for _,n in ipairs({s.princess,s.drone}) do
    U.assertNumber(n,1,size); assert(not seen[n],"overlapping breeder slots"); seen[n]=true
  end
  assert(#s.outputs>0,"no output slots registered")
  for _,n in ipairs(s.outputs) do U.assertNumber(n,1,size); assert(not seen[n],"output overlaps input"); seen[n]=true end
  assert(s.inventorySize==size,"inventory size changed; reverify slot map")
  assert(self.config.environment and self.config.environment.verified,"environment unverified")
  return true
end
function M:isReady()
  self:validate()
  local s=self:getSlots()
  if self.inv:get(self.endpoint,s.princess) or self.inv:get(self.endpoint,s.drone) then return false,"input occupied" end
  for _,n in ipairs(s.outputs) do if self.inv:get(self.endpoint,n) then return false,"output occupied" end end
  local h=self:housing()
  if h.getQueen() or h.getDrone() then return false,"housing/inventory map disagrees" end
  return true
end
function M:insertPrincess(item,owner)
  assert(B.kind(item.stack)=="princess","princess required")
  return self.inv:move(item,self.endpoint,self:getSlots().princess,1,owner)
end
function M:insertDrone(item,owner,princess)
  assert(B.kind(item.stack)=="drone","drone required")
  return self.inv:move(item,self.endpoint,self:getSlots().drone,1,owner,function(got,n)
    if got or n~=1 then return false end
    local q=self.inv:get(self.endpoint,self:getSlots().princess)
    return B.kind(q)=="queen" and B.scanned(q) and
      U.equal(q.individual.active,princess.individual.active) and
      U.equal(q.individual.inactive,princess.individual.inactive)
  end)
end
function M:getCycleState()
  local s=self:getSlots(); local h=self:housing()
  local input=self.inv:get(self.endpoint,s.princess)
  local drone=self.inv:get(self.endpoint,s.drone)
  local queen=h.getQueen(); local hd=h.getDrone()
  if input or drone or queen or hd then
    return "RUNNING",h.canBreed() and nil or "housing reports it cannot work; check climate, flowers, outputs and special conditions"
  end
  local p,d=0,0
  for _,slot in ipairs(s.outputs) do local stack=self.inv:get(self.endpoint,slot)
    if B.kind(stack)=="princess" then p=p+stack.size end
    if B.kind(stack)=="drone" then d=d+stack.size end
  end
  if p>0 and d>0 then return "FINISHED" end
  return "UNCERTAIN","no live inputs and no complete offspring pair; inspect mapped outputs"
end
function M:collectResults(storage,owner)
  local r={}
  for _,slot in ipairs(self:getSlots().outputs) do local stack=self.inv:get(self.endpoint,slot)
    if stack then
      r[#r+1]=storage:deposit({endpoint=self.endpoint,slot=slot,stack=stack},self.config.storage,owner)
    end
  end; return r
end
function M:extractAll(storage,owner)
  -- Input extraction is disallowed by Forestry; never claim to evacuate a live queen.
  assert(not self.inv:get(self.endpoint,self:getSlots().princess) and not self.inv:get(self.endpoint,self:getSlots().drone),
    "Live input cannot be extracted automatically. Let the cycle finish or remove manually.")
  return self:collectResults(storage,owner)
end
return M
