# Install on GTNH 2.9.0 Beta 3

Use an OpenComputers computer running **OpenOS with Lua 5.2 or Lua 5.3**.
Give it a writable hard drive, sufficient RAM, a screen/keyboard, stable power,
and OC cable connections to every configured component. Keep all breeder, storage,
scanner, routing and computer chunks loaded together. An Internet Card is not
needed for the offline installation below.

## Download from GitHub

With an Internet Card, exit the Lua prompt with Ctrl+D and enter these commands
at the OpenOS shell, one line at a time:

```sh
cd /home
wget https://raw.githubusercontent.com/bizzlebazzle/Beeomatic/master/get.lua
lua get.lua
Beeomatic setup
Beeomatic doctor
```

If `/home/get.lua` already exists, use `wget -f` to replace that bootstrap file.
The downloader resolves `master` to a full commit SHA, downloads the release
manifest and every listed file from that revision into `/home/Beeomatic.download`
(beside the destination when using a custom path), checks Lua syntax
and staged file contents, then invokes the offline installer. A failed download
leaves the installed program untouched. The installer retains existing `data/`
and one previous generation of replaced program files. Stop the worker first.
The final output prints the installed commit SHA. Downloaded staging files are
removed after success or failure; empty staging directories can remain for reuse.
The downloader does not use `/tmp`, which can be a much smaller filesystem than
the hard drive.

The release installs only the runtime paths in `manifest.lua`. Documentation,
tests, research, example configuration and robot helpers stay on the development
PC. Download staging, one previous installed generation and runtime data need
additional disk space. The downloader avoids the smaller `/tmp` filesystem.

To select a specific revision instead, run `lua get.lua FULL_COMMIT_SHA`.
An optional second argument selects an absolute installation directory.
Download uses GitHub's public API and raw file host; server Internet Card policy
must permit both `api.github.com` and `raw.githubusercontent.com`.
Complete hardware acceptance before starting a valuable breeding job.

### Quick updates

The installer also creates `/usr/bin/update`. Stop Beeomatic, then type:

```sh
update
```

This changes to `/home`, downloads `get.lua` with `wget -f`, and runs the freshly
downloaded installer. If the download fails, the update stops. Reboot afterward
to clear cached application modules. Like `get.lua`, it defaults to installing
in `/home/Beeomatic`; use `update FULL_COMMIT_SHA /absolute/install/path` for a
specific revision and destination.

To add the shortcut to an older installation after these files are published:

```sh
wget -f https://raw.githubusercontent.com/bizzlebazzle/Beeomatic/master/update.lua /usr/bin/update
```

## Offline installation

1. Copy the paths listed in `manifest.lua`, preserving their directory structure,
   into an OpenOS-visible filesystem, for example
   `/home/Beeomatic-source`. For single-player you can copy it into the computer's
   mounted filesystem directory under the world's `opencomputers` save data while
   the world is stopped. On a server, use the server's permitted file-transfer or
   disk workflow. Do not guess a filesystem UUID; identify the mounted disk first.
2. In OpenOS run:

   ```sh
   cd /home/Beeomatic-source
   lua install.lua /home/Beeomatic
   Beeomatic setup
   Beeomatic doctor
   Beeomatic plan spirit
   Beeomatic breed spirit
   ```

`install.lua` copies only the release manifest, verifies copied bytes, keeps one
`.previous` generation of replaced program files, and creates `/usr/bin/Beeomatic`.
It does not overwrite `data/`. It requires permission to write the chosen directory
and `/usr/bin`. It does not download or reboot anything. Do not install over a
running worker. A second install from the same source is supported.

`setup` lists compatible components by number, showing their addresses and saved
friendly names (or `Unnamed`). Select a number and name the component on first use;
names and full addresses are saved in `data/config.lua`. Existing configurations
work without a migration. Lists show two components per page: `>` and `<` change
pages, `R` refreshes, and `N` takes a snapshot before asking you to connect a new
component. It then lists only newly discovered compatible components for selection.
Use `R` to return to the complete list. Enter retains an available current selection.
When registering an inventory, a lone already named compatible transposer is reused
automatically. Otherwise, choose the transposer first. A separate numbered menu then
asks which attached inventory serves the named role (Interface, alveary, analyser, etc.).
Select its inventory menu number, not its world-side number; directions and contents
are identification hints. Empty inventories can be selected. `R` refreshes this
inventory menu without returning to transposer selection. The saved side remains
the actual world direction, so existing configuration remains compatible.
Transposer previews show world sides, inventory sizes and up to two occupied slots
per inventory. Use a distinctive item in a previewed slot to identify a chest, then
refresh; previews never move items. Full method documentation is available separately
through `Beeomatic doctor --probe` and is not printed during normal setup.
Component-picker and inventory headings use cyan on colour terminals, restoring
the previous text colour immediately afterward. Monochrome terminals retain `==`
heading markers. ME Interface setup asks for the network reader and dedicated
database once, then binds a local Interface to each alveary's known transposer.
Each port uses stock slots 1/2 and unconfigured return slot 9. The shared scanner
has a separate Interface and transposer on the same ME network.
The scanner transposer touches an input chest. Your pipes draw bees from the chest
through the analyser and return analysed bees directly to an unconfigured Interface
slot. Setup asks for no output inventory, analyser slots or scanner confirmation.
After upgrading program files, reboot the OpenComputer before testing to clear
OpenOS's cached application modules.

