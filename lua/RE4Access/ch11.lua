-- RE4 Access: Chapter 11 step by step (N). Claude PLAYED these parts live on 11/26 and took
-- every spot from the game (tools/ch11/notes.txt). Chapter id 24200. The objective text
-- "Make your way to the surface" is the same as Chapter 10 part 2, so this file goes by the
-- chapter id and runs before ch10.lua.
-- Verified: start -> quarry lever -> Dynamite -> blast wall (+ escape run) -> story event ->
-- two giants -> boost Luis -> mine cart -> ride 1 (switch) -> second cart -> ride 2 ->
-- hive elevator -> Krauser (all played to the chapter end).
local G = RE4Access.game
if not G then return {} end
local C = {}

local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
local function V(x, y, z) return { x = x, y = y, z = z } end

local function gm_by_name(part)
    local found, core0
    pcall(function()
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core and not found then
                pcall(function()
                    local go = core:call("get_GameObject")
                    if go:call("get_Name"):find(part, 1, true) then found, core0 = go, core end
                end)
            end
        end
    end)
    return found, core0
end
local function gm_done(part)
    local _, core = gm_by_name(part)
    if not core then return nil end
    local ok, d = pcall(function() return core:call("get_Context"):call("hasDoneForMap") end)
    if not ok then return nil end
    return d == true
end

local function has_key_item(name)
    local has = false
    pcall(function()
        local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
        for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
            local c = e:get_field("value")
            if c and c:get_type_definition():get_name() == "KeyItemInventoryController" then
                local l = c:call("getInventoryItems")
                for i = 0, l:call("get_Count") - 1 do
                    local id = l:call("get_Item", i):get_field("<Item>k__BackingField"):get_field("_ItemId")
                    if RE4Access.menu.clean(mg:call(nil, mm:call("getItemNameMsgId", id))) == name then has = true end
                end
            end
        end
    end)
    return has
end

local function spot(name, stand, face, after, key, pos, extra)
    local t = { name = name, pos = stand, dist = d2(stand, pos), face = face, latch = true, fname = name,
        spoken = name:gsub("^the ", ""), after = after, key = key, tip = "" }
    if extra then for k, v in pairs(extra) do t[k] = v end end
    return t
end

-- The escape run after lighting the dynamite (verified: alive at full health at the end).
C.ESCAPE = { V(146.5, -12.3, -5.5), V(148.6, -13.0, -8.4), V(152.0, -14.1, -12.0), V(155.0, -14.4, -13.0), V(158.0, -14.8, -13.0) }

local function blast_lit()
    local go, core = gm_by_name("gm82_512")
    if not go then return false end
    local pos = G.player_pos()
    if not pos or d2(pos, V(145.0, -10.8, -1.8)) > 40 then return false end
    -- the wall reports "done" as soon as the Dynamite is placed; it is really blown when its
    -- routine (_Rno) reaches 5 (11/26 test: 1 while the fuse burns, 5 after the blast)
    local ok, lit = pcall(function()
        local bw = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmBlastWall"))
        return bw:get_field("_IsIgnition") and (tonumber(bw:get_field("_Rno")) or 0) < 5
    end)
    return ok and lit
end

-- The rock has been looked at: the lever's trigger is active (game truth, when loaded),
-- or the key item list opened while Leon stood at the rock (speech hook below).
local function lever_active()
    local go = gm_by_name("gm84_838")
    if not go then return nil end
    local ok, act = pcall(function()
        local ih = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InteractHolder"))
        for _, t in ipairs(ih:get_field("_Triggers"):get_elements()) do
            if t:get_field("_Trigger"):get_field("<Activate>k__BackingField") ~= 0 then return true end
        end
        return false
    end)
    return ok and act
end
if not RE4Access.ch11_speak_hooked and RE4Access.speak then
    RE4Access.ch11_speak_hooked = true
    local sp = RE4Access.speak
    RE4Access.speak = function(text, ...)
        if type(text) == "string" and text:find("^Use a key item") then
            pcall(function()
                local p0 = G.player_pos()
                if p0 and math.sqrt((p0.x - 145.4) ^ 2 + (p0.z + 2.5) ^ 2) < 4 then G.ch11_rock_seen = true end
            end)
        end
        return sp(text, ...)
    end
end

