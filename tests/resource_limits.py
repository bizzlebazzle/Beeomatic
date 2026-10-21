"""Full startup allocation test, including OpenOS-style source concatenation."""
import pathlib
import tempfile
import gzip
import random
import struct


def write_nbt_fixture(path):
    rng = random.Random(17)
    with path.open("wb") as output:
        for _ in range(160):
            raw = b"\x0a\0\0\x07\0\x01x" + struct.pack(">I", 900) + rng.randbytes(900) + b"\0"
            tag = gzip.compress(raw, mtime=0)
            output.write(struct.pack(">H", len(tag)) + tag)


def check_planning(runtime, root, version, variants=80):
    with tempfile.TemporaryDirectory(prefix="planning-", dir=root / "tests") as folder:
        path = pathlib.Path(folder)
        (path / "data").mkdir()
        write_nbt_fixture(path / "nbt-cache.bin")
        seed = runtime(unpack_returned_tuples=True)
        seed.execute('''
          local root,variants=...
          local W=require("tests.mocks.world"); local ME=require("tests.mocks.me")
          local U=require("lib.util"); local B=require("lib.bees"); local w=ME.new()
          local stock={Princess={},Drone={},Queen={}}
          for n=1,variants do
            local species=n%2==0 and "Forest" or "Meadows"
            local kind=n<3 and "princess" or "drone"
            local s=ME.bee(species,kind,kind=="drone" and 64 or 1,false,{lifespan=n})
            s.tag=string.rep(string.char(n%256),600)..n
            w.state.aeCatalog[B.identity(s)]=s.individual; s.individual=nil
            local caste=kind=="drone" and "Drone" or "Princess"
            stock[caste][#stock[caste]+1]=s
          end
          local function write(name,value)
            local f=assert(io.open(root.."/"..name,"wb"))
            U.write(value,function(chunk) assert(f:write(chunk)) end); f:close()
          end
          write("data/config.lua",w.c)
          write("data/catalogue.lua",w.state.aeCatalog); w.state.aeCatalog=nil
          w.state.pendingRequest={target="spirit",mode="breed",flags={}}
          write("data/state.lua",w.state)
          for caste,items in pairs(stock) do write(caste..".lua",items) end
        ''', path.as_posix(), variants)
        initial = {p.name: p.read_bytes() for p in (path / "data").iterdir()}
        source = (root / "tests/resource_limits.lua").read_text(encoding="utf-8")
        for command, scenario in (("breed", True), ("resume", True), ("resume", "rebreed")):
            for file in (path / "data").iterdir():
                file.unlink()
            for name, data in initial.items():
                (path / "data" / name).write_bytes(data)
            if command == "breed":
                (path / "data/state.lua").write_text('return {jobs={},reservations={},transactions={}}')
            elif scenario == "rebreed":
                (path / "data/state.lua").write_text('''return {reservations={},transactions={},jobs={
                  {id="job1",species="spirit",mode="convert",state="WAITING",cycles=0,confirmed=0,dependencies={}}}}''')
            limited = runtime(max_memory=2 * 1024 * 1024, unpack_returned_tuples=True)
            limited.globals().disk_used = lambda: sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) + 768 * 1024
            _, live_kib = limited.execute(source, path.as_posix(), True, "missing", command, False, False, scenario)
            print(f"Lua {version}: Spirit {command}{' saved conversion' if scenario == 'rebreed' else ''} planned with {variants} known bee variants "
                  f"within 2 MiB; live {live_kib:.0f} KiB", flush=True)


def check(runtime, root, version):
    with tempfile.TemporaryDirectory(prefix="startup-", dir=root / "tests") as folder:
        path = pathlib.Path(folder)
        (path / "data").mkdir()
        write_nbt_fixture(path / "nbt-cache.bin")
        seed = runtime(unpack_returned_tuples=True)
        seed.execute('''
          package.path="./?.lua;"..package.path
          local root=...
          local W=require("tests.mocks.world"); local ME=require("tests.mocks.me")
          local U=require("lib.util"); local w=ME.new()
          for n=1,6 do W.job(w,"job"..n,"Spirit","convert") end
          for n=1,64 do
            local s=ME.bee("Forest","drone",8); s.tag=string.rep(string.char(32+n),12000)..n
            local identity=require("lib.bees").identity(s)
            w.state.transactions[n]={id=n,phase="COMMITTED",owner="old",count=8,
              source=w.c.scanner.storage,dest=w.c.scanner.input,slot=1,destSlot=1,
              identity=identity,stack=U.copy(s)}
            if n<=16 then w.state.aeCatalog[identity]=U.copy(s.individual) end
          end
          local function write(name,value)
            local f=assert(io.open(root.."/data/"..name,"wb"))
            U.write(value,function(chunk) assert(f:write(chunk)) end); f:close()
          end
          write("config.lua",w.c); write("state.lua",w.state)
        ''', str(path).replace("\\", "/"))
        legacy = (path / "data/state.lua").read_bytes()
        source = (root / "tests/resource_limits.lua").read_text(encoding="utf-8")
        control = runtime(max_memory=2 * 1024 * 1024, unpack_returned_tuples=True)
        try:
            control.execute(source, str(path).replace("\\", "/"), False)
        except MemoryError:
            pass
        else:
            raise AssertionError("legacy receipt fixture must exceed 2 MiB")
        installed = sum((root / p).stat().st_size for p in seed.eval('assert(loadfile("manifest.lua"))()').values())
        for mode, command, profile, large_network in (("missing", "resume", False, False), ("disabled", "resume", False, False),
                                      ("missing", "cancel", False, False), ("disabled", "cancel", False, False),
                                      ("missing", "resume", True, False), ("disabled", "resume", True, False),
                                      ("missing", "resume", False, True), ("disabled", "resume", True, True)):
            for file in (path / "data").iterdir():
                if file.name != "config.lua":
                    file.unlink()
            (path / "data/state.lua").write_bytes(legacy)
            limited = runtime(max_memory=2 * 1024 * 1024, unpack_returned_tuples=True)
            peak_disk = 0
            def disk_used():
                nonlocal peak_disk
                used = sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) + 2 * installed + 256 * 1024
                peak_disk = max(peak_disk, used)
                return used
            limited.globals().disk_used = disk_used
            _, live_kib = limited.execute(source, path.as_posix(), True, mode, command, profile, large_network)
            current = (path / "data/state.lua").stat().st_size
            catalogue_path = path / "data/catalogue.lua"
            catalogue = catalogue_path.stat().st_size if catalogue_path.exists() else 0
            # Cancel retains the known-genome catalogue without querying broken
            # hardware; resume can prune entries proven absent from live stock.
            ratio = 0.5 if command == "resume" else 0.65
            assert current + catalogue < len(legacy) * ratio, (current, catalogue, len(legacy))
            assert peak_disk < 4 * 1024 * 1024, peak_disk
            print(f"Lua {version}: full ME {command}{' --profile' if profile else ''}{' with 219 bee variants + 3,000 unrelated types' if large_network else ''} with collectgarbage {mode} fits 2 MiB "
                  f"with 384 KiB host reserve; live {live_kib:.0f} KiB; "
                  f"checkpoint {len(legacy):,} -> {current:,} bytes; "
                  f"catalogue {catalogue:,} bytes; "
                  f"disk fixture peak {peak_disk:,}/4,194,304 bytes", flush=True)
