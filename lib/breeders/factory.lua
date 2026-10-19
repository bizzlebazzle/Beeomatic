local M={}
function M.new(a,inv,components)
  local kind=a.backend or "alveary"
  assert(kind=="alveary" or kind=="routed","unsupported breeder backend")
  return require("lib.breeders."..kind).new(a,inv,components)
end
return M
