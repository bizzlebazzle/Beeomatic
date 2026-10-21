# Troubleshooting and recovery

Always preserve `data/config.lua`, `data/state.lua` and their `.bak` files. Do not
delete bees or the journal to make a warning disappear. Stop other workers before
changing configuration or moving stock involved in a pending transfer.

`Beeomatic logs` reads the saved job-event history from `data/state.lua`. Older
versions did not save uncaught worker tracebacks there. Updated workers save the
latest foreground crash to `data/crash.log` and print the original error briefly.
Run `Beeomatic logs --crash` to read that report with terminal paging (Enter/Space
for next page, B for back, Q to close). `--no-pager` prints the full report.
This command works even when saved configuration/state cannot be loaded. A crash
from before this change cannot be recovered retroactively from this file; reproduce
it after updating. Failures before the worker starts are outside this crash capture.

If a worker crash reports `lib/jobs.lua: Existing work is preserved` while
creating a plan, older startup code cleared the stopped flag before replacing a
drained plan with its already accepted pending request. Update and run
`Beeomatic resume`; the corrected startup continues the pending request without
resuming the old plan. Existing machine assignments still block replacement and
require recovery. No manual state-file edits are needed.

| Report | Action |
|---|---|
| Complex `plan` targets fail with `too long without yielding` after scanning completes | The old planner scanned the full inventory repeatedly and compared unrelated princess/drone pairs without yielding to OpenOS. The corrected planner caches verified parent stock, checks relevant pairs and periodically yields during search and stock checks. Reboot after updating and retry `Beeomatic plan spirit`; keep your existing configuration and scanned bee data. |
| Complex `plan` targets report `mutation search budget exceeded; provide prerequisite stock` | The old recursive search counted repeated visits to shared ancestors, so even a small achievable graph could exhaust 20,000 expansions. The corrected search discovers each species once and builds the cheapest achievable routes from verified stock, including alternate routes out of dependency cycles. Spare drones above the reserve can seed princess conversion even for species with mutation recipes. Update, reboot and replan with the same scanned data. `maxPlanExpansion` now limits distinct species inspected (20,000 by default); a genuine graph limit is reported separately from missing stock. |
| After updating, `resume` says `Both state generations are unreadable` | The first streaming loader called file reads inside Lua's non-yieldable `load()` callback. OpenComputers filesystem calls may yield, causing valid files to be rejected. The corrected loader parses saved table data incrementally in Lua and reads binary bytes; it accepts both legacy and chunk-written state. Preserve the primary/backup files, install the loader fix and reboot before retrying. If loading still fails, the new `Cannot load saved data; files preserved` report includes the underlying error for each path. Do not delete state or reset jobs on the strength of the old generic message. |
| Scanning pauses with `lib/util.lua: ... not enough memory for buffer allocation` | This is a Lua/computer memory allocation failure during serialization, not a full Interface or analyser buffer. The corrected saver writes and verifies chunks of at most 4 KiB instead of constructing a giant state string and loading another state copy. It also loads older state files incrementally. Scanning retains only the current caste's return baseline and drops obsolete cached genomes while preserving active request/batch references. Stop Beeomatic before installing the fix; retain `data/` and its backups, then rerun `Beeomatic plan TARGET` and accept scanning to continue. A constrained Lua test saves/verifies/reloads 1,600 synthetic records within 2 MiB on Lua 5.2 and 5.3; this does not certify every in-game inventory size. |
| `plan` reports a missing prerequisite with no mutation recipe | The planner follows all intermediate recipes back to verified stock. The report uses readable species names and shows pure princess/drone counts for unresolved species with no reported recipe. Obtain these founders externally (hives, trades, etc.), or supply pure drones above `reserveDrones` for princess conversion. Monastic is a villager-trade founder in Forestry. If stock is present but unverified, accept the scan prompt and retry. Repeated prerequisites are reported once, without a traceback. |
| Startup reports `module 'lib.cli' not found` | Check `/home/Beeomatic/lib/cli.lua` exists (adjust for a custom destination). As a workaround, `cd /home/Beeomatic` and rerun `Beeomatic setup`. Upgrade using the corrected installer to regenerate `/usr/bin/Beeomatic` with the explicit installation root. Existing `data/` is preserved. |
| Missing housing/transposer/inventory | Check loaded chunks, power, OC cables, adapter face and the full configured address. Restore the original machine configuration, then `doctor` and `resume`. |
| Inventory size or slot witness changed | Stop, inspect `doctor --probe`, and reverify this specific machine. Do not reuse another alveary's map. |
| Scanner setup says to use a nine-slot full-block ME Interface | This check reads the inventory selected through the transposer, separately from the OC Interface adapter. Select the transposer side touching the Interface, not the analyser. Updated setup shows the actual slot count/transposer/side and allows reselection. If the correct side still reports another size, retain that reading and inspect `doctor --probe` rather than replacing hardware based on this message alone. |
| No compatible alveary | Read the job's temperature/tolerance, humidity, flowers and special-condition explanation. Add/configure a compatible housing, or correct a false environment attestation. |
| Cannot work / timeout | Inspect flowers, climate, sky, rain/day, queen health, frames, mutation equipment and full outputs. The API supplies only general workability. Resume gives a fresh bounded observation interval. |
| Last parent princess protected | Add spare princesses. The scheduler can convert expendable spares using reserve drones but cannot manufacture a princess from drones or consume every protected founder. |
| Exact drone reserve protected | Add compatible drones or run population from a usable pair with fertility >1 and a reserve drone. Different inactive alleles are not interchangeable. |
| Unscanned bees | Analyze manually or configure/test the isolated scanner path. In Interface mode, restore the shared scanner; initial drones must all be analysed before breeding. Unknown ME records need physical inspection first. |
| Scanner delayed/full | Restore input chest extraction, scanner honey/power and delivery of analysed bees into the output chest. The transposer must reach both chests and the relocated Interface. Only Beeomatic may extract from the output chest. Restore AE channels and cell capacity if deposits stall. Missing/partial outputs time out after ten minutes with the batch saved. |
| Scanner layout retired | Resolve any outstanding batch on the previous version. Replace the old Interface position beside the scanner with an output chest, move the Interface beside the transposer above its adapter, update/reboot and run `Beeomatic setup`. It automatically resumes at scanner registration even when the previous setup was complete; storage and alveary registration are retained. Outstanding work must be resolved first. Old direct analyser and automatic AE returns are unsupported. |
| Scanner output identity/count mismatch or contamination | Keep the saved batch intact. Check for raw, wrong-caste, wrong-species, excess or unrelated items in the dedicated output chest. Outputs must form one complete stack matching the reserved count. Do not inject replacement bees to fake completion. |
| Archive full | Add usable space or move unrelated products while no transaction is active. Source offspring remain in the machine. Exact full-stack merges reduce fragmentation; uncertain transfers remain journalled. |
| AE2 export cannot identify NBT | Enable server `allowItemStackNBTTags`, verify database copy behavior, or use physical chest storage. No visible-label fallback is allowed. |
| Too many same-label variants | Increase the dedicated database capacity/configuration. Never select only by visible label. All database entries used by Beeomatic are temporary scratch space. |
| Database did not preserve exact bee NBT | Update and reboot, then resume. Identity now compares complete decoded NBT, allowing compound-field ordering and gzip encoding differences without relaxing any genetic or other value checks. Saved identities migrate automatically. Transient copy failures still get three attempts. If blocked again, run `Beeomatic doctor --nbt`; it reports whether complete contents match or the first changed field. |
| `PREPARING_STOCK` stays active | Inspect the pending scanner phase/count in status. Restore honey, power, channels and output capacity. Initial drones cannot be skipped. Untracked analyser bees require an audit. |
| Interface stock/return timeout | Check exact stock, adapter-to-inventory pairing, AE power/channels/capacity and unwanted filters. A stock request or accepted return can remain locally journalled; repair before resuming. |
| Unexpected Interface filter / wrong receipt | Keep the request and stock for audit. Remove other filter controllers and fuzzy upgrades; verify that the selected adapter and inventory belong to the same port. |
| Owned ME batch missing | Restore the exact reserved stock or audit the journal. Other automation must not consume Beeomatic's owned bees. Do not replace a missing genotype with a same-label variant. |
| Legacy `exportIntoSlot` / redstone export failure | Retained saved configurations use the old exporter. See [legacy hardware](LEGACY_AE2.md); reconcile before migrating with `setup --reconfigure`. New Interface mode does not use that callback or redstone circuit. |
| Partial transfer | For ordinary inventories, `doctor` compares both sides and records an unambiguous observed partial quantity. A saved positive Interface callback with matching physical evidence can reconcile a partial quantity; scanner preparation then processes the remaining units. Missing proof stays blocked for audit. Resume collection after the journal reconciles. Scanning partial stacks may require manual recombination of the tracked stock. |
| Restart during input insertion | Inspect the real housing. Use `doctor --adopt JOB` for an observed matching live queen/finished pair, or restore original sources and an empty machine, then `doctor --retry JOB`. Neither option repeats an uncertain movement blindly. |
| Worker lock after reboot | Ensure no old foreground/background worker remains, then `resume --recover`. A lock is not automatically expired merely because a heartbeat is old. |
| Cycle budget exhausted | Inspect genetics, mutation chance and conditions. Archive results, drain jobs safely, fix resources/configuration, then replan. Increasing `maxCycles` is an explicit bounded policy change. |

