local U=require("lib.util"); local P=require("lib.persistence")
local W=require("tests.mocks.world"); local O=require("tests.mocks.openos")

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

test("small checkpoints serialize once while large ones retain bounded streaming verification",function()
  local w=W.new(); w:build()
  O.with(w,function(files,_,fs)
    for _,length in ipairs({0,16363,16364,32000}) do
      local data={tag=string.rep("x",length)}; local calls=0; local write=U.write
      U.write=function(...) calls=calls+1; return write(...) end
      local success,why=pcall(function() P.new("/state.lua",fs):save(data) end)
      U.write=write; ok(success,why)
      eq(calls,U.size(data)<=16384 and 1 or 2)
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

test("state saves verify exact chunks without loading another copy of state",function()
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

test("corrupted temporary state cannot replace the previous generation",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out,fs)
    local path="/project/data/state.lua"; files[path]='return {old=true}'
    local open=io.open
    io.open=function(name,mode)
      local f,why=open(name,mode)
      if f and name==path..".tmp" and mode=="wb" then
        f.flush=function() files[name]=files[name]:gsub("new","bad"); return true end
      end
      return f,why
    end
    raises(function() P.new(path,fs):save({new=true}) end,"state verification failed")
    eq(files[path],'return {old=true}'); eq(files[path..".bak"],nil)
  end)
end)

test("large streaming checkpoints also reject truncation and trailing bytes before replacement",function()
  for _,corrupt in ipairs({function(s) return s:sub(1,-2) end,function(s) return s.."x" end}) do
    local w=W.new(); w:build()
    O.with(w,function(files,_,fs)
      local path="/state.lua"; files[path]="return {old=true}"
      local open=io.open
      io.open=function(name,mode)
        local f,why=open(name,mode)
        if f and name==path..".tmp" and mode=="wb" then
          f.flush=function() files[name]=corrupt(files[name]); return true end
        end
        return f,why
      end
      raises(function() P.new(path,fs):save({large=string.rep("x",20000)}) end,"state verification failed")
      eq(files[path],"return {old=true}"); eq(files[path..".bak"],nil)
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

test("checkpoint disk preflight leaves primary backup and partial temporary file untouched",function()
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,_,fs)
    local path="/project/data/state.lua"
    files[path]="return {old=true}"; files[path..".bak"]="previous"; files[path..".tmp"]="partial"
    local original=U.copy(files)
    fs.get=function() return {spaceTotal=function() return 4*1024*1024 end,
      spaceUsed=function() return 4*1024*1024-4200 end} end
    fs.size=function(p) return files[p] and #files[p] end
    raises(function() P.new(path,fs):save({new=string.rep("data",500)}) end,"Not enough disk space for checkpoint")
    eq(files,original)
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
        eq(files,original)
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
