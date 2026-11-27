-- RE4 Access: mine cart rides (Chapter 11). Built from Claude's live rides on 11/26:
--  * Leaning: the cart's Tilt goes from -0.5 to 0.5 in turns. Tilt above zero: hold A;
--    below zero: hold D (verified: with the opposite keys the cart flipped, with these it
--    held). The mod says "Lean A" / "Lean D" and "Straight".
--  * Track switches (GmRailSwitch) must be shot before the cart reaches them, or the cart
--    runs into a dead end and the game ends. Barricades (GmRailCarBarricade) and piles of
--    red oil drums (GmOilDrum) ahead must be shot too. The chainsaw man rides alongside.
--  * Aiming in the cart uses the game's VehicleCameraController, not the player camera.
--    While L is held, this turns that camera to the most urgent target.
local G = RE4Access.game
if not G then return {} end
local M = { said = {}, lean = nil, lean_at = 0, intro = false, at = 0 }
local function say(t, i) RE4Access.speak(t, i ~= false) end

local function scan()
    local now = os.clock()
    if M.cache and now - (M.cache_at or 0) < 2 then return M.cache end
    M.cache_at = now
    local out = { cars = {}, hz = {} }
    pcall(function()
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject")
                local n = go:call("get_Name")
                if n:find("Player_RailCar", 1, true) then
                    local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmRailCar"))
                    if c then out.cars[#out.cars + 1] = c end
                    return
                end
                local sw = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmRailSwitch"))
                local br = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmRailCarBarricade"))
                local od = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmOilDrum"))
                if sw or br or od then
                    out.hz[#out.hz + 1] = { go = go, core = core, sw = sw, kind = sw and "switch" or br and "barricade" or "drums" }
                end
            end) end
        end
    end)
    M.cache = out
    return out
end

-- The cart Leon rides now (rider ch0a0z0_body, not finished), or nil.
function M.riding()
    for _, c in ipairs(scan().cars) do
        local ok, yes = pcall(function()
            local u = c:get_field("_User")
            return u and u:call("get_Name") == "ch0a0z0_body" and not c:get_field("<Finish>k__BackingField")
        end)
        if ok and yes then return c end
    end
end

-- Hazards ahead that still need a shot: { kind, pos, dist, key }
function M.hazards(car, pos)
    local out = {}
    local mv
    pcall(function() mv = car:get_field("<MoveSpeedPerSec>k__BackingField") end)
    for _, h in ipairs(scan().hz) do
        pcall(function()
            local need
            if h.sw then need = h.sw:get_field("_Switch") ~= h.sw:get_field("_SuccessSwitch")
            else need = not h.core:call("get_Context"):call("hasDoneForMap") end
            if not need then return end
            local q = h.go:call("get_Transform"):call("get_Position")
            local dx, dz = q.x - pos.x, q.z - pos.z
            local d = math.sqrt(dx * dx + dz * dz)
            local ahead = not mv or (dx * mv.x + dz * mv.z) > 0
            local range = h.kind == "switch" and 60 or 45
            if ahead and d < range and d > (h.kind == "switch" and 0 or 8) then
                -- switches: the hit boxes sit 1.3 m above the base (measured)
                out[#out + 1] = { kind = h.kind, pos = { x = q.x, y = q.y + (h.kind == "switch" and 1.3 or 0.8), z = q.z }, dist = d, key = tostring(h.go:get_address()) }
            end
        end)
    end
    -- 11/26 test: an enemy standing ON the track ahead wrecks the cart (died twice at
    -- (592,-190) on ride 2; the ride that shot it lived). Straight ahead = within 12 degrees
    -- of the cart's heading, 8-40 m away.
    if mv then
        local sp = math.sqrt(mv.x * mv.x + mv.z * mv.z)
        if sp > 1 then
            pcall(function()
                for _, e in ipairs(G.enemies(pos, 40)) do
                    local h = 0
                    pcall(function() h = e.ctx:call("get_HitPoint"):call("get_CurrentHitPoint") end)
                    local dx, dz = e.pos.x - pos.x, e.pos.z - pos.z
                    local d = math.sqrt(dx * dx + dz * dz)
                    if h > 0 and d > 8 and (dx * mv.x + dz * mv.z) / (d * sp) > 0.978 and math.abs(e.pos.y - pos.y) < 3 then
                        out[#out + 1] = { kind = "track enemy", pos = { x = e.pos.x, y = e.pos.y + 1.4, z = e.pos.z }, dist = d, key = "te" .. tostring(e.key) }
                    end
                end
            end)
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- What L should aim at: a chainsaw man within 25 m first, then hazards, then the nearest enemy.
function M.aim_point(car, pos)
    local saw, best
    pcall(function()
        for _, e in ipairs(G.enemies(pos, 35)) do
            local h = 0
            pcall(function() h = e.ctx:call("get_HitPoint"):call("get_CurrentHitPoint") end)
            if h > 0 then
                local tn = ""
                pcall(function() tn = e.ctx:get_type_definition():get_name() end)
                if tn:find("^Ch1d1") and e.dist < 25 and (not saw or e.dist < saw.dist) then saw = e end
                if not best or e.dist < best.dist then best = e end
            end
        end
    end)
    local hz = M.hazards(car, pos)[1]
    if hz and (not saw or hz.dist < 30) then return hz.pos, hz.kind end
    if saw then return { x = saw.pos.x, y = saw.pos.y + 1.5, z = saw.pos.z }, "chainsaw man" end
    if best then return { x = best.pos.x, y = best.pos.y + 1.4, z = best.pos.z }, "enemy" end
end

local NAMES = { switch = "Track switch ahead! Hold L and press K, or the cart crashes.",
    barricade = "Barricade on the track ahead. Hold L and press K.",
    drums = "Red barrels on the track ahead. Hold L and press K to blow them up early.",
    ["track enemy"] = "Enemy on the track ahead! Hold L and press K, or the cart crashes into him." }

function M.update(now)
    if now - M.at < 0.1 then return end
    M.at = now
    local car = M.riding()
    if not car then
        if M.intro then M.intro = false; M.lean = nil; M.saw_told = nil end
        M.start_at = nil
        return
    end
    if G.is_paused and G.is_paused() then return end
    local pos = G.player_pos()
    if not pos then return end
    if not M.intro then
        -- wait 1.5 s: the camera-change message would cut the line off (11/26 test)
        M.start_at = M.start_at or now
        if now - M.start_at < 1.5 then return end
        M.intro = true
        say("Mine cart. It rolls by itself. When I say Lean A or Lean D, hold that key until I say Straight. Hold L: I aim at track switches, barricades, red barrels and enemies. Press K to shoot. Every track switch must be shot.")
    end
    -- leaning
    local tilt = 0
    pcall(function() tilt = car:get_field("<Tilt>k__BackingField") end)
    local want = tilt > 0.12 and "A" or tilt < -0.12 and "D" or (math.abs(tilt) < 0.05 and "straight" or M.lean)
    if want ~= M.lean and now - M.lean_at > 0.3 then
        if want == "A" then say("Lean A") elseif want == "D" then say("Lean D") elseif M.lean then say("Straight", false) end
        M.lean, M.lean_at = want, now
    end
    -- enemies: the chainsaw man rides alongside (Ch1d1), others jump on or shoot crossbows.
    -- 11/26 test: died silently 30 s after the last cue - only "Fire" (L held) named them.
    do
        local saw, near = nil, 0
        pcall(function()
            for _, e in ipairs(G.enemies(pos, 25)) do
                local h = 0
                pcall(function() h = e.ctx:call("get_HitPoint"):call("get_CurrentHitPoint") end)
                if h > 0 then
                    local tn = ""
                    pcall(function() tn = e.ctx:get_type_definition():get_name() end)
                    if tn:find("^Ch1d1") and e.dist < 18 then saw = e end
                    if e.dist < 15 then near = near + 1 end
                end
            end
        end)
        if saw and now - (M.saw_at or -10) > 3 then
            M.saw_at = now
            -- 11/26 evening: 5000 HP; if he still lives at about (593,-191) on ride 2 he
            -- wrecks the cart = game over (3 test deaths, full health). Keep L held.
            local pct
            pcall(function()
                local h = saw.ctx:call("get_HitPoint")
                pct = math.floor(h:call("get_CurrentHitPoint") * 100 / math.max(1, h:call("get_DefaultHitPoint")) + 0.5)
            end)
            if not M.saw_told then
                M.saw_told = true
                say("Chainsaw man beside you! Keep L held the whole time and press K again and again. He must die soon, or he wrecks the cart. A shotgun or magnum hits hardest.", true)
            else
                say("Chainsaw " .. (pct and (pct .. " percent") or "") .. ". Keep shooting!", true)
            end
        elseif not saw and near > 0 and now - (M.near_at or -10) > 4 and not reframework:is_key_down(0x4C) then
            M.near_at = now
            say(near == 1 and "Enemy close. Hold L." or (near .. " enemies close. Hold L."), false)
        end
    end
    -- hazards: once each
    for _, h in ipairs(M.hazards(car, pos)) do
        if not M.said[h.key] then
            M.said[h.key] = true
            if RE4Access.sound then RE4Access.sound("stopf") end
            say(NAMES[h.kind], true)
            log.info(string.format("[RE4Access] cart hazard %s %.0f m", h.kind, h.dist))
        end
    end
end

-- L held in the cart: turn the cart's camera to the target every frame.
function M.aim_frame()
    if not reframework:is_key_down(0x4C) then M.fire_at = nil return end
    local car = M.riding()
    if not car then return end
    local pos = G.player_pos()
    if not pos then return end
    local now = os.clock()
    if not M.aim_cache or now - (M.aim_at or 0) > 0.2 then
        M.aim_at = now
        M.aim_cache, M.aim_name = M.aim_point(car, pos)
    end
    local t = M.aim_cache
    if not t then return end
    pcall(function()
        local vc = sdk.get_managed_singleton("chainsaw.CameraSystem"):call("get_MainCameraController"):get_field("_CameraControllerArray"):get_elements()[3]
        if vc:get_type_definition():get_name() ~= "VehicleCameraController" then return end
        local dx, dz = t.x - pos.x, t.z - pos.z
        vc:set_field("_Yaw", math.atan(dx, dz))
        vc:set_field("_Pitch", math.atan(t.y - (pos.y + 1.5), math.sqrt(dx * dx + dz * dz)))
    end)
    -- "Fire" when the line is clear, at most once a second
    if not M.fire_at or now - M.fire_at > 1.0 then
        local okc, clear = pcall(G.clear_shot, { x = pos.x, y = pos.y + 1.5, z = pos.z }, t)
        if okc and clear then
            M.fire_at = now
            say("Fire, " .. tostring(M.aim_name), true)
        end
    end
end

if not RE4Access.minecart_hooked then
    RE4Access.minecart_hooked = true
    re.on_frame(function()
        local m = RE4Access.minecart
        if not m then return end
        pcall(m.update, os.clock())
        pcall(m.aim_frame)
    end)
end

-- the boat help must not run in the cart (it said "In the boat. W goes forward...")
-- 11/26 test: at the end of the ride the cart is "finished" but the camera is still the
-- vehicle one, and the boat code woke up and started a "water route". Keep it off while
-- Leon is within 8 m of any player cart.
function M.near_cart()
    local pos = G.player_pos()
    if not pos then return false end
    for _, c in ipairs(scan().cars) do
        local ok, near = pcall(function()
            local q = c:call("get_GameObject"):call("get_Transform"):call("get_Position")
            return math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) < 8 and math.abs(q.y - pos.y) < 4
        end)
        if ok and near then return true end
    end
    return false
end
if G.update_boat then
    G.update_boat_before_cart = G.update_boat_before_cart or G.update_boat
    G.update_boat = function(now, ...)
        -- 11/26 evening: after "Continue" mid-ride the cart list was stale for 2 s and the
        -- boat help spoke again. Chapter 11 has no boat at all: keep it off there.
        local okc, ch = pcall(G.chapter)
        if okc and ch == 24200 then G.in_boat = false return end
        local okr, car = pcall(M.riding)
        local okn, near = pcall(M.near_cart)
        if (okr and car) or (okn and near) then G.in_boat = false return end
        return G.update_boat_before_cart(now, ...)
    end
end

RE4Access.minecart = M
log.info("[RE4Access] minecart loaded")
return M
