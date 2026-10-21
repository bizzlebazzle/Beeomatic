# Bee movement performance audit

This audit covers selection, ME requests, transposer movement, collection,
scanner preparation/returns and recovery. Operation counts below come from Lua
mocks; the server profile discussed separately below measures in-game time.

## Larger bounded NBT cache and reuse counters (21 October 2026)

The seventh in-game benchmark took 75.7 seconds. NBT canonicalization still
consumed 11.4 seconds across 2,390 calls. Its separate cache held at most 16
compressed tags within 64 KiB, too few for the supplied 80-entry catalogue.

The NBT cache now allows 128 entries within 128 KiB. Accounting includes compressed
bytes, canonical bytes and 128 bytes per entry for overhead. FIFO eviction keeps
both limits bounded; the existing per-tag parsing/decompression limits and exact
canonical identity format are unchanged. Only immutable input bytes and their
canonical result are cached, with no inventory counts or ownership data.

The profile header adds `NBT cache`: hits, misses and evictions during the
command, plus current entry count and accounted retained bytes. Counters use a
baseline at command start so a warm module cache does not inflate reported work.
Opaque mock tags are excluded; a failed gzip decode counts as a miss but is not
retained. The existing large-string encoding cache has separate counters.

`python tests/benchmark_nbt.py` compares the previous and new bounds on 80 synthetic
variants. An optional `state.lua` or `catalogue.lua` path instead parses saved
canonical identities and recompresses their NBT for replay, without executing the
save. In a local 30-pass replay of the supplied catalogue (2,400 calls), misses
fell from 2,251 to 70 and evictions from 2,235 to zero. The new cache recorded
2,330 hits (97.1%) and retained 102,285 accounted bytes. There were 70 distinct
recompressed inputs across the 80 catalogue entries. Both Lua 5.2 and 5.3 returned
identical canonical bytes. This replay changes compression/field ordering from
the original game tags; the next in-game profile must establish actual reuse.

Resource checks fill the NBT cache alongside a full encoding cache during 339 KB
saves and reload, and retain a full NBT cache through startup/recovery. All fit
the 2 MiB allocator ceiling with 384 KiB host reserve, including without manual
collection. No scanner routing or checkpoint behavior changes in this update.

## Save the catalogue only when it changes (21 October 2026)

The sixth in-game profile took 86.8 seconds, down from 126.4 seconds. Encoding
cache hits reached 98.8%. Serialization excluding nested operations fell to
0.95 seconds, but the 70 checkpoints still took 34 seconds, including 18.05
seconds in writes. File replacement adds further time within those checkpoints.

The CLI now stores known ME genomes in `data/catalogue.lua`, outside the
frequently written `data/state.lua`. The catalogue is written before state when
entries are added, replaced with changed genes, or pruned. Unchanged replacement
entries do not trigger writes. Existing genome writers replace entire entries;
the change detector retains a shallow index of these entries, sharing immutable
gene tables and identity strings rather than copying the catalogue in memory.
State serialization uses a shallow view without `aeCatalog`; the live state is
never detached from its catalogue, including when a write fails or yields.

Loading still accepts an inline legacy catalogue. The next checkpoint saves it
separately before replacing state; inline data wins if recovering an older
backup. Each file uses the existing temporary-write/backup replacement path.
The separate file contains knowledge of genes, not ownership or movement counts.
Pending transfers, scanner progress and ownership remain in the state checkpoint.
Missing catalogue files start an empty index that normal stock analysis can
rebuild; unreadable files retain the existing backup/error behavior.

Against the supplied 259,964-byte save, the repeated state file is 41,633 bytes
and the separate catalogue is 218,325 bytes on Lua 5.3. A local 70-save replay
wrote the catalogue once and 3,132,626 bytes in total, about 83% less than writing
the full state 70 times. Migration, repeated writes and reload passed on both
Lua 5.2 and 5.3 in 2 MiB VMs with 384 KiB host reserve and manual collection
disabled. This byte reduction is not a prediction of elapsed in-game time.

The profile adds `checkpoint.catalogue`, `catalogue.load` and `Catalogue file
bytes` alongside the state measurements. Catalogue writes are nested inside
state checkpoints, so do not add their totals together. Both files share the
existing 256 KiB encoding cache. NBT caching and direct scanner routing remain
unchanged; rerun `Beeomatic benchmark` to measure this update.

## Cache sized against the saved catalogue (21 October 2026)

The fifth in-game benchmark took 126.4 seconds. Its 74 checkpoints consumed
76.8 seconds, with 54.4 seconds in serialization excluding children. The first
encoding cache recorded 2,295 hits against 16,603 misses: its 64 KiB budget was
too small to retain this catalogue between checkpoints.

