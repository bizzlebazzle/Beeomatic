-- Legacy saved-configuration support only; new Interface mode does not load this.
-- Exact-filter export control. Redstone mode uses normal AE2 ticks, waiting for
-- physical receipts instead of assuming a fixed pulse or bus transfer speed.
local B=require("lib.bees"); local U=require("lib.util")
local M={}; M.__index=M
function M.new(components,inv,runtime)
  runtime=runtime or {}
  local self=setmetatable({components=components,inv=inv},M)
  self.now=runtime.now or function() return require("computer").uptime() end
  self.cancelled=runtime.cancelled
  self.wait=runtime.wait or function(seconds)
    local name,_,char=require("event").pull(seconds)
    if name=="interrupted" then error("Export wait interrupted; inspect saved receipts before resuming") end
    if name=="key_down" and (char==112 or char==113) then
      if char==112 then inv.state.paused=true else inv.state.cancelRequested=true; inv.state.stopping=true end
      inv.save(); error("Export wait stopped by user; progress preserved")
    end
  end
  return self
end
function M:validate(c)
  local mode=c.exportMode or "callback"
  assert(mode=="callback" or mode=="redstone","choose callback or redstone export mode")
  local methods={"setExportConfiguration"}
  if mode=="redstone" then
    methods[#methods+1]="getExportConfiguration"; methods[#methods+1]="getExportSlotSize"
    local g=assert(c.exportGate,"register the OC redstone export gate")
    assert(g.verified,"verify redstone wiring, active-with-signal mode and exclusive OC control")
    U.assertNumber(g.side,0,5); assert(g.off==0,"export gate off level must be zero")
    U.assertNumber(g.on,1,15)
    self.components:proxy(g.address,{"getOutput","setOutput"})
    U.assertNumber(c.exportTimeout or 60,1,600); U.assertNumber(c.exportPollSeconds or 1,1,10)
  else methods[#methods+1]="exportIntoSlot" end
  self.components:proxy(c.exportAddress,methods)
end
function M:off(x)
  if x.mode=="redstone" then
    local g=assert(x.gate); local p=self.components:proxy(g.address,{"getOutput","setOutput"})
    p.setOutput(g.side,g.off); assert(p.getOutput(g.side)==g.off,"export gate output did not turn off")
  end
end
function M:shutdown(x)
  -- Try BOTH operations even if one component has disappeared.
  local offOK,offError=pcall(self.off,self,x)
  local clearOK,clearError=pcall(function()
    local bus=self.components:proxy(x.exportAddress,{"setExportConfiguration"})
    local yes,why=bus.setExportConfiguration(x.exportSide,1)
    assert(yes,"filter cleanup failed: "..tostring(why))
    if x.mode=="redstone" then
      local entry,err=bus.getExportConfiguration(x.exportSide,1)
      assert(entry==nil and err==nil,"export filter did not clear: "..tostring(err))
    end
  end)
  if not offOK or not clearOK then return false,
    (not offOK and ("gate shutdown failed: "..tostring(offError).."; ") or "")..
    (not clearOK and tostring(clearError) or "") end
  return true
end
function M:preflight(x)
  self:off(x)
  assert(#self.inv:scan(x.dest)==0,"isolated ME export buffer must be completely empty; reconcile existing contents")
  if x.mode=="redstone" then
    local bus=self.components:proxy(x.exportAddress)
    local n=bus.getExportSlotSize(x.exportSide)
    U.assertNumber(n,1,64)
    for slot=1,n do local value,err=bus.getExportConfiguration(x.exportSide,slot)
      assert(value==nil and err==nil,"clear all existing export filters before automated export")
    end
  end
end
function M:receipts(x)
  local items=self.inv:scan(x.dest); local count=0
  for _,i in ipairs(items) do
    assert(B.identity(i.stack)==x.identity,"wrong-NBT item in isolated export buffer; preserve it for audit")
    assert(i.stack.size>0,"invalid export receipt count"); count=count+i.stack.size
  end
  assert(not x.before or count<=x.before,"export receipt exceeds selected source count")
  return items,count
end
function M:run(x,database,entry)
  local bus=self.components:proxy(x.exportAddress)
  local ok,reason=pcall(function()
    assert(bus.setExportConfiguration(x.exportSide,1,database,entry),"cannot configure export bus")
    if x.mode=="redstone" then
      local configured=bus.getExportConfiguration(x.exportSide,1)
      assert(configured and B.identity(configured)==x.identity,"export filter read-back did not preserve exact NBT")
      x.phase="ENABLING"; self.inv.save() -- durable before signal can move stock
      local g=x.gate; local p=self.components:proxy(g.address)
      p.setOutput(g.side,g.on); assert(p.getOutput(g.side)==g.on,"export gate did not enable")
      local deadline=self.now()+x.timeout
      while true do
        if self.inv.state.cancelRequested or (self.cancelled and self.cancelled()) then
          self.inv.state.cancelRequested=true; self.inv.state.stopping=true
          error("Cancellation requested",0)
        end
        local items=self:receipts(x)
        if #items>0 then break end
        assert(self.now()<deadline,"ME export timeout waiting for receipt; check channel, power, stock and redstone wiring")
        self.wait(math.min(x.pollSeconds,deadline-self.now()))
      end
    else
      local result,detail=bus.exportIntoSlot(x.exportSide,x.slot)
      if not result then error(tostring(detail or "export returned no success"),0) end
    end
  end)
  local stopped,stopError=self:shutdown(x)
  if not ok or not stopped then
    reason=tostring(reason or "export cleanup failed")..(not stopped and ("; "..stopError) or "")
    x.lastError=reason
    if reason:find("config",1,true) and reason:find("null",1,true) then
      x.compatibilityIssue="https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/25284"
      reason=reason.."; known GTNH exportIntoSlot config=null incompatibility. Select validated redstone export mode."
    end
    self.inv.save(); error("AE2 export failed/uncertain; inspect buffer and run doctor. "..reason)
  end
  local items,count=self:receipts(x)
  assert(count>0,"AE2 export has no physical receipt; inspect buffer and run doctor")
  x.phase="RECEIVED"; x.receivedCount=count; self.inv.save()
  return items,count
end
return M
