# Validation and in-game acceptance

Target: GTNH **2.9.0 Beta 3**, OpenComputers **1.12.61-GTNH**, Forestry **4.11.37**,
AE2 **rv3-beta-1050-GTNH**, Gendustry **1.9.13-GTNH**. The source contracts are
recorded in [API compatibility](API_COMPATIBILITY.md). **No Minecraft runtime is
attached to this development workspace. The new Interface/scanner application
flow still requires in-game acceptance.**

## Automated checks

Current result: **428 tests, zero failures on each of Lua 5.2 and Lua 5.3**.
Run `python tests/run.py` in the development workspace. It syntax-checks every
project Lua file, then runs the suite on both engines using local Lupa runtimes.
Alternatively run `lua tests/run.lua` with a compatible runtime. These dependencies
stay on the development PC and are not installed on the OpenComputer.

Buffered journal reads yield periodically during parsing, including skipped legacy
payloads, backup recovery and separate catalogues. A simulated watchdog exercises
the public `status` and `cancel` commands with reads that never yield themselves;
status preserves the saved files and cancellation retains unresolved receipts.
Small control reads do not sleep or consume foreground keys.

Resource checks run in fresh VMs with a hard **2 MiB allocator ceiling** and
384 KiB reserved to represent host overhead. Both an absent `collectgarbage` and
a host wrapper that throws are tested; neither is required for resume. Worker
modules must load before the large journal is opened. Tests model OpenOS module loading
(chunks plus a concatenated source buffer), load a roughly 1.96 MB legacy journal,
and run the public ME `resume` path through recovery, checkpoints and a stock wait,
plus the immediate `cancel` path.
The same legacy fixture fails when full completed-receipt stacks are retained.
Obsolete completed-receipt payloads are skipped without constructing their tables
during decoding, while pending transfer/scanner
records retain their recovery data. Completed Interface receipts also drop
identities that are no longer used. The resulting checkpoint is roughly 22 KB
after resume prunes the absent catalogue, or 21 KB plus a 241 KB catalogue when
cancel retains it. The fixture reloads both files and saves again under the same
limits, checking that catalogue entries survive the split.
The compact startup/recovery cases also retain a filled 128 KiB NBT cache.
Its fixture stops once the cache is full, without further setup-only decompression
churn. Worker code loads before the storage backend to limit source-buffer overlap.
Profiled Lua 5.3 startup was also repeated three times in each missing/disabled
manual-collection mode under the same ceiling.

Every checkpoint write in this fixture is also checked against a **4 MiB disk
ceiling**, including the previous state, temporary checkpoint, two generations
of installed code and 256 KiB of other disk use. An oversized old backup is
reclaimed only when a known good primary remains. Saves encode once and check
space incrementally without readback or a document-sized RAM buffer. Write/flush
failures preserve the primary; an unverified primary's backup is also preserved.
These are deterministic mocked hardware workloads, not a guarantee that arbitrary
stock/journal sizes fit, and in-game acceptance on the actual computer is still required.

The encoding cache is also exercised by two successive 339 KB binary-string
checkpoints and reload in a 2 MiB VM with 384 KiB host reserve. That fixture fills
the cache's 256 KiB accounting budget alongside a filled 128 KiB NBT cache.
Loading releases the encoded pieces before parsing; the fixture also disables
manual collection. Unit checks cover eviction,
exact binary output, changed identities/tables, persistent-store reuse, cache
release on load with counters preserved, and profile counters.

Catalogue persistence checks cover inline migration, unchanged replacement
genomes, additions, changed genes, pruning, restart without another catalogue
write, backup recovery, and write failure before either file is replaced. The
CLI benchmark checks that the separate catalogue exists and is profiled while
the state omits its inline copy. Both files share one bounded encoding cache.

NBT cache checks cover repeated access to 80 tags without another decompression,
the 128-entry and 128 KiB bounds, entry overhead accounting, eviction/reload,
unchanged canonical bytes, failed decodes, and counters relative to command start.
Generated resource fixtures stay on the development PC. Run
`python tests/benchmark_nbt.py [state.lua-or-catalogue.lua]` for the separate CPU
and reuse comparison; actual game tags still need the next benchmark profile.

