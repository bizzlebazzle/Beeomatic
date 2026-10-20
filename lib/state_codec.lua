-- Incremental, data-only reader for current and legacy Lua table state files.
-- File reads run in Lua, outside load()'s non-yieldable C parser callback.
local M={}
local escapes={a="\a",b="\b",f="\f",n="\n",r="\r",t="\t",v="\v",['\\']='\\',['"']='"',["'"]="'"}
-- Avoid table.concat's extra C buffer for long NBT identities. Balanced Lua
-- concatenations also avoid quadratic copying and use the VM's allocator.
local function join(parts)
  local n=#parts
  while n>1 do
    local target=1
    for i=1,n,2 do parts[target]=parts[i]..(parts[i+1] or ""); target=target+1 end
    for i=target,n do parts[i]=nil end
    n=target-1
  end
  return parts[1] or ""
end
function M.read(reader,onTable,skipField)
  local buffer,pos,offset="",1,0
  local strings={}
  local function intern(s)
    if #s<64 then return s end
    local old=strings[s]; if old then return old end
    strings[s]=s; return s
  end
  local function peek()
    if pos>#buffer then
      offset=offset+#buffer; buffer=reader() or ""; pos=1
    end
    return buffer:sub(pos,pos)
  end
  local function take() local ch=peek(); pos=pos+1; return ch end
  local function fail(why) error("state data at byte "..tostring(offset+pos)..": "..why,0) end
  local function space() while peek()~="" and peek():match("%s") do pos=pos+1 end end
  local function expect(ch) space(); if take()~=ch then fail("expected "..ch) end end
  local function word()
    local result={}
    while peek()~="" and peek():match("[%w_]") do result[#result+1]=take() end
    return table.concat(result)
  end
  local function quoted(shared,discard)
    local quote=take(); local pieces,blocks
    if not discard then pieces,blocks={},{} end
    local function piece(s)
      if discard then return end
      pieces[#pieces+1]=s
      if #pieces>=128 then blocks[#blocks+1]=join(pieces); pieces={} end
    end
    while true do
      if peek()=="" then fail("unfinished string") end
      local last=buffer:find('["\'\\\r\n]',pos)
      -- The other quote character is ordinary data inside this string.
      if last and buffer:sub(last,last)~=quote and buffer:sub(last,last)~="\\" and
        buffer:sub(last,last)~="\r" and buffer:sub(last,last)~="\n" then
        piece(buffer:sub(pos,last)); pos=last+1
      elseif not last then
        piece(buffer:sub(pos)); pos=#buffer+1
      else
        if last>pos then piece(buffer:sub(pos,last-1)) end
        pos=last
        local ch=take()
        if ch==quote then
          if discard then return true end
          blocks[#blocks+1]=join(pieces)
          local result=join(blocks)
          return shared and intern(result) or result
        end
        if ch~="\\" then fail("unescaped newline in string") end
        ch=take()
        if escapes[ch] then piece(escapes[ch])
        elseif ch:match("%d") then
          local digits=ch
          for _=1,2 do if peek():match("%d") then digits=digits..take() else break end end
          local byte=tonumber(digits); if byte>255 then fail("invalid byte escape") end
          piece(string.char(byte))
        elseif ch=="x" then
          local hex=take()..take(); if not hex:match("^%x%x$") then fail("invalid hex escape") end
          piece(string.char(tonumber(hex,16)))
        elseif ch=="z" then space()
        elseif ch=="\n" or ch=="\r" then
          if ch=="\r" and peek()=="\n" then take() end
          piece("\n")
        else fail("invalid string escape") end
      end
    end
  end
  local value
  local function keyword(name)
    if name=="true" then return true elseif name=="false" then return false elseif name=="nil" then return nil end
    fail("unsupported value "..name)
  end
  local function object(depth,field,parent,discard)
    if depth>128 then fail("table nesting limit exceeded") end
    expect("{"); local result,index=not discard and {} or nil,1
    local function child(key)
      local drop=discard or (skipField and skipField(key,field,parent))
      return value(depth,key,field,drop),drop
    end
    space()
    while peek()~="}" do
      if peek()=="" then fail("unfinished table") end
      local key,item,explicit,skipped
      if peek()=="[" then
        take(); key=value(depth,nil,nil,discard); expect("]"); expect("="); item,skipped=child(key); explicit=true
      elseif peek():match("[%a_]") then
        local name=word(); space()
        if peek()=="=" then take(); key=name; item,skipped=child(key); explicit=true
        else item=keyword(name) end
      else item,skipped=child(index) end
      if not explicit then key=index; index=index+1 end
      if key==nil then fail("nil table key") end
      if not discard and not skipped then result[key]=item end; space()
      if peek()=="," or peek()==";" then take(); space()
      elseif peek()~="}" then fail("expected comma or closing brace") end
    end
    take(); if not discard and onTable then onTable(result,field,parent) end
    return discard and true or result
  end
  value=function(depth,field,parent,discard)
    space(); local ch=peek()
    if ch=="{" then return object(depth+1,field,parent,discard)
    elseif ch=='"' or ch=="'" then
      return quoted(field==nil or field=="identity" or field=="original" or field=="slot",discard)
    elseif ch:match("[%a_]") then return keyword(word())
    else
      local token={}
      while peek()~="" and peek():match("[%w%.%+%-]") do token[#token+1]=take() end
      local n=tonumber(table.concat(token))
      if not n or n~=n or n==math.huge or n==-math.huge then fail("invalid number/value") end
      return n
    end
  end
  space(); if word()~="return" then fail("expected return") end
  local result=value(0); space()
  if peek()~="" then fail("unexpected trailing data") end
  if type(result)~="table" then fail("expected a state table") end
  return result
end
return M
