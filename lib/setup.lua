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
    if value:lower()=="back" then error({setupBack=true},0) end
    if value=="" and default~=nil then return tostring(default) end; return value
  end
  function w:yes(label,default) return self:ask(label,default and "yes" or "no"):lower()=="yes" end
  function w:number(label,lo,hi,default)
    while true do local ok,n=pcall(U.assertNumber,self:ask(label,default),lo,hi); if ok then return n end; self.out(tostring(n)) end
  end
  function w:autoId(prefix)
    local used={}
    local function collect(value)
      if type(value)~="table" then return end
      if value.id then used[value.id]=true end
      for _,child in pairs(value) do collect(child) end
    end
    collect(self.c)
    for _,id in pairs(self.c.inventoryIds or {}) do used[id]=true end
    self.c.nextIds=self.c.nextIds or {}
    local n=self.c.nextIds[prefix] or 1
    while used[prefix..n] do n=n+1 end
    self.c.nextIds[prefix]=n+1
    return prefix..n
  end
  function w:inventoryId(address,side,default)
    local key=address..":"..side
    local ids=self.c.inventoryIds or {}; self.c.inventoryIds=ids
    local found
    local function find(value)
      if type(value)~="table" then return end
      if value.id and value.transposer==address and value.side==side then found=found or value.id end
      for _,child in pairs(value) do find(child) end
    end
    -- Registered storage takes precedence over unfinished setup defaults.
    find(self.c.storage.endpoints); find(self.c)
    -- A supplied archive default also identifies its view from another transposer.
    ids[key]=found or ids[key] or (default and default.id) or self:autoId("inventory_")
    self.save()
    return ids[key]
  end
  function w:selectId(label,choices,current)
    assert(#choices>0,"no registered choices for "..label)
    local selected
    for n,choice in ipairs(choices) do
      self.out(n..". "..(choice.name or choice.id))
      if choice.id==current then selected=n end
    end
    return choices[self:number(label,1,#choices,selected or 1)].id
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
  function w:endpoint(label,default,fixedTransposer)
    default=default or {}
    self:heading("Registering inventory: "..label)
    self.out("Step 1/2: choose the transposer beside "..label..".")
    local address=fixedTransposer or self:address("Transposer for "..label,{"getInventorySize","getStackInSlot","transferItem"},default.transposer,true)
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
    local ep={id=self:inventoryId(address,side,default),transposer=address,side=side}
    self.out("Inventory reference: "..ep.id.." (assigned automatically)")
    self.inv:size(ep); return ep
  end
  function w:alvearyEndpoint(name,default)
    self:heading("Find "..name.." automatically")
    self.out("Choose the transposer touching the alveary itself.")
    local address=self:address("Transposer for "..name,{"getInventorySize","getStackInSlot","transferItem"},default.transposer,true)
    local p=self.components:proxy(address)
    local sides={"down","up","north","south","west","east"}
    while true do
      self.out("Put a drone in "..name.."'s drone slot (slot 2). Leave its princess/queen slot (slot 1) empty so mating cannot start. Analysis is not required.")
      self.out("Keep drones out of slot 2 in other unregistered nine-slot inventories touching this transposer, including ME Interfaces.")
      self:ask("Press Enter to detect the alveary, or type back to change the connection","")
      local matches,unreadable={},false
      for side=0,5 do
        local registered=false
        for _,a in ipairs(self.c.alvearies) do
          if a.transposer==address and a.side==side then registered=true end
        end
        if not registered then
          local success,match=pcall(function()
            if p.getInventorySize(side)~=9 then return false end
            return not p.getStackInSlot(side,1) and B.kind(p.getStackInSlot(side,2))=="drone"
          end)
          if not success then unreadable=true; self.out("Cannot read "..sides[side+1].." ("..side.."). Check the connection and loaded chunks.")
          elseif match then matches[#matches+1]=side end
        end
      end
      if #matches==1 and not unreadable then
        local side=matches[1]
        local ep={id=self:inventoryId(address,side,default),transposer=address,side=side}
        self.out("Detected "..name..": "..sides[side+1].." ("..side..") from the transposer. Leave the drone there for the connection check.")
        return ep
      elseif #matches>1 then
        self.out("More than one inventory matches: "..table.concat(matches,", ")..". Leave a drone only in the alveary being added, then retry.")
      elseif #matches==0 then
        self.out("No unregistered alveary found. Check the transposer, the drone in slot 2, and the empty princess/queen slot; then retry.")
      end
    end
  end
  function w:port(label,default,transposer)
    local ep
    while true do
      ep=self:endpoint(label,default,transposer)
      local size=self.inv:size(ep)
      if size==9 then break end
      self.out("Selected inventory reports "..tostring(size).." slots through transposer "..ep.transposer..", side "..ep.side.."; expected 9 for an ME Interface.")
      self.out("This checks the transposer's attached inventory, not the OC Interface adapter. Select the inventory on the side touching your full-block Interface, rather than the analyser or a staging chest.")
      self.out("Choose the inventory again, or type back to revisit the previous setup section.")
    end
    ep.address=self:address("Adapter at "..label,{"getInterfaceConfiguration","setInterfaceConfiguration"},default and default.address)
    ep.managed=true; ep.princessSlot=1; ep.droneSlot=2; ep.returnSlot=9
    for _,old in ipairs(self.c.storage.endpoints) do
      assert(old.address~=ep.address or old.transposer==ep.transposer and old.side==ep.side,
        "Interface adapter already registered against a different inventory connection")
      if old.address==ep.address then ep.id=old.id end
    end
    return ep
  end
  function w:registerEndpoint(ep)
    for n,old in ipairs(self.c.storage.endpoints) do
      if old.id==ep.id and old.transposer==ep.transposer then self.c.storage.endpoints[n]=ep; return end
    end
    self.c.storage.endpoints[#self.c.storage.endpoints+1]=ep
  end
  function w:beeWitness(ep,slot,kind,otherSlot,housing)
    local role=kind=="princess" and "princess" or "drone"
    while true do
      self.out("In "..ep.id..", put a "..role.." in alveary slot "..slot..". Leave slot "..otherSlot.." empty. Analysis is not required for this placement check.")
      self:ask("Press Enter to check, or type back to change the inventory connection","")
      local stack=self.inv:get(ep,slot); local other=self.inv:get(ep,otherSlot)
      local problem
      if other then problem="Slot "..otherSlot.." is occupied. Remove that bee first so mating cannot start."
      elseif not stack then
        problem="Slot "..slot.." is empty through transposer "..ep.transposer..", side "..ep.side..". If the bee is visible in the GUI, type back and check which alveary inventory you selected."
      elseif B.kind(stack)~=kind then
        problem="Slot "..slot.." contains "..tostring(stack.label or stack.name).." ("..tostring(B.kind(stack) or stack.name).."). Use a "..role.." for this check."
      elseif housing then
        local observed
        if kind=="princess" then observed=housing.getQueen() else observed=housing.getDrone() end
        if kind=="drone" and housing.getQueen() then
          problem="The housing adapter still sees a princess/queen after its removal. Check that this adapter belongs to the selected alveary."
        elseif not observed then
          problem="The transposer sees the "..role..", but the housing adapter does not. Type back and select the adapter touching this alveary."
        elseif B.scanned(stack) and (not U.equal(observed.active,stack.individual.active) or not U.equal(observed.inactive,stack.individual.inactive)) then
          problem="The housing adapter sees different genetics. Type back and check the housing adapter/selected alveary."
        elseif stack.individual and stack.individual.ident and observed.ident and stack.individual.ident~=observed.ident then
          problem="The housing adapter sees a different bee species. Type back and check the selected housing."
        end
      end
      if not problem then self.out("Confirmed "..role.." in slot "..slot.."."); return stack end
      self.out(problem)
    end
  end
  function w:storage()
    self:heading("Storage setup")
    self.out("ME: one Interface beside each alveary transposer, all on the same AE network. Bees live in ME cells; one shared station handles scanning.")
    local kind
    repeat
      kind=self:ask("Storage: me or chest",self.c.storage.kind=="chest" and "chest" or "me"):lower()
      if kind=="me" or kind=="interface" then kind="me_interface" end
    until kind=="me_interface" or kind=="chest"
    local changed=kind~=self.c.storage.kind
    if changed then
      self.c.storage={kind=kind,endpoints={}}
      self.c.scanner={enabled=false}; self.c.templates={enabled=false}
      self.c.storageRemap={}
      for _,a in ipairs(self.c.alvearies) do self.c.storageRemap[a.id]=true end
      self.save()
    end
    local s=self.c.storage
    if kind=="me_interface" then
      s.address=self:address("ME network reader (Interface/controller)",{"getItemsInNetwork","store"},s.address)
      s.database=self:address("Dedicated database",{"clear","get"},s.database)
      s.databaseSlots=self:number("Database entry capacity",1,4096,s.databaseSlots or 9)
      s.timeout=self:number("Maximum wait for ME stock/returns, seconds",1,600,s.timeout or 60)
      s.verified=self:yes("All ports belong to this ME network, with no storage buses, fuzzy/crafting upgrades or other filter controllers?",s.verified)
      self.out("Each port uses slot 1 for princesses, 2 for drones and 9 for returns. Keep other filters clear. Run doctor --interface PORT_ID to test a port.")
    elseif #s.endpoints==0 or self:yes("Change the primary archive connection?",false) then
      s.endpoints[1]=self:endpoint("Archive chest",s.endpoints[1])
    end
    if self.c.storageRemap then
      for _,a in ipairs(self.c.alvearies) do if self.c.storageRemap[a.id] then
        a.storage=kind=="me_interface" and self:port("ME Interface for "..a.name,{id="port_"..a.id},a.transposer) or
          self:endpoint("Archive for "..a.name,s.endpoints[1],a.transposer)
        self:registerEndpoint(a.storage); self.c.storageRemap[a.id]=nil; self.save()
      end end
      self.c.storageRemap=nil
    end
    self.save()
  end
  function w:climate(a)
    self.out("Enter this alveary's working temperature and humidity, including any heaters/fans.")
    local function choice(label,values,default)
      while true do
        local value=self:ask(label,default):upper():match("^%s*(.-)%s*$")
        if values[value] then return value end
        self.out("Choose one of the listed climate values.")
      end
    end
    local e=U.copy(a.environment or {})
    e.temperature=choice("Temperature: ICY COLD NORMAL WARM HOT HELLISH",{ICY=true,COLD=true,NORMAL=true,WARM=true,HOT=true,HELLISH=true},e.temperature)
    e.humidity=choice("Humidity: ARID NORMAL DAMP",{ARID=true,NORMAL=true,DAMP=true},e.humidity)
    e.verified=true; e.provenance="setup-entered climate"
    if not a.environment or e.temperature~=a.environment.temperature or e.humidity~=a.environment.humidity then a.confirmed={} end
    a.environment=e
    self.out("Each bee's required flower type is shown in alveary status. Supply those flowers in-world.")
  end
  function w:editAlveary(a)
    local draft=U.copy(a)
    self.out("Configure "..a.id..". Enter keeps the current value. Change heaters/fans in-world before recording their climate here.")
    repeat draft.name=self:ask("Friendly alveary name",draft.name):match("^%s*(.-)%s*$") until draft.name~=""
    self:climate(draft)
    draft.priority=self:number("Scheduling priority (lower runs first)",1,100000,draft.priority or 99)
    draft.enabled=self:yes("Enabled for scheduling?",draft.enabled~=false)
    for key,value in pairs(draft) do a[key]=value end
    self.save(); self.out("Saved settings for "..a.id..". Run Beeomatic resume to retry blocked work.")
  end
  function w:addAlveary()
    local draft=self.c.alvearyDraft or {stage=1,machine={enabled=true,priority=#self.c.alvearies+1}}
    self.c.alvearyDraft=draft; local a=draft.machine; self.save()
    self.out("Alveary registration saves each stage. Type back to revisit the previous stage.")
    while draft.stage<=4 do
      local success,err=pcall(function()
        if draft.stage==1 then
          a.id=a.id or self:autoId("alveary_")
          for _,old in ipairs(self.c.alvearies) do assert(old.id~=a.id,"ID already registered") end
          a.name=self:ask("Friendly alveary name",a.name or "Alveary "..(#self.c.alvearies+1))
        elseif draft.stage==2 then
          self.out("Connect the housing adapter and a transposer touching the housing inventory and its storage port. Register each multiblock only once.")
          a.address=self:address("Housing component address",{"getQueen","getDrone","getBeeParents","canBreed"},a.address)
          a.backend=self:ask("Inventory backend: alveary (direct access) or routed (external gated pipes)",a.backend or "alveary"):lower()
          assert(a.backend=="alveary" or a.backend=="routed","choose alveary or routed")
          if a.backend=="alveary" then a.routing=nil end
          local connection={id=a.id,transposer=a.transposer,side=a.side}
          local ep=a.backend=="routed" and self:endpoint("Input staging chest for "..a.name,connection) or self:alvearyEndpoint(a.name,connection)
          a.transposer=ep.transposer; a.side=ep.side
          a.storage=self.c.storage.kind=="me_interface" and
            self:port("ME Interface for "..a.name,a.storage or {id="port_"..a.id},a.transposer) or
            self:endpoint("Archive for "..a.name,a.storage or self.c.storage.endpoints[1],a.transposer)
          assert(a.storage.side~=a.side,"breeder and storage need separate sides")
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
        elseif draft.stage==3 then
          local ep={id=a.id,transposer=a.transposer,side=a.side}
          local size=self.inv:size(ep)
          local slots={inventorySize=size,outputs={}}
          if not a.routing then
            assert(size==9,"Expected the nine-slot Forestry alveary inventory. Type back and check the selected inventory connection.")
            slots.princess=1; slots.drone=2
            slots.outputs={3,4,5,6,7,8,9}
            self.out("Forestry alveary slots: 1 princess/queen, 2 drone, 3-9 products/offspring. These are assigned automatically.")
          else
            slots.princess=self:number("Princess input staging slot",1,size,a.slots and a.slots.princess)
            slots.drone=self:number("Drone input staging slot",1,size,a.slots and a.slots.drone)
            local text=self:ask("Product/offspring output staging slots, comma separated")
            for n in text:gmatch("%d+") do slots.outputs[#slots.outputs+1]=U.assertNumber(n,1,a.routing.outputInventorySize) end
            assert(#slots.outputs>0,"output slots required")
          end
          self.out("Connection check: test one bee at a time. This check only reads inventories and does not move bees.")
          local h=not a.routing and self.components:proxy(a.address) or nil
          if not a.routing then
            self:beeWitness(ep,slots.drone,"drone",slots.princess,h)
            self.out("Remove the drone through the GUI before testing the princess.")
            self:beeWitness(ep,slots.princess,"princess",slots.drone,h)
          else
            self:beeWitness(ep,slots.princess,"princess",slots.drone,h)
            self.out("Remove the princess through the GUI before testing the drone.")
            self:beeWitness(ep,slots.drone,"drone",slots.princess,h)
          end
          self.out("Remove the test bee. Before breeding, verify this alveary can complete a normal cycle and return the test stock to storage.")
          if a.routing then slots.verified=self:yes("Have you tested the isolated output staging route and slot map?",false)
          else slots.verified=true end
          a.slots=slots
        else
          self:climate(a)
        end
      end)
      if success then draft.stage=draft.stage+1
      elseif type(err)=="table" and err.setupBack then
        if draft.stage==1 then self.save(); error(err,0) end
        draft.stage=draft.stage-1
      else self.save(); error(err,0) end
      self.save()
    end
    self:registerEndpoint(a.storage)
    self.c.alvearies[#self.c.alvearies+1]=a; self.c.alvearyDraft=nil; self.save()
    self.out("Saved "..a.id..": [Storage "..a.storage.id..", side "..a.storage.side.."] -- [Transposer "..a.transposer.."] -- ["..a.name..", side "..a.side.."]")
    self.out("Housing adapter: "..a.address)
  end
  function w:scanner()
    local s=self.c.scanner
    if self.c.storage.kind=="me_interface" then
      s.enabled=true
      self.out("Scanner: ME Interface -> transposer -> input chest. Your pipes extract from the chest, analyse bees and return them directly to an unconfigured Interface slot on the same ME network.")
      self.out("Keep the external scanner path empty before first use and dedicated to Beeomatic. Supply honey/power; do not insert or remove bees elsewhere while a scanner batch is outstanding.")
      s.storage=self:port("Shared scanner ME Interface",s.storage or {id="scanner_port"})
      s.input=self:endpoint("Scanner input chest",s.input,s.storage.transposer)
      assert(s.storage.side~=s.input.side,"scanner input chest must be separate from the Interface")
      s.mode="external"; s.output=nil; s.outputSlots=nil; s.inputSlot=nil; s.isolatedVerified=nil
      s.timeout=600; s.batchSize=nil
      self:registerEndpoint(s.storage); self.save()
      self.out("Scanner saved. Input slots are chosen automatically; analysed returns are verified through ME. All initial drones are scanned before breeding starts.")
      return
    end
    s.enabled=self:yes("Configure automated scanner? (Otherwise analyze bees manually)",s.enabled)
    if s.enabled then
      self.out("Use dedicated input/output inventories and external pipes routing through a Forestry analyzer or supported scanner. Supply its required consumables/power. No other items may enter this path. One reserved stack is processed at a time; this program calls no imaginary analyze method.")
      s.storage=self:endpoint("Scanner's view of archive chest",s.storage or self.c.storage.endpoints[1])
      s.input=self:endpoint("Analyser input (or isolated input staging)",s.input,s.storage.transposer)
      s.output=self:endpoint("Analyser output (or isolated output staging)",s.output,s.storage.transposer)
      assert(s.storage.transposer==s.input.transposer and s.output.transposer==s.input.transposer,"scanner staging needs a common transposer")
      s.inputSlot=self:number("Witnessed input slot (Forestry analyser: 3)",1,self.inv:size(s.input),s.inputSlot)
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
      if self.c.storage.kind=="me_interface" then
        local ep=self:endpoint("Temporary reference drone witness inventory")
        local slot=self:number("Analysed reference drone witness slot",1,self.inv:size(ep))
        local s=self.inv:get(ep,slot)
        assert(B.kind(s)=="drone" and B.scanned(s) and type(s.tag)=="string","reference must be an analysed drone with exact NBT")
        t.identity=B.identity(s); t.endpointId=nil; t.slot=nil
        self.out("Reference genotype recorded. Return the drone to ME; its reserve is protected by exact identity.")
      else
        t.endpointId=self:selectId("Reference drone archive number",self.c.storage.endpoints,t.endpointId)
        t.slot=self:number("Reserved reference drone slot",1,100000,t.slot)
      end
      t.reserve=self:number("Minimum reference drones to retain",1,64,t.reserve or 1)
    end
    self.out("Offspring and products are retained. Back up data with the worker stopped. Frames and upgrades are never touched.")
    self.save()
  end
  function w:run(reconfigure)
    if reconfigure then self.c.setupStep=1; self.save() end
    self.out("Beeomatic setup. Progress is saved; type back to revisit the previous section.")
    self.out("For detailed hardware diagnostics, use Beeomatic doctor --probe.")
    while (self.c.setupStep or 1)<=4 do
      local step=self.c.setupStep or 1
      local success,err=pcall(function()
        if step==1 then self:storage()
        elseif step==2 then
          while self.c.alvearyDraft or #self.c.alvearies==0 or self:yes("Register another alveary?",false) do self:addAlveary() end
        elseif step==3 then self:scanner()
        else self:optional() end
      end)
      if success then self.c.setupStep=step+1
      elseif type(err)=="table" and err.setupBack then self.c.setupStep=math.max(1,step-1)
      else error(err,0) end
      self.save()
    end
    C.prunePorts(self.c); self.save()
    C.validate(self.c); self.out("Configuration saved. Run Beeomatic doctor for hardware validation before breeding.")
  end
  return w
end
return M
