-- Example only. Replace addresses and run setup's role checks on actual hardware.
local c=require("lib.config").defaults()
c.concurrency=2
c.storage={kind="chest",endpoints={
  {id="archive",transposer="REPLACE-TEMPERATE-TRANSPOSER",side=0},
  {id="archive",transposer="REPLACE-HOT-TRANSPOSER",side=0},
  {id="archive",transposer="REPLACE-COLD-TRANSPOSER",side=0}}}
local environments={
  {"temperate_1","Temperate Alveary","NORMAL","NORMAL"},
  {"hot_dry_1","Hot Dry Alveary","HOT","ARID"},
  {"cold_damp_1","Cold Damp Alveary","COLD","DAMP"}}
for n,v in ipairs(environments) do
  c.alvearies[n]={id=v[1],name=v[2],enabled=true,priority=n,
    address="REPLACE-HOUSING-"..n,transposer=c.storage.endpoints[n].transposer,
    side=3,storage=c.storage.endpoints[n],
    -- Sample indices are deliberately unverified; copy only the structure.
    slots={princess=1,drone=2,outputs={3,4,5,6,7,8,9},inventorySize=9,verified=false},
    environment={temperature=v[3],humidity=v[4],biome="REPLACE",dimension="REPLACE",
      flowers={flowers=true},daylightManaged=false,rainProtected=false,skyAccess=false,verified=false},
    confirmed={}}
end
-- For optional AE2 also configure storage.address, database, databaseSlots,
-- exportAddress, exportSide, exportIsolated, storageBusVerified and buffer endpoint.
-- Beta 3 workaround (fill addresses/sides and verify the circuit in-game):
-- c.storage.exportMode = "redstone"
-- c.storage.exportGate = {address="REPLACE-OC-REDSTONE",side=3,on=15,off=0,verified=false}
-- c.storage.exportTimeout = 60 -- maximum wait; signal stays on until receipt
-- c.storage.exportPollSeconds = 1
-- See docs/HARDWARE.md. Do not change kind without completing that configuration.
return c
