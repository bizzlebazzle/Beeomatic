local U=require("lib.util"); local C=require("lib.config"); local B=require("lib.bees")
local M={}
function M.new(config,components,inv,save,read,out)
  local w={c=config,components=components,inv=inv,save=save,read=read or io.read,out=out or print}
  function w:heading(text)
    local gpu,previous,palette
    if self.out==print then
      pcall(function()
        local term=require("term"); local candidate=term.gpu()
        if candidate and candidate.getDepth()>1 then
          io.stdout:flush()
          previous,palette=candidate.getForeground()
          candidate.setForeground(0x55FFFF)
          gpu=candidate
        end
      end)
    end
    local ok,err=pcall(self.out,"== "..text.." ==")
    if gpu then
      pcall(function() io.stdout:flush() end)
      pcall(gpu.setForeground,previous,palette)
    end
    if not ok then error(err,0) end
  end
  function w:ask(label,default)
    self.out(label..(default~=nil and (" ["..tostring(default).."]") or "")..": ")
    local value=self.read(); assert(value,"Setup interrupted; completed sections are saved")
    if value=="" and default~=nil then return tostring(default) end; return value
  end
  function w:yes(label,default) return self:ask(label,default and "yes" or "no"):lower()=="yes" end
  function w:number(label,lo,hi,default)
    while true do local ok,n=pcall(U.assertNumber,self:ask(label,default),lo,hi); if ok then return n end; self.out(tostring(n)) end
  end
  function w:address(label,methods,default,useNamedSingle)
    local registry=self.c.componentNames or {}
    local page,onlyNew=1,nil
    while true do
      local all=self.components:discover(); local choices={}
      for _,c in ipairs(all) do
        local compatible=not c.error
        for _,method in ipairs(methods) do if c.methods[method]==nil then compatible=false end end
        if compatible and (not onlyNew or not onlyNew[c.address]) then choices[#choices+1]=c end
      end
      if useNamedSingle and #choices==1 and registry[choices[1].address] then
        local selected=choices[1]
        local ok,p=pcall(self.components.proxy,self.components,selected.address,methods)
        if ok then
          self.out("Using the only available transposer: "..registry[selected.address].name)
          return p.address or selected.address
        end
      end
      local pages=math.max(1,math.ceil(#choices/2)); page=math.min(page,pages)
      self:heading(label.." - choose a component (page "..page.."/"..pages..")")
      local defaultNumber
      for i,c in ipairs(choices) do if c.address==default then defaultNumber=i end end
      if #choices==0 then self.out("No compatible components found. Connect one and refresh.") end
      if defaultNumber and (defaultNumber<=(page-1)*2 or defaultNumber>page*2) then
        self.out("Current selection: "..defaultNumber.." ("..default.."); Enter keeps it.")
      end
      for i=(page-1)*2+1,math.min(page*2,#choices) do
        local c=choices[i]; local saved=registry[c.address]
        self.out(i..". "..(saved and saved.name or "Unnamed").." ("..c.kind..")"..(c.address==default and " [current]" or ""))
        self.out("   "..c.address)
        if c.methods.getInventorySize~=nil and c.methods.getStackInSlot~=nil then
          for _,line in ipairs(self.components:inventorySummary(c.address)) do self.out("   "..line) end
        end
      end
      self.out("R refresh | N connect new | > next page | < previous page")
      self.out("Select the number of the component you want to use.")
      local answer=self:ask("Component number",defaultNumber):lower()
      if answer=="r" then onlyNew=nil; page=1
      elseif answer=="n" then
        onlyNew={}; for _,c in ipairs(all) do onlyNew[c.address]=true end
        self:ask("Connect the new component to the OC network, then press Enter","")
        page=1
      elseif answer==">" then page=math.min(page+1,pages)
      elseif answer=="<" then page=math.max(1,page-1)
      else
        local n=tonumber(answer)
        local selected=n and n%1==0 and choices[n]
        -- Retain support for an exact address for existing/manual workflows.
        if not selected then for _,c in ipairs(choices) do if c.address==answer then selected=c end end end
        if selected then
          local ok,p=pcall(self.components.proxy,self.components,selected.address,methods)
          if ok then
            if not registry[selected.address] then
              local name
              repeat name=self:ask("Friendly name for this component",label):match("^%s*(.-)%s*$") until name~=""
              registry[selected.address]={name=name,kind=selected.kind}
              self.c.componentNames=registry; self.save()
            end
            return p.address or selected.address
          end
          self.out("Component unavailable; refresh and select again.")
        else self.out("Choose a listed number or use R to refresh.") end
      end
    end
  end
  function w:endpoint(label,default)
    default=default or {}
    self:heading("Registering inventory: "..label)
    self.out("Step 1/2: choose the transposer beside "..label..".")
    local address=self:address("Transposer for "..label,{"getInventorySize","getStackInSlot","transferItem"},default.transposer,true)
    local named=self.c.componentNames and self.c.componentNames[address]
    local side
    repeat
      self:heading("Step 2/2: which attached inventory is "..label.."?")
      self.out("Transposer: "..(named and named.name or address))
      self.out("Directions below are FROM the transposer TO each inventory.")
      local _,choices=self.components:inventorySummary(address)
      local defaultNumber
      for i,choice in ipairs(choices) do
        self.out(i..". "..choice.summary)
        if choice.side==default.side then defaultNumber=i end
      end
      if #choices==0 then self.out("No inventories detected. Check adjacency and loaded chunks.") end
      self.out("Choose an INVENTORY number above, or R to refresh this list.")
      self.out("Contents are identification hints; an empty chest can also be selected.")
      local answer=self:ask("Inventory number for "..label,defaultNumber):lower()
      local n=tonumber(answer)
      local choice=n and n%1==0 and choices[n]
      if choice then side=choice.side; self.out("Selected "..label..": "..choice.summary)
      elseif answer~="r" then self.out("That inventory number is not listed. Please choose again.") end
    until side~=nil
    self.out("Give this physical inventory a short ID, e.g. archive or alveary_1.")
    self.out("Reuse its ID when registering the SAME inventory from another transposer.")
    local ep={id=self:ask("Inventory ID for "..label,default.id),transposer=address,side=side}
    assert(ep.id~="","inventory ID cannot be empty"); self.inv:size(ep); return ep
  end
  function w:storage()
    self:heading("Storage setup")
    self.out("Storage: a shared physical archive is the transfer hub. Every breeder transposer must reach that same inventory, or its own registered storage inventory.")
    local kind=self:ask("Storage type: chest or ae2",self.c.storage.kind):lower()
    assert(kind=="chest" or kind=="ae2","choose chest or ae2")
    local s=self.c.storage; s.kind=kind
    if #s.endpoints==0 or self:yes("Reconfigure the primary archive connection?",false) then
      s.endpoints[1]=self:endpoint("Archive chest",s.endpoints[1]); self.save()
    end
    if kind=="ae2" then
      self:heading("ME network access")
      self.out("The archive chest needs an ME STORAGE BUS on your dedicated bee subnet.")
      self.out("Next choose the ME interface/controller adapter used to read network stock.")
      s.address=self:address("ME interface/controller address",{"getItemsInNetwork","store"},s.address)
      self.out("Next choose the OC database used to remember exact bee item types.")
      self.out("Its entries are temporary scratch space; use a dedicated database.")
      s.database=self:address("Database component address",{"clear","get"},s.database)
      s.databaseSlots=self:number("Dedicated database capacity (number of entries shown in its GUI)",1,4096,s.databaseSlots or 9)
      self:exportControl()
      self:heading("Export bus and receiving chest")
      self.out("Choose the adapter exposing the ME export bus that sends bees to a buffer chest.")
      self.out("This buffer is separate from the archive: no storage/import bus on it.")
      local methods={"setExportConfiguration"}
      if s.exportMode=="redstone" then
        methods[#methods+1]="getExportConfiguration"; methods[#methods+1]="getExportSlotSize"
      else methods[#methods+1]="exportIntoSlot" end
      s.exportAddress=self:address("ME export bus component address",methods,s.exportAddress)
      s.exportSide=self:exportDirection(s.exportSide)
      s.buffer=self:endpoint("Isolated export buffer",s.buffer)
      if s.exportMode=="redstone" then
        self.out("Set the ME bus to ACTIVE WITH SIGNAL. An OC Redstone Card must be the sole signal source. Remove the manual lever. Connect the chosen computer output face to the bus through verified redstone wiring. Signal stays ON until an exact physical receipt arrives; bus speed is not assumed.")
        local g=s.exportGate or {}; s.exportGate=g
        g.address=self:address("OC redstone component address",{"getOutput","setOutput"},g.address)
        self.out("OC Redstone Card sides follow the computer's local orientation, not the transposer's world-direction map. Verify the actual powered face before saving this side; use require('sides') aliases where helpful.")
        g.side=self:number("Verified LOCAL computer/redstone output side (different from export-bus side)",0,5,g.side)
        g.off=0; g.on=15
        self.components:proxy(g.address).setOutput(g.side,g.off)
        s.exportTimeout=self:number("Maximum wait for an export receipt, seconds",1,600,s.exportTimeout or 60)
        s.exportPollSeconds=1
        g.verified=self:yes("Have you tested OC signal ON exporting exact stock, and signal OFF stopping it?",false)
      else self.out("The imperative exportIntoSlot callback is broken on the tested Beta 3 server (config=null). Only select callback mode on an installation where a real export has passed.") end
      self.out("Remove fuzzy/crafting upgrades. Clear every export filter. Keep the isolated buffer empty; attach no other automation to it. With redstone mode, only the configured OC output may enable the bus.")
      s.exportIsolated=self:yes("Have you verified those export safety conditions?",false)
      s.storageBusVerified=self:yes("Is the archive exposed by a storage bus on the dedicated subnet?",false)
      self.save()
    end
  end
  function w:exportDirection(default)
    local names={"down","up","north","south","west","east"}
    self:heading("Which way does the export bus send bees?")
    self.out("Start at the ME cable block that carries the export bus.")
    self.out("Follow the bus outward towards the buffer chest receiving the bees:")
    self.out("ME cable block -> export bus -> buffer chest")
    self.out("Example: chest SOUTH of the cable block means south (3).")
    self.out("This is a world direction, not a side of the OC adapter or transposer.")
    self.out("0 down | 1 up | 2 north | 3 south | 4 west | 5 east")
    repeat
      local answer=self:ask("Export direction (name or number)",default~=nil and names[default+1] or nil):lower():match("^%s*(.-)%s*$")
      for i,name in ipairs(names) do if answer==name then return i-1 end end
      local n=tonumber(answer)
      if n and n%1==0 and n>=0 and n<=5 then return n end
      self.out("Enter down, up, north, south, west, east, or a number from 0 to 5.")
    until false
  end
  function w:exportControl()
    self:heading("How should Beeomatic start and stop ME exports?")
    self.out("redstone (recommended for your tested GTNH Beta 3 setup):")
    self.out("  Beeomatic enables the export bus using an OC redstone output.")
    self.out("  It waits for bees in the buffer, then switches the signal off.")
    self.out("  Needs an OC Redstone Card wired to a bus set to ACTIVE WITH SIGNAL.")
    self.out("callback (only for an installation where this command has been tested):")
    self.out("  Asks the ME adapter to export directly using exportIntoSlot.")
    self.out("  This failed with config=null on your tested server. Use redstone here.")
    self.out("Press Enter to keep the option shown in brackets.")
    repeat
      local mode=self:ask("Export control: redstone or callback",self.c.storage.exportMode or "redstone"):lower()
      if mode=="redstone" or mode=="callback" then self.c.storage.exportMode=mode; return end
      self.out("Enter redstone or callback, or press Enter to keep the default.")
    until false
  end
  function w:addAlveary()
    local a={id=self:ask("Unique alveary ID (letters/numbers/underscore)"),enabled=true,priority=#self.c.alvearies+1}
    assert(a.id:match("^[%w_%-]+$"),"invalid alveary ID")
    for _,old in ipairs(self.c.alvearies) do assert(old.id~=a.id,"ID already registered") end
    a.name=self:ask("Friendly alveary name",a.id)
    self.out("Place one adapter against an assembled alveary block; connect it to the OC cable network. Place a transposer directly beside the alveary inventory face and the archive chest. Do not register two blocks of the same multiblock as separate machines.")
    a.address=self:address("Housing component address",{"getQueen","getDrone","getBeeParents","canBreed"})
    a.backend=self:ask("Inventory backend: alveary (direct access) or routed (external gated pipes)","alveary"):lower()
    assert(a.backend=="alveary" or a.backend=="routed","choose alveary or routed")
    local ep=self:endpoint(a.backend=="routed" and "Input staging chest for "..a.name or "Alveary inventory for "..a.name)
    a.transposer=ep.transposer; a.side=ep.side
    a.storage=self:endpoint("Archive chest as viewed by THIS transposer",self.c.storage.endpoints[1])
    assert(a.storage.transposer==a.transposer and a.storage.side~=a.side,"breeder and archive need separate sides on the same transposer")
    local known=false
    for _,x in ipairs(self.c.storage.endpoints) do if x.id==a.storage.id and x.transposer==a.storage.transposer then known=true end end
    if not known then self.c.storage.endpoints[#self.c.storage.endpoints+1]=a.storage end
    local size=self.inv:size(ep)
    if a.backend=="routed" then
      self.out("The inventory just registered is your INPUT STAGING CHEST, not the alveary. Isolate this machine's caste routes and outputs. Both input routes must remain completely stopped while the gate is OFF; do not install return-to-breeder loops.")
      a.routing={output=self:endpoint("Dedicated routing output chest")}
      a.routing.outputInventorySize=self.inv:size(a.routing.output)
      self.out("Redstone output sides follow the controller's local orientation. Verify the physical powered face; do not reuse the transposer's world side numbers.")
      a.routing.gate={address=self:address("Dedicated routing redstone component address",{"setOutput"}),
        side=self:number("Verified LOCAL redstone gate output side",0,5),off=0,on=15}
      self.components:proxy(a.routing.gate.address).setOutput(a.routing.gate.side,0)
      a.routing.verified=self:yes("Have you tested both caste paths, gate isolation, correct housing association and complete output return?",false)
    end
    local slots={inventorySize=size,outputs={}}
    slots.princess=self:number("Princess/queen slot observed through probe (no default)",1,size)
    slots.drone=self:number("Drone input slot observed through probe (no default)",1,size)
    local text=self:ask("Observed product/offspring output slots, comma separated")
    for n in text:gmatch("%d+") do slots.outputs[#slots.outputs+1]=U.assertNumber(n,1,a.routing and a.routing.outputInventorySize or size) end
    assert(#slots.outputs>0,"output slots required")
    self.out("Role check: use expendable analyzed test stock. With drone input EMPTY, manually put a princess in the configured princess slot. This read-only check does not insert or consume bees.")
    self:ask("Press Enter when the princess is present","")
    local p=self.inv:get(ep,slots.princess); assert(B.kind(p)=="princess" and B.scanned(p),"princess slot witness failed")
    local h=self.components:proxy(a.address); local q=h.getQueen()
    if not a.routing then assert(q and U.equal(q.active,p.individual.active),"adapter does not observe that princess; wrong housing address") end
    self.out("Remove princess through GUI. Put one analyzed drone in the drone input, with princess input EMPTY.")
    self:ask("Press Enter to inspect drone","")
    assert(not self.inv:get(ep,slots.princess),"remove test princess first")
    local d=self.inv:get(ep,slots.drone); local hd=h.getDrone()
    assert(B.kind(d)=="drone" and B.scanned(d),"drone slot witness failed")
    if not a.routing then assert(hd and U.equal(hd.active,d.individual.active),"drone adapter association failed") end
    self.out("Remove test drone manually. Observe one complete expendable breeding cycle in this machine. Verify every configured output slot belongs to offspring/products, never upgrades or frames. Return all stock to the archive after testing.")
    slots.verified=self:yes("Have you witnessed and verified the output map?",false)
    a.slots=slots
    self.out("This housing API has no live climate/environment methods. Read its working climate in-game, including heaters/fans, and enter the actual categories.")
    a.environment={temperature=self:ask("Temperature: ICY COLD NORMAL WARM HOT HELLISH"):upper(),
      humidity=self:ask("Humidity: ARID NORMAL DAMP"):upper(),biome=self:ask("Biome"),dimension=self:ask("Dimension")}
    local e=a.environment; e.flowers={}
    local flowers=self:ask("Verified flower-provider IDs, comma separated (e.g. flowers)")
    for f in flowers:gmatch("[^, ]+") do e.flowers[f]=true end
    e.daylightManaged=self:yes("Does this installation support the required day/night schedule?",false)
    e.rainProtected=self:yes("Is operation protected from rain?",false)
    e.skyAccess=self:yes("Does the bee housing have valid sky access?",false)
    e.verified=self:yes("Have you verified this operating environment in-game?",false)
    e.provenance="manual in-game attestation"; a.confirmed={}
    self.c.alvearies[#self.c.alvearies+1]=a; self.save()
    self.out("Saved "..a.id.." physical layout (sides relative to "..a.transposer.."):")
    self.out("[Archive "..a.storage.id..", side "..a.storage.side.."] -- [Transposer] -- ["..(a.routing and "Input staging" or "Alveary")..", side "..a.side.."]")
    if a.routing then self.out("  Input staging -- gated caste pipes --> housing "..a.address.." -- output pipes --> "..a.routing.output.id.." (side "..a.routing.output.side..")") end
    self.out("[OC computer] -- OC cable -- [Adapter at housing "..a.address.."]")
  end
  function w:scanner()
    local s=self.c.scanner
    s.enabled=self:yes("Configure automated scanner? (Otherwise analyze bees manually)",s.enabled)
    if s.enabled then
      self.out("Use dedicated input/output inventories and external pipes routing through a Forestry analyzer or supported scanner. Supply its required consumables/power. No other items may enter this path. One reserved stack is processed at a time; this program calls no imaginary analyze method.")
      s.storage=self:endpoint("Scanner's view of archive chest",self.c.storage.endpoints[1])
      s.input=self:endpoint("Scanner input staging chest",s.input)
      s.output=self:endpoint("Scanner output staging chest",s.output)
      assert(s.storage.transposer==s.input.transposer and s.output.transposer==s.input.transposer,"scanner staging needs a common transposer")
      s.inputSlot=self:number("Input staging slot",1,self.inv:size(s.input),1)
      s.timeout=self:number("Scanner timeout in seconds",30,7200,600)
      assert(#self.inv:scan(s.input)==0 and #self.inv:scan(s.output)==0,"empty scanner staging inventories first")
      s.isolatedVerified=self:yes("Have you tested one input stack producing one analyzed output stack with equal count?",false)
    end
    self.save()
  end
  function w:optional()
    local t=self.c.templates
    t.enabled=self:yes("Enable selective genetic imprinting from reference drones?",t.enabled)
    if t.enabled then
      t.endpointId=self:ask("Template archive inventory ID",self.c.storage.endpoints[1].id)
      t.slot=self:number("Reserved reference drone slot",1,100000,t.slot)
      t.reserve=self:number("Minimum reference drones to retain",1,64,t.reserve or 1)
    end
    local r=self.c.robot
    r.enabled=self:yes("Register an optional wireless foundation helper?",r.enabled)
    if r.enabled then
      r.modem=self:address("Local wireless modem address",{"send","open","isWireless"},r.modem)
      r.address=self:ask("Robot wireless modem address",r.address)
      r.alvearyId=self:ask("ID of the alveary this stationary robot's foundation position serves",r.alvearyId)
      r.port=self:number("Robot command port",1,65535,r.port)
      r.replyPort=self:number("Reply port",1,65535,r.replyPort)
    end
    self.out("Offspring, unused bees and products are archived. Add storage space or dedicated reachable archive endpoints as needed. Back up the data directory with the computer stopped. Frames and upgrades are never touched.")
    self.save()
  end
  function w:run(reconfigure)
    if reconfigure then self.c.setupStep=1; self.save() end
    self.out("Beeomatic setup. Completed sections and component names are saved.")
    self.out("For detailed hardware diagnostics, use Beeomatic doctor --probe.")
    local step=self.c.setupStep or 1
    if step<=1 then self:storage(); self.c.setupStep=2; self.save() end
    if step<=2 then
      while #self.c.alvearies==0 or self:yes("Register another alveary?",false) do self:addAlveary() end
      self.c.setupStep=3; self.save()
    end
    if step<=3 then self:scanner(); self.c.setupStep=4; self.save() end
    if step<=4 then self:optional(); self.c.setupStep=5; self.save() end
    C.validate(self.c); self.out("Configuration saved. Run Beeomatic doctor for hardware validation before breeding.")
  end
  return w
end
return M
