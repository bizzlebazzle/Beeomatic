"""Run with Python + Lupa against OpenOS-compatible Lua 5.2 and Lua 5.3."""
import os
import pathlib
import sys
import tempfile
from resource_limits import check as check_startup, write_nbt_fixture

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools'))
from lupa.lua52 import LuaRuntime
from lupa.lua53 import LuaRuntime as Lua53Runtime

os.chdir(ROOT)
sources = [p for p in ROOT.rglob('*.lua') if not {'.tools', 'research', 'data'} & set(p.relative_to(ROOT).parts)]
for version, runtime in [('5.2', LuaRuntime), ('5.3', Lua53Runtime)]:
    lua = runtime(unpack_returned_tuples=True)
    for source in sources:
        lua.execute('assert(load(...))', source.read_text(encoding='utf-8'))
    print(f'Lua {version} syntax: {len(sources)} files', flush=True)
    lua.execute((ROOT / 'tests/run.lua').read_text(encoding='utf-8'))
    # Real allocator limit, not just timing or table-size mocks. The old giant
    # serialization buffer fails here; streaming save + reload fit.
    with tempfile.TemporaryDirectory(prefix='memory-', dir=ROOT / 'tests') as folder:
        limited = runtime(max_memory=2 * 1024 * 1024, unpack_returned_tuples=True)
        limited.execute('''
          package.path="./?.lua;"..package.path
          U=require("lib.util"); P=require("lib.persistence"); state={}
          for i=1,1600 do
            state[i]={tag=string.rep(string.char(i%256),500)..i,
              genome={species="Forest",fertility=3}}
          end
          collectgarbage("collect")
          local oldSucceeded=pcall(U.encode,state)
          assert(not oldSucceeded,"fixture must reproduce the old memory failure")
          collectgarbage("collect")
          store=P.new(...,{exists=function() return false end,
            rename=function(a,b) return os.rename(a,b) end})
          store:save(state)
          state=nil; collectgarbage("collect")
          local restored=assert(store:readFile(store.path))
          assert(#restored==1600)
          for i=1,1600 do
            assert(restored[i].tag==string.rep(string.char(i%256),500)..i)
            assert(restored[i].genome.fertility==3)
          end
        ''', str(pathlib.Path(folder) / 'state.lua'))
        print(f'Lua {version}: 1,600 records saved and reloaded within 2 MiB; old encoder exhausted memory', flush=True)
        buffered = runtime(max_memory=2 * 1024 * 1024, unpack_returned_tuples=True)
        nbt_path = pathlib.Path(folder) / 'nbt-cache.bin'
        write_nbt_fixture(nbt_path)
        buffered.execute('''
          local reserve=string.rep("O",384*1024)
          local U=require("lib.util"); local P=require("lib.persistence")
          package.loaded.computer={freeMemory=function()
            return 2*1024*1024-collectgarbage("count")*1024
          end}
          local chunks={}
          for n=1,663 do chunks[n]=string.rep(string.char(n%256),512) end
          local state={tag=table.concat(chunks):sub(1,339000)}; chunks=nil
          collectgarbage("collect") -- release fixture-construction temporaries
          collectgarbage=nil -- automatic collection must suffice for saves and reload
          local nbt=require("tests.fixtures.nbt_cache")(select(2,...))
          local write=U.write; local calls=0
          U.write=function(...) calls=calls+1; return write(...) end
          local store=P.new(...,{exists=function(path)
              local f=io.open(path,"rb"); if f then f:close(); return true end; return false
            end,remove=os.remove,rename=os.rename})
          store:save(state)
          assert(calls==1,"server-sized checkpoint must encode only once")
          assert(store.cache.bytes>250000 and store.cache.bytes<=262144,"fixture must fill the bounded cache")
          store:save(state)
          assert(calls==2,"second checkpoint must still encode only once")
          assert(store:load({}).tag==state.tag)
          assert(nbt.cache.bytes>125000)
          assert(#reserve==384*1024)
        ''', str(pathlib.Path(folder) / 'buffered.lua'), str(nbt_path))
        print(f'Lua {version}: repeated 339 KB checkpoints with full encoding and NBT caches fit 2 MiB with 384 KiB host reserve', flush=True)
    check_startup(runtime, ROOT, version)
