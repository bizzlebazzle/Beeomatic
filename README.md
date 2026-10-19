# Beeomatic

Modular OpenComputers/OpenOS bee breeding for **GTNH 2.9.0 Beta 3**. It discovers
Forestry mutation routes, schedules independent prerequisites across registered
alvearies, retains useful genetics, stabilizes target stock, and journals physical
item movements. Chest storage works independently; exact-NBT AE2 subnet storage,
isolated scanning, reference-drone imprinting and a foundation robot are optional.

The application and mocked Lua 5.2 tests are implemented. **Actual in-game hardware
acceptance is still required**; see [validation](docs/VALIDATION.md). Source-verified
integration versions and genuine limits are recorded in
[API compatibility](docs/API_COMPATIBILITY.md).

```sh
lua install.lua /home/Beeomatic
Beeomatic setup
Beeomatic doctor
Beeomatic plan spirit
Beeomatic breed spirit
```

Copy this complete folder to an OpenOS-visible disk before running the offline
installer above. Internet Card installation from the public
[GitHub repository](https://github.com/bizzlebazzle/Beeomatic) is also supported:

```sh
cd /home
wget https://raw.githubusercontent.com/bizzlebazzle/Beeomatic/master/get.lua
lua get.lua
```

The downloader fetches one consistent Git revision before installing and preserves
existing data. The main installed command is `Beeomatic`.
Use `Beeomatic help` for commands or see [installation](docs/INSTALLATION.md),
[physical hardware/layout](docs/HARDWARE.md), [commands](docs/COMMANDS.md),
[architecture](docs/ARCHITECTURE.md), [troubleshooting](docs/TROUBLESHOOTING.md), and
the [reference implementation review](docs/REFERENCE_REVIEW.md).

`breed spirit` uses the recipes returned by your server. Ethereal + Aware is a
preferred route only when Forestry actually reports it. Missing dependencies are
planned recursively. The scheduler can populate parent drones and convert spare
princesses without separate user commands. Hive founders, adequate spare princesses,
reserve drones, compatible climates, scanning access and mutation conditions must
exist physically. The program cannot create hive stock from nothing.

Default completion requires a pure target princess and pure compatible drones,
minimum stock, and two consecutive confirmed stable offspring cycles. All-gene
equivalence is a separate option. All offspring/products are archived; no destructive
discard policy runs by default. Source leases, machine reservations and protected
princess lineages prevent competing jobs from sharing the same selected item.

The foreground worker handles `p`, `r`, `q` and Ctrl+C, with persistent mailbox
control from another OpenOS shell where available. `resume` reconciles actual
inventories and saved work. Ambiguous transfers require an audit instead of replay.

Typical multi-alveary registration:

```lua
-- Structure only; use setup for real addresses, sides, climate and slot witnesses.
alvearies = {
  {id="temperate_1", name="Temperate Alveary", priority=1, enabled=true,
    environment={temperature="NORMAL", humidity="NORMAL", verified=false}},
  {id="hot_dry_1", name="Hot Dry Alveary", priority=2, enabled=true,
    environment={temperature="HOT", humidity="ARID", verified=false}},
  {id="cold_damp_1", name="Cold Damp Alveary", priority=3, enabled=true,
    environment={temperature="COLD", humidity="DAMP", verified=false}},
}
```

[config.example.lua](config.example.lua) includes the complete defaults-based
structure with separate transposers and explicit unverified slot maps. Runtime
configuration lives in `data/config.lua`; job state, journal and mailbox live in
`data/`. Never copy the example over an existing installation's state.

Project tree:

```text
Beeomatic/
  Beeomatic                 # source-folder launcher
  Beeomatic.lua             # installed entry point
  install.lua
  manifest.lua
  config.example.lua
  robot-helper.lua
  README.md
  lib/
    util.lua, cli.lua, setup.lua, config.lua, components.lua
    bees.lua, genetics.lua, mutations.lua, planner.lua, environment.lua
    inventory.lua, persistence.lua, jobs.lua, scheduler.lua
    scanner.lua, templates.lua, robot.lua
    storage/  base.lua, chest.lua, ae2.lua, ae2_export.lua
    breeders/ base.lua, factory.lua, alveary.lua, routed.lua
    ui/       status.lua, diagnostics.lua
  tools/probe.lua
  tests/
    run.lua, run.py
    mocks/world.lua, mocks/openos.lua
    test_planner.lua, test_genetics.lua, test_environment.lua
    test_storage.lua, test_scheduler.lua, test_recovery.lua
    test_scanner.lua, test_setup.lua, test_integration.lua, test_cli.lua
  docs/
    INSTALLATION.md, HARDWARE.md, COMMANDS.md, ARCHITECTURE.md
    TROUBLESHOOTING.md, API_COMPATIBILITY.md, REFERENCE_REVIEW.md
    VALIDATION.md, API_EVIDENCE.json
```

Development check in this workspace: `python tests/run.py` runs Lua 5.2 and Lua 5.3.
Current validation: **80 tests passed on each engine**, including the public CLI Spirit workflow,
installer upgrades, exact selection of a second same-label AE2 genetic variant,
concurrent machines, protected reserves and interrupted transfer recovery.
Local `.tools/` and downloaded `research/` are ignored and not installed. No external
Lua library is needed on the Minecraft computer.

Multiplayer testing found the GTNH 2.9 Beta 3 `exportIntoSlot` **config=null**
integration bug. Normal redstone-controlled export was then verified manually with
an exact-NBT receipt. Setup now defaults to `exportMode="redstone"` for AE2: a
dedicated OC redstone output stays enabled until real receipts arrive or a timeout
expires. It shuts down and clears the exact filter before archiving all receipts.
The automated OC signal path still needs in-game wiring validation. Callback mode
remains available for installations with a working integration; it is not an
automatic fallback after an uncertain export.
