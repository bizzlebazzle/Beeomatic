"""Full startup allocation test, including OpenOS-style source concatenation."""
import pathlib
import tempfile


def check(runtime, root, version):
    with tempfile.TemporaryDirectory(prefix="startup-", dir=root / "tests") as folder:
        path = pathlib.Path(folder)
        (path / "data").mkdir()
        seed = runtime(unpack_returned_tuples=True)
        seed.execute('''
          package.path="./?.lua;"..package.path
          local root=...
          local W=require("tests.mocks.world"); local ME=require("tests.mocks.me")
          local U=require("lib.util"); local w=ME.new()
          w.c.scanner.mode="external"; w.c.scanner.output=nil; w.c.scanner.outputSlots=nil
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
        limited = runtime(max_memory=2 * 1024 * 1024, unpack_returned_tuples=True)
        installed = sum((root / p).stat().st_size for p in seed.eval('assert(loadfile("manifest.lua"))()').values())
        peak_disk = 0
        def disk_used():
            nonlocal peak_disk
            used = sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) + 2 * installed + 256 * 1024
            peak_disk = max(peak_disk, used)
            return used
        limited.globals().disk_used = disk_used
        _, live_kib = limited.execute(source, str(path).replace("\\", "/"), True)
        current = (path / "data/state.lua").stat().st_size
        assert current < len(legacy) / 2, (current, len(legacy))
        # Include installer files and their previous generation in the disk budget.
        assert peak_disk < 4 * 1024 * 1024, peak_disk
        print(f"Lua {version}: full ME resume fits 2 MiB with 384 KiB host reserve; "
              f"live {live_kib:.0f} KiB; checkpoint {len(legacy):,} -> {current:,} bytes; "
              f"disk fixture peak {peak_disk:,}/4,194,304 bytes", flush=True)
