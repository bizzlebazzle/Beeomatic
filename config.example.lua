-- Structure only: run setup and verify actual component addresses, sides and slots.
local c=require("lib.config").defaults()
-- Stock required before completing each stage; consecutive stable offspring cycles.
c.minDrones=32
c.confirmCycles=3
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
-- Pipes feed the scanner from the input chest; analysed bees collect in the
-- output chest for physical verification and transposer return to the Interface.
local input={id="scanner_input",transposer=scannerPort.transposer,side=1}
local output={id="scanner_output",transposer=scannerPort.transposer,side=2}
c.scanner={enabled=true,mode="buffered",storage=scannerPort,input=input,output=output,timeout=600}
return c
