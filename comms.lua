-- comms.lua -- unified communication pane with a per-channel filter.
--
-- Routes tell/clan/talk/relay/form/ally/novice/auction into one pane. The pane
-- is a copy: main output still receives every line (never gagged). A capped
-- buffer holds every channel so switching the filter can replay history; that
-- buffer is persisted per character. The filter itself is per-session and
-- always starts on "all".
--
-- Ported from the workspace comms.lua. Changes:
--   - formation regex fixed: (.-) is not a lazy quantifier in RE2 (Rune's
--     engine is Go RE2, not Lua patterns), so the original could never match;
--     it needs (.+?).
--   - lines are timestamped, matching the old per-channel panes.
--   - character name comes from charname.lua instead of a private copy.

local style = rune.style
local H = require("helpstyle")
local charname = require("charname")

rune.pane.create("comms")

local CAP = 500
local SAVE_INTERVAL = 5

local FILTERS = {
    all = true, tell = true, clan = true, talk = true, relay = true,
    form = true, ally = true, novice = true, auction = true,
}
local TITLES = {
    all = "all", tell = "tells", clan = "clan", talk = "talk", relay = "relay",
    form = "form", ally = "ally", novice = "novice", auction = "auction",
}

local filter = "all"
local history = {}   -- ordered { category, line } for every routed line
local dirty = false
local adopted = false
local active_key = nil   -- store key the current history belongs to

-- The pane title reflects the filter. Panes have no runtime title setter, so
-- changing it re-declares the layout via rune_build_layout (defined in init).
rune.comms_title = "Comms (all)"

local function stamp(text)
    return style.dim("[" .. os.date("%m-%d %H:%M") .. "]") .. " " .. style.cyan(text)
end

