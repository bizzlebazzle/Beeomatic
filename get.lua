-- OpenOS Internet Card bootstrap. Download all files before invoking install.lua.
local fs=require("filesystem")
local internet=require("internet")
local args={...}
local repo="bizzlebazzle/Beeomatic"
local total=0
local function fetch(url)
  local response=internet.request(url,nil,{["User-Agent"]="Beeomatic-Installer"})
  local chunks,size,checked={},0,false
  local yes,err=pcall(function()
    for chunk in response do
      if not checked then
        local code,message=response.response()
        assert(code==200,"HTTP "..tostring(code)..": "..tostring(message))
        checked=true
      end
      size=size+#chunk; total=total+#chunk
      assert(size<=1024*1024 and total<=8*1024*1024,"download size limit exceeded")
      chunks[#chunks+1]=chunk
    end
    assert(checked and size>0,"empty download: "..url)
  end)
  pcall(function() response.close() end)
  assert(yes,"Download failed: "..tostring(err))
  return table.concat(chunks)
end
local revision=args[1]
if not revision then
  local metadata=fetch("https://api.github.com/repos/"..repo.."/commits/master")
  revision=metadata:match('"sha"%s*:%s*"([a-f0-9]+)"')
end
assert(type(revision)=="string" and #revision==40 and revision:match("^[a-f0-9]+$"),
  "expected a full Git commit SHA (or omit it to resolve master)")
local dest=args[2] or "/home/Beeomatic"
assert(dest:sub(1,1)=="/","installation destination must be absolute")
dest=fs.canonical(dest)
assert(dest~="/","choose a dedicated installation directory")
assert(not fs.exists(fs.canonical(dest).."/data/worker.lock"),"stop Beeomatic before upgrading")
local base="https://raw.githubusercontent.com/"..repo.."/"..revision.."/"
-- /tmp can be a small separate filesystem. Stage on the installation's disk.
local stage=dest..".download"
print("Downloading Beeomatic "..revision)
local manifest=fetch(base.."manifest.lua")
local files=assert(load(manifest,"=downloaded manifest","t",{}))()
assert(type(files)=="table" and #files>0 and #files<200,"invalid release manifest")
local seen={}
for _,path in ipairs(files) do
  assert(type(path)=="string" and path:match("^[%w_./%-]+$") and
    path:sub(1,1)~="/" and not path:find("..",1,true) and
    not path:find("//",1,true) and not seen[path],"unsafe or duplicate release path")
  seen[path]=true
end
assert(seen["manifest.lua"] and seen["install.lua"] and seen["Beeomatic.lua"],"incomplete release manifest")
local function install()
  for i,path in ipairs(files) do
    print(i.."/"..#files.." "..path)
    local data=path=="manifest.lua" and manifest or fetch(base..path)
    if path:match("%.lua$") then assert(load(data,"@"..stage.."/"..path,"t",{})) end
    local target=stage.."/"..path
    fs.makeDirectory(fs.path(target))
    local f=assert(io.open(target,"wb")); assert(f:write(data)); assert(f:flush()); f:close()
    local check=assert(io.open(target,"rb")); assert(check:read("*a")==data); check:close()
  end
  -- Only now touch the installation; install.lua retains its data and backup rules.
  local f=assert(io.open(stage.."/install.lua","rb")); local source=f:read("*a"); f:close()
  assert(load(source,"="..stage.."/install.lua","t",_G))(dest,stage)
end
local yes,err=pcall(install)
-- Remove only validated manifest paths in our dedicated staging directory.
for _,path in ipairs(files) do
  local target=stage.."/"..path
  if fs.exists(target) then
    local removed,reason=fs.remove(target)
    if not removed then print("Could not remove staging file: "..target..": "..tostring(reason)) end
  end
end
assert(yes,err)
print("Installed revision "..revision)
