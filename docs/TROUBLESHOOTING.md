# Troubleshooting and recovery

Always preserve `data/config.lua`, `data/state.lua` and their `.bak` files. Do not
delete bees or the journal to make a warning disappear. Stop other workers before
changing configuration or moving stock involved in a pending transfer.

| Report | Action |
|---|---|
| Missing housing/transposer/inventory | Check loaded chunks, power, OC cables, adapter face and the full configured address. Restore the original machine configuration, then `doctor` and `resume`. |
| Inventory size or slot witness changed | Stop, inspect `doctor --probe`, and reverify this specific machine. Do not reuse another alveary's map. |
| No compatible alveary | Read the job's temperature/tolerance, humidity, flowers and special-condition explanation. Add/configure a compatible housing, or correct a false environment attestation. |
| Cannot work / timeout | Inspect flowers, climate, sky, rain/day, queen health, frames, mutation equipment and full outputs. The API supplies only general workability. Resume gives a fresh bounded observation interval. |
| Last parent princess protected | Add spare princesses. The scheduler can convert expendable spares using reserve drones but cannot manufacture a princess from drones or consume every protected founder. |
| Exact drone reserve protected | Add compatible drones or run population from a usable pair with fertility >1 and a reserve drone. Different inactive alleles are not interchangeable. |
| Unscanned bees | Analyze manually or configure/test the isolated scanner path. For ME stock, permit exact NBT exports and allow archive space for catalog inspection. |
| Scanner delayed/full | Restore honey/power/routing and empty only unrelated obstructions. Keep the tracked stack and original archive return slot. Do not inject a replacement bee to fake completion. |
| Archive full | Add usable space or move unrelated products while no transaction is active. Source offspring remain in the machine. Exact full-stack merges reduce fragmentation; uncertain transfers remain journalled. |
| AE2 export cannot identify NBT | Enable server `allowItemStackNBTTags`, verify database copy behavior, or use physical chest storage. No visible-label fallback is allowed. |
| Too many same-label variants | Increase the dedicated database capacity/configuration or place some variants in the physical archive. All database entries used by Beeomatic are temporary scratch space. |
| Export receipt missing/wrong | Inhibit autonomous export, clear other export filters, remove fuzzy upgrades, isolate the buffer and check the network. Inspect the exact pending export before retrying. |
| `exportIntoSlot` returns `config is null` | Confirmed GTNH 2.9 integration bug (#25284). Use setup's explicit redstone export mode after verifying the OC signal circuit; do not repeat the broken callback or automatically switch after an uncertain movement. |
| Redstone export is slow or times out | The signal is held until a receipt, not briefly pulsed. Check channel/power, exact filter, source stock and active-with-signal wiring. Increase `exportTimeout` only after confirming the bus needs more time. Reconcile any pending receipt before another export. |
| Partial transfer | `doctor` compares both inventories and records an unambiguous observed partial quantity. Resume collection after the journal reconciles. Scanning partial stacks may require manual recombination of the tracked stock. |
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
