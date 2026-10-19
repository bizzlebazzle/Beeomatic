local W=require("tests.mocks.world"); local U=require("lib.util")
local function scanWorld()
  local w=W.new(); w:addMachine("a"); w:inventory("input",5); w:inventory("output",5)
  w:addTransposer("tp1",{[0]="hub",[1]="input",[2]="output",[3]="a"})
  w.c.scanner={enabled=true,isolatedVerified=true,input={id="input",transposer="tp1",side=1},
    output={id="output",transposer="tp1",side=2},storage={id="hub",transposer="tp1",side=0},inputSlot=1,timeout=60}
  w:build(); local s=W.bee("Spirit","princess"); s.individual.active=nil; s.individual.inactive=nil; s.individual.isAnalyzed=false
  w.inventories.hub[7]=s; return w
end
test("scanner delay does not busy wait or lose stack",function()
  local w=scanWorld(); local yes=w.scanner:step(w.storage:scan()); ok(not yes); ok(w.state.scan); eq(w.moves,1)
  w.time=30; ok(not w.scanner:step(w.storage:scan())); eq(w.moves,1)
  w.inventories.input[1]=nil; w.inventories.output[1]=W.bee("Spirit","princess")
  ok(w.scanner:step(w.storage:scan())); ok(w.inventories.hub[7].individual.active); eq(w.state.scan,nil)
end)
test("scanner timeout preserves reserved progress",function()
  local w=scanWorld(); w.scanner:step(w.storage:scan()); w.time=61
  raises(function() w.scanner:step(w.storage:scan()) end,"timeout"); ok(w.state.scan); ok(w.inventories.input[1])
end)
test("already scanned bees bypass scanner",function()
  local w=scanWorld(); w.inventories.hub[7]=W.bee("Spirit","princess")
  ok(w.scanner:step(w.storage:scan())); eq(w.moves,0)
end)

test("doctor accepts external ME scanner without legacy provenance flag and checks hardware",function()
  local w=require("tests.mocks.me").new(); local c=w.c.scanner
  c.mode="external"; c.output=nil; c.outputSlots=nil; c.inputSlot=nil; c.isolatedVerified=nil
  local function scannerResult()
    for _,r in ipairs(require("lib.ui.diagnostics").check(w.c,w.components,w.inv,w.storage)) do
      if r.name=="scanner" then return r end
    end
    error("scanner result missing")
  end
  local r=scannerResult(); ok(r.ok,r.error); eq(w.moves,0)
  c.input.side=c.storage.side
  r=scannerResult(); ok(not r.ok); ok(r.error:find("separate sides",1,true)); eq(w.moves,0)
end)

test("doctor retains provenance checks for chest and legacy ME scanners",function()
  local worlds={scanWorld(),require("tests.mocks.me").new()}
  for _,w in ipairs(worlds) do
    w.c.scanner.isolatedVerified=nil
    local found=false
    for _,r in ipairs(require("lib.ui.diagnostics").check(w.c,w.components,w.inv,w.storage)) do
      if r.name=="scanner" then
        found=true; ok(not r.ok); ok(r.error:find("verif",1,true))
      end
    end
    ok(found); eq(w.moves,0)
  end
end)
