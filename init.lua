-- Rune config for Materia Magica.
--   rune   -- connects to Materia Magica; type your character name

-- Connect on startup. rune.session survives /reload, so this fires once per
-- client run, not on every reload. No world bookmark is needed, so a fresh
-- clone connects straight away.
if not rune.session.get("autoconnect") then
    rune.session.set("autoconnect", "1")
    rune.connect("materiamagica.com:4000")
end

-- Keep the last command in the input line, selected: Enter resends it,
-- typing replaces it. Off by default.
rune.config.set("keep_input", true)

-- Mouse wheel scrollback is left to the terminal so copy/paste behaves
-- normally. Scroll the game output with PgUp/PgDn or Ctrl+F instead.
-- To let Rune capture the wheel instead, set this to true (then use
-- Shift+drag to select text):
-- rune.config.set("mouse", true)

-- Pouch of plenitude auto-looter/sorter. See autopouch.lua.
require("autopouch")

-- Shared character name detection (required by statusbar, comms, mapper_map).
require("charname")

require("mapper")

-- ASCII map of the current area/floor, centred on you. See mapper_map.lua.
require("mapper_map")

-- Unified comms pane: tell/clan/talk/relay/form/alliance/novice/auction,
-- with a per-channel filter. See comms.lua.
require("comms")

require("statusbar")

-- Additional modules (self-contained; no UI pane of their own in this layout).
require("sense")      -- autowalk from 'you sense that X may be located...'
require("sign")       -- roadsign picker
require("spdr")       -- named speedwalk destinations
require("terrain")    -- terrain stamp in room headers
require("timers")     -- anti-idle twiddle
require("updater")    -- /update from the public repo
require("panes")      -- /panes hide/show all panes
require("quests")     -- quest pane and triggers
require("enemy")      -- wound lines -> inline health bars

-- Browser map server (webmap.lua + webmap/). Loaded only when present, so the
-- public copy runs fine without it.
local webmap_file = io.open((rune.config_dir or ".") .. "/webmap.lua", "r")
if webmap_file then
    webmap_file:close()
    require("webmap")
end

-- Layout: MM output 80 cols on the left; on the right a column holding comms
-- on top and a row below with the map pane (33 wide) and the quests pane
-- filling the remaining space.
--
-- The map is pinned to 33 wide by an inner column; a row's children get widths
-- instead of heights, so the column pins the pane. If you change 33 here, also
-- change WIDTH in mapper_map.lua to 31 (33 minus the two border cells).
--
-- Panes have no runtime title setter, so comms calls rune_build_layout again
-- when the filter changes, and mapper_map does the same when the map's area
-- or zoom changes. That function reads rune.comms_title and rune.map_title,
-- which those modules set. Anything else here should stay stable across
-- those re-declarations.
function rune_build_layout()
    rune.ui.layout({
        type = "column",
        children = {
            { type = "row", size = "1fr", children = {
                { type = "pane", name = "output", size = 80, border = "none" },
                { type = "column", size = "1fr", children = {
                    { type = "pane", name = "comms", size = 10, border = "full",
                      title = rune.comms_title or "Comms",
                      hidden = rune.pane.is_hidden("comms") or false },
                    { type = "row", size = "1fr", children = {
                        { type = "column", size = 33, children = {
                            { type = "pane", name = "map", size = "1fr", border = "full",
                              title = rune.map_title or "Map",
                              hidden = rune.map_hidden == true
                                  or rune.pane.is_hidden("map") or false },
                        }},
                        { type = "pane", name = "quests", size = "1fr", border = "full",
                          title = "Quests",
                          hidden = rune.pane.is_hidden("quests") or false },
                    }},
                }},
            }},
            { type = "input" },
            { type = "bar", name = "status" },
        },
    })
end

rune_build_layout()
