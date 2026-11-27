-- RE4 Access: buildings (10/14, user: "a places category with houses and
-- warehouses that people could walk in and explore by themselves").
--
-- The game has no house names, so the mod finds buildings itself with physics
-- rays: a floor below and a roof above = indoors. Starting next to doors,
-- indoor items and Leon, it floods outward over 1 m cells (walls stop it, closed
-- doors don't) and collects one building per connected roofed area, stairs
-- included. Where a roofed cell meets open sky with no wall between, that is a
-- way in: a door, or an open doorway.
--
--   Semicolon -> "Buildings": each one with size, floors, ways in, what is
--     inside and how much of it you have walked through. Shift+Backslash walks
--     you to its nearest way in.
--   Semicolon -> "Inside this building": the items, things, doors and ways out
--     inside the building you are in (or the one you last picked).
--   Walking in and out says "Entered building B, 3 items inside" / "Left
--     building B, 1 item not picked up".
-- The mapping runs a few milliseconds per frame in the background.

local P = RE4Access.places or {}
-- always the current game module (it can be hot-reloaded)
local G = setmetatable({}, { __index = function(_, k) return RE4Access.game[k] end })

local CELL = 1.0
local BAND = 2.5            -- floor height bands (m) for telling floors apart
local MAX_STEP = 0.7        -- floor height change allowed between cells (stairs)
local ROOF_MIN = 1.7        -- ceiling at least this high above the floor
local ROOF_MAX = 12
local CHEST = 1.3
local MAX_CELLS = 4000      -- bigger roofed areas are not mapped further
local MIN_CELLS = 6         -- smaller ones (an alcove, an overhang) are not buildings
local SCAN_RANGE = 70
local BUDGET = 0.003        -- seconds of mapping per frame

local function say(text, interrupt)
    if interrupt == nil then interrupt = false end
    RE4Access.speak(text, interrupt)
end

local function R() return RE4Access.route end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
local function band(y) return math.floor(y / BAND + 0.5) end
local function idx(v) return math.floor(v / CELL + 0.5) end

-- Fresh state (kept across hot reloads).
function P.reset()
    P.cells = {}        -- "ix,iz,band" -> cell { ix, iz, x, z, y, roof, owner, visited }
    P.cols = {}         -- "ix,iz" -> list of cells (all floors)
    P.probe_cache = {}  -- "ix,iz,refband" -> cell
    P.edges = {}        -- "keyA|keyB" -> true when open
    P.buildings = {}    -- id -> building
    P.next_id = 1
    P.seeds = {}
    P.seeded = {}       -- seed key -> true
    P.job = nil
    P.origin = nil
    P.inside = nil      -- building id Leon is in
    P.focus = nil       -- building id picked last
    P.rays_dead = false
end
if not P.cells then P.reset() end

-- ---------------- cells ----------------

-- The floor at a 1 m cell near height ref_y, and whether it has a roof.
local function probe(ix, iz, ref_y)
    local pk = ix .. "," .. iz .. "," .. band(ref_y)
    local c = P.probe_cache[pk]
    if c then return c end
    local x, z = ix * CELL, iz * CELL
    local hit = R().cast(x, ref_y + 1.2, z, x, ref_y - 1.5, z)
    if not hit then return nil end     -- no floor, or not loaded yet: ask again later
    local y = hit.y
    local key = ix .. "," .. iz .. "," .. band(y)
    c = P.cells[key]
    if not c then
        local roof = R().cast(x, y + 0.5, z, x, y + ROOF_MAX, z)
        c = { ix = ix, iz = iz, x = x, z = z, y = y, key = key, roof = roof ~= nil and (roof.y - y) >= ROOF_MIN }
        P.cells[key] = c
        local ck = ix .. "," .. iz
        P.cols[ck] = P.cols[ck] or {}
        table.insert(P.cols[ck], c)
    end
    P.probe_cache[pk] = c
    return c
end

-- Doors near the mapped area (closed doors are solid, but they are ways through).
local doors = { at = -10, list = {} }
local function refresh_doors(pos)
    local now = os.clock()
    if now - doors.at < 3 then return end
    doors.at = now
    doors.list = {}
    for _, t in ipairs(G.scan_things(pos, SCAN_RANGE + 30)) do
        if t.name == "Door" or t.name == "Gate" then
            local ok, c = pcall(G.door_center_of, t)
            doors.list[#doors.list + 1] = { t = t, c = (ok and c) or t.pos }
        end
    end
end
local function door_at(x, y, z, r)
    for _, d in ipairs(doors.list) do
        if math.abs(d.c.y - y) < 2.5 and math.sqrt((d.c.x - x) ^ 2 + (d.c.z - z) ^ 2) < r then return d end
    end
end

-- Can Leon walk from cell a to its neighbour b? Rays both ways at chest height
-- (a ray starting inside a thick wall would miss it), or a door in between.
local function open_between(a, b)
    local k = a.key < b.key and (a.key .. "|" .. b.key) or (b.key .. "|" .. a.key)
    local v = P.edges[k]
    if v ~= nil then return v end
    local cast = R().cast
    v = not cast(a.x, a.y + CHEST, a.z, b.x, b.y + CHEST, b.z) and not cast(b.x, b.y + CHEST, b.z, a.x, a.y + CHEST, a.z)
    if not v and door_at((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, 1.0) then v = true end
    P.edges[k] = v
    return v
end

-- ---------------- buildings ----------------

local function building(id)
    local b = P.buildings[id]
    while b and b.merged do b = P.buildings[b.merged] end
    return b
end
P.building = building

local function claim(b, c)
    c.owner = b.id
    b.n = b.n + 1
    b.cells[#b.cells + 1] = c
    b.bands[band(c.y)] = true
end

local function merge(into, other)
    for _, c in ipairs(other.cells) do c.owner = into.id; into.cells[#into.cells + 1] = c; into.bands[band(c.y)] = true end
    into.n = into.n + other.n
    for _, e in ipairs(other.edges) do into.edges[#into.edges + 1] = e end
    if other.big then into.big = true end
    other.merged = into.id
    other.cells, other.edges = {}, {}
end

local function expand(job, c)
    local b = building(job.b)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local nb = probe(c.ix + d[1], c.iz + d[2], c.y)
        if nb and math.abs(nb.y - c.y) <= MAX_STEP and open_between(c, nb) then
            if nb.roof then
                if not nb.owner then
                    claim(b, nb)
                    job.queue[#job.queue + 1] = nb
                elseif building(nb.owner) ~= b then
                    local o = building(nb.owner)
                    if o then merge(b, o) end
                end
            else
                -- roofed meets open sky: a way in
                local mx, my, mz = (c.x + nb.x) / 2, (c.y + nb.y) / 2, (c.z + nb.z) / 2
                local door = door_at(mx, my, mz, 1.5)
                b.edges[#b.edges + 1] = { inn = { x = c.x, y = c.y, z = c.z }, out = { x = nb.x, y = nb.y, z = nb.z }, door = door }
            end
        end
    end
    if b.n >= MAX_CELLS then b.big = true return false end
    return true
end

-- Group way-in edges into entrances (one per doorway or open side).
local function make_entrances(b)
    local groups = {}
    for _, e in ipairs(b.edges) do
        local g
        for _, q in ipairs(groups) do
            if d2(q.last, e.out) < 2.6 and math.abs(q.last.y - e.out.y) < 1.5 then g = q break end
        end
        if not g then g = { edges = {}, sx = 0, sy = 0, sz = 0, ix = 0, iy = 0, iz = 0 }; groups[#groups + 1] = g end
        g.edges[#g.edges + 1] = e
        g.last = e.out
        g.sx, g.sy, g.sz = g.sx + e.out.x, g.sy + e.out.y, g.sz + e.out.z
        g.ix, g.iy, g.iz = g.ix + e.inn.x, g.iy + e.inn.y, g.iz + e.inn.z
        if e.door then g.door = e.door end
    end
    local out = {}
    for _, g in ipairs(groups) do
        local n = #g.edges
        local en = { out = { x = g.sx / n, y = g.sy / n, z = g.sz / n }, inn = { x = g.ix / n, y = g.iy / n, z = g.iz / n }, width = n, door = g.door }
        if not en.door then
            -- the door may stand one cell further in (a porch in front of it)
            local dd = door_at(en.inn.x, en.inn.y, en.inn.z, 2.5)
            if dd then en.door = dd end
        end
        out[#out + 1] = en
    end
    b.entrances = out
end

local function finish_job()
    local job = P.job
    P.job = nil
    local b = job and building(job.b)
    if not b then return end
    make_entrances(b)
    b.done = true
    log.info(string.format("[RE4Access] building %d mapped: %d cells, %d floors, %d ways in%s, rays %d",
        b.id, b.n, P.floors(b), #b.entrances, b.big and " (too big, stopped)" or "", R().stats.rays))
end

local function start_seed(s)
    if P.seeded[s.key] then return end
    local c = probe(idx(s.x), idx(s.z), s.y)
    if not c then return end           -- not loaded yet: the seed comes back later
    P.seeded[s.key] = true
    if not c.roof or c.owner then return end
    local b = { id = P.next_id, n = 0, cells = {}, edges = {}, bands = {}, entrances = {} }
    P.next_id = P.next_id + 1
    P.buildings[b.id] = b
    claim(b, c)
    P.job = { b = b.id, queue = { c }, qi = 1 }
end

-- Background mapping, a few ms per frame.
function P.work()
    if P.rays_dead or not R() then return end
    local stop = os.clock() + BUDGET
    while os.clock() < stop do
        local job = P.job
        if job then
            local b = building(job.b)
            if not b then P.job = nil
            elseif b.big then finish_job()
            else
                local c = job.queue[job.qi]
                if not c then finish_job()
                else
                    job.qi = job.qi + 1
                    if not expand(job, c) then finish_job() end
                end
            end
        else
            local s = table.remove(P.seeds)
            if not s then return end
            start_seed(s)
        end
    end
end

-- Seeds: both sides of every door, indoor items and things, and Leon himself.
local function add_seeds(pos)
    refresh_doors(pos)
    local list = {}
    for _, d in ipairs(doors.list) do
        if d2(d.c, pos) < SCAN_RANGE then
            for a = 0, 7 do
                local ang = a * math.pi / 4
                list[#list + 1] = { key = "d" .. d.t.key .. "_" .. a, x = d.c.x + math.sin(ang) * 1.4, y = d.c.y, z = d.c.z + math.cos(ang) * 1.4 }
            end
        end
    end
    for _, it in ipairs(G.items(pos, SCAN_RANGE)) do
        list[#list + 1] = { key = "i" .. it.key, x = it.pos.x, y = it.pos.y, z = it.pos.z }
    end
    for _, t in ipairs(G.scan_things(pos, 40)) do
        if t.name ~= "Breakable crate" and t.name ~= "Door" and t.name ~= "Gate" then
            list[#list + 1] = { key = "t" .. t.key, x = t.pos.x, y = t.pos.y, z = t.pos.z }
        end
    end
    -- Leon last in the list = first taken
    list[#list + 1] = { key = "L" .. idx(pos.x) .. "," .. idx(pos.z) .. "," .. band(pos.y), x = pos.x, y = pos.y, z = pos.z }
    -- farthest first in the list (taken last)
    local mine = table.remove(list)
    table.sort(list, function(a, b) return d2(a, pos) > d2(b, pos) end)
    list[#list + 1] = mine
    P.seeds = {}
    for _, s in ipairs(list) do if not P.seeded[s.key] then P.seeds[#P.seeds + 1] = s end end
end

-- ---------------- where is a point ----------------

-- The building a point (Leon's feet, an item on a table) belongs to.
function P.owner_at(p)
    local best, bd
    local ix, iz = idx(p.x), idx(p.z)
    for dx = -1, 1 do
        for dz = -1, 1 do
            for _, c in ipairs(P.cols[(ix + dx) .. "," .. (iz + dz)] or {}) do
                local dy = p.y - c.y
                if c.owner and dy > -0.8 and dy < 2.4 then
                    local dd = (c.x - p.x) ^ 2 + (c.z - p.z) ^ 2 + (dx == 0 and dz == 0 and 0 or 0.3)
                    if not bd or dd < bd then best, bd = c, dd end
                end
            end
        end
    end
    return best and building(best.owner), best
end

function P.floors(b)
    local n = 0
    for _ in pairs(b.bands) do n = n + 1 end
    return n
end

local function listed(b)
    return b and b.done and not b.merged and b.n >= MIN_CELLS
end

-- ---------------- letters ----------------

local function label(b)
    if not b.letter then
        P.letters = (P.letters or 0) + 1
        local n = P.letters
        b.letter = n <= 26 and string.char(64 + n) or tostring(n)
    end
    return "Building " .. b.letter
end

-- ---------------- contents ----------------

local JUNK = { ["Breakable crate"] = true, Padlock = true, ["Map Icon Only"] = true, ["Door Lock"] = true,
    ["Correlated Shutter"] = true, Mouse = true }

-- What is inside building b: items, things, doors, enemies.
function P.contents(b, pos)
    local out = { items = {}, things = {}, doors = {}, enemies = {} }
    local R_ = SCAN_RANGE + 40
    for _, it in ipairs(G.items(pos, R_)) do
        if P.owner_at(it.pos) == b then out.items[#out.items + 1] = it end
    end
    for _, t in ipairs(G.scan_things(pos, R_)) do
        if not JUNK[t.name] and not (t.name:sub(1, 10) == "Path point" and G.visited[t.key]) then
            if t.name == "Door" or t.name == "Gate" then
                local ok, c = pcall(G.door_center_of, t)
                c = (ok and c) or t.pos
                local o1 = P.owner_at({ x = c.x, y = c.y, z = c.z })
                if o1 == b then out.doors[#out.doors + 1] = t
                else
                    for _, e in ipairs(b.entrances) do
                        if e.door and e.door.t.key == t.key then out.doors[#out.doors + 1] = t break end
                    end
                end
            elseif P.owner_at(t.pos) == b then
                out.things[#out.things + 1] = t
            end
        end
    end
    for _, e in ipairs(G.enemies(pos, R_)) do
        if P.owner_at(e.pos) == b then out.enemies[#out.enemies + 1] = e end
    end
    return out
end

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

local function contents_text(ct)
    local parts = {}
    if #ct.items > 0 then parts[#parts + 1] = plural(#ct.items, "item", "items") end
    if #ct.things > 0 then parts[#parts + 1] = plural(#ct.things, "other thing", "other things") end
    if #ct.enemies > 0 then parts[#parts + 1] = plural(#ct.enemies, "enemy", "enemies") end
    if #parts == 0 then return "nothing found inside" end
    return table.concat(parts, ", ") .. " inside"
end

local function explored(b)
    local v = 0
    for _, c in ipairs(b.cells) do if c.visited then v = v + 1 end end
    return b.n > 0 and math.floor(v * 100 / b.n + 0.5) or 0
end

local function size_word(b)
    local per_floor = b.n / math.max(1, P.floors(b))
    if b.big then return "very large" end
    if per_floor < 40 then return "small" elseif per_floor < 150 then return "medium" end
    return "large"
end

local function entrance_locked(e)
    if not (e.door and e.door.t.go) then return false end
    local ok, v = pcall(G.door_locked, e.door.t.go)
    return ok and v == true
end

-- Nearest way in from pos (unlocked ones first).
local function best_entrance(b, pos)
    local best, bs
    for _, e in ipairs(b.entrances) do
        local s = d2(e.out, pos) + math.abs(e.out.y - pos.y) * 5 + (entrance_locked(e) and 1000 or 0)
        if not bs or s < bs then best, bs = e, s end
    end
    return best
end

-- Spoken summary after the name and position.
function P.describe(t, pos)
    local b = building(t.building)
    if not b then return "" end
    local parts = { size_word(b) }
    local fl = P.floors(b)
    if fl > 1 then parts[#parts + 1] = fl .. " floors" end
    if P.inside == b.id then parts[#parts + 1] = "you are inside" end
    local ne = #b.entrances
    local open_sides = false
    for _, e in ipairs(b.entrances) do if e.width >= 5 and not e.door then open_sides = true end end
    if open_sides then parts[#parts + 1] = "open on one side or more" end
    if ne == 0 then parts[#parts + 1] = "no way in found yet"
    else
        local locked = 0
        for _, e in ipairs(b.entrances) do if entrance_locked(e) then locked = locked + 1 end end
        local s = plural(ne, "way in", "ways in")
        if locked == ne then s = s .. ", locked" elseif locked > 0 then s = s .. ", " .. locked .. " locked" end
        parts[#parts + 1] = s
    end
    local okc, ct = pcall(P.contents, b, pos)
    if okc then parts[#parts + 1] = contents_text(ct) end
    local ex = explored(b)
    if ex == 0 then parts[#parts + 1] = "not visited"
    elseif ex >= 70 then parts[#parts + 1] = "explored"
    else parts[#parts + 1] = ex .. " percent explored" end
    return table.concat(parts, ", ")
end

-- ---------------- lists ----------------

function P.list(pos)
    local out = {}
    for _, b in pairs(P.buildings) do
        if listed(b) then
            local e = best_entrance(b, pos)
            local p
            if P.inside == b.id then p = { x = pos.x, y = pos.y, z = pos.z }
            elseif e then p = e.out
            else p = b.cells[1] and { x = b.cells[1].x, y = b.cells[1].y, z = b.cells[1].z } end
            if p then
                out[#out + 1] = { name = label(b), pos = p, dist = d2(p, pos), key = "bld" .. b.id, building = b.id }
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- Contents of the building Leon is in, or the one picked last.
function P.inside_list(pos)
    local b = building(P.inside) or building(P.focus)
    P.list_building = b
    if not b then return {} end
    local ct = P.contents(b, pos)
    local out = {}
    for _, t in ipairs(ct.items) do out[#out + 1] = t end
    for _, t in ipairs(ct.things) do out[#out + 1] = t end
    for _, t in ipairs(ct.enemies) do out[#out + 1] = t end
    for _, t in ipairs(ct.doors) do
        local way_out = false
        for _, e in ipairs(b.entrances) do if e.door and e.door.t.key == t.key then way_out = true break end end
        out[#out + 1] = { name = t.name, pos = t.pos, dist = t.dist, key = t.key, go = t.go, note = way_out and "a way in and out" or "inside the building" }
    end
    for i, e in ipairs(b.entrances) do
        if not e.door then
            out[#out + 1] = { name = e.width >= 5 and "Open side" or "Open doorway", pos = e.out, dist = d2(e.out, pos), key = "way" .. b.id .. "_" .. i, note = "a way in and out" }
        end
    end
    table.sort(out, function(a, c) return a.dist < c.dist end)
    return out
end

-- Said after the category name when switching to Buildings.
function P.note(inside_cat)
    if P.rays_dead then return "Can't map buildings right now: the game's collision is not answering. Try again in a moment." end
    if inside_cat then
        local b = P.list_building
        if not b then return "You are not in a building. Pick one in Buildings first." end
        return (P.inside == b.id and "In " or "Showing ") .. label(b)
    end
    if P.job or #P.seeds > 0 then return "Still mapping, more may appear." end
    return nil
end

-- ---------------- walking there ----------------

function P.go(t)
    local b = building(t.building)
    local pos = G.player_pos()
    if not b or not pos then say("Building not known any more", true) return end
    if P.inside == b.id then say("You are inside " .. label(b) .. ". Semicolon to Inside this building lists what is here.", true) return end
    local e = best_entrance(b, pos)
    if not e then say("I found no way into " .. label(b) .. " yet.", true) return end
    P.focus = b.id
    if e.door and e.door.t.go then
        say("Walking you to the door of " .. label(b) .. ". Hold W.", true)
        RE4Access.speak_hold = true
        R().go(e.door.t)
        RE4Access.speak_hold = nil
        P.arrive = { b = b.id, door = true, out = e.out, inn = e.inn }
    else
        RE4Access.speak_hold = true
        R().go({ name = "the way into " .. label(b), pos = e.out })
        RE4Access.speak_hold = nil
        P.arrive = { b = b.id, door = false, out = e.out, inn = e.inn }
    end
end

-- ---------------- per tick (10 times a second) ----------------

local tick = { at = 0, seeds_at = -10, cand = nil, cand_n = 0 }
function P.update(pos, now)
    if now - tick.at < 0.5 then return end
    tick.at = now
    -- far from where mapping started: start over (old areas get unloaded)
    if not P.origin or d2(P.origin, pos) > 200 then
        local had = P.origin ~= nil
        P.reset()
        P.origin = { x = pos.x, y = pos.y, z = pos.z }
        if had then log.info("[RE4Access] buildings reset (new area)") end
    end
    -- collision answering? (it doesn't while paused, and sometimes after a save)
    local hit = R().cast(pos.x, pos.y + 1.0, pos.z, pos.x, pos.y - 2.0, pos.z)
    P.rays_dead = hit == nil
    if P.rays_dead then return end
    if now - tick.seeds_at > 4 and not P.job then
        tick.seeds_at = now
        local ok, err = pcall(add_seeds, pos)
        if not ok then log.info("[RE4Access] building seeds error: " .. tostring(err)) end
    end
    -- walked-through cells
    local ix, iz = idx(pos.x), idx(pos.z)
    for dx = -2, 2 do
        for dz = -2, 2 do
            for _, c in ipairs(P.cols[(ix + dx) .. "," .. (iz + dz)] or {}) do
                if c.owner and math.abs(c.y - pos.y) < 1.5 then c.visited = true end
            end
        end
    end
    -- entering / leaving (the same answer twice in a row, so doorways don't flicker)
    local b = P.owner_at(pos)
    if b and not listed(b) then b = nil end
    local id = b and b.id or false
    if id == tick.cand then tick.cand_n = tick.cand_n + 1 else tick.cand, tick.cand_n = id, 1 end
    -- 11/26 Ch11 hive elevator: going up it said "Entered Building J / Left Building J /
    -- Entered K..." every few seconds. Rising or falling fast (lift, drop) = no speech.
    local vfast = false
    if tick.vy_at and now > tick.vy_at then
        vfast = math.abs(pos.y - tick.vy_y) / (now - tick.vy_at) > 1.2
    end
    tick.vy_at, tick.vy_y = now, pos.y
    if vfast then tick.vfast_until = now + 2 end
    if tick.cand_n == 2 and (P.inside or false) ~= id and tick.vfast_until and now < tick.vfast_until then
        P.inside = id or nil
    elseif tick.cand_n == 2 and (P.inside or false) ~= id then
        local old = building(P.inside)
        P.inside = id or nil
        local route_on = R() and R().active()
        if b then
            P.focus = b.id
            P.arrive = nil
            local okc, ct = pcall(P.contents, b, pos)
            local s = "Entered " .. label(b)
            if okc then
                s = s .. ", " .. contents_text(ct)
                if (#ct.items + #ct.things) > 0 and not P.hint_said then
                    P.hint_said = true
                    s = s .. ". Semicolon to Inside this building lists them"
                end
            end
            say(s .. ".")
        elseif old and listed(old) and not route_on then
            local okc, ct = pcall(P.contents, old, pos)
            local s = "Left " .. label(old)
            if okc then
                s = s .. (#ct.items > 0 and (", " .. plural(#ct.items, "item", "items") .. " not picked up") or "")
            end
            say(s .. ".")
        end
    end
    -- reached an open doorway: turn to face inside
    local a = P.arrive
    if a and not a.door and not (R() and R().active()) then
        if d2(a.out, pos) < 2 then
            G.face_point(a.inn)
            say("Way in ahead. Walk in with W.")
        end
        P.arrive = nil
    end
end

RE4Access.places = P
log.info("[RE4Access] places (buildings) loaded")
return P
