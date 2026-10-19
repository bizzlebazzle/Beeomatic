# ME Interface storage redesign (research and proposal)

Research date: 2026-10-19. Target: GTNH 2.9.0 Beta 3, OpenComputers
1.12.61-GTNH, AE2 rv3-beta-1050-GTNH. This document proposes a replacement;
the application still implements the archive/export-bus design. No runtime,
setup, configuration or saved-state changes are part of this research commit.

## Decision and scope

Use real ME storage as the stock pool and a full-block ME Interface beside each
alveary's transposer as its local transfer port. Add one shared scanner station,
as requested. Remove the shared archive chest, archive storage bus, export bus,
export buffer and export redstone circuit from the new backend's requirements.

The remaining choice is whether unanalysed bees may temporarily enter the main
ME network while awaiting scanning. The single-network proposal below permits
this temporary queue but excludes those bees from usable breeding stock. If
analysis must precede *any* main-network storage, use the separate intake route
described below. This distinction cannot be solved by an Interface setting.

## Verified API and behavior

The pinned [OC block Interface driver](https://github.com/GTNewHorizons/OpenComputers/blob/1.12.61-GTNH/src/main/scala/li/cil/oc/integration/appeng/DriverBlockInterface.scala)
exposes `getInterfaceConfiguration` and `setInterfaceConfiguration` on
`me_interface`, alongside network queries. Its
[configuration implementation](https://github.com/GTNewHorizons/OpenComputers/blob/1.12.61-GTNH/src/main/scala/li/cil/oc/integration/appeng/internal/InterfaceEnvironmentBase.scala)
uses `getInventoryByName("config")`. Pinned AE2's
[DualityInterface](https://github.com/GTNewHorizons/Applied-Energistics-2-Unofficial/blob/rv3-beta-1050-GTNH/src/main/java/appeng/helpers/DualityInterface.java)
still implements that name. Thus the export bus's known missing configuration
inventory does not imply the same failure here. This is source evidence, not an
in-game pass.

Calls for a full-block Interface are:

```lua
-- Illustrative API only; not a ready-to-run transfer/recovery procedure.
iface.setInterfaceConfiguration(slot, databaseAddress, entry, quantity)
local configured = iface.getInterfaceConfiguration(slot)
iface.setInterfaceConfiguration(slot) -- clears this request
-- Physical movement is separate:
transposer.transferItem(interfaceSide, alvearySide, count, sourceSlot, targetSlot)
```

Slots are one-based. The optional quantity defaults to one and is capped by the
item's maximum stack size in
[DatabaseAccess](https://github.com/GTNewHorizons/OpenComputers/blob/1.12.61-GTNH/src/main/scala/li/cil/oc/util/DatabaseAccess.scala).
Copy actual bee stacks into the database; do not recreate their genetics from
labels. The database is a filter/reference store, not item storage.

AE2 has nine local stock slots. Stocking holds requested items locally and
replenishes them after removal; clearing a request schedules return to ME.
Unconfigured contents are also scheduled for insertion into ME. These operations
need ticks, power, channels and capacity. Disable fuzzy/crafting upgrades for this
use. Stock configuration does not itself place parents into an alveary, and an
Interface does not analyse bees. These observations follow `updatePlan`, `usePlan`
and the slot constants in the pinned DualityInterface linked above.

The pinned [OC inventory transfer implementation](https://github.com/GTNewHorizons/OpenComputers/blob/1.12.61-GTNH/src/main/scala/li/cil/oc/util/InventoryUtils.scala)
moves between actual adjacent inventories with explicit slots/counts. Therefore
an Interface port does not remove the transposer adjacency requirement.

## Proposed physical layout

```text
                         MAIN ME NETWORK + storage cells
                             |                  |
                    [ME Interface A]    [ME Interface B]     ...
                             |                  |
                       [Transposer A]     [Transposer B]
                             |                  |
                         [Alveary A]        [Alveary B]

MAIN ME NETWORK -- [Scanner ME Interface] -- [Scanner transposer]
                                                    |
                                            [Shared analyser]
```

OC cable connects the transposers, Interface adapters, housing adapters and
database to the controller. AE cable connects the Interfaces to the same intended
ME network. Each local port has a distinct identity; these are not multiple views
of one physical inventory. No alveary transposer needs to reach another port.

The scanner diagram assumes the chosen machine exposes suitable automated
input/output slots. Verify its faces, power, consumables and exact machine type.
If it needs external routing, use small dedicated staging inventories at this
one station, not a shared storage archive beside every alveary. Bound transit
waits and process one reserved batch at a time.

If unanalysed bees must stay outside the main network: route bee outputs over
dedicated physical transport to the shared scanner, or use a separate AE intake
network with temporary queue storage and a second Interface at each alveary.
The scanner bridges intake to main ME only after analysis. Products can still
enter main ME directly. This costs extra transport/hardware and must be explicit
in setup; a single-network design cannot promise that physical separation.

## Item flow and ownership

1. **Stock discovery:** query ME and catalogue exact bee variants. Existing Beta 3
   observations show network records can omit genomes even for analysed bees.
   An uncatalogued tag means "needs physical inspection", not necessarily "needs
   analysis". Materialise it at the shared station, read its individual, and only
   send genuinely unanalysed bees through the analyser. Cache by full item identity
   including exact NBT. Do not export every unknown variant into a permanent chest.
2. **Parent request:** reserve the selected quantity of an exact variant globally,
   choose the destination alveary's port, copy/verify the matching database entry,
   persist intent, configure the chosen stock slot, and await a matching physical
   receipt. Request only the units needed for the cycle. Reserve logical quantities
   rather than claiming a permanent ME slot or entire drone stack.
3. **Parent insertion:** move the chosen count from the witnessed Interface slot
   to the verified housing input. Read back the destination/queen transition, then
   clear the stock request and reconcile any automatic refill back into ME. Do not
   clear before extraction: that would return the very parent being requested.
4. **Collection:** journal each output with job, cycle, exact identity and count.
   Send products and bee batches into unconfigured return slots of that alveary's
   Interface. Track local acceptance separately from eventual ME insertion. Pause
   on backpressure; preserve outputs not yet accepted.
5. **Shared scanning:** queue returned bee batches with provenance and exclude
   pending quantities from selection. The station requests one batch from ME,
   inspects it, analyses if needed, verifies caste/count/genomes, and returns the
   result through its own Interface. Persist the old-to-new identity mapping:
   analysis changes NBT. Catalogue the result and release only confirmed quantities.
6. **Next cycle:** identify each job's offspring using batch ownership and exact
   identity, not a transient Interface slot. Equivalent stacks can merge in ME;
   ownership is a quantity ledger. Retain the princess lineage and drone/template
   reserves across those merges. No disposal policy is introduced.

Use fixed role slots initially (princess, drone, return) with configured counts;
general slot allocation can follow later. Keep return slots unconfigured and
separate from stock requests. A single shared database can be used if each
copy/configuration sequence is exclusive and configuration readback is verified
before reuse. Capacity checks for same-label genetic variants remain necessary.

## Necessary internal changes

This cannot safely be implemented by replacing an archive endpoint with an
Interface address. Current assumptions differ:

| Current code | Required change |
| --- | --- |
| `storage/ae2.lua` extends chest storage and exports whole stacks | Add an Interface backend with network stock, per-port requests and bounded quantities |
| `inventory.lua` requires stable source/destination deltas | Add external-operation receipts for Interface refill/drain; preserve existing rules for ordinary inventories |
| `scanner.lua` returns to the original archive slot | Receive an owned batch, verify its changed identity and return to ME |
| `scheduler.lua` stores offspring/lineage as endpoint + slot | Track logical batch ownership, exact identities and quantities across ME merges |
| `templates.lua` protects an archive slot | Protect a verified exact reference genotype and its reserved quantity |
| Setup assumes a common archive | Discover/register a local Interface port for each alveary and one scanner station |

An automatically replenished source may show no net decrease after a successful
move. An automatically drained destination may be empty after successful deposit.
The current transfer journal would classify these as uncertain. The new backend
needs durable request, local-transfer and network-return phases; success cannot
depend solely on post-call local counts or solely on a global ME count delta.
Concurrent jobs can change that same global count.

On restart, inspect pending stock configurations, local slots, housing state and
batch ledger before dispatch. An unresolved insertion into ME must never be
replayed from intent alone. Fully indistinguishable outcomes pause for audit;
the design does not claim crash-proof atomicity across Lua persistence and AE.
Reconcile leased slots before clearing them, since clearing itself moves items.

## Setup experience

Start with a concise layout explanation and choose Interface storage once.
Discover candidate components, use numbered choices/names, and show actual side
contents. Register one alveary by pairing its housing, transposer and adjacent
Interface. Perform one guided parent/return probe, then save it independently.
Allow adding another alveary later without repeating storage/scanner setup.
Persist partial setup and offer resume/edit/back navigation.

Keep necessary physical witnesses for housing association, slots and climate;
automate component-method and inventory checks. Print a short final connection
summary. Old export/redstone prompts must not appear for the Interface backend.
Pending scanner batches and their blocking reason belong in status output.

## Implementation and commit sequence

1. **This research proposal.** Commit only this new document. Preserve all setup
   edits that were already uncommitted when this task began.
2. **Hardware probe and API evidence.** Add a bounded, explicit Interface test:
   database-derived exact filter, requested count, local receipt, partial extraction,
   refill, clear/return and ordinary output insertion. Test the actual analyser's
   input/output access. Record in-game results separately from source verification.
3. **Interface storage and recovery.** Add configuration/backend selection,
   per-port operations, quantity reservations and recovery tests. Preserve the
   existing backend for existing installations; do not silently migrate saved jobs.
4. **Shared scanner and scheduler ownership.** Implement the batch queue, catalogue,
   analysis identity mapping, lineage/template protection and collection recovery.
   Exercise the complete flow with two alvearies before exposing it as the default.
5. **Setup and documentation.** Implement resumable registration and new defaults,
   update installer manifest if new runtime files are added, and document migration.
   Require old transfers/jobs to be reconciled or finished before migration.

Each implementation commit needs relevant tests before the next dependent change.
Run the existing Lua 5.2/5.3 suite for integration changes. Add behavior tests for
same-label different-NBT bees, partial transfers, automatic refill, full/offline
ME, shared-scanner contention, merged batches, changed analysis NBT, restart at
each external-operation boundary and quantity-based reserve enforcement.

In-game acceptance must demonstrate two independent alvearies drawing from ME,
products returning to ME, offspring passing through one shared scanner, protected
stock remaining unavailable to other jobs, and restart without duplicate insertion.
No implementation or hardware success is claimed by this planning document.