Polling checks cover deferred background scans with fresh active observations,
unfinished dependencies, ready jobs bypassing the deadline, and collection and
assessment while two alvearies are breeding. External raw bees still enter the
scanner on the background refresh. Idle display reuse is checked separately from
active observations, new assignment, manual/terminal refresh and uptime reset.

Checkpoint checks inspect the full known-catalogue CLI benchmark's saved intent
before each of its eight transfers and enforce 58 state checkpoints. Scanner
phase checks retain returned counts and committed receipts while combining saves.
Reload tests cover scanner insertion intent, verified output before transfer,
interrupted consumed-port cleanup and collection before result locations were
saved, for both chest and Interface storage. Existing ambiguous Interface intents
still stop without replay; no new automatic recovery rule is introduced.

Interface coverage includes:

- Exact NBT selection among same-label variants and bounded requested quantities.
- Automatic source refill, return drain before readback, full/offline storage,
  interrupted requests, proven partial acceptance, and crash recovery with/without
  sufficient acceptance proof.
- Startup inspection of already-analysed bees without spending analysis supplies,
  all units across multiple raw drone batches, missing scanner, new external raw
  variants, initial housing leftovers and untracked chest slots.
- One shared scanner, analysis changing NBT, quantity ownership through merged
  stacks and two independent alvearies retaining their own offspring.
- Restart immediately after accepted scanner input and after committed return;
  collection recovery after the bounded physical history has expired.
- The public CLI through saved configuration/state, foreground events and initial
  drone preparation, breeding, offspring scanning and completion.
- Fresh Interface-first setup, both scanner chests on the same transposer,
  automatic input slots, `back`, resumed registration and port pruning.
- Automatic IDs surviving setup interruption, shared Interface ID reuse,
  mismatched Interface connection rejection, and optional setup without robot configuration.
  Climate entries require no separate environment confirmation.
- An incorrect scanner Interface inventory reports its actual size/transposer/side
  and allows reselection before asking for the Interface adapter.
- Input/output scanner chests: one AE request per raw batch, physical verification
  before deposit, split deliveries, owned batch splits and existing-stock merges,
  rejected raw/wrong-species/wrong-caste/excess/contaminated outputs, immediate
  input extraction, preserved timeout progress, partial deposit recovery and
  restart before output transfer and after committed return. Unrelated changes
  in ME cannot satisfy or contaminate chest returns. Retired layouts are rejected.
  The public CLI completes startup and breeding through this topology.
- Plain `setup` resumes completed retired configurations at scanner registration,
  preserving alvearies and the saved checkpoint on interruption. Current layouts
  keep their completed checkpoint. Migration refuses unresolved movements, scanner
  batches, Interface requests, owned batches and active jobs before changing config.
- Automatic native alveary input/output maps and retryable placement checks:
  empty slots, wrong caste and mismatched housing adapters. Unanalysed test bees
  are accepted for placement without weakening the runtime analysis gate.
- The Interface doctor probe and refusal to migrate unresolved saved work.
- Setup omits biome/dimension/flower questions. Missing or old flower lists do not
  block scheduling. Live status shows separate resident bee flower requirements,
  labels unknown raw-bee requirements, isolates missing housings and does not
  rewrite worker state or move items during a status query.
- Day/night, lighting, rain-shield and sky-access questions are omitted. Missing
  or false old daylight/rain/sky declarations do not reject otherwise compatible bees.

Cancellation tests cover queued, running, paused, partial-insertion and collecting
jobs; manually removed queens; missing flowers; broken databases and storage;
`cancel`/`stop` mailbox requests; the `q` key; cancellation during Interface waits;
retained physical receipts and inserted scanner batches; routing gate shutdown;
repeatable cancellation and fresh-request recovery. Cancellation never waits for
queen completion or opens a worker screen when invoked at the shell.
Cancelled-work cleanup tests return only the existing scanner batch, refund a
proven untouched insertion without replay, retain ambiguous movement/filter
evidence, reject active work/worker locks and permit subsequent reconfiguration.
Manual scanner recovery checks empty input/output buffers without inventing
genomes or fetching AE stock, refuses occupied/unavailable buffers and preserves
ambiguous transfer evidence. Repeated cleanup waits print once; interruption
retains the batch. Output-count progress stays routine while timeouts stay visible.

