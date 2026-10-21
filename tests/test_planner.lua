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

test("shared missing prerequisites finish without exhausting the search budget",function()
  local recipes={spirit={}}
  for i=1,12 do recipes.spirit[i]=W.route("Middle","Other",i) end
  for depth=1,7 do
    local name=depth==1 and "middle" or "middle"..depth
    local parent=depth==7 and "Missing" or "Middle"..(depth+1)
    recipes[name]={W.route(parent,"Other",1),W.route(parent,"Other",2)}
  end
  local c=Config.defaults(); c.maxPlanExpansion=500
  local p,e=run(recipes,{},"spirit",c)
  eq(p,nil); ok(e:find("Missing: no mutation recipe reported",1,true)); ok(#e<1000,e)
  ok(not e:find("search limit",1,true)); ok(not e:find("budget exceeded",1,true))
end)

local function founders()
  local stock=pair("Forest")
  for _,s in ipairs(pair("Meadows")) do stock[#stock+1]=s end
  return stock
end
local function ordered(plan)
  local seen={}
  for _,n in ipairs(plan.order) do
    ok(not seen[n.species],"duplicate planned species "..n.species)
    for _,child in ipairs(n.children) do ok(seen[child.species]==child,"prerequisite must precede result") end
    seen[n.species]=n
  end
  ok(seen[plan.target]==plan.root)
end

test("Spirit with exponentially shared ancestry produces one ordered job per species",function()
  local recipes={spirit={W.route("Ethereal","Aware")},
    ethereal={W.route("Tier24","Tier23")},aware={W.route("Tier24","Tier22")}}
  for i=1,24 do
    recipes["tier"..i]={W.route(i>1 and "Tier"..(i-1) or "Forest",i>2 and "Tier"..(i-2) or "Meadows")}
  end
  -- This graph has only 29 species but exceeds 20,000 recursive visits.
  local c=Config.defaults()
  watchdog(function()
    local p=assert(run(recipes,founders(),"spirit",c))
    eq(#p.order,29); ordered(p)
    local state={}; require("lib.jobs").create(state,p,"breed")
    eq(#state.jobs,27); eq(state.jobs[#state.jobs].species,"spirit")
    ok(P.render(p):find("Ethereal",1,true)); ok(P.render(p):find("Aware",1,true))
    c.maxPlanExpansion=29
    local bounded=assert(run(recipes,founders(),"spirit",c)); eq(#bounded.order,29)
  end)
end)

test("unique species limit reports a graph limit rather than requesting extra stock",function()
  local c=Config.defaults(); c.maxPlanExpansion=2
  local p,e=run({spirit={W.route("Middle","Forest")},middle={W.route("Forest","Meadows")}},founders(),"spirit",c)
  eq(p,nil); ok(e:find("unique-species search limit (2)",1,true))
  ok(not e:find("provide prerequisite stock",1,true))
end)

test("cyclic alternate recipes use an achievable entrance and produce no job cycles",function()
  local recipes={spirit={W.route("Left","Right",100)},
    left={W.route("Right","Forest",100),W.route("Forest","Meadows",10)},
    right={W.route("Left","Meadows",100),W.route("Forest","Meadows",1)}}
  local c=Config.defaults(); c.alvearies={{id="normal",environment=W.environment()}}
  local p=assert(run(recipes,founders(),"spirit",c)); ordered(p)
  ok(p.root.cost==22); eq(p.root.children[1].route.parents,{"forest","meadows"})
  eq(p.root.children[2].children[1],p.root.children[1])
end)

test("known mutated species with spare drones uses conversion without rebuilding its ancestors",function()
  local c=Config.defaults(); c.maxPlanExpansion=3
  local p=assert(run({spirit={W.route("Ethereal","Aware")},
    ethereal={W.route("Missing","Impossible")}},
    {W.bee("Ethereal","drone",16),W.bee("Aware","princess"),W.bee("Aware","drone",16)},"spirit",c))
  eq(#p.order,3); ok(p.root.children[1].conversion); ordered(p)
  local stock={W.bee("Ethereal","drone",c.reserveDrones)}
  local missing,e=run({ethereal={W.route("Missing","Impossible")}},stock,"ethereal")
  eq(missing,nil); ok(e:find("Missing: no mutation recipe reported",1,true))
end)

test("target recovery creates a conversion dependency before the requested operation",function()
  local p=assert(run({spirit={W.route("Missing","Impossible")}}, {W.bee("Spirit","drone",16)}))
  ok(p.root.conversion)
  for _,mode in ipairs({"breed","populate","imprint","convert"}) do
    local state={}; require("lib.jobs").create(state,p,mode,32)
    if mode=="convert" then eq(#state.jobs,1)
    else
      eq(#state.jobs,2); eq(state.jobs[1].mode,"convert")
      eq(state.jobs[2].mode,mode); eq(state.jobs[2].dependencies,{state.jobs[1].id})
      eq(state.jobs[2].count,32)
    end
  end
end)

test("route ranking matches an independent cost relaxation across cyclic mutation graphs",function()
  local c=Config.defaults(); c.alvearies={{id="normal",environment=W.environment()}}; c.preferred={}
  local seed=19
  local function random(n) seed=(seed*48271)%2147483647; return (seed%n)+1 end
  local function species(i) return i==9 and "forest" or i==10 and "meadows" or "species"..i end
  for fixture=1,32 do
    local recipes={}
    for i=1,8 do
      local routes={}; recipes[species(i)]=routes
      for j=1,3 do routes[j]=W.route(species(random(10)),species(random(10)),random(100)) end
    end
    local costs={forest=0,meadows=0}
    for pass=1,8 do
      for i=1,8 do
        local name=species(i)
        for _,r in ipairs(recipes[name]) do
          local left,right=costs[r.parents[1]],costs[r.parents[2]]
          if left and right then
            local cost=100/r.chance+left+right
            if not costs[name] or cost<costs[name] then costs[name]=cost end
          end
        end
      end
    end
    local p,e=run(recipes,founders(),"species8",c)
    if costs.species8 then
      ok(p,e); ok(math.abs(p.root.cost-costs.species8)<0.000001,"wrong route cost in fixture "..fixture); ordered(p)
    else eq(p,nil) end
  end
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
  ok(P.render(p):find("Ethereal",1,true)); ok(P.render(p):find("Aware",1,true))
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
  local p,e=run({}); eq(p,nil); ok(e:find("Spirit: no mutation recipe reported",1,true))
  ok(e:find("pure stock: 0 princesses, 0 drones",1,true))
end)

test("shared missing founders are reported once across nested routes",function()
  local recipes={spirit={},middle={}}
  for i=1,20 do
    recipes.spirit[i]=W.route("Middle","Other",i)
    recipes.middle[i]=W.route("magicbees.speciesunusual","Other",i)
  end
  local p,e=run(recipes)
  eq(p,nil)
  local _,count=e:gsub("Unusual: no mutation recipe","")
  eq(count,1); ok(not e:find("magicbees.speciesunusual",1,true)); ok(#e<750,e)
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
test("optional lunar bonus does not penalize an otherwise suitable mutation route",function()
  local c=Config.defaults(); c.alvearies={{id="a",enabled=true,confirmed={},environment=W.environment()}}
  local stock=pair("Esoteric"); for _,s in ipairs(pair("Mysterious")) do stock[#stock+1]=s end
  local p=assert(run({arcane={W.route("Esoteric","Mysterious",8,
    {"Better success between the Waxing Crescent and Waxing Gibbous."}),
    W.route("Mysterious","Esoteric",1)}},stock,"arcane",c))
  eq(p.root.route.chance,8); eq(p.root.suitable,{"a"}); eq(p.root.unresolved,{})
end)
test("only runtime confirmed Spirit routes are used",function()
  local stock=pair("Forest"); for _,s in ipairs(pair("Meadows")) do stock[#stock+1]=s end
  local p=assert(run({spirit={W.route("Forest","Meadows")}},stock)); eq(p.root.route.parents,{"forest","meadows"})
end)
test("species aliases resolve case insensitively",function()
  local m=require("lib.mutations").new({getBeeParents=function() return {} end},{ghost="Spirit"})
  eq(m:resolve("GHOST"),"spirit")
end)
