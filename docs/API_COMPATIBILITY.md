# GTNH compatibility evidence

Inspected 2026-10-19. No Minecraft runtime is attached to this workspace. Source
verification is not an in-game hardware test. Different GTNH releases can differ.

The user's deployment target is **GTNH 2.9.0 Beta 3**. Its
[release manifest](https://github.com/GTNewHorizons/DreamAssemblerXXL/blob/master/releases/manifests/2.9.0-beta-3.json)
pins OpenComputers **1.12.61-GTNH**, Forestry **4.11.37**, AE2
**rv3-beta-1050-GTNH**, Gendustry **1.9.13-GTNH**. The integration and inventory
contracts below were rechecked at those exact OC/Forestry release tags after the
user supplied their pack version.

Initial integration inspection used [GTNH OpenComputers commit
1e4559ff5f2443695cb28c7cdc9fba87219a862b](https://github.com/GTNewHorizons/OpenComputers/tree/1e4559ff5f2443695cb28c7cdc9fba87219a862b).
Final source verification uses [OpenComputers 1.12.61-GTNH](https://github.com/GTNewHorizons/OpenComputers/tree/1.12.61-GTNH)
and [Forestry 4.11.37](https://github.com/GTNewHorizons/ForestryMC/tree/4.11.37).
Runtime probes remain mandatory because adapter placement, installed configs and
external routing cannot be verified from source alone. GTNH 2.8.4 was also
inspected during research; it is not the deployment target.

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

Network discovery uses three exact `name` filters: `Forestry:beePrincessGE`,
`Forestry:beeDroneGE` and `Forestry:beeQueenGE`. The pinned `getItemsInNetwork`
implementation applies field equality before returning its array to Lua. This
keeps unrelated network items out of the 2 MiB computer without selecting by
species, label or genotype. Exact variant selection still verifies full NBT.

[Forestry `TileAlveary`](https://github.com/GTNewHorizons/ForestryMC/blob/4.11.37/src/main/java/forestry/apiculture/multiblock/TileAlveary.java)
implements `IBeeHousing` and delegates inventory to its controller. Adapter queries
and transposer inventory access are separate. Multiple adapters on blocks of the
same multiblock must not be registered as separate machines.

[Forestry `InventoryBeeHousing`](https://github.com/GTNewHorizons/ForestryMC/blob/4.11.37/src/main/java/forestry/apiculture/InventoryBeeHousing.java)
uses internal queen/drone indices 0/1 and seven products from index 2; OC indices
are one-based. Inputs cannot normally be extracted through automation. These are
source observations, **not a default slot map**: each machine's setup must verify
its exposed view, size, input roles, output roles and adapter association. No
apiary inventory size heuristic is used.

The inspected housing integration exposes no live temperature, humidity, biome,
dimension, flowers, frames, daylight or weather methods. Beeomatic uses explicitly
attested climate configuration. Day/night, rain and sky workability are observed
through the housing, without setup declarations for lighting or rain shields.
Setup omits biome/dimension and
flower lists; flower requirements are read from resident bees' active genomes and
displayed per housing, without claiming to detect actual nearby flower blocks.
`canBreed()` reports general
workability; it does not prove that an arbitrary mutation condition is satisfied.
Special conditions are descriptions, not a complete machine-readable requirement
API. Mandatory conditions require specific per-alveary confirmation; optional structured route
environment constraints can narrow selection further.

Rechecked 2026-10-21 against the pack's Magic Bees **2.10.12-GTNH**:
[MoonPhaseMutationBonus](https://github.com/GTNewHorizons/MagicBees/blob/2.10.12-GTNH/src/main/java/magicbees/bees/MoonPhaseMutationBonus.java)
returns its bonus multiplier during the named phases and **1** outside them.
Its English `Better success between the {phase} and {phase}.` and
`Better success during the {phase}.` descriptions are optional and do not gate
planning, dispatch or `doctor --confirm`. Routes already stored in saved jobs
use the same check, without needing a replan.
[Arcane's Esoteric + Mysterious recipe](https://github.com/GTNewHorizons/MagicBees/blob/2.10.12-GTNH/src/main/java/magicbees/bees/BeeMutation.java)
has base chance 8 and a 1.2 multiplier from Waxing Crescent through Waxing Gibbous.
[MoonPhaseMutationRestriction](https://github.com/GTNewHorizons/MagicBees/blob/2.10.12-GTNH/src/main/java/magicbees/bees/MoonPhaseMutationRestriction.java)
instead returns **0** outside its phases; its `Occurs between ...` / `During ...`
descriptions remain mandatory, as do unknown descriptions and foundation rules.
Unconfirmed requirements identify the missing confirmation and the per-alveary
command, rather than implying that the selected queen cannot survive.

Temperature order: ICY, COLD, NORMAL, WARM, HOT, HELLISH. Humidity: ARID, NORMAL,
DAMP. Source enums expose title-case display names, normalized by Beeomatic.
NONE is not treated as a valid operating climate. UP/DOWN/BOTH tolerance direction
matters. Active traits determine current operation; both species alleles determine
purity. Every selected princess is rechecked before another cycle.

## Mating, queen climate and inheritance

Rechecked 2026-10-20 against Forestry **4.11.37**:

- [BeekeepingLogic.canWork / tickBreed](https://github.com/GTNewHorizons/ForestryMC/blob/4.11.37/src/main/java/forestry/apiculture/BeekeepingLogic.java#L146-L195)
  checks for a drone while a princess is mating, without applying a parent climate
  intersection. `tickBreed` mates the princess and writes her as a queen.
- [Bee.mate](https://github.com/GTNewHorizons/ForestryMC/blob/4.11.37/src/main/java/forestry/apiculture/genetics/Bee.java#L151-L159)
  stores the drone genome in `mate`; it leaves the princess's own `genome` unchanged.
  [Bee.getCanWork](https://github.com/GTNewHorizons/ForestryMC/blob/4.11.37/src/main/java/forestry/apiculture/genetics/Bee.java#L275-L301)
  tests that genome's active species and temperature/humidity tolerances.
- [Bee.createOffspring](https://github.com/GTNewHorizons/ForestryMC/blob/4.11.37/src/main/java/forestry/apiculture/genetics/Bee.java#L613-L637)
  combines the maternal and stored paternal chromosomes, including possible mutation.

Beeomatic selects a climate where the princess-derived queen can work for the full
cycle, even though mating itself can happen outside that climate. The drone's
climate does not gate dispatch. Newly observed offspring princess genes determine
the next cycle's climate. Both parents still require analysed genes for selection,
and independently confirmed mutation conditions remain enforced.

## ME Interface backend

Bee identity now uses the complete decoded, typed NBT with compound fields sorted,
rather than compressed-byte equality. The user's database diagnostic showed a
stable 419-byte queen tag against a 416-byte network tag, with the first difference
inside the deflate payload. This establishes a representation difference, not by
itself whether the NBT values changed. The Lua decoder verifies gzip CRC/length,
preserves all NBT types, scalar bytes, arrays and list order, and rejects malformed
or oversized data. Equivalent encodings compare equal; changed values remain
blocked. `doctor --nbt` now identifies a changed field when contents differ.
Existing identity references, catalogue keys and scanner count baselines migrate
in memory before reconciliation, then persist with the next ordinary checkpoint.
Raw stack tags remain available unchanged for OC calls. No Data Card is required.

The default backend is now `storage.kind="me_interface"`. The pinned
[DriverBlockInterface](https://github.com/GTNewHorizons/OpenComputers/blob/1.12.61-GTNH/src/main/scala/li/cil/oc/integration/appeng/DriverBlockInterface.scala)
exposes `getInterfaceConfiguration(slot)` and
`setInterfaceConfiguration(slot, databaseAddress, entry, quantity)`.
[InterfaceEnvironmentBase](https://github.com/GTNewHorizons/OpenComputers/blob/1.12.61-GTNH/src/main/scala/li/cil/oc/integration/appeng/internal/InterfaceEnvironmentBase.scala)
uses the named `config` inventory, which pinned
[DualityInterface](https://github.com/GTNewHorizons/Applied-Energistics-2-Unofficial/blob/rv3-beta-1050-GTNH/src/main/java/appeng/helpers/DualityInterface.java)
still exposes. Clearing with only the slot removes its stock request. These
callbacks therefore avoid the export bus's specific configuration-inventory bug.

Quantity is one-based/default one and capped at the item stack limit by
[DatabaseAccess](https://github.com/GTNewHorizons/OpenComputers/blob/1.12.61-GTNH/src/main/scala/li/cil/oc/util/DatabaseAccess.scala).
The Interface has nine local inventory/config slots. Requests replenish and
unconfigured contents return to network storage asynchronously. The backend
uses per-port journals and durable returned transfer counts rather than assuming
stable local source/destination deltas. It rejects loose identity selection,
manual stock filters and insufficient same-label database capacity.

The pinned Forestry
[InventoryAnalyzer](https://github.com/GTNewHorizons/ForestryMC/blob/4.11.37/src/main/java/forestry/core/inventory/InventoryAnalyzer.java)
defines OC input slots 3-8, output slots 9-12, internal specimen 1 and honey
container 2. Input accepts genetic items; extraction is restricted to outputs.
[TileAnalyzer](https://github.com/GTNewHorizons/ForestryMC/blob/4.11.37/src/main/java/forestry/core/tiles/TileAnalyzer.java)
moves an input stack to its internal specimen slot and writes analysed NBT before
returning the stack through its outputs. It uses honey and energy for analysis.
ME scanner setup does not access these indices. It selects separate input and
output chests on the Interface's transposer. Pipes feed the scanner and deliver
only analysed outputs to the output chest. Beeomatic verifies the physical stack
there, then deposits it into the Interface; no second request through ME is needed.
Keep this path empty before first use and exclusive to Beeomatic. Direct analyser
and direct-to-Interface output configurations are retired.

On every start/resume the shared station inspects uncatalogued exact identities
and analyses unscanned initial drones before normal dispatch. ME records lacking
chromosomes are not treated as proof that analysis is needed. Temporary unscanned
offspring are allowed in ME but excluded from selection. No Interface/analyser
in-game success is claimed yet; `doctor --interface PORT_ID` is the new bounded
stock/return probe. See [validation](VALIDATION.md).

## Legacy export-bus backend (saved configurations only)

AE2 export requires a dedicated subnet, database, exact NBT, no fuzzy export
upgrade, an empty isolated export buffer and an export bus inhibited except under
explicit OC redstone control. Callback mode additionally requires the imperative
method to pass an actual export test; it fails on the tested Beta 3 server. The
implemented redstone mode uses normal bus operation instead. No `database.set()` is used to
reconstruct bee NBT. A physical archive chest with a storage bus provides verified
import receipts without racing an asynchronous import bus.

Beta 3's network item conversion can omit Forestry's `individual` record. Unknown
network bees are therefore automatically materialized into the physical archive
for inspection, and their analyzed genetics are catalogued by exact NBT. Truly
unscanned bees then use the scanner path or request manual analysis. The archive
and network views are deduplicated by NBT. Candidate stacks are copied into a
**dedicated database**, then exact binary NBT is compared before configuring the
export bus. Same-label variants must fit the configured database capacity; no
species-only export fallback is permitted. This also avoids depending on binary
filter behavior that differs between OC releases.

For inaccessible direct inventories, the `routed` backend uses verified staging
chests and external caste-selective routing held behind an explicit redstone gate.
It checks housing occupancy plus isolated offspring receipts, bounds transit waits,
and does not claim that a staging chest is the alveary's native inventory.

Lua targets OpenOS Lua **5.2**: no native bitwise operators, `//`, `goto` dependency,
Lua 5.4 resource syntax, or third-party Lua packages. Tests use the actual Lua 5.2
runtime distributed with Lupa on the development host.

Initial multiplayer probing also confirmed OpenOS running **Lua 5.3**, an
`me_interface` with callable-table methods, and a stored Wintry Drone exposing
`tag` as a string while `individual.active` was absent. The full suite now runs on
both Lua 5.2 and 5.3. Proxy validation uses `component.methods(address)` rather than
requiring callbacks to have Lua type `function`; metadata value `false` means an
indirect callback, not a missing method. This probe confirms network visibility
and NBT exposure, not exact export or breeding behavior.

## Confirmed blocker during multiplayer export testing

The user's Beta 3 installation successfully copied the Wintry Drone into the OC
database with byte-identical NBT, but `exportIntoSlot(3,1)` returned `nil` plus
`Cannot invoke ... because "config" is null`. The network drone remained stored
and no chest receipt appeared. This matches
[GTNH issue #25284](https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/25284).
At the pinned OC tag, `DriverExportBus` still uses `getInventoryByName("config")`;
AE2 rv3-beta-1050's `PartSharedItemBus` exposes the new configuration through
`getAEInventoryByName(StorageName.CONFIG)`. The filter configuration callbacks
already use the new API, explaining why configuration succeeds while export fails.

The current Lua backend reports this incompatibility, preserves callback error
details and the pending journal, and attempts filter cleanup. It cannot repair a
Java callback from Lua. Ordinary redstone-controlled bus operation was investigated
next, as recorded below. There is no automatic switch after an uncertain export.
The direct callback remains blocked on this installation. Physical chest
inspection and NBT copying have passed; full application breeding has not.

## Validated normal-export path and implemented workaround

The user confirmed the database-derived Wintry Drone filter in both the GUI
and `getExportConfiguration(3,1)`. Holding redstone enabled long enough for ordinary
bus ticks exported one Wintry Drone to the isolated chest, and its compressed NBT
matched the original exactly. A very brief pulse had produced no receipt; no
fixed warm-up duration or acceleration-card behavior is inferred from that test.

The Lua backend now implements explicit `exportMode="redstone"`, configured in saved installations with a verified OC `redstone` output (`getOutput`/`setOutput`, checked in
the pinned `RedstoneVanilla.scala`). It waits for receipts with a timeout, shuts
down on errors/interruption, and reconciles buffer/archive contents after restart.
Legacy configuration without an export mode retains callback mode; retain its existing circuit until old work is reconciled, then migrate using
`setup --reconfigure` and select `me`.
Manual normal export is verified; automated OC signal wiring and full breeding
still require in-game acceptance. Both paths retain exact-NBT database selection.

`RedstoneVanilla.checkSide` converts the supplied side with `redstone.toGlobal()`;
computer Redstone Card outputs therefore follow local computer orientation. The
transposer's world-side map must not be reused blindly. A reported failure to
light the north-side wire exposed an incorrect world-north assumption in the
manual test guidance; setup now explicitly requires local-side calibration.
