-- PC resource fixture: fill the real cache without retaining the input dataset.
return function(path)
  local N=require("lib.nbt")
  local f=assert(io.open(path,"rb"))
  while true do
    local length=f:read(2); if not length then break end
    local bytes=length:byte(1)*256+length:byte(2)
    local tag=assert(f:read(bytes)); assert(#tag==bytes)
    N.canonical(tag)
  end
  f:close()
  assert(N.cache.bytes>125000 and N.cache.bytes<=N.cache.limit,"fixture must fill the NBT cache")
  return N
end
