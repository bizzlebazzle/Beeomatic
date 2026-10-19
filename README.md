# Beeomatic

OpenComputers/OpenOS bee breeding for **GTNH 2.9.0 Beta 3**. Beeomatic discovers
Forestry mutation routes, schedules work across multiple alvearies, retains useful
genetics and protects founder/reserve stock. It journals physical item movement
and keeps jobs recoverable after interruptions.

**ME Interface storage is the default.** Each alveary has a local Interface and
transposer; bees and products live in real ME storage. One shared analyser station
inspects/analyses bees. Its transposer inserts raw bees into an adjacent input
chest; your pipes handle analysis and return directly to an ME Interface.
Setup needs no analyser slot map or output inventory. No shared archive chest or
export bus is required.

On every start/resume, all initial drones must be verified analysed before breeding
begins. During operation, offspring may queue temporarily in AE, but pending bees
cannot be selected for breeding. Already-analysed bees whose ME records omit genes
are physically inspected and catalogued without unnecessary analysis.

The implementation passes mocked Lua 5.2 and 5.3 tests. **The new Interface flow
still requires in-game acceptance**; source verification and mocks cannot certify
your installed hardware. See [validation](docs/VALIDATION.md).

```sh
cd /home
wget https://raw.githubusercontent.com/bizzlebazzle/Beeomatic/master/get.lua
lua get.lua
Beeomatic setup
Beeomatic doctor
Beeomatic doctor --interface port_temperate
Beeomatic plan spirit
Beeomatic breed spirit
```

Use your saved port ID for the probe. Stop Beeomatic before updating with `update`
and reboot afterward. For offline installation, copy the files in `manifest.lua`
and run `lua install.lua /home/Beeomatic`. Existing `data/` is preserved.

Setup uses numbered component/inventory choices, saved names, section checkpoints
and `back`. Alveary registration also saves its own stages, so it resumes after
an interruption. Use `Beeomatic alveary add` to add a machine without repeating
storage/scanner setup. Each housing retains its own slot map and climate.

See [installation and migration](docs/INSTALLATION.md), [hardware](docs/HARDWARE.md),
[commands](docs/COMMANDS.md), [architecture](docs/ARCHITECTURE.md),
[API evidence](docs/API_COMPATIBILITY.md), [troubleshooting](docs/TROUBLESHOOTING.md)
and the [design](docs/ME_INTERFACE_PLAN.md). [config.example.lua](config.example.lua)
shows three independent alveary ports and one shared scanner; it is deliberately
unverified and must not overwrite existing configuration/state.

`breed spirit` uses the server's actual recipes. Ethereal + Aware is preferred only
when Forestry reports that route. Prerequisites are planned recursively. Population
and spare-princess conversion use the same scheduler. Hive founders, spare
princesses, reserve drones, compatible climates and mutation requirements must
exist physically; the program cannot create founders from nothing.

Completion requires a pure target princess, pure compatible drones, minimum stock
and two consecutive stable offspring cycles by default. Full gene equivalence and
reference-drone imprinting are additional options. No destructive discard policy
runs. Exact identity/quantity ownership survives ME stack merging and analysis
changing NBT; each job keeps its own princess lineage while active.

The foreground worker supports `p`, `r`, `q`, Ctrl+C and persistent mailbox control
from another shell. `resume` reconciles inventories and pending receipts. Ambiguous
movement pauses for audit instead of replaying an insertion.

Chest-only storage remains optional. Existing `kind="ae2"` export-bus installations
retain a compatibility backend so their jobs/journals can be reconciled before
migration. New setup uses `kind="me_interface"`; the old export prompts are removed.

Development check: `python tests/run.py` syntax-checks and tests on Lua 5.2 and 5.3.
Tests/docs/research and development dependencies are excluded from the installation
manifest. No third-party Lua library is needed on the Minecraft computer.
