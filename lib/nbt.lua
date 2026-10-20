-- Read Minecraft gzip NBT without a Data Card or external Lua libraries.
-- Preserve every typed value; only compound field order is insignificant.
local M={}
local LIMIT=65536
local function xor(a,b)
  local result,bit=0,1
  while a>0 or b>0 do
    local x,y=a%2,b%2
    if x~=y then result=result+bit end
    a=math.floor(a/2); b=math.floor(b/2); bit=bit*2
  end
  return result
end
local bxor=bit32 and bit32.bxor or xor
local crcTable={}
for i=0,255 do
  local c=i
  for _=1,8 do c=c%2==1 and bxor(math.floor(c/2),3988292384) or math.floor(c/2) end
  crcTable[i]=c
end
local function tree(lengths)
  local counts,codes,lookup={},{},{}
  for _,len in ipairs(lengths) do
    assert(len>=0 and len<=15,"invalid Huffman length")
    if len>0 then counts[len]=(counts[len] or 0)+1 end
  end
  local code=0
  for len=1,15 do
    code=(code+(counts[len-1] or 0))*2
    assert(code+(counts[len] or 0)<=2^len,"oversubscribed Huffman tree")
    codes[len]=code; lookup[len]={}
  end
  for symbol,len in ipairs(lengths) do if len>0 then
    lookup[len][codes[len]]=symbol-1; codes[len]=codes[len]+1
  end end
  return lookup