The supplied 259,964-byte state has 80 catalogue variants occupying 218,326
encoded bytes. Its 203 distinct long-string pieces need 225,252 accounted cache
bytes. Increasing the FIFO limits to 256 KiB and 256 entries retains these pieces.
A 128 KiB FIFO still churned through most of them. In a local 74-save comparison,
the previous cache took 0.89-0.94 seconds; the larger cache took 0.65 seconds
(27-30% less CPU time). It recorded 17,927 hits and 203 misses, about 99% hits
including the first save. This measures serialization only, not in-game elapsed
time; small fields and table traversal still run on every save.

The cache is released before loading a save so encoded pieces do not compete
with the parser for RAM. Repeated 339 KB saves with a full cache and a reload
fit a 2 MiB VM with 384 KiB host reserve, including without manual collection.
The full startup/recovery tests also retain their RAM and disk limits.

Run `python tests/benchmark_serialization.py "path/to/state.lua"` to compare
cached and uncached encoding against a real save on the development PC. The
file is parsed as data. The supplied state is not added to the repository.
Run `Beeomatic benchmark` in-game next to measure the actual change. Direct
scanner routing and NBT canonicalization remain unchanged.

## Bounded string-encoding cache (21 October 2026)

The fourth in-game benchmark took 127.65 seconds. Its 70 checkpoints consumed
78.4 seconds, including 58.65 seconds of serialization excluding children; disk
writes took only 1.5 seconds. The state was 260,009 bytes.

The initial cache retained escaped pieces of long strings between saves.
Pieces are at most 512 source bytes, so similar NBT identities can share unchanged
parts. It evicted its oldest pieces within a 64 KiB accounting budget and
64-entry limit. Accounting includes raw and escaped bytes plus an entry overhead
allowance; actual VM memory is covered by the allocator tests. Small strings keep
their direct path. Mutable tables are always traversed again, and changing a
string changes its cache key. Save bytes, disk format, watchdog yields and transfer
checkpoints are unchanged. The cache lasts only for that store's invocation.

`python tests/benchmark_serialization.py` compares 70 cached/uncached serializations
on Lua 5.2 and 5.3. The 247,218-byte shared-NBT catalogue fixture has 98% of its
string input bytes in long strings. One local sample reduced bytes passed through
escaping by 61-78%, and CPU time by 48-70% (about 0.6 seconds to 0.18-0.32 seconds).
The deliberately unrepeated 250,962-byte text fixture has no cache hits and was
6-8% slower due to cache bookkeeping. These synthetic workloads do not establish
an in-game speedup; entry order and real genotype reuse affect the result.

The profile header now includes `Large-string cache`: piece hits, misses, source
bytes whose escaping was reused, and accounted retained bytes. Those counters
describe the state writer's long-string pieces, not small fields or NBT decoding.
Rerun `Beeomatic benchmark` and share its profile to measure real reuse and timing.
The NBT canonicalization cache and P2P routing are unchanged.

## Fewer checkpoints and repeated observations (21 October 2026)

The third in-game benchmark took 162 seconds. Its 74 checkpoints consumed
84 seconds, including 62.3 seconds of serialization work excluding children.
The eight transfer callbacks together took only 0.4 seconds.

Dispatch now saves reservations with PREPARING and the prepared inputs, rather
than in separate saves. RUNNING and its event log share a checkpoint. Completion
and assessment save ME batch releases with the associated job transition. The
scheduler compares a small lifecycle/diagnostic summary with the last successful
checkpoint, including saves inside inventory/scanner/storage calls, before writing
at the end of a step. Changed errors and terminal flags still get saved; unchanged
startup scanning messages no longer write the state every waiting iteration.
Physical transfer intent, moved-count and committed-receipt saves remain.

Two-slot input reads now use bulk snapshots too. Foreground status can consume
the housing observation made by the scheduler in the same iteration; a new
dispatch discards it, and the next iteration starts fresh. Standalone status
commands still read live hardware. Initial housing/scanner-emptiness checks run
once at startup/resume instead of every ready poll. New ME bees still queue for
analysis. While an Interface scanner batch is active, its saved source and expected
return suffice for polling; whole-network stock and display counts refresh after
the batch finishes, before parent selection. Assessment also waits for that
iteration's scanner result instead of polling the same batch a second time.

A delayed mock benchmark (six breeding wait polls, three analysis polls per
batch) kept all eight transfers and reduced checkpoints from 97 to 90, network
scans from 28 to 18, and individual slot callbacks from 161 to 79. These are
operation counts, not an in-game speed prediction. Rerun `Beeomatic benchmark`
to measure this update. P2P routing and the NBT cache are unchanged.

## Smaller receipt history and bulk output reads (21 October 2026)

