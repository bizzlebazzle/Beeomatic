local U=require("lib.util"); local P=require("lib.persistence")
local W=require("tests.mocks.world"); local O=require("tests.mocks.openos")

test("split catalogue migrates legacy saves and writes only changed genomes",function()
  local w=W.new(); w:build()
  O.with(w,function(files,_,fs)
    local path,cat="/state.lua","/catalogue.lua"
    local value={aeCatalog={old=W.bee("Forest","drone").individual},jobs={{cycles=1}}}
    files[path]="return "..U.encode(value); files[cat]="return {stale=true}"
    local store=P.new(path,fs,nil,nil,cat); local loaded=store:load({})
    eq(loaded,value); eq(files[cat],"return {stale=true}") -- no migration writes during loading
    local open=io.open; local writes=0
    io.open=function(name,mode)
      if name==cat..".tmp" and mode=="wb" then writes=writes+1 end
      return open(name,mode)
    end
    store:save(loaded); eq(writes,1); eq(store.cache,store.catalogue.cache)
    eq(assert(load(files[path]))().aeCatalog,nil); eq(assert(load(files[cat]))(),value.aeCatalog)
    eq(loaded,value) -- serialization leaves the live catalogue attached
    for n=2,20 do loaded.jobs[1].cycles=n; store:save(loaded) end
    loaded.aeCatalog.old=U.copy(loaded.aeCatalog.old); store:save(loaded)
    eq(writes,1,"unchanged replacement genomes must not rewrite the catalogue")
    loaded.aeCatalog.new=W.bee("Spirit","drone").individual; store:save(loaded); eq(writes,2)
    loaded.aeCatalog.new=U.copy(loaded.aeCatalog.new)
    loaded.aeCatalog.new.active.fertility=4; store:save(loaded); eq(writes,3)
    loaded.aeCatalog.old=nil; store:save(loaded); eq(writes,4)
    local reopened=P.new(path,fs,nil,nil,cat); local restored=reopened:load({})
    eq(restored,loaded); reopened:save(restored); eq(writes,4)
    io.open=open
  end)
end)

test("split catalogue failures preserve recovery state and can retry without dropping live genes",function()
  for _,failure in ipairs({"catalogue","state"}) do
    local w=W.new(); w:build()
    O.with(w,function(files,_,fs)
      local path,cat="/state.lua","/catalogue.lua"
      local store=P.new(path,fs,nil,nil,cat)
      local value={aeCatalog={old={ident="forest"}},pending={identity="old",count=1}}
      store:save(value)
      local primary,backup=files[path],files[path..".bak"]
      value.aeCatalog.new={ident="spirit"}; value.pending.identity="new"
      local open=io.open
      io.open=function(name,mode)
        local f,why=open(name,mode)
        if f and name==(failure=="catalogue" and cat or path)..".tmp" and mode=="wb" then
          f.flush=function() return nil,"disk failure" end
        end
        return f,why
      end
      raises(function() store:save(value) end,"disk failure")
      io.open=open
      eq(files[path],primary); eq(files[path..".bak"],backup)
      eq(value.aeCatalog.new.ident,"spirit")
      local restored=P.new(path,fs,nil,nil,cat):load({})
      eq(restored.pending,{identity="old",count=1})
      if failure=="state" then eq(restored.aeCatalog.new.ident,"spirit") end
      store:save(value); eq(P.new(path,fs,nil,nil,cat):load({}),value)
    end)
  end
end)

test("split catalogue restores backups and keeps inline legacy fallback authoritative",function()
  local w=W.new(); w:build()
  O.with(w,function(files,_,fs)
    local path,cat="/state.lua","/catalogue.lua"
    files[path]="return {jobs={}}"; files[cat]="broken"
    files[cat..".bak"]='return {forest={ident="forest"}}'
    local restored=P.new(path,fs,nil,nil,cat):load({})
    eq(restored.aeCatalog.forest.ident,"forest")
    -- A recovered catalogue's marker belongs to the file loader, not the index.
    eq(restored.aeCatalog.recoveredBackup,nil)
    files[path]="broken"; files[path..".bak"]='return {aeCatalog={legacy={ident="old"}}}'
    local store=P.new(path,fs,nil,nil,cat); restored=store:load({})
    eq(restored.aeCatalog,{legacy={ident="old"}}); ok(restored.recoveredBackup)
    store:save(restored); eq(assert(load(files[cat]))(),restored.aeCatalog)
    files[cat]=nil; files[cat..".bak"]=nil
    eq(P.new(path,fs,nil,nil,cat):load({}).aeCatalog,{})
  end)
end)

