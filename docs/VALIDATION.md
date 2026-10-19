# Validation and in-game acceptance

Target: GTNH **2.9.0 Beta 3**, OpenComputers **1.12.61-GTNH**, Forestry **4.11.37**,
AE2 **rv3-beta-1050-GTNH**, Gendustry **1.9.13-GTNH**. The source contracts are
recorded in [API compatibility](API_COMPATIBILITY.md). **No Minecraft runtime is
attached to this development workspace. The new Interface/scanner application
flow still requires in-game acceptance.**

## Automated checks

Current result: **137 tests, zero failures on each of Lua 5.2 and Lua 5.3**.
Run `python tests/run.py` in the development workspace. It syntax-checks every
project Lua file, then runs the suite on both engines using local Lupa runtimes.
Alternatively run `lua tests/run.lua` with a compatible runtime. These dependencies
stay on the development PC and are not installed on the OpenComputer.

Interface coverage includes:

- Exact NBT selection among same-label variants and bounded requested quantities.
- Automatic source refill, return drain before readback, full/offline storage,
  interrupted requests, proven partial acceptance, and crash recovery with/without
  sufficient acceptance proof.
- Startup inspection of already-analysed bees without spending analysis supplies,
  all units across multiple raw drone batches, missing scanner, new external raw
  variants, initial housing leftovers and untracked analyser specimen slots.
- One shared scanner, analysis changing NBT, quantity ownership through merged
  stacks and two independent alvearies retaining their own offspring.
- Restart immediately after accepted scanner input and after committed return;
  collection recovery after the bounded physical history has expired.
- The public CLI through saved configuration/state, foreground events and initial
  drone preparation, breeding, offspring scanning and completion.
- Fresh Interface-first setup, bound transposers, direct analyser output slots
  with consumables untouched, `back`, resumed registration and port pruning.
- Automatic native alveary input/output maps and retryable placement checks:
  empty slots, wrong caste and mismatched housing adapters. Unanalysed test bees
  are accepted for placement without weakening the runtime analysis gate.
- The Interface doctor probe and refusal to migrate unresolved saved work.

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
4. Test the actual analyser input/output slots and consumables. For standard pinned
   Forestry, source indices are inputs 3-8, outputs 9-12, specimen 1 and honey
   container 2. Witness one isolated batch returning analysed with the same count.
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