-- Ordered history of every routed line: { category = "...", line = "..." }.
local function load_history(k)
    local out = {}
    local saved = rune.store.get(k)
    if type(saved) == "table" then
        for _, e in ipairs(saved) do
            if FILTERS[e.c] and type(e.l) == "string" then
                out[#out + 1] = { category = e.c, line = e.l }
            end
        end
        while #out > CAP do table.remove(out, 1) end
    end
    return out
end

local function save_history()
    if not dirty or not active_key then return end
    dirty = false
    local out = {}
    for i, e in ipairs(history) do
        out[i] = { c = e.category, l = e.line }
    end
    rune.store.set(active_key, out)
end

local function pane_matches(category)
    return filter == "all" or filter == category
end

-- Called for every routed line. Buffers it, shows it if it passes the filter,
-- and never gags: returning nil passes the line through to main output.
local function mirror(category, ctx)
    local entry = { category = category, line = stamp(ctx.line:raw()) }
    history[#history + 1] = entry
    dirty = true
    while #history > CAP do table.remove(history, 1) end
    if pane_matches(category) then
        rune.pane.write("comms", entry.line)
    end
    return nil
end

local function replay()
    local lines = {}
    for _, e in ipairs(history) do
        if pane_matches(e.category) then
            lines[#lines + 1] = e.line
        end
    end
    rune.pane.replace("comms", table.concat(lines, "\n"))
end

local function set_filter(f, silent)
    if not FILTERS[f] then return end
    if f == filter then
        if not silent then rune.echo("[comms] showing: " .. f) end
        return
    end
    filter = f
    if charname.get() then
        rune.store.set(charname.key("comms.filter"), f)
    end
    rune.comms_title = "Comms (" .. TITLES[f] .. ")"
    if rune_build_layout then rune_build_layout() end
    if not silent then
        replay()
        rune.echo("[comms] showing: " .. f)
    end
end

-- Persist once the name is known, merging anything routed before it arrived.
local function adopt()
    if adopted or not charname.get() then return end
    adopted = true
    active_key = charname.key("comms.history")

    local saved = rune.store.get(charname.key("comms.filter"))
    set_filter(FILTERS[saved] and saved or "all", true)

    local merged = load_history(active_key)
    for _, e in ipairs(history) do
        merged[#merged + 1] = e
    end
    while #merged > CAP do table.remove(merged, 1) end
    history = merged
    dirty = true
    replay()
end

-- Tells -----------------------------------------------------------------------

rune.trigger.regex("^(\\S+) tells you '(.+)'$", function(m, ctx)
    return mirror("tell", ctx)
end, { name = "comms-tell-in" })

rune.trigger.regex("^You tell (\\S+) '(.+)'$", function(m, ctx)
    return mirror("tell", ctx)
end, { name = "comms-tell-out" })

-- Formation -------------------------------------------------------------------

rune.trigger.regex("^(.+?) tells the formation '(.+)'$", function(m, ctx)
    return mirror("form", ctx)
end, { name = "comms-form-in" })

rune.trigger.regex("^You tell the formation '(.+)'$", function(m, ctx)
    return mirror("form", ctx)
end, { name = "comms-form-out" })

-- Alliance --------------------------------------------------------------------

rune.trigger.regex("^\\[ALLIED (\\d+)\\] (.+)$", function(m, ctx)
    return mirror("ally", ctx)
end, { name = "comms-ally-in" })

rune.trigger.regex("^\\[(\\d+)\\] alliance members heard you say, '(.+)'$", function(m, ctx)
    return mirror("ally", ctx)
end, { name = "comms-ally-out" })

-- Clan ------------------------------------------------------------------------

rune.trigger.regex("^\\[CLAN\\] (\\S+): '(.+)'$", function(m, ctx)
    return mirror("clan", ctx)
end, { name = "comms-clan-in" })

rune.trigger.regex("^\\[CLAN\\] (.+) has entered Materia Magica\\.$", function(m, ctx)
    return mirror("clan", ctx)
end, { name = "comms-clan-entered" })

rune.trigger.regex("^\\[CLAN\\] (.+) has left Materia Magica\\.$", function(m, ctx)
    return mirror("clan", ctx)
end, { name = "comms-clan-left" })

rune.trigger.regex("^\\[(\\d+)\\] clan members heard you say, '(.+)'$", function(m, ctx)
    return mirror("clan", ctx)
end, { name = "comms-clan-out" })

-- Novice clan (distinct format from standard [CLAN]) -------------------------

rune.trigger.regex("^\\[CLAN ([^\\]]+)\\] ([^:]+): '(.+)'$", function(m, ctx)
    return mirror("novice", ctx)
end, { name = "comms-novice-in" })

rune.trigger.regex("^\\[(\\d+)\\] (.+) clan members heard you say, '(.+)'$", function(m, ctx)
    return mirror("novice", ctx)
end, { name = "comms-novice-out" })

-- PK talk channels, with and without the online-count suffix ------------------

rune.trigger.regex("^\\[TALK [ABC]\\] (\\S+): '(.+)' \\[(\\d+)\\]$", function(m, ctx)
    return mirror("talk", ctx)
end, { name = "comms-talk-counted" })

rune.trigger.regex("^\\[TALK [ABC]\\] (\\S+): '(.+)'$", function(m, ctx)
    return mirror("talk", ctx)
end, { name = "comms-talk-bare" })

-- Relay ------------------------------------------------------------------------

rune.trigger.regex("^([^@\\s]+)@(#[^:\\s]+): (.+)$", function(m, ctx)
    return mirror("relay", ctx)
end, { name = "comms-relay-in" })

rune.trigger.regex("^\\[\\d+\\] .* heard you relay '(.+)'$", function(m, ctx)
    return mirror("relay", ctx)
end, { name = "comms-relay-out" })

-- Auction ---------------------------------------------------------------------

rune.trigger.contains("AUCTION:", function(_, ctx)
    return mirror("auction", ctx)
end, { name = "comms-auction" })

-- Scrolling -------------------------------------------------------------------
-- Rune's default pgup/pgdown target the reserved output pane only. shift+pgup
-- is grabbed by some terminals for their own scrollback, so ctrl+alt is used.

rune.bind("ctrl+alt+pgup", function() rune.pane.scroll_up("comms", 5) end,
    { group = "comms" })
rune.bind("ctrl+alt+pgdown", function() rune.pane.scroll_down("comms", 5) end,
    { group = "comms" })

-- Commands --------------------------------------------------------------------

rune.alias.regex(
    "^comms[ ]+(show|hide|toggle|clear|top|bottom|all|tell|clan|talk|relay|form|ally|novice|auction|name)$",
    function(m)
        local cmd = m[1]
        if cmd == "clear" then
            history = {}
            dirty = true
            save_history()
            rune.pane.clear("comms")
            rune.echo("[comms] cleared")
        elseif cmd == "top" then
            rune.pane.scroll_to_top("comms")
        elseif cmd == "bottom" then
            rune.pane.scroll_to_bottom("comms")
        elseif cmd == "name" then
            rune.echo("[comms] character: " .. (charname.get() or "(not yet received via GMCP)"))
        elseif FILTERS[cmd] then
            set_filter(cmd)
        else
            local on = rune.pane.toggle("comms")
            rune.echo("[comms] " .. (on and "shown" or "hidden"))
        end
    end, { name = "comms-cmd" })

rune.alias.regex("^comms([ ]+help)?$", function()
    rune.echo(H.title("comms pane (tells, clan, talk, relay, formation, alliance, novice, auction)"))
    rune.echo(H.line("comms show | hide | toggle", "show/hide the comms pane"))
    rune.echo(H.line("comms all | tell | clan | talk | relay | form | ally | novice | auction", "show only that channel (all are buffered)"))
    rune.echo(H.line("comms clear", "clear the buffer and the pane"))
    rune.echo(H.line("comms top | bottom", "jump to buffer extremes"))
    rune.echo(H.line("comms name", "show the GMCP character name"))
    rune.echo(H.line("ctrl+alt+pgup | ctrl+alt+pgdown", "scroll comms pane (5 lines)", 34))
    rune.echo("")
    rune.echo(H.foot("Matching lines are written to the pane AND pass through the main output (never gagged). History is capped at " .. CAP .. " lines and saved per character."))
end, { name = "comms-help" })

-- Persistence -----------------------------------------------------------------

-- The on_change callback is the only place we switch the active character.
-- The save uses the explicit `old` name so it lands under the right key even
-- though `charname` has already moved on. Then we drop the in-memory buffer,
-- point active_key at the new name, and load its history into the pane.
charname.on_change(function(old)
    if old and old ~= "" then
        local k = "comms.history." .. old:lower():gsub("[^%w_-]", "_")
        local out = {}
        for i, e in ipairs(history) do
            out[i] = { c = e.category, l = e.line }
        end
        rune.store.set(k, out)
    end
    history = {}
    dirty = false
    adopted = false
    active_key = charname.key("comms.history")
    history = load_history(active_key)
    dirty = true
    replay()
end)

rune.hooks.on("ready", adopt, { name = "comms-adopt" })
rune.timer.every(SAVE_INTERVAL, save_history, { name = "comms-save" })
rune.hooks.on("disconnected", save_history, { name = "comms-save-disconnect" })
rune.hooks.on("reloading", save_history, { name = "comms-save-reload" })