For a genuinely ambiguous chest or scanner movement, `doctor` intentionally cannot
guess where an item went. Inspect the recorded `pending` source, destination,
identity and counts. Restore the recorded before-state without deleting stock, or
restore a provable complete/partial receipt. Then run `doctor` again. If the final
drone has been consumed into a queen, `doctor --adopt JOB` has a narrow verification
path for that job's expected queen and source-count change. A routed adoption
additionally requires your visual inspection of the real housing.

For an ambiguous AE2 export, stop all autonomous export, inspect the journal's
isolated buffer slot, and preserve exported stock. A matching physical receipt can
be reconciled by `doctor`. If no receipt exists and network movement cannot be
proved, manual audit is required; the program does not issue another export and
risk double allocation. Keep the journal while investigating.

Mutation conditions are saved by exact text and alveary ID. If a special foundation
is installed, use `doctor --confirm ID` and explicitly confirm it. Day/time/weather
or equipment-dependent descriptions may become false later: revoke their saved
confirmation after changes.


## Limited RAM and disk space

For the 2048 KiB RAM / 4 MB disk computer, update and reboot OpenOS before running
`Beeomatic resume` so old loaded modules are released. Existing state is retained:
legacy completed receipts are compacted as they are read, and the next successful
checkpoint writes the smaller form. Pending transfers, scanner batches and exact
identities remain available for recovery. Do not delete `data/state.lua` to fix RAM.

`Not enough disk space for checkpoint` means the new generation cannot fit with
recovery protection. Beeomatic checks the mounted filesystem before writing and
keeps a verified generation. Free unrelated disk space, then resume. Old backup
space is reclaimed automatically only when a verified primary exists and that
reclaim is sufficient; a backup recovered after a corrupt primary is protected.


## Abandoning a stuck process

Run `Beeomatic cancel`. `Beeomatic stop` and the foreground `q` key do the same.
This removes the whole breeding plan immediately, including jobs paused after a
queen was removed manually or blocked by missing flowers. It does not require
working hardware or a completed cycle. Bees remain in-world; occupied housings
must be emptied manually before reuse. Already-inserted scanner batches and
unresolved transfers remain as inactive recovery records for the next fresh
request. `resume` does not restart a cancelled plan.
