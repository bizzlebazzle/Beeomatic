-- Local/offline OpenOS installer. Copy the manifest's files first.
local fs=require("filesystem"); local shell=require("shell")
local args={...}; local dest=args[1] or "/home/Beeomatic"
local src=args[2] or fs.path(debug.getinfo(1,"S").source:gsub("^[@=]",""))
if src~="" then src=src:gsub("/+$","").."/" end
assert(dest:sub(1,1)=="/","installation destination must be absolute")
dest=fs.canonical(dest)
assert(not fs.exists(dest.."/data/worker.lock"),"stop Beeomatic before upgrading; recover stale worker lock separately")
local manifest,reason=loadfile(src.."manifest.lua")
assert(manifest,"Cannot load "..src.."manifest.lua: "..tostring(reason))
local files=manifest()
local function writeAtomic(path,text)
  if fs.exists(path) then
    local existing=assert(io.open(path,"rb")); local previous=existing:read("*a"); existing:close()
    if previous==text then return end -- Preserve backups and disk space for real changes.
  end
  fs.makeDirectory(fs.path(path))
  local f=assert(io.open(path..".tmp","wb")); assert(f:write(text)); assert(f:flush()); f:close()
  local check=assert(io.open(path..".tmp","rb")); assert(check:read("*a")==text); check:close()
  if fs.exists(path) then
    if fs.exists(path..".previous") then assert(fs.remove(path..".previous")) end
    assert(fs.rename(path,path..".previous"))
  end
  assert(fs.rename(path..".tmp",path))
end
for _,relative in ipairs(files) do
  local source=src..relative; local target=dest.."/"..relative
  if fs.canonical(source)~=fs.canonical(target) then
    local f=assert(io.open(source,"rb"),"missing release file: "..relative)
    local text=f:read("*a"); f:close(); writeAtomic(target,text)
  end
end
-- Retire only known obsolete program files; retain one recoverable generation.
for _,relative in ipairs({"lib/storage/base.lua","lib/breeders/base.lua","tools/probe.lua","lib/robot.lua","robot-helper.lua"}) do
  local path=dest.."/"..relative
  if fs.exists(path) then
    if fs.exists(path..".previous") then assert(fs.remove(path..".previous")) end
    assert(fs.rename(path,path..".previous"))
  end
end
-- The installer knows the root; do not infer it from runtime debug chunk names.
writeAtomic("/usr/bin/Beeomatic","local root="..string.format("%q",dest).."\n"..
  'package.path=root.."/?.lua;"..root.."/?/init.lua;"..package.path\n'..
  'return require("lib.cli").main(root,{...})\n')
writeAtomic("/usr/bin/update",'return assert(loadfile('..
  string.format("%q",dest.."/update.lua")..'))(...)\n')
fs.makeDirectory(dest.."/data")
print("Installed Beeomatic in "..dest..". Existing data/configuration were preserved.")
print("Run: Beeomatic setup\nThen: Beeomatic doctor\nThen: Beeomatic plan spirit\nThen: Beeomatic breed spirit")
