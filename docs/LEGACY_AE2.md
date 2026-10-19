# Legacy AE2 export-bus installations

Compatibility reference for existing `storage.kind="ae2"` configurations only.
Fresh setup uses ME Interfaces. These modules remain installed so existing jobs
and journals can be finished/reconciled before migration. The wizard no longer
creates or edits export-bus configurations. See [installation](INSTALLATION.md)
for migration. Do not change backend kind while a movement is unresolved.

## AE2 dedicated subnet

Required: powered dedicated ME subnet and storage, ME storage bus on the physical
archive, interface or controller exposed through an adapter, a **dedicated OC
database**, and a separately exposed ME export bus feeding an isolated buffer.
For Beta 3 redstone export mode, add an OC Redstone Card/output and a dedicated
redstone connection to the export bus.

```text
ME storage / subnet -- storage bus -- archive <---> breeder transposers
          |
          +-- ME interface/controller -- OC adapter -- OC cable
          |
          +-- export bus --> isolated buffer <---> bridge transposer <---> archive
                       OC adapter         |
                                 dedicated database on OC network
```

The buffer must not be exposed to ME by another storage/import bus. Set the bus's
AE2 Redstone Card to **active with signal**, remove fuzzy/crafting upgrades and
clear all filters. The dedicated OC output must be the ONLY source of enabling
signal; remove the testing lever before automatic control. Register the OC
redstone component address and output face independently from the export-bus face.
**Redstone Card side numbers follow the computer's local orientation**: the pinned
OC implementation calls `redstone.toGlobal()` before accessing the physical face.
Do not assume that side 2 powers world north as it does for a transposer. Identify
the computer's front and verify the actual powered face with the output enabled;
only then save the redstone side and attest the circuit in the existing configuration.
Output zero must disable the bus; output 15 must enable it. Verify the entire
physical circuit before attesting `exportGate.verified` in setup.

Existing Beta 3 redstone configurations use **redstone mode**, avoiding the broken imperative
`exportIntoSlot` callback. Beeomatic reads back the exact database-derived filter
before enabling the signal. It polls every second, holding the signal until a real
receipt appears; it does not assume a short pulse or require acceleration cards.
The configurable maximum wait defaults to 60 seconds. On receipt, error, Ctrl+C,
pause/stop key or timeout it attempts signal OFF and filter cleanup. It rechecks
all buffer slots, verifies exact NBT/source counts, and archives every matching
stack, including excess exported during a polling interval. The whole buffer must
start empty and have no other automation. Following a power interruption, recovery
first disables the saved output/filter and reconciles actual buffer/archive stock
before any new export. Ensure the physical circuit does not introduce delayed
exports or route items from elsewhere after the bus has been disabled.

Callback mode remains for installations where the imperative method has actually
passed an export test. Never switch mechanisms automatically after a missing
receipt: an uncertain first export must be reconciled first.

Beeomatic temporarily uses filter slot 1 and clears it after each request.
Database capacity is entered
explicitly; the database must not be used by another script. Same-label genetic
variants need enough database entries to copy the candidate group before choosing
the exact NBT match. A capacity mismatch pauses rather than selecting loosely.

Results are transferred into the **real archive chest** and verified there. Its
storage bus makes those bees part of ME storage. There is no racing asynchronous
import bus on that chest. On Beta 3, network item records can lack Forestry genetic
data: unknown records are exported to the archive for inspection and catalogued.
Allow enough physical archive space for this discovery, offspring, products and
protected reserves. Space exhaustion preserves sources and pauses collection.

The bridge transposer needs a view of the same physical archive used by the
selected breeder. Other breeder transposers can use their own views of that hub.
Disconnected archives need suitable physical bridge topology; there is no
arbitrary transfer between OC components. Do not put storage buses on working
alvearies. Only Beeomatic may modify the dedicated export bus/database while jobs
run. Avoid manual item movement while a transfer is in progress.
