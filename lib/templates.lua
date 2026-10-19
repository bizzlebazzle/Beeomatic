local B=require("lib.bees"); local G=require("lib.genetics")
local M={}
function M.get(config,items)
  if not config.enabled then return nil end
  for _,i in ipairs(items) do
    if (config.identity and B.identity(i.stack)==config.identity) or
      (not config.identity and i.endpoint.id==config.endpointId and i.slot==config.slot) then
      assert(B.kind(i.stack)=="drone" and B.scanned(i.stack),"template must be an analyzed drone")
      assert(i.stack.size>=(config.reserve or 1),"replenish template drones; reserve protected")
      return i
    end
  end
  error("Template drone missing from registered location")
end
function M.complete(p,d,template)
  return G.templateMatch(p,template.stack.individual.active) and G.templateMatch(d,template.stack.individual.active)
end
-- Imprinting means selective crossing using reference drone genes, like the original.
-- No unsupported Gendustry machine methods are called. Machine-made templates can
-- be supplied as analyzed reference drones through the registered storage slot.
return M
