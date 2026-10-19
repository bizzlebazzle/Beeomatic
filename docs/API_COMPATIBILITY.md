# GTNH compatibility evidence

Inspected 2026-10-19. No Minecraft runtime is attached to this workspace. Source
verification is not an in-game hardware test. Different GTNH releases can differ.

The [GTNH 2.8.4 release manifest](https://github.com/GTNewHorizons/DreamAssemblerXXL/blob/master/releases/manifests/2.8.4.json)
pins OpenComputers **1.11.20-GTNH**, Forestry **4.10.17**, AE2
**rv3-beta-695-GTNH**, Gendustry **1.9.4-GTNH**. This is a named compatibility
baseline, not a claim that the player's installed pack matches it.

Primary integration inspection used [GTNH OpenComputers commit
1e4559ff5f2443695cb28c7cdc9fba87219a862b](https://github.com/GTNewHorizons/OpenComputers/tree/1e4559ff5f2443695cb28c7cdc9fba87219a862b).
This revision is newer than that release: runtime probes remain mandatory.

| Source (under `src/main/scala/li/cil/oc/`) | Verified contract |
|---|---|
| `integration/forestry/DriverBeeHouse.java` | Targets `IBeeHousing`; component `bee_housing`; `getQueen`, `getDrone`, `canBreed`, `getBeeParents(nameOrUid)`, `getBeeBreedingData`, `listAllSpecies` |
| `integration/forestry/ConverterIAlleles.java` | Parent records contain `allele1`, `allele2`, percentage `chance`, string array `specialConditions`; species have `name`, `uid`, title-case temperature/humidity |
| `integration/forestry/ConverterIIndividual.java` | Only analyzed bees expose active/inactive chromosomes; species, fertility, tolerance strings and boolean traits are available |
| `integration/forestry/DriverAnalyzer.scala` | `forestry_analyzer` exposes progress/display/working information; these are not item movement methods |
| `integration/appeng/NetworkControl.scala` | `getItemsInNetwork(filter)` and `store(filter, databaseAddress, startSlot, count)` copy actual network stacks to database |
| `integration/appeng/DriverExportBus.scala` | `setExportConfiguration(side,slot,database,entry)` and `exportIntoSlot(side,targetSlot)`; latter returns boolean, not amount; fuzzy cards change selection |
| `integration/appeng/DriverImportBus.scala` | No synchronous `importFromSlot`; Beeomatic does not invent one |
| `integration/vanilla/ConverterItemStack.scala` | Compressed binary `tag` exists only with server setting `allowItemStackNBTTags`; `insertIdsInConverters` does not enable NBT |

[Forestry `TileAlveary`](https://github.com/GTNewHorizons/ForestryMC/blob/master/src/main/java/forestry/apiculture/multiblock/TileAlveary.java)
implements `IBeeHousing` and delegates inventory to its controller. Adapter queries
and transposer inventory access are separate. Multiple adapters on blocks of the
same multiblock must not be registered as separate machines.

[Forestry `InventoryBeeHousing`](https://github.com/GTNewHorizons/ForestryMC/blob/master/src/main/java/forestry/apiculture/InventoryBeeHousing.java)
uses internal queen/drone indices 0/1 and seven products from index 2; OC indices
are one-based. Inputs cannot normally be extracted through automation. These are
source observations, **not a default slot map**: each machine's setup must verify
its exposed view, size, input roles, output roles and adapter association. No
apiary inventory size heuristic is used.

The inspected housing integration exposes no live temperature, humidity, biome,
dimension, flowers, frames, daylight or weather methods. Beeomatic uses explicitly
attested configuration and reports that provenance. `canBreed()` reports general
workability; it does not prove that an arbitrary mutation condition is satisfied.
Special conditions are descriptions, not a complete machine-readable requirement
API. They require specific per-alveary confirmation; optional structured route
environment constraints can narrow selection further.

Temperature order: ICY, COLD, NORMAL, WARM, HOT, HELLISH. Humidity: ARID, NORMAL,
DAMP. Source enums expose title-case display names, normalized by Beeomatic.
NONE is not treated as a valid operating climate. UP/DOWN/BOTH tolerance direction
matters. Active traits determine current operation; both species alleles determine
purity. Every selected princess is rechecked before another cycle.

AE2 export requires a dedicated subnet, database, exact NBT, no fuzzy export
upgrade, an empty isolated export buffer and an export bus inhibited from ordinary
autonomous operation. The imperative export callback must be verified to work
under that redstone setup on the installed release. No `database.set()` is used to
reconstruct bee NBT. A physical archive chest with a storage bus provides verified
import receipts without racing an asynchronous import bus.

Lua targets OpenOS Lua **5.2**: no native bitwise operators, `//`, `goto` dependency,
Lua 5.4 resource syntax, or third-party Lua packages. Tests use the actual Lua 5.2
runtime distributed with Lupa on the development host.
