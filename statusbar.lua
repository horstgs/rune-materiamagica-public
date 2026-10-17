-- statusbar.lua -- character name/level in the status area.

local charname = require("charname")
local style = rune.style
local level = nil
local totallevel = nil

rune.gmcp.on("Char.Status", function(data)
    if data then
        level = data.level
        totallevel = data.totallevel
        rune.ui.refresh_bars()
    end
end)

rune.ui.bar("status", function()
    local name = charname.get()
    if not name then return "" end
    local label = style.white(name)
    if level then
        if totallevel and totallevel ~= level then
            return label .. " " .. style.magenta("[") .. style.white(level .. ":" .. totallevel) .. style.magenta("]")
        else
            return label .. " " .. style.magenta("[") .. style.white(level) .. style.magenta("]")
        end
    end
    return label
end)
