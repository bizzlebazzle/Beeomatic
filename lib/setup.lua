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
    self.out("Give this physical inventory a short ID, e.g. port_1 or alveary_1.")
    self.out("Reuse its ID when registering the SAME inventory from another transposer.")
    local ep={id=self:ask("Inventory ID for "..label,default.id),transposer=address,side=side}
    assert(ep.id~="","inventory ID cannot be empty"); self.inv:size(ep); return ep
  end
  function w:port(label,default,transposer)
    local ep=self:endpoint(label,default,transposer)
    ep.address=self:address("Adapter at "..label,{"getInterfaceConfiguration","setInterfaceConfiguration"},default and default.address)
    ep.managed=true; ep.princessSlot=1; ep.droneSlot=2; ep.returnSlot=9
    assert(self.inv:size(ep)==9,"use a full-block ME Interface with nine inventory slots")
    for _,old in ipairs(self.c.storage.endpoints) do
      assert(old.id==ep.id or old.address~=ep.address,"Interface already registered under another port ID")
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
  function w:addAlveary()
    local draft=self.c.alvearyDraft or {stage=1,machine={enabled=true,priority=#self.c.alvearies+1}}
    self.c.alvearyDraft=draft; local a=draft.machine; self.save()
    self.out("Alveary registration saves each stage. Type back to revisit the previous stage.")
    while draft.stage<=4 do
      local success,err=pcall(function()
        if draft.stage==1 then
          a.id=self:ask("Unique alveary ID (letters/numbers/underscore)",a.id)
          assert(a.id:match("^[%w_%-]+$"),"invalid alveary ID")
          for _,old in ipairs(self.c.alvearies) do assert(old.id~=a.id,"ID already registered") end
          a.name=self:ask("Friendly alveary name",a.name or a.id)
        elseif draft.stage==2 then
          self.out("Connect the housing adapter and a transposer touching the housing inventory and its storage port. Register each multiblock only once.")
          a.address=self:address("Housing component address",{"getQueen","getDrone","getBeeParents","canBreed"},a.address)
          a.backend=self:ask("Inventory backend: alveary (direct access) or routed (external gated pipes)",a.backend or "alveary"):lower()
          assert(a.backend=="alveary" or a.backend=="routed","choose alveary or routed")
          if a.backend=="alveary" then a.routing=nil end
          local ep=self:endpoint(a.backend=="routed" and "Input staging chest for "..a.name or "Alveary inventory for "..a.name,{id=a.id,transposer=a.transposer,side=a.side})
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
          self:beeWitness(ep,slots.princess,"princess",slots.drone,h)
          self.out("Remove the princess through the GUI before testing the drone.")
          self:beeWitness(ep,slots.drone,"drone",slots.princess,h)
          self.out("Remove the test drone. Before breeding, verify this alveary can complete a normal cycle and return the test stock to storage.")
          if a.routing then slots.verified=self:yes("Have you tested the isolated output staging route and slot map?",false)
          else slots.verified=true end
          a.slots=slots
        else
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
      self.out("Register the shared analyser station. Unknown ME bees are inspected here; all initial drones must be analysed before breeding starts.")
    else s.enabled=self:yes("Configure automated scanner? (Otherwise analyze bees manually)",s.enabled) end
    if s.enabled then
      self.out("Use dedicated input/output inventories and external pipes routing through a Forestry analyzer or supported scanner. Supply its required consumables/power. No other items may enter this path. One reserved stack is processed at a time; this program calls no imaginary analyze method.")
      s.storage=self.c.storage.kind=="me_interface" and self:port("Shared scanner ME Interface",s.storage or {id="scanner_port"}) or
        self:endpoint("Scanner's view of archive chest",s.storage or self.c.storage.endpoints[1])
      s.input=self:endpoint("Analyser input (or isolated input staging)",s.input,s.storage.transposer)
      s.output=self:endpoint("Analyser output (or isolated output staging)",s.output,s.storage.transposer)
      assert(s.storage.transposer==s.input.transposer and s.output.transposer==s.input.transposer,"scanner staging needs a common transposer")
      s.inputSlot=self:number("Witnessed input slot (Forestry analyser: 3)",1,self.inv:size(s.input),s.inputSlot)
      if self.c.storage.kind=="me_interface" then
        local previous=s.outputSlots and table.concat(s.outputSlots,",") or nil
        s.outputSlots={}
        local text=self:ask("Witnessed output slots (Forestry analyser: 9,10,11,12; exclude consumables)",previous)
        for n in text:gmatch("%d+") do s.outputSlots[#s.outputSlots+1]=U.assertNumber(n,1,self.inv:size(s.output)) end
        assert(#s.outputSlots>0,"scanner output slots required")
        for _,slot in ipairs(s.outputSlots) do
          assert(s.input.side~=s.output.side or slot~=s.inputSlot,"scanner input and output slots overlap")
          assert(not self.inv:get(s.output,slot),"empty scanner output slots first")
        end
        assert(not self.inv:get(s.input,s.inputSlot),"empty scanner input slot first")
        assert(s.storage.side~=s.input.side and s.storage.side~=s.output.side,"scanner cannot use Interface slots as analyser input/output")
        self:registerEndpoint(s.storage)
      end
      s.timeout=self:number("Scanner timeout in seconds",30,7200,600)
      if self.c.storage.kind~="me_interface" then assert(#self.inv:scan(s.input)==0 and #self.inv:scan(s.output)==0,"empty scanner staging inventories first") end
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
        t.endpointId=self:ask("Template archive inventory ID",self.c.storage.endpoints[1].id)
        t.slot=self:number("Reserved reference drone slot",1,100000,t.slot)
      end
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