Register each Interface port, housing, transposer view and operating environment.
Direct Forestry alveary slots are fixed automatically: princess/queen 1, drone 2,
outputs 3-9. No native slot-number or output-map questions are asked. Read-only
placement checks use one manually placed bee at a time to associate the inventory
with its housing adapter; analysis is not required for these checks. Failed reads
explain what was found and retry without exiting setup. Custom routed staging
slots, climate and route isolation still require explicit configuration/verification.
Setup asks for working temperature/humidity. It does not ask for sky access,
biome, dimension, flower-provider IDs, day/night scheduling, lighting or rain shields.
The infrastructure guide expects Alveary Lighting and a Rain Shield for continuous operation.
Beeomatic displays
the current bees' required flower types beside each alveary in foreground/status
output. Supply those flowers physically; no manually maintained flower list is used.

Setup saves completed sections and each alveary registration stage. Type `back`
to revisit the previous stage/section. If interrupted, run `setup` again; an
unfinished `alveary add` also resumes its saved registration.
Use `setup --reconfigure` to repeat the stages while retaining existing machines;
use `alveary add` to add a machine independently. To correct a registered machine's
slot or climate mapping, stop the worker and edit `data/config.lua`, or remove its
idle registration and register it again. Back up the data directory before edits.
The sample `config.example.lua` is deliberately unverified and is not installed as
a working configuration.

You need hive stock for leaf species that have no mutation parents. Beeomatic
cannot create a princess from drones. Supply spare princesses in addition to each
species' protected breeding princess, and at least two drones of each needed exact
genotype. The planner automatically schedules conversions and population jobs
where those resources permit them. Its default policy keeps one pure princess per
species and one useful drone per genotype, so an operation can pause for spare
stock even when it could make progress by risking the last reserve.

For ME Interfaces, follow [HARDWARE.md](HARDWARE.md). Your server must expose exact
compressed item NBT (`allowItemStackNBTTags=true`). Use real ME storage cells, a
dedicated OC database, one full-block Interface per alveary and one shared scanner.
Supply honey/power separately. On each start/resume, `PREPARING_STOCK` physically
inspects unknown variants and analyses all initial drones before dispatch.
Temporary raw offspring in AE remain unavailable until inspected/analysed.

After setup, test every saved port with at least two identical analysed drones
available in ME:

```sh
Beeomatic doctor --interface port_temperate
Beeomatic doctor --interface scanner_port
```

Substitute your actual IDs. The probe returns all test drones and checks the exact
ME count. Verify the shared analyser separately, then complete the acceptance
steps in [VALIDATION.md](VALIDATION.md) before valuable breeding work.

## Migrating an existing export-bus installation

Existing `storage.kind="ae2"` configurations keep their working compatibility
backend. No automatic conversion of saved jobs or transfer journals occurs.

1. Finish or drain old work with the existing hardware connected. Use `doctor`
   to reconcile pending exports/movements; resolve reserved machines and scanner
   batches. Do not remove the old gate/export buffer while their journal is pending.
2. Stop the worker and back up `data/`, including `.bak` files. Update and reboot.
3. Build the Interface ports and one shared scanner station. Run
   `Beeomatic setup --reconfigure`, select `me`, and register the new local port
   for each existing alveary. Housing slots/climate registrations are retained.
   Old scanner/template settings are reset because their archive references do
   not apply to the new topology. Interrupted port remapping resumes on rerun.
4. Test ports/scanner, then start a job. Initial drone preparation runs before
   breeding. Legacy export hardware can be retired after its old work is reconciled.

Reconfiguration refuses unresolved movements, scanner requests or owned batches.
An explicit completed drain releases idle logical ME lineage reservations. Old
export/redstone prompts have been removed from setup. The legacy modules remain
only to run/recover saved old configurations; see [legacy hardware](LEGACY_AE2.md).
The installer retires the unused base-contract modules and standalone probe,
keeping `.previous` backups. It preserves user data and unrelated files.
