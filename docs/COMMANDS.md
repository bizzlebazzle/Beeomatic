# Commands and process control

Commands and species names are case insensitive. Use quotes around multiword
species. Full Forestry species UIDs and configured aliases are accepted.

```sh
Beeomatic setup
Beeomatic setup --reconfigure
Beeomatic doctor
Beeomatic doctor --probe
Beeomatic doctor --interface scanner_port
Beeomatic plan spirit
Beeomatic plan spirit --verbose
Beeomatic plan spirit --no-pager
Beeomatic breed spirit
Beeomatic breed spirit --noFinalImprint
Beeomatic breed spirit --onlyFinalImprint
Beeomatic convert spirit
Beeomatic populate spirit 32
Beeomatic imprint spirit
Beeomatic status
Beeomatic status --verbose
Beeomatic pause
Beeomatic pause job3
Beeomatic resume
Beeomatic resume job3
Beeomatic stop
Beeomatic cancel
Beeomatic alveary list
Beeomatic alveary add
Beeomatic alveary remove hot_dry_1
Beeomatic storage scan
Beeomatic bees list
Beeomatic bees inspect spirit
Beeomatic logs
Beeomatic logs --crash
Beeomatic help
```

`plan` reads runtime routes and actual storage. If bees lack verified genes, it asks
`Would you like to scan all unscanned bees now? [y/N]`. Answer `y` or `yes` to
inspect/analyse all those bees using the configured scanner, then plan from the
refreshed stock. Declining (or pressing Enter) plans with existing verified stock
without moving bees. Scanning does not start breeding. Scanner interruptions or
failures preserve progress; repair the scanner and rerun `plan TARGET` to continue.
Scanning requires no running worker or unfinished breeding work; use `resume`
for saved breeding work instead.

The plan starts with a summary, any condition/climate checks requiring attention,
and the species already in verified stock. Numbered recipes list prerequisites
before offspring, with each shared prerequisite included once. Chances are base
mutation percentages, not completion estimates. `[CHECK]` marks steps for which no
suitable alveary is currently confirmed; their reasons appear above the recipes.
Parent genes and spendable reserves are checked again when each step starts.

Long plans pause at terminal-sized pages. Enter or Space advances, B goes back,
and Q or Escape closes the report without starting breeding. Enter closes the
last page. `--verbose` includes candidate alveary IDs and the full species UID
mapping; `--no-pager` prints the entire report for redirection/copying. A verified
target pair is reported directly without listing unnecessary breeding steps.

Interface stocking/return checks and scanner steps default to 0.1 seconds. The
worker defaults to 0.5 seconds, including with an existing saved `pollSeconds=5`.
Set top-level `workerPollSeconds`, `storage.pollSeconds` or `scanner.pollSeconds`
to override their respective intervals (minimum 0.05 seconds). The original
`pollSeconds` remains an upper bound. Housing details refresh at most once a
second; unchanged stock-readiness and idle worker polls do not write checkpoints.
These intervals affect detection delays; analyser and pipe processing still take
their normal time, and exact returned bees are physically inspected before use.
Polling intervals are not total batch timings: component calls and durable state
writes also take time in-game. Inventory scans use `getAllStacks` snapshots when
available to avoid repeated world reads for every empty chest/Interface slot.
Components without that method retain individual reads with one size check per
scan. Transfers still read their actual source/destination before committing. Grouped slot reads
share one inventory-availability check. Component capability discovery is reused
while the component proxy is unchanged; actual item contents are read fresh.
ME requests clear only the database slots needed for their matching variants.
A single previous database entry can be reused after reading and verifying its
exact NBT again. Transfers save the reservation with the movement intent, retaining
the before-move intent, moved-count and verified-receipt checkpoints.

If no route is achievable, `plan` explains missing founders, unresolved cycles or
the distinct-species graph limit and returns to the shell without a traceback. Every breeding worker
start/resume verifies all initial drones before dispatch. `PREPARING_STOCK`
inspects unknown variants and completes required analysis at the shared station. A mutation preference is a tie-breaking
preference among runtime-confirmed routes, not a recipe assertion. Spirit's
Ethereal/Aware preference is ignored if the runtime does not return that pair.

Breeding, conversion, population and imprinting run in the **foreground**. Keep the
computer powered and chunks loaded. On-screen keys are `p` (pause), `r` (resume),
`q` (drain and stop). Ctrl+C preserves state and returns to the shell. Pausing
suspends scheduling/observation; Minecraft may continue a queen's natural lifecycle.
Resuming inspects reality before continuing. Stopping prevents new insertions and
collects active cycles when possible; a broken or explicitly paused machine still
needs recovery before its stock can be released. Never delete state to stop work.

If OpenOS provides another shell/process, `pause`, `resume`, and `stop` write
`data/control.lua`. The foreground worker reads this mailbox at its bounded polling
interval; it does not pretend a second command magically controls another process.
The running screen refreshes in place on an available OpenOS terminal. It shows
the target, completed/active/queued steps, scanner activity, and one line per busy
alveary. Idle alvearies are counted together. Species names are shortened for
readability. Routine scanner waiting is activity; actual failures appear under
`Attention`, with each alert on its own line. Parent preparation is normal work:
`Planned: Eldritch - Waiting for stable parent population`, followed by each
parent's analysed drone count/required minimum and any ongoing stable-cycle
confirmation. Counts use the latest storage snapshot and include stock held by
population helpers; breeding still respects ownership and reserve rules. Such
waits do not trigger `Needs attention`. `q` lets active work finish before stopping.