end
local fixedLit,fixedDist={},{}
for symbol=0,287 do fixedLit[symbol+1]=symbol<144 and 8 or symbol<256 and 9 or symbol<280 and 7 or 8 end
for symbol=0,31 do fixedDist[symbol+1]=5 end
fixedLit=tree(fixedLit); fixedDist=tree(fixedDist)
local lengths={3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
local lengthBits={0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
local distances={1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
local distanceBits={0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
function M.gunzip(s)
  assert(type(s)=="string" and #s>=18 and #s<=LIMIT,"invalid gzip size")
  assert(s:sub(1,3)=="\31\139\8","expected gzip NBT")
  local flags=s:byte(4); assert(flags<32,"reserved gzip flags")
  local pos,last=11,#s-8
  local function flag(bit) return math.floor(flags/bit)%2==1 end
  if flag(4) then
    assert(pos+1<=last,"truncated gzip header")
    local n=s:byte(pos)+256*s:byte(pos+1); pos=pos+2+n
  end
  for _,bit in ipairs({8,16}) do if flag(bit) then
    local stop=s:find("\0",pos,true); assert(stop and stop<=last,"truncated gzip header"); pos=stop+1
  end end
  -- Minecraft does not emit header CRCs; reject rather than ignore one.
  assert(not flag(2),"unsupported gzip header checksum")
  assert(pos<=last,"empty gzip payload")
  local buffer,bits=0,0
  local function read(n)
    while bits<n do
      assert(pos<=last,"truncated deflate data")
      buffer=buffer+s:byte(pos)*2^bits; pos=pos+1; bits=bits+8
    end
    local v=buffer%2^n; buffer=math.floor(buffer/2^n); bits=bits-n; return v
  end
  local function decode(t)
    local code=0
    for len=1,15 do
      code=code*2+read(1)
      local symbol=t[len][code]; if symbol~=nil then return symbol end
    end
    error("invalid Huffman code")
  end
  local output,n={},0
  local function emit(byte)
    assert(n<LIMIT,"NBT exceeds decompression limit")
    n=n+1; output[n]=string.char(byte)
  end
  local final
  repeat
    final=read(1)==1
    local kind=read(2)
    if kind==0 then
      buffer=0; bits=0
      local count,check=read(16),read(16)
      assert(count+check==65535,"invalid stored block length")
      for _=1,count do emit(read(8)) end
    else
      assert(kind~=3,"reserved deflate block")
      local lit,dist=fixedLit,fixedDist
      if kind==2 then
        local nl,nd,nc=read(5)+257,read(5)+1,read(4)+4
        assert(nl<=286,"invalid literal count")
        local order={16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
        local cl={}; for i=1,19 do cl[i]=0 end
        for i=1,nc do cl[order[i]+1]=read(3) end
        local ct=tree(cl); local all={}
        while #all<nl+nd do
          local symbol=decode(ct)
          if symbol<=15 then all[#all+1]=symbol
          else
            local value,count=0,0
            if symbol==16 then assert(#all>0,"missing repeated code"); value=all[#all]; count=read(2)+3
            elseif symbol==17 then count=read(3)+3
            else count=read(7)+11 end
            assert(#all+count<=nl+nd,"too many code lengths")
            for _=1,count do all[#all+1]=value end
          end
        end
        local ll,dd={},{}
        for i=1,nl do ll[i]=all[i] end
        for i=1,nd do dd[i]=all[nl+i] end
        assert(ll[257]>0,"missing end of block")
        lit=tree(ll); dist=tree(dd)
      end
      while true do
        local symbol=decode(lit)
        if symbol<256 then emit(symbol)
        elseif symbol==256 then break
        else
          local index=symbol-256; assert(lengths[index],"invalid length symbol")
          local count=lengths[index]+read(lengthBits[index])
          local d=decode(dist)+1; assert(distances[d],"invalid distance symbol")
          local offset=distances[d]+read(distanceBits[d])
          assert(offset<=n,"deflate distance exceeds output")
          assert(n+count<=LIMIT,"NBT exceeds decompression limit")
          for _=1,count do n=n+1; output[n]=output[n-offset] end
        end
      end
    end
  until final
  assert(pos==last+1,"trailing deflate data")
  local function little(p) return s:byte(p)+s:byte(p+1)*256+s:byte(p+2)*65536+s:byte(p+3)*16777216 end
  assert(little(#s-3)==n,"gzip size mismatch")
  local raw=table.concat(output); output=nil
  local crc=4294967295
  for i=1,#raw do crc=bxor(math.floor(crc/256),crcTable[bxor(crc%256,raw:byte(i))]) end
  assert(bxor(crc,4294967295)==little(#s-7),"gzip checksum mismatch")
  return raw
end
function M.sort(raw)
  assert(#raw<=LIMIT,"NBT exceeds size limit")
  local pos,nodes=1,0
  local function take(n)
    assert(n>=0 and pos+n-1<=#raw,"truncated NBT")
    local value=raw:sub(pos,pos+n-1); pos=pos+n; return value
  end
  local function number(n)
    local bytes=take(n); local v=0
    for i=1,n do v=v*256+bytes:byte(i) end
    return v,bytes
  end
  local function name()
    local n,prefix=number(2); local value=take(n); return value,prefix..value
  end
  local payload
  payload=function(kind,depth)
    nodes=nodes+1; assert(nodes<=LIMIT and depth<=64,"NBT nesting/element limit exceeded")
    local widths={[1]=1,[2]=2,[3]=4,[4]=8,[5]=4,[6]=8}
    if widths[kind] then return take(widths[kind]) end
    if kind==8 then local _,value=name(); return value end
    if kind==7 or kind==11 or kind==12 then
      local count,prefix=number(4); assert(count<=LIMIT,"invalid NBT array length")
      return prefix..take(count*(kind==7 and 1 or kind==11 and 4 or 8))
    end
    if kind==9 then
      local element=number(1); local count,prefix=number(4)
      assert(count<=LIMIT and (element>=1 and element<=12 or count==0 and element==0),"invalid NBT list")
      local parts={string.char(element),prefix}
      for _=1,count do parts[#parts+1]=payload(element,depth+1) end
      return table.concat(parts)
    end
    assert(kind==10,"unknown NBT type")
    local fields,keys={},{}
    while true do
      local ty=number(1); if ty==0 then break end
      local key,encoded=name(); assert(not fields[key],"duplicate NBT compound field")
      fields[key]=string.char(ty)..encoded..payload(ty,depth+1); keys[#keys+1]=key
    end
    table.sort(keys)
    local parts={}; for _,key in ipairs(keys) do parts[#parts+1]=fields[key] end
    parts[#parts+1]="\0"; return table.concat(parts)
  end
  assert(number(1)==10,"NBT root must be a compound")
  local _,root=name(); local value="\10"..root..payload(10,0)
  assert(pos==#raw+1,"trailing NBT data")
  return value
end
-- Bounded cache avoids decompressing unchanged network/receipt tags each poll.
local cache,queue={},{}
function M.canonical(tag)
  if type(tag)~="string" or tag:sub(1,2)~="\31\139" then return nil end
  if cache[tag] then return cache[tag] end
  local value=M.sort(M.gunzip(tag))
  if #queue>=16 then cache[table.remove(queue,1)]=nil end
  queue[#queue+1]=tag; cache[tag]=value
  return value
end
return M
