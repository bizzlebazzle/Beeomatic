local U=require("lib.util"); local C=require("lib.config"); local B=require("lib.bees")
local M={}
function M.new(config,components,inv,save,read,out)
  local w={c=config,components=components,inv=inv,save=save,read=read or io.read,out=out or print}
  function w:ask(label,default)
    self.out(label..(default~=nil and (" ["..tostring(default).."]") or "")..": ")
    local value=self.read(); assert(value,"Setup interrupted; completed sections are saved")
    if value=="" and default~=nil then return tostring(default) end; return value
  end
  function w:yes(label,default) return self:ask(label,default and "yes" or "no"):lower()=="yes" end
  function w:number(label,lo,hi,default)
    while true do local ok,n=pcall(U.assertNumber,self:ask(label,default),lo,hi); if ok then return n end; self.out(tostring(n)) end
  end
  function w:address(label,methods,default)
    while true do local a=self:ask(label,default); local ok,p=pcall(self.components.proxy,self.components,a,methods)
      if ok then return p.address or a end; self.out(tostring(p))
    end
  end
  function w:endpoint(label,default)
    default=default or {}
    self.out(label..": put this inventory directly against the chosen transposer. Sides are world directions: 0 down, 1 up, 2 north, 3 south, 4 west, 5 east.")
    local address=self:address("Full transposer address",{"getInventorySize","getStackInSlot","transferItem"},default.transposer)
    for _,i in ipairs(self.components:inventories(address)) do self.out("  side "..i.side..": "..i.size.." slots") end
    local side=self:number("Inventory side",0,5,default.side)
    local ep={id=self:ask("Physical inventory ID (use SAME ID for views of the SAME shared chest)",default.id),transposer=address,side=side}
    assert(ep.id~="","inventory ID cannot be empty"); self.inv:size(ep); return ep
  end
  function w:storage()
    self.out("Storage: a shared physical archive is the transfer hub. Every breeder transposer must reach that same inventory, or its own registered storage inventory.")
    local kind=self:ask("Storage type: chest or ae2",self.c.storage.kind):lower()
    assert(kind=="chest" or kind=="ae2","choose chest or ae2")
    local s=self.c.storage; s.kind=kind
    if #s.endpoints==0 or self:yes("Reconfigure the primary archive connection?",false) then
      s.endpoints[1]=self:endpoint("Archive chest",s.endpoints[1]); self.save()
    end
    if kind=="ae2" then
      self.out("Attach an ME STORAGE BUS to the archive. Keep it on a dedicated bee subnet. Add an adapter on an ME interface/controller, database component, and an adapter exposing a separate export bus into a buffer chest. The buffer MUST NOT have a storage/import bus.")
      s.address=self:address("ME interface/controller address",{"getItemsInNetwork","store"},s.address)
      s.database=self:address("Database component address",{"clear","get"},s.database)
      s.databaseSlots=self:number("Dedicated database capacity (number of entries shown in its GUI)",1,4096,s.databaseSlots or 9)
      s.exportAddress=self:address("ME export bus component address",{"setExportConfiguration","exportIntoSlot"},s.exportAddress)
      s.exportSide=self:number("Direction the export bus faces (relative to its host block)",0,5,s.exportSide)
      s.buffer=self:endpoint("Isolated export buffer",s.buffer)
      self.out("Remove fuzzy/crafting upgrades. Clear all export filter slots. Inhibit normal export with a redstone card. Verify a manually requested export still works using doctor probes on your GTNH version.")
      s.exportIsolated=self:yes("Have you verified those export safety conditions?",false)
      s.storageBusVerified=self:yes("Is the archive exposed by a storage bus on the dedicated subnet?",false)
      self.save()
    end
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
    local ep=self:endpoint("This alveary's exposed inventory")
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
      a.routing.gate={address=self:address("Dedicated routing redstone component address",{"setOutput"}),
        side=self:number("Gate output side",0,5),off=0,on=15}
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
    require("lib.ui.diagnostics").probe(self.components,self.out)
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
