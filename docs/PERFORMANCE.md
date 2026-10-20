# Bee movement performance audit

This audit covers selection, ME requests, transposer movement, collection,
scanner preparation/returns and recovery. Operation counts below come from Lua
mocks; the server profile discussed separately below measures in-game time.

## Server profile diagnosis (20 October 2026)

The supplied 605.4-second run spent 563.3 seconds in 137 state checkpoints
(93% of elapsed time). Measuring encoded size cost 214.1 seconds; encoding
consumed 320.15 seconds excluding nested I/O. The 12 transposer transfers
themselves took 0.6 seconds combined. The state was 339,453 bytes and the report
showed 1,360,217 bytes of free RAM. Scheduler steps reached 109.6 seconds,
delaying the old end-of-step keyboard check.

Checkpoints now count bytes while encoding and retain the encoded chunks when
they fit the RAM budget: at most 512 KiB, and at most half the free memory
remaining above a 512 KiB reserve. With the reported free RAM, that state fits.
The same bytes are written and compared exactly, removing the separate size
pass and second encoding. If a state exceeds the budget, its buffer is discarded
and writing/verification stream as before. Unknown memory availability uses a
16 KiB buffer. No checkpoint or recovery validation is removed.

The foreground worker checks Ctrl+C and Q after each completed checkpoint.
It suspends the operation stack at that boundary rather than throwing through
recovery handlers. Ctrl+C retains the saved work; Q cancels it. A transfer
interrupted at its INTENT or MOVED checkpoint retains its recovery evidence.
Individual saves and component calls still need to finish before these checks.
In-flight enclosing operations are absent from completed-call profile totals
when the worker stops at a checkpoint; completed saves and calls remain recorded.
Repeat the in-game profile to measure the actual improvement.

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
| Completion checks | Stock/genotype work before sufficient confirmation cycles, and all princess/drone pairs in the default mode | Reject insufficient confirmations immediately; check candidates independently in one pass unless full equivalence requires pair comparison |
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
share reserves only when their exact identities match. Completion is checked against
the prior pairwise rules across 144 stock/template/equivalence cases, with a
linear purity-check bound in the default mode. Bulk destination selection
uses one snapshot even when a merge is blocked; fallback selection reads each slot
once, including empty gaps. One unowned ME stack uses two full stack copies
(network mock plus private pooling) instead of three, with genome isolation tested.

## In-game profiling

Stop the current worker with Ctrl+C (which preserves breeding progress), then:

```sh
Beeomatic resume --profile
# Let several slow insertions and collections happen, then press Ctrl+C.
Beeomatic logs --profile --no-pager
```

`breed`, `convert`, `populate`, `imprint` and `plan` also accept `--profile`.
Profiling is disabled by default and applies only to that invocation. It times
wall-clock seconds using `computer.uptime()`, including component synchronization,
disk and machine waits. It writes `data/profile.log` at safe worker/scanner loop
boundaries once 30 seconds have passed and again on normal exit, Ctrl+C or a caught
failure. A long operation can delay the periodic snapshot until its loop completes;
a power loss or hard process kill can lose the most recent measurements. Each run
replaces the previous report, so copy the report before starting another one.

Rows are sorted by `own_s`, the time excluding other instrumented calls nested
inside that operation. `total_s` includes those children, `max_s` is the slowest
individual call, and `errors` counts thrown errors. Do not add overlapping totals.
Counts and totals cover the whole invocation; the history retains the last 24
completed calls taking at least 0.25 seconds, plus thrown errors. Transfers show
source/destination IDs and slots; component calls show full addresses and up to
five primitive arguments. Inventory contents, bee genomes and NBT are not logged.

- `ADDRESS.transferItem` measures the transposer callback itself.
- `inventory.move` includes the checks and checkpoints around a transfer.
- `checkpoint.state` includes the complete durable save. `serialize` measures
  encoding plus its streaming sink. Older logs have a separate
  `checkpoint.measure` row for the now-removed byte-count pass.
  `disk.read`, `disk.write`, `disk.flush`, `disk.close` and `filesystem.*` separate
  measured I/O from the enclosing operation. Untimed work, including file opens,
  remains in the enclosing row's `own_s`.
- `bee.identity` and `nbt.canonical` expose identity and decompression work.
- `storage.scan` includes ME discovery and Interface inventory scans.
- `storage.poll` includes waiting for AE stocking/draining; `storage.wait` and
  `event.wait` expose intentional sleeps. Large idle wait totals are expected
  during breeding and do not by themselves indicate a transfer bottleneck.

The report also includes available free RAM and state-file size. Counters are
limited to 128 operation groups (excess groups aggregate under `other`), proxy
caching to 32 addresses, and slow history to 24 entries. The report is capped at
32 KiB; replacement can temporarily require a second 32 KiB file. Log writes are
best effort and excluded from operation timings; failure does not change breeding
or recovery state. The optional wrappers add measurement overhead, especially to
frequent short Lua calls, so use profiling for diagnosis and omit the flag for
normal operation. No profiler hooks remain after the invocation returns.

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
