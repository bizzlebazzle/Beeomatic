local source=debug.getinfo(1,"S").source:gsub("^@","")
local root=source:match("^(.*)[/\\][^/\\]+$") or "."
package.path=root.."/?.lua;"..root.."/?/init.lua;"..package.path
return require("lib.cli").main(root,{...})