local function giants_alive()
    local out = {}
    pcall(function()
        local list = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
        for i = 0, list:call("get_Count") - 1 do
            local e = list:call("get_Item", i)
            if e:call("get_KindID") == 200006 then
                local h = e:call("get_HitPoint")
                if h:call("get_CurrentHitPoint") > 0 then out[#out + 1] = { max = h:call("get_DefaultHitPoint"), hp = h:call("get_CurrentHitPoint") } end
            end
        end
    end)
    return out
end

-- 11/26 evening: L aims at the explosive Luis planted on the armored giant's back
-- (gm82_586), when it rides on a live armored giant 5-35 m away and is in clear view.
-- Hooked through G.drum_target, which the aim code looks up on every L press.
local function giant_bomb(pos)
    local okc, ch = pcall(G.chapter)
    if not (okc and ch == 24200) then return nil end
    local go, core = gm_by_name("gm82_586")
    if not go then return nil end
    if core:call("get_Context"):call("hasDoneForMap") == true or go:call("get_DrawSelf") == false then return nil end
    local bp = go:call("get_Transform"):call("get_Position")
    local on_giant = false
    local list = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
    for i = 0, list:call("get_Count") - 1 do
        local e = list:call("get_Item", i)
        if e:call("get_KindID") == 200006 then
            local h = e:call("get_HitPoint")
            if h:call("get_CurrentHitPoint") > 0 and h:call("get_DefaultHitPoint") < 15000 then
                local q = e:call("get_Position")
                if math.sqrt((q.x - bp.x) ^ 2 + (q.z - bp.z) ^ 2) < 3.5 and bp.y > q.y + 2.5 then on_giant = true end
            end
        end
    end
    if not on_giant then return nil end
    local ap = { x = bp.x, y = bp.y, z = bp.z }
    local d = math.sqrt((ap.x - pos.x) ^ 2 + (ap.z - pos.z) ^ 2)
    if d < 5 or d > 35 then return nil end
    if G.clear_shot then
        local eye = { x = pos.x, y = pos.y + 1.4, z = pos.z }
        local _, hd = G.clear_shot(eye, ap)
        local full = math.sqrt((ap.x - eye.x) ^ 2 + (ap.y - eye.y) ^ 2 + (ap.z - eye.z) ^ 2)
        if hd and hd < full - 0.7 then return nil end
    end
    return { name = "Explosive on the giant's back", pos = ap, dist = d, key = "ch11_giant_bomb", fixed = true, go = go, why = "" }
end
C.giant_bomb = giant_bomb
function C.armored_near_bomb(bp)
    local list = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
    for i = 0, list:call("get_Count") - 1 do
        local e = list:call("get_Item", i)
        if e:call("get_KindID") == 200006 then
            local h = e:call("get_HitPoint")
            if h:call("get_CurrentHitPoint") > 0 and h:call("get_DefaultHitPoint") < 15000 then
                local q = e:call("get_Position")
                if math.sqrt((q.x - bp.x) ^ 2 + (q.z - bp.z) ^ 2) < 3.5 then return true end
            end
        end
    end
    return false
end
if G.drum_target and not G.drum_target_before_ch11 then
    G.drum_target_before_ch11 = G.drum_target
    G.drum_target = function(pos)
        local ok, t = pcall(function() return (RE4Access.ch11 and RE4Access.ch11.giant_bomb or giant_bomb)(pos) end)
        if ok and t then return t end
        return G.drum_target_before_ch11(pos)
    end
end

function C.step(pos)
    local obj = tostring(G.objective_text and G.objective_text() or ""):lower()
    -- right after the opening scene the game has no objective yet (11/26 test)
    if obj == "" or obj == "nil" then obj = "make your way to the surface" end

    -- ---------- the two giants ----------
    if obj:find("giant", 1, true) then
        local g = giants_alive()
        local plain, armored
        for _, x in ipairs(g) do if x.max >= 15000 then plain = x else armored = x end end
        if plain then
            return { name = "the two giants", pos = pos, dist = 0, no_route = true, key = "ch11_giant1",
                tip = "Two giants. The one WITHOUT armor can be hurt now: keep your distance, hold L, press K. Press U to hear its health. The armored one takes no damage yet; keep away from it. Press N when the first one is dead." }
        end
        if armored then
            -- 11/26 evening: the armored giant DOES lose a little health before its armor is
            -- off (10740 of 12000 with the explosive still unused), so go by the explosive
            -- gm82_586: used up (done), gone or hidden = armor off.
            local armor_off = false
            pcall(function()
                local go, core = gm_by_name("gm82_586")
                if not go then armor_off = true return end
                if core:call("get_Context"):call("hasDoneForMap") == true then armor_off = true return end
                if go:call("get_DrawSelf") == false then armor_off = true end
            end)
            if armor_off then
                return { name = "the armored giant, its armor is off", pos = pos, dist = 0, no_route = true, key = "ch11_giant3",
                    tip = "It can be hurt now. Keep 8 meters away: run with Shift and W when it comes close, then turn, hold L and press K. Press U for its health." }
            end
            -- 11/26 evening replay: Luis jumped on it by himself during the first fight, and
            -- shooting where L aims (the mod calls it "the padlock" on its armor) took it
            -- from 10740 to 0 from 8-14 m; the explosive was never needed. No stand spot.
            return { name = "the armored giant", pos = pos, dist = 0, no_route = true, key = "ch11_giant2",
                tip = "Keep 8 to 14 meters away from it: when it comes close, run with Shift and W, then turn back. Hold L: I aim at the padlock on its armor, or at the explosive on its back if Luis planted one. Press K, again and again. Press U for its health." }
        end
    end

    -- ---------- Krauser (knife only) ----------
    if obj:find("krauser", 1, true) then
        return { name = "Krauser", pos = pos, dist = 0, no_route = true, key = "ch11_krauser",
            tip = "Knife fight. Hold Space and press K to slash, again and again; stay close. When I say Evade or Lunge, press the key I name. Press U for his health. At about a quarter of his health he leaves and the chapter ends." }
    end

    if not obj:find("surface", 1, true) then return nil end

    -- in a mine cart: minecart.lua talks (lean, switches, barricades, barrels)
    if RE4Access.minecart and RE4Access.minecart.riding and RE4Access.minecart.riding() then
        return { name = "the mine cart ride", pos = pos, dist = 0, no_route = true, key = "ch11_cart",
            tip = "Hold A or D when I say Lean A or Lean D. Hold L and press K on every track switch, barricade and red barrel I call. The chainsaw man rides beside you: shoot him too." }
    end

    -- riding the hive elevator up (11/26 evening: N there said "the mine cart")
    if math.abs(pos.x - 178.2) < 3 and math.abs(pos.z - 89.5) < 3 and pos.y > -73.3 and pos.y < -3 then
        return { name = "the elevator ride", pos = pos, dist = 0, no_route = true, key = "ch11_lift",
            tip = "The elevator is going up. Wait: a long cutscene comes, then Krauser. Knife fight: hold Space and press K." }
    end
    -- ---------- the insect hive cave after the second ride: the elevator ----------
    if pos.y < -60 then
        return spot("the elevator button", V(178.4, -74.5, 89.6), V(177.87, -73.47, 90.11),
            "Walk into the elevator, then hold F for 1 second on the button. It goes up; a cutscene follows. The yellow sacks on the ceiling are insect hives: you can ignore them.", "ch11_elevator", pos, { spoken = "elevator button" })
    end

    -- ---------- the stop between the two rides: the second cart ----------
    if pos.x > 150 and pos.x < 235 and pos.z > -235 and pos.z < -140 and pos.y > -40 then
        return spot("the second mine cart, up the stairs", V(196.0, -22.6, -167.9), V(198.0, -22.2, -167.0),
            "Hold F for 1 second to get in. On this ride: lean right at the first big turn, a barricade and piles of red barrels to shoot, a chainsaw man beside you, and a track switch near the end.", "ch11_cart2", pos, { spoken = "second mine cart" })
    end

    -- ---------- after the giants: boost Luis, then the mine cart ----------
    if pos.z > 30 or gm_done("gm91_006_00_2") then
        if gm_done("gm91_006_00_2") == false then
            return spot("the wall where you boost Luis up", V(150.35, -11.7, 49.97), V(150.5, -11.0, 50.71),
                "Hold F for 1 second: Leon boosts Luis over the wall. Luis opens the gate from the other side. Then press N.", "ch11_coop", pos, { spoken = "wall" })
        end
        if G.in_boat then
            return { name = "the mine cart ride", pos = pos, dist = 0, no_route = true, key = "ch11_cart",
                tip = "The cart rolls by itself. A and D lean into turns. A track switch comes up about a minute in: hold L and press K to hit it, or the cart runs into a dead end. Shoot enemies on the side tracks with L and K." }
        end
        return spot("the mine cart", V(106.95, -3.63, 74.22), V(105.33, -4.5, 70.54),
            "Hold F for 1 second to get in. The ride starts by itself. A and D lean, L and K shoot. Watch for the track switch: shoot it.", "ch11_railcar", pos, { spoken = "mine cart" })
    end

    -- ---------- the dynamite wall ----------
    local wall = gm_done("gm82_512")
    do  -- blown only at routine 5 (see blast_lit)
        local go = gm_by_name("gm82_512")
        if go then pcall(function()
            local bw = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmBlastWall"))
            wall = (tonumber(bw:get_field("_Rno")) or 0) >= 5
        end) end
    end
    -- far away the wall is not loaded (nil): it is still shut unless Leon is past it (north)
    if wall == nil then wall = pos.z > 5 and pos.x < 146 end
    if wall == false then
        if blast_lit() then
            return { name = "RUN from the blast", pos = C.ESCAPE[#C.ESCAPE], dist = d2(C.ESCAPE[#C.ESCAPE], pos), key = "ch11_escape",
                fixed_path = C.ESCAPE, face = C.ESCAPE[#C.ESCAPE],
                tip = "Hold Shift and W now! Follow my turns into the tunnel.", after = "Safe. Wait for the blast, then press N." }
        end
        if has_key_item("Dynamite") then
            return spot("the painted rock blocking the tunnel", V(145.3, -12.0, -3.05), V(145.46, -11.16, -1.99),
                "Press F. Pick Dynamite with Enter, then Enter on Use. Then press N AT ONCE and hold Shift and W: the blast comes in 6 seconds and kills you if you are close.", "ch11_wall", pos, { spoken = "painted rock" })
        end
        -- 11/26 evening replay: the lever's touch zone is a 1 m ball at the panel; the old
        -- stand (109.6,-14.44) was 1.33 m away = no prompt. (110.2,-14.7) gives the prompt.
        -- It is a HOLD F (1 s) lever. Pressing F at the rock first is NOT needed (it sets no
        -- game flag), so N goes straight to the lever.
        if gm_done("gm84_838") ~= true then
            return spot("the lever that lowers the quarry bridge", V(110.2, -4.88, -14.7), V(109.99, -4.2, -15.72),
                "Hold F down for 1 second to pull it. If F picks up money lying there first, hold F again. Then press N for the Dynamite.", "ch11_lever", pos, { spoken = "lever" })
        end
        -- Leon still up in the lever hut: the hut's lower door is locked from inside and the
        -- route picks it, so first send him out to the bridge start.
        if pos.y > -6.2 and pos.x > 107 and pos.x < 117 and pos.z > -17.5 and pos.z < -10 then
            return spot("the bridge start", V(101.5, -7.3, -27.7), V(104.0, -6.5, -36.0),
                "The bridge is down. Press N again for the Dynamite.", "ch11_bridge", pos, { spoken = "bridge" })
        end
        return spot("the Dynamite on the boxes", V(110.92, -5.15, -53.44), V(110.21, -3.71, -53.75),
            "Press F to take it. Then press N to go back to the blocked tunnel.", "ch11_dynamite", pos, { spoken = "Dynamite" })
    end

    -- ---------- wall open: the story event before the giants ----------
    return spot("the story event past the tunnel", V(132.9, -7.8, 26.1), V(133.85, -6.96, 26.5),
        "Press F. A cutscene starts, then a fight with two giants. Then press N.", "ch11_event", pos, { spoken = "story event" })
end

-- Runs before Chapter 10's steps (same objective text).
if not G.hole_step_before_ch11 then G.hole_step_before_ch11 = G.hole_step end
G.hole_step = function(pos)
    local okc, ch = pcall(G.chapter)
    if okc and ch == 24200 then
        local ok, st = pcall((RE4Access.ch11 or C).step, pos)
        if ok and st then return st end
        if not ok then log.info("[RE4Access] ch11 step error: " .. tostring(st)) end
        -- Chapter 11 outside the mapped parts: skip Chapter 10's steps (same objective text)
        return G.hole_step_before_ch10 and G.hole_step_before_ch10(pos) or nil
    end
    return G.hole_step_before_ch11(pos)
end

RE4Access.ch11 = C
log.info("[RE4Access] ch11 steps loaded")
return C
