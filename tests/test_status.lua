local Status=require("lib.ui.status")
local config={alvearies={{id="a",name="Main alveary"},{id="b"}}}
local function sample()
  return {target="magicbees.speciescharmed",stockPhase="PREPARING_STOCK",stockRemaining=0,
    scan={phase="PROCESSING",count=1},error="Shared scanner analysing 1 bees",
    machines={a={state="ASSESSING",job="job1"}},
    jobs={{id="job1",species="forestry.speciescommon",state="ASSESSING",mode="breed",cycles=4,confirmed=0},
      {id="job2",species="magicbees.speciescharmed",state="WAITING",mode="breed",cycles=0,confirmed=0}},
    events={{message="job1: /home/Beeomatic/lib/scanner_me.lua:101: old failure"}},lastCycle=620.2}
end

test("compact status explains work without duplicating diagnostics or stale events",function()
  local state=sample(); local text=Status.render(state,config,false)
  ok(text:find("Target: Charmed",1,true)); ok(text:find("BEEOMATIC | Working",1,true))
  ok(text:find("Progress: 0/2 steps complete | 1 active | 1 queued",1,true))
  ok(text:find("Scanner: Analysing bees (1)",1,true))
  ok(text:find("Main alveary: Checking offspring - Common",1,true))
  ok(text:find("Alvearies idle: 1",1,true))
  for _,noise in ipairs({"forestry.species","job1","cycles=","alleles=","Intervention","Attention:","old failure","620.2"}) do
    ok(not text:find(noise,1,true),text)
  end
  state.events[#state.events+1]={message="another diagnostic"}; state.lastCycle=999
  eq(Status.render(state,config,false),text)
  local details=Status.render(state,config,true)
  ok(details:find("cycles=4",1,true)); ok(details:find("another diagnostic",1,true))
end)

test("compact status keeps real scanner and job failures visible",function()
  local state=sample(); state.error="/home/Beeomatic/lib/scanner_me.lua:101: multiple possible scanner returns; audit the external path"
  state.jobs[1].state="PAUSED"; state.jobs[1].error="/home/Beeomatic/lib/jobs.lua:36: missing flowers"
  local text=Status.render(state,config,false)
  ok(text:find("BEEOMATIC | Needs attention",1,true)); ok(text:find("1 paused",1,true))
  ok(text:find("Attention:\n  multiple possible scanner returns; audit the external path\n  Common: missing flowers",1,true))
  ok(not text:find(".lua:",1,true)); ok(text:find("Beeomatic status --verbose",1,true))
  ok(Status.render(state,config,true):find(state.error,1,true))
  state=sample(); state.housings={b={error="housing disconnected"}}
  text=Status.render(state,config,false)
  ok(text:find("BEEOMATIC | Needs attention",1,true)); ok(text:find("b: cannot read housing",1,true))
end)

test("compact status lists shared mutation requirements once with a confirmation command",function()
  local W=require("tests.mocks.world"); local E=require("lib.environment")
  local c={alvearies={}}
  for n=1,6 do c.alvearies[n]={id="alveary_"..n,name="Alveary "..n,environment=W.environment()} end
  local req="Requires a magical biome"
  local foundation="Requires Diamond as a foundation"
  local _,why=E.select(c.alvearies,W.route("Ethereal","Infernal",8,{req,foundation}),
    W.bee("Ethereal","princess"),W.bee("Infernal","drone"))
  local original="Cannot start this pairing in any available alveary.\nSelected parents: Ethereal princess + Infernal drone.\n"..why
  local state={jobs={{id="job",species="icy",mode="breed",state="WAITING",cycles=0,confirmed=0,error=original}}}
  local text=Status.render(state,c,false)
  local _,count=text:gsub("Unconfirmed mutation requirement:",""); eq(count,2)
  ok(text:find("Icy: Unconfirmed mutation requirement: "..req.."\n    (run Beeomatic doctor --confirm alveary_1)",1,true),text)
  ok(text:find("Unconfirmed mutation requirement: "..foundation,1,true),text)
  for _,noise in ipairs({"Selected parents:","Cannot start this pairing","[temp ","--confirm alveary_6"}) do
    ok(not text:find(noise,1,true),text)
  end
  local details=Status.render(state,c,true)
  ok(details:find("  "..original:gsub("\n","\n  "),1,true),details)
  ok(details:find("Selected parents: Ethereal princess + Infernal drone.",1,true),details)
  ok(details:find("--confirm alveary_6",1,true),details); eq(state.jobs[1].error,original)
  state.error="scanner output contaminated"
  ok(Status.render(state,c,false):find(state.error,1,true))
end)

test("scanner output counts are routine progress but timeout remains an error",function()
  local state=sample(); state.error="Shared scanner waiting for output: 3/8 analysed bees in scan-output"
  local text=Status.render(state,config,false)
  ok(text:find("BEEOMATIC | Working",1,true)); ok(not text:find("Attention:",1,true))
  state.error=state.error.."; timeout: check input chest, pipes, scanner power/honey and output route; batch preserved"
  text=Status.render(state,config,false)
  ok(text:find("BEEOMATIC | Needs attention",1,true)); ok(text:find("timeout:",1,true))
end)

test("lunar waits show planned progress once while real failures remain visible",function()
  local state=sample(); state.jobs[2].error="Waiting for moon phase: New Moon; current: Full Moon"
  local text=Status.render(state,config,false)
  ok(text:find("BEEOMATIC | Working",1,true),text)
  ok(text:find("Planned: Charmed - "..state.jobs[2].error,1,true),text)
  ok(not text:find("Attention:",1,true)); ok(not text:find("--confirm",1,true))
  local _,count=text:gsub("Waiting for moon phase:",""); eq(count,1)
  state.jobs[1].error="missing flowers"
  text=Status.render(state,config,false); ok(text:find("Attention:\n  Common: missing flowers",1,true),text)
  state.jobs[2].error="Cannot read in-game moon phase; check OpenOS world time"
  ok(Status.render(state,config,false):find("Charmed: "..state.jobs[2].error,1,true))
end)

test("parent population waits are normal planned status with counts and stability",function()
  for _,message in ipairs({"Waiting for parent drone population and stable confirmation cycles","Waiting for stable parent population"}) do
    local state=sample()
    state.jobs[2].species="magicbees.specieseldritch"; state.jobs[2].error=message
    state.jobs[2].route={parents={"attuned","cultivated"}}
    state.parentStock={attuned={count=12,minimum=32},cultivated={count=40,minimum=32}}
    state.jobs[3]={id="helper",species="attuned",mode="populate",state="RUNNING",confirmed=1}
    config.confirmCycles=2
    local text=Status.render(state,config,false)
    ok(text:find("BEEOMATIC | Working",1,true)); ok(not text:find("Attention:",1,true))
    ok(text:find("Planned: Eldritch - Waiting for stable parent population\n  Attuned: 12/32 drones | stable cycles 1/2\n  Cultivated: 40/32 drones",1,true))
    ok(not text:find("stable confirmation cycles",1,true))
    state.jobs[1].error="missing flowers"
    text=Status.render(state,config,false)
    ok(text:find("BEEOMATIC | Needs attention",1,true)); ok(text:find("Attention:\n  Common: missing flowers",1,true))
    state.jobs[2].state="RUNNING"; state.jobs[2].error=nil
    ok(not Status.render(state,config,false):find("Planned: Eldritch",1,true))
  end
end)
test("automatic mutation recovery is planned work while real recovery failures remain visible",function()
  local state=sample(); local j=state.jobs[2]
  j.rebreeding=true; j.error="Rebreeding Charmed from mutation parents to restore stable drone stock"
  local text=Status.render(state,config,false)
  ok(text:find("Planned: "..j.error,1,true),text); ok(not text:find("Attention:",1,true),text)
  j.error="Cannot start this pairing in any available alveary."
  ok(Status.render(state,config,false):find("Attention:",1,true))
end)

test("compact status identifies pending target and terminal states",function()
  local state={jobs={},target="old",pendingRequest={target="magicbees.speciescharmed"}}
  local text=Status.render(state,config,false)
  ok(text:find("Target: Charmed",1,true)); ok(text:find("preparing stock before planning",1,true))
  state.pendingRequest=nil; state.stopped=true
  ok(Status.render(state,config,false):find("BEEOMATIC | Stopped",1,true))
  state.paused=true
  ok(Status.render(state,config,false):find("BEEOMATIC | Paused",1,true))
  state.paused=false; state.stopped=false; state.finished=true
  ok(Status.render(state,config,false):find("BEEOMATIC | Complete",1,true))
end)

test("foreground status refreshes an available terminal and falls back to plain output",function()
  local previous=package.loaded.term; local original=print
  local calls={}
  local success,err=pcall(function()
    print=function(text) calls[#calls+1]=text end
    package.loaded.term={isAvailable=function() return true end,
      clear=function() calls[#calls+1]="clear" end,
      setCursor=function(x,y) eq(x,1); eq(y,1); calls[#calls+1]="cursor" end}
    Status.show("first"); Status.show("second")
    eq(calls,{"clear","cursor","first","clear","cursor","second"})
    calls={}; package.loaded.term.isAvailable=function() return false end
    Status.show("plain"); eq(calls,{"plain"})
  end)
  print=original; package.loaded.term=previous; assert(success,err)
end)

test("a failing terminal refresh cannot abort foreground breeding output",function()
  local previous=package.loaded.term; local original=print
  local calls={}
  local success,err=pcall(function()
    print=function(text) calls[#calls+1]=text end
    for _,failure in ipairs({"isAvailable","clear","setCursor"}) do
      package.loaded.term={isAvailable=function() return true end,
        clear=function() end,setCursor=function() end}
      package.loaded.term[failure]=function() error("screen disconnected during "..failure) end
      Status.show(failure)
    end
    eq(calls,{"isAvailable","clear","setCursor"})
  end)
  print=original; package.loaded.term=previous; assert(success,err)
end)


test("climate diagnostics remain indented on separate lines in both status views",function()
  local state=sample()
  state.jobs[2].mode="convert"
  state.jobs[2].error="Recover Charmed princess.\nSelected parents: Wintry princess + Charmed drone.\nalveary_1 [temp NORMAL, humidity NORMAL]:\n  Wintry princess needs temperature ICY/COLD"
  local text=Status.render(state,config,false)
  ok(text:find("Charmed: Recover Charmed princess.\n    Selected parents:",1,true),text)
  ok(text:find("\n    alveary_1 [temp NORMAL, humidity NORMAL]:\n      Wintry princess",1,true),text)
  text=Status.render(state,{alvearies={{id="alveary_1",environment={temperature="NORMAL",humidity="NORMAL"}}}},true)
  ok(text:find("Configured climate: temperature NORMAL; humidity NORMAL",1,true),text)
  ok(text:find("\n  Selected parents:",1,true),text)
end)