Cross-climate conversion tests cover Wintry Icy/UP_1 princesses with Attuned and
Cultivated Normal/NONE drones, queen genome retention, and redispatch to Normal
after observing Normal offspring genes.

Population tests plan and grow one pure Steadfast princess/drone pair to at least
32 drones through the public CLI, including resume of a saved pending request.
Scheduler recovery continues below the configured drone reserve; fertility-one
princesses pause without movement. Protected/other-job stock, hybrids, conversion
and mutation parents retain their reserve checks.

Existing checks also cover route planning, purity/templates, climate/tolerances,
reserves, chest transfers, gated routing, legacy export recovery, persistence,
callable OC proxy tables, component discovery, installation/download revision
consistency and failure preservation. Installation tests verify retired files
receive `.previous` backups while user state and unrelated files remain intact.
The mocked downloader still exercises a 512 KiB hard drive and 1 KiB `/tmp`.

## New Interface acceptance

1. Stop the worker, back up `data/`, install/update and reboot to clear cached Lua
   modules. Build the [hardware topology](HARDWARE.md), run setup and doctor.
2. Verify every saved Interface adapter corresponds to the transposer's chosen
   physical inventory. Remove fuzzy/crafting upgrades and unrelated filters;
   exclude other automation from reserved bees. Verify AE channels, power and
   cell capacity. Do not attach storage buses to these ports.
3. With at least two identical analysed drones in ME, run
   `Beeomatic doctor --interface PORT_ID` for each port, including the scanner.
   Observe the two-unit request, one-unit extraction, stock cleanup, return and
   unchanged final exact ME count. Repeat with same-label genetic variants.
4. Empty the scanner path of bees. Verify the transposer touches the relocated
   Interface and both chests on different sides. Pipes feed the scanner from the
   input chest and deliver only analysed outputs to the output chest. No other
   automation or AE bus may extract from/expose these chests. Supply honey/power.
   Observe the full returned stack being verified in the output chest, transferred
   to the Interface and catalogued without another AE request. Repeat with stock
   of that analysed variant already in ME to exercise ownership through merging.
5. Put analysed and unanalysed drones in ME, including more than one stack and
   different same-label variants. Start a small job. Confirm `PREPARING_STOCK`
   remains active until every initial drone is analysed, and no alveary receives
   parents early. Already-analysed variants should only need physical inspection.
6. Run two alvearies with a shared drone genotype. Observe distinct requested
   units, correctly assigned parents, combs returning directly to ME, and raw
   offspring passing through the one scanner before becoming usable. Confirm
   founder/template reserves and each job's princess lineage remain protected.
7. Exercise full ME storage, missing honey/power and slow stock delivery with
   expendable bees. Confirm accepted stock remains in the journal/local buffer
   and unaccepted outputs remain in the housing. Repair and resume.
8. Interrupt at stock receipt, parent insertion, scanner input and scanner return.
   Stop any old worker, then use `resume --recover`. Confirm no duplicate insertion
   or lost ownership. Ambiguous outcomes must pause for audit. Use doctor adoption
   only after checking the real matching queen/offspring pair.
9. Confirm interrupted setup resumes, `back` revisits the expected stage, and adding
   an alveary does not repeat the shared storage/scanner registration.

## Previous manual evidence

Earlier tests on the user's server confirmed exact database NBT copying and
physical bee genetics, the broken `exportIntoSlot` callback, normal redstone export,
buffer-to-archive transfer and a storage bus exposing that archive in ME. Those
results concern the retained [legacy backend](LEGACY_AE2.md), not this Interface flow.

The nine-slot alveary was manually observed with princess/queen in slot 1, drone
in slot 2, and products/offspring in slots 3-5. A princess insertion was witnessed,
a queen formed after drone insertion, and one complete cycle's combs/drones/princess
were extracted. Slots 6-9 remain individually unverified. Component type `items`
was observed; registration correctly relies on methods rather than type names.
The full application and revised wizard still require the acceptance steps above.
