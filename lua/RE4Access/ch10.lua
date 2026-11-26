-- RE4 Access: Chapter 10 step by step (N). Claude PLAYED Chapter 10 live on 11/21
-- (can't die on) and took every spot below from the game. Each step is the place to
-- stand; on arrival the mod turns you to the thing and says what to press.
-- Part 1 "Head for the throne room": levers, drawbridge weights, Garradors, horns.
-- Part 2 "Make your way to the surface": cave (no map data: N says the way), crawl,
-- crown, ladder, lab lever, breaker, crank, elevator.
local G = RE4Access.game
if not G then return {} end
local C = {}
G.ch10 = G.ch10 or {}

local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
local function V(x, y, z) return { x = x, y = y, z = z } end

-- Gimmick by name part near a spot: returns go, done
local function gfind(part, x, z, r)
    local best, done
    pcall(function()
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject")
                if go:call("get_Name"):find(part, 1, true) then
                    local q = go:call("get_Transform"):call("get_Position")
                    if math.sqrt((q.x - x) ^ 2 + (q.z - z) ^ 2) < (r or 1.5) then
                        best = go
                        done = false
                        pcall(function() done = core:call("get_Context"):call("hasDoneForMap") end)
                    end
                end
            end) end
        end
    end)
    return best, done
end

local function item_near(namepart, pos, r)
    local okI, list = pcall(G.items, pos, r or 40)
    if not okI or not list then return nil end
    for _, it in ipairs(list) do
        if tostring(it.name):find(namepart, 1, true) then return it end
    end
end

-- A spot to stand on, then face something and press F (route latch = exact spot).
local function spot(name, stand, face, after, key, pos, extra)
    local t = { name = name, pos = stand, dist = d2(stand, pos), face = face, latch = true, fname = name,
        spoken = name:gsub("^the ", ""), after = after, key = key or ("ch10_" .. name), tip = "" }
    if extra then for k, v in pairs(extra) do t[k] = v end end
    return t
end

-- No map data in the cave: no route, N says where the next point is.
local function cave(name, p, pos, tip)
    local where = ""
    pcall(function() where = math.floor(d2(p, pos) + 0.5) .. " meters, " .. G.describe_position(p, pos, G.facing()) end)
    return { name = name .. ", " .. where, pos = p, dist = d2(p, pos), no_route = true, key = "ch10_cave", face = p,
        tip = tip or "Hold W that way, then press N again." }
end

local function garradors_alive(pos)
    local n = 0
    pcall(function()
        local list = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
        for i = 0, list:call("get_Count") - 1 do
            local c = list:call("get_Item", i)
            if c:call("get_KindID") == 200008 and c:call("get_HitPoint"):call("get_CurrentHitPoint") > 0 then
                local q = c:call("get_Position")
                if q.x > 235 and q.x < 290 and q.y > 25 then n = n + 1 end
            end
        end
    end)
    return n
end

