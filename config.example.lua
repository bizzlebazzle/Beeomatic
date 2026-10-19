-- Structure only: run setup and verify actual component addresses, sides and slots.
local c=require("lib.config").defaults()
c.storage.address="REPLACE-ME-READER"
c.storage.database="REPLACE-DATABASE"
c.storage.verified=false
local function port(id,transposer,address,side)
  return {id=id,transposer=transposer,address=address,side=side,managed=true,
    princessSlot=1,droneSlot=2,returnSlot=9}
end
local environments={{"temperate","NORMAL","NORMAL"},{"hot_dry","HOT","ARID"},{"cold_damp","COLD","DAMP"}}
for n,v in ipairs(environments) do
  local ep=port("port_"..v[1],"REPLACE-TRANSPOSER-"..n,"REPLACE-INTERFACE-"..n,0)
  c.storage.endpoints[#c.storage.endpoints+1]=ep
  c.alvearies[n]={id=v[1],name=v[1],enabled=true,priority=n,
    address="REPLACE-HOUSING-"..n,transposer=ep.transposer,side=3,storage=ep,
    slots={princess=1,drone=2,outputs={3,4,5,6,7,8,9},inventorySize=9,verified=false},
    environment={temperature=v[2],humidity=v[3],
      verified=false},confirmed={}}
end
local scannerPort=port("scanner_port","REPLACE-SCANNER-TRANSPOSER","REPLACE-SCANNER-INTERFACE",0)
c.storage.endpoints[#c.storage.endpoints+1]=scannerPort
-- Source-observed Forestry analyser indices, still requiring hardware validation:
-- specimen 1; honey container 2; automated inputs 3..8; outputs 9..12.
local analyser={id="shared_analyser",transposer=scannerPort.transposer,side=1}
c.scanner={enabled=true,isolatedVerified=false,storage=scannerPort,input=analyser,output=analyser,
  inputSlot=3,outputSlots={9,10,11,12},timeout=600,batchSize=64}
return c
