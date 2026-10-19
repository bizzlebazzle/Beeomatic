# Troubleshooting and recovery

Always preserve `data/config.lua`, `data/state.lua` and their `.bak` files. Do not
delete bees or the journal to make a warning disappear. Stop other workers before
changing configuration or moving stock involved in a pending transfer.

| Report | Action |
|---|---|
| Startup reports `module 'lib.cli' not found` | Check `/home/Beeomatic/lib/cli.lua` exists (adjust for a custom destination). As a workaround, `cd /home/Beeomatic` and rerun `Beeomatic setup`. Upgrade using the corrected installer to regenerate `/usr/bin/Beeomatic` with the explicit installation root. Existing `data/` is preserved. |
| Missing housing/transposer/inventory | Check loaded chunks, power, OC cables, adapter face and the full configured address. Restore the original machine configuration, then `doctor` and `resume`. |
| Inventory size or slot witness changed | Stop, inspect `doctor --probe`, and reverify this specific machine. Do not reuse another alveary's map. |
| Scanner setup says to use a nine-slot full-block ME Interface | This check reads the inventory selected through the transposer, separately from the OC Interface adapter. Select the transposer side touching the Interface, not the analyser. Updated setup shows the actual slot count/transposer/side and allows reselection. If the correct side still reports another size, retain that reading and inspect `doctor --probe` rather than replacing hardware based on this message alone. |
| No compatible alveary | Read the job's temperature/tolerance, humidity, flowers and special-condition explanation. Add/configure a compatible housing, or correct a false environment attestation. |
| Cannot work / timeout | Inspect flowers, climate, sky, rain/day, queen health, frames, mutation equipment and full outputs. The API supplies only general workability. Resume gives a fresh bounded observation interval. |
| Last parent princess protected | Add spare princesses. The scheduler can convert expendable spares using reserve drones but cannot manufacture a princess from drones or consume every protected founder. |
| Exact drone reserve protected | Add compatible drones or run population from a usable pair with fertility >1 and a reserve drone. Different inactive alleles are not interchangeable. |
| Unscanned bees | Analyze manually or configure/test the isolated scanner path. In Interface mode, restore the shared scanner; initial drones must all be analysed before breeding. Unknown ME records need physical inspection first. |
| Scanner delayed/full | Restore honey/power/routing and empty only unrelated obstructions. Keep the tracked batch and its recorded analyser input/output intact. Do not inject a replacement bee to fake completion. |
| Archive full | Add usable space or move unrelated products while no transaction is active. Source offspring remain in the machine. Exact full-stack merges reduce fragmentation; uncertain transfers remain journalled. |
| AE2 export cannot identify NBT | Enable server `allowItemStackNBTTags`, verify database copy behavior, or use physical chest storage. No visible-label fallback is allowed. |
| Too many same-label variants | Increase the dedicated database capacity/configuration. Never select only by visible label. All database entries used by Beeomatic are temporary scratch space. |
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
confirmation after changes. A robot acknowledgement never confirms all conditions.
