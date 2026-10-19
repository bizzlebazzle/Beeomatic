local U=require("lib.util")
local M={}
function M.defaults()
  return {version=1,alvearies={},aliases={},componentNames={},preferred={spirit={"ethereal","aware"}},
    concurrency=2,pollSeconds=5,cycleTimeout=3600,maxCycles=128,minDrones=32,
    reserveDrones=1,reservePrincesses=1,fullEquivalence=false,confirmCycles=3,
    weights={species=1000,fertility=13,temperatureTolerance=4,humidityTolerance=4,
      lifespan=1,nocturnal=2,tolerantFlyer=2,caveDwelling=2},desired={},
    storage={kind="me_interface",endpoints={},databaseSlots=9,timeout=60},scanner={enabled=false},templates={enabled=false},
    }
end
function M.validate(c)
  assert(c.version==1,"unsupported configuration version")
  assert(c.storage and (c.storage.kind=="chest" or c.storage.kind=="ae2" or c.storage.kind=="me_interface"),"unsupported storage backend")
  U.assertNumber(c.concurrency,1,32); U.assertNumber(c.pollSeconds,1,300)
  U.assertNumber(c.maxCycles,1,100000); U.assertNumber(c.confirmCycles,1,100)
  U.assertNumber(c.reserveDrones,1,100000); U.assertNumber(c.reservePrincesses,1,100000)
  if c.storage.kind=="me_interface" then
    assert(c.storage.address and c.storage.database,"configure ME reader and database")
    assert(c.scanner.enabled and c.scanner.storage and c.scanner.storage.managed,"register the shared scanner Interface")
    assert(c.scanner.input and (c.scanner.mode=="external" or c.scanner.output and c.scanner.inputSlot),
      "configure shared scanner input chest")
    local ports,addresses,views={},{},{}
    for _,ep in ipairs(c.storage.endpoints) do
      assert(ep.managed and ep.address and ep.id and ep.transposer,"incomplete Interface port")
      U.assertNumber(ep.side,0,5)
      assert(not ports[ep.id] and not addresses[ep.address],"duplicate Interface port ID/address")
      local view=ep.transposer..":"..ep.side; assert(not views[view],"duplicate Interface inventory")
      ports[ep.id]=ep; addresses[ep.address]=true; views[view]=true
    end
    for _,a in ipairs(c.alvearies) do
      assert(a.storage and ports[a.storage.id] and U.equal(a.storage,ports[a.storage.id]),"alveary Interface port is not registered")
    end
    assert(ports[c.scanner.storage.id] and U.equal(c.scanner.storage,ports[c.scanner.storage.id]),"scanner Interface port is not registered")
  end
  local ids,addresses,physical={},{},{}
  for _,a in ipairs(c.alvearies) do
    assert(not a.backend or a.backend=="alveary" or a.backend=="routed","unsupported breeder backend")
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
function M.prunePorts(c)
  if c.storage.kind~="me_interface" then return end
  local used={}
  for _,a in ipairs(c.alvearies) do used[a.storage.id]=true end
  if c.scanner.storage then used[c.scanner.storage.id]=true end
  for n=#c.storage.endpoints,1,-1 do if not used[c.storage.endpoints[n].id] then table.remove(c.storage.endpoints,n) end end
end
return M
