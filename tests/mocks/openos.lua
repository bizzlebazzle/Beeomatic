-- In-memory OpenOS filesystem/process facade. Absolute paths never touch the host.
local U=require("lib.util")
local M={}
function M.with(world,fn,quotas)
  local files,dirs,output={},{},{}
  local originalOpen,originalPrint,originalLoadfile=io.open,print,loadfile
  local previous={}; for _,name in ipairs({"filesystem","component","computer","event"}) do previous[name]=package.loaded[name] end
  local fs={exists=function(p) return files[p]~=nil or dirs[p]==true end,
    makeDirectory=function(p) dirs[p]=true; return true end,
    remove=function(p) files[p]=nil; dirs[p]=nil; return true end,
    rename=function(a,b) if files[a]==nil then return nil,"missing source" end; files[b]=files[a]; files[a]=nil; return true end,
    path=function(p) return p:match("^(.*[/])") or "" end,canonical=function(p) return p:gsub("/+$","") end}
  io.open=function(path,mode)
    if path:sub(1,1)~="/" then return originalOpen(path,mode) end
    mode=mode or "r"
    if mode:find("r",1,true) and files[path]==nil then return nil,"not found" end
    if mode:find("w",1,true) then files[path]="" end
    local f={}
    function f:write(s)
      if quotas then
        local temporary=path:sub(1,5)=="/tmp/"
        local used=0
        for p,data in pairs(files) do
          if (p:sub(1,5)=="/tmp/")==temporary then used=used+#data end
        end
        local limit=temporary and quotas.tmp or quotas.root
        if limit and used+#s>limit then return nil,"not enough space" end
      end
      files[path]=(files[path] or "")..s; return self
    end
    function f:read() return files[path] end
    function f:flush() return self end
    -- OpenOS filesystem close can succeed without returning any values.
    function f:close() end
    return f
  end
  -- OpenOS loadfile uses '=path' chunk names, unlike native Lua's '@path'.
  loadfile=function(path,mode,env)
    local f,reason=io.open(path,"rb"); if not f then return nil,reason end
    local data=f:read("*a"); f:close()
    return load(data,"="..path,mode or "t",env or _G)
  end
  print=function(...) local args={...}; for i,v in ipairs(args) do args[i]=tostring(v) end; output[#output+1]=table.concat(args,"\t") end
  package.loaded.filesystem=fs; package.loaded.component=world.components.api
  package.loaded.computer={uptime=function() return world.time end,address=function() return "test-computer" end}
  local pulls=0
  package.loaded.event={pull=function()
    pulls=pulls+1; assert(pulls<100,"foreground did not terminate")
    local data=files["/project/data/state.lua"]
    if data then local state=assert(load(data,"=teststate","t",{}))()
      for _,j in ipairs(state.jobs or {}) do if j.state=="RUNNING" then
        local species=j.species:sub(1,1):upper()..j.species:sub(2)
        local factory=world.cells and require("tests.mocks.me") or require("tests.mocks.world")
        world:finish(j.machine,factory.bee(species,"princess"),factory.bee(species,"drone",4,world.cells and true or nil))
      end end
    end
    if world.cells then
      if world.inventories.analyser[1] then world:finishScan() end
      world:tick()
    end
    world.time=world.time+5; return nil
  end}
  -- The installer only needs this standard shell module's existence.
  local oldShell=package.loaded.shell; package.loaded.shell={}
  local yes,err=xpcall(function() fn(files,output,fs) end,debug.traceback)
  io.open=originalOpen; print=originalPrint; loadfile=originalLoadfile; package.loaded.shell=oldShell
  for _,name in ipairs({"filesystem","component","computer","event"}) do package.loaded[name]=previous[name] end
  assert(yes,err)
  return files,output
end
return M
