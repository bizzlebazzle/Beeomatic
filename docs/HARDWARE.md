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

MAIN ME NETWORK -- [Scanner Interface] -- [Scanner transposer] -- [Analyser]
```

OC cable connects all adapters, transposers and the database to the controller.
AE cable connects the Interfaces to ME. Every port has a unique ID/address; two
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
networks. The transposer reaches the analyser's exposed input/output inventory,
or dedicated isolated staging inventories with external routes through it.
There is one reserved batch in this path at a time. No unrelated bees may enter.
Supply honey/power/consumables separately, outside the registered bee slots.

Pinned Forestry source defines a twelve-slot analyser: specimen **1**, honey
container **2**, automated input **3-8**, output **9-12** (OC indices). Slot 1 is
internal processing, not an automation input. These are source observations;
confirm the actual machine, faces and inventory before configuring it. The
scanner inspects all visible bee slots for unrelated stock when idle and extracts
only the configured output slots. Consumable slots are left alone.

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
Enter flower-provider IDs from analysed genetics and verify sky, rain and day/night
operation. The housing API cannot report all these facts. `canBreed()` does not
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
