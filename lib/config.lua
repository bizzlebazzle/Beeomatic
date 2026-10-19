local U=require("lib.util")
local M={}
function M.defaults()
  return {version=1,alvearies={},aliases={},preferred={spirit={"ethereal","aware"}},
    concurrency=2,pollSeconds=5,cycleTimeout=3600,maxCycles=128,minDrones=8,
    reserveDrones=1,reservePrincesses=1,fullEquivalence=false,confirmCycles=2,
    weights={species=1000,fertility=13,temperatureTolerance=4,humidityTolerance=4,
      lifespan=1,nocturnal=2,tolerantFlyer=2,caveDwelling=2},desired={},
    storage={kind="chest",endpoints={}},scanner={enabled=false},templates={enabled=false},
    robot={enabled=false,port=3000,replyPort=3001,timeout=10}}
end
function M.validate(c)
  assert(c.version==1,"unsupported configuration version")
  U.assertNumber(c.concurrency,1,32); U.assertNumber(c.pollSeconds,1,300)
  U.assertNumber(c.maxCycles,1,100000); U.assertNumber(c.confirmCycles,1,100)
  U.assertNumber(c.reserveDrones,1,100000); U.assertNumber(c.reservePrincesses,1,100000)
  local ids,addresses,physical={},{},{}
  for _,a in ipairs(c.alvearies) do
    assert(a.id and not ids[a.id],"duplicate alveary ID"); ids[a.id]=true
    assert(a.address and not addresses[a.address],"duplicate bee housing address"); addresses[a.address]=true
    local p=tostring(a.transposer)..":"..tostring(a.side)
    assert(not physical[p],"duplicate breeder inventory"); physical[p]=true
    assert(a.storage and a.storage.id,"missing storage endpoint")
    assert(a.storage.transposer==a.transposer,"storage and breeder must share transposer")
    assert(a.storage.side~=a.side,"storage side overlaps breeder")
  end
  return true
end
return M
