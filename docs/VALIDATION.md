# Validation and in-game acceptance

Development target: GTNH **2.9.0 Beta 3**; OpenComputers **1.12.61-GTNH**,
Forestry **4.11.37**, AE2 **rv3-beta-1050-GTNH**, Gendustry **1.9.13-GTNH**.
These versions are verified from the release manifest and OC/Forestry tagged source.
The full application has not yet run in-game. Manual component tests on the user's
server confirmed physical genetic inspection, exact database NBT copy, the broken
imperative callback, and normal redstone export with an exact-NBT receipt.

Current automated result: **76 tests passed, zero failures, on each of Lua 5.2 and Lua 5.3**. This
includes the public command path, persistent foreground events, installer copy and
upgrade preservation, and exact selection of a non-first same-label ME variant.

Run automated tests on a development machine with Lua 5.2:

```sh
lua tests/run.lua
```

Or on this Windows workspace, where a local Lupa runtime was installed:

```powershell
python tests/run.py
```

The Python wrapper imports `lupa.lua52` and `lupa.lua53`, syntax-checks every project Lua file and
runs the same test suite on both engines. Component mocks use callable tables and
indirect (`false`) method metadata, matching the user's observed OpenOS proxies.
To provision another development host, install Lupa
(`python -m pip install --target .tools lupa`). That is a development dependency,
not a Minecraft installation requirement.

The suites cover runtime route selection; recursive missing Ethereal/Aware planning;
alternate routes and cycles; purity/full equivalence/templates; directional climate
tolerances; multi-machine compatibility; exact identities and reservations;
failed/interrupted transfers; AE2 export and database selection; full archives;
conversion and population; concurrent jobs; delayed/timed-out scans; active queen
restart and partial insertion; missing machines; special conditions; resumable
setup checkpoints; and multi-stage Spirit execution preserving founder reserves.
Mocks use Forestry active/inactive species tables, percentage mutation chances,
special-condition strings, OpenComputers inventory callbacks and AE2's boolean
export result. Native breeder mocks deliberately use **11 slots, princess 4,
drone 2, outputs 6/8/10**, so apiary input/output assumptions would fail tests.

## Required acceptance on the actual server

1. Back up computer data and use expendable analyzed stock. Run `doctor --probe`.
   Confirm the exact exposed methods and full addresses. Verify multiple blocks of
   one alveary are not mistaken for independent machines.
2. For each alveary, witness princess and drone input roles separately without
   mating, then witness an expendable full cycle. Verify output slots, products,
   frame/upgrade exclusion, extraction permissions, actual climate and association
   between adapter and transposer views. Empty or restore test inventories.
3. Configure one native machine and chest first. Run a common, low-cost mutation.
   Check that actual transfer amounts and queen formation agree with journal
   receipts, results are archived, hybrids are analyzed, and completion requires
   stable pure princess/drone offspring across the configured confirmation cycles.
4. Fill archive/output space and block a transfer. Verify source stock remains and
   the job pauses with a useful diagnosis. Restore space, run `doctor`, then resume.
5. Pause/interrupt during an active queen and restart the computer. Verify no second
   insertion, queen loss, output replay or double allocation. Test the documented
   partial-insertion adoption/retry workflow only with expendable stock.
6. Register a second machine with a different climate. Request independent
   prerequisites and confirm exclusive machine assignment, climate filtering,
   founder reserves and fair progress. Disconnect one machine and verify another
   running operation can still progress.
7. Validate the scanner's one-stack, count-preserving, isolated input/output
   provenance. Test loss of power/honey, delayed output, blocked return slot and
   restart after analysis. Keep automation disabled until this passes.
8. For AE2, enable exact NBT exposure, use a dedicated database/subnet and remove
   fuzzy export upgrades. Store two same-label drones with different inactive
   alleles. Verify the requested genotype is copied to the database and exported,
   including when the matching entry is not first. Confirm automatic export is
   controlled only by the configured OC output, the isolated buffer is not exposed
   back to ME, and archive/storage-bus counts are deduplicated. Test network outage,
   export failure and space exhaustion.
9. If using `routed`, test gate OFF holding both caste stacks, gate ON delivering
   only to its configured breeder, complete isolated output return, stalled pipe
   timeout and restart while items are in transit. Do not enable without proof of
   isolation and correct routing polarity.
10. Test a real special mutation. Confirm each requirement at the selected alveary;
    verify a robot reply cannot satisfy unrelated conditions. Revoke confirmations
    when world/equipment conditions change. Finally run `plan spirit`, then
    `breed spirit`, and compare the runtime-confirmed recipe tree to actual GTNH data.

These checks concern physical machine behavior and server settings that mocks
cannot establish. Do not describe the release as hardware-validated until these
steps have passed on the intended installation.
