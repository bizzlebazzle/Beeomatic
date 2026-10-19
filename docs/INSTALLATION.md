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

The compact release contains 30 files, approximately **104 KiB of file contents**
before filesystem allocation overhead. This includes all application modules,
`install.lua` and `manifest.lua`. It excludes documentation, tests, mocks, research,
the example configuration, the repository launcher, the separate robot helper and
the redundant standalone probe (use `Beeomatic doctor --probe`). The downloaded
`/home/get.lua` bootstrap remains separate. All tests run on the development PC
before pushing; they are not needed on the OpenComputer. Documentation remains on
GitHub. Download staging and one previous installed generation require additional
temporary disk space, and runtime data grows with use. A second drive is not
required for the program files themselves.

To select a specific revision instead, run `lua get.lua FULL_COMMIT_SHA`.
An optional second argument selects an absolute installation directory.
Download uses GitHub's public API and raw file host; server Internet Card policy
must permit both `api.github.com` and `raw.githubusercontent.com`.
Complete hardware acceptance before starting a valuable breeding job.

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

`setup` shows every detected component address and available method. Select full
addresses, then register a physical archive, each housing, its transposer view,
actual slot roles and operating environment. The wizard performs read-only input
witness checks using test stock that you place manually. It never inserts test
bees automatically. Output mapping, climate, route isolation and environmental
facts require explicit in-game verification and are marked unverified until then.

Setup saves completed sections as it progresses. If interrupted, run `setup` again.
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

For AE2, follow [HARDWARE.md](HARDWARE.md) before selecting that backend. Your server
must expose exact compressed item NBT (`allowItemStackNBTTags=true`) for autonomous
network export. Chest-only operation does not require AE2 or that server setting.
The tested Beta 3 imperative export callback is broken; setup's default redstone
mode uses ordinary AE2 export with a verified OC Redstone Card circuit and a
receipt-based wait. Configure a longer timeout if an unaccelerated bus needs it.

After installation, complete the release-specific in-game acceptance procedure in
[VALIDATION.md](VALIDATION.md). Automated tests validate program behavior against
mocks; they do not certify an actual Minecraft installation.
