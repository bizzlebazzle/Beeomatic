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

test("parent population alerts use short wording for both saved and new messages",function()
  for _,message in ipairs({"Waiting for parent drone population and stable confirmation cycles","Waiting for stable parent population"}) do
    local state=sample()
    state.jobs[2].species="magicbees.specieseldritch"; state.jobs[2].error=message
    local text=Status.render(state,config,false)
    ok(text:find("Attention:\n  Eldritch: Waiting for stable parent population\n",1,true))
    ok(not text:find("stable confirmation cycles",1,true))
  end
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
