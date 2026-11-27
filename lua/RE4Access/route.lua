-- RE4 Access: route finder.
-- Builds its own walking route with physics rays (the game's navmesh only
-- answers for a few metres). A grid of 0.8 m cells is searched outward from
-- Leon: each cell gets its ground height from a downward ray, and a step
-- between cells is allowed when the ground is not too steep and rays at knee
-- and chest height don't hit a wall. The search runs a few milliseconds per
-- frame so the game doesn't stutter.
--
-- The game loads collision in chunks, so a far goal may have no ground or walls
-- yet. Then the route goes to the reachable spot closest to the goal, and plans
-- again from there once more has loaded.
--
-- While a route is active the camera keeps turning toward a point about 2 m
-- ahead on the route, so holding W walks it. Walking off the route or getting
-- blocked makes it plan again from where Leon is.

local R = {}
local nav_route      -- defined with the navmesh code below

local CELL = 0.8            -- grid cell size (m)
local MAX_STEP_UP = 0.8     -- ground height change allowed between cells (m); stairs need ~0.6+
local KNEE, CHEST = 0.55, 1.35
local BUDGET = 0.004        -- seconds of searching per frame
local MAX_NODES = 25000
local GOAL_RADIUS = 1.3
local LOOKAHEAD = 1.5     -- aim point ahead on the route (short = fewer cut corners)
local OFF_ROUTE = 3.0

-- Leon's own CharacterController filter (live-read 10/11): rays hit exactly what blocks him.
R.cast_cfg = { layer = 2, mask = 788, group = 12 }
R.stats = { rays = 0 }

local function say(text, interrupt)
    if interrupt == nil then interrupt = true end
    -- 10/27: re-routes after kidnapped Ashley said "Route found, N meters" every
    -- 2 s in the Checkpoint fight, over the danger cues. Silent while set.
    if RE4Access.route_quiet and text and (text:find("^Route found") or text:find("^Part of the way") or text:find("^Only part")) then return end
    RE4Access.speak(text, interrupt)
end

