local P=require("lib.planner"); local W=require("tests.mocks.world")
local Pager=require("lib.ui.pager")
local function fixture()
  local forest={species="forestry.speciesforest",available=true,children={}}
  local meadows={species="forestry.speciesmeadows",available=true,children={}}
  local common={species="forestry.speciescommon",route={parents={forest.species,meadows.species},chance=12.0},
    children={forest,meadows},suitable={"alveary_1"}}
  local spirit={species="magicbees.speciesspirit",route={parents={common.species,forest.species},chance=8.0},
    children={common,forest},suitable={"alveary_1"}}
  return {target=spirit.species,requested="spirit",root=spirit,order={forest,meadows,common,spirit}}
end

test("plan output presents one ordered recipe per step with compact names and chances",function()
  local text=P.render(fixture())
  ok(text:find("Breeding plan: Spirit",1,true))
  ok(text:find("2 breeding steps | 0 princess conversions | 2 species in stock",1,true))
  ok(text:find("Stock present: Forest, Meadows",1,true))
  local first=text:find("1. Common <- Forest + Meadows (12% base)",1,true)
  local second=text:find("2. Spirit <- Common + Forest (8% base)",1,true)
  ok(first and second and first<second)
  ok(not text:find("Actual parent genes",1,true))
  local _,checks=text:gsub("checked before each step",""); eq(checks,1)
  ok(not text:find("forestry.species",1,true)); ok(not text:find("8.0%%"))
  ok(not text:find("magicbees.species",1,true))
  local _,steps=text:gsub("%d+%. ",""); eq(steps,2)
end)

test("plan output moves actionable conditions before recipes and marks the affected step",function()
  local plan=fixture(); plan.root.suitable={}
  plan.root.unresolved={"alveary_1: Requires a special foundation"}
  local text=P.render(plan)
  local warning=text:find("NEEDS ATTENTION",1,true)
  local requirement=text:find("Requires a special foundation",1,true)
  local steps=text:find("Steps in breeding order",1,true)
  ok(warning and requirement and warning<requirement and requirement<steps)
  ok(text:find("Step 2 - Spirit:",1,true)); ok(text:find("(8% base) [CHECK]",1,true))
  local detailed=P.render(plan,{verbose=true})
  ok(detailed:find("Alvearies: none confirmed",1,true))
  ok(detailed:find("Spirit = magicbees.speciesspirit",1,true))
end)

test("available targets and conversion plans explain their next action",function()
  local plan=fixture(); local stock=plan.order[1]
  plan.target=stock.species; plan.root=stock; plan.order={stock}
  local text=P.render(plan)
  ok(text:find("no mutations needed",1,true)); ok(not text:find("To start:",1,true))
  stock.available=nil; stock.conversion=true
  text=P.render(plan)
  ok(text:find("0 breeding steps | 1 princess conversion |",1,true))
  ok(text:find("1. Recover Forest princess from spare drones",1,true))
end)

test("stock species labels retain spelling and multiword names without global indices",function()
  local m=require("lib.mutations").new({listAllSpecies=function() error("unbounded species list") end,
    getBeeBreedingData=function() error("unbounded recipe list") end,getBeeParents=function() return {} end},{})
  local stock={W.bee("Certus Quartz","princess"),W.bee("Certus Quartz","drone",16)}
  for _,s in ipairs(stock) do
    s.individual.active.species.uid="mod.speciescertus"; s.individual.inactive.species.uid="mod.speciescertus"
  end
  m:index(stock)
  eq(m:displayName("magicbees.speciesspirit"),"Spirit")
  local p=assert(P.plan("certus quartz",m,stock,require("lib.config").defaults()))
  eq(p.names[p.target],"Certus Quartz")
  ok(P.render(p):find("Breeding plan: Certus Quartz",1,true))
end)

