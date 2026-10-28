# Commands and process control

Commands and species names are case insensitive. Multiword species work with or
without quotes: `Beeomatic plan end dust` and `Beeomatic plan "End Dust"` are
equivalent. For `populate`, put the count last: `Beeomatic populate end dust 32`.
Full Forestry species UIDs and configured aliases are accepted.

`populate` requires a drone count (a whole number from 1 to 1000000). For example,
use `Beeomatic populate water 32` or `Beeomatic populate monastic 32` to build
drone stock. Omitting the count displays the command syntax without starting work.

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
Beeomatic benchmark
Beeomatic status
Beeomatic status --verbose
Beeomatic pause
Beeomatic pause job3
Beeomatic resume
Beeomatic resume --profile
Beeomatic resume job3
Beeomatic stop
Beeomatic cancel
Beeomatic alveary list
Beeomatic alveary add
Beeomatic alveary rename alveary_2 "Cold room"
Beeomatic alveary configure alveary_2
Beeomatic alveary remove hot_dry_1
Beeomatic storage scan
Beeomatic bees list
Beeomatic bees inspect spirit
Beeomatic logs
Beeomatic logs --crash
Beeomatic logs --profile
Beeomatic logs --profile --no-pager
Beeomatic help
```

`Beeomatic benchmark` enables profiling automatically and selects an analyzed
princess and drone with identical active and inactive genes, compatible with a
registered housing. It breeds exactly one cycle, collects and analyzes the
offspring, returns them to storage, then exits. An automated scanner is required.
Stock inspection and any initial analysis run automatically and are included in
the report. Templates are protected; the selected pair may use its last drone
because this is a single same-genome cycle. No species is hard-coded or required.
Existing unfinished work must be completed or cancelled first. Missing suitable
stock or a blocked machine pauses the benchmark with a diagnostic. After Ctrl+C
or a repair, `Beeomatic resume --profile` continues the saved benchmark.
Read the completed report with `Beeomatic logs --profile --no-pager`.

For performance diagnosis, stop an existing worker with Ctrl+C, then run
`Beeomatic resume --profile`. New breed/convert/populate/imprint commands and
`plan` also accept `--profile`. Let it complete several slow movements, stop with
Ctrl+C, and read `Beeomatic logs --profile --no-pager`. Profiling applies to that
invocation only; a later `resume` runs normally. The latest run replaces
`data/profile.log`; copy it before profiling another run. See
[profiling details](PERFORMANCE.md#in-game-profiling) for interpreting the report.

`alveary list` shows IDs, friendly names, saved climates, priorities and disabled
registrations. `alveary rename ID NAME` changes a friendly name without changing
its stable ID or connections. `alveary configure ID` (also `edit ID`) prompts for
name, temperature, humidity, scheduling priority and enabled status; Enter keeps
current values. It saves only after all answers are complete. Exit the worker
before editing; configuration changes require the selected machine to have no
assigned job. Change heaters/fans in-world first: the command records the resulting
climate, rather than controlling those blocks. Changing climate clears that
alveary's mutation-condition confirmations; verify them again with `doctor --confirm ID`.
Then use `resume` to retry blocked jobs.

Temperature tolerance is directional: `ICY` with `UP_1` accepts `ICY` and `COLD`,
but not `NORMAL`. The queen retains the selected princess's genome; the drone's
genome is stored separately for offspring inheritance. Beeomatic therefore checks
only the princess's active temperature/humidity genes for the current cycle.
A Wintry Icy/UP_1 princess can run at Cold with an Attuned or Cultivated Normal/NONE
drone. Each collected offspring princess is analysed and checked again before
her next cycle, so an inherited Normal requirement can select a different alveary.

Compatibility messages name the selected parents, then list rejected alvearies
with their configured climates and the princess's allowed range. A `convert` job
names the princess species being recovered; its selected donor princess can be
another species. Mutation-specific environment conditions still apply separately.
Changing a registration alone cannot change the physical climate or the bees' genes.

Drone shortage messages report analysed target drones available to the job, the
largest group with identical stored identity, and the number needed to breed while
retaining `reserveDrones` (default 1). Nine different single variants cannot supply
one another's reserves, even when all carry the target species. When target stock
cannot supply a usable pairing, the worker tries the species' runtime mutation
recipes, adds any missing prerequisite jobs, and breeds/stabilizes the target up
to its normal drone minimum (32 by default). This also works for saved conversion
jobs on `resume`; existing dependencies, princess lineages and reserves are retained.
The dashboard identifies this as planned rebreeding. Fresh plans only select
conversion when one unprotected identical drone group exceeds the reserve.

If automatic rebreeding is unavailable, the message includes the reason (for
example missing founders or no reported recipe). Supply those prerequisites, or
add matching drones to reach `reserveDrones+1` in one group, then `Beeomatic resume`.
Protected reference drones are counted separately; other jobs' reserved stock is
excluded. Hybrids carrying the target in either species allele count as candidates.

`populate SPECIES COUNT` can start with just one pure target princess and one
pure target drone, even below `reserveDrones`. It breeds that pair repeatedly to
reach the requested stock and stable-cycle requirement; no mutation recipe is
needed. A princess with active fertility <= 1 pauses before insertion. Protected
reference stock and other jobs' reservations remain excluded, and hybrid crosses,
conversion and mutation parents still require spendable drones above the reserve.
Housing climate and readiness checks still apply.

`plan` reads runtime routes and actual storage. If bees lack verified genes, it asks
`Would you like to scan all unscanned bees now? [y/N]`. Answer `y` or `yes` to
inspect/analyse all those bees using the configured scanner, then plan from the
refreshed stock. Declining (or pressing Enter) plans with existing verified stock
without moving bees. Scanning does not start breeding. Scanner interruptions or
failures preserve progress; repair the scanner and rerun `plan TARGET` to continue.
Scanning requires no running worker or unfinished breeding work; use `resume`
for saved breeding work instead.

`plan` follows mutation recipes recursively back to verified stock, including all
intermediate species. A missing species is not a blocker if its parents can be
bred from your stock. If a prerequisite has no reported mutation recipe, the
failure report names it and shows its verified pure princess/drone counts. These
founders may need to come from hives, trades or other external sources. For
example, Forestry's Monastic bee is obtained from Apiarist villagers rather than
a mutation. Supply a pure pair, or more pure drones than `reserveDrones` so the
planner can include a princess conversion. Then rerun the original target plan.

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
`Beeomatic doctor --nbt` diagnoses a persistent database identity failure without
moving bees or rewriting saved progress. Stop the worker first. It checks the
saved scanner selection (or a network bee when no scanner selection exists),
rebuilds only its scratch database entries, and reports missing entries, field
types, NBT lengths, byte differences and repeated-read stability. It also checks
complete decoded NBT and names the first changed field when values differ. Share that
output before changing hardware or disabling identity checks. It does not run
the usual doctor's transfer reconciliation.

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
`q` (cancel all work immediately). Ctrl+C preserves state and returns to the shell. Pausing
suspends scheduling/observation; Minecraft may continue a queen's natural lifecycle.
Resuming inspects reality before continuing. `Beeomatic cancel` discards the
whole process, including running, paused and broken assignments, without waiting
for queens to finish. `stop` is an alias for the same action. Bees already in
housings or scanner paths remain there; Minecraft may continue their natural
processing. Dedicated routing gates are switched off and saved Interface stock
filters are cleared when reachable; filters needed to prove an unresolved
transfer are retained until reconciliation. Never delete state to cancel work.

If OpenOS provides another shell/process, `pause`, `resume`, and `cancel` write
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
waits do not trigger `Needs attention`. `q` cancels at the next safe worker point.

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

The compact status lists each unconfirmed requirement once with a confirmation
command for one affected alveary. `Beeomatic status --verbose` retains the full
per-alveary conditions, climate and selected-parent diagnostics.

```sh
Beeomatic doctor --confirm hot_dry_1
```

Confirmation asks about each exact requirement string and saves only explicit
`confirmed` replies. Revoke a confirmation in the configuration if the relevant
block, biome, dimension, equipment or world condition changes. Structured route `environment` constraints
are supported by the planner/backend if supplied by an extension/configuration.

To abandon the entire process, use one command:

```sh
Beeomatic cancel
```

It removes all queued jobs, paused/running assignments and the pending breeding
request, even if a queen was removed manually, flowers are missing, or the scanner
or database is broken. It does not launch the working screen or require `stop`
first. `stop` and the foreground `q` key perform the same cancellation. If another
worker is running, `cancel` sends it a mailbox request; it exits at its next safe
point, including during an Interface wait. No in-flight transfer is replayed by
cancellation.

`status` then says `Cancelled` with no saved work. `resume` cannot restart the old
plan; issue a new breeding request when ready. Bees already inserted are left in
place; manually empty occupied housings before reusing them. Unresolved transfer
receipts and already-inserted scanner batches remain recorded but inactive. A new
request reconciles those physical records before planning fresh work, without
resuming the cancelled jobs. Unstarted scanner fetches are discarded immediately.

Before changing storage or scanner wiring after cancellation, run:

```sh
Beeomatic doctor --cleanup
Beeomatic setup --reconfigure
```

Keep the current hardware connected during cleanup. It reconciles recorded
transfers, clears cancelled Interface requests, waits for an already-inserted
scanner batch to finish and returns it using the saved configuration. It never
starts another batch or breeding cycle. Ctrl+C interrupts cleanup with recovery
records preserved; rerun it after fixing scanner power/honey or ME capacity.
Ambiguous movements still require the physical audit described in troubleshooting.

If you already removed or manually analysed the cancelled scanner bees and
returned them to storage, empty the scanner, both chests and connecting pipes of
bees, then run `Beeomatic doctor --cleanup --scanner-cleared`. This flag confirms
your manual recovery, verifies the saved input/output inventories contain no
bees, and clears the stale scanner record without assuming a successful scan.
Unresolved transfer journals still need reconciliation. Cleanup identifies the
recorded batch and reports output counts only when they change.

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

To replan after changed stock/routes: use `cancel`, empty any occupied housings,
and issue `breed TARGET` again. The cancelled plan is removed immediately. The `--noFinalImprint` and `--onlyFinalImprint` flags
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
Use `setup --reconfigure` only after old work is finished or cancelled and
journals are reconciled (`doctor --cleanup` after cancellation). Setup offers `me`/`chest`; existing export-bus configurations
remain supported for recovery without exposing old export questions in new setup.