test("checkpoint yields during streaming writes under a simulated watchdog",function()
  for _,free in ipairs({1360217,524288}) do
    local w=W.new(); w:build()
    O.with(w,function(files,_,fs)
      local now,lastYield,phase=0,0,"encode"; local yields={}
      local function work()
        now=now+0.1
        assert(now-lastYield<1,"too long without yielding")
      end
      local computer=require("computer")
      computer.uptime=function() return now end
      computer.freeMemory=function() return free end
      local sleep,write,open=os.sleep,U.write,io.open
      os.sleep=function(seconds)
        ok(seconds>0); yields[phase]=(yields[phase] or 0)+1
        coroutine.yield("watchdog"); lastYield=now
      end
      U.write=function(value,sink,cache)
        return write(value,function(chunk) work(); sink(chunk) end,cache)
      end
      io.open=function(path,mode)
        local f,why=open(path,mode)
        if f then
          local writing=f.write
          f.write=function(self,...) phase="write"; work(); return writing(self,...) end
        end
        return f,why
      end
      local data={tag=string.rep("x",339000)}
      local thread=coroutine.create(function() P.new("/state.lua",fs):save(data) end)
      local success,why
      repeat
        success,why=coroutine.resume(thread)
      until not success or coroutine.status(thread)=="dead"
      os.sleep,U.write,io.open=sleep,write,open
      ok(success,why)
      for _,name in ipairs({"encode","write"}) do ok((yields[name] or 0)>0,name) end
      eq(P.new("/state.lua",fs):load({}),data)
    end)
  end
end)

