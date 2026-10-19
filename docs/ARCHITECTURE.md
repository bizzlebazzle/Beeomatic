# Architecture and safety boundaries

`Beeomatic.lua` locates its own installation and loads `lib/cli.lua`. The CLI owns
the foreground loop and mailbox; its services receive injected components, clock,
storage and persistence so the same logic runs under Lua 5.2 mocks.

| Modules | Responsibility |
|---|---|
| `components`, `ui/diagnostics`, `setup`, `config` | Enumerate every address, inspect methods/inventories, collect verified configuration |
| `bees`, `genetics` | Caste/genome normalization, purity, desired traits, exact identity, separate full equivalence |
| `mutations`, `planner` | Runtime routes, aliases, cycle-bounded dependency expansion, inventory/climate/requirements/probability costs |
| `inventory`, `persistence` | Source leases, write-ahead movement intent, verified receipts, two-generation state replacement |
| `storage/chest`, `storage/ae2` | Reachable physical inventories, exact NBT database selection, isolated export, network reconciliation |
| `breeders/alveary`, `breeders/routed`, `breeders/factory` | Native or gated-staging hardware lifecycle behind one interface |
| `jobs`, `scheduler` | Dependencies, fair dispatch, exclusive machine allocation, replenishment/conversion, bounded cycles, lineage protection |
| `scanner`, `templates`, `robot` | Isolated scanning provenance, reference-drone crossing, addressed condition-specific requests |
| `ui/status` | Persisted runtime status; no fabricated inventory/climate measurements |

The scheduler rotates its starting job on each tick. Independent dependencies can
run concurrently up to `concurrency`. Each machine has at most one job, and each
source selection is reserved before movement. Transfers execute serially in the
single worker: after a verified withdrawal, the remaining stack is a fresh pool of
unallocated units, so two jobs can safely use distinct drones from the same stack.
An active job's princess lineage remains protected between cycles. Machine leases
and unresolved movements survive interruption.

State transitions:

```text
WAITING -> PREPARING -> RUNNING -> COLLECTING -> ASSESSING -> WAITING / DONE
             |           |           |            |
             +-----------+-----------+------------+--> PAUSED
```

Before insertion the worker checks route conditions, the actual parents' active
genomes and a free verified machine. Both species alleles affect progress/purity.
Every subsequent cycle checks the actual next princess again. Directional climate
tolerances are respected. Future offspring cannot be assumed to inherit identical
climate genes; an incompatible next generation remains archived and pauses that
operation until a suitable machine exists.

The native lifecycle requires no housing/input queen or drone plus a princess AND
drones in the configured output slots. Empty input alone is never enough. The
routed lifecycle also accounts for staging occupancy and bounded pipe transit.
Forestry's `canBreed()` is general workability, not proof of every mutation rule.

Collection archives all products/offspring, merging only matching exposed exact
identities where an entire receipt fits. It never discards the last useful stock.
If new genomes are unavailable, scanning occurs one isolated stack at a time.
Assessment uses the job's own collected results. Consecutive stable offspring
cycles are required (`confirmCycles=2` by default), as are pure target princesses,
pure compatible drones and minimum stock. `fullEquivalence` additionally requires
all exposed chromosomes to agree across both active/inactive genomes of the pair.
Template criteria apply independently to non-species genes.

The planner can use existing drones to schedule spare-princess conversion and can
request population helpers before a parent is consumed. One pure princess per
species and useful drone reserves are protected by default. Fertility <= 1 cannot
produce net drone growth and is diagnosed. Useful hybrids are scored above
non-target stock; lost mutations recover using the protected lineage and available
parent/reserve drones without recursion. Every job has a finite cycle budget.

Each transfer writes source identity/count, destination identity/count, requested
quantity, owner and sequence before invoking hardware. Receipt verification checks
the actual source delta, destination delta and returned transfer count. A queen
transition can specifically witness final drone insertion. Known failed, committed
and partial transfers can be reconciled from physical evidence. Ambiguous movements
block further transfers and are never blindly replayed. Collector receipts are
saved individually; a receipt committed immediately before a crash is reconstructed
from the journal sequence. Scanner NBT changes use isolated provenance and stable
return locations, rather than pretending pre/post-analysis NBT is identical.

State uses data-only Lua tables with an empty load environment. A temporary file
is read back, the old primary is renamed to `.bak`, and the temporary generation
is renamed into place. A readable backup is used if the primary is damaged. This
does not claim filesystem-level `fsync`, which OpenOS does not expose here. Preserve
both generations when investigating a power-loss recovery.

Config and hardware-dependent facts remain separate from job state. The inspected
GTNH APIs do not expose live operating climate/flowers/biome or comprehensive
machine-readable mutation constraints. These facts require explicit in-game
attestation and must be revoked when the physical installation changes. The
program cannot prove arbitrary natural-language conditions or guarantee real
machine behavior without the acceptance tests in `VALIDATION.md`.
