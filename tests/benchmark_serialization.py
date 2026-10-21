"""PC-only comparison: python tests/benchmark_serialization.py (requires Lupa)."""
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools'))
from lupa.lua52 import LuaRuntime
from lupa.lua53 import LuaRuntime as Lua53Runtime

os.chdir(ROOT)
for version, runtime in [('5.2', LuaRuntime), ('5.3', Lua53Runtime)]:
    print(f'Lua {version}; 70 serializations per case (local CPU time)', flush=True)
    runtime().execute('''
      local U=require("lib.util"); local N=require("lib.nbt")
      local W=require("tests.mocks.world"); local F=require("tests.fixtures.nbt")
      local catalogue={aeCatalog={},jobs={{state="RUNNING",cycles=1}}}
      local nbt=N.sort(F.dynamicRaw)
      for n=1,11 do
        local identity=U.encode({name="Forestry:beeDroneGE",damage=n,nbt=nbt})
        catalogue.aeCatalog[identity]=W.bee("Forest","drone",8).individual
      end
      local parts,seed={},17
      for n=1,480 do
        local block={}
        for i=1,512 do seed=seed*48271%2147483647; block[i]=string.char(32+seed%95) end
        parts[n]=table.concat(block)
      end
      local unique={tag=table.concat(parts)}; parts=nil
      local function measure(value,cached)
        local cache=cached and U.stringCache() or nil
        local native=string.gsub; local escaped=0
        string.gsub=function(s,...) escaped=escaped+#s; return native(s,...) end
        for _=1,70 do U.write(value,function() end,cache) end
        string.gsub=native
        local hits,misses,retained=cache and cache.hits or 0,cache and cache.misses or 0,cache and cache.bytes or 0
        cache=cached and U.stringCache() or nil
        collectgarbage("collect")
        local start=os.clock()
        for _=1,70 do U.write(value,function() end,cache) end
        return os.clock()-start,escaped,hits,misses,retained
      end
      for _,fixture in ipairs({{"shared NBT",catalogue},{"unique text",unique}}) do
        print(fixture[1]..": "..U.size(fixture[2]).." encoded bytes")
        for _,cached in ipairs({false,true}) do
          local seconds,escaped,hits,misses,retained=measure(fixture[2],cached)
          print(string.format("  %s: %.3fs; %d bytes escaped; %d hits, %d misses; %d accounted cache bytes",
            cached and "cached" or "uncached",seconds,escaped,hits,misses,retained))
        end
      end
    ''')
