-- mapper_map.lua -- a map of where you are, in the "map" pane.
--
-- The layout is derived from the exit graph, NOT from the room coordinates in
-- mapper_store. The coordinates are not trustworthy: the server often sends a
-- coord with no z at all, and interiors collapse onto a single shared value
-- (124 of the 472 "Towne of Rune" rooms sit at exactly 705,763,0). The exit
-- graph is built from what the server actually reports, so walking outwards
-- from your current room produces a shape that is correct as you go.
--
-- Rooms sit two characters apart in each axis, so the cell between two
-- neighbours belongs to exactly one link. That is what lets a diagonal be a
-- real slash: with rooms one character apart the gap is a corner shared by
-- four rooms, and there is nowhere to put it. The cost is that the pane holds
-- about a quarter as many rooms as a dense floor plan would.
--
-- Consequences worth knowing:
--   * The current floor falls out for free: u/d/in/out exits have no grid
--     delta, so they are not drawn and the map stays on your level.
--   * Your room is always the centre, since the walk starts from it.
--   * Shapes drift a little where exits disagree with the true geometry; that
--     is inherent to reconstructing a map from a graph.
--
-- Commands: `mapper map`, `mapper map show|hide|refresh`.
-- Key: ctrl+alt+m.

local store = require("mapper_store")
local charname = require("charname")
local style = rune.style

-- Settings are stored per character, the way comms stores its filter: two
-- clients share one store.json and write it whole, so a single shared key
-- meant whichever client saved last won -- which is how the map style
-- disappeared more than once. Until GMCP has given us a name, fall back to the
-- plain key so nothing is lost before login completes.
local function setting_key(base)
    if charname.get() then return charname.key(base) end
    return base
end

-- How you are drawn on the map. rune.style only offers the eight basic colours
-- plus bold/dim/inverse -- there is no "bright" helper -- but terminals render
-- bold + colour as the high-intensity variant, so bold magenta reads as high
-- magenta. (Diagonals are also magenta, so if this blurs into them, swap the
-- colour here: it is the only place the marker is defined.)
local function player_mark()
    return style.bold(style.magenta("@"))
end

-- A plain room.
local ROOM = "o"

local PANE = "map"
-- Must match the map pane's inner size, which init.lua pins with a fixed-width
-- column (33 wide -> 31 inner) and an auto height. There is no API to ask a
-- pane its dimensions, so these have to agree by hand: change the column in
-- init.lua and these together.
local WIDTH = 31          -- grid columns; pane width minus its two borders
local HEIGHT = 19         -- grid rows; what is left after borders, legend, footer
-- Rooms are two characters apart, so the pane holds half as many per axis.
-- These are both the room-space window and the character half-extents.
local HALF_W = math.floor(WIDTH / 2)
local HALF_H = math.floor(HEIGHT / 2)

local REDRAW_EVERY = 1    -- seconds; walking moves at most a room or two a second
local DEPTH = 12          -- rooms of BFS reach; pane is HALF_W x HALF_H so this is the cap

local dirty = true
local last_depth = DEPTH

local function mp(msg)
    return style.magenta("[map]") .. " " .. style.white(msg)
end

rune.pane.create(PANE)

-- Whether the pane starts hidden. Read by init.lua when it declares the
-- layout, and remembered across /reload (a runtime hide does not survive
-- one, because the new generation rebuilds the tree from scratch). Re-read
-- when the character name arrives, since the key is per character.
local function refresh_hidden()
    rune.map_hidden = rune.store.get(setting_key("mapper.map_hidden")) == true
end
refresh_hidden()

-- Layout --------------------------------------------------------------------

-- One step per room, in compass directions. Only the eight horizontal
-- directions get a delta: u/d/in/out lead off this floor.

local DELTA = {
    n = { 0,  1}, ne = { 1,  1}, e = {  1,  0}, se = { 1, -1},
    s = { 0, -1}, sw = { -1, -1}, w = { -1,  0}, nw = { -1,  1},
}

-- Exits are walked and drawn in this order, never with pairs(): Lua leaves the
-- order of string keys undefined, so pairs() would place rooms differently on
-- each run and the map would change shape when you reloaded.
local DIR_ORDER = { "n", "ne", "e", "se", "s", "sw", "w", "nw" }

