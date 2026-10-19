local W=require("tests.mocks.world"); local O=require("tests.mocks.openos")
local revision=string.rep("a",40)
local base="https://raw.githubusercontent.com/bizzlebazzle/Beeomatic/"..revision.."/"
local function scenario(options,fn)
  local w=W.new(); w:addMachine("a"); w:build()
  O.with(w,function(files,out)
    local previousInternet,previousLoadfile=package.loaded.internet,loadfile
    local requests={}
    package.loaded.internet={request=function(url)
      requests[#requests+1]=url
      local code,body=200,nil
      if url=="https://api.github.com/repos/bizzlebazzle/Beeomatic/commits/master" then
        body='{"sha":"'..revision..'"}'
      else
        assert(url:sub(1,#base)==base,"mixed download revisions")
        local path=url:sub(#base+1)
        if options.badManifest and path=="manifest.lua" then
          body='return {"../data/config.lua", "install.lua", "manifest.lua", "Beeomatic.lua"}'
        elseif options.fail==path then code=404; body="Not Found"
        elseif options.syntax==path then body="this is not Lua code!"
        else
          local f=assert(io.open(path,"rb")); body=f:read("*a"); f:close()
        end
      end
      local sent=false
      return setmetatable({response=function() return code,"test response" end,close=function() end},
        {__call=function() if not sent then sent=true; return body end end})
    end}
    loadfile=function(path,...)
      if files[path] then return load(files[path],"@"..path,"t",_G) end
      return previousLoadfile(path,...)
    end
    local yes,err=xpcall(function() fn(files,requests,out) end,debug.traceback)
    loadfile=previousLoadfile; package.loaded.internet=previousInternet
    assert(yes,err)
  end,options.quotas)
end
test("online installation pins all files to one revision and preserves existing data",function()
  scenario({},function(files,requests)
    files["/home/Beeomatic/data/config.lua"]="saved configuration"
    assert(loadfile("get.lua"))()
    eq(files["/home/Beeomatic/data/config.lua"],"saved configuration")
    ok(files["/usr/bin/Beeomatic"])
    for _,path in ipairs(assert(loadfile("manifest.lua"))()) do
      ok(files["/home/Beeomatic/"..path],"missing installed "..path)
    end
    eq(requests[1],"https://api.github.com/repos/bizzlebazzle/Beeomatic/commits/master")
  end)
end)
test("missing last release file leaves installed program and data untouched",function()
  scenario({fail="lib/util.lua"},function(files)
    files["/home/Beeomatic/Beeomatic.lua"]="previous program"
    files["/home/Beeomatic/data/config.lua"]="saved configuration"
    raises(function() assert(loadfile("get.lua"))(revision) end,"HTTP 404")
    eq(files["/home/Beeomatic/Beeomatic.lua"],"previous program")
    eq(files["/home/Beeomatic/data/config.lua"],"saved configuration")
    eq(files["/usr/bin/Beeomatic"],nil)
    for path in pairs(files) do ok(not path:find("/home/Beeomatic.download/",1,true),"staging leaked") end
  end)
end)

test("compact download avoids tiny temporary disk and cleans staging after upgrades",function()
  scenario({quotas={root=512*1024,tmp=1024}},function(files,requests)
    files["/home/Beeomatic/data/config.lua"]="saved configuration"
    files["/tmp/unrelated"]="keep"
    assert(loadfile("get.lua"))(revision)
    assert(loadfile("get.lua"))(revision)
    eq(files["/home/Beeomatic/data/config.lua"],"saved configuration")
    eq(files["/tmp/unrelated"],"keep")
    for _,url in ipairs(requests) do
      ok(not url:find("/docs/",1,true)); ok(not url:find("/tests/",1,true))
      ok(not url:find("robot-helper.lua",1,true)); ok(not url:find("config.example.lua",1,true))
    end
    for path in pairs(files) do
      ok(not path:find("/home/Beeomatic.download/",1,true),"staging leaked")
      ok(path=="/tmp/unrelated" or not path:find("/tmp/",1,true),"temporary disk used")
    end
  end)
end)
test("downloader rejects manifest traversal before downloading release files",function()
  scenario({badManifest=true},function(files,requests)
    raises(function() assert(loadfile("get.lua"))(revision) end,"unsafe or duplicate")
    eq(#requests,1); eq(files["/home/Beeomatic/Beeomatic.lua"],nil)
  end)
end)
test("invalid Lua download cannot replace the installed program",function()
  scenario({syntax="lib/scheduler.lua"},function(files)
    files["/home/Beeomatic/Beeomatic.lua"]="previous program"
    raises(function() assert(loadfile("get.lua"))(revision) end)
    eq(files["/home/Beeomatic/Beeomatic.lua"],"previous program")
  end)
end)