The next in-game benchmark took 257.3 seconds, down from 565.3 seconds (54%).
Its 99 checkpoints took 175.6 seconds; serialization alone still consumed 139.9
seconds excluding children. The state was 358,032 bytes. Per-slot reads and
inventory-size calls on the busiest transposer added another 28.35 seconds.

Completed Interface receipts now discard their full NBT identity, along with the
already-discarded stack and ownership transform. Ownership has already been
applied to active ME batches; collection recovery uses receipt IDs and endpoints.
Pending movement proof, active batches, requests and catalogue identities stay
exact. Legacy export receipts retain the identity used by export reconciliation.
The loader also compacts old Interface history, so the next save benefits without
waiting for all 64 retained receipts to rotate out.

The same 64-receipt/16-catalogue synthetic fixture below shrinks from 359,852 to
102,421 bytes (72%), reducing writes per checkpoint from 91 to 26. Local Lua 5.2
CPU time was about 22 ms before versus 5 ms after; in-game timing remains to be
measured. This change does not introduce a new persistence format or cache.

The initial bulk-read change used one fresh snapshot for three or more slots
when supported. Only requested slots are returned, including correct gaps; old
components keep the per-slot fallback. This reduces housing-output polling from
one size call plus a call per output slot to one bulk callback. Stock is never
reused across observations.

## Single-pass saves (21 October 2026)

The supplied automatic benchmark took 565.3 seconds, including 507.55 seconds
in 113 state checkpoints (90% of elapsed time). Its 299 serialization calls
spent 399.5 seconds encoding, excluding timed children. The saved state was
347,243 bytes. The adaptive buffer from the earlier fix still fell back to
three complete encoding passes on many saves; end-of-run free RAM does not
describe memory available during each save.

Saving now streams the state once, in chunks of at most 4 KiB, directly to the
temporary file. It checks write/flush results, then rotates the backup and renames
the temporary file. The sizing/buffering pass and full readback verification are
removed. Space is checked as chunks arrive; a failed write leaves the primary
in place. There is no immediate detection of silent disk corruption; normal load
parsing and backup fallback remain. This is the simpler save policy appropriate
for this game script.

State tables no longer sort every key, and small strings/field names take fewer
Lua calls to emit. Bee identity encoding remains deterministic and unchanged.
Saved files remain compatible with the existing reader, including binary NBT.
Watchdog yields and keyboard handling at completed saves remain in place.

A local Lua 5.2 fixture containing 64 completed receipts and 16 catalogue entries
(359,852 encoded bytes) dropped from three serialization passes and 92 reads to
one pass and zero reads. A debug instruction counter dropped from approximately
1,246,000 to 197,000 instructions (84%); local CPU time was about 58 ms versus
22 ms. These are synthetic measurements, not predicted Minecraft timings. Rerun
`Beeomatic benchmark` in game to measure the new total; breeding and analysis
still contribute their own waits.

## Earlier server profile diagnosis (20 October 2026)

The supplied 605.4-second run spent 563.3 seconds in 137 state checkpoints
(93% of elapsed time). Measuring encoded size cost 214.1 seconds; encoding
consumed 320.15 seconds excluding nested I/O. The 12 transposer transfers
themselves took 0.6 seconds combined. The state was 339,453 bytes and the report
showed 1,360,217 bytes of free RAM. Scheduler steps reached 109.6 seconds,
delaying the old end-of-step keyboard check.

The initial fix counted bytes while encoding and retained the encoded chunks when
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

Standalone `cancel` subsequently exposed a watchdog timeout during checkpoint
verification. Saves now yield before encoding and at chunk boundaries when
0.5 seconds have elapsed, including writing and exact readback verification.
Buffered I/O alone does not guarantee a yield. The wait is 0.05 seconds because
some OpenOS versions have a [zero-sleep yielding bug](https://github.com/MightyPirates/OpenComputers/pull/3779).
During foreground saves, keyboard requests received in these waits are retained
and acted on after atomic replacement. A simulated watchdog tests both buffered
and streaming saves; standalone cancellation and quit-during-save tests cover
the command paths.

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

For a complete automatic sample, use `Beeomatic benchmark`. It profiles stock
preparation, selects a matching homozygous princess/drone pair, breeds exactly
one cycle, and scans the collected offspring back into storage before exiting.
It uses the normal journal and scanner recovery paths. It requires configured
automated scanning and no unfinished jobs; species, population targets, template
imprinting and confirmation-cycle counts do not extend this single-cycle test.
The queen's lifespan and scanner processing time remain part of elapsed time.
Read the result using `Beeomatic logs --profile --no-pager`.

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

- Durable checkpoints still serialize the complete saved state once. Their
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
- The scanner now verifies analysed batches in a dedicated output chest and
  deposits them into ME. Return detection no longer snapshots the ME network
  or requests returned variants for another physical inspection.
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
