-- Run on an optional OpenOS robot: robot-helper LOCAL_MODEM CONTROLLER_MODEM PORT
-- Whitelist exact requirement strings and reference item slots in robot-foundations.lua.
local component=require("component"); local event=require("event"); local robot=require("robot")
local args={...}; local modem=component.proxy(assert(args[1],"local modem address required"))
local controller=assert(args[2],"controller modem address required"); local port=tonumber(args[3]) or 3000
local foundations=assert(loadfile("robot-foundations.lua"))()
modem.open(port)
while true do
  local name,_,sender,received,_,protocol,id,requirement,reply=event.pull("modem_message")
  if name and sender==controller and received==port and protocol=="beeomatic" and type(id)=="string" and
    type(reply)=="number" and reply>=1 and reply<=65535 then
    local slot=foundations[requirement]; local ok=false
    if type(slot)=="number" then
      robot.select(slot)
      if robot.compare() then ok=true
      elseif not robot.detect() and robot.place() then ok=robot.compare() end
    end
    -- No digging. A specific foundation action never certifies unrelated conditions.
    modem.send(controller,reply,"beeomatic",id,requirement,ok)
  end
end