-- Walk out from `root`, assigning each reachable room a grid position.
-- Returns layout[uid] = { x, y } plus the bounding box.
--
-- One floor at a time. The server reports some staircases as a horizontal exit
-- whose destination is a floor or two away, and drawing that would put two
-- levels on the same plane. A jump of five or more floors in a single step does
-- not happen in a real building, so those are left alone -- they are stale
-- coordinates, not stairs. A room with no usable z is never dropped either.
--
-- One cell holds one room. Two routes can want the same cell; when they do the
-- first to arrive keeps it (the walk is breadth-first, so rooms nearer to you
-- win) and the other is simply not placed. Without this the later room was
-- written over the earlier one, which is how a diagonal from a room you are not
-- standing next to ended up drawn as though it came off your neighbour.
local MAX_FLOOR_JUMP = 4

local function build_layout(root, area, depth)
    local root_room = store.get(tostring(root))
    local root_z = root_room and root_room.coord and tonumber(root_room.coord.z)

    local function on_this_floor(room)
        if not root_z or not room or not room.coord then return true end
        local z = tonumber(room.coord.z)
        if not z then return true end
        local jump = math.abs(z - root_z)
        return jump == 0 or jump > MAX_FLOOR_JUMP
    end

    local layout = { [tostring(root)] = { x = 0, y = 0 } }
    local occupied = { ["0,0"] = true }
    local minx, maxx, miny, maxy = 0, 0, 0, 0
    local frontier = { { uid = tostring(root), x = 0, y = 0 } }

    for _ = 1, depth do
        local next_frontier = {}
        for _, node in ipairs(frontier) do
            local room = store.get(node.uid)
            for _, dir in ipairs(DIR_ORDER) do
                local dest = room and room.exits and room.exits[dir]
                local delta = DELTA[dir]
                if dest and delta then
                    dest = tostring(dest)
                    if not layout[dest] then
                        local dest_room = store.get(dest)
                        local x, y = node.x + delta[1], node.y + delta[2]
                        local cell = x .. "," .. y
                        if dest_room and (not area or dest_room.area == area)
                            and on_this_floor(dest_room)
                            and not occupied[cell] then
                            layout[dest] = { x = x, y = y }
                            occupied[cell] = true
                            if x < minx then minx = x end
                            if x > maxx then maxx = x end
                            if y < miny then miny = y end
                            if y > maxy then maxy = y end
                            next_frontier[#next_frontier + 1] = { uid = dest, x = x, y = y }
                        end
                    end
                end
            end
        end
        frontier = next_frontier
        if #frontier == 0 then break end
    end

    return layout, minx, maxx, miny, maxy
end

-- Room classification -------------------------------------------------------

local function tokens(s)
    local set = {}
    if type(s) == "table" then
        for _, v in ipairs(s) do set[tostring(v):lower()] = true end
        return set
    end
    for tok in tostring(s or ""):lower():gmatch("[^,%s]+") do
        set[tok] = true
    end
    return set
end

local PK = {
    ["npk"] = true, ["cpk"] = true, ["lpk"] = true,
    ["player-kill-neutral"] = true, ["player-kill-chaotic"] = true,
}

-- A room you would want to find on the map, not just walk through.
-- Returns rank, glyph, style function; rank 0 means "not worth a letter".
-- Where a room is several of these, the rank decides which letter wins. A
-- training room inside a shop shows as T (the rarer, more specific thing);
-- a player-kill room keeps # since that is a safety marker.
local function classify(room, flags, tags)
    local pk = tags["dt"]
    for t in pairs(PK) do
        if flags[t] then pk = true break end
    end
    if pk then return 5, "#", style.red end
    if flags["trainer"] or tags["trainer"] then return 3, "T", style.yellow end
    if flags["shop"] or tags["shop"] then return 2, "$", style.cyan end
    if flags["safe"] or tags["safe"] then return 1, "S", style.white end
    return 0
end

-- Rendering -----------------------------------------------------------------

-- Offset from a room's node to the cell holding the link to a neighbour.
-- A whole room step is two characters, so half a step is these offsets.
local GRAPH_EDGE = {
    n = {0, 1, "│"},  s = {0, -1, "│"},
    e = {1, 0, "─"},  w = {-1, 0, "─"},
    ne = {1, 1, "╱"}, sw = {-1, -1, "╱"},
    nw = {-1, 1, "╲"}, se = {1, -1, "╲"},
}

local function render_graph(layout, root)
    local grid = {}
    -- `keep` leaves an already-drawn cell alone: two different diagonal links
    -- can want the same corner cell, and the first one drawn should win.
    local function put(cx, cy, ch, keep)
        if cx < -HALF_W or cx > HALF_W or cy < -HALF_H or cy > HALF_H then return end
        local row = grid[cy]
        if not row then row = {}; grid[cy] = row end
        if keep and row[cx] then return end
        row[cx] = ch
    end

    -- Draw in a fixed order, top row first then left to right. pairs() over the
    -- layout has no defined order, so without this the map could redraw
    -- differently whenever it was rebuilt.
    local order = {}
    for uid, at in pairs(layout) do order[#order + 1] = { uid = uid, at = at } end
    table.sort(order, function(a, b)
        if a.at.y ~= b.at.y then return a.at.y > b.at.y end
        return a.at.x < b.at.x
    end)

    for _, entry in ipairs(order) do
        local uid, at = entry.uid, entry.at
        local room = store.get(uid)
        if room then
            local nx, ny = at.x * 2, at.y * 2
            if uid == root then
                put(nx, ny, player_mark())
            else
                local rank, glyph, col = classify(room, tokens(room.flags), tokens(room.tags))
                put(nx, ny, rank > 0 and col(glyph) or style.dim(ROOM))
            end
            for _, dir in ipairs(DIR_ORDER) do
                local dest = room.exits and room.exits[dir]
                local e = GRAPH_EDGE[dir]
                if dest and e then
                    dest = tostring(dest)
                    local delta = DELTA[dir]
                    local t = layout[dest]
                    -- Only when the target really sits in the cell this
                    -- direction points at. Otherwise the glyph would be drawn
                    -- against whatever room happens to be there instead.
                    if t and delta and t.x == at.x + delta[1] and t.y == at.y + delta[2] then
                        put(nx + e[1], ny + e[2], style.gray(e[3]), true)
                    end
                end
            end
        end
    end

    local lines = {}
    for cy = HALF_H, -HALF_H, -1 do
        local row = grid[cy]
        local buf = {}
        for cx = -HALF_W, HALF_W do
            buf[#buf + 1] = (row and row[cx]) or " "
        end
        lines[#lines + 1] = table.concat(buf)
    end
    return lines
end

-- Every line has to fit the pane or it wraps and pushes the grid around.
-- Colours do not count as width.
local function note(msg)
    if #msg > WIDTH then msg = msg:sub(1, WIDTH) end
    rune.pane.replace(PANE, style.gray(msg))
end

local function legend()
    return {
        style.dim(ROOM) .. style.gray(" room   ") .. player_mark() .. style.gray(" you"),
        style.white("S") .. style.gray(" safe  ") .. style.red("#") .. style.gray(" pk  ") ..
            style.cyan("$") .. style.gray(" shop"),
        style.yellow("T") .. style.gray(" trainer"),
    }
end

-- Grid, then legend and footer, then one UI update.
local function emit(lines, room, uid)
    lines[#lines + 1] = ""
    for _, l in ipairs(legend()) do lines[#lines + 1] = l end
    local head = "#" .. uid .. "  "
    local name = tostring(room.name or "?")
    if #head + #name > WIDTH then name = name:sub(1, WIDTH - #head) end
    lines[#lines + 1] = style.gray(head .. name)
    rune.pane.replace(PANE, table.concat(lines, "\n"))
end

-- Reach out far enough to fill the pane, but no further: deeper is only useful
-- while the mapped area still fits. The ceiling is generous because the size
-- check stops us long before it bites -- rooms that collide onto an
-- already-placed cell are not revisited.
local MAX_DEPTH = 24

local function resolve_layout(root, area)
    local best
    local first_view

    for depth = DEPTH, MAX_DEPTH do
        local layout, minx, maxx, miny, maxy = build_layout(root, area, depth)
        local view = {
            layout = layout,
            minx = minx, maxx = maxx, miny = miny, maxy = maxy,
        }
        last_depth = depth
        if not first_view then first_view = view end
        if maxx - minx + 1 <= HALF_W and maxy - miny + 1 <= HALF_H then
            best = view
            break
        end
    end

    -- Nothing fit? Draw the shallowest reach anyway: the window is centred on
    -- you and clips, so a too-large layout is still useful, whereas returning
    -- nothing leaves the pane saying "no mapped neighbours".
    return best or first_view
end

local function render()
    local pos = store.position
    if not pos then note("no position yet") return end
    local uid = tostring(pos.uid)
    local room = store.get(uid)
    if not room then note("unknown room #" .. uid) return end

    local view = resolve_layout(uid, room.area)
    if not view then note("no mapped neighbours") return end
    emit(render_graph(view.layout, uid), room, uid)
end

-- Refresh loop --------------------------------------------------------------

local function redraw()
    if rune.pane.is_hidden(PANE) then return end
    render()
end

-- Title is the area name; panes have no runtime title setter, so changing it
-- re-declares the layout the same way comms does for its filter. Kept
-- idempotent so the redraw tick can call it unconditionally.
local function set_title()
    local pos = store.position
    local room = pos and store.get(pos.uid)
    local want = (room and room.area) or "Map"
    if rune.map_title == want then return end
    rune.map_title = want
    if rune_build_layout then rune_build_layout() end
end

-- Draw the moment the room changes. Marking a flag and waiting for the tick
-- meant the pane could be a full second behind a move -- during a speedwalk it
-- mostly showed the room just left. The draw is well under a millisecond, so
-- there is nothing to gain by deferring it; the tick stays as a backstop for
-- state this handler does not cover (the character name arriving, and so on).
rune.gmcp.on("Room.Info", function()
    dirty = true
    redraw()
    set_title()
end, { name = "mapper-map-room" })

-- The name arrives a moment after login, and the settings are keyed on it, so
-- pick them up then and re-declare the layout (the pane's hidden state comes
-- from the layout). Also covers a character switch.
charname.on_change(function()
    refresh_hidden()
    if rune_build_layout then rune_build_layout() end
    dirty = true
    redraw()
end)

rune.timer.every(REDRAW_EVERY, function()
    if not dirty then return end
    dirty = false
    redraw()
    set_title()
end, { name = "mapper-map-tick" })

-- Commands ------------------------------------------------------------------

local function report()
    rune.echo(mp("reach " .. last_depth .. ", up to " .. HALF_W .. "x" .. HALF_H .. " rooms"))
end

rune.alias.regex("^mapper[ ]+map[ ]+show$", function()
    rune.map_hidden = false
    rune.store.set(setting_key("mapper.map_hidden"), false)
    rune.pane.show(PANE)
    dirty = true
    redraw()
    report()
end, { name = "mapper-map-show" })

rune.alias.regex("^mapper[ ]+map[ ]+hide$", function()
    rune.map_hidden = true
    rune.store.set(setting_key("mapper.map_hidden"), true)
    rune.pane.hide(PANE)
    rune.echo(mp("hidden; ctrl+alt+m to toggle, `mapper map show` to bring it back"))
end, { name = "mapper-map-hide" })

rune.alias.regex("^mapper[ ]+map[ ]+refresh$", function()
    dirty = true
    redraw()
    rune.echo(mp("redrawn"))
end, { name = "mapper-map-refresh" })

rune.alias.regex("^mapper[ ]+map$", function()
    dirty = true
    render()
    set_title()
    report()
end, { name = "mapper-map" })

-- The key is the binding's name; rune.bind ignores a name in opts.
rune.bind("ctrl+alt+m", function()
    local shown = rune.pane.toggle(PANE)
    -- Remember it, so the pane comes back the way you left it after a reload.
    rune.map_hidden = not shown
    rune.store.set(setting_key("mapper.map_hidden"), rune.map_hidden)
    dirty = true
    if shown then render() end
end)

set_title()