`status` uses the same compact overview. `status --verbose` includes full species
IDs, job IDs, cycle/genetics counters, resident bees and flowers, storage counts,
and recent diagnostic details. `logs` shows event history. `logs --crash` pages
through the last foreground worker traceback saved in `data/crash.log`, even if
the saved job state cannot be loaded. Use `--no-pager` to print it in full.

`status` and `logs` read the last saved snapshot. `status` additionally refreshes resident bee/flower information
from the registered housings without moving items or writing the worker's state.
A missing housing is reported independently; raw bees show unknown flowers until
analysed. Do not start two workers for the
same data directory. A persistent lock prevents ordinary duplicate starts. After a
crash, first ensure the old worker is not running, then use:

```sh
Beeomatic resume --recover
```

`resume` launches a worker when none exists; with a lock it sends a mailbox request
unless `--recover` explicitly replaces the stale lock. A blocked operation saves
its explanation and returns to OpenOS when no other machine can progress. Repair
the condition and run `resume`. Independent active operations can continue when
one machine is paused. The default maximum is two concurrent machines.

To attest special requirements reported by runtime mutations:

```sh
Beeomatic doctor --confirm hot_dry_1
```

Confirmation asks about each exact requirement string and saves only explicit
`confirmed` replies. Revoke a confirmation in the configuration if the relevant
block, biome, dimension, equipment or world condition changes. Structured route `environment` constraints
are supported by the planner/backend if supplied by an extension/configuration.

To discard a pending request before its plan has been created, exit the worker
with Ctrl+C if it is running, then use `Beeomatic cancel`. This also clears requests
stranded by the old stopped-plan replacement bug. It preserves the old drained
jobs and all scanner/transfer/ownership records; a new request reconciles those
records before breeding. It refuses cancellation while a worker lock or active
machine/job assignment remains. For an existing idle or blocked plan, `cancel`
removes its jobs and releases their logical stock ownership. Unresolved physical
transfers or Interface requests must be reconciled first. Use `stop` to drain
assigned work before cancelling. At the shell, `stop` runs the foreground worker
to complete the drain; with another worker running, it sends that worker a request.

Recovery tools for a reserved job:

```sh
Beeomatic doctor --adopt job3
Beeomatic doctor --retry job3
```

`--adopt` is an explicit operator instruction after inspecting that job's actual
queen or complete offspring pair. It continues observation/collection and does not
repeat insertion. A consumed-drone transfer can only be adopted with source-count
or a durable Interface acceptance receipt and the expected queen genome. For routed machines, the operator must
verify the real queen through the GUI because staging inventories cannot establish
caste inside the housing. `--retry` requires an empty machine, reconciled journal
and restored recorded source items in chest/legacy mode. In Interface mode it
returns unconsumed local requests to ME before reselection. Neither command discards bees.

To replan after changed stock/routes: drain existing work with `stop`, resolve any
reserved machines, and issue `breed TARGET` again. The completed stopped plan stays
in the journal until replaced. The `--noFinalImprint` and `--onlyFinalImprint` flags
affect optional reference-drone crossing only; ordinary breeding works without
templates. Full genome equivalence is configured separately from species purity
using `fullEquivalence=true` in `data/config.lua` while the worker is stopped.

Population and stability settings are also saved in `data/config.lua`. With the
worker stopped, set `minDrones=32` and `confirmCycles=3`, then run `Beeomatic resume`
to reload the configuration. These are the defaults for new setups; updating the
program preserves existing saved settings, so existing installations must edit
these values themselves. `minDrones` is the pure-species drone count required to
complete each stage, and `confirmCycles` is the number of consecutive cycles with
a qualifying stable offspring pair. An explicit `populate SPECIES COUNT` overrides
the drone threshold for that population job.
Before starting a mutation from parent stock, the scheduler checks both parent
species against `minDrones`, including base species already present in storage.
Understocked parents receive population jobs; the mutation waits for those jobs
to finish their confirmation cycles. Existing active mutation lineages continue
their recovery/stabilization rather than restarting this preparation step.

Generic princess conversion (including imprint fallback) excludes unrelated
donors with fertility <= 1 in either allele. Required recipe parents and the
requested target remain usable regardless of fertility. This uses analysed genes,
not a Rocky species blacklist. If a required species has pure princesses but none
has active fertility > 1, its automatic drone threshold becomes `reserveDrones+1`
instead of `minDrones`; exact-genotype drone reserves and confirmation cycles still
apply. Supply more drones or improve fertility when that reserve is exhausted.
An explicit population count is never reduced: an active fertility-one princess
pauses population with an explanation. Population prefers a princess with active
fertility > 1 when one is available. Already tracked breeding/conversion lineages
continue rather than discarding their progress.

`doctor --interface PORT_ID` operates on the saved local port while the worker is
stopped. It needs two identical analysed drones, requests two, transfers one into
its unconfigured return slot, clears/refunds local stock and checks that the original
exact network count returns. `doctor --probe` remains the read-only capability dump.
Use `setup --reconfigure` only after old work is finished or fully drained and
journals are reconciled. Setup offers `me`/`chest`; existing export-bus configurations
remain supported for recovery without exposing old export questions in new setup.
