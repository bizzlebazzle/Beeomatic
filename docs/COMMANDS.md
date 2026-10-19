# Commands and process control

Commands and species names are case insensitive. Use quotes around multiword
species. Full Forestry species UIDs and configured aliases are accepted.

```sh
Beeomatic setup
Beeomatic setup --reconfigure
Beeomatic doctor
Beeomatic doctor --probe
Beeomatic plan spirit
Beeomatic breed spirit
Beeomatic breed spirit --noFinalImprint
Beeomatic breed spirit --onlyFinalImprint
Beeomatic convert spirit
Beeomatic populate spirit 32
Beeomatic imprint spirit
Beeomatic status
Beeomatic status --verbose
Beeomatic pause
Beeomatic pause job3
Beeomatic resume
Beeomatic resume job3
Beeomatic stop
Beeomatic alveary list
Beeomatic alveary add
Beeomatic alveary remove hot_dry_1
Beeomatic storage scan
Beeomatic bees list
Beeomatic bees inspect spirit
Beeomatic logs
Beeomatic help
```

`plan` reads runtime routes and actual storage without moving items. Missing hive
stock, unknown species and dependency cycles produce diagnostics. Unanalyzed
network stock can remain unresolved in a read-only plan; `breed` performs catalog
inspection/scanning before planning. A mutation preference is a tie-breaking
preference among runtime-confirmed routes, not a recipe assertion. Spirit's
Ethereal/Aware preference is ignored if the runtime does not return that pair.

Breeding, conversion, population and imprinting run in the **foreground**. Keep the
computer powered and chunks loaded. On-screen keys are `p` (pause), `r` (resume),
`q` (drain and stop). Ctrl+C preserves state and returns to the shell. Pausing
suspends scheduling/observation; Minecraft may continue a queen's natural lifecycle.
Resuming inspects reality before continuing. Stopping prevents new insertions and
collects active cycles when possible; a broken or explicitly paused machine still
needs recovery before its stock can be released. Never delete state to stop work.

If OpenOS provides another shell/process, `pause`, `resume`, and `stop` write
`data/control.lua`. The foreground worker reads this mailbox at its bounded polling
interval; it does not pretend a second command magically controls another process.
`status` and `logs` read the last saved snapshot. Do not start two workers for the
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

```sh
Beeomatic doctor --confirm hot_dry_1
Beeomatic doctor --robot temperate_1
```

Confirmation asks about each exact requirement string and saves only explicit
`confirmed` replies. Revoke a confirmation in the configuration if the relevant
block, biome, dimension, equipment or world condition changes. No inference from a
generic robot reply is sufficient. Structured route `environment` constraints
are supported by the planner/backend if supplied by an extension/configuration.

Recovery tools for a reserved job:

```sh
Beeomatic doctor --adopt job3
Beeomatic doctor --retry job3
```

`--adopt` is an explicit operator instruction after inspecting that job's actual
queen or complete offspring pair. It continues observation/collection and does not
repeat insertion. A consumed-drone transfer can only be adopted with source-count
evidence and the expected queen genome. For routed machines, the operator must
verify the real queen through the GUI because staging inventories cannot establish
caste inside the housing. `--retry` requires an empty machine, reconciled journal
and restored recorded source items. Neither command discards bees.

To replan after changed stock/routes: drain existing work with `stop`, resolve any
reserved machines, and issue `breed TARGET` again. The completed stopped plan stays
in the journal until replaced. The `--noFinalImprint` and `--onlyFinalImprint` flags
affect optional reference-drone crossing only; ordinary breeding works without
templates. Full genome equivalence is configured separately from species purity
using `fullEquivalence=true` in `data/config.lua` while the worker is stopped.
