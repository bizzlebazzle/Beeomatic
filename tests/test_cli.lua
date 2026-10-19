local W=require("tests.mocks.world"); local O=require("tests.mocks.openos"); local U=require("lib.util")
test("public Beeomatic breed spirit completes through CLI persistence and foreground events",function()
  local w=W.new(); w:addMachine("a"); w:addMachine("b"); w:build(); w.c.minDrones=4
  for slot=1,10 do w.inventories.hub[slot]=W.bee(slot<=5 and "Forest" or "Meadows","princess") end
  w.inventories.hub[11]=W.bee("Forest","drone",64); w.inventories.hub[12]=W.bee("Meadows","drone",64)
  w.recipes={spirit={W.route("Ethereal","Aware")},ethereal={W.route("Forest","Meadows")},aware={W.route("Forest","Meadows")}}
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("lib.cli").main("/project",{"BrEeD","SpIrIt"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished,require("lib.ui.status").render(state,w.c,true)); eq(state.pending,nil); eq(files["/project/data/worker.lock"],nil)
    ok(table.concat(out,"\n"):find("stable stock archived",1,true))
    require("lib.cli").main("/project",{"STATUS","--VERBOSE"})
  end)
end)
test("installer copies manifest, preserves data and creates valid command launcher",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/home/Test/data/state.lua"]="user state"
    assert(loadfile("install.lua"))("/home/Test")
    eq(files["/home/Test/data/state.lua"],"user state")
    for _,path in ipairs(assert(loadfile("manifest.lua"))()) do ok(files["/home/Test/"..path],"missing installed "..path) end
    local destination,arguments
    local launcher=assert(load(files["/usr/bin/Beeomatic"],"=launcher","t",{
      assert=assert,loadfile=function(p) destination=p; return function(...) arguments={...} end end}))
    launcher("breed","spirit"); eq(destination,"/home/Test/Beeomatic.lua"); eq(arguments,{"breed","spirit"})
    assert(loadfile("install.lua"))("/home/Test")
    eq(files["/home/Test/data/state.lua"],"user state"); ok(files["/home/Test/lib/cli.lua.previous"])
  end)
end)
test("installer refuses to overwrite a running installation",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/home/Test/data/worker.lock"]="active"
    raises(function() assert(loadfile("install.lua"))("/home/Test") end,"stop Beeomatic")
    eq(files["/home/Test/Beeomatic.lua"],nil)
  end)
end)

local function failFlush()
  local previous=io.open
  io.open=function(path,mode)
    local f,err=previous(path,mode)
    if f and path:sub(-4)==".tmp" then
      f.flush=function() return nil,"disk full" end
    end
    return f,err
  end
end

test("installer preserves the previous program when flushing fails",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/home/Test/Beeomatic.lua"]="previous program"
    failFlush()
    raises(function() assert(loadfile("install.lua"))("/home/Test") end,"disk full")
    eq(files["/home/Test/Beeomatic.lua"],"previous program")
    eq(files["/home/Test/Beeomatic.lua.previous"],nil)
  end)
end)

test("state saver preserves the previous generation when flushing fails",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out,fs)
    local path="/home/Test/data/state.lua"
    files[path]='return {marker="previous"}'
    failFlush()
    raises(function() require("lib.persistence").new(path,fs):save({marker="next"}) end,"disk full")
    eq(files[path],'return {marker="previous"}')
    eq(files[path..".bak"],nil)
  end)
end)
