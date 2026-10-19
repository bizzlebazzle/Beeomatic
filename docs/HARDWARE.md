# Physical construction and topology

The direct backend needs, per alveary, an OC adapter against an assembled alveary
block and a transposer touching a valid inventory face. The adapter supplies bee
and mutation information; the transposer supplies item access. Do not expect an
adapter to transfer items. Connect both to the computer with OC cable.

```text
                    OC cable to computer
                     |             |
              [Adapter]       [Transposer]
                  |               |    |
             [Alveary] -----------+    +-- [Archive chest]
```

This is a topology diagram, not a promise that arbitrary faces work. The wizard
prints the selected addresses and actual sides after probing your installation.
Side numbers are world directions relative to the transposer: **0 down, 1 up,
2 north, 3 south, 4 west, 5 east**. They are not screen directions or the front of
the computer. Slots in OpenComputers are one-based.

For multiple machines, each transposer should reach the **same physical archive**.
Use accessible faces of a suitably sized shared inventory or a multiblock storage
inventory whose multiple block views you have verified to expose the same slots.
A normal chest has finitely many usable faces; do not pretend arbitrarily many
transposers can fit around one block. Give views of the same inventory the same
`id` and verify identical slot contents. Never reuse that ID for separate chests.
Separate archive IDs are supported for inspection, but chest mode cannot teleport
bees between disconnected inventories. A job pauses if its selected stock is in
an unreachable archive. Scale the physical hub or use the AE2 bridge described
below. Every alveary retains its own input/output map, environment and address.

Build different climates as required. Read **working** temperature and humidity,
including alveary climate upgrades. Configure actual flower-provider IDs seen in
an analyzed bee's `individual.active.flowerProvider`; names such as `flowers` are
IDs, not assumptions about which blocks a particular species accepts. Verify sky,
rain and day/night operation. `daylightManaged` means you have explicitly verified
how this installation handles the bee's activity schedule; the program does not
set the Minecraft time or bypass the bee's traits. A queen that cannot work will
report obstruction and eventually hit the configured timeout.

## When direct inventory access is unavailable

Choose `routed` during alveary registration. Keep the housing adapter but provide
dedicated input and output staging inventories accessible to the transposer:

```text
archive <---> transposer <---> input staging
                    |              |
                    |       two caste-selective routes
                    |        controlled by ONE gate
                    |              |
              output staging <--- alveary + adapter
```

The route from each input staging slot must accept the correct caste and deliver
it to that single alveary. Both input routes MUST be stopped at gate level `off`,
so princess and drone receipts can be verified before routing starts. The gate is
an explicitly addressed OC redstone component with `setOutput(side,level)`.
Validate the external pipes, filters, redstone polarity and chunk behavior using
expendable stock. The separate output chest must receive only this machine's
offspring/products. Disable automatic rebreeding loops. Inputs and output must be
isolated from every other job and from the archive. Beeomatic waits for empty
staging inputs, no housing queen/drone, and a complete offspring pair in the output
chest. Transit and machine activity share the bounded cycle timeout.

## AE2 dedicated subnet

Required: powered dedicated ME subnet and storage, ME storage bus on the physical
archive, interface or controller exposed through an adapter, a **dedicated OC
database**, and a separately exposed ME export bus feeding an isolated buffer.

```text
ME storage / subnet -- storage bus -- archive <---> breeder transposers
          |
          +-- ME interface/controller -- OC adapter -- OC cable
          |
          +-- export bus --> isolated buffer <---> bridge transposer <---> archive
                       OC adapter         |
                                 dedicated database on OC network
```

The buffer must not be exposed to ME by another storage/import bus. Inhibit the
export bus's normal automatic operation using a redstone card, remove fuzzy and
crafting upgrades, clear every filter slot, and verify the imperative
`exportIntoSlot` callback still works in this arrangement. Beeomatic temporarily
uses filter slot 1 and clears it after each request. Database capacity is entered
explicitly; the database must not be used by another script. Same-label genetic
variants need enough database entries to copy the candidate group before choosing
the exact NBT match. A capacity mismatch pauses rather than selecting loosely.

Results are transferred into the **real archive chest** and verified there. Its
storage bus makes those bees part of ME storage. There is no racing asynchronous
import bus on that chest. On Beta 3, network item records can lack Forestry genetic
data: unknown records are exported to the archive for inspection and catalogued.
Allow enough physical archive space for this discovery, offspring, products and
protected reserves. Space exhaustion preserves sources and pauses collection.

The bridge transposer needs a view of the same physical archive used by the
selected breeder. Other breeder transposers can use their own views of that hub.
Disconnected archives need suitable physical bridge topology; there is no
arbitrary transfer between OC components. Do not put storage buses on working
alvearies. Only Beeomatic may modify the dedicated export bus/database while jobs
run. Avoid manual item movement while a transfer is in progress.

## Scanner, templates and foundation helper

The scanner path is optional. Supply a dedicated input staging chest, a supported
scanner/analyzer with its power and consumables, external routing, and a dedicated
output chest. The scanner transposer must reach both staging chests and the same
archive. One complete reserved stack enters at a time, and output must merge into
one analyzed stack of identical caste/count/individual identity. No unrelated
items may enter. Beeomatic records the original archive slot and returns the
analyzed stack there. If this layout cannot be validated, scan bees manually and
leave automation disabled.

Templates are analyzed reference **drones in a registered archive slot**, made
with Gendustry if desired. Imprinting is ordinary selective crossing; no unsupported
Gendustry machine RPC is used. Species purity and non-species template traits are
verified independently, and template reserve drones are protected.

An optional stationary robot can serve one registered alveary foundation position.
Run `robot-helper.lua LOCAL_MODEM CONTROLLER_MODEM PORT` on that robot with a
`robot-foundations.lua` file returning a map of exact runtime requirement strings
to reference block inventory slots. Its front must face the intended foundation
position. It will compare/place, **never dig**. Modem addresses and ports must match
setup. `doctor --robot ID` requests whitelisted foundation actions; you still use
`doctor --confirm ID` after inspecting the actual condition. Replies are scoped to
sender, nonce and requirement, and cannot approve unrelated mutation conditions.
