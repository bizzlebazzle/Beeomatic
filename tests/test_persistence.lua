local U=require("lib.util"); local P=require("lib.persistence")
local W=require("tests.mocks.world"); local O=require("tests.mocks.openos")

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
      if f and name==path..".tmp" and mode=="w" then
        f.flush=function() files[name]=files[name]:gsub("new","bad"); return true end
      end
      return f,why
    end
    raises(function() P.new(path,fs):save({new=true}) end,"state verification failed")
    eq(files[path],'return {old=true}'); eq(files[path..".bak"],nil)
  end)
end)