-- ===================== PART 1: Head for the throne room =====================
function C.part1(pos)
    -- Approach from the Grand Hall (the ballroom is not loaded yet from there):
    -- big gate past the Chimera statue, east hall, stairs up, door, room, door.
    -- 11/25 user test: the Chapter 10 save starts Leon in the railed pocket just north of
    -- the Chimera statue; the navmesh goes straight through the railing (blocked 4x).
    -- Way out (ray-checked 11/25): around the statue's east side, south, west along the
    -- corridor, north up the west side, then the gate route.
    if pos.y > 26.8 and pos.y < 28.5 then
        if pos.x > 130.4 and pos.x < 134.6 and pos.z > 41.2 and pos.z < 43.4 then
            return spot("the corridor south of the statue", V(132.4, 27.3, 36.6), V(128.0, 27.3, 36.5),
                "Press N.", "ch10_pocket1", pos, { spoken = "corridor" })
        end
        if pos.x > 128.6 and pos.x < 135.5 and pos.z > 34.5 and pos.z < 39.3 then
            return spot("the west end of the corridor", V(127.6, 27.3, 36.6), V(127.7, 27.3, 42.0),
                "Press N.", "ch10_pocket2", pos, { spoken = "corridor end" })
        end
        if pos.x <= 128.6 and pos.z > 34.5 and pos.z < 41.6 then
            return spot("the west side of the statue", V(127.7, 27.3, 42.0), V(130.0, 27.3, 44.6),
                "Press N.", "ch10_pocket3", pos, { spoken = "west side" })
        end
    end
    if pos.x < 135.6 and pos.y < 30 then
        return spot("the big gate past the Chimera statue", V(134.4, 27.3, 56.4), V(137.0, 28.3, 56.4),
            "Press F, then hold W to push it open and walk through. Then press N.", "ch10_gate1", pos, { spoken = "big gate" })
    end
    if pos.x > 140 and pos.x < 158.9 and pos.z > 52.8 and pos.y < 29 then
        return spot("the gap in the railing", V(158.2, 27.2, 53.4), V(158.0, 27.3, 51.0),
            "Hold W to step through it, then press N. Two bugs come here: hold L and press K.", "ch10_rail", pos, { spoken = "gap in the railing" })
    end
    if pos.x < 166.5 and pos.y < 31.5 then
        return spot("the door at the top of the stairs", V(167.1, 32.5, 37.6), V(167.5, 33.5, 35.5),
            "Hold W to walk through. Then press N.", "ch10_door1", pos, { spoken = "door" })
    end
    if pos.x > 160 and pos.x < 181.2 and pos.z > 25 and pos.z < 36.2 and pos.y > 31 then
        local sp = item_near("First Aid Spray, in a cupboard", pos, 15)
        if sp then
            return spot("the glass cabinet with a First Aid Spray", V(167.65, 32.55, 28.8), V(167.8, 33.8, 27.7),
                "Press F to take the First Aid Spray. Then press N.", "ch10_spray", pos)
        end
        return spot("the door on the right side of this room", V(180.5, 32.55, 34.6), V(183.0, 33.5, 35.3),
            "Hold W to walk through. Then press N. A swarm of flying bugs is ahead: shotgun.", "ch10_door2", pos, { spoken = "door" })
    end
    -- First Aid Spray in the glass cabinet of the room upstairs (optional, close by)
    if pos.x > 160 and pos.x < 182 and pos.z > 25 and pos.z < 40 and pos.y > 31 then
        local sp = item_near("First Aid Spray, in a cupboard", pos, 15)
        if sp then
            return spot("the glass cabinet with a First Aid Spray", V(167.65, 32.55, 28.8), V(167.8, 33.8, 27.7),
                "Press F to take the First Aid Spray. Then press N.", "ch10_spray", pos)
        end
    end
    local _, ldone = gfind("gm84_873", 199.6, 51.6)
    -- ballroom floor, lever 1 still up: the ladder to the balcony (exact spot; the
    -- route's own ladder stop overshot it, 11/21 test)
    if ldone ~= true and pos.y < 28.5 and pos.x > 168 and pos.x < 203 and pos.z > 30 and pos.z < 60 then
        return spot("the ladder up to the balcony", V(189.45, 26.3, 39.69), V(190.11, 27.3, 39.91),
            "Hold F for 1 second to climb up. Then press N. Flying bugs attack in this ballroom: shotgun, or hold L and press K.", "ch10_ballladder", pos, { spoken = "ladder" })
    end
    if ldone == false then
        return spot("the first ballroom lever", V(198.9, 32.5, 50.6), V(199.6, 33.5, 51.6),
            "Press F to pull it. Then press N for the second lever.", "ch10_lever1", pos)
    end
    local _, rdone = gfind("gm84_872", 199.6, 61.4)
    -- lever 1 done, Leon still on the south balcony: jump down west, then the long way
    -- round to the north balcony (tested 11/21)
    if rdone == false and pos.y > 31 and pos.x > 190 and pos.z < 56 then
        return spot("the balcony edge to jump down", V(198.0, 32.5, 51.5), V(195.5, 32.5, 52.1),
            "Do not turn. Hold W and keep tapping F; Leon jumps over the railing. Then press N.", "ch10_drop", pos, { spoken = "edge" })
    end
    if rdone == false then
        return spot("the second ballroom lever", V(200.1, 32.5, 62.1), V(199.6, 33.5, 61.4),
            "Press F to pull it. The ballroom gate opens. Then press N.", "ch10_lever2", pos)
    end
    local w1, w1done = gfind("gm84_764", 241.9, 60.4)
    if w1done == false then
        return spot("the spot to shoot the high counterweight", V(228.3, 29.4, 57.2), V(242.0, 34.0, 60.3),
            "Hold L: I aim at the counterweight, it hangs left of the raised drawbridge. Press K when I say fire. Then press N.",
            "ch10_w1", pos, { shoot = { x = 242.0, y = 34.0, z = 60.3, label = "Counterweight" }, go = w1 })
    end
    local w2, w2done = gfind("gm84_764", 241.2, 55.3)
    if w2done == false then
        return spot("the spot to shoot the low counterweight", V(222.74, 29.47, 46.6), V(241.2, 25.4, 55.4),
            "This is the only spot that sees the low counterweight, between two stone columns, 20 meters away. Hold L: I aim at it. Press K when I say fire. Then press N.",
            "ch10_w2", pos, { shoot = { x = 241.2, y = 25.4, z = 55.4, label = "Counterweight", range = 22 }, go = w2 })
    end
    local _, shdone = gfind("gm80_557", 274.7, 56.4)
    if shdone == false then
        if pos.x < 242.5 and garradors_alive(pos) > 0 or pos.x < 238 then
            return spot("the gate across the drawbridge", V(243.1, 29.4, 56.5), V(246.0, 30.5, 56.4),
                "Press F, then hold W to push it open. Two blind Garradors and some zealots are inside. Crouch with E, walk, do not run. Then press N.", "ch10_antegate", pos, { spoken = "gate" })
        end
        if garradors_alive(pos) > 0 then
            return { name = "the Garradors", pos = V(250, 29.5, 56.5), dist = d2(V(250, 29.5, 56.5), pos), no_route = true, key = "ch10_garr",
                tip = garradors_alive(pos) .. " Garradors left. They are blind and follow sound. Crouch with E and walk, do not run. Hold L and press K: hit the parasite on the back when you can. A bell you shoot makes a Garrador charge it and get stuck. Grenades work well. Press N when they are dead." }
        end
        local horn = item_near("Unicorn Horn", pos, 40)
        if horn then
            local c = {} for k, v in pairs(horn) do c[k] = v end
            c.tip = "Press F at F ready."
            return c
        end
        local s2, s1 = V(272.2, 30.7, 57.7), V(272.3, 30.7, 54.4)
        local first, second = s2, s1
        if d2(s1, pos) < d2(s2, pos) then first, second = s1, s2 end
        -- standing at one statue already (horn placed there): the other one
        if d2(first, pos) < 1.2 then first = second end
        local face = first == s2 and V(273.33, 31.7, 57.87) or V(273.36, 31.7, 54.65)
        return spot("a Unicorn statue", first, face,
            "Press F. In the key item list pick Unicorn Horn, press Space, then Space on Use. Then press N for the other statue.", "ch10_stand", pos)
    end
    local _, tdone = gfind("gm80_797", 281.1, 56.4)
    if tdone == false then
        return spot("the throne room gate", V(278.8, 30.6, 56.6), V(284, 31.5, 56.4),
            "Hold W and press F to push it open.", "ch10_throne", pos, { spoken = "throne room gate" })
    end
end

-- ===================== PART 2: Make your way to the surface =====================
-- Claude's recorded walk 11/21 (tools/ch10/trail.txt lines 76-202): out of the
-- squeeze, round the rock, north up the water passage to the crawl hole.
C.CAVE_PATH = {
    V(316.26, -38.39, 53.09), V(317.91, -38.39, 53.89), V(318.42, -38.39, 53.61), V(319.49, -38.55, 52.46), V(320.59, -38.62, 53.34),
    V(321.25, -38.62, 54.49), V(321.45, -38.62, 55.49), V(321.01, -38.62, 55.93), V(321.05, -38.62, 57.04),
    V(321.55, -38.62, 58.25), V(321.81, -38.62, 59.55), V(322.04, -38.62, 60.77), V(321.81, -38.62, 61.85),
    V(321.54, -38.62, 62.89), V(321.25, -38.62, 64.23), V(320.89, -38.62, 65.68), V(320.44, -38.62, 67.06),
    V(320.14, -38.62, 68.21), V(319.58, -38.62, 69.60), V(319.00, -38.62, 70.73), V(318.60, -38.62, 71.80),
    V(317.84, -38.62, 73.19), V(317.23, -38.62, 74.41), V(316.53, -38.62, 75.50), V(315.83, -38.62, 76.62),
    V(314.93, -38.62, 77.69), V(313.85, -38.62, 78.46), V(313.60, -38.62, 78.10),
}
function C.part2(pos)
    -- the landing pit (bones, water): east end has a narrow gap
    if pos.y < -37 and pos.x > 295 and pos.x < 309.5 and pos.z > 44 and pos.z < 60 then
        local gap = V(307.2, -38.45, 47.4)
        if d2(gap, pos) < 1.5 then
            return { name = "the narrow gap", pos = gap, dist = 0, no_route = true, key = "ch10_gap", face = V(308.36, -37.4, 48.11),
                tip = "It is right here. I turned you to it. Hold F for 1 second: Leon squeezes through by himself. Then press N." }
        end
        return cave("the narrow gap at the east end of this pit", gap, pos,
            "The Green Herb is near the south side. Hold W that way, then press N again.")
    end
    -- past the gap: north along the water passage to the crawl hole (GmInterstice1Motion
    -- _OnlyCrouch = true: F works only while crouched, 11/26 user held F standing).
    -- 11/26 user test: "No walking route found to the water passage north" (no
    -- walking map in this cave) and the straight lines ran into rock. Now a fixed
    -- route along Claude's own recorded walk of 11/21 (trail.txt), checked with rays.
    if pos.y < -37 and pos.x > 309.5 and pos.x < 325 and pos.z > 44 and pos.z < 80 then
        -- still inside the squeeze (Leon moves by himself, camera locked)
        if pos.x < 315.9 and pos.z < 52.9 and pos.x > 309.5 and d2(pos, V(316.26, -38.39, 53.09)) > 0.8 then
            return { name = "the narrow gap", pos = V(316.26, -38.39, 53.09), dist = 0, no_route = true, key = "ch10_gap2",
                tip = "You are squeezing through it now. Keep holding W until Leon is out, then press N." }
        end
        local hole = V(313.6, -38.6, 78.1)
        if d2(hole, pos) < 1.2 then
            return { name = "the low crawl hole", pos = hole, dist = 0, no_route = true, key = "ch10_crawl",
                face = V(312.7, -38.1, 77.8),
                tip = "I turned you to it. Press E to crouch first: this hole only works while crouching. Then hold F for 1 second, and Leon crawls through by himself. Then press N." }
        end
        return { name = "the low crawl hole", pos = hole, dist = d2(hole, pos), key = "ch10_cavepath",
            fixed_path = C.CAVE_PATH, face = V(311.6, -38.1, 77.3),
            tip = "Walking you along the water passage north to a low hole.",
            after = "Press E to crouch first: this hole only works while crouching. Then hold F for 1 second, and Leon crawls through by himself. Then press N." }
    end
    -- the old prison room: crown, herb, ladder (map data works from here)
    if pos.y < -33 and pos.x > 255 and pos.x < 310 then
        local crown = item_near("Elegant Crown", pos, 60)
        if crown then
            local c = {} for k, v in pairs(crown) do c[k] = v end
            c.tip = "A treasure. Press F at F ready."
            return c
        end
        -- 11/26: the herb and the ladder are past a narrow squeeze gap (gm91_004,
        -- hold F 1 s). The route ran into its blocker. If the way there goes
        -- through the gap, stop in front of it first.
        local GAP = V(270.19, -37.19, 63.17)
        local function through_gap(goal)
            local okn, pts = pcall(RE4Access.route.nav_points, pos, goal)
            if not okn or not pts then return false end
            for _, q in ipairs(pts) do if d2(q, GAP) < 1.2 and math.abs(q.y - GAP.y) < 1.5 then return true end end
            return false
        end
        local herb0 = item_near("Yellow Herb", pos, 25)
        local next_goal = (herb0 and pos.x < 280) and V(270.4, -37.2, 67.85) or V(274.65, -37.19, 64.81)
        if d2(pos, GAP) > 1.6 and through_gap(next_goal) then
            return spot("the narrow gap", V(269.05, -37.19, 62.28), V(270.19, -36.4, 63.17),
                "Hold F for 1 second: Leon squeezes through by himself. Then press N.", "ch10_gap3", pos, { spoken = "narrow gap" })
        end
        local herb = item_near("Yellow Herb", pos, 12)
        if herb and pos.x < 280 then
            return spot("the Yellow Herb on the crate", V(270.4, -37.2, 67.85), V(271.4, -36.5, 67.7),
                "Tap W once, then press F. Then press N for the ladder.", "ch10_herb", pos)
        end
        return spot("the ladder up", V(274.65, -37.19, 64.81), V(274.93, -36.2, 64.40),
            "Press F to climb up. Then press N.", "ch10_ladder", pos)
    end
    -- sewers + laboratory
    if pos.y > -33 and pos.y < -15 and pos.x > 120 and pos.x < 230 and pos.z < 30 then
        local _, lv = gfind("gm84_875", 157.9, -13.2)
        local _, br = gfind("gm84_804", 147.9, -28.4)
        if lv == false then
            return spot("the lever that opens the laboratory", V(158.6, -30.4, -13.7), V(157.9, -29.4, -13.2),
                "Press F to pull it. Then press N.", "ch10_lablever", pos)
        end
        if br == false then
            return spot("the circuit breaker", V(147.25, -30.4, -28.3), V(147.9, -29.4, -28.4),
                "Press F. Verdugo comes after this: then press N right away.", "ch10_breaker", pos)
        end
        -- 11/26: the First Aid Spray in a chest (177.2,-10.8) sits behind shutter gm80_770,
        -- which opens when the breaker is on. Optional, but handy before Verdugo.
        if br == true then
            local spray = item_near("First Aid Spray", pos, 45)
            if spray and spray.pos.x > 170 and spray.pos.x < 182 and spray.pos.z > -14 and spray.pos.z < -8 then
                -- 11/26: the tall cabinet (gm Locker at 177.37,-12.11) opens to the WEST; the
                -- spray and gunpowder lie on its shelf 1.2 m north of its middle. From the
                -- route's end (176.2,-11.7) the frame blocks them: no F. Stand in front of them.
                local _, cdone = gfind("Locker", 177.37, -12.11, 0.6)
                pcall(function() for _, t in ipairs(G.scan_things(V(177.37, -29.65, -12.11), 0.5)) do cdone = G.gimmick_done(t.go) end end)
                if cdone then
                    return spot("the First Aid Spray on the cabinet shelf", V(176.35, -30.4, -10.9), V(177.17, -29.55, -10.77),
                        "Press F to take it. Then F again for the gunpowder next to it. Then press N.", "ch10_spray2", pos, { spoken = "First Aid Spray" })
                end
                return spot("the tall cabinet with the First Aid Spray", V(176.3, -30.4, -12.1), V(177.37, -29.2, -12.11),
                    "Hold F for 1 second to open it. Then press N: I put you in front of the spray.", "ch10_cabinet", pos, { spoken = "cabinet" })
            end
        end
        local _, sh = gfind("gm80_799", 131.6, -17.2)
        if sh == false and pos.x < 140 then
            return spot("the crank of the closed shutter", V(129.7, -30.4, -17.3), V(130.3, -29.4, -16.6),
                "Hold F for about 15 seconds to turn it. When I say Evade, press E, then hold F again. Then press N.", "ch10_crank", pos)
        end
        -- the elevator: car comes down by itself, then the button inside
        local car_down = false
        pcall(function()
            for _, t in ipairs(G.scan_things(V(207, -30.4, -17.5), 4)) do
                if t.go:call("get_Name") == "BoxButton" and t.go:call("get_Transform"):call("get_Position").y < -25 then car_down = true end
            end
        end)
        if car_down then
            return spot("the elevator button", V(207.5, -30.4, -17.7), V(206.2, -29.3, -17.6),
                "Press F. The elevator goes up and the chapter ends.", "ch10_button", pos)
        end
        return spot("the elevator door", V(208.0, -30.4, -16.0), V(208.8, -29.4, -18.4),
            "Wait here. The elevator takes about a minute to come down. Verdugo attacks: press E when I say Evade. When I say Elevator is here, press N.", "ch10_elevator", pos)
    end
end

function C.step(pos)
    if not pos then return nil end
    local obj = tostring(G.objective_text and G.objective_text() or ""):lower()
    if obj:find("throne room", 1, true) then
        -- the start ladder stays with the older handler (it runs first)
        if pos.x < 140 and pos.y < 30 and pos.z < 60 and pos.z > 30 then
            -- Grand Hall: go straight on to the first lever (the route opens the gate)
        end
        return C.part1(pos)
    elseif obj:find("surface", 1, true) then
        return C.part2(pos)
    end
end

if not G.hole_step_before_ch10 then G.hole_step_before_ch10 = G.hole_step end
G.hole_step = function(pos)
    local ok, st = pcall((RE4Access.ch10 or C).step, pos)
    if ok and st then return st end
    if not ok then log.info("[RE4Access] ch10 step error: " .. tostring(st)) end
    return G.hole_step_before_ch10(pos)
end

RE4Access.ch10 = C
log.info("[RE4Access] ch10 steps loaded")
return C
