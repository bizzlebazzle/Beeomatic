# BreederTron3000 review

Read all seven Lua files in
[the reference](https://github.com/FrostyFire1/GTNH_OC_SCRIPTS/tree/main/BreederTron3000):
main, utility, config, robotUtil, setup, robotSetup and robot. Beeomatic is an
independent implementation; no reference code is redistributed.

Preserved: recursive runtime parent discovery (`createBreedingChain`,
`processBee`), route preferences, useful hybrid selection (`breed`), drone reserve
recovery, weighted gene matching (`getGeneticScore`), repeated drone production
(`populateBee`), princess conversion, separate full equivalence
(`ensureGeneticEquivalence`) and selective reference-drone imprinting
(`imprintFromTemplate`). Foundation handling remains optional.

Replaced: interactive route conflicts with deterministic cost evaluation; species
counts with exact stack locations and genomes; implicit scanner positions with an
isolated single-stack scanner queue; one global machine with explicit component
addresses and per-machine mappings. Collection archives all offspring and products.
There is no destructive default disposal policy.

Original assumptions include the first transposer/housing proxy, size-based machine
selection, inputs 1/2 and outputs 3–9, one scan output sequence, an implicit last-slot
template, manual climate management and broad robot acknowledgements. Conversion
uses empty slot 1 as a completion signal; `cycleIsDone` instead searches for a
princess in fixed output slots. Neither is a reusable alveary lifecycle contract.
`dumpBreeder` shares those slot assumptions. `listBeesInStorage` groups by display
species/caste, losing genetic distinctions. Reserve searches can terminate after
empty gaps. Failed transfers, scanner waits and mutation restarts can be unbounded.
The replacement verifies receipts, scans full inventories, bounds cycles/timeouts,
and reconciles persisted intent before retry. Genetic comparison uses structural
values rather than a floating-point score equality test. Mutation conditions require
explicit operator confirmation for the exact requirement.
