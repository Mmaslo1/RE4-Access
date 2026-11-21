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
    return { name = name .. ", " .. where, pos = p, dist = d2(p, pos), no_route = true, key = "ch10_cave",
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
            "Hold W and tap F to jump down. Then press N.", "ch10_drop", pos, { spoken = "edge" })
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
local CAVE = { -- pocket past the narrow gap, north to the crawl hole
    V(321.4, -38.6, 55.5), V(321.8, -38.6, 61.9), V(320.4, -38.6, 67.0), V(317.8, -38.6, 73.2), V(313.9, -38.6, 78.3),
}
function C.part2(pos)
    -- the landing pit (bones, water): east end has a narrow gap
    if pos.y < -37 and pos.x > 295 and pos.x < 309.5 and pos.z > 44 and pos.z < 60 then
        local gap = V(307.2, -38.45, 47.4)
        if d2(gap, pos) < 1.5 then
            return { name = "the narrow gap", pos = gap, dist = 0, no_route = true, key = "ch10_gap",
                tip = "It is right here, east of you. Face east and hold W: Leon squeezes through by himself. Then press N." }
        end
        return cave("the narrow gap at the east end of this pit", gap, pos,
            "The Green Herb is near the south side. Hold W that way, then press N again.")
    end
    -- past the gap: north along the water passage to the crawl hole
    if pos.y < -37 and pos.x > 309.5 and pos.x < 325 and pos.z > 44 and pos.z < 80 then
        local hole = V(313.6, -38.6, 78.1)
        if d2(hole, pos) < 2.0 then
            return { name = "the low crawl hole", pos = hole, dist = 0, no_route = true, key = "ch10_crawl",
                tip = "Press E to crouch, face west, and hold W. Leon crawls through. Then press N." }
        end
        local i = 1
        for k, p in ipairs(CAVE) do if d2(p, pos) < d2(CAVE[i], pos) then i = k end end
        if d2(CAVE[i], pos) < 2.5 and i < #CAVE then i = i + 1 end
        if pos.z < 53 and pos.x > 319 and pos.z < 50 then i = 1 end
        return cave("the water passage north", CAVE[i], pos)
    end
    -- the old prison room: crown, herb, ladder (map data works from here)
    if pos.y < -33 and pos.x > 255 and pos.x < 310 then
        local crown = item_near("Elegant Crown", pos, 60)
        if crown then
            local c = {} for k, v in pairs(crown) do c[k] = v end
            c.tip = "A treasure. Press F at F ready."
            return c
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
