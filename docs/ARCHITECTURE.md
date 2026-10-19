# Architecture and recovery

`Beeomatic.lua` loads `lib/cli.lua` from its installed root. The foreground worker
owns component access, scheduling, mailbox control and persistence. Services
accept injected components/clocks so they can be exercised under Lua 5.2/5.3.

| Modules | Responsibility |
| --- | --- |
| `components`, `setup`, `config`, `ui/diagnostics` | Capability discovery, resumable registration and hardware checks |
| `bees`, `genetics`, `mutations`, `planner` | Exact identity, chromosomes, runtime routes and bounded prerequisite planning |
| `inventory`, `storage/receipts`, `persistence` | Physical transfer intents/receipts, logical batch updates and saved generations |
| `storage/me_interface` | Per-port exact quantity requests, refill cleanup, returns, network catalogue and probe |
| `scanner`, `scanner_me` | Chest scanner compatibility and shared ME inspection/analysis state machine |
| `jobs`, `scheduler`, `templates` | Fair dispatch, exclusive machines, quantity ownership, lineage and genotype reserves |
| `breeders/alveary`, `breeders/routed`, `breeders/factory` | Direct inventory or isolated gated routes |
| `storage/chest` | Optional standalone chest mode |
| `storage/ae2`, `storage/ae2_export` | Compatibility for saved legacy export-bus configurations |

## Startup and scanning

On every worker start/resume, Interface mode closes the dispatch gate and enters
`PREPARING_STOCK`. Recovery inspects pending movement first. Unknown variants are
materialised at the shared scanner port to read physical genetics. An analysed
item whose ME conversion omits genomes is catalogued by exact NBT and returned
without analysis. Unanalysed items go through the isolated analyser in bounded
stack-sized batches. Readiness requires analysed initial drone stock, no unresolved
batch and no untracked bees in registered analyser inventories. Initial raw drones
in idle housing outputs are collected; active jobs keep ownership of their results.

Shared scanner phases:

```text
REQUESTING -> INSPECTED -> return/rescan
     |
     +-> INSERTING -> PROCESSING -> RETURNING -> rescan
```

Input acceptance and output return update scanner phase evidence in the same save
as the transfer receipt. Restart after either boundary does not repeat the move.
Analysis changes NBT; an explicit identity mapping preserves owned quantities.
During operation, new raw offspring and external unknown variants are quarantined
until inspection/analysis. Existing queens can keep running while the scanner is
busy; new dispatch waits. A missing scanner or uncertain batch blocks readiness.

## ME ownership and scheduler

A single worker serialises physical transfers; independent cycles run concurrently.
Network stock is grouped by full item identity. Port-local stock is also inspected;
ports must not have storage buses exposing them again. `meBatches` allocates exact
quantities to collection receipts and job owners, leaving the remainder available.
Each Interface has its own unique inventory/component identity. Stocked buffers
are transient and never used as permanent lineage locations.

```text
WAITING -> PREPARING -> RUNNING -> COLLECTING -> ASSESSING -> WAITING / DONE
             |           |           |            |
             +-----------+-----------+------------+--> PAUSED
```

Each job assesses only its own receipt roots, even when identical offspring merge
in ME or analysis splits/transforms a batch. The chosen princess batch stays owned
between cycles. Committed insertion spends only selected units; logical source
leases are then released so another job can use other drones in the same stack.
Drone/template reserves are exact-genotype quantities. Completed jobs and explicit
fully drained stops release their remaining batch ownership without discarding bees.

## Transfers and restart

Ordinary inventories retain strict source/destination delta checks. An Interface
can refill a source or drain a destination before readback, so managed operations
also use the returned transfer count and a persisted acceptance receipt. Intent is
saved before configuring stock or moving items; the callback result is saved before
subsequent reads. The receipt's ownership/analysis updates commit with the journal.
A queen transition can witness the final drone insertion.

A source refilling is not evidence of failure, and an empty return slot is not
proof by itself that a deposit succeeded. Recovery uses durable callback receipts
and remaining physical evidence. Proven partial acceptance records only the accepted quantity; the scanner
finishes that smaller batch and later processes the remainder. Missing proof or
mixed uncertain outcomes
pause for audit instead of replay. No atomicity across Lua disk writes and Minecraft
is claimed. Collector receipts can be reconstructed after a crash; logical batch
records survive the bounded physical transaction history.

Requests remain journalled through configuration, receipt and refill return.
An interruption keeps a bounded stock request for recovery. Consumed requests and
orphan probe requests are cleared during reconciliation; unfinished parent requests
remain associated with the interrupted job. `doctor --adopt`/`--retry` provide
explicit recovery after checking the actual machine. Reconfiguration is blocked
while transfers, scanner batches, stock requests or owned work remain unresolved.

Persistence uses data-only Lua, temporary-file readback and a `.bak` generation.
OpenOS does not provide filesystem `fsync` here. Preserve both generations when
investigating power loss. Configuration facts (climate/flowers/requirements) remain
explicit in-game attestations because the housing API does not expose them all.
