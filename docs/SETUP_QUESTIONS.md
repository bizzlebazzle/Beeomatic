# Setup question inventory

Current after removing sky-access questions. This lists actual prompts, including
questions shared by component/inventory pickers. Informational instructions are
not counted as questions. Invalid choices can repeat a prompt; `back` revisits a
stage. No further prompts have been removed on the basis of this inventory.

## Per alveary: direct Forestry inventory + ME Interface

These are the prompts in order for `alveary add`, also used within full setup:

| # | Prompt | Notes |
| --- | --- | --- |
| 1 | Unique alveary ID (letters/numbers/underscore) | Distinguishes machines |
| 2 | Friendly alveary name | Defaults to its ID |
| 3 | Component number: Housing component address | Select the housing adapter |
| 4 | Inventory backend: alveary (direct access) or routed (external gated pipes) | Defaults to `alveary` |
| 5 | Component number: Transposer for Alveary inventory | Skipped when there is only one compatible, already-named transposer |
| 6 | Inventory number for Alveary inventory | Select the attached alveary/side |
| 7 | Inventory ID for Alveary inventory | Defaults to alveary ID |
| 8 | Inventory number for ME Interface | Uses the already selected transposer |
| 9 | Inventory ID for ME Interface | Reuse the ID when sharing a physical Interface |
| 10 | Component number: Adapter at ME Interface | Select its OC adapter |
| 11 | Press Enter to check, or type back to change the inventory connection | Manually place princess in slot 1, slot 2 empty |
| 12 | Press Enter to check, or type back to change the inventory connection | Remove princess; put drone in slot 2, slot 1 empty |
| 13 | Temperature: ICY COLD NORMAL WARM HOT HELLISH | Working climate including upgrades |
| 14 | Humidity: ARID NORMAL DAMP | Working humidity |
| 15 | Have you verified this operating environment in-game? | Yes/no, defaults no |

Each previously unnamed component selected at 3, 5 or 10 adds **Friendly name for
this component** immediately after selection. Previously named components skip
that question. Full setup also asks **Register another alveary?** after registration;
standalone `alveary add` does not.

There are no native input/output slot questions. Slots 1/2/3-9 are assigned
automatically. No biome, dimension, flower, time-of-day, lighting, rain, rain-shield
or sky-access questions remain.

## Shared ME storage section (full setup)

Before registering alvearies:

1. Storage: me or chest.
2. Component number: ME network reader (Interface/controller).
3. Component number: Dedicated database.
4. Database entry capacity.
5. Maximum wait for ME stock/returns, seconds (default 60).
6. All ports belong to this ME network, with no storage buses, fuzzy/crafting
   upgrades or other filter controllers?

New component selections also ask for friendly names. Switching an existing
installation to ME remaps each saved alveary's storage using the Interface
inventory number, inventory ID and Interface adapter picker.

Chest mode instead registers the archive through a transposer picker, inventory
picker and inventory ID. Existing chest mode can ask **Change the primary archive
connection?**. Per-alveary chest registration selects its archive inventory and ID
in place of ME Interface registration.

## Shared scanner section (full setup, ME mode)

1. Component number: Transposer for Shared scanner ME Interface (may auto-select
   a lone named transposer).
2. Inventory number for Shared scanner ME Interface.
3. Inventory ID for Shared scanner ME Interface.
4. Component number: Adapter at Shared scanner ME Interface.
5. Inventory number for Analyser input (or isolated input staging).
6. Inventory ID for Analyser input (or isolated input staging).
7. Inventory number for Analyser output (or isolated output staging).
8. Inventory ID for Analyser output (or isolated output staging).
9. Witnessed input slot (Forestry analyser: 3).
10. Witnessed output slots (Forestry analyser: 9,10,11,12; exclude consumables).
11. Scanner timeout in seconds (default 600).
12. Have you tested one input stack producing one analyzed output stack with
    equal count?

The scanner transposer is reused for input/output selection. New components add
their friendly-name question. ME mode requires a scanner and does not ask whether
to enable one. Chest mode first asks **Configure automated scanner? (Otherwise
analyze bees manually)** and, if enabled, registers its archive/input/output
inventories, input slot, timeout and isolation confirmation.

## Optional features (full setup)

1. Enable selective genetic imprinting from reference drones?
   - If yes in ME mode: temporary witness inventory (transposer, inventory, ID),
     analysed reference drone witness slot, minimum reference drones to retain.
   - If yes in chest mode: template archive inventory ID, reserved reference drone
     slot, minimum reference drones to retain.
2. Register an optional wireless foundation helper?
   - If yes: local wireless modem component, robot wireless modem address,
     alveary ID served by the robot, command port and reply port.

Component selection adds a friendly name only when the component is unnamed.

## Additional routed-alveary questions

Selecting `routed` replaces native inventory selection with input staging
selection. It also adds:

- Dedicated routing output inventory: transposer, inventory number and inventory ID.
- Routing redstone component and verified local gate output side.
- Confirmation of caste paths, gate isolation, housing association and output return.
- Princess input staging slot, drone input staging slot and output staging slots.
- Confirmation that the isolated output staging route and slot map were tested.

The two placement checks and climate questions still follow. These extra questions
do not appear for direct Forestry alvearies.

## Optional picker action

Choosing **N connect new** adds **Connect the new component to the OC network,
then press Enter**. Refresh and pagination reuse the component-number prompt.
