local U=require("lib.util"); local P=require("lib.persistence")
local W=require("tests.mocks.world"); local O=require("tests.mocks.openos")

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
