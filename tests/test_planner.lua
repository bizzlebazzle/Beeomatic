local W=require("tests.mocks.world"); local P=require("lib.planner"); local Config=require("lib.config")
local function run(recipes,stock,target,c)
  local mutations=require("lib.mutations").new({getBeeParents=function(name) return recipes[name] or {} end},{})
  return P.plan(target or "spirit",mutations,stock or {},c or Config.defaults())
end
local function pair(s) return {W.bee(s,"princess"),W.bee(s,"drone",16)} end
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
