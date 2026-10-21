-- Opt-in wall-clock timings. No item/NBT payloads, unbounded logs or saved state.
local M={}; M.__index=M
local function describe(...)
  local out={}
  for i=1,math.min(5,select("#",...)) do
    local v=select(i,...); local kind=type(v)
    out[#out+1]=(kind=="table" or kind=="userdata") and kind or tostring(v):gsub("[%c]"," "):sub(1,40)
  end
  return table.concat(out,",")
end
function M.new(path,now,fs,memory)
  local start=now()
  return setmetatable({path=path,now=now,fs=fs,memory=memory,start=start,lastFlush=start,
    rows={},entries=0,events={},restore={},proxies={}},M)
end
function M:call(label,detail,fn,...)
  if self.suspended then return fn(...) end
  label=label:gsub("[%c]"," "):sub(1,100)
  local row=self.rows[label]
  if not row then
    if self.entries>=127 then label="other"; row=self.rows[label] end
    if not row then row={count=0,total=0,own=0,max=0,errors=0}; self.rows[label]=row; self.entries=self.entries+1 end
  end
  local parent=self.frame; local frame={start=self.now(),children=0}; self.frame=frame
  local result=table.pack(pcall(fn,...))
  local elapsed=math.max(0,self.now()-frame.start); self.frame=parent
  if parent then parent.children=parent.children+elapsed end
  row.count=row.count+1; row.total=row.total+elapsed; row.own=row.own+math.max(0,elapsed-frame.children)
  row.max=math.max(row.max,elapsed); if not result[1] then row.errors=row.errors+1 end
  if elapsed>=0.25 or not result[1] then
    self.events[#self.events+1]=string.format("%8.3f +%.3fs %s %s%s",frame.start-self.start,elapsed,
      label,tostring(detail or ""):gsub("[%c]"," "):sub(1,160),result[1] and "" or " ERROR")
    if #self.events>24 then table.remove(self.events,1) end
  end
  if not result[1] then error(result[2],0) end
  return table.unpack(result,2,result.n)
end
function M:wrap(object,key,label,detail)
  local fn=object[key]; if not fn then return end
  local own=rawget(object,key)
  self.restore[#self.restore+1]=function() object[key]=own end
  object[key]=function(...)
    return self:call(label,detail and detail(...) or nil,fn,...)
  end
end
function M:proxy(address,raw,methods)
  local entry=self.proxies[address]
  if entry and entry.raw==raw then return entry.proxy end
  local proxy=setmetatable({},{__index=function(t,key)
    local value=raw[key]
    if methods[key]~=nil and value~=nil then
      local fn=value
      value=function(...) return self:call(address.."."..key,describe(...),fn,...) end
      rawset(t,key,value)
    end
    return value
  end})
  if (self.proxyCount or 0)<32 or entry then
    self.proxies[address]={raw=raw,proxy=proxy}
    if not entry then self.proxyCount=(self.proxyCount or 0)+1 end
  end
  return proxy
end
function M:file(raw)
  return setmetatable({},{__index=function(t,key)
    local fn=raw[key]
    if key~="read" and key~="write" and key~="flush" and key~="close" then return fn end
    local wrapped=function(_,...) return self:call("disk."..key,nil,fn,raw,...) end
    rawset(t,key,wrapped); return wrapped
  end})
end
function M:report()
  local labels={}; for label in pairs(self.rows) do labels[#labels+1]=label end
  table.sort(labels,function(a,b) return self.rows[a].own>self.rows[b].own end)
  local out={"Beeomatic profile (seconds)\nElapsed: "..string.format("%.3f",self.now()-self.start),
    "Own excludes timed children; total includes them. Do not add nested totals.",
    "Component labels use full addresses. Slow/error history keeps the last 24 completed calls."}
  if self.command then out[#out+1]="Command: "..self.command end
  out[#out+1]="Outcome: "..(self.outcome or "running")
  if self.memory then local ok,n=pcall(self.memory); if ok and type(n)=="number" then out[#out+1]="Free RAM bytes: "..n end end
  if self.statePath and self.fs.size then
    local ok,n=pcall(self.fs.size,self.statePath); if ok and n then out[#out+1]="State file bytes: "..n end
  end
  if self.cataloguePath and self.fs.size then
    local ok,n=pcall(self.fs.size,self.cataloguePath); if ok and n then out[#out+1]="Catalogue file bytes: "..n end
  end
  local cache=self.stringCache
  if cache then out[#out+1]=string.format(
    "Large-string cache: %d hits, %d misses; %d input bytes reused; %d/262144 bytes retained (accounted)",
    cache.hits,cache.misses,cache.reused,cache.bytes) end
  local nbt=self.nbtCache
  if nbt then
    local start=self.nbtBaseline or {hits=0,misses=0,evictions=0}
    out[#out+1]=string.format(
      "NBT cache: %d hits, %d misses, %d evictions; %d entries; %d/%d bytes retained (accounted)",
      nbt.hits-start.hits,nbt.misses-start.misses,nbt.evictions-start.evictions,nbt.entries,nbt.bytes,nbt.limit)
  end
  out[#out+1]="\n    count      own_s    total_s      max_s errors operation"
  for _,label in ipairs(labels) do local r=self.rows[label]
    out[#out+1]=string.format("%9d %10.3f %10.3f %10.3f %6d %s",r.count,r.own,r.total,r.max,r.errors,label)
  end
  out[#out+1]="\nRecent slow/error calls (start offset, duration, operation, arguments):"
  for _,line in ipairs(self.events) do out[#out+1]=line end
  return (table.concat(out,"\n").."\n"):sub(1,32768)
end
function M:flush(force)
  if not force and self.now()-self.lastFlush<30 then return end
  self.lastFlush=self.now()
  self.suspended=true -- exclude report I/O from the application's measurements
  local file
  local ok,why=pcall(function()
    local report=self:report(); local tmp=self.path..".tmp"
    if self.fs.get then
      local disk=self.fs.get(self.path)
      if disk and disk.spaceTotal and disk.spaceUsed then
        assert(disk.spaceTotal()-disk.spaceUsed()>=#report+4096,"not enough disk space for profiling log")
      end
    end
    file=assert(io.open(tmp,"wb")); assert(file:write(report)); assert(file:flush()); file:close(); file=nil
    if self.fs.exists(self.path) then assert(self.fs.remove(self.path)) end
    assert(self.fs.rename(tmp,self.path))
  end)
  if file then pcall(file.close,file) end
  self.suspended=false
  self.error=not ok and tostring(why) or nil
  return ok,why
end
function M:finish()
  self:flush(true)
  for i=#self.restore,1,-1 do self.restore[i]() end
  if self.error then print("Could not save profiling log: "..self.error)
  else print("Profiling log: "..self.path.." (Beeomatic logs --profile)") end
end
return M
