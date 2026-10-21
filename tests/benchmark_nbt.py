"""PC-only NBT cache comparison: python tests/benchmark_nbt.py [state.lua or catalogue.lua]."""
import gzip
import os
import pathlib
import random
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools'))
from lupa.lua52 import LuaRuntime
from lupa.lua53 import LuaRuntime as Lua53Runtime

path = str(pathlib.Path(sys.argv[1]).resolve()) if len(sys.argv) > 1 else None
os.chdir(ROOT)
if path:
    # Parse the save and each identity as data, never as executable Lua.
    raw = LuaRuntime(encoding=None).execute(b'''
      local P=require("lib.persistence"); local C=require("lib.state_codec")
      local state=assert(P.new(...,{}):readFile(...)); local tags={}
      for key in pairs(state.aeCatalog or state) do
        if type(key)=="string" and key:sub(1,1)=="{" then
          local supplied=false
          local identity=C.read(function()
            if not supplied then supplied=true; return "return "..key end
          end)
          if identity.nbt then tags[#tags+1]=identity.nbt end
        end
      end
      return tags
    ''', path.encode()).values()
    raw = list(raw)
    if not raw:
        raise SystemExit('No canonical catalogue identities; pass the matching catalogue.lua or an older inline save.')
else:
    rng = random.Random(17)
    raw = []
    for n in range(80):
        text = str(n).encode() + bytes(rng.choice(b'ACGT') for _ in range(900))
        raw.append(b'\x0a\0\0\x08\0\x01x' + struct.pack('>H', len(text)) + text + b'\0')

tags = [gzip.compress(value, mtime=0) for value in raw]
source = (ROOT / 'lib/nbt.lua').read_bytes()
assert b'#queue>=128' in source and b'limit=131072' in source
print(f'{len(tags)} recompressed tags; 30 passes; local CPU time (not in-game elapsed time)', flush=True)
for version, runtime in [('5.2', LuaRuntime), ('5.3', Lua53Runtime)]:
    for entries, limit in [(16, 65536), (128, 131072)]:
        # Compare the bounds with the same implementation/counter overhead.
        candidate = source.replace(b'#queue>=128', f'#queue>={entries}'.encode()).replace(
            b'limit=131072', f'limit={limit}'.encode())
        lua = runtime(encoding=None, unpack_returned_tuples=True)
        lua.execute(b'package.preload["lib.nbt"]=assert(load(...))', candidate)
        seconds, hits, misses, evictions, retained = lua.execute(b'''
          local tags,expected=...; local N=require("lib.nbt")
          local start=os.clock()
          for pass=1,30 do for n,tag in ipairs(tags) do
            assert(N.canonical(tag)==expected[n],"canonical bytes changed")
          end end
          return os.clock()-start,N.cache.hits,N.cache.misses,N.cache.evictions,N.cache.bytes
        ''', lua.table_from(tags), lua.table_from(raw))
        print(f'Lua {version}, {entries} entries/{limit//1024} KiB: {seconds:.3f}s; '
              f'{hits} hits, {misses} misses, {evictions} evictions; {retained} accounted bytes', flush=True)
