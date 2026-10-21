local E=require("lib.environment"); local W=require("tests.mocks.world")
test("temperature tolerance respects direction",function()
  local p=W.bee("Forest","princess",1,nil,{temperatureTolerance="UP_2"})
  ok(E.bee(p,W.environment("HOT"))); ok(not E.bee(p,W.environment("COLD")))
  p.individual.active.temperatureTolerance="DOWN_1"; ok(E.bee(p,W.environment("COLD")))
end)
test("humidity tolerance and unknown climate fail closed",function()
  local p=W.bee("Forest","princess",1,nil,{humidityTolerance="BOTH_1"})
  ok(E.bee(p,W.environment("NORMAL","DAMP"))); ok(not E.bee(p,W.environment("NONE")))
end)
test("selects compatible alveary rather than first",function()
  local p=W.bee("Forest","princess"); local d=W.bee("Forest","drone")
  local r=E.select({{id="hot",environment=W.environment("HOT")},{id="normal",environment=W.environment()}},{},p,d,{})
  eq(#r,1); eq(r[1].id,"normal")
end)
test("mutation conditions distinct from survival",function()
  local p=W.bee("Forest","princess"); local a={id="a",environment=W.environment(),confirmed={}}
  local r=E.select({a},W.route("Forest","Meadows",10,{"Requires Diamond as a foundation"}),p,p,{})
  eq(#r,0); a.confirmed["Requires Diamond as a foundation"]=true
  eq(#E.select({a},W.route("Forest","Meadows",10,{"Requires Diamond as a foundation"}),p,p,{}),1)
end)
test("optional lunar bonuses allow compatible princesses in all four alvearies",function()
  local p=W.bee("Esoteric","princess",1,nil,{temperatureTolerance="BOTH_1"})
  local d=W.bee("Mysterious","drone"); local housings={}
  for n,temp in ipairs({"NORMAL","COLD","NORMAL","WARM"}) do
    housings[n]={id="alveary_"..n,environment=W.environment(temp),confirmed={}}
  end
  for _,bonus in ipairs({"Better success between the Waxing Crescent and Waxing Gibbous.",
    "Better success during the Full Moon."}) do
    local route=W.route("Esoteric","Mysterious",8,{bonus})
    local candidates,why=E.select(housings,route,p,d,{})
    eq(#candidates,4); eq(why,"")
    housings[1].environment.temperature="HOT"
    candidates,why=E.select(housings,route,p,d,{})
    eq(#candidates,3); ok(why:find("needs temperature COLD/NORMAL/WARM",1,true),why)
    housings[1].environment.temperature="NORMAL"
  end
end)
test("lunar restrictions and unknown mutation requirements still need confirmation",function()
  local a={id="a",environment=W.environment(),confirmed={}}
  for _,req in ipairs({"Occurs between the Waxing Half and Waning Half","During the Full Moon",
    "Requires Diamond as a foundation","Unknown mutation condition"}) do
    local route=W.route("Esoteric","Mysterious",8,
      {"Better success during the Full Moon.",req})
    local success,why=E.mutation(route,a)
    ok(not success); ok(why:find("Unconfirmed mutation requirement: "..req,1,true),why)
    ok(why:find("Beeomatic doctor --confirm a",1,true),why)
    ok(not why:find("Better success",1,true),why)
    a.confirmed[req]=true; ok(E.mutation(route,a))
  end
  local success,why=E.mutation({environment={temperature="COLD"}},a)
  ok(not success); eq(why,"Mutation requires temperature=COLD")
end)
test("flower, day/night, rain and sky declarations do not gate scheduling",function()
  local p=W.bee("Forest","princess"); local e=W.environment(); e.flowers=nil; ok(E.bee(p,e))
  e.flowers={}; ok(E.bee(p,e))
  e=W.environment(); e.skyAccess=false; ok(E.bee(p,e))
  e.skyAccess=true; e.rainProtected=false; e.daylightManaged=false; ok(E.bee(p,e))
  e.rainProtected=nil; e.daylightManaged=nil; e.skyAccess=nil; ok(E.bee(p,e))
end)


test("Icy UP_1 queen accepts Cold regardless of the drone climate",function()
  local p=W.bee("Wintry","princess",1,nil,{temperatureTolerance="UP_1"})
  p.individual.active.species.temperature="Icy"
  ok(E.bee(p,W.environment("COLD")))
  ok(E.bee(p,W.environment("ICY")))
  ok(not E.bee(p,W.environment("NORMAL")))
  local d=W.bee("Forest","drone")
  local candidates,why=E.select({{id="cold",environment=W.environment("COLD")}},nil,p,d,{})
  eq(#candidates,1); eq(candidates[1].id,"cold"); eq(why,"")
end)


test("housing diagnostics separate configured climate from the rejected bee range",function()
  local p=W.bee("Wintry","princess",1,nil,{temperatureTolerance="UP_1"})
  p.individual.active.species.temperature="Icy"
  local d=W.bee("Attuned","drone")
  local candidates,why=E.select({{id="alveary_1",name="Main",environment=W.environment("NORMAL")},
    {id="alveary_2",environment=W.environment("COLD")}},nil,p,d,{})
  eq(#candidates,1); eq(candidates[1].id,"alveary_2")
  ok(why:find("alveary_1 (Main) [temp NORMAL, humidity NORMAL]:\n  Wintry princess needs temperature ICY/COLD (active genes: ICY, UP_1)",1,true),why)
  ok(not why:find("drone needs",1,true),why)
end)

test("humidity diagnostics show the allowed humidity range",function()
  local p=W.bee("Forest","princess",1,nil,{humidityTolerance="UP_1"})
  local candidates,why=E.select({{id="dry",environment=W.environment("NORMAL","ARID")}},nil,p,nil,{})
  eq(#candidates,0)
  ok(why:find("humidity ARID",1,true),why)
  ok(why:find("Forest princess needs humidity NORMAL/DAMP (active genes: NORMAL, UP_1)",1,true),why)
end)


test("only the princess active genome determines queen temperature and humidity",function()
  local p=W.bee("Wintry","princess",1,"Attuned",{temperatureTolerance="UP_1"})
  p.individual.active.species.temperature="Icy"
  local d=W.bee("Attuned","drone")
  d.individual.active.species.humidity="Arid"
  local housings={{id="normal",environment=W.environment("NORMAL")},{id="cold",environment=W.environment("COLD")}}
  local candidates=E.select(housings,nil,p,d,{})
  eq(#candidates,1); eq(candidates[1].id,"cold")
  candidates=E.select(housings,nil,d,p,{})
  eq(#candidates,0) -- the reversed princess now needs ARID humidity
  d.individual.active.species.humidity="Normal"
  candidates=E.select(housings,nil,d,p,{})
  eq(#candidates,1); eq(candidates[1].id,"normal")
end)

test("drone analysis and mutation conditions remain required independently of climate",function()
  local p=W.bee("Forest","princess"); local d=W.bee("Wintry","drone")
  d.individual.isAnalyzed=false
  local a={id="normal",environment=W.environment(),confirmed={}}
  local candidates,why=E.select({a},nil,p,d,{})
  eq(#candidates,0); ok(why:find("analyse the selected drone",1,true),why)
  d.individual.isAnalyzed=true; d.individual.active.species.temperature="Icy"
  candidates=E.select({a},W.route("Forest","Wintry",10,{"Requires foundation"}),p,d,{})
  eq(#candidates,0)
  a.confirmed["Requires foundation"]=true
  candidates=E.select({a},W.route("Forest","Wintry",10,{"Requires foundation"}),p,d,{})
  eq(#candidates,1)
end)
