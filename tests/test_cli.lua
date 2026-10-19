local W=require("tests.mocks.world"); local O=require("tests.mocks.openos"); local U=require("lib.util")
test("public CLI Interface workflow scans initial drones and offspring through one station",function()
  local ME=require("tests.mocks.me"); local w=ME.new(); w.c.confirmCycles=1; w.c.minDrones=2
  w:addStock(ME.bee("Spirit","princess")); w:addStock(ME.bee("Spirit","drone",8,true))
  O.with(w,function(files,out)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    require("lib.cli").main("/project",{"populate","spirit","2"})
    local state=assert(load(files["/project/data/state.lua"],"=state","t",{}))()
    ok(state.finished,require("lib.ui.status").render(state,w.c,true)); eq(state.stockPhase,"READY")
    eq(state.scan,nil); eq(state.pending,nil); eq(next(state.meRequests),nil)
    ok(table.concat(out,"\n"):find("PREPARING_STOCK",1,true))
  end)
end)
test("reconfiguration refuses to migrate saved unresolved movements",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    files["/project/data/config.lua"]="return "..U.encode(w.c)
    files["/project/data/state.lua"]="return "..U.encode({jobs={},pendingExternal={kind="ME_EXPORT"}})
    raises(function() require("lib.cli").main("/project",{"setup","--reconfigure"}) end,"reconcile outstanding")
    eq(files["/project/data/config.lua"],"return "..U.encode(w.c))
  end)
end)
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
    local launcherPackage={path="/lib/?.lua"}
    local launcher=assert(load(files["/usr/bin/Beeomatic"],"=launcher","t",{
      package=launcherPackage,require=function(name)
        eq(name,"lib.cli")
        return {main=function(root,args) destination=root; arguments=args end}
      end}))
    launcher("breed","spirit"); eq(destination,"/home/Test"); eq(arguments,{"breed","spirit"})
    eq(launcherPackage.path,"/home/Test/?.lua;/home/Test/?/init.lua;/lib/?.lua")
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

test("installed command loads real modules from its recorded root outside the install directory",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out)
    local root="/home/Custom Bees"
    assert(loadfile("install.lua"))(root)
    local env=setmetatable({package={path="/lib/?.lua",loaded={}}},{__index=_G})
    env.require=function(name)
      if name:sub(1,4)~="lib." then return require(name) end
      if env.package.loaded[name] then return env.package.loaded[name] end
      local modulePath=name:gsub("%.","/")
      for pattern in env.package.path:gmatch("[^;]+") do
        local path=pattern:gsub("%?",modulePath)
        -- Model an OpenOS shell whose working directory is /home.
        if path:sub(1,1)~="/" then path="/home/"..path end
        if files[path] then
          local result=assert(load(files[path],"="..path,"t",env))(name)
          env.package.loaded[name]=result
          return result
        end
      end
      error("module not found in installed files: "..name)
    end
    assert(load(files["/usr/bin/Beeomatic"],"=launcher","t",env))("help")
    ok(env.package.loaded["lib.cli"])
    ok(table.concat(out,"\n"):find("Beeomatic setup",1,true))
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

test("offline installer locates manifest from an absolute OpenOS chunk name",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files)
    for _,path in ipairs(assert(loadfile("manifest.lua"))()) do
      local f=assert(io.open(path,"rb")); files["/release/"..path]=f:read("*a"); f:close()
    end
    assert(loadfile("/release/install.lua"))("/home/Test")
    ok(files["/home/Test/lib/cli.lua"]); ok(files["/usr/bin/Beeomatic"])
  end)
end)

test("application launcher resolves both OpenOS and native Lua source prefixes",function()
  local f=assert(io.open("Beeomatic.lua","rb")); local code=f:read("*a"); f:close()
  for _,prefix in ipairs({"=","@"}) do
    local root,args
    local env=setmetatable({package={path="original"},require=function(name)
      eq(name,"lib.cli")
      return {main=function(r,a) root=r; args=a end}
    end},{__index=_G})
    assert(load(code,prefix.."/home/Beeomatic/Beeomatic.lua","t",env))("doctor")
    eq(root,"/home/Beeomatic"); eq(args,{"doctor"})
    ok(env.package.path:sub(1,6)=="/home/")
  end
end)
