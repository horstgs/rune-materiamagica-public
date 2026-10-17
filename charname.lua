-- charname.lua -- GMCP character name, shared by statusbar and the history panes.

local M = {}
local name = nil
local callbacks = {}

function M.set(n)
    local v = tostring(n or "")
    if v == name then return end
    local old = name
    name = v
    for _, cb in ipairs(callbacks) do cb(old, v) end
end

function M.get()
    return name
end

function M.key(prefix)
    local k = tostring(name or ""):gsub("[^%w_-]", "_"):lower()
    return prefix .. "." .. k
end

function M.on_change(cb)
    callbacks[#callbacks + 1] = cb
end

rune.gmcp.subscribe("Char")

rune.gmcp.on("Char.Base", function(data)
    if data and data.name then M.set(data.name) end
end)

rune.trigger.regex("Welcome( back)? to Materia Magica", function()
    if rune.gmcp.is_enabled() then
        rune.gmcp.send("char.base", { [""] = "" })
        rune.gmcp.send("char.status", { [""] = "" })
    end
end, { name = "charname-welcome" })

rune.trigger.regex("^You are player \\[", function()
    if rune.gmcp.is_enabled() then
        rune.gmcp.send("char.base", { [""] = "" })
        rune.gmcp.send("char.status", { [""] = "" })
    end
end, { name = "charname-welcome-fresh" })

return M
