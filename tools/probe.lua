local source=debug.getinfo(1,"S").source:gsub("^@","")
local root=(source:match("^(.*)[/\\]tools[/\\]") or ".")
package.path=root.."/?.lua;"..package.path
require("lib.ui.diagnostics").probe(require("lib.components").new())
