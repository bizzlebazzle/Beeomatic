# Physical construction and topology

## ME Interface storage (default)

Each alveary needs a housing adapter and a transposer touching both its inventory
and a **full-block ME Interface**. Each Interface connects to the same powered ME
network and real storage cells. Give every Interface its own adapter on the OC
network. Add an OC database dedicated to Beeomatic. A network reader can be one
of those Interfaces or a controller adapter exposing `getItemsInNetwork`/`store`.

```text
                      MAIN ME NETWORK + cells
                         |             |
                   [Interface A]  [Interface B]  ...
                         |             |
                   [Transposer A] [Transposer B]
                         |             |
                     [Alveary A]    [Alveary B]

MAIN ME NETWORK -- [Scanner Interface] -- [Scanner transposer] -- [Input chest]
                         ^                                          |
                         +--- return pipes --- [Analyser] <--- pipes+
```

OC cable connects all adapters, transposers and the database to the controller.
AE cable connects the Interfaces to ME. Setup assigns inventory and alveary IDs
automatically; you enter a friendly alveary name. Two alvearies may share one
transposer and Interface when each housing occupies a different adjacent side.
Select the same Interface inventory and adapter for both; setup reuses its port ID.
Each alveary still needs its own housing adapter. Every port has a unique ID/address; two
ports are separate inventories, not two views of a shared chest. No shared archive,
storage bus, export bus, export buffer or export redstone circuit is required.
Do not put a storage bus on these Interfaces or working alvearies. Keep this
worker in sole control of reserved bees and Interface filters; other consumers
must not remove reserved bee stock.

Setup assigns local Interface slots **1 princess, 2 drones, 9 returns**. Requests
use exact database-derived NBT and request only the needed count. Stocked slots
refill automatically after extraction; Beeomatic clears its request and lets the
refill return to ME. Keep return slots unconfigured. Products and offspring enter
those slots and drain into ME. Full/offline ME preserves accepted local contents
and pauses further collection. Keep all relevant chunks loaded and allow enough
AE channels, power and cell capacity for each port.

Side numbers are world directions relative to the transposer: **0 down, 1 up,
2 north, 3 south, 4 west, 5 east**. Slots are one-based. Adapter addresses identify
components; they do not transfer items. Direct Forestry alveary slots are assigned
automatically: **1 princess/queen, 2 drone, 3-9 products/offspring**. Setup checks
the selected inventory/housing association with one bee at a time; these placement
checks accept unanalysed bees. Empty/wrong-caste/mismatched-adapter readings explain
the problem and let you retry or type `back`. Routed staging maps remain configurable.
Register an assembled alveary once, even if multiple adapters
can observe blocks of the same multiblock.

## One shared scanner

Give the scanner station its own Interface and transposer on the same ME and OC
networks. The transposer touches that Interface and a normal input chest.
Pipes extract bees from the chest into your analyser, then extract analysed bees
directly into an unconfigured Interface slot on the same ME network. The analyser
and its output do not need to touch the transposer or have OC adapters.
Supply analyser honey/power separately. Configure pipes to extract only analysed
outputs, without cycling unanalysed bees straight back to ME.

Setup selects only the Interface connection and input chest. Beeomatic chooses
an empty chest slot automatically; it does not manage analyser slots or move
outputs. It records ME quantities before sending one batch, waits for the full
return, briefly requests the exact returned variant for physical analysis
verification, then clears that request so the bees return to cells. Existing
analysed stock can merge with returns without losing owned quantities.

Before first use, empty the chest, pipes and analyser of bees. Keep this scanner
path dedicated to Beeomatic, and do not manually add/remove bees or run another
scanner into the same ME network while a batch is outstanding. Ambiguous return
variants/counts pause for inspection; a missing return times out after ten minutes
with the batch preserved. The program cannot inspect bees inside external pipes
or the analyser. Previously saved direct-analyser configurations remain supported
for recovery; new ME setup uses this chest-and-pipes flow.

Startup enters `PREPARING_STOCK`: unknown exact variants are physically inspected,
and all unanalysed drones are analysed before breeding starts. ME item records can
omit genomes even when the physical bee is already analysed; those bees are
inspected and catalogued without spending analyser supplies. Large quantities
are processed in stack-sized batches. An unavailable scanner blocks readiness.
New offspring can wait temporarily in AE during operation but are excluded from
breeding until inspected/analysed. A restart repeats the initial readiness check.

After setup, put at least two identical analysed drones in ME and run:

```sh
Beeomatic doctor --interface port_temperate
Beeomatic doctor --interface scanner_port
```

Use the port IDs you actually saved. The probe requests two drones, transfers one
to an unconfigured return slot, clears the stock request, and verifies the original
exact ME count is restored. It records the successful probe in state. Stop the
worker and finish/reconcile pending requests first; keep other bee automation
idle during this conservation test. Repeat for each registered port. This probe
does not prove the analyser or a complete breeding cycle works; complete the
[in-game acceptance](VALIDATION.md) as well.

## Climates and routed housings

Read each alveary's actual working temperature/humidity, including upgrades.
Setup does not ask for biome, dimension or flower lists. Status shows the current
princess/queen and drone in each alveary, with the flower type required by each
bee's active genes. Unanalysed bees show an unknown requirement until analysed.
Supply the displayed flowers in-world. The intended continuous-operation setup
includes **Alveary Lighting and a Rain Shield** on each alveary. Install and
maintain these upgrades physically; Beeomatic does not install them. Setup asks
no upgrade, day/night, rain or sky questions, and old declarations do not block scheduling.
The worker observes the housing's actual workability while the queen is present.
Flower availability is checked by actual housing operation, not a configured list.
The housing API cannot report all these facts. `canBreed()` does not
prove every mutation requirement. Revoke attestations when the world changes.

If direct inventory access is unavailable, the `routed` backend retains a housing
adapter and uses isolated input/output staging with caste-selective external pipes.
Both input routes must stop behind the configured OC redstone gate while parent
receipts are checked. Disable automatic rebreeding. Bind the output inventory to
that machine only. Redstone output sides follow the controller's local orientation;
verify them physically rather than reusing transposer world sides.

## Chest mode and older installations

Standalone chest mode remains available. Each breeder/scanner transposer needs a
verified view of the same physical archive, or stock can be unreachable. Identical
IDs mean the same real inventory; do not reuse an ID for disconnected chests.
This optional mode retains its own archive scanner contract.

Existing export-bus configurations still load through the compatibility backend.
See [legacy hardware](LEGACY_AE2.md) and [migration](INSTALLATION.md). The new setup
contains no export-bus or redstone-export prompts.

Templates use an analysed reference drone. In Interface mode, setup records its
exact NBT identity from a temporary witness inventory; return the drone to ME.
The reserve is protected by genotype/count, not a permanent ME slot. The optional
foundation robot remains a separately registered, addressed helper; it never digs
or automatically attests arbitrary mutation conditions.
