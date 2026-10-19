package.path="./?.lua;./?/init.lua;"..package.path
local count,failed=0,0
function test(name,fn)
  count=count+1; local success,err=xpcall(fn,debug.traceback)
  if success then print("PASS "..name) else failed=failed+1; print("FAIL "..name.."\n"..err) end
end
function eq(a,b,message) assert(require("lib.util").equal(a,b),message or (tostring(a).." ~= "..tostring(b))) end
function ok(value,message) assert(value,message or "expected truthy value") end
function raises(fn,needle)
  local yes,e=pcall(fn); assert(not yes,"expected failure")
  if needle then assert(tostring(e):find(needle,1,true),"wrong diagnostic: "..tostring(e)) end
end
for _,suite in ipairs({"planner","plan_output","genetics","environment","persistence","storage","interface","scheduler","recovery","scanner","setup","integration","cli","status","download","performance"}) do
  require("tests.test_"..suite)
end
print(string.format("%d tests, %d failures",count,failed)); assert(failed==0,"test suite failed")
