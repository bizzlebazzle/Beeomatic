local W=require("tests.mocks.world"); local U=require("lib.util")
test("setup checkpoint persists completed sections",function()
  local w=W.new(); w:addMachine("a"); w:build(); w.c.setupStep=3
  local answers={"no","no","no"}; local n=0; local snapshots={}
  local wizard=require("lib.setup").new(w.c,w.components,w.inv,function() snapshots[#snapshots+1]=U.copy(w.c) end,
    function() n=n+1; return answers[n] end,function() end)
  wizard:run(false); eq(w.c.setupStep,5); ok(#snapshots>=3); eq(snapshots[#snapshots].scanner.enabled,false)
end)
test("configuration rejects duplicated machine identity",function()
  local w=W.new(); w:addMachine("a"); local copy=U.copy(w.c.alvearies[1]); copy.id="other"; w.c.alvearies[2]=copy
  raises(function() require("lib.config").validate(w.c) end,"duplicate bee housing")
end)
test("probe inspects all component addresses and side views",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build(); local out={}
  require("lib.ui.diagnostics").probe(w.components,function(s) out[#out+1]=s end)
  local text=table.concat(out,"\n"); ok(text:find("tp1",1,true)); ok(text:find("tp2",1,true)); ok(text:find("side 3",1,true))
end)
test("component validation accepts callable tables and indirect method metadata",function()
  local w=W.new(); w:addMachine("a"); w:build()
  eq(type(w.proxies.tp1.getInventorySize),"table")
  eq(w.components.api.methods("tp1").getInventorySize,false)
  local p=w.components:proxy("tp1",{"getInventorySize"})
  eq(p.getInventorySize(0),100)
end)
test("component validation still rejects absent methods",function()
  local w=W.new(); w:addMachine("a"); w:build()
  raises(function() w.components:proxy("tp1",{"notAnInventoryMethod"}) end,"missing method notAnInventoryMethod")
end)
