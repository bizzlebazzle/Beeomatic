-- OpenOS shortcut: refresh the bootstrap, then run the installer.
local shell=require("shell")
local args={...}
assert(shell.setWorkingDirectory("/home"),"cannot change directory to /home")
local success,reason=shell.execute("wget -f https://raw.githubusercontent.com/bizzlebazzle/Beeomatic/master/get.lua")
assert(success,reason or "could not download get.lua; update stopped")
return assert(loadfile("/home/get.lua"))(table.unpack(args))
