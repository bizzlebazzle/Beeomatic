local M={}
function M.request(c,components,requirement,nonce,event)
  assert(c.enabled,"Robot unavailable; satisfy and confirm: "..requirement)
  local modem=components:proxy(c.modem,{"send","open","isWireless"})
  assert(modem.isWireless(),"wireless modem required"); modem.open(c.replyPort)
  modem.send(c.address,c.port,"beeomatic",nonce,requirement,c.replyPort)
  local deadline=require("computer").uptime()+c.timeout
  while require("computer").uptime()<deadline do
    local _,_,sender,port,_,protocol,id,req,ok=event.pull(math.max(0,deadline-require("computer").uptime()),"modem_message")
    if sender==c.address and port==c.replyPort and protocol=="beeomatic" and id==nonce and req==requirement then
      return ok==true,ok==true and "Foundation action acknowledged; other conditions still require confirmation" or "Robot reported failure"
    end
  end
  return false,"Robot acknowledgement timed out"
end
return M