-- 0.25.3 (ON1XN 11/3): arriving where F is needed. On a story route (N) one
-- short "stop, press F" sound first, so holding W doesn't run past it; and the
-- line is protected for a few seconds so the next ordinary line can't cut it
-- off (danger lines and fights still cut in: RE4Access.lua protected_now).
local function arrive_f(text)
    if R.story and RE4Access.sound then RE4Access.sound("stopf") end
    say(text, true)
    RE4Access.protect_until = os.clock() + math.min(7, 2 + #tostring(text) * 0.06)
    log.info("[RE4Access] arrive F" .. (R.story and " (story, sound)" or "") .. ": " .. tostring(text))
end

-- ---------------- physics rays ----------------

local phys_t = sdk.find_type_definition("via.physics.System")
local cast_method = phys_t and phys_t:get_method("castRay(via.physics.CastRayQuery, via.physics.CastRayResult)")
local query, result

local function new_objects()
    query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
    result = sdk.create_instance("via.physics.CastRayResult"):add_ref()
end

local function cast_once(ax, ay, az, bx, by, bz, cfg)
    pcall(function() result:call("clear") end)
    query:call("setRay(via.vec3, via.vec3)", Vector3f.new(ax, ay, az), Vector3f.new(bx, by, bz))
    query:call("clearOptions")
    query:call("enableNearSort")
    local fi = query:call("get_FilterInfo")
    fi:call("set_Group", cfg.group)
    fi:call("set_MaskBits", cfg.mask)
    fi:call("set_Layer", cfg.layer)
    query:call("set_FilterInfo", fi)
    cast_method:call(sdk.get_native_singleton("via.physics.System"), query, result)
    if result:call("get_NumContactPoints") == 0 then return nil end
    local cp = result:call("getContactPoint(System.UInt32)", 0)
    return cp:get_field("Position"), cp:get_field("Distance")
end

-- Name of the thing the last ray hit (11/26: the "branch" in front of the Ch10
-- ballroom Ruby nest was an invisible Novistador flight zone, "..._ch1d3z0Area").
function R.last_hit_name()
    local name
    pcall(function()
        if result:call("get_NumContactPoints") == 0 then return end
        name = result:call("getContactCollidable(System.UInt32)", 0):call("get_GameObject"):call("get_Name")
    end)
    return name
end

-- Returns hit position, hit distance (nil when nothing was hit).
-- The query objects can go stale (freed by the game); then they are rebuilt.
function R.cast(ax, ay, az, bx, by, bz, cfg)
    cfg = cfg or R.cast_cfg
    if not query then new_objects() end
    R.stats.rays = R.stats.rays + 1
    local ok, hit, d = pcall(cast_once, ax, ay, az, bx, by, bz, cfg)
    if ok then return hit, d end
    R.stats.rebuilds = (R.stats.rebuilds or 0) + 1
    new_objects()
    return cast_once(ax, ay, az, bx, by, bz, cfg)
end

-- Ground height under (x, z), searching from just above ref_y downward.
-- Starting only 1.8 m above keeps tree tops and roofs from counting as ground.
local function ground(x, ref_y, z)
    local hit = R.cast(x, ref_y + 1.8, z, x, ref_y - 3.0, z)
    return hit and hit.y or nil
end

-- True when a wall is between two points at knee or chest height.
-- Leon is about 0.5 m wide, so knee-height rays also run 0.2 m to each side:
-- routes then keep to the middle of doorways instead of brushing the frame.
local SIDE = 0.2
local function wall_between(ax, ay, az, bx, by, bz)
    if R.cast(ax, ay + KNEE, az, bx, by + KNEE, bz) ~= nil
        or R.cast(ax, ay + CHEST, az, bx, by + CHEST, bz) ~= nil then return true end
    local dx, dz = bx - ax, bz - az
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then return false end
    local ox, oz = -dz / len * SIDE, dx / len * SIDE
    return R.cast(ax + ox, ay + KNEE, az + oz, bx + ox, by + KNEE, bz + oz) ~= nil
        or R.cast(ax - ox, ay + KNEE, az - oz, bx - ox, by + KNEE, bz - oz) ~= nil
end

-- Try every layer and report which ones see the ground under Leon and a wall
-- ahead. Used once to pick the layer for route rays (logged).
function R.calibrate(p)
    p = p or function(...) log.info("[RE4Access] " .. table.concat({ ... }, " ")) end
    local pos = RE4Access.game.player_pos()
    if not pos then p("no player") return end
    local found
    for layer = 0, 31 do
        local cfg = { layer = layer, mask = 0, group = 0 }
        local ok, hit = pcall(R.cast, pos.x, pos.y + 1.5, pos.z, pos.x, pos.y - 2, pos.z, cfg)
        if ok and hit then
            p(string.format("layer %d ground y=%.2f (player y=%.2f)", layer, hit.y, pos.y))
            if not found and math.abs(hit.y - pos.y) < 0.4 then found = layer end
        elseif not ok then
            p("layer " .. layer .. " error " .. tostring(hit))
        end
    end
    if found then R.cast_cfg.layer = found end
    p("chosen layer " .. tostring(found))
    return found
end

-- ---------------- the search ----------------

local DIRS = {
    { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
    { 1, 1, 1.4142 }, { 1, -1, 1.4142 }, { -1, 1, 1.4142 }, { -1, -1, 1.4142 },
}

-- Binary heap on f.
local function heap_push(h, n)
    h[#h + 1] = n
    local i = #h
    while i > 1 do
        local par = i // 2
        if h[par].f <= h[i].f then break end
        h[par], h[i] = h[i], h[par]
        i = par
    end
end
local function heap_pop(h)
    local top = h[1]
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local i = 1
        while true do
            local l, r, m = 2 * i, 2 * i + 1, i
            if l <= #h and h[l].f < h[m].f then m = l end
            if r <= #h and h[r].f < h[m].f then m = r end
            if m == i then break end
            h[i], h[m] = h[m], h[i]
            i = m
        end
    end
    return top
end

local search      -- running search, or nil
local route       -- { points = {...}, goal =, name = }
R.blocked_world = {}   -- spots where Leon got stuck (avoided on replan)

-- 11/15 (Chapter 10 start, Grand Hall corridor): cage bars beside the Chimera statue are
-- not in the navmesh. Leon walked into the pocket west of the statue (130.6,40.1) and every
-- navmesh route (ladder, Sapphire) went straight through the bars: "Blocked, finding another
-- way" 8 times with the SAME path, because the navmesh ignores blocked spots and N cleared
-- them. Stuck marks: spots just in front of Leon where he could not pass; kept 3 minutes
-- (N does not clear them); routes that cross one are re-planned through a detour point.
R.stuck_marks = R.stuck_marks or {}
local function live_marks()
    local now, keep = os.clock(), {}
    for _, m in ipairs(R.stuck_marks) do if now - m.t < 180 then keep[#keep + 1] = m end end
    R.stuck_marks = keep
    return keep
end
local function is_blocked_spot(x, z)
    for _, b in ipairs(R.blocked_world) do
        if (b.x - x) ^ 2 + (b.z - z) ^ 2 < 0.8 then return true end
    end
    for _, b in ipairs(R.stuck_marks) do
        if (b.x - x) ^ 2 + (b.z - z) ^ 2 < 0.3 then return true end
    end
    return false
end
-- true when the path passes within 0.5 m of a stuck mark (same floor)
function R.path_hits_stuck(pts)
    local marks = live_marks()
    if #marks == 0 or not pts then return false end
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        for _, m in ipairs(marks) do
            if math.abs((m.y or a.y) - a.y) < 2 then
                local t = l2 > 0 and math.max(0, math.min(1, ((m.x - a.x) * dx + (m.z - a.z) * dz) / l2)) or 0
                local px, pz = a.x + dx * t, a.z + dz * t
                if (px - m.x) ^ 2 + (pz - m.z) ^ 2 < 0.25 then return true, m end
            end
        end
    end
    return false
end

local function start_search(from, goal, name)
    local ox, oz = from.x, from.z
    local s = {
        ox = ox, oz = oz, goal = goal, name = name,
        open = {}, nodes = {}, gcache = {}, expanded = 0, started = os.clock(), rays0 = R.stats.rays,
    }
    local n = { ix = 0, iz = 0, x = ox, y = from.y, z = oz, g = 0 }
    n.f = math.sqrt((goal.x - ox) ^ 2 + (goal.z - oz) ^ 2) * 1.2
    s.nodes[0 .. "," .. 0 .. "," .. math.floor(from.y / 1.5 + 0.5)] = n
    heap_push(s.open, n)
    s.limit = math.sqrt((goal.x - ox) ^ 2 + (goal.z - oz) ^ 2) + 40   -- don't wander further than this
    s.doors = {}
    pcall(function() s.doors = RE4Access.game.door_positions(from, s.limit) end)
    search = s
    R.last_search = s   -- for debugging
end

local function finish(s, last)
    -- Walk parents back to the start, keep points every ~1.6 m.
    local pts = {}
    local n = last
    while n do
        table.insert(pts, 1, { x = n.x, y = n.y, z = n.z })
        n = n.parent
    end
    local total = 0
    for i = 2, #pts do total = total + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].z - pts[i - 1].z) ^ 2) end
    -- Center points in narrow places (doorways, corridors): measure the free space
    -- to the left and right at knee height and move the point to the middle.
    for i = 2, #pts - 1 do
        local a, b = pts[i - 1], pts[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local len = math.sqrt(dx * dx + dz * dz)
        if len > 0.01 then
            local nx, nz = -dz / len, dx / len
            local q = pts[i]
            local y = q.y + KNEE
            local _, dl = R.cast(q.x, y, q.z, q.x + nx * 1.2, y, q.z + nz * 1.2)
            local _, dr = R.cast(q.x, y, q.z, q.x - nx * 1.2, y, q.z - nz * 1.2)
            if dl and dr then
                local shift = math.max(-0.4, math.min(0.4, (dl - dr) / 2))
                q.x, q.z = q.x + nx * shift, q.z + nz * shift
            elseif dl and dl < 0.45 then
                q.x, q.z = q.x - nx * (0.45 - dl), q.z - nz * (0.45 - dl)
            elseif dr and dr < 0.45 then
                q.x, q.z = q.x + nx * (0.45 - dr), q.z + nz * (0.45 - dr)
            end
        end
    end
    pts[#pts + 1] = { x = s.goal.x, y = s.goal.y, z = s.goal.z }
    return pts, total
end

-- One slice of the search. Returns "done", "fail" or nil (still running).
-- Nodes are keyed by cell AND height band, so a basement under a floor (or a
-- floor over a basement) are separate places.
local function band(y) return math.floor(y / 1.5 + 0.5) end
local function nkey(ix, iz, y) return ix .. "," .. iz .. "," .. band(y) end

-- Ground under a cell, searched from the height of the cell we come from.
local function cell_ground(s, ix, iz, from_y)
    local gk = ix .. "," .. iz .. "," .. band(from_y)
    local y = s.gcache[gk]
    if y == nil then
        y = ground(s.ox + ix * CELL, from_y, s.oz + iz * CELL) or false
        s.gcache[gk] = y
    end
    return y or nil
end

local function step_search(s)
    local t_end = os.clock() + BUDGET
    local gx, gz, gy = s.goal.x, s.goal.z, s.goal.y
    while os.clock() < t_end do
        local cur = heap_pop(s.open)
        if not cur then return "fail" end
        if not cur.closed then
            cur.closed = true
            s.expanded = s.expanded + 1
            if s.expanded > MAX_NODES then return "fail" end
            local dg = math.sqrt((gx - cur.x) ^ 2 + (gz - cur.z) ^ 2) + math.max(0, math.abs(gy - cur.y) - 2)
            if not s.best or dg < s.best_d then s.best, s.best_d = cur, dg end
            if dg < GOAL_RADIUS and math.abs(gy - cur.y) < 2.5 then
                s.result = cur
                return "done"
            end
            for _, d in ipairs(DIRS) do
                local ix, iz = cur.ix + d[1], cur.iz + d[2]
                local x, z = s.ox + ix * CELL, s.oz + iz * CELL
                if not is_blocked_spot(x, z) and math.sqrt((x - s.ox) ^ 2 + (z - s.oz) ^ 2) <= s.limit then
                    local y = cell_ground(s, ix, iz, cur.y)
                    -- Diagonal steps need both side cells walkable (no corner cutting).
                    local diag_ok = true
                    if y and d[1] ~= 0 and d[2] ~= 0 then
                        local ya = cell_ground(s, cur.ix + d[1], cur.iz, cur.y)
                        local yb = cell_ground(s, cur.ix, cur.iz + d[2], cur.y)
                        diag_ok = ya and yb and math.abs(ya - cur.y) <= MAX_STEP_UP and math.abs(yb - cur.y) <= MAX_STEP_UP
                    end
                    local why
                    if not y then why = "noground"
                    elseif not diag_ok then why = "corner"
                    elseif math.abs(y - cur.y) > MAX_STEP_UP * d[3] then why = "steep" end
                    local k = y and nkey(ix, iz, y)
                    local nb = k and s.nodes[k]
                    if y and not (nb and nb.closed) and not why then
                        -- Close to the goal the target itself (a door) may be in the way.
                        local skip_walls = math.sqrt((gx - x) ^ 2 + (gz - z) ^ 2) < GOAL_RADIUS
                        -- Closed doors are walls to the rays, but you can open them. Only the
                        -- step crossing the doorway (its midpoint near the door middle).
                        if not skip_walls then
                            local mx, mz = (cur.x + x) / 2, (cur.z + z) / 2
                            for _, dp in ipairs(s.doors) do
                                if (dp.x - mx) ^ 2 + (dp.z - mz) ^ 2 < 0.5 and math.abs(dp.y - y) < 2 then skip_walls = true break end
                            end
                        end
                        if not skip_walls and wall_between(cur.x, cur.y, cur.z, x, y, z) then
                            why = "wall"
                        else
                            if not nb then
                                nb = { ix = ix, iz = iz, x = x, z = z, y = y, g = math.huge }
                                s.nodes[k] = nb
                            end
                            local g = cur.g + CELL * d[3] + math.max(0, y - cur.y)
                            if g < nb.g then
                                nb.g, nb.parent = g, cur
                                nb.f = g + 1.2 * (math.sqrt((gx - x) ^ 2 + (gz - z) ^ 2) + math.abs(gy - y))
                                nb.closed = false
                                heap_push(s.open, nb)
                            end
                        end
                    end
                    if why then
                        s.blocked = s.blocked or {}
                        s.blocked[ix .. "," .. iz] = s.blocked[ix .. "," .. iz] or why
                    end
                end
            end
        end
    end
end

-- ---------------- following ----------------

local function dist2d(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

local function closest_index(pts, pos, from)
    local best, bi = math.huge, from
    for i = math.max(1, from - 2), math.min(#pts, from + 25) do
        local d = dist2d(pts[i], pos)
        -- a point on another floor is not "here" (10/15: upstairs in the Chief's
        -- house the route below, under Leon's feet, won; he was steered into a wall)
        if pts[i].y and pos.y and math.abs(pts[i].y - pos.y) > 1.6 then d = d + 20 end
        if d < best then best, bi = d, i end
    end
    return bi, (pts[bi] and dist2d(pts[bi], pos) or best)
end

local last_face, replans = 0, 0

local function follow(pos, now)
    local pts = route.points
    local a = route.action
    if route.waiting then
        -- At a window or ladder: wait until Leon comes out on the other side.
        -- A window's two sides are only ~1.2 m apart, so "near the exit" is true
        -- before the jump (10/22 Building G: "Through" + same window again, loop).
        -- Past the window plane on the exit side counts as through.
        local past = true
        if a.kind == "window" and a.face then
            local nx, nz = a.exit.x - a.entry.x, a.exit.z - a.entry.z
            local nl = math.sqrt(nx * nx + nz * nz)
            if nl > 0.01 then past = ((pos.x - a.face.x) * nx + (pos.z - a.face.z) * nz) / nl > 0.3 end
        end
        if past and dist2d(pos, a.exit) < 1.6 and math.abs(pos.y - a.exit.y) < 1.2 then
            local goal, name = route.goal, route.name
            route = nil
            say("Through. On to " .. name, false)
            if nav_route({ x = pos.x, y = pos.y, z = pos.z }, goal, name, true) then return end
            start_search({ x = pos.x, y = pos.y, z = pos.z }, goal, name)
            search.quiet = true
            search.after_through = true
            return
        end
        if dist2d(pos, a.entry) > 4 and math.abs(pos.y - a.entry.y) < 1.5 then
            R.replan(pos, "Off route, finding a new way")
            return
        end
        -- A drop the game won't let you take (10/14 6:13PM: factory back stairs,
        -- 'Edge here' 5 times by the Sapphire chest, F did nothing): remember it
        -- and walk the long way round.
        -- 11/8 Ch8 window: the user was shooting cultists (L held) at the sill,
        -- the 20 s ran out and the good window was marked bad. Aiming or an
        -- enemy within 6 m restarts the clock.
        if a.kind == "drop" and route.wait_since then
            local busy = false
            pcall(function()
                local GG = RE4Access.game
                if GG.aim_held() or #GG.enemies(pos, 6) > 0 then busy = true end
            end)
            if busy then route.wait_since = now end
        end
        if a.kind == "drop" and route.wait_since and now - route.wait_since > 20 then
            R.bad_drops[#R.bad_drops + 1] = { x = a.entry.x, y = a.entry.y, z = a.entry.z }
            log.info(string.format("[RE4Access] bad drop remembered (%.2f,%.2f,%.2f)", a.entry.x, a.entry.y, a.entry.z))
            R.replan(pos, "No jump here. Finding the way around")
            return
        end
        -- repeat the F reminder at most twice (10/18: "Ladder. Press F to climb
        -- down" every 12 s while the user stood reading at the barn trapdoor)
        if now - route.prompt_at > 12 and (route.prompt_n or 0) < 2 then
            route.prompt_at = now
            route.prompt_n = (route.prompt_n or 0) + 1
            RE4Access.game.face_point(a.face, true)
            say(a.text .. (RE4Access.game.spoken and (" It is " .. (RE4Access.game.last_dir or "near") .. ".") or ""), false)
        end
        return
    end
    local ci, off = closest_index(pts, pos, route.idx)
    -- A point Leon has already passed is done, even while it is still the nearest
    -- (10/15, bear trap by the Chief's front door: just past a point he was turned
    -- back to it, reached it, turned forward, passed it - swinging on the spot).
    -- Only within 1 m of it, so a sharp bend is not cut short.
    do
        local p1, p2 = pts[ci], pts[ci + 1]
        if p2 and not (p1.y and math.abs(p1.y - pos.y) > 1.6) then
            -- 11/1 Ch7 start: bend point followed by a 4.5 m leg. 1 m past the bend it was
            -- still the nearest point, so Leon was turned back to it, turned forward,
            -- back again for 30 s. On the next leg (within 1.2 m of it) = passed too.
            local ux, uz = p2.x - p1.x, p2.z - p1.z
            local ul = math.sqrt(ux * ux + uz * uz)
            local along = (pos.x - p1.x) * ux + (pos.z - p1.z) * uz
            if along > 0 and ul > 0.01 then
                local perp = math.abs((pos.x - p1.x) * uz - (pos.z - p1.z) * ux) / ul
                if dist2d(p1, pos) < 1.0 or (along / ul < ul and perp < 1.2) then ci = ci + 1 end
            end
        end
    end
    route.idx = ci
    -- 0.25.4 (ON1XN 11/4, 0.25.3 still ran past F spots): the stop sound came only
    -- once Leon was ON the spot (0.45 m for picked things), and a running Leon
    -- that passed beside it never "arrived" at all. On N routes: warn 3.5 m before,
    -- and if he passes it, say so and that it is behind him.
    if R.story and ci >= #pts - 1 then
        local nm = tostring(route.name)
        local needs_f = (a and tostring(a.text):find("F")) or (not a and (route.face_target or route.crate
            or nm == "the crank" or nm:find("to kick it", 1, true) or nm:find("shutter", 1, true) or nm == "the other door"))
        if needs_f then
            local d = dist2d(pts[#pts], pos)
            if not route.near_warned and d < 3.5 and d > 1.2 then
                route.near_warned = true
                if RE4Access.sound then RE4Access.sound("stopf") end
                say("Slow down, let go of W. F spot " .. math.max(1, math.floor(d + 0.5)) .. " meters ahead.", true)
                RE4Access.protect_until = os.clock() + 2.5
                log.info(string.format("[RE4Access] F spot near warning %.1f m: %s", d, nm))
            end
            route.min_d = math.min(route.min_d or 99, d)
            if route.min_d < 1.8 and d > route.min_d + 0.8 and (not route.passed_at or now - route.passed_at > 4) then
                route.passed_at = now
                say("Stop, you went past it. Let go of W. It is behind you, " .. math.max(1, math.floor(d + 0.5)) .. " meters. Turn around and walk back slowly.", true)
                RE4Access.protect_until = os.clock() + 3
                log.info(string.format("[RE4Access] F spot passed: closest %.2f m, now %.2f m: %s", route.min_d, d, nm))
                route.min_d = d
            end
        end
    end
    -- Drops need the exact spot (10/14: the lookout jump works within about
    -- 0.45 m; the route stopped 1.1 m short and F did nothing).
    local arrive_r = (a and a.kind == "drop") and 0.4 or GOAL_RADIUS
    if a and dist2d(pts[#pts], pos) < arrive_r then
        route.waiting, route.prompt_at = true, now
        route.wait_since = route.wait_since or now
        RE4Access.game.face_point(a.face, true)
        local atext = a.text .. (RE4Access.game.spoken and (" It is " .. (RE4Access.game.last_dir or "near") .. ".") or "")
        if tostring(a.text):find("F") then arrive_f(atext) else say(atext, true) end
        return
    end
    -- Already down off the drop (walked off the edge before reaching the exact
    -- spot): carry on from below.
    -- (10/27 live: a fresh route from below planned a drop whose top was 1.2 m
    -- above Leon; this check fired at once, replanned the same drop and said
    -- "Down. On to ..." 10 times a second. Only after Leon was up there.)
    if a and a.kind == "drop" and pos.y >= a.entry.y - 0.6 then route.was_up = true end
    if a and a.kind == "drop" and route.was_up and pos.y < a.entry.y - 1.2 and dist2d(pos, a.entry) < 6 then
        local goal, name = route.goal, route.name
        route = nil
        say("Down. On to " .. name, false)
        if nav_route({ x = pos.x, y = pos.y, z = pos.z }, goal, name, true) then return end
        start_search({ x = pos.x, y = pos.y, z = pos.z }, goal, name)
        search.quiet = true
        return
    end
    -- Only near the end of the route (10/15: under the Chief's typewriter, one floor
    -- down, a fresh 26 m route via the stairs was replanned 7 times at once: "Stuck").
    local same_floor = math.abs(pts[#pts].y - pos.y) <= 1.8
    if dist2d(pts[#pts], pos) < GOAL_RADIUS and not same_floor and ci >= #pts - 1 then
        R.replan(pos, "Wrong floor, finding the way")
        return
    end
    if not a and same_floor and dist2d(pts[#pts], pos) < GOAL_RADIUS and not route.wall_checked and not tostring(route.name):find("bird's nest", 1, true) then
        local g = pts[#pts]
        -- wall_before: the thing an item hangs on is no wall (10/14: the emblem's
        -- post on the roof -> "going around" 6 times in a second, then "Stuck").
        local okc, wall = pcall(RE4Access.game.wall_before, { x = pos.x, y = pos.y + 1.2, z = pos.z }, { x = g.x, y = g.y + 1.0, z = g.z })
        if dist2d(g, pos) < 2.5 then wall = false end
        if okc and wall then
            route.wall_checked = true
            R.replan(pos, "Wall in the way, going around")
            return
        end
    end
    -- With a drop/ladder/window still ahead the end of these points is NOT the
    -- goal (10/14 5:56PM: 'Arrived at Crank stand' 1 m from a drop, 58 m away).
    -- A spot picked so only one thing is in F reach needs the exact spot too
    -- (10/15: stopped 1.1 m short of the Red Herb spot, F kept going to the typewriter).
    local goal_r = route.face_target and 0.45 or GOAL_RADIUS
    if not a and same_floor and dist2d(pts[#pts], pos) < goal_r then
        if route.partial then
            local goal, name = route.goal, route.name
            route = nil
            say("Looking further", false)
            if nav_route({ x = pos.x, y = pos.y, z = pos.z }, goal, name, true) then return end
            start_search({ x = pos.x, y = pos.y, z = pos.z }, goal, name)
            search.quiet, search.partial_hop = true, true
            return
        end
        local name = route.name
        local route_crate = route.crate
        local route_face = route.face_target
        local route_after = route.after_text
        route = nil
        -- At a shooting spot: stop there (10/12: arrived at the bird's nest spot,
        -- kept walking and stepped into a bear trap).
        if tostring(name):find("to kick it", 1, true) then
            arrive_f("Stop here, let go of W. Press F to kick the padlock. If the door stays shut, press F again.")
        elseif tostring(name):find("shoot", 1, true) then
            say("Stop here, let go of W. Hold L, then press K when I say fire.", true)
        elseif name == "the crank" then
            arrive_f("Stop here, let go of W. Hold F to turn the wheel. Keep holding until I say fully turned.")
        elseif tostring(name):find("shutter", 1, true) then
            arrive_f("At the shutter. Press F to slide under it. Quick!")
        elseif route_face then
            pcall(RE4Access.game.face_item, route_face)
            arrive_f("Stop here, let go of W. " .. (tostring(name):gsub("^%l", string.upper)) .. " is in front of you. " .. (route_after or "Wait for F ready, then press F."))
            pcall(RE4Access.game.expect_prompt)
            pcall(RE4Access.game.want_f, { pos = route_face, name = name })
        elseif route_crate then
            pcall(RE4Access.game.face_item, route_crate.item)
            arrive_f("Stop here, let go of W. The crate is in front of you. " .. route_crate.tail)
        elseif name == "the other door" and R.pending_target then
            local t = R.pending_target
            -- 10/15: plan the way in only once the door is open (a shut door cuts
            -- the walking map, so planning at once could fail or go round again).
            if R.pending_door then pcall(RE4Access.game.face_point, R.pending_door, true) end
            arrive_f("At the other door. Hold W to walk into it, or press F. I'll go on to " .. tostring(t.name) .. " once it opens.")
            R.door_wait = { target = t, until_t = os.clock() + 30, next_at = os.clock() + 1 }
            R.pending_target, R.pending_door = nil, nil
            return
        elseif not RE4Access.game.sneak_on then   -- 11/9 sneak: silent waypoints
            local ex = ""
            pcall(function() ex = RE4Access.game.arrive_extra(name) or "" end)
            say("Arrived at " .. name .. ex)
        end
        if RE4Access.game.on_arrived then RE4Access.game.on_arrived() end
        return
    end
    if off > OFF_ROUTE then
        R.replan(pos, "Off route, finding a new way")
        return
    end
    -- Aim at the first point at least LOOKAHEAD metres away.
    local ti = ci
    -- After a bump, steer straight at the next route point for a few seconds.
    local look = (route.precise_until and now < route.precise_until) and 0.5 or LOOKAHEAD
    for i = ci, math.min(#pts, ci + 2) do if pts[i].trap then look = 0.6 end end
    -- Don't cut a sharp bend: reach the bend point first (10/15: top of the Chief's
    -- stairs, cutting the bend walked Leon into the railing post for 80 s).
    while ti < #pts and dist2d(pts[ti], pos) < look do
        local p0, p1, p2 = pts[ti - 1], pts[ti], pts[ti + 1]
        if p0 and p2 and dist2d(p1, pos) > 0.45 then
            local ax, az, bx, bz = p1.x - p0.x, p1.z - p0.z, p2.x - p1.x, p2.z - p1.z
            local la, lb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
            if la > 0.2 and lb > 0.2 and (ax * bx + az * bz) / (la * lb) < 0.8 then break end   -- bend > ~37 deg
        end
        ti = ti + 1
    end
    if RE4Access.game.spoken then
        if now - last_face > 0.3 then last_face = now RE4Access.game.guide_to(pts[ti], now) end
    elseif now - last_face > 0.25 and not (RE4Access.game.aim_held and RE4Access.game.aim_held())
        and not (RE4Access.game.guard_until and now < RE4Access.game.guard_until) then
        last_face = now
        local f = RE4Access.game.facing()
        local want = (math.deg(math.atan(pts[ti].x - pos.x, pts[ti].z - pos.z)) + 360) % 360
        if not f or math.abs((want - f + 540) % 360 - 180) > 8 then
            RE4Access.game.face_point(pts[ti], true)
        end
    end
    -- Tripwire laser across the route ahead: warn once at about 8 m.
    for _, lz in ipairs(route.lasers or {}) do
        if not lz.said and lz.idx >= ci and RE4Access.game.trap_live(lz.bomb.go) then
            local d = 0
            local prev = pos
            for i = ci + 1, lz.idx do d = d + dist2d(prev, pts[i]) prev = pts[i] end
            if d < 8 then
                lz.said = true
                say(string.format("Stop! Tripwire bomb across the path, %d meters ahead. Shoot it first: hold L, press K. Stay back at least 4 meters.", math.floor(d + 0.5)), true)
            end
        end
    end
    -- Low passages: "press E to crouch" before, "press E to stand" after.
    local crouch_ahead = false
    for i = ci, math.min(#pts, ci + 3) do
        if pts[i].crouch and dist2d(pts[i], pos) < 2.5 then crouch_ahead = true end
    end
    if crouch_ahead and not route.crouch_said then
        route.crouch_said = true
        say("Low passage ahead. Press E to crouch, then keep holding W.", true)
    elseif route.crouch_said and not crouch_ahead then
        local any_near = false
        for i = math.max(1, ci - 2), math.min(#pts, ci + 3) do if pts[i].crouch then any_near = true end end
        if not any_near then
            route.crouch_said = false
            say("Through. Press E to stand up.", true)
        end
    end
    -- Turn-by-turn (10/13, user): "Straight 12 meters, then turn left" whenever
    -- the next turn or door changes. Spoken mode only; Period asks any time.
    local m = R.next_mark(pos)
    if m and route.mark_said ~= m.mark then
        route.mark_said = m.mark
        if m.mark.kind == "door" and m.mark.idx > 0 then route.door_passing = m.mark end
        if RE4Access.game.spoken and now - (route.turn_said_at or -10) > 2 then
            route.turn_said_at = now
            say(R.next_turn_text(pos), false)
        end
    end
    -- Through the building's door: say how far is left inside (both modes).
    local dm = route.door_passing
    if dm and ci > dm.idx and dist2d(pos, pts[dm.idx]) > 1.5 then
        route.door_passing = nil
        local left = R.left(pos)
        if left and left > 2 then say(string.format("Through the door. %d meters to %s.", math.floor(left + 0.5), route.name), false) end
    end
end

-- ---------------- turns and doors along the route ----------------
-- The route's corners (Douglas-Peucker simplified, so the navmesh's little
-- zigzags don't count) and the doors it walks through, in route order.
local function simplify(pts, i, j, tol, keep)
    local a, b = pts[i], pts[j]
    local dx, dz = b.x - a.x, b.z - a.z
    local len = math.sqrt(dx * dx + dz * dz)
    local best, bi = 0, nil
    for k = i + 1, j - 1 do
        local p = pts[k]
        local d
        if len < 0.01 then d = dist2d(p, a)
        else d = math.abs((p.x - a.x) * dz - (p.z - a.z) * dx) / len end
        if d > best then best, bi = d, k end
    end
    if bi and best > tol then
        simplify(pts, i, bi, tol, keep)
        keep[bi] = true
        simplify(pts, bi, j, tol, keep)
    end
end

local function heading(a, b) return math.deg(math.atan(b.x - a.x, b.z - a.z)) end

local function turn_word(t)
    local a, side = math.abs(t), t > 0 and "left" or "right"   -- higher heading = left (10/19 fix)
    if a < 60 then return "bear " .. side
    elseif a < 130 then return "turn " .. side
    else return "turn sharp " .. side end
end

local function build_marks(pts)
    local marks = {}
    if #pts < 3 then return marks end
    local keep = { [1] = true, [#pts] = true }
    simplify(pts, 1, #pts, 1.2, keep)
    local v = {}
    for i = 1, #pts do if keep[i] then v[#v + 1] = i end end
    for k = 2, #v - 1 do
        local t = (heading(pts[v[k]], pts[v[k + 1]]) - heading(pts[v[k - 1]], pts[v[k]]) + 540) % 360 - 180
        if math.abs(t) >= 35 then marks[#marks + 1] = { idx = v[k], kind = "turn", angle = t } end
    end
    -- Doors the route passes through (within 1.3 m of a doorway middle).
    pcall(function()
        local G = RE4Access.game
        local mid = pts[math.floor(#pts / 2) + 1]
        local span = 0
        for _, p in ipairs(pts) do span = math.max(span, dist2d(p, mid)) end
        for _, t in ipairs(G.scan_things(mid, span + 3)) do
            if t.name == "Door" or t.name == "Gate" then
                local c = G.door_center_of(t)
                local bi, bd = nil, 1.3
                for i, p in ipairs(pts) do
                    local d = dist2d(p, c)
                    if d < bd and math.abs(p.y - c.y) < 2 then bi, bd = i, d end
                end
                if bi then
                    -- a door replaces a turn at the same spot
                    for n = #marks, 1, -1 do
                        if math.abs(marks[n].idx - bi) <= 1 then table.remove(marks, n) end
                    end
                    marks[#marks + 1] = { idx = bi, kind = "door", name = t.name:lower() }
                end
            end
        end
    end)
    table.sort(marks, function(a, b) return a.idx < b.idx end)
    return marks
end

-- Distance along the route from pos to point index idx (ci = closest index).
local function along(pts, pos, ci, idx)
    if idx <= ci then return dist2d(pos, pts[idx]) end
    local d = dist2d(pos, pts[ci + 1])
    for i = ci + 2, idx do d = d + dist2d(pts[i], pts[i - 1]) end
    return d
end

-- The next turn or door ahead: { mark =, dist = } or nil.
-- The route point Leon is walking toward now (Backslash faces it, 10/14).
function R.next_point()
    if not route then return nil end
    local pts = route.points
    return pts[math.min(#pts, (route.idx or 1) + 1)], route.name
end

function R.next_mark(pos)
    if not route then return nil end
    local pts = route.points
    if route.marks_for ~= pts then route.marks, route.marks_for = build_marks(pts), pts end
    local ci = closest_index(pts, pos, route.idx)
    for _, m in ipairs(route.marks) do
        if m.idx > ci or (m.idx == ci and dist2d(pos, pts[m.idx]) > 1.2 and ci < #pts
            and dist2d(pos, pts[ci + 1]) > dist2d(pts[ci], pts[ci + 1])) then
            return { mark = m, dist = along(pts, pos, ci, m.idx) }
        end
    end
    return nil
end

-- "Straight 12 meters, then turn left. Then 8 meters to Handgun Ammo."
function R.next_turn_text(pos)
    if search then return "Still looking for a way to " .. search.name end
    if not route then return nil end
    local left = R.left(pos) or 0
    local m = R.next_mark(pos)
    local function what(mk)
        if mk.kind == "door" then return "go through the " .. mk.name end
        return turn_word(mk.angle)
    end
    if not m then
        local s = string.format("Straight %d meters to %s", math.floor(left + 0.5), route.name)
        if route.action then s = s .. ", then " .. route.action.kind end
        return s .. "."
    end
    local d = math.floor(m.dist + 0.5)
    local s = d <= 2 and (what(m.mark):gsub("^%l", string.upper) .. " now") or string.format("Straight %d meters, then %s", d, what(m.mark))
    -- What comes after that turn: the next one, or the goal.
    local pts = route.points
    local after
    for _, mk in ipairs(route.marks) do if mk.idx > m.mark.idx then after = mk break end end
    if after then
        local gap = 0
        for i = m.mark.idx + 1, after.idx do gap = gap + dist2d(pts[i], pts[i - 1]) end
        s = s .. string.format(". Then %d meters, %s", math.floor(gap + 0.5), what(after))
    else
        s = s .. string.format(". Then %d meters to %s", math.floor(math.max(0, left - m.dist) + 0.5), route.name)
    end
    return s .. "."
end

-- Doors the current route goes through (for the "route found" sentence).
function R.route_doors()
    if not route then return 0 end
    local pts = route.points
    if route.marks_for ~= pts then route.marks, route.marks_for = build_marks(pts), pts end
    local n = 0
    for _, m in ipairs(route.marks) do if m.kind == "door" then n = n + 1 end end
    return n
end

-- ---------------- public ----------------

function R.active() return route ~= nil or search ~= nil end
function R.current_action() return route and route.action end

-- Metres left along the route (nil when no route).
function R.left(pos)
    if not route then return nil end
    local pts = route.points
    local ci, off = closest_index(pts, pos, route.idx)
    local left = off
    for i = ci + 1, #pts do left = left + dist2d(pts[i], pts[i - 1]) end
    return left
end

-- For the status key: nil when no route, else a short sentence.
function R.status(pos)
    if search then return "Still looking for a way to " .. search.name end
    if not route then return nil end
    local pts = route.points
    local ci, off = closest_index(pts, pos, route.idx)
    local left = off
    for i = ci + 1, #pts do left = left + dist2d(pts[i], pts[i - 1]) end
    local s = string.format("%s, %d meters to go", route.name, math.floor(left + 0.5))
    if route.partial then s = s .. ", only part of the way known" end
    if off < 1 then s = s .. ". On the path"
    else s = s .. string.format(". %d meters off the path", math.floor(off + 0.5)) end
    return s
end

-- ---------------- the game's own navmesh ----------------
-- Leon's body has a via.navigation.NavigationSurface. queryPathSync gives a chain
-- of navmesh polygons (nodes) from Leon to the goal; the route goes through the
-- middle of the edge each polygon shares with the next one. (Near the game's
-- start this answered only for a few metres; later areas work fully.)
local nav_body
-- 11/14: in Ashley's part (Ch9 "Rescue Leon") Leon's body ch0a0z0_body is gone and the player
-- is Ashley (ch0a1z0_body, own NavigationSurface): every route failed and N sent her along
-- Leon's trail. The walking map now comes from whoever the player is.
-- 11/26 (Ch10, corridor past the door to the ballroom): the navmesh path cut the
-- door-frame corner - the first leg from Leon ran 0.6 m into the wall, "Blocked,
-- finding another way" twice, and the new route cut the same corner. Check each
-- flat leg with rays; when one hits a wall, put in a nearby point that has a clear
-- line from the leg's start and to a later route point (skipping the cut points).
-- Legs that climb or drop (stairs, ladders) are left alone.
-- floor under the whole line (no shortcut over a hole or a balcony edge)
local function floor_along(a, b)
    local n = math.max(1, math.ceil(dist2d(a, b) / 0.5))
    for k = 1, n - 1 do
        local t = k / n
        local gy = ground(a.x + (b.x - a.x) * t, a.y, a.z + (b.z - a.z) * t)
        if not gy or math.abs(gy - (a.y + ((b.y or a.y) - a.y) * t)) > 0.35 then return false end
    end
    return true
end

-- room for Leon's body (0.5 m) all round a new point
local function roomy(x, y, z)
    for k = 0, 7 do
        local ang = k * math.pi / 4
        if R.cast(x, y + KNEE, z, x + math.cos(ang) * 0.5, y + KNEE, z + math.sin(ang) * 0.5) ~= nil then return false end
    end
    return true
end

function R.fix_corners(pts, max_fix)
    if not pts or #pts < 2 then return pts end
    local out, fixes, i = { pts[1] }, 0, 1
    while i < #pts do
        local a, b = pts[i], pts[i + 1]
        local flat = math.abs((a.y or 0) - (b.y or 0)) < 0.15
        if fixes < (max_fix or 4) and flat and wall_between(a.x, a.y, a.z, b.x, b.y, b.z) then
            local best, bj, bc
            -- farthest reachable later point first: the points next to the cut corner
            -- hug the wall (first try went back to a point 0.2 m from the corner)
            for j = math.min(#pts, i + 5), i + 1, -1 do
                local t = pts[j]
                -- never skip a marked point (crouch, bear trap, link)
                local marked = false
                for m = i + 1, j - 1 do local q = pts[m] if q.crouch or q.trap or q.kind or q.action then marked = true end end
                if not marked and math.abs((t.y or a.y) - a.y) < 0.3 then
                    for _, r in ipairs({ 0.6, 1.0, 1.5, 2.0 }) do
                        for k = 0, 15 do
                            local ang = k * math.pi / 8
                            local cx, cz = a.x + math.cos(ang) * r, a.z + math.sin(ang) * r
                            local gy = ground(cx, a.y, cz)
                            if gy and math.abs(gy - a.y) < 0.3 then
                                local cost = r + dist2d({ x = cx, z = cz }, t)
                                if (not bc or cost < bc) and not wall_between(a.x, a.y, a.z, cx, gy, cz)
                                    and not wall_between(cx, gy, cz, t.x, t.y, t.z)
                                    and floor_along({ x = cx, y = gy, z = cz }, t) and roomy(cx, gy, cz) then
                                    best, bj, bc = { x = cx, y = gy, z = cz }, j, cost
                                end
                            end
                        end
                        if best then break end
                    end
                    if best then break end
                end
            end
            if best then
                fixes = fixes + 1
                out[#out + 1] = best
                log.info(string.format("[RE4Access] corner fix: leg (%.1f,%.1f)->(%.1f,%.1f) hits a wall, via (%.1f,%.1f) to point %d",
                    a.x, a.z, b.x, b.z, best.x, best.z, bj))
                out[#out + 1] = pts[bj]
                i = bj
            else
                out[#out + 1] = b
                i = i + 1
            end
        else
            out[#out + 1] = b
            i = i + 1
        end
    end
    return out
end

function R.dezigzag(pts)
    if not pts or #pts < 4 then return pts end
    local changed, guard = true, 0
    while changed and guard < 20 do
        changed, guard = false, guard + 1
        for i = 2, #pts - 1 do
            local p0, p1, p2 = pts[i - 1], pts[i], pts[i + 1]
            if not (p1.crouch or p1.trap or p1.kind or p1.action) and math.abs(p1.y - p0.y) < 0.4 and math.abs(p2.y - p1.y) < 0.4 then
                local ax, az, bx, bz = p1.x - p0.x, p1.z - p0.z, p2.x - p1.x, p2.z - p1.z
                local la, lb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
                local cx, cz = p2.x - p0.x, p2.z - p0.z
                local lc = math.sqrt(cx * cx + cz * cz)
                local dev = lc > 0.05 and math.abs((p1.x - p0.x) * cz - (p1.z - p0.z) * cx) / lc or 0
                local cosb = (la > 0.05 and lb > 0.05) and (ax * bx + az * bz) / (la * lb) or 1
                -- 11/14 PM (Knights' Hall, centaur statue): (120.4,14.0) -> (121.9,14.2) -> back to
                -- (119.0,10.7): a 1.5 m / 4.5 m out-and-back to the statue's corner; Leon stuck on it.
                -- A sharp reversal (> 110 deg) with legs up to 5 m also goes when the line past it is clear.
                if (la < 1.6 and lb < 1.6 and la > 0.05 and lb > 0.05 and (cosb < 0.5 or dev < 0.5))
                    or (la > 0.05 and lb > 0.05 and la < 5 and lb < 5 and cosb < -0.35) then
                    local okw, wall = pcall(wall_between, p0.x, p0.y, p0.z, p2.x, p2.y, p2.z)
                    if okw and not wall then
                        table.remove(pts, i)
                        changed = true
                        break
                    end
                end
            end
        end
    end
    return pts
end

local function nav_surface()
    local ok, surf = pcall(function()
        local body
        pcall(function() body = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_BodyGameObject") end)
        if body then nav_body = body end
        if not nav_body or not nav_body:call("get_Valid") then
            local sm = sdk.get_native_singleton("via.SceneManager")
            local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            nav_body = scene:call("findGameObject(System.String)", "ch0a0z0_body")
        end
        return nav_body:call("getComponent(System.Type)", sdk.typeof("via.navigation.NavigationSurface"))
    end)
    return ok and surf or nil
end

local function vkey(v) return string.format("%.2f,%.2f,%.2f", v.x, v.y, v.z) end

-- Returns a list of points from `from` to `goal` and the path length, or nil.
R.ONE_WAY_EDGES = {
    { name = "edge into the swamp", a = { x = 174.3, y = -0.3, z = 73.5 }, b = { x = 175.9, y = -6.1, z = 68.3 },
      face = { x = 175.0, y = -3, z = 69 },
      -- the swamp and the fish farm beyond it (the Boat Fuel is in a padlocked building there)
      area = { x1 = 100, x2 = 172, z1 = 30, z2 = 90 },
      text = "Hold W to walk off the edge. Leon drops into the swamp, there are enemies. Then press N again." },
}
function R.nav_points(from, goal)
    local surf = nav_surface()
    if not surf then return nil end
    local rep = sdk.create_instance("via.navigation.PathQueryReport", true)
    local ok, res = pcall(function()
        return surf:call("queryPathSync(via.vec3, via.vec3, via.navigation.PathQueryReport)",
            Vector3f.new(from.x, from.y, from.z), Vector3f.new(goal.x, goal.y, goal.z), rep)
    end)
    if not ok or not res then return nil end
    local pi = rep:call("get_PathInfo")
    local n = pi:call("getNodeCount()")
    if not n or n == 0 then return nil end
    local nodes = {}
    for i = 0, n - 1 do nodes[#nodes + 1] = pi:call("getNode(System.Int32)", i) end
    local function verts(node)
        local out = {}
        for k = 0, node:call("getGlobalVertexCount") - 1 do
            local v = node:call("getGlobalVertex", k)
            out[#out + 1] = { x = v.x, y = v.y, z = v.z }
        end
        return out
    end
    local pts = { { x = from.x, y = from.y, z = from.z } }
    local prev = verts(nodes[1])
    local function low(node)
        local ok, a = pcall(function() return node:call("get_Attribute") end)
        return ok and a and (a & 32) ~= 0
    end
    for i = 1, #nodes - 1 do
        local nxt = verts(nodes[i + 1])
        -- the edge shared by this polygon and the next: vertices they have in common
        local seen, shared = {}, {}
        for _, v in ipairs(prev) do seen[vkey(v)] = v end
        for _, v in ipairs(nxt) do if seen[vkey(v)] then shared[#shared + 1] = v end end
        if #shared >= 2 then
            local a, b = shared[1], shared[2]
            pts[#pts + 1] = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 }
        else
            local c = nodes[i + 1]:call("get_Pos")
            pts[#pts + 1] = { x = c.x, y = c.y, z = c.z }
        end
        -- Navmesh attribute 32 marks low passages (Leon must crouch, key E).
        if low(nodes[i]) or low(nodes[i + 1]) then pts[#pts].crouch = true end
        prev = nxt
    end
    -- The query snaps start and goal to the nearest floor in 2D: a goal on the
    -- ground floor right under Leon "succeeded" on the floor above (10/12, barn).
    -- The path's first and last mesh points must be on the start's/goal's floor.
    if math.abs(pts[#pts].y - goal.y) > 1.5 then return nil end
    if #pts >= 2 and math.abs(pts[2].y - from.y) > 1.5 then return nil end
    if #pts == 1 and math.abs(from.y - goal.y) > 1.5 then return nil end
    -- Where the walking map really ends: the goal if it lies on the last
    -- polygon, else the nearest point of that polygon's edges (10/17: a goal
    -- inside a closet; the polygon's entry edge was 1.7 m off).
    local snap
    pcall(function()
        local lv = verts(nodes[n])
        local inside, j = false, #lv
        for i = 1, #lv do
            local a, b = lv[i], lv[j]
            if ((a.z > goal.z) ~= (b.z > goal.z)) and (goal.x < (b.x - a.x) * (goal.z - a.z) / (b.z - a.z) + a.x) then inside = not inside end
            j = i
        end
        if inside then snap = { x = goal.x, y = lv[1].y, z = goal.z } return end
        local bd
        j = #lv
        for i = 1, #lv do
            local a, b = lv[j], lv[i]
            local ex, ez = b.x - a.x, b.z - a.z
            local l2 = ex * ex + ez * ez
            local t = l2 > 0 and math.max(0, math.min(1, ((goal.x - a.x) * ex + (goal.z - a.z) * ez) / l2)) or 0
            local q = { x = a.x + ex * t, y = a.y + (b.y - a.y) * t, z = a.z + ez * t }
            local d = (q.x - goal.x) ^ 2 + (q.z - goal.z) ^ 2
            if not bd or d < bd then snap, bd = q, d end
            j = i
        end
    end)
    pts[#pts + 1] = { x = goal.x, y = goal.y, z = goal.z }
    -- Shut gates and closed shutters: the navmesh walks through them; no path
    -- (10/14: Valley entrance shutter -> the plan went down the entrance ladder
    -- and back up, round and round).
    local blocked = false
    pcall(function()
        for _, gp in ipairs(RE4Access.game.asleep_gate_positions(from, 80)) do
            for i, q in ipairs(pts) do
                if i > 2 and i < #pts and (q.x - gp.x) ^ 2 + (q.z - gp.z) ^ 2 < 1.0 and math.abs(q.y - gp.y) < 2 then blocked = true return end
            end
        end
    end)
    if blocked then return nil end
    -- drop points closer than 0.7 m to the previous one
    local out = { pts[1] }
    for i = 2, #pts do
        local l = out[#out]
        if math.sqrt((pts[i].x - l.x) ^ 2 + (pts[i].z - l.z) ^ 2) > 0.7 or i == #pts or pts[i].crouch then out[#out + 1] = pts[i] end
    end
    local total = 0
    for i = 2, #out do total = total + math.sqrt((out[i].x - out[i - 1].x) ^ 2 + (out[i].z - out[i - 1].z) ^ 2) end
    out.snap = snap
    return out, total
end

-- Try the navmesh; true when a route was set up. If the goal is beyond the
-- loaded navmesh, aim for points part of the way there (partial route; at its
-- end the route plans again from there).
-- ---------------- windows and ladders ----------------
-- The navmesh has no links through windows or up ladders, so a goal on the
-- other side of one has no path. Each window/ladder is a "connector" with an
-- entry and exit point; a route is: walk to the entry, F, then plan again from
-- the exit. Up to two connectors are chained (e.g. window, then ladder down).
local CONN_RANGE = 45
local function connectors(near)
    local out = {}
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    if not gm then return out end
    local t_win, t_lad = sdk.typeof("chainsaw.GmWindow"), sdk.typeof("chainsaw.GmUprightLadder")
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            local tr = go:call("get_Transform")
            local gp = tr:call("get_Position")
            if dist2d(gp, near) > CONN_RANGE then return end
            local w = go:call("getComponent(System.Type)", t_win)
            if w and not w:get_field("_IsDummy") then
                -- Locked windows (seen 10/12: the barn's ground-floor windows) can't be used.
                if RE4Access.game.window_locked(w) then return end
                local P, ax = w:get_field("_Position"), w:get_field("_AxisZ")
                local fy = P.y - 1.0
                -- 0.6 m: close enough that F reaches the window.
                local c = { kind = "window", face = { x = P.x, y = fy, z = P.z }, ax = { x = ax.x, z = ax.z },
                    a = { x = P.x + ax.x * 0.6, y = fy, z = P.z + ax.z * 0.6 },
                    b = { x = P.x - ax.x * 0.6, y = fy, z = P.z - ax.z * 0.6 } }
                c.d = dist2d(c.face, near)
                out[#out + 1] = c
                return
            end
            local l = go:call("getComponent(System.Type)", t_lad)
            if l then
                local top
                local ch = tr:call("get_Child")
                while ch do
                    if ch:call("get_GameObject"):call("get_Name") == "TopPosObj" then top = ch:call("get_Position") end
                    ch = ch:call("get_Next")
                end
                if top then
                    -- Stand in FRONT of the ladder (10/14: house ladder in the Valley, F
                    -- pressed 30 times from beside it, nothing). The front is the side
                    -- of its AxisZ with floor and no wall right behind you.
                    local ax = tr:call("get_AxisZ")
                    local foot = { x = gp.x, y = gp.y, z = gp.z }
                    pcall(function()
                        local best
                        for _, sg in ipairs({ -1, 1 }) do
                            local sx, sz = gp.x + ax.x * 0.75 * sg, gp.z + ax.z * 0.75 * sg
                            local fl = R.cast(sx, gp.y + 0.5, sz, sx, gp.y - 1, sz)
                            local behind = R.cast(sx, gp.y + 1.2, sz, sx + ax.x * 0.8 * sg, gp.y + 1.2, sz + ax.z * 0.8 * sg)
                            if fl and math.abs(fl.y - gp.y) < 0.4 and not behind then best = { x = sx, y = gp.y, z = sz } break end
                        end
                        if best then foot = best end
                    end)
                    -- The game's own F boxes for the ladder (GimmickSensorUserData
                    -- boxes, one pair at the foot, one at the top): stand in the
                    -- one nearest the ladder (10/18 barn ladder: from beside the
                    -- hole no F at all; inside the top box F came at once).
                    local btop
                    pcall(function()
                        local cols = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
                        local bfoot
                        for ci = 0, cols:call("get_NumColliders") - 1 do
                            local box = cols:call("getColliders", ci):call("get_TransformedShape"):call("get_Box")
                            local m = box.coord[3]
                            local q = { x = m.x, y = m.y, z = m.z }
                            if math.abs(q.y - (top.y + 0.5)) < 0.8 then
                                if not btop or dist2d(q, top) < dist2d(btop, top) then btop = q end
                            elseif math.abs(q.y - (gp.y + 0.5)) < 0.8 then
                                if not bfoot or dist2d(q, gp) < dist2d(bfoot, gp) then bfoot = q end
                            end
                        end
                        if bfoot then foot = { x = bfoot.x, y = gp.y, z = bfoot.z } end
                    end)
                    local c = { kind = "ladder", face = { x = gp.x, y = gp.y, z = gp.z },
                        a = foot, b = btop and { x = btop.x, y = top.y, z = btop.z } or { x = top.x, y = top.y, z = top.z } }
                    c.d = dist2d(c.face, near)
                    out[#out + 1] = c
                end
            end
        end) end
    end
    table.sort(out, function(x, y) return x.d < y.d end)
    while #out > 10 do out[#out] = nil end
    return out
end
R.connectors = connectors

local function action_for(c, entry, exit)
    local text
    if c.kind == "window" then
        text = "Window. Press F to jump through it."
    else
        text = exit.y > entry.y and "Ladder. Hold F down for 1 second to climb up." or "Ladder. Hold F down for 1 second to climb down."
    end
    return { kind = c.kind, face = c.face, entry = entry, exit = exit, text = text }
end

-- Returns walking points to the first connector and its action, or nil.
local function plan_via(from, goal)
    -- The navmesh query snaps points to the nearest floor in 2D, so a point on
    -- the ground floor can "succeed" on the floor above: check the heights.
    local function reach(p, q)
        local ok, pts, total = pcall(R.nav_points, p, q)
        if not (ok and pts) then return nil end
        local last_mesh = pts[#pts - 1] or p
        local first_mesh = pts[2] or q
        if #pts >= 3 and (math.abs(last_mesh.y - q.y) > 1.5 or math.abs(first_mesh.y - p.y) > 1.5) then return nil end
        if #pts < 3 and math.abs(p.y - q.y) > 1.5 then return nil end
        return pts, total
    end
    -- Some floors have no navmesh loaded until Leon is there; a goal close to the
    -- exit on the same floor counts as reachable (the grid search does the rest).
    local function near_goal(q)
        return dist2d(q, goal) < 10 and math.abs(q.y - goal.y) < 1.5
    end
    local conns = connectors(from)
    local hops = {}
    for _, c in ipairs(conns) do
        for _, d in ipairs({ { c.a, c.b }, { c.b, c.a } }) do
            hops[#hops + 1] = { c = c, entry = d[1], exit = d[2] }
        end
    end
    local firsts = {}
    for _, h in ipairs(hops) do
        local pts, total = reach(from, h.entry)
        if pts then h.pts, h.total = pts, total firsts[#firsts + 1] = h end
    end
    -- Length of the rest of the way from a connector's exit to the goal, or nil.
    local rest = {}
    local function rest_len(h)
        if rest[h] == nil then
            local _, t = reach(h.exit, goal)
            rest[h] = t or (near_goal(h.exit) and dist2d(h.exit, goal)) or false
        end
        return rest[h] or nil
    end
    -- Pick the shortest plan (each window/ladder counts as 3 m extra).
    local best, best_len
    for _, h in ipairs(firsts) do
        local r = rest_len(h)
        if r and (not best_len or h.total + 3 + r < best_len) then best, best_len = h, h.total + 3 + r end
    end
    for _, h in ipairs(firsts) do
        for _, h2 in ipairs(hops) do
            if h2.c ~= h.c and (not best_len or h.total + 6 < best_len) then
                local r2 = rest_len(h2)
                if r2 then
                    local _, mid = reach(h.exit, h2.entry)
                    if mid and (not best_len or h.total + mid + r2 + 6 < best_len) then best, best_len = h, h.total + mid + r2 + 6 end
                end
            end
        end
    end
    if best then return best.pts, best.total, action_for(best.c, best.entry, best.exit) end
end
R.plan_via = plan_via

-- The navmesh itself links floors at some ladders and drops: two route points
-- in a row 1.5 m+ apart in height (10/12: barn ladder 6.9 -> 3.4). Walking can't
-- follow that, so the route stops at the top/bottom and asks for F, like the
-- window/ladder connectors. Returns the points up to the link and the action.
-- Way round a stuck mark: a navmesh path from Leon to a detour point (1.5 to 6 m from him)
-- and from there to the goal, neither crossing a stuck mark; the shortest wins.
function R.stuck_detour(from, goal)
    local best, bt
    for _, r in ipairs({ 1.5, 2.5, 3.5, 4.5, 6 }) do
        for k = 0, 15 do
            local a = k * math.pi / 8
            local cx, cz = from.x + math.cos(a) * r, from.z + math.sin(a) * r
            local okg, g = pcall(R.cast, cx, from.y + 1.5, cz, cx, from.y - 2.5, cz)
            if okg and g and not is_blocked_spot(cx, cz) then
                local c = { x = cx, y = g.y, z = cz }
                local ok1, p1, t1 = pcall(R.nav_points, from, c)
                if ok1 and p1 and #p1 > 0 and dist2d(p1[#p1], c) < 0.7 and not R.path_hits_stuck(p1) and not (bt and t1 >= bt) then
                    local ok2, p2, t2 = pcall(R.nav_points, c, goal)
                    if ok2 and p2 and #p2 > 0 and dist2d(p2[#p2], goal) < 1.5 and not R.path_hits_stuck(p2) and (not bt or t1 + t2 < bt) then
                        local _, l1 = R._split_at_link(p1)
                        local _, l2 = R._split_at_link(p2)
                        if not l1 and not l2 then
                            local all = {}
                            for _, q in ipairs(p1) do all[#all + 1] = q end
                            for i = 2, #p2 do all[#all + 1] = p2[i] end
                            best, bt = all, t1 + t2
                        end
                    end
                end
            end
        end
        if best then break end
    end
    if best then return best, bt end
    return nil, "none"
end

local function split_at_link(pts)
    -- Windows the path walks through (the navmesh links both sides; 10/12 the
    -- route walked into the barn's upstairs window and got "Blocked" forever).
    local windows, seen = {}, {}
    for _, q in ipairs({ pts[1], pts[#pts] }) do
        for _, c in ipairs(connectors(q)) do
            local k = string.format("%.1f,%.1f", c.face.x, c.face.z)
            if c.kind == "window" and not seen[k] then seen[k] = true windows[#windows + 1] = c end
        end
    end
    local function window_crossed(a, b)
        for _, w in ipairs(windows) do
            local sa = (a.x - w.face.x) * w.ax.x + (a.z - w.face.z) * w.ax.z
            local sb = (b.x - w.face.x) * w.ax.x + (b.z - w.face.z) * w.ax.z
            if sa * sb < 0 and math.abs(a.y - w.face.y) < 1.5 then
                local t = sa / (sa - sb)
                local cx, cz = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
                if math.sqrt((cx - w.face.x) ^ 2 + (cz - w.face.z) ^ 2) < 1.0 then
                    return w, sa > 0 and w.a or w.b, sa > 0 and w.b or w.a
                end
            end
        end
    end
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local w, entry, exit = window_crossed(a, b)
        if w then
            local head = {}
            for j = 1, i do head[j] = pts[j] end
            head[#head + 1] = { x = entry.x, y = entry.y, z = entry.z }
            return head, { kind = "window", face = w.face, entry = entry, exit = exit, text = "Window. Press F to jump through it." }
        end
        -- Stairs: the floor between the two points rises evenly (10/14 9PM: Chief's
        -- house stairs, 'Climb up here. Press F' halfway up, F did nothing).
        local function is_stairs()
            local hd = dist2d(a, b)
            if hd < 1.2 * math.abs(b.y - a.y) * 0.8 then return false end
            local ok, res = pcall(function()
                for k = 1, 7 do
                    local t = k / 8
                    local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
                    local want = a.y + (b.y - a.y) * t
                    local g = R.cast(x, want + 1.0, z, x, want - 1.5, z)
                    if not g or math.abs(g.y - want) > 0.6 then return false end
                end
                return true
            end)
            return ok and res
        end
        if math.abs(b.y - a.y) > 1.5 and not is_stairs() then
            local face, kind = { x = b.x, y = a.y, z = b.z }, "drop"
            for _, c in ipairs(connectors(a)) do
                if c.kind == "ladder" and dist2d(c.a, a) < 2 then face, kind = c.face, "ladder" break end
            end
            local text
            if kind == "ladder" then
                text = b.y > a.y and "Ladder. Hold F down for 1 second to climb up." or "Ladder. Hold F down for 1 second to climb down."
            elseif b.y > a.y then
                -- 10/19 quarry rubble: F alone did nothing; walking into it while tapping F climbed
                text = "Climb up here. Hold W into it and tap F."
            else
                -- 10/27 live (platform by the Ch6 wire gate): F alone did nothing;
                -- holding W toward the edge while tapping F jumped down at once.
                text = "Edge here. Hold W toward the edge and tap F to jump down."
            end
            -- 11/8 Ch8 storeroom: the "edge" was a window sill (gm91_508 窓越え,
            -- game prompt "Vault Over"); the user did not know what to do.
            if kind == "drop" then
                pcall(function()
                    for _, t in ipairs(RE4Access.game.scan_things(a, 2.5)) do
                        if t.name == "Window" then
                            text = "Window here. Hold W into it and tap F to climb through. You land inside, a little lower."
                            break
                        end
                    end
                end)
            end
            -- A railing in front of the drop spot (10/14: Valley lookout platform,
            -- "hold W, hops over" 8 times, nothing; the user had dropped 1.3 m
            -- further along): move the spot to an open gap in the edge nearby.
            -- Jump spots found by testing (10/14: Valley lookout platform; F at
            -- (56.38,204.87) facing 85 deg jumped down; the navmesh spot 0.8 m
            -- away did nothing). The game shows no prompt we can read here.
            local KNOWN_JUMPS = { { x = 56.38, y = -0.16, z = 204.87, heading = 85 } }
            local known
            if kind == "drop" then
                for _, j in ipairs(KNOWN_JUMPS) do
                    if dist2d(j, a) < 3.5 and math.abs(j.y - a.y) < 1 then known = j break end
                end
            end
            if known then
                a = { x = known.x, y = known.y, z = known.z }
                face = { x = known.x + math.sin(math.rad(known.heading)) * 3, y = known.y, z = known.z + math.cos(math.rad(known.heading)) * 3 }
                b = { x = face.x, y = b.y, z = face.z }
                text = "Jump spot. Stand still and press F to jump down."
            end
            if kind == "drop" and not known then
                pcall(function()
                    local dx, dz = b.x - a.x, b.z - a.z
                    local dl = math.sqrt(dx * dx + dz * dz)
                    if dl < 0.1 then return end
                    dx, dz = dx / dl, dz / dl
                    local function open(px, pz)
                        for _, h in ipairs({ 0.3, 0.9 }) do
                            if R.cast(px, a.y + h, pz, px + dx * 1.4, a.y + h, pz + dz * 1.4) then return false end
                        end
                        local g = R.cast(px + dx * 1.4, a.y + 0.5, pz + dz * 1.4, px + dx * 1.4, a.y - 8, pz + dz * 1.4)
                        return g and g.y < a.y - 1.2
                    end
                    if open(a.x, a.z) then return end
                    local best, bd
                    for ox = -2.5, 2.5, 0.25 do
                        for oz = -2.5, 2.5, 0.25 do
                            local px, pz = a.x + ox, a.z + oz
                            local d = math.sqrt(ox * ox + oz * oz)
                            if (not bd or d < bd) and d > 0.1 then
                                local fl = R.cast(px, a.y + 0.5, pz, px, a.y - 0.6, pz)
                                if fl and math.abs(fl.y - a.y) < 0.4 and not R.cast(a.x, a.y + 0.5, a.z, px, a.y + 0.5, pz) and open(px, pz) then
                                    best, bd = { x = px, y = a.y, z = pz }, d
                                end
                            end
                        end
                    end
                    if best then
                        log.info(string.format("[RE4Access] drop spot moved %.1f m to an open edge (%.2f,%.2f)", bd, best.x, best.z))
                        a = best
                        b = { x = best.x + dx * 2, y = b.y, z = best.z + dz * 2 }
                        face = { x = b.x, y = a.y, z = b.z }
                    end
                end)
            end
            local head = {}
            for j = 1, i do head[j] = pts[j] end
            if #head == 1 then head[2] = { x = a.x, y = a.y, z = a.z } end
            if head[#head] ~= a then head[#head + 1] = { x = a.x, y = a.y, z = a.z } end
            return head, { kind = kind, face = face, entry = a, exit = b, text = text }
        end
    end
    return pts, nil
end

R.split_at_link = split_at_link

-- An unlocked door near the goal, and a spot outside it you can walk to:
-- the shortest walk wins. Returns spot, walking distance.
function R.other_door_spot(from, goal)
    local best, bt
    local okd, doors = pcall(RE4Access.game.door_positions, goal, 30)
    if not okd then return nil end
    for _, d in ipairs(doors) do
        -- only doors into the same place: close to the goal (10/14: the Chief's
        -- main gate, 28 m away, scored better than the back door by walking)
        if math.abs(d.y - from.y) < 3 and dist2d(d, from) > 2 and dist2d(d, goal) < 15 then
            for ang = 0, 315, 45 do
                local sx, sz = d.x + math.sin(math.rad(ang)) * 1.3, d.z + math.cos(math.rad(ang)) * 1.3
                local okg, g = pcall(R.cast, sx, d.y + 1.5, sz, sx, d.y - 2, sz)
                -- 10/15: the ground ray gives nothing while the game is paused (the
                -- 10/14 test found "none"); then trust the navmesh check below.
                if not (okg and g) then g = { y = d.y } end
                if math.abs(g.y - d.y) < 0.8 then
                    local okn, pts, tot = pcall(R.nav_points, from, { x = sx, y = g.y, z = sz })
                    if okn and pts and dist2d(pts[#pts], { x = sx, z = sz }) < 0.7 then
                        local score = tot + 3 * dist2d(d, goal)
                        if not bt or score < bt then best, bt = { x = sx, y = g.y, z = sz, walk = tot, door = { x = d.x, y = d.y, z = d.z } }, score end
                    end
                end
            end
        end
    end
    if best then
        log.info(string.format("[RE4Access] other door spot (%.1f,%.1f,%.1f) walk %.1f", best.x, best.y, best.z, best.walk))
        return best, best.walk
    end
    log.info("[RE4Access] other door: none of " .. #doors .. " doors reachable")
end

-- Where Leon stands to take an item (10/17: Pesetas and the Crystal Marble in the
-- Chief's closet, ammo on a desk, herbs on shelves). The walking map is the
-- floor; an item on a table or in a cupboard is 0.5-2 m above it, so a path
-- query to the item itself fails and the mod said "behind a locked door" or
-- "very close, walk yourself". Ask for the floor under and around the item
-- instead; the shortest walk that ends within arm's reach wins.
function R.reach_spot(from, item, reach, max_up)
    local best, bt, level, lt
    for _, r in ipairs({ 0, 0.6, 1.0, 1.4 }) do
        for k = 0, (r == 0 and 0 or 7) do
            local a = k * math.pi / 4
            local x, z = item.x + math.sin(a) * r, item.z + math.cos(a) * r
            for _, h in ipairs({ 0, 0.5, 1.0, 1.5, 2.0 }) do
                local okn, pts, tot = pcall(R.nav_points, from, { x = x, y = item.y - h, z = z })
                local e = okn and pts and (pts.snap or pts[#pts])
                -- 11/14: the Lion Head sits on the west face of a lion statue (gm84_643); the
                -- nearest floor was behind the statue (east), F never came. The spot must
                -- also see the item: no wall/statue on the line from chest height to it.
                local seen = true
                if e and e.y then
                    local G = RE4Access.game
                    if G and G.wall_before then
                        local okw, wb = pcall(G.wall_before, { x = e.x, y = e.y + 1.2, z = e.z }, { x = item.x, y = item.y + 0.15, z = item.z })
                        if okw and wb then seen = false end
                    end
                end
                if e and e.y and seen and dist2d(e, item) < (reach or 1.3) and item.y - e.y > -0.4 and item.y - e.y < (max_up or 2.2) then
                    if not bt or tot < bt then best, bt = { x = e.x, y = e.y, z = e.z, walk = tot }, tot end
                    -- 11/1: a herb on the upper floor, 2 m over Leon on the stairs: the
                    -- spot under it won as the shorter walk. A floor level with the
                    -- item wins over any floor below it, however long the walk.
                    if item.y - e.y < 0.7 and (not lt or tot < lt) then level, lt = { x = e.x, y = e.y, z = e.z, walk = tot }, tot end
                    break
                end
            end
        end
        if level then best = level break end
        if best then break end
    end
    if best then log.info(string.format("[RE4Access] reach spot (%.2f,%.2f,%.2f) walk %.1f", best.x, best.y, best.z, best.walk)) end
    return best
end

-- The cupboard, drawer or closet an item lies in (GmLocker within 1.3 m), and its
-- dial lock if one is still unsolved (a ring not on its right picture).
function R.cabinet_of(item)
    -- (a wide closet: its Pesetas lay 1.8 m from its middle, so a dial-locked one
    -- counts within 2 m)
    local best, bd
    pcall(function()
        for _, t in ipairs(RE4Access.game.scan_things(item, 3)) do
            local lk = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmLocker"))
            local d = lk and math.sqrt((t.pos.x - item.x) ^ 2 + (t.pos.z - item.z) ^ 2)
            if d and math.abs(t.pos.y - item.y) < 2.2 then
                local dial
                -- an opened locker is done for the map; its dial no longer matters (10/18)
                local okd, done = pcall(function() return lk:call("get_Context"):call("hasDoneForMap") end)
                if not (okd and done) then pcall(function()
                    for _, dl in ipairs(lk:get_field("_DialLocks"):get_elements()) do
                        for _, b in ipairs(dl:get_field("_Blocks"):get_elements()) do
                            if b:get_field("_Index") ~= b:get_field("_Correct") then dial = dl end
                        end
                    end
                end) end
                if d < (dial and 2.0 or 1.3) and (not bd or d < bd) then best, bd = { go = t.go, pos = t.pos, locker = lk, dial = dial }, d end
            end
        end
    end)
    return best
end

-- A locked door that really cuts Leon off from the goal: one side of it is on
-- Leon's walking map, the other side reaches the goal (10/17: the Chief's
-- bedroom behind the crystal-ball door; the old straight-line test missed it).
function R.blocking_door(from, goal)
    local G = RE4Access.game
    for _, d in ipairs(G.scan_things(from, 30)) do
        if (d.name == "Door" or d.name == "Gate") and (G.door_locked(d.go) or G.gate_asleep(d.go)) and not G.door_is_open(d.go) then
            local c = G.door_center_of(d)
            local near, far = false, false
            for ang = 0, 315, 45 do
                local s = { x = c.x + math.sin(math.rad(ang)) * 1.1, y = c.y, z = c.z + math.cos(math.rad(ang)) * 1.1 }
                local ok1, p1 = pcall(R.nav_points, from, s)
                if ok1 and p1 and dist2d(p1[#p1 - 1] or p1[1], s) < 0.6 then near = true
                else
                    for _, h in ipairs({ 0, 0.7, 1.4 }) do
                        local ok2, p2 = pcall(R.nav_points, s, { x = goal.x, y = goal.y - h, z = goal.z })
                        if ok2 and p2 and p2.snap and dist2d(p2.snap, goal) < 2.2 then far = true break end
                    end
                end
            end
            if near and far then
                log.info(string.format("[RE4Access] blocking door (%.1f,%.1f,%.1f)", c.x, c.y, c.z))
                return d, c
            end
        end
    end
end

-- What opens a door, by the game's (Japanese) object name.
function R.door_opener_text(d)
    local G = RE4Access.game
    local gn = ""
    pcall(function() gn = d.go:call("get_Name") end)
    if gn:find("水晶パズル", 1, true) then
        local t = "It opens with the crystal ball puzzle next to it. The ball needs the Crystal Marble"
        local found = false
        pcall(function()
            for _, it in ipairs(G.items(d.pos, 30)) do
                if it.name:find("Crystal Marble", 1, true) then
                    local cab = R.cabinet_of(it.pos)
                    t = t .. ", which is " .. (cab and cab.dial and "in a cabinet with a dial lock, " or "")
                        .. G.describe_position(it.pos, G.player_pos(), G.facing()) .. ". Pick Crystal Marble in Items and press Backslash"
                    found = true
                    return
                end
            end
        end)
        if not found or G.has_item(119217600) then t = "It opens with the crystal ball puzzle next to it. You have the Crystal Marble: go to the crystal ball (Puzzles category), press F and choose the marble" end
        return t .. "."
    end
    local okk, kt = pcall(G.door_key_text, d.go, G.player_pos())
    return okk and kt or nil
end

-- Drops the game would not let Leon take (learned while playing).
R.bad_drops = R.bad_drops or {
    { x = -13.19, y = 1.52, z = 160.33 },   -- Ch2 factory back stairs, Sapphire chest
}
function R.is_bad_drop(q)
    for _, b in ipairs(R.bad_drops) do
        if dist2d(b, q) < 1.5 and math.abs(b.y - q.y) < 1.2 then return true end
    end
    return false
end

-- Navmesh paths ignore traps. Bear traps: route points closer than 1.4 m are
-- pushed away and a detour point is added where a stretch passes one.
-- Tripwire lasers crossing the route are remembered so follow() warns early.
local function seg_closest(a, b, c)
    local dx, dz = b.x - a.x, b.z - a.z
    local l2 = dx * dx + dz * dz
    local t = l2 > 0 and math.max(0, math.min(1, ((c.x - a.x) * dx + (c.z - a.z) * dz) / l2)) or 0
    return { x = a.x + dx * t, y = a.y + (b.y - a.y) * t, z = a.z + dz * t }, t
end
local function avoid_traps(pts)
    local G = RE4Access.game
    local okt, traps = pcall(G.trap_positions, pts[1])
    if not okt then traps = {} end
    -- A side point is usable when there is ground at about the same height and no
    -- wall between it and where we come from.
    local function usable(from, q)
        local okg, hit = pcall(R.cast, q.x, from.y + 1.5, q.z, q.x, from.y - 2, q.z)
        if not (okg and hit) or math.abs(hit.y - from.y) > 0.7 then return false end
        q.y = hit.y
        local okw, wall = pcall(wall_between, from.x, from.y, from.z, q.x, q.y, q.z)
        return okw and not wall
    end
    -- Go around each bear trap with two points 1.7 m to the side, before and after
    -- it, on whichever side has floor (10/12: one 1.5 m point wasn't enough, the
    -- straight legs to it still crossed two traps).
    local CLEAR = 1.7
    local out = { pts[1] }
    -- Starting right next to a trap (10/12: route began 1 m from one and the first
    -- leg went past it; detours only looked at the middle of a leg): step away first.
    for _, tp in ipairs(traps) do
        local d = dist2d(pts[1], tp)
        if d < CLEAR then
            local ox, oz = pts[1].x - tp.x, pts[1].z - tp.z
            local ol = math.max(0.05, math.sqrt(ox * ox + oz * oz))
            local q = { x = tp.x + ox / ol * CLEAR, y = pts[1].y, z = tp.z + oz / ol * CLEAR, trap = true, away = true }
            if usable(pts[1], q) then out[#out + 1] = q end
            out[1].trap = true
        end
    end
    for i = 2, #pts do
        local b = pts[i]
        -- a route point sitting on a trap is moved off it first
        for _, tp in ipairs(traps) do
            local d = dist2d(b, tp)
            if d < CLEAR and i < #pts then
                local ox, oz = b.x - tp.x, b.z - tp.z
                local ol = math.max(0.05, math.sqrt(ox * ox + oz * oz))
                b = { x = tp.x + ox / ol * CLEAR, y = b.y, z = tp.z + oz / ol * CLEAR, crouch = b.crouch }
            end
        end
        local a = out[#out]
        for _, tp in ipairs(traps) do
            local c, t = seg_closest(a, b, tp)
            if dist2d(c, tp) < CLEAR and t > 0 and t < 1 then
                local dx, dz = b.x - a.x, b.z - a.z
                local dl = math.max(0.05, math.sqrt(dx * dx + dz * dz))
                dx, dz = dx / dl, dz / dl
                local sx, sz = -dz, dx
                if (c.x - tp.x) * sx + (c.z - tp.z) * sz < 0 then sx, sz = -sx, -sz end
                for _, side in ipairs({ 1, -1 }) do
                    local p1 = { x = tp.x - dx * CLEAR + sx * side * CLEAR, y = c.y, z = tp.z - dz * CLEAR + sz * side * CLEAR, trap = true }
                    local p2 = { x = tp.x + dx * CLEAR + sx * side * CLEAR, y = c.y, z = tp.z + dz * CLEAR + sz * side * CLEAR, trap = true }
                    if usable(a, p1) and usable(p1, p2) then
                        out[#out + 1] = p1
                        out[#out + 1] = p2
                        a = p2
                        break
                    end
                end
            end
        end
        out[#out + 1] = b
    end
    -- Detours can leave original points behind the detour, so the path doubled
    -- back and forth (10/12 log: (200,-117) (201,-115) (200,-115) (203,-114)...).
    -- Drop any point where the path turns back more than 120 degrees.
    local changed = true
    while changed and #out > 2 do
        changed = false
        for i = 2, #out - 1 do
            local a, b, c = out[i - 1], out[i], out[i + 1]
            local ux, uz, vx, vz = b.x - a.x, b.z - a.z, c.x - b.x, c.z - b.z
            local lu, lv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
            if not b.away and (lu < 0.3 or (lv > 0.01 and (ux * vx + uz * vz) / (lu * lv) < -0.5)) then
                table.remove(out, i)
                changed = true
                break
            end
        end
    end
    -- Where the path still runs within 2 m of a trap (narrow lanes with no room for a
    -- detour, 1.2-1.6 m measured in the village), steer tightly so Leon doesn't drift.
    for i = 2, #out do
        for _, tp in ipairs(traps) do
            local c = seg_closest(out[i - 1], out[i], tp)
            if dist2d(c, tp) < 2 then out[i - 1].trap, out[i].trap = true, true end
        end
    end
    local lasers = {}
    pcall(function()
        for _, bm in ipairs(G.laser_bombs(pts[1], 120)) do
            for i = 2, #out do
                local p1, p2 = out[i - 1], out[i]
                -- 2D segment intersection with the laser line
                local function cross(o, a2, b2) return (a2.x - o.x) * (b2.z - o.z) - (a2.z - o.z) * (b2.x - o.x) end
                local d1, d2 = cross(bm.a, bm.b, p1), cross(bm.a, bm.b, p2)
                local d3, d4 = cross(p1, p2, bm.a), cross(p1, p2, bm.b)
                if d1 * d2 < 0 and d3 * d4 < 0 and math.abs(p1.y - bm.a.y) < 2.5 then
                    lasers[#lasers + 1] = { idx = i, bomb = bm }
                    break
                end
            end
        end
    end)
    return out, lasers
end
R.avoid_traps = avoid_traps

function nav_route(from, goal, name, quiet)
    -- Standing at the top (or foot) of a ladder and the goal is on the other
    -- level: use the ladder. 10/14: the Valley entrance lookout platform (Continue
    -- point) - the navmesh offered a drop off the railing 7 m away, "Blocked" 6x.
    local okl, lad = pcall(function()
        for _, c in ipairs(connectors(from)) do
            if c.kind == "ladder" then
                if dist2d(c.b, from) < 1.8 and math.abs(c.b.y - from.y) < 1 and goal.y < from.y - 1.5 then return { c = c, entry = c.b, exit = c.a } end
                if dist2d(c.a, from) < 1.8 and math.abs(c.a.y - from.y) < 1 and goal.y > from.y + 1.5 then return { c = c, entry = c.a, exit = c.b } end
            end
        end
    end)
    -- ...but only when the other end really leads on (10/14: at the ladder foot
    -- the way to the emblem went back up and off the platform's far end).
    if okl and lad then
        local okn, np = pcall(R.nav_points, lad.exit, goal)
        local back = false
        if okn and np then
            local _, lk = split_at_link(np)
            if lk and lk.kind == "ladder" and dist2d(lk.entry, lad.exit) < 2 then back = true end
        end
        if not (okn and np) or back then lad = nil end
    end
    if okl and lad then
        route = { points = { { x = from.x, y = from.y, z = from.z }, { x = lad.entry.x, y = from.y, z = lad.entry.z } }, goal = goal, name = name, idx = 1,
            action = action_for(lad.c, lad.entry, lad.exit) }
        R.last_route = route.points
        log.info("[RE4Access] nav route: ladder right here")
        RE4Access.game.face_point(lad.c.face, true)
        local near = dist2d(from, lad.entry) < 0.4
        say((lad.exit.y < from.y and "Ladder down right here. " or "Ladder up right here. ") .. (near and "Hold F down for 1 second." or "Hold W a step to its spot, then hold F down for 1 second."), not quiet)
        return true
    end
    local ok, pts, total = pcall(R.nav_points, from, goal)
    if not ok then log.info("[RE4Access] nav error: " .. tostring(pts)) return false end
    -- 10/14: at the foot of the Valley entrance ladder the query snapped Leon to
    -- the ledge above and failed; 0.8 m away it found the 66 m walk. Try a few
    -- start points around Leon before giving up.
    if not pts then
        for a = 0, 315, 45 do
            local sx, sz = from.x + math.sin(math.rad(a)) * 0.8, from.z + math.cos(math.rad(a)) * 0.8
            local okc, hit = pcall(R.cast, from.x, from.y + 0.5, from.z, sx, from.y + 0.5, sz)
            if okc and not hit then
                local ok3, p3, t3 = pcall(R.nav_points, { x = sx, y = from.y, z = sz }, goal)
                if ok3 and p3 then
                    table.insert(p3, 1, { x = from.x, y = from.y, z = from.z })
                    pts, total = p3, t3 + 0.8
                    log.info("[RE4Access] nav start nudged 0.8 m at " .. a)
                    break
                end
            end
        end
    end
    -- The navmesh runs through gates the story keeps shut (10/14: factory iron
    -- bars): such a path is no path.
    if pts then
        pcall(function()
            for _, gp in ipairs(RE4Access.game.asleep_gate_positions(from, 60)) do
                for i, q in ipairs(pts) do
                    -- not the first points (you may be standing next to it)
                    if i > 2 and (q.x - gp.x) ^ 2 + (q.z - gp.z) ^ 2 < 1.0 and math.abs(q.y - gp.y) < 2 then
                        log.info("[RE4Access] nav path crosses a shut gate, dropped")
                        pts = nil
                        return
                    end
                end
            end
        end)
    end
    local partial = false
    -- A goal close by on the same floor: no window/ladder needed, the grid
    -- search finds the way (there the navmesh may simply not be loaded yet).
    local same_floor_near = math.abs(goal.y - from.y) < 1.5 and dist2d(goal, from) < 15
    if not pts and not same_floor_near then
        local okv, vpts, vtotal, action = pcall(plan_via, from, goal)
        if not okv then log.info("[RE4Access] plan_via error: " .. tostring(vpts)) end
        if okv and vpts then
            local head, link = split_at_link(vpts)
            if link then vpts, action = head, link end
            route = { points = vpts, goal = goal, name = name, idx = 1, action = action }
            R.last_route = vpts
            log.info(string.format("[RE4Access] nav route via %s: %.1f m", action.kind, vtotal))
            local what = action.kind == "window" and "a window" or action.kind == "drop" and "a drop" or "a ladder"
            say(string.format("Route found, %d meters to %s on the way. Hold W.", math.floor(vtotal + 0.5), what), not quiet)
            RE4Access.game.face_point(vpts[math.min(#vpts, 2)], true)
            return true
        end
    end
    if not pts then
        for _, f in ipairs({ 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2 }) do
            local mid = { x = from.x + (goal.x - from.x) * f, y = from.y + (goal.y - from.y) * f, z = from.z + (goal.z - from.z) * f }
            local ok2, p2, t2 = pcall(R.nav_points, from, mid)
            if ok2 and p2 and t2 > 4 then pts, total, partial = p2, t2, true break end
        end
    end
    if not pts then return false end
    local head, link = split_at_link(pts)
    -- A "drop" whose top is above Leon is a navmesh oddity (10/27 by the wire
    -- gate: Leon 3.6 m, path up onto a crate edge and down; "Edge here" never
    -- reachable, the route looped). Walk the plain points instead.
    if link and link.kind == "drop" and link.entry.y > from.y + 0.8 then
        log.info(string.format("[RE4Access] drop above Leon (%.1f > %.1f) ignored, plain walk", link.entry.y, from.y))
        head, link = pts, nil
    end
    if link and link.kind == "drop" and R.is_bad_drop(link.entry) then
        -- Walk to a spot next to the goal without that drop instead.
        local best, bt
        for _, r in ipairs({ 0.9, 1.3, 1.8, 2.4 }) do
            for ang = 0, 330, 30 do
                local gx, gz = goal.x + math.sin(math.rad(ang)) * r, goal.z + math.cos(math.rad(ang)) * r
                local okg, g = pcall(R.cast, gx, goal.y + 1.5, gz, gx, goal.y - 3, gz)
                if okg and g then
                    local okn, ap, at = pcall(R.nav_points, from, { x = gx, y = g.y, z = gz })
                    if okn and ap and (not bt or at < bt) then
                        local _, lk = split_at_link(ap)
                        local last = ap[#ap]
                        if not lk and dist2d(last, { x = gx, z = gz }) < 0.6 and math.abs(last.y - g.y) < 1 then best, bt = ap, at end
                    end
                end
            end
            if best then break end
        end
        if best then
            log.info(string.format("[RE4Access] bad drop avoided, walking round: %.1f m", bt))
            pts, total, head, link = best, bt, best, nil
        end
    end
    if link then
        local lasers
        head, lasers = avoid_traps(head)
        do local okf, fp = pcall(R.fix_corners, head) if okf and fp then head = fp end end
        route = { points = head, goal = goal, name = name, idx = 1, action = link, lasers = lasers }
        R.last_route = head
        local len = 0
        for i = 2, #head do len = len + dist2d(head[i], head[i - 1]) end
        log.info(string.format("[RE4Access] nav route: %.1f m to a %s link", len, link.kind))
        local what = link.kind == "ladder" and "a ladder" or link.kind == "window" and "a window" or "a drop"
        say(string.format("Route found, %d meters to %s on the way. Hold W.", math.floor(len + 0.5), what), not quiet)
        RE4Access.game.face_point(head[math.min(#head, 2)], true)
        return true
    end
    local lasers
    pts, lasers = avoid_traps(pts)
    if #lasers > 0 and not R.laser_fallback then
        -- A tripwire laser across the navmesh path: block the laser for the grid
        -- search and look for a way around it (10/12: died twice walking into the
        -- fishing village bomb). If there is none, the nav route is used with a
        -- warning to shoot the bomb first.
        -- First choice (10/12 PM, boathouse back hallway): the bomb blocks the only
        -- way, so walk to a spot 4-6 m from it with a clear shot and stop there.
        if not tostring(name):find("tripwire", 1, true) then
            local okb, spot = pcall(RE4Access.game.bomb_shoot_spot, lasers[1].bomb, from)
            if okb and spot then
                if dist2d(spot, from) < 1.5 then
                    say("A tripwire bomb blocks the way. Shoot it from here: hold L, press K when I say fire.", true)
                    return true
                end
                say("A tripwire bomb blocks the way. Walking you to a spot to shoot it. Hold W.", true)
                RE4Access.speak_hold = true
                local okr = nav_route(from, { x = spot.x, y = spot.y, z = spot.z }, "spot to shoot the tripwire bomb", false)
                RE4Access.speak_hold = nil
                if okr then return true end
            end
        end
        for _, lz in ipairs(lasers) do
            local a, b = lz.bomb.a, lz.bomb.b
            local len = dist2d(a, b)
            local n = math.max(2, math.ceil((len + 0.8) / 0.4))
            for k = 0, n do
                local t = -0.4 / math.max(len, 0.1) + k / n * (1 + 0.8 / math.max(len, 0.1))
                R.blocked_world[#R.blocked_world + 1] = { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t }
            end
        end
        R.pending_laser_route = { points = pts, goal = goal, name = name, idx = 1, partial = partial, lasers = lasers }
        start_search(from, goal, name)
        search.laser_avoid = true
        search.quiet = quiet
        say("Tripwire bomb on the way. Finding a way around it.", not quiet)
        return true
    end
    -- 11/14 (Ashley, west-facing door gm80_508(2)): the navmesh path zigzags through
    -- narrow doorways - (116.1,89.3) (115.1,89.1) (116.0,88.5) (114.7,88.9) - and the
    -- route steered at each zig, walking her into the open door panel ("Blocked" x6).
    -- Facing straight through the door worked at once. Drop a point when both its legs
    -- are short (< 1.6 m), it turns sharply (> 60 degrees), and the straight line past
    -- it is clear of walls.
    if R.path_hits_stuck(pts) then
        local okd, det, dt = pcall(R.stuck_detour, from, goal)
        if okd and det then
            log.info(string.format("[RE4Access] stuck mark on the path: detour %.1f m (was %.1f m)", dt, total))
            pts, total = det, dt
        else
            log.info("[RE4Access] stuck mark on the path, no detour found: " .. tostring(det))
        end
    end
    pts = R.dezigzag(pts)
    do local okf, fp = pcall(R.fix_corners, pts) if okf and fp then pts = fp end end
    route = { points = pts, goal = goal, name = name, idx = 1, partial = partial, lasers = lasers }
    R.last_route = pts
    log.info(string.format("[RE4Access] nav route: %.1f m, %d points, %d lasers, to %s", total, #pts, #lasers, tostring(name)))
    pcall(function()
        local t = {}
        for i = 1, #pts, math.max(1, math.floor(#pts / 12)) do t[#t + 1] = string.format("(%.0f,%.0f)", pts[i].x, pts[i].z) end
        log.info("[RE4Access] route path: " .. table.concat(t, " "))
    end)
    if not quiet then
        if partial then
            say(string.format("Part of the way known, %d meters toward %s. Hold W.", math.floor(total + 0.5), name))
        else
            local s = string.format("Route found, %d meters.", math.floor(total + 0.5))
            -- Goal inside a building: "18 meters to a door, then 7 meters inside" (10/13).
            pcall(function()
                R.route_doors()
                local fd
                -- (10/17: "0 meters to a door" = a door Leon stands next to and walks away from)
                local d
                for _, mk in ipairs(route.marks) do
                    if mk.kind == "door" then
                        d = 0
                        for i = 2, mk.idx do d = d + dist2d(pts[i], pts[i - 1]) end
                        if d >= 1.5 then fd = mk break end
                    end
                end
                if fd then
                    s = s .. string.format(" %d meters to a %s, then %d meters to %s.", math.floor(d + 0.5), fd.name,
                        math.floor(math.max(0, total - d) + 0.5), name)
                end
            end)
            say(s .. " Hold W.")
        end
    end
    RE4Access.game.face_point(pts[math.min(#pts, 2)], true)
    return true
end

-- Items on tables or shelves: walk to a floor spot right next to them instead
-- of into the table, and away from ladders, so F picks the item up instead of
-- climbing (10/12: the Wooden Cog lies on a table beside the barn ladder; F
-- took Leon up the ladder). Returns nil for items lying on the floor.
local function stand_spot(item)
    local cands, lowest = {}, nil
    for _, r in ipairs({ 0.8, 1.1 }) do
        for k = 0, 11 do
            local a = k * math.pi / 6
            local x, z = item.x + math.sin(a) * r, item.z + math.cos(a) * r
            local hit = R.cast(x, item.y + 0.8, z, x, item.y - 2.5, z)
            -- a wall between the spot and the item: not a place to pick it up from
            if hit then
                local eye_y = hit.y + 1.2
                local wall, wd = R.cast(x, eye_y, z, item.x, item.y + 0.1, item.z)
                local full = math.sqrt((item.x - x) ^ 2 + (item.y + 0.1 - eye_y) ^ 2 + (item.z - z) ^ 2)
                if wall and wd and wd < full - 0.3 then hit = nil end
            end
            if hit then
                cands[#cands + 1] = { x = x, y = hit.y, z = z, r = r }
                if not lowest or hit.y < lowest then lowest = hit.y end
            end
        end
    end
    if not lowest or item.y - lowest < 0.5 then return nil end
    local ladders = {}
    for _, c in ipairs(connectors(item)) do
        if c.kind == "ladder" then ladders[#ladders + 1] = c.a end
    end
    local best, best_score
    for _, c in ipairs(cands) do
        if c.y - lowest < 0.15 then
            local ld = 3
            for _, l in ipairs(ladders) do ld = math.min(ld, dist2d(c, l)) end
            local score = ld - c.r
            if not best_score or score > best_score then best, best_score = c, score end
        end
    end
    return best
end
R.stand_spot = stand_spot

-- Where to stand to break a crate or barrel the item is inside (10/13: herb in a
-- large factory crate; routes to the item's centre ended inside the solid crate,
-- went round through a door and said "behind a wall" while Leon stood next to it).
-- A floor spot 1.1-2.0 m from the item whose view of it is blocked only by the
-- crate itself; the one closest to Leon.
local function crate_spot(item, from)
    local best, best_d
    for _, r in ipairs({ 1.1, 1.4, 1.7, 2.0 }) do
        for k = 0, 15 do
            local a = k * math.pi / 8
            local x, z = item.x + math.sin(a) * r, item.z + math.cos(a) * r
            local hit = R.cast(x, item.y + 1.5, z, x, item.y - 2.5, z)
            if hit and hit.y < item.y - 0.3 and hit.y > item.y - 2.0 then
                local eye_y = hit.y + 1.2
                local wall = R.cast(x, eye_y, z, item.x, item.y + 0.1, item.z)
                if wall and dist2d(wall, item) > 0.9 then hit = nil end
            else
                hit = nil
            end
            if hit then
                local d = dist2d({ x = x, z = z }, from) + math.abs(hit.y - from.y) * 3
                if not best_d or d < best_d then best, best_d = { x = x, y = hit.y, z = z }, d end
            end
        end
        if best then return best end
    end
end
R.crate_spot = crate_spot

-- Things packed close together (10/13: rifle ammo, typewriter and a document
-- within a meter; F always went to the typewriter): a spot 0.7-1.1 m from the
-- target, with a clear view of it, as far as possible from the other things.
local function clear_spot(target, from, others)
    local cands = {}
    for _, r in ipairs({ 0.7, 0.9, 1.1 }) do
        for k = 0, 15 do
            local a = k * math.pi / 8
            local x, z = target.x + math.sin(a) * r, target.z + math.cos(a) * r
            local hit = R.cast(x, target.y + 1.0, z, x, target.y - 2.5, z)
            if not hit then
                -- 10/13: rays find nothing in the factory typewriter room; the
                -- walking map (navmesh) still knows where Leon can stand.
                local okn, np = pcall(R.nav_points, from, { x = x, y = from.y, z = z })
                local last = okn and np and np[#np]
                if last and math.sqrt((last.x - x) ^ 2 + (last.z - z) ^ 2) < 0.25 then hit = { y = last.y or from.y, nav = true } end
            end
            if hit and hit.y < target.y + 0.3 and hit.y > target.y - 1.9 then
                local eye = hit.y + 1.2
                local wall, wd
                if not hit.nav then wall, wd = R.cast(x, eye, z, target.x, target.y + 0.1, target.z) end
                local full = math.sqrt((target.x - x) ^ 2 + (target.y + 0.1 - eye) ^ 2 + (target.z - z) ^ 2)
                if not wall or (wd and wd > full - 0.35) then
                    local near = 9
                    for _, o in ipairs(others) do near = math.min(near, math.sqrt((o.x - x) ^ 2 + (o.z - z) ^ 2)) end
                    local s = near - r * 0.5 - math.sqrt((x - from.x) ^ 2 + (z - from.z) ^ 2) * 0.05
                    cands[#cands + 1] = { x = x, y = hit.y, z = z, near = near, s = s }
                end
            end
        end
    end
    -- Only a spot Leon can walk to (10/15: the Red Herb spot was over the stairwell,
    -- behind the railing; Leon walked into the railing). Best first.
    table.sort(cands, function(p1, p2) return p1.s > p2.s end)
    for _, c in ipairs(cands) do
        local okn, np, tot = pcall(R.nav_points, from, { x = c.x, y = c.y, z = c.z })
        local last = okn and np and np[#np]
        local straight = math.sqrt((c.x - from.x) ^ 2 + (c.z - from.z) ^ 2)
        if last and math.sqrt((last.x - c.x) ^ 2 + (last.z - c.z) ^ 2) < 0.35 and math.abs((last.y or c.y) - c.y) < 1.0
            and (not tot or tot < straight * 2 + 4) then
            log.info(string.format("[RE4Access] clear spot (%.2f,%.2f) near %.2f, walk %.1f", c.x, c.z, c.near, tot or -1))
            return c
        end
    end
    log.info("[RE4Access] clear spot: none of " .. #cands .. " reachable")
    return nil
end
R.clear_spot = clear_spot

R._split_at_link = split_at_link

-- 11/26 Ch10 cave: there is no walking map (navmesh) down there, so N gave "No
-- walking route found", and the straight lines it then suggested ran into rock.
-- A route along a fixed list of points (taken from Claude's own walk through the
-- cave), steered like any other route. Starts at the farthest point ahead that
-- Leon can see.
function R.go_points(pts, name, face, after, quiet)
    R.door_wait = nil
    R.going_on, R.pending_target, R.pending_door = nil, nil, nil
    R.story = true
    local pos = RE4Access.game.player_pos()
    if not pos or not pts or #pts == 0 then return false end
    local bi, bd
    for i, q in ipairs(pts) do
        local d = dist2d(q, pos)
        if math.abs(q.y - pos.y) < 1.5 and d < 12 and (not bd or d < bd)
            and not wall_between(pos.x, pos.y, pos.z, q.x, q.y, q.z) then bi, bd = i, d end
    end
    if not bi then return false end
    while bi < #pts do
        local q = pts[bi + 1]
        if dist2d(q, pos) < 5 and not wall_between(pos.x, pos.y, pos.z, q.x, q.y, q.z) then bi = bi + 1 else break end
    end
    local out = { { x = pos.x, y = pos.y, z = pos.z } }
    for i = bi, #pts do out[#out + 1] = pts[i] end
    route = { points = out, goal = pts[#pts], name = name, idx = 1, face_target = face, after_text = after,
        fixed = { pts = pts, name = name, face = face, after = after } }
    R.last_route = out
    local total = 0
    for i = 2, #out do total = total + dist2d(out[i], out[i - 1]) end
    log.info(string.format("[RE4Access] fixed route: %.1f m, %d points, from point %d, to %s", total, #out, bi, tostring(name)))
    if not quiet then say(string.format("Route %d. Hold W.", math.max(1, math.floor(total + 0.5)))) end
    RE4Access.game.face_point(out[math.min(#out, 2)], true)
    return true
end

function R.go(target)
    R.door_wait = nil   -- a new route replaces waiting at the other door
    -- 10/15 7:53PM: a save loaded halfway to the other door left pending_target
    -- set for good, so the other door was never offered again ("locked door, 14
    -- meters" only). Every new route starts clean; only the going-on from the
    -- other door itself skips the other-door search (no loop).
    local going_on = R.going_on
    R.going_on, R.pending_target, R.pending_door = nil, nil, nil
    -- 0.25.3: a route started by N (or follow mode) is a story route; going on
    -- from the other door keeps what the first route was.
    if not going_on then R.story = RE4Access.n_story_now and true or false end
    local pos = RE4Access.game.player_pos()
    if not pos then return end
    -- In the boat no walking route: the boat steering says where to go (10/20:
    -- N gave "No walking route found ... what now" three times on the water)
    if RE4Access.game.in_boat and RE4Access.game.boat_kick then
        RE4Access.game.boat_kick()
        return
    end
    R.blocked_world = {}
    -- Keep away from bear traps.
    pcall(function()
        for _, t in ipairs(RE4Access.game.trap_positions(pos)) do R.blocked_world[#R.blocked_world + 1] = t end
    end)
    replans = 0
    route = nil
    local from = { x = pos.x, y = pos.y, z = pos.z }
    local goal = { x = target.pos.x, y = target.pos.y, z = target.pos.z }
    -- The boat sits in the water: walk to the nearest dry spot beside it and
    -- face it (10/19: picking "Boat" in a list gave "no walking route").
    if target.name == "Boat" and not target.latch then
        local b = target.pos
        local stand
        for r = 1.5, 6, 1.5 do
            for k = 0, 15 do
                local a = k * math.pi / 8
                local t = { x = b.x + math.sin(a) * r, z = b.z + math.cos(a) * r }
                local g = R.cast(t.x, b.y + 12, t.z, t.x, b.y - 4, t.z)
                if g then
                    t.y = g.y
                    local okn, pts = pcall(R.nav_points, from, t)
                    local l = okn and pts and pts[#pts]
                    if l and dist2d(l, t) < 0.8 then stand = t break end
                end
            end
            if stand then break end
        end
        if stand then
            target = { name = "Boat", pos = stand, face = { x = b.x, y = b.y + 0.5, z = b.z }, go = target.go, key = target.key,
                latch = true, fname = "Boat", spoken = "boat", after = "Press F to get in the boat. If F does not come, tap A or D a little." }
            goal = { x = stand.x, y = stand.y, z = stand.z }
        end
    end
    -- One-way edges the navmesh has no link for: walk to the edge first, then
    -- walk off it (10/19: into the lake swamp from the dock; "no walking route"
    -- to the Boat Fuel, Leon dropped in by walking off at about (175.5,-0.3,73)).
    if not target.latch and not target.edge then
        -- how close a walk from p gets to q (the Boat Fuel itself is behind a
        -- padlocked door, so "near" counts: within 10 m)
        local function gap(p, q)
            local okn, pts = pcall(R.nav_points, p, q)
            local last = okn and pts and pts[#pts]
            return last and dist2d(last, q) or 1e9
        end
        for _, L in ipairs(R.ONE_WAY_EDGES) do
            -- not when Leon is already on the far side (10/19: from the platform
            -- above the swamp N sent him back to the dock edge)
            local inside = from.x > L.area.x1 and from.x < L.area.x2 and from.z > L.area.z1 and from.z < L.area.z2
            if not inside and dist2d(from, L.a) > 1 and gap(from, goal) > 10 and gap(from, L.a) < 1.5
                and (gap(L.b, goal) < 10 or (goal.x > L.area.x1 and goal.x < L.area.x2 and goal.z > L.area.z1 and goal.z < L.area.z2)) then
                target = { name = target.name, pos = L.a, face = L.face, go = nil, key = target.key, latch = true, edge = true,
                    fname = L.name, spoken = L.name, after = L.text }
                goal = { x = L.a.x, y = L.a.y, z = L.a.z }
                say("The way there goes down an edge first.", false)
                break
            end
        end
    end
    -- A document's F works only inside its small sensor sphere (10/18 Lakeside
    -- Map: r 1.0; the route stopped 1.5 m off, F never came): walk to a floor
    -- spot well inside it, on Leon's side, then face its icon.
    if target.sensor and not target.latch then
        local c = target.sensor
        local stand
        local dx, dz = from.x - c.x, from.z - c.z
        local base = math.atan(dx, dz)
        for _, rr in ipairs({ 0.35, 0.55, math.max(0.3, c.r - 0.3) }) do
            for k = 0, 11 do
                local a = base + (k % 2 == 0 and 1 or -1) * math.floor((k + 1) / 2) * math.pi / 6
                local q = { x = c.x + math.sin(a) * rr, y = c.y, z = c.z + math.cos(a) * rr }
                local okn, pts = pcall(R.nav_points, from, q)
                local last = okn and pts and pts[#pts]
                if last and dist2d(last, q) < 0.2 and math.abs(last.y - c.y) < 1.2 then stand = q break end
            end
            if stand then break end
        end
        if stand then
            target = { name = target.name, pos = stand, face = target.face or c, go = target.go, key = target.key,
                latch = true, fname = target.name, spoken = target.name:lower(),
                after = target.name == "Document" and "Press F to read it."
                    or "Press F to look through the binoculars. If nothing happens, HOLD F down for 1 second." }
            goal = { x = stand.x, y = stand.y, z = stand.z }
        end
    end
    -- A gate latch: walk to the exact spot the game wants, then face the latch
    -- (10/18: from the middle of the gate F never showed up).
    if target.latch then
        local after = target.after or "HOLD F down for 1 second to lift the latch. Then hold W to push the gate open."
        local fname = target.fname or "Gate latch"
        if dist2d(goal, from) < 0.5 then
            pcall(RE4Access.game.face_item, target.face)
            say("The " .. (target.spoken or "gate latch") .. " is in front of you. " .. after, true)
            pcall(RE4Access.game.want_f, { pos = target.face, name = fname, go = target.go })
            return
        end
        if nav_route(from, goal, fname, false) then
            if route then route.face_target, route.after_text = target.face, after end
            return
        end
    end
    -- A door you picked: walk to its near side, never "behind a bolted door,
    -- walking you to the crank" about the door itself (10/13, barred door).
    local is_door = target.go and (target.name == "Door" or target.name == "Gate")
    if is_door then
        local okc, c = pcall(RE4Access.game.door_center_of, target)
        if okc and c then
            local dx, dz = from.x - c.x, from.z - c.z
            local dl = math.sqrt(dx * dx + dz * dz)
            if dl < 1.6 then
                say("The door is right here. Press Backslash to face it, then F.")
                return
            end
            goal = { x = c.x + dx / dl * 1.0, y = c.y, z = c.z + dz / dl * 1.0 }
        end
    end
    -- Behind iron bars the story opens later, and no walking way: say so at
    -- once (10/18: the church's broken phone note gave a long search, "Blocked").
    -- (not for the story objective itself: 10/20 "Head for the church" with the
    -- key in the case, the church gate counted as "opens later")
    if not target.latch and not tostring(target.name):find("Objective", 1, true) then
        local okb, barred = pcall(RE4Access.game.behind_closed_bars, goal, 8)
        if okb and barred then
            local okn, pts = pcall(R.nav_points, from, goal)
            if not (okn and pts) then
                say(tostring(target.name) .. " is behind iron bars that open later in the story. Skip it for now.", true)
                return
            end
        end
    end
    -- Items: walk to the floor in front of them (see R.reach_spot). An item in a
    -- dial-locked cabinet: walk to the cabinet and say how the lock works.
    local ck0 = target.item and tostring(target.name):match(", in a (%a+)$")
    if target.item and not (ck0 == "crate" or ck0 == "barrel" or ck0 == "box") then
        local okr, raw = pcall(R.nav_points, from, goal)
        local cab = R.cabinet_of(goal)
        if cab and not cab.dial and okr and raw then cab = nil end
        if not (okr and raw) or cab then
            local spot = R.reach_spot(from, cab and cab.dial and cab.pos or goal, cab and cab.dial and 1.6 or nil)
            if spot then
                local nm = tostring(target.name)
                local face, fname, after = goal, nm, nil
                if cab and cab.dial then
                    face, fname = cab.pos, "the dial lock on the cabinet with " .. nm
                    after = "Press F to use the dial lock. I read the rings as you turn them. The clue is in a document; for this closet it is the Iluminados page: the farmer's crop, the swineherd's pig, the grandam's babe."
                elseif cab then
                    face, fname = cab.pos, "the cabinet with " .. nm
                    after = "Press F to open it, then F again to take " .. nm .. "."
                end
                if dist2d(spot, from) < 0.6 and math.abs(spot.y - from.y) < 1 then
                    pcall(RE4Access.game.face_item, face)
                    say((fname:gsub("^%l", string.upper)) .. " is in front of you. " .. (after or "Wait for F ready, then press F."), true)
                    pcall(RE4Access.game.want_f, { pos = face, name = fname })
                    return
                end
                if nav_route(from, { x = spot.x, y = spot.y, z = spot.z }, fname, false) then
                    if route then route.face_target, route.after_text = face, after end
                    return
                end
            end
            -- No floor spot: what cuts it off?
            local okb, bd = pcall(R.blocking_door, from, goal)
            if okb and bd then
                say(target.name .. " is behind a locked door, " .. RE4Access.game.describe_position(RE4Access.game.door_center_of(bd), from, RE4Access.game.facing())
                    .. ". " .. (R.door_opener_text(bd) or "It is locked, and I can't tell what opens it.") .. " Question mark: what now.", true)
                return
            end
            -- In an attic: its ladder comes down with a lever (10/17, Chief's house).
            local GG = RE4Access.game
            if goal.y - from.y > 2 then
                for _, t in ipairs(GG.scan_things(goal, 12)) do
                    if t.name == "Attic Lid" and t.pos.y < goal.y then
                        local msg = target.name .. " is in the attic."
                        -- A two-person ladder (Coop Move Up) under the hatch: Ashley has
                        -- to climb up and lower the ladder (story, Chapter 5). 10/17 the
                        -- user pulled the lever in Chapter 3 and nothing happened.
                        local coop = false
                        for _, cq in ipairs(GG.scan_things(t.pos, 5)) do if cq.name == "Coop Move Up" then coop = true end end
                        if coop and not RE4Access.ashley_here then
                            say(msg .. " You can't get up there yet: Ashley has to climb up first and lower the ladder for you. Come back here later in the story, when Ashley is with you.", true)
                            return
                        end
                        for _, l in ipairs(GG.scan_things(t.pos, 10)) do
                            if l.name == "Lever" then
                                msg = msg .. " A lever lowers the attic ladder: Lever, " .. GG.describe_position(l.pos, from, GG.facing()) .. "."
                                -- only when the lever itself can't be walked to (10/17: after the
                                -- crystal door opened it still said "behind a locked door")
                                local lspot = R.reach_spot(from, l.pos, nil, 1.6)
                                local okb2, bd2 = false, nil
                                if not lspot then okb2, bd2 = pcall(R.blocking_door, from, l.pos) end
                                if okb2 and bd2 then msg = msg .. " The lever is behind a locked door. " .. (R.door_opener_text(bd2) or "")
                                else msg = msg .. " Pull the lever first: pick Lever in Puzzles and press Shift+Backslash to walk there." end
                                break
                            end
                        end
                        say(msg, true)
                        return
                    end
                end
            end
        end
    end
    -- Anything behind a puzzle door (10/17: N led to the bedroom lever behind the
    -- crystal ball door; the route went OUTSIDE "to the other door" and Leon ended
    -- in a bear trap). A puzzle door has no other way in: say what opens it.
    if not is_door and not target.item then
        local okr2, raw2 = pcall(R.nav_points, from, goal)
        if not (okr2 and raw2) then
            -- things up on a wall or a stand (crystal ball, lever): the floor in front.
            -- Their position is near their own floor: at most 1.6 m up (a lever on
            -- the floor above matched the stairs below it).
            local spot = R.reach_spot(from, goal, nil, 1.6)
            -- A walking point (trigger area in the air): just walk under it, no F (10/19).
            if spot and target.walk_point then
                if dist2d(spot, from) < 1.5 then
                    say("Arrived at " .. tostring(target.name) .. ". Press N for the next step.", true)
                    return
                end
                if nav_route(from, { x = spot.x, y = spot.y, z = spot.z }, tostring(target.name), false) then return end
            end
            if spot and not target.walk_point then
                if dist2d(spot, from) < 0.6 and math.abs(spot.y - from.y) < 1 then
                    pcall(RE4Access.game.face_item, goal)
                    say(tostring(target.name) .. " is in front of you. Wait for F ready, then press F.", true)
                    pcall(RE4Access.game.want_f, { pos = goal, name = target.name, go = target.go })
                    return
                end
                if nav_route(from, { x = spot.x, y = spot.y, z = spot.z }, tostring(target.name), false) then
                    if route then route.face_target = goal end
                    return
                end
            end
            local okb, bd = pcall(R.blocking_door, from, goal)
            local gn = ""
            if okb and bd then pcall(function() gn = bd.go:call("get_Name") end) end
            if gn:find("水晶パズル", 1, true) then
                say(target.name .. " is behind the crystal ball door. " .. (R.door_opener_text(bd) or ""):gsub("Pick Crystal Marble in Items", "Pick it in Items"), true)
                return
            end
        end
    end
    -- No navmesh way and no ladder/window plan: a locked door in between? Say so
    -- instead of a route that can't arrive (10/12: Small Key behind the crest door).
    if not is_door and not tostring(target.name):find("bird's nest", 1, true) then
        local okn, npts = pcall(R.nav_points, from, goal)
        if not (okn and npts) then
            local okv, vpts = pcall(plan_via, from, goal)
            if not (okv and vpts) then
                local okl, msg, bolted = pcall(RE4Access.game.locked_door_between, from, goal)
                if okl and msg and bolted then
                    -- Bolted door: walk to the crank that opens the way round.
                    local crank = RE4Access.game.gimmick_near(from, "シャッターハンドル", 60)
                    if crank then
                        if dist2d(crank, from) < 1.3 then
                            say(target.name .. " is " .. msg .. ". You are at the crank: hold F to turn it.", true)
                            return
                        end
                        say(target.name .. " is " .. msg .. ". Walking you to a crank that opens another way. Hold W.", true)
                        RE4Access.speak_hold = true
                        local okr = nav_route(from, crank, "the crank", false)
                        RE4Access.speak_hold = nil
                        if okr then return end
                    end
                end
                -- 10/14: from the Valley roof the mod sent Leon to a padlock 2.5 m
                -- below him (kick spot on the roof). Only a padlock on your floor.
                local okk0, kspot0 = pcall(RE4Access.game.padlock_kick_spot, from)
                local same_floor = okk0 and kspot0 and math.abs((kspot0.y or from.y) - from.y) < 1.5
                if okl and msg and msg:find("padlock", 1, true) and not same_floor then
                    log.info("[RE4Access] padlock not on your floor, skipped")
                    msg = nil
                end
                if okl and msg then
                    if msg:find("padlock", 1, true) then
                        -- Walk up to the lock and kick it (F): no bullets needed.
                        local okk, kspot = pcall(RE4Access.game.padlock_kick_spot, from)
                        if okk and kspot then
                            if dist2d(kspot, from) < 1.2 then
                                say("Padlocked door. You're at the padlock: press F to kick it.", true)
                                return
                            end
                            say(target.name .. " is behind a padlocked door. Walking you to the padlock to kick it. Hold W.", true)
                            RE4Access.speak_hold = true
                            local okr = nav_route(from, kspot, "padlock, to kick it", false)
                            RE4Access.speak_hold = nil
                            if okr then return end
                        end
                        local okp, spot = pcall(RE4Access.game.padlock_spot, from)
                        if okp and spot then
                            if dist2d(spot, from) < 1.5 then
                                say("Padlocked door. Shoot the padlock from here: hold L, press K when I say fire. Two hits.", true)
                                return
                            end
                            say(target.name .. " is behind a padlocked door. Walking you to a spot to shoot the padlock. Hold W.", true)
                            RE4Access.speak_hold = true
                            local okr = nav_route(from, { x = spot.x, y = spot.y, z = spot.z }, "spot to shoot the padlock", false)
                            RE4Access.speak_hold = nil
                            if okr then return end
                        end
                    end
                    -- Another door into the same place (10/14 9PM: Chief's house
                    -- front door locked, the back door open; the mod only said
                    -- 'behind a locked door').
                    if not going_on then
                        local spot, sd = R.other_door_spot(from, goal)
                        if spot then
                            say(target.name .. " is behind a locked door. Walking you round to another door, " .. math.floor(sd + 0.5) .. " meters. Hold W.", true)
                            RE4Access.speak_hold = true
                            local okr = nav_route(from, spot, "the other door", false)
                            RE4Access.speak_hold = nil
                            if okr then R.pending_target, R.pending_door = target, spot.door return end
                        end
                    end
                    say(target.name .. " is " .. msg .. " Question mark: what now.", true)
                    return
                end
            end
        end
    end
    if target.item and tostring(target.name):find("bird's nest", 1, true) then
        -- A nest is shot down, not walked to: go to a spot 4-9 m away with a clear line.
        -- aim point is the nest up in the tree, not the item's spot on the ground
        -- under it (10/20: the line test went to the ground and picked a spot where
        -- a branch took every shot)
        local ok, spot = pcall(RE4Access.game.shoot_spot, target.shoot or goal, from, { 5, 6, 4, 7, 3, 8, 9, 10, 12, 14 })
        if ok and spot then
            if dist2d(spot, from) < 1.5 then
                say("Shoot the nest from here: hold L, press K when I say fire.")
                return
            end
            if nav_route(from, { x = spot.x, y = spot.y, z = spot.z }, "spot to shoot the bird's nest", false) then return end
        end
    end
    local ckind = target.item and tostring(target.name):match(", in a (%a+)$")
    if ckind == "crate" or ckind == "barrel" or ckind == "box" then
        local ok, spot = pcall(crate_spot, goal, from)
        if ok and spot then
            local tail = (RE4Access.game.has_knife and RE4Access.game.has_knife() == false)
                and "You need a knife to break it, and you have none. Find a knife first."
                or "Hold Space and press K to break it, then press F to pick it up."
            if dist2d(spot, from) < 1.0 and math.abs(spot.y - from.y) < 1.0 then
                pcall(RE4Access.game.face_item, goal)
                say("The " .. ckind .. " is right in front of you. " .. tail)
                return
            end
            if nav_route(from, { x = spot.x, y = spot.y, z = spot.z }, "the " .. ckind .. " with " .. tostring(target.name):gsub(", in a %a+$", ""), false) then
                if route then route.crate = { item = goal, tail = tail } end
                return
            end
        end
    end
    -- Crowded spot: walk to where the target is the nearest thing to press F on.
    if not is_door and not target.ctx and not target.walk_point and target.pos then
        local others = {}
        pcall(function()
            local GG = RE4Access.game
            for _, t in ipairs(GG.scan_things(goal, 2.5)) do
                if t.go ~= target.go and t.name ~= "Breakable crate" and t.name ~= "Map Icon Only" and t.name ~= "Mouse" then others[#others + 1] = t.pos end
            end
            for _, t in ipairs(GG.items(goal, 2.5)) do
                if t.go ~= target.go and dist2d(t.pos, goal) > 0.1 then others[#others + 1] = t.pos end
            end
        end)
        local crowded = false
        for _, o in ipairs(others) do if dist2d(o, goal) < 1.6 then crowded = true break end end
        if crowded then
            local oks, spot = pcall(clear_spot, goal, from, others)
            if oks and spot then
                if dist2d(spot, from) < 0.4 and not target.walk_point then
                    pcall(RE4Access.game.face_item, goal)
                    say("Stand still here. " .. tostring(target.name) .. " is in front of you. Wait for F ready, then press F.")
                    pcall(RE4Access.game.expect_prompt)
                    return
                end
                if nav_route(from, { x = spot.x, y = spot.y, z = spot.z }, tostring(target.name), false) then
                    -- 11/2: walking points are not F targets ('wait for F ready' on 'the room above')
                    if route and not target.walk_point then route.face_target = goal end
                    return
                end
            end
        end
    end
    if target.item then
        -- Within 2 m on the same floor: no route needed.
        if dist2d(goal, from) < 2.2 and math.abs(goal.y - from.y) < 1.8 then
            local where = "close"
            pcall(function()
                local f = RE4Access.game.facing()
                local d = (math.deg(math.atan(goal.x - from.x, goal.z - from.z)) - f + 540) % 360 - 180
                local a, side = math.abs(d), d > 0 and "left" or "right"   -- higher heading = left (10/19 fix)
                where = a < 20 and "ahead" or a < 60 and ("ahead " .. side) or a < 120 and side or a < 160 and ("behind " .. side) or "behind"
            end)
            local tail = "Step toward it and press F."
            local kind = tostring(target.name):match(", in a (%a+)$")
            if kind == "crate" or kind == "barrel" or kind == "box" then
                -- 10/13: "Press F" at a herb crate; F does nothing until it is broken.
                if RE4Access.game.has_knife and RE4Access.game.has_knife() == false then
                    tail = "You need a knife to break it, and you have none. Find a knife first."
                else
                    tail = "Stop here. Hold Space and press K to break the " .. kind .. ", then press F to pick it up."
                end
            end
            say(string.format("%s is right here, %d meters %s. %s", target.name, math.floor(dist2d(goal, from) + 0.5), where, tail))
            return
        end
        local ok, spot = pcall(stand_spot, goal)
        if ok and spot then
            local sgoal = { x = spot.x, y = spot.y, z = spot.z }
            if nav_route(from, sgoal, target.name, false) then return end
        end
    end
    if nav_route(from, goal, target.name, false) then return end
    start_search(from, goal, target.name)
    say("Finding a way to " .. target.name)
end

function R.stop(quiet)
    local was = R.active()
    route, search = nil, nil
    if was and not quiet then say("Route off") end
end

function R.replan(pos, why)
    if not route then return end
    -- a fixed path (no walking map here): start it again from where Leon is (11/26)
    if route.fixed then
        local f = route.fixed
        replans = replans + 1
        if replans > 6 then
            say("Stuck. Route off. Press N again.")
            route = nil
            return
        end
        route = nil
        say(why, false)
        R.go_points(f.pts, f.name, f.face, f.after, true)
        return
    end
    -- Right after Continue (loading, cutscene) the map isn't there yet: a replan
    -- then fails with nonsense (10/14: "behind walls, not open yet" for the emblem).
    local st = RE4Access.game and RE4Access.game.state_text
    if st ~= "In control" or (RE4Access.game.is_dead) then route = nil return end
    replans = replans + 1
    if replans > 6 then
        say("Stuck. Route off. Try the trail back with B, or pick another place.")
        route = nil
        return
    end
    local goal, name = route.goal, route.name
    route = nil
    say(why, false)
    if nav_route({ x = pos.x, y = pos.y, z = pos.z }, goal, name, true) then return end
    start_search({ x = pos.x, y = pos.y, z = pos.z }, goal, name)
    search.quiet = true
end

function R.trap_block(pos)
    local G = RE4Access.game
    for _, t in ipairs(G.scan_things(pos, 3)) do
        if t.name == "Bear trap" and G.trap_live(t.go) and math.abs(t.pos.y - pos.y) < 2 then
            R.stop(true)
            local dir = G.describe_position and G.describe_position(t.pos, pos, G.facing()) or ""
            local g = G.gun_info and G.gun_info()
            if g and (g.loaded > 0 or g.spare > 0) then
                say("A bear trap is in the way, " .. dir .. ". Route stopped. Take 2 steps back with S, hold L, and press K when I say fire. Then start the route again.", true)
            else
                say("A bear trap is in the way, " .. dir .. ". Route stopped. No ammo to shoot it: walk past it slowly with the trap on your side, or get ammo first.", true)
            end
            log.info(string.format("[RE4Access] blocked by bear trap at (%.1f,%.1f)", t.pos.x, t.pos.z))
            return true
        end
    end
    return false
end

-- Called by game.lua when "Blocked" is detected while a route is active:
-- remember the cell in front of Leon as blocked and plan again.
function R.on_blocked(pos)
    if not route then return end
    -- A closed door in the way: open it rather than looking for another way.
    local ok, door, locked, asleep = pcall(RE4Access.game.door_in_front, pos)
    -- A gate the story keeps shut is a wall like any other (routes avoid it);
    -- don't say "Closed door" about it, just go around.
    if ok and door and asleep then door = nil end
    if ok and door then
        local kt
        if locked then pcall(function() kt = RE4Access.game.door_key_text(door.go, pos) end) end
        if not locked then
            -- Step back from the hinge side and walk into the middle: that pushes it open.
            pcall(function() RE4Access.game.face_point(door.pos, true) end)
        end
        -- Gates that open with F (10/19: lakeside gate; "Step back with S, then
        -- hold W to walk into it" every 2 s, 11 times, while the game showed F).
        local fnow = false
        pcall(function() fnow = RE4Access.game.prompt_active() end)
        local text = locked and ("Locked door. " .. (kt or "Press F; if you have the key, choose it."))
            or fnow and "Closed gate. Press F to open it, then hold W."
            or "Closed door. " .. (RE4Access.game.spoken and ("Its middle is " .. (RE4Access.game.last_dir or "ahead")) or "Turned you to its middle") .. ". Step back with S, then hold W to walk into it."
        -- once per door, not every bump
        local now0 = os.clock()
        if R.door_said and R.door_said.key == door.key and R.door_said.text == text and now0 - R.door_said.at < 10 then return end
        R.door_said = { key = door.key, text = text, at = now0 }
        say(text)
        return
    end
    -- 11/26 Ch10 sewers: a shutter the story opens later (gm80_770 "shutter that opens
    -- after the sewer breaker", a plain GmPortrayal, not a door) stood in the way of the
    -- First Aid Spray: "Blocked, finding another way" over and over. Say what it is.
    do
        local sh_name
        pcall(function()
            local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core and not sh_name then
                    pcall(function()
                        local go = core:call("get_GameObject")
                        local n = go:call("get_Name")
                        if n:find("シャッター", 1, true) then
                            local q = go:call("get_Transform"):call("get_Position")
                            if dist2d(q, pos) < 2.0 and math.abs(q.y - pos.y) < 2 and not core:call("get_Context"):call("hasDoneForMap") then sh_name = n end
                        end
                    end)
                end
            end
        end)
        if sh_name then
            local when = sh_name:find("ブレーカー", 1, true) and " It opens after you switch on the circuit breaker; press N for the way there." or " The story opens it later; press N for the way on."
            say("A closed shutter blocks the way." .. when, true)
            log.info("[RE4Access] blocked by story shutter: " .. sh_name)
            route = nil
            return
        end
    end
    -- A live bear trap right here (10/12 PM: Resources (S) lies 1.5 m past a trap;
    -- the route bumped into the trap guard and said "Blocked, finding another way"
    -- 5 times). Shoot it shut first.
    if R.trap_block(pos) then return end
    -- First bump: probably a cut corner. Steer exactly along the route for 4 s.
    local now = os.clock()
    if not route.nudged_at or now - route.nudged_at > 8 then
        -- Fresh path from exactly here (10/17, Chief's bedroom: Leon walked into
        -- furniture by the Ruby route 6 times; our rays can't see furniture, but the
        -- navmesh goes round it - from his real spot it said step back, then round).
        if not route.action then
            local old = route
            route = nil
            pcall(nav_route, { x = pos.x, y = pos.y, z = pos.z }, old.goal, old.name, true)
            if not route then route = old end
            route.lasers = route.lasers or old.lasers
        else
            -- ladder/window routes are not re-planned here: fix a cut corner from
            -- exactly where Leon stands instead (11/26)
            pcall(function()
                local rest = { { x = pos.x, y = pos.y, z = pos.z } }
                for k = route.idx + 1, #route.points do rest[#rest + 1] = route.points[k] end
                local fixed = R.fix_corners(rest, 2)
                if #fixed ~= #rest or fixed[2] ~= rest[2] then
                    route.points = fixed
                    route.idx = 1
                end
            end)
        end
        route.nudged_at = now
        route.precise_until = now + 4
        local pts = route.points
        local nxt = pts[math.min(#pts, route.idx + 1)]
        if nxt then RE4Access.game.face_point(nxt, true) end
        log.info(string.format("[RE4Access] blocked: nudging along the route at (%.1f,%.1f,%.1f), point %d of %d, to %s",
            pos.x, pos.y, pos.z, route.idx, #route.points, tostring(route.name)))
        return
    end
    local pts = route.points
    local nxt = pts[math.min(#pts, route.idx + 2)]
    if nxt then R.blocked_world[#R.blocked_world + 1] = { x = nxt.x, z = nxt.z } end
    -- 11/15: remember the spot just in front of Leon, toward where he was heading
    local hd = pts[math.min(#pts, route.idx + 1)]
    if hd then
        local dx, dz = hd.x - pos.x, hd.z - pos.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 0.05 then
            local k = math.min(0.7, l)
            R.stuck_marks[#R.stuck_marks + 1] = { x = pos.x + dx / l * k, y = pos.y, z = pos.z + dz / l * k, t = os.clock() }
            log.info(string.format("[RE4Access] stuck mark at (%.1f,%.1f), %d marks", pos.x + dx / l * k, pos.z + dz / l * k, #R.stuck_marks))
        end
    end
    R.replan(pos, "Blocked, finding another way")
end

function R.on_frame(now)
    local dw = R.door_wait
    if dw and not route and not search and now >= dw.next_at then
        dw.next_at = now + 0.5
        local pos = RE4Access.game.player_pos()
        if now > dw.until_t then
            R.door_wait = nil
            say("The door did not open. Face it and press F, then press Backslash on " .. tostring(dw.target.name) .. " again.", true)
        elseif pos then
            -- the floor by the target: a typewriter on a table has no walking map
            -- under its own point (10/15: waited 30 s at an open door for that)
            local g = dw.target.pos
            local through = false
            for _, dy in ipairs({ 0, -1.0 }) do
                local okn, pts = pcall(R.nav_points, { x = pos.x, y = pos.y, z = pos.z }, { x = g.x, y = g.y + dy, z = g.z })
                if okn and pts and #pts > 0 and dist2d(pts[#pts], g) < 2.0 and math.abs(pts[#pts].y - g.y) < 2.0 then through = true break end
            end
            if through then
                R.door_wait = nil
                log.info("[RE4Access] other door open, going on to " .. tostring(dw.target.name))
                say("Door open. On to " .. tostring(dw.target.name) .. ".", true)
                R.going_on = true
                R.go(dw.target)
            end
        end
    end
    -- 11/26: right after a ladder Leon is still in the climb-off animation and the first
    -- search from there failed ("No walking route found"; N again worked). Try once more.
    if R.through_retry and not search and os.clock() >= R.through_retry.at then
        local tr = R.through_retry
        R.through_retry = nil
        local p0 = RE4Access.game.player_pos()
        if p0 and not route then
            if not nav_route({ x = p0.x, y = p0.y, z = p0.z }, tr.goal, tr.name, true) then
                start_search({ x = p0.x, y = p0.y, z = p0.z }, tr.goal, tr.name)
                search.quiet = true
            end
        end
    end
    if search then
        local ok, res = pcall(step_search, search)
        if not ok then
            log.info("[RE4Access] route search error: " .. tostring(res))
            say("Route finder error")
            search = nil
            return
        end
        local partial = false
        if res == "fail" then
            local s = search
            local start_d = dist2d(s.goal, { x = s.ox, z = s.oz })
            log.info(string.format("[RE4Access] route fail: %d cells, %d rays, %.1fs, closest %.1f m (start %.1f)",
                s.expanded, R.stats.rays - s.rays0, os.clock() - s.started, s.best_d or -1, start_d))
            if s.laser_avoid and R.pending_laser_route and not (s.best and s.best_d < start_d - 3) then
                -- No way around the laser: walk the nav route, warned to shoot the bomb.
                route = R.pending_laser_route
                R.pending_laser_route = nil
                search = nil
                local lz = route.lasers[1]
                say("Can't get around the tripwire bomb. Shoot it first: hold L, press K, from at least 4 meters away. Then hold W.", true)
                return
            end
            if s.after_through and not route then
                search = nil
                R.through_retry = { goal = s.goal, name = s.name, at = os.clock() + 1.5 }
                return
            end
            if s.best and s.best_d < start_d - 3 then
                -- Go as close as we can; plan again from there.
                s.result, partial = s.best, true
                res = "done"
            else
                local hint = ""
                pcall(function() hint = RE4Access.game.no_route_hint(s.goal) end)
                -- No ground at all under the target: that part of the map isn't
                -- loaded (10/13: Rifle Ammo past a wall in the Chapter 2 factory).
                pcall(function()
                    local g = s.goal
                    if not R.cast(g.x, g.y + 0.5, g.z, g.x, g.y - 3, g.z) then
                        hint = ". It is behind walls in a part of the map that is not open yet. The way there is probably later in the story; skip it for now"
                    end
                end)
                -- only on Leon's own floor (10/17: "Yellow Herb is very close, 2 meters,
                -- walk yourself" - it was in the attic, 5 m up)
                local same_fl = true
                pcall(function() same_fl = math.abs(s.goal.y - RE4Access.game.player_pos().y) < 1.8 end)
                if start_d < 3.5 and same_fl then
                    say(string.format("%s is very close, %d meters. Walk toward it yourself; Backslash faces it.", s.name, math.floor(start_d + 0.5)))
                else
                    say((s.partial_hop and ("Can't get closer to " .. s.name .. ". Route off.") or ("No walking route found to " .. s.name .. ". It may open later in the story")) .. hint .. ". Question mark: what now.")
                end
                search = nil
                return
            end
        end
        if res == "done" then
            local s = search
            search = nil
            local pts, total = finish(s, s.result)
            if partial then pts[#pts] = nil end   -- drop the unreachable goal point
            log.info(string.format("[RE4Access] route found: %.1f m, %d points, %d cells, %d rays, %.1fs",
                total, #pts, s.expanded, R.stats.rays - s.rays0, os.clock() - s.started))
            route = { points = pts, goal = s.goal, name = s.name, idx = 1, partial = partial }
            R.last_route = pts
            local straight = dist2d(s.goal, pts[1])
            if s.quiet then
                RE4Access.game.face_point(pts[math.min(#pts, 3)], true)
            else
                local extra = total > straight * 1.3 and ", winding" or ""
                if partial then
                    say(string.format("Only part of the way is known. Route %d meters toward %s. Hold W.", math.floor(total + 0.5), s.name))
                else
                    say(string.format("Route found, %d meters%s. Hold W.", math.floor(total + 0.5), extra))
                end
                RE4Access.game.face_point(pts[math.min(#pts, 3)], true)
            end
        end
        return
    end
    if route then
        local pos = RE4Access.game.player_pos()
        if pos then
            local ok, err = pcall(follow, pos, now)
            if not ok then log.info("[RE4Access] route follow error: " .. tostring(err)) end
        end
    end
end

RE4Access.route = R
return R
