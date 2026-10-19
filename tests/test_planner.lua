local W=require("tests.mocks.world"); local P=require("lib.planner"); local Config=require("lib.config")
local function run(recipes,stock,target,c)
  local mutations=require("lib.mutations").new({getBeeParents=function(name) return recipes[name] or {} end},{})
  return P.plan(target or "spirit",mutations,stock or {},c or Config.defaults())
end
local function pair(s) return {W.bee(s,"princess"),W.bee(s,"drone",16)} end
-- Model the OC watchdog with an instruction budget between OpenOS sleeps.
local function watchdog(fn)
  local oldSleep=os.sleep
  local oldHook,mask,interval=debug.gethook()
  local ticks,yields=0,0
  os.sleep=function(timeout) eq(timeout,0); ticks=0; yields=yields+1 end
  debug.sethook(function()
    ticks=ticks+1; assert(ticks<250,"too long without yielding")
  end,"",1000)
  local yes,err=xpcall(fn,debug.traceback)
  debug.sethook(oldHook,mask,interval); os.sleep=oldSleep
  assert(yes,err); ok(yields>0,"large plan must yield")
end

test("large verified stock plans within the watchdog instruction budget",function()
  local stock={}
  for i=1,800 do
    stock[#stock+1]=W.bee("Unrelated","princess")
    stock[#stock+1]={stack=W.bee("Unrelated","drone",64)}
  end
  for _,name in ipairs({"Forest","Meadows"}) do
    for _,s in ipairs(pair(name)) do stock[#stock+1]=s end
  end
  local c=Config.defaults(); c.alvearies={{id="normal",environment=W.environment()}}
  watchdog(function()
    local p=assert(run({spirit={W.route("Forest","Meadows")}},stock,"spirit",c))
    eq(p.root.suitable,{"normal"}); eq(#p.order,3)
  end)
end)

test("complex mutation search yields and retains its expansion budget",function()
  local recipes={spirit={}}
  for i=1,12 do recipes.spirit[i]=W.route("Middle","Other",i) end
  for depth=1,7 do
    local name=depth==1 and "middle" or "middle"..depth
    local parent=depth==7 and "Missing" or "Middle"..(depth+1)
    recipes[name]={W.route(parent,"Other",1),W.route(parent,"Other",2)}
  end
  local c=Config.defaults(); c.maxPlanExpansion=500
  watchdog(function()
    local p,e=run(recipes,{},"spirit",c)
    eq(p,nil); ok(e:find("mutation search budget exceeded",1,true)); ok(#e<1000,e)
  end)
end)

test("parent stock filtering checks reverse orientation and all genome variants",function()
  local c=Config.defaults(); c.alvearies={{id="normal",environment=W.environment()}}
  local hot=W.bee("Meadows","princess"); hot.individual.active.species.temperature="HOT"
  local forest=W.bee("Forest","princess"); forest.individual.active.species.temperature="HOT"
  local stock={hot,W.bee("Meadows","princess"),W.bee("Forest","drone",16),
    forest,W.bee("Meadows","drone",16)}
  local p=assert(run({spirit={W.route("Forest","Meadows")}},stock,"spirit",c))
  eq(p.root.suitable,{"normal"})
  stock[2]=hot
  p=assert(run({spirit={W.route("Forest","Meadows")}},stock,"spirit",c))
  eq(p.root.suitable,{})
end)
test("simple runtime mutation",function()
  local stock=pair("Ethereal"); for _,s in ipairs(pair("Aware")) do stock[#stock+1]=s end
  local p=assert(run({spirit={W.route("Ethereal","Aware")}},stock,"SPIRIT"))
  eq(p.target,"spirit"); eq(#p.order,3); eq(p.root.route.parents,{"ethereal","aware"})
end)
test("Spirit recursively obtains missing Ethereal and Aware",function()
  local recipes={spirit={W.route("Ethereal","Aware")},ethereal={W.route("Forest","Meadows")},aware={W.route("Forest","Common")},common={W.route("Forest","Meadows")}}
  local stock=pair("Forest"); for _,s in ipairs(pair("Meadows")) do stock[#stock+1]=s end
  local p=assert(run(recipes,stock)); eq(#p.order,6); ok(not p.root.children[1].available)
  ok(P.render(p):find("ethereal",1,true)); ok(P.render(p):find("aware",1,true))
end)
test("alternate achievable route beats missing parents",function()
  local stock=pair("Forest"); for _,s in ipairs(pair("Meadows")) do stock[#stock+1]=s end
  local p=assert(run({spirit={W.route("Missing","Impossible",99),W.route("Forest","Meadows",5)}},stock))
  eq(p.root.route.parents,{"forest","meadows"})
end)
test("dependency cycle terminates with useful diagnostic",function()
  local p,e=run({spirit={W.route("Spirit","Aware")}})
  eq(p,nil); ok(e:find("cycle",1,true))
end)
test("unknown or missing hive stock is diagnosed",function()
  local p,e=run({}); eq(p,nil); ok(e:find("unknown/unobtainable",1,true))
end)

test("shared missing founders are reported once across nested routes",function()
  local recipes={spirit={},middle={}}
  for i=1,20 do
    recipes.spirit[i]=W.route("Middle","Other",i)
    recipes.middle[i]=W.route("magicbees.speciesunusual","Other",i)
  end
  local p,e=run(recipes)
  eq(p,nil)
  local _,count=e:gsub("magicbees.speciesunusual","")
  eq(count,1); ok(#e<500,e)
end)

test("many distinct failures have a bounded summary",function()
  local recipes={spirit={}}
  for i=1,50 do recipes.spirit[i]=W.route("Missing"..i,"Other") end
  local p,e=run(recipes)
  eq(p,nil); ok(e:find("Additional route failures omitted",1,true)); ok(#e<1000,e)
end)

test("plan failure explains bees without verified genes",function()
  local s=W.bee("Forest","drone",16); s.individual=nil
  local p,e=run({}, {s})
  eq(p,nil); ok(e:find("16 bees lack verified genes",1,true))
end)
test("route with confirmed conditions wins",function()
  local c=Config.defaults(); c.alvearies={{id="a",enabled=true,confirmed={},environment=W.environment()}}
  local stock=pair("Forest"); for _,s in ipairs(pair("Meadows")) do stock[#stock+1]=s end
  local p=assert(run({spirit={W.route("Forest","Meadows",99,{"Requires block"}),W.route("Meadows","Forest",1)}},stock,"spirit",c))
  eq(p.root.route.chance,1)
end)
test("only runtime confirmed Spirit routes are used",function()
  local stock=pair("Forest"); for _,s in ipairs(pair("Meadows")) do stock[#stock+1]=s end
  local p=assert(run({spirit={W.route("Forest","Meadows")}},stock)); eq(p.root.route.parents,{"forest","meadows"})
end)
test("species aliases resolve case insensitively",function()
  local m=require("lib.mutations").new({getBeeParents=function() return {} end},{ghost="Spirit"})
  eq(m:resolve("GHOST"),"spirit")
end)
