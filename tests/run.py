"""Run with Python + Lupa against OpenOS-compatible Lua 5.2 and Lua 5.3."""
import os
import pathlib
import sys
import tempfile
from resource_limits import check as check_startup, check_planning, write_nbt_fixture

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
          local hostGC=collectgarbage
          package.loaded.computer={freeMemory=function()
            return 2*1024*1024-hostGC("count")*1024
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
          assert(store.cache.bytes>0 and store.cache.bytes<=store.cache.limit and store.cache.limit<=262144,
            "encoding cache exceeded available-memory budget")
          store:save(state)
          assert(calls==2,"second checkpoint must still encode only once")
          assert(store:load({}).tag==state.tag)
          assert(nbt.cache.bytes>125000)
          assert(#reserve==384*1024)
        ''', str(pathlib.Path(folder) / 'buffered.lua'), str(nbt_path))
        print(f'Lua {version}: repeated 339 KB checkpoints with full encoding and NBT caches fit 2 MiB with 384 KiB host reserve', flush=True)
        recovery = runtime(max_memory=2 * 1024 * 1024, unpack_returned_tuples=True)
        recovery.execute('''
          local reserve=string.rep("O",384*1024)
          local cache=require("tests.fixtures.nbt_cache")(...)
          local U=require("lib.util")
          function eq(a,b) assert(U.equal(a,b),tostring(a).." ~= "..tostring(b)) end
          function ok(value,message) assert(value,message) end
          local count=0
          function test(name,fn)
            if name:match("^saved blocked conversion rebreeds") or name:match("^automatic rebreeding adds prerequisite") then
              fn(); count=count+1
            end
          end
          -- Include OpenOS's complete source concatenation at load time.
          local native=package.searchers[2]
          package.searchers[2]=function(name)
            if name:sub(1,4)~="lib." then return native(name) end
            local f=assert(io.open(name:gsub("%.","/")..".lua","rb")); local chunks={}
            while true do local chunk=f:read(1024); if not chunk then break end; chunks[#chunks+1]=chunk end
            f:close(); return assert(load(table.concat(chunks),"="..name,"t",_G))
          end
          collectgarbage=nil
          require("tests.test_integration")
          assert(count==2 and #reserve==384*1024 and cache.cache.bytes>125000)
        ''', str(nbt_path))
        print(f'Lua {version}: mutation recovery, prerequisite expansion and restart fit 2 MiB with full NBT cache and 384 KiB host reserve', flush=True)
        scanning = runtime(max_memory=2 * 1024 * 1024, unpack_returned_tuples=True)
        scanning.execute('''
          local reserve=string.rep("O",384*1024)
          local nbt=require("tests.fixtures.nbt_cache")(...)
          local U=require("lib.util"); local nativeGC=collectgarbage
          function eq(a,b,message) assert(U.equal(a,b),message or (tostring(a).." ~= "..tostring(b))) end
          function ok(v,message) assert(v,message) end
          local count=0
          function test(name,fn)
            if name=="plan scanning defers mutation modules and releases stock between snapshots" or
              name=="foreground worker stays alive through lunar waits and starts when the phase changes" then
              collectgarbage=nil; fn(); count=count+1
            end
          end
          local native=package.searchers[2]
          package.searchers[2]=function(name)
            if name:sub(1,4)~="lib." then return native(name) end
            local f=assert(io.open(name:gsub("%.","/")..".lua","rb")); local chunks={}
            while true do local chunk=f:read(1024); if not chunk then break end; chunks[#chunks+1]=chunk end
            f:close(); return assert(load(table.concat(chunks),"="..name,"t",_G))
          end
          nativeGC("collect")
          require("tests.test_cli")
          assert(count==2 and #reserve==384*1024 and nbt.cache.bytes>125000)
        ''', str(nbt_path))
        print(f'Lua {version}: standalone plan scans/plans with 24 known variants; lunar wait/start/restart fits 2 MiB with full NBT cache, 384 KiB host reserve and no manual GC', flush=True)
    check_startup(runtime, ROOT, version)
    check_planning(runtime, ROOT, version)
