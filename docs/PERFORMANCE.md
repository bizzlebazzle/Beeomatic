# Bee movement performance audit

This audit covers selection, ME requests, transposer movement, collection,
scanner preparation/returns and recovery. Operation counts below come from Lua
mocks; they are not measurements of elapsed time on an OpenComputer.

## Changes

| Path | Avoidable work removed | Checks retained |
| --- | --- | --- |
| Component access | Repeated method discovery for the same proxy | Resolve the current proxy on access, reject missing methods, refresh metadata when the proxy changes |
| Destination selection | A second inventory walk to find an empty slot after merge search | Reuse the same ordered snapshot and its size; prefer exact unreserved merges and verify the destination again before movement |
| ME result allocation | Deep-copying already privately pooled unowned stacks again | Transfer the private stack to the result; catalogue, owned splits and network data remain independent |
| Housing/output reads | Inventory-size checks for each slot in a group | One availability check per group, fresh reads of every selected slot |
| Physical transfer | Separate reservation checkpoint and duplicate initial source read | Reservation and intent saved together before movement, moved count saved before receipt evaluation, exact source/destination checks and committed receipt |
| ME request | Clearing every database slot and refilling the same verified entry repeatedly | Clear the required matching-variant range; re-read cached entry NBT before reuse; verify configuration and actual stocked quantity |
| ME stock ownership | Sorting and walking all batches for every genotype | One sorted batch grouping by exact identity; existing count and missing-batch checks |
| Genetic comparisons | Serializing both operands just to compare them | Recursive field/value comparison, including extra fields and false values |
| Parent selection | Recounting all exact-genotype drones for every candidate | One temporary count map per selection snapshot; exact reserves and ownership filtering |
| Dispatch | Two standalone logical ME lease saves | Save both leases with PREPARING before the first materialization |
| Startup scanning | Repeated global stock scans while a batch already has a saved source/baseline | Scanner still verifies its exact physical returns; global stock is refreshed before the next batch and planning |
| Offspring assessment | Rescanning Interface stock immediately after the scanner declared the snapshot ready | Reuse only that freshly verified snapshot; independent dispatches still scan again |
| Lineage protection | Walking every active job for every inventory item | Build a temporary location/genotype index per selection; owner and DONE rules remain unchanged |

Regression checks demonstrate 20 accesses to one unchanged component use one
method-discovery call; three grouped slot reads use one size check; a normal
transfer uses three state checkpoints instead of four; a fresh one-variant ME
selection clears one slot instead of nine; a second verified entry selection
requires no clear/store calls. Selection across 80 drone variants stays within a
linear identity-call bound and rebuilds totals after stock changes. Split stacks
share reserves only when their exact identities match. Bulk destination selection
uses one snapshot even when a merge is blocked; fallback selection reads each slot
once, including empty gaps. One unowned ME stack uses two full stack copies
(network mock plus private pooling) instead of three, with genome isolation tested.

## Remaining costs

- Durable checkpoints still serialize and verify the complete saved state. Their
  cost grows with the live catalogue, jobs, batch records and retained receipts.
  A smaller separate movement journal would require a recovery-format redesign.
- Independent dispatches still scan current stock. Reusing a snapshot after a
  withdrawal could allocate the same units to two machines, so there is no
  persistent cache of inventory contents or spendable counts.
- ME stock discovery still reads the network and registered Interface buffers.
  Exact request preparation may enumerate same-label genetic variants. A bee-only
  API or filtered discovery could reduce large-network payloads but must preserve
  all supported item names and the pinned server API contract.
- The worker now defaults to 0.5 seconds, and Interface/scanner checks to 0.1
  seconds, including existing saved configurations. Optional workerPollSeconds
  and per-subsystem pollSeconds settings override them with a 0.05-second minimum.
  Unchanged idle ticks and stock-readiness checks avoid checkpoint writes, while
  UI housing observations are limited to once per second. Movement, lifecycle,
  changed diagnostics and terminal flags retain their checkpoints. Component
  calls, disk writes and physical machines still add their own time.
- The current external scanner still returns through ME. Unknown return variants
  are requested for physical inspection and verified before use. The planned
  output-chest layout is deliberately not implemented in this change.
- Retained chest, routed-housing and AE2 export backends have reachable consumers:
  setup/configuration, diagnostics or saved-work recovery. Removing them would
  remove supported paths. Unreferenced breeder inspection/evacuation wrappers and
  the explicitly unwanted robot feature were removed. The generic inventory
  inspector remains because doctor invokes it through pcall.

## Validation

The full suite runs on Lua 5.2 and 5.3. It covers missing/replaced components,
changed database contents, unavailable stock, split-genotype reserves, simultaneous
withdrawals, interrupted and partial movement, collection recovery, scanner
ownership and installation. Persistence also round-trips 1,600 synthetic records
under a 2 MiB allocator limit. Actual transfer latency still requires in-game
measurement with the installed computer, disk, AE network and pipes.
