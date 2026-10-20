local N=require("lib.nbt"); local F=require("tests.fixtures.nbt")
test("gzip NBT reader handles stored fixed and dynamic deflate blocks",function()
  for _,tag in ipairs({F.a,F.stored,F.fixed}) do eq(N.gunzip(tag),F.raw) end
  eq(N.gunzip(F.dynamic),F.dynamicRaw)
end)
test("legacy checkpoint migration updates identity references and keys but preserves stack tags and ownership",function()
  local U=require("lib.util"); local B=require("lib.bees")
  local s={name="Forestry:beeQueenGE",damage=0,tag=F.a}
  local old=U.encode(s); local key=B.identity(s)
  local other=U.encode({name=s.name,damage=0,tag=F.b})
  local state={scan={identity=old,item={stack=s},before={[old]=2,[other]=3}},
    aeCatalog={[old]={ident="end"}},meBatches={owned={identity=old,count=1,owner="job"}},
    pending={identity=old},meRequests={port={identity=old}},reservations={port={identity=old}}}
  B.migrateIdentities(state)
  eq(state.scan.identity,key); eq(state.scan.item.stack.tag,F.a); eq(state.scan.before[key],5)
  eq(state.aeCatalog[old],nil); eq(state.aeCatalog[key].ident,"end")
  eq(state.meBatches.owned.identity,key); eq(state.meBatches.owned.owner,"job")
  eq(state.pending.identity,key); eq(state.meRequests.port.identity,key); eq(state.reservations.port.identity,key)
  local copy=U.copy(state); B.migrateIdentities(state); eq(state,copy)
  eq(B.upgradeIdentity('os.execute("bad")'), 'os.execute("bad")')
end)
test("migration rejects conflicting equivalent saved identities without persisting an overwrite",function()
  local U=require("lib.util"); local B=require("lib.bees")
  local function key(tag) return U.encode({name="Forestry:beeQueenGE",damage=0,tag=tag}) end
  raises(function() B.migrateIdentities({aeCatalog={[key(F.a)]={ident="one"},[key(F.b)]={ident="two"}}}) end,"conflicting saved NBT identities")
end)

test("migration leaves opaque tag identities untouched without re-encoding large receipt strings",function()
  local U=require("lib.util"); local B=require("lib.bees")
  local identity=U.encode({name="Forestry:beeDroneGE",damage=0,tag=string.rep("opaque",2000)})
  local state={transactions={{identity=identity}},aeCatalog={[identity]={ident="forest"}}}
  local encode=U.encode; U.encode=function() error("opaque identities must not be re-encoded") end
  local success,why=pcall(B.migrateIdentities,state); U.encode=encode
  ok(success,why); eq(state.transactions[1].identity,identity); eq(state.aeCatalog[identity].ident,"forest")
end)
test("NBT identity ignores compound order and gzip metadata while preserving every typed value",function()
  eq(N.canonical(F.a),N.canonical(F.b))
  ok(N.canonical(F.a)~=N.canonical(F.changed))
  ok(N.canonical(F.a)~=N.canonical(F.listChanged))
  ok(N.canonical(F.a)~=N.canonical(F.typeChanged))
  eq(N.canonical("mock compressed tag"),nil)
  eq(N.difference(F.a,F.b),nil)
  eq(N.difference(F.a,F.changed),'root["Genome"]["Inactive"]')
  eq(N.difference(F.a,F.typeChanged),'root["Genome"]["Fertility"]')
  eq(N.difference(F.a,F.listChanged),'root["Mate"][1]')
end)
test("NBT reader rejects corrupt truncated and oversized data",function()
  raises(function() N.canonical(F.a:sub(1,-2)) end)
  local bad=F.a:sub(1,-9)..string.char((F.a:byte(-8)+1)%256)..F.a:sub(-7)
  raises(function() N.canonical(bad) end,"checksum")
  raises(function() N.sort(F.raw.."\0") end,"trailing NBT")
  raises(function() N.sort("\10\0\0\8\0\1x\0\4abc\0") end)
  raises(function() N.sort(string.rep("x",65537)) end,"size limit")
end)