test("cached string pieces preserve binary bytes and reflect table and identity changes",function()
  local bytes={}; for i=0,255 do bytes[#bytes+1]=string.char(i) end
  local binary=table.concat(bytes):rep(12)
  local value={[binary]={tag=binary,cycles=1},pending={identity=binary},jobs={{state="RUNNING"}}}
  local cache=U.stringCache()
  local function encode(cached)
    local chunks={}
    U.write(value,function(chunk) ok(#chunk<=4096); chunks[#chunks+1]=chunk end,cached)
    return table.concat(chunks)
  end
  local original=encode(); eq(encode(cache),original)
  local misses=cache.misses; eq(encode(cache),original); eq(cache.misses,misses); ok(cache.hits>0)
  value[binary].cycles=2; value[binary].tag=binary.."changed\0"
  value.pending.identity=binary.."new variant"; value.jobs[1].state="PAUSED"
  local updated=encode(cache); eq(updated,encode())
  eq(assert(load(updated,"=cached","t",{}))(),value)
end)

test("string cache evicts old pieces and remains bounded under changing stock",function()
  local cache=U.stringCache(); local value={}
  for n=1,240 do
    value.tag=string.rep(string.char(n),512).."tail"
    U.write(value,function() end,cache)
    ok(cache.bytes<=262144); ok(#cache.queue<=256)
  end
  local bytes,entries=0,0
  for key,encoded in pairs(cache.values) do
    ok(#key<=512); bytes=bytes+#key+#encoded+128; entries=entries+1
  end
  eq(bytes,cache.bytes); eq(entries,#cache.queue)
  eq(cache.values[string.rep(string.char(1),512)],nil)
  local misses=cache.misses; value.tag=string.rep(string.char(1),512).."tail"
  local chunks={}; U.write(value,function(chunk) chunks[#chunks+1]=chunk end,cache)
  ok(cache.misses>misses); eq(assert(load(table.concat(chunks),"=evicted","t",{}))(),value)
end)

test("persistence reuses its encoding cache between saves without persisting cache data",function()
  local w=W.new(); w:build()
  O.with(w,function(files,_,fs)
    local store=P.new("/state.lua",fs); local value={tag=string.rep("\0\255\\\"",1400),job={cycles=1}}
    store:save(value); local misses=store.cache.misses
    value.job.cycles=2; store:save(value)
    eq(store.cache.misses,misses); ok(store.cache.hits>0); ok(store.cache.reused>#value.tag)
    local cache=store.cache; local hits=cache.hits
    eq(store:load({}),value); eq(assert(load(files["/state.lua"]))(),value)
    eq(store.cache,cache); eq(cache.hits,hits) -- profile keeps the same counters
    eq(cache.bytes,0); eq(cache.values,{}); eq(cache.queue,{})
    eq(P.new("/other.lua",fs).cache.hits,0)
  end)
end)

test("checkpoint byte count matches serialization for all bytes keys and scalar types",function()
  local bytes={}; for i=0,255 do bytes[#bytes+1]=string.char(i) end
  local binary=table.concat(bytes):rep(9)
  for _,value in ipairs({{}, {binary=binary,[binary]=false,[false]=true,[3.5]=-1.25e30,
    nested={empty="",zero=0}}, {boundary=string.rep("\\",513).."\0\127\255"}}) do
    local actual=0; U.write(value,function(chunk) actual=actual+#chunk end)
    eq(U.size(value),actual)
  end
  raises(function() U.size({bad=function() end}) end,"cannot persist")
  raises(function() U.size({bad=math.huge}) end)
end)

test("state serialization avoids sorting while identity encoding remains deterministic",function()
  local value={z={second=2,first=1},a=false,[4]="four"}
  local keys=U.keys; U.keys=function() error("state must not sort keys") end
  local chunks={}
  local success,why=pcall(U.write,value,function(chunk) chunks[#chunks+1]=chunk end)
  U.keys=keys; ok(success,why)
  eq(assert(load(table.concat(chunks),"=state","t",{}))(),value)
  eq(U.encode({b=2,a=1}),'{["a"]=1,["b"]=2,}')
end)

test("checkpoints serialize once without measurement buffering or readback at any free RAM",function()
  local w=W.new(); w:build()
  O.with(w,function(files,_,fs)
    for _,free in ipairs({1360217,524288}) do
      require("computer").freeMemory=function() return free end
      local data={tag=string.rep("x",339000)}
      local write,size,open=U.write,U.size,io.open; local calls=0
      U.write=function(...) calls=calls+1; return write(...) end
      U.size=function() error("redundant size pass") end
      io.open=function(path,mode) eq(mode,"wb","save must not read back"); return open(path,mode) end
      local success,why=pcall(function() P.new("/state.lua",fs):save(data) end)
      U.write,U.size,io.open=write,size,open
      ok(success,why); eq(calls,1)
      eq(P.new("/state.lua",fs):load({}),data)
    end
  end)
end)

test("checkpoint serialization stays single pass across chunk and former buffer boundaries",function()
  local w=W.new(); w:build()
  O.with(w,function(files,_,fs)
    for _,length in ipairs({0,16363,16364,32000}) do
      local data={tag=string.rep("x",length)}; local calls=0; local write=U.write
      U.write=function(...) calls=calls+1; return write(...) end
      local success,why=pcall(function() P.new("/state.lua",fs):save(data) end)
      U.write=write; ok(success,why)
      eq(calls,1)
      eq(P.new("/state.lua",fs):load({}),data)
    end
  end)
end)

test("legacy and streamed state decode correctly across every byte boundary",function()
  local Codec=require("lib.state_codec")
  local bytes={}; for i=0,255 do bytes[#bytes+1]=string.char(i) end
  local data={jobs={},scan={phase="PROCESSING",tag=table.concat(bytes)},number=-1.25e30,flag=false}
  local chunks={}; U.write(data,function(s) chunks[#chunks+1]=s end)
  for _,source in ipairs({"return "..U.encode(data),table.concat(chunks)}) do
    local i=0
    local result=Codec.read(function() i=i+1; if i<=#source then return source:sub(i,i) end end)
    eq(result,data)
  end
end)

test("state loader tolerates yielding filesystem reads that fail inside load callbacks",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out,fs)
    local path="/project/data/state.lua"; local data={jobs={},scan={phase="PROCESSING",tag=string.rep("\0\255",5000)}}
    files[path]="return "..U.encode(data)
    local open=io.open
    io.open=function(name,mode)
      local f,why=open(name,mode)
      if f and name==path then
        eq(mode,"rb"); local read=f.read
        f.read=function(self,n) coroutine.yield("filesystem read"); return read(self,n) end
      end
      return f,why
    end
    local thread=coroutine.create(function() return P.new(path,fs):readFile(path) end)
    local yields=0; local result
    repeat
      local success,value=coroutine.resume(thread); ok(success,value)
      if coroutine.status(thread)=="dead" then result=value else yields=yields+1 end
    until coroutine.status(thread)=="dead"
    ok(yields>1); eq(result,data)
    local old=coroutine.create(function() return load(function() coroutine.yield("filesystem read"); return "return {}" end) end)
    local success,fn,why=coroutine.resume(old)
    ok(success); eq(fn,nil); ok(why:find("yield",1,true),why)
  end)
end)

test("state loader preserves both failures and uses a valid backup",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out,fs)
    local path="/project/data/state.lua"; local broken="return {jobs="
    files[path]=broken; files[path..".bak"]="return {jobs={},marker='backup'}"
    local state=P.new(path,fs):load({}); eq(state.marker,"backup"); ok(state.recoveredBackup)
    files[path..".bak"]="return {"
    local success,why=pcall(function() P.new(path,fs):load({}) end)
    eq(success,false); ok(why:find(path..": state data",1,true)); ok(why:find(path..".bak: state data",1,true))
    eq(files[path],broken); eq(files[path..".bak"],"return {")
  end)
end)

test("streaming persistence round trips binary strings across chunk boundaries",function()
  local bytes={}; for i=0,255 do bytes[#bytes+1]=string.char(i) end
  local binary=table.concat(bytes):rep(24)
  local value={[binary]={tag=binary,edge=string.rep("a",511).."\1".."23",yes=true,no=false,n=12.5}}
  local chunks={}; U.write(value,function(chunk) ok(#chunk<=4096); chunks[#chunks+1]=chunk end)
  eq(assert(load(table.concat(chunks),"=stream","t",{}))(),value)
end)

test("state saves round trip without loading another copy of state",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out,fs)
    local path="/project/data/state.lua"; local p=P.new(path,fs)
    local data={jobs={},large=string.rep("binary\0\255",5000)}
    p.readFile=function() error("save must not parse a second state table") end
    p:save(data)
    eq(assert(load(files[path],"=saved","t",{}))(),data)
    eq(P.new(path,fs):load({}),data)
  end)
end)

test("write and flush failures preserve the primary and backup generations",function()
  for _,failure in ipairs({"write","flush"}) do
    local w=W.new(); w:build()
    O.with(w,function(files,_,fs)
      local path="/state.lua"; files[path]="return {old=true}"; files[path..".bak"]="return {older=true}"
      local open=io.open
      io.open=function(name,mode)
        local f,why=open(name,mode)
        if f and name==path..".tmp" and mode=="wb" then
          f[failure]=function() return nil,"disk failure" end
        end
        return f,why
      end
      raises(function() P.new(path,fs):save({large=string.rep("x",20000)}) end,"disk failure")
      eq(files[path],"return {old=true}"); eq(files[path..".bak"],"return {older=true}")
    end)
  end
end)


test("loading legacy receipts drops completed stacks while pending recovery remains exact",function()
  local w=W.new(); w:addMachine("a"); w:build()
  local stack=W.bee("Forest","princess"); stack.tag=string.rep("legacy-nbt",300)
  local tx={id=1,owner="job",phase="COMMITTED",stack=stack,identity=require("lib.bees").identity(stack),
    source={id="a"},dest={id="hub"},slot=1,destSlot=2,count=1,transform={batchId="old"}}
  local value={transactions={U.copy(tx)},pending=U.copy(tx),scan={item={stack=U.copy(stack)}},
    reservations={slot={owner="job",identity=tx.identity}}}
  O.with(w,function(files,_,fs)
    local path="/project/data/state.lua"; local original="return "..U.encode(value); files[path]=original
    local state=P.new(path,fs,require("lib.storage.receipts").decoded):load({})
    eq(state.transactions[1].stack,nil); eq(state.transactions[1].transform,nil)
    eq(state.transactions[1].identity,tx.identity); eq(state.transactions[1].dest,tx.dest)
    eq(state.pending,value.pending); eq(state.scan,value.scan); eq(state.reservations,value.reservations)
    eq(files[path],original)
  end)
end)

test("loaded Interface receipt history drops unused identities and preserves pending recovery data",function()
  local w=W.new(); w:build()
  local receipts=require("lib.storage.receipts")
  local managed={id="port",managed=true}; local chest={id="chest"}
  local value={transactions={},pending={source=managed,dest=chest,identity=string.rep("nbt",1200),stack={tag="raw"}}}
  for n=1,64 do
    value.transactions[n]={id=n,owner="job",phase="COMMITTED",source=n%2==0 and managed or chest,
      dest=n%2==0 and chest or managed,destSlot=1,count=1,identity=value.pending.identity..n}
  end
  value.transactions[65]={id=65,source=chest,dest=chest,identity="legacy-export"}
  local before=U.size(value)
  O.with(w,function(files,_,fs)
    files["/state.lua"]="return "..U.encode(value)
    local store=P.new("/state.lua",fs,receipts.decoded,receipts.skipField)
    local loaded=store:load({})
    eq(loaded.pending,value.pending)
    for n=1,64 do
      eq(loaded.transactions[n].identity,nil); eq(loaded.transactions[n].id,n)
      eq(loaded.transactions[n].dest,value.transactions[n].dest); eq(loaded.transactions[n].count,1)
    end
    eq(loaded.transactions[65].identity,"legacy-export")
    ok(U.size(loaded)<before/4,"completed identities must not dominate subsequent checkpoints")
    store:save(loaded); eq(store:load({}),loaded)
  end)
end)

test("checkpoint disk limit preserves primary and backup while streaming",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,_,fs)
    local path="/project/data/state.lua"
    files[path]="return {old=true}"; files[path..".bak"]="previous"; files[path..".tmp"]="partial"
    local original=U.copy(files)
    fs.get=function() return {spaceTotal=function() return 4*1024*1024 end,
      spaceUsed=function() return 4*1024*1024-4200 end} end
    fs.size=function(p) return files[p] and #files[p] end
    raises(function() P.new(path,fs):save({new=string.rep("data",500)}) end,"Not enough disk space for checkpoint")
    eq(files[path],original[path]); eq(files[path..".bak"],original[path..".bak"])
    fs.get=function() return {spaceTotal=function() return 4*1024*1024 end,spaceUsed=function() return 1000 end} end
    P.new(path,fs):save({new=true})
    eq(P.new(path,fs):load({}),{new=true}); eq(files[path..".bak"],original[path])
  end)
end)


test("checkpoint reclaims an oversized backup only when the primary is verified",function()
  for _,valid in ipairs({true,false}) do
    local w=W.new(); w:addMachine("a"); w:build()
    O.with(w,function(files,_,fs)
      local path="/project/data/state.lua"
      files[path]=valid and "return {old=true}" or "return {broken="
      files[path..".bak"]="return "..U.encode({padding=string.rep("x",10000)})
      fs.get=function() return {spaceTotal=function() return 4*1024*1024 end,
        spaceUsed=function() return 4*1024*1024-5100 end} end
      fs.size=function(p) return files[p] and #files[p] end
      local store=P.new(path,fs); local loaded=store:load({})
      local original=U.copy(files)
      if valid then
        store:save({new=string.rep("y",2000)})
        eq(store:load({}).new,string.rep("y",2000)); eq(files[path..".bak"],original[path])
      else
        ok(loaded.recoveredBackup)
        raises(function() store:save({new=string.rep("y",2000)}) end,"Not enough disk space")
        eq(files[path],original[path]); eq(files[path..".bak"],original[path..".bak"])
      end
    end)
  end
end)


test("state decoder skips obsolete receipt payloads without materializing their tables",function()
  local receipts=require("lib.storage.receipts"); local codec=require("lib.state_codec")
  local value={transactions={{id=1,identity="exact",stack={individual={active={species={name="Forest"}}}},transform={batchId="old"}}},
    pending={stack={individual={active={species={name="Forest"}}}}}}
  local source="return "..U.encode(value); local pos=1; local visited={}
  local state=codec.read(function()
    if pos>#source then return nil end
    local chunk=source:sub(pos,pos+16); pos=pos+17; return chunk
  end,function(_,field,parent) visited[#visited+1]={field=field,parent=parent} end,receipts.skipField)
  eq(state.transactions[1].stack,nil); eq(state.transactions[1].transform,nil)
  eq(state.transactions[1].identity,"exact"); eq(state.pending,value.pending)
  local forests=0
  for _,entry in ipairs(visited) do if entry.field=="species" then forests=forests+1 end end
  eq(forests,1,"only the pending recovery genome should be materialized")
end)

test("discarded receipt payloads still reject malformed data",function()
  local source='return {transactions={{stack={tag="bad\\999"}}}}'
  local supplied=false
  raises(function() require("lib.state_codec").read(function()
    if supplied then return nil end; supplied=true; return source
  end,nil,require("lib.storage.receipts").skipField) end,"invalid byte escape")
end)
