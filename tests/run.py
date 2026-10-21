"""Run with Python + Lupa against OpenOS-compatible Lua 5.2 and Lua 5.3."""
import os
import pathlib
import sys
import tempfile
from resource_limits import check as check_startup

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
        buffered.execute('''
          local reserve=string.rep("O",384*1024)
          local U=require("lib.util"); local P=require("lib.persistence")
          package.loaded.computer={freeMemory=function()
            return 2*1024*1024-collectgarbage("count")*1024
          end}
          local state={tag=string.rep("x",339000)}
          collectgarbage("collect") -- release fixture-construction temporaries
          local write=U.write; local calls=0
          U.write=function(...) calls=calls+1; return write(...) end
          local store=P.new(...,{exists=function() return false end,
            rename=function(a,b) return os.rename(a,b) end})
          store:save(state)
          assert(calls==1,"server-sized checkpoint must encode only once")
          assert(store:load({}).tag==state.tag)
          assert(#reserve==384*1024)
        ''', str(pathlib.Path(folder) / 'buffered.lua'))
        print(f'Lua {version}: 339 KB streaming checkpoint encodes once within 2 MiB with 384 KiB host reserve', flush=True)
    check_startup(runtime, ROOT, version)