test("recursive plans explain missing external founders by name and recover when supplied",function()
  local species={
    target={name="End Dust",uid="gregtech.bee.speciesenddust"},
    middle={name="Test Intermediate",uid="test.speciesmiddle"},
    base={name="Forest",uid="forestry.speciesForest"},
    external={name="Monastic",uid="forestry.speciesMonastic"}}
  -- Synthetic routes exercise recursive lookup, not a hardcoded pack recipe.
  local routes={
    [species.target.uid]={{allele1=species.middle,allele2=species.base,chance=10}},
    [species.middle.uid]={{allele1=species.external,allele2=species.base,chance=10}}}
  local m=require("lib.mutations").new({
    listAllSpecies=function() error("unbounded species list") end,
    getBeeParents=function(id)
      -- The pinned OC housing accepts either localized name or UID.
      for _,s in pairs(species) do if id==s.name:lower() then id=s.uid end end
      return routes[id] or {}
    end},{})
  local function bee(s,kind,count)
    local stack=W.bee(s.name,kind,count)
    stack.individual.active.species=s; stack.individual.inactive.species=s
    return stack
  end
  local stock={bee(species.base,"princess"),bee(species.base,"drone",16)}
  m:index(stock)
  local c=require("lib.config").defaults(); c.reserveDrones=2
  local p,e=P.plan("end dust",m,stock,c)
  eq(p,nil); ok(e:find("Cannot plan End Dust",1,true))
  ok(e:find("Monastic: no mutation recipe reported; pure stock: 0 princesses, 0 drones.",1,true))
  ok(e:find("more than 2 pure drones for princess conversion",1,true))
  ok(not e:find("gregtech.",1,true)); ok(not e:find("forestry.",1,true))
  stock[#stock+1]=bee(species.external,"drone",2)
  p,e=P.plan("end dust",m,stock,c)
  eq(p,nil); ok(e:find("0 princesses, 2 drones",1,true))
  stock[#stock].size=3
  p=assert(P.plan("end dust",m,stock,c))
  eq(#p.order,4); ok(p.root.children[1].children[1].conversion)
  local text=P.render(p)
  ok(text:find("End Dust <- Test Intermediate + Forest",1,true))
  stock[#stock+1]=bee(species.external,"princess")
  p=assert(P.plan("end dust",m,stock,c))
  eq(#p.order,4); ok(p.root.children[1].children[1].available)
end)

local function terminal(keys,fn,width,height)
  local oldTerm,oldEvent,oldPrint=package.loaded.term,package.loaded.event,print
  local output,reads={},0
  package.loaded.term={isAvailable=function() return true end,getViewport=function() return width or 40,height or 8 end}
  package.loaded.event={pull=function()
    reads=reads+1; local char=keys[reads]; assert(char,"unexpected pager wait")
    return "key_down","keyboard",char,0
  end}
  print=function(text) output[#output+1]=text end
  local yes,err=xpcall(function() fn(output,function() return reads end) end,debug.traceback)
  package.loaded.term=oldTerm; package.loaded.event=oldEvent; print=oldPrint
  assert(yes,err)
end

test("pager wraps long condition text and unbroken identifiers within terminal width",function()
  local text="    Needs special conditions in this alveary to breed this bee.\n"..string.rep("x",85)
  local lines=Pager.lines(text,30)
  for _,line in ipairs(lines) do ok(#line<=30,line) end
  ok(#lines>=5)
end)

test("pager supports forward back and quit without losing the beginning",function()
  local lines={}; for i=1,18 do lines[i]="Line "..i end
  terminal({13,98,32,113},function(out,reads)
    Pager.show(table.concat(lines,"\n"))
    eq(reads(),4)
    ok(out[1]:find("Line 1\n",1,true)); ok(out[2]:find("[1/3]",1,true))
    ok(out[3]:find("Line 7\n",1,true)); ok(out[4]:find("[2/3]",1,true))
    eq(out[5],out[1]); eq(out[7],out[3])
  end)
end)

test("pager can finish the last page and bypass paging for captured output",function()
  terminal({13,13},function(out,reads)
    Pager.show(string.rep("text\n",8)); eq(reads(),2)
    ok(out[#out]:find("[2/2]",1,true))
  end)
  terminal({},function(out,reads)
    local text=string.rep("text\n",20)
    Pager.show(text,{enabled=false}); eq(reads(),0); eq(out,{text})
  end)
end)

test("CLI pages long plans and no-pager prints details without creating breeding work",function()
  local w=W.new(); w:addMachine("a"); w:build()
  w.recipes={spirit={W.route("Ethereal","Aware")},ethereal={W.route("Forest","Meadows")},aware={W.route("Forest","Meadows")}}
  w.inventories.hub[1]=W.bee("Forest","princess"); w.inventories.hub[2]=W.bee("Forest","drone",16)
  w.inventories.hub[3]=W.bee("Meadows","princess"); w.inventories.hub[4]=W.bee("Meadows","drone",16)
  require("tests.mocks.openos").with(w,function(files)
    files["/project/data/config.lua"]="return "..require("lib.util").encode(w.c)
    terminal({113},function(out,reads)
      require("lib.cli").main("/project",{"plan","spirit"})
      eq(reads(),1); ok(out[1]:find("Breeding plan: Spirit",1,true)); ok(out[2]:find("[1/",1,true))
    end)
    terminal({},function(out,reads)
      require("lib.cli").main("/project",{"plan","spirit","--verbose","--no-pager"})
      eq(reads(),0)
      local text=table.concat(out,"\n")
      ok(text:find("Species IDs:",1,true)); ok(text:find("Alvearies: a",1,true))
      ok(text:find("To start: Beeomatic breed spirit",1,true))
    end)
    eq(w.moves,0); eq(files["/project/data/state.lua"],nil); eq(files["/project/data/worker.lock"],nil)
  end)
end)
