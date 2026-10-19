local M={}
-- Wrap before paging so a long condition never scrolls a page off the screen.
function M.lines(text,width)
  width=math.max(1,width)
  local lines={}
  for line in (text.."\n"):gmatch("(.-)\n") do
    local indent=line:match("^%s*") or ""
    if #indent>=width then indent="" end
    while #line>width do
      local cut=line:sub(1,width+1):match("^.*()%s")
      if not cut or cut<=#indent+1 then cut=width+1 end
      lines[#lines+1]=line:sub(1,cut-1)
      line=indent..line:sub(cut):gsub("^%s+","")
    end
    lines[#lines+1]=line
  end
  return lines
end
function M.show(text,options)
  options=options or {}
  if options.enabled==false then print(text); return end
  local ok,term=pcall(require,"term")
  if not ok or not term.getViewport or (term.isAvailable and not term.isAvailable()) then print(text); return end
  local width,height=term.getViewport()
  if not width or not height or width<24 or height<6 then print(text); return end
  local lines=M.lines(text,width-1)
  local size=height-2; local pages=math.ceil(#lines/size)
  if pages<=1 then print(table.concat(lines,"\n")); return end
  local event=require("event"); local page=1
  while true do
    local chunk={}
    for i=(page-1)*size+1,math.min(page*size,#lines) do chunk[#chunk+1]=lines[i] end
    print(table.concat(chunk,"\n"))
    print(string.format("[%d/%d] Enter > B < Q",page,pages))
    local action
    repeat
      local kind,_,char,key=event.pull()
      if kind=="interrupted" then return end
      if kind=="key_down" then
        if char==113 or char==81 or key==1 then return end
        if char==98 or char==66 then action="back"
        elseif char==13 or char==32 or key==28 then action="next" end
      end
    until action
    if action=="back" then page=math.max(1,page-1)
    elseif page==pages then return
    else page=page+1 end
  end
end
return M
