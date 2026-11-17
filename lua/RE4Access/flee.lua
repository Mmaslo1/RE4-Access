-- RE4 Access: chapter 6 "Flee from the villagers" (10/29).
-- The user died twice right after the scene east of the wire gate (17:27,
-- 17:31): stood and fought ~60 s at (214,-210) with health 45-68 %, then a
-- cutscene = game over with no hit before it. The user thought it was a boss
-- fight. Walkthroughs (Push Square, actugaming): it is a CHASE - Chief Mendez
-- follows and kills Leon if he catches him; villagers block the way; a red
-- barrel to shoot when they bunch up; the bridge blows up -> turn LEFT onto
-- the cliff path; a Merchant after it, then the house with the Mendez fight.
-- Ashley: if she is knocked down and hit again it is game over too.
-- The exact path is not known yet: this module logs the run ("flee:" lines
-- + data\REAccess_flee_trail.txt) so the real route can be added.

local F = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end
local st = { told = false }

local function in_flee()
    local ok, ot = pcall(RE4Access.game.objective_text)
    return ok and type(ot) == "string" and ot:lower():find("flee from the villagers", 1, true) ~= nil
end
F.in_flee = in_flee

-- the way's end known so far (autosave before Mendez, 10/27 live read)
local EAST = { name = "the way east, toward the Merchant", x = 280.0, y = 10.9, z = -222.2 }

-- 10/29 user: the first text was full of sighted steps (red barrel, bridge,
-- turn left). Only keys + things the mod itself says.
-- 11/1: the old intro took about 25 s to speak; Mendez killed Leon 14-16 s after
-- control came back. Short order only, the route starts by itself, O has the rest.
local INTRO = "Run! Hold Shift and W. I steer you. Do not fight."

local function enemies(pos)
    local out = {}
    pcall(function()
        local l = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
        for i = 0, l:call("get_Count") - 1 do
            pcall(function()
                local e = l:call("get_Item", i)
                local live = true
                pcall(function() live = e:call("get_HitPoint"):call("get_IsLive") end)
                local tn = e:get_type_definition():get_name()
                if live == false or tn:find("^Ch8g") then return end
                local q = e:call("get_Position")
                out[#out + 1] = { t = tn, c = e, d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2), x = q.x, y = q.y, z = q.z }
            end)
        end
    end)
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

-- 11/2 Chapter 7 past the Merchant. Claude WALKED steps 1 to 17 (protected, Garrador weakened
-- for the test, so that fight is not proven). Steps 18 on: path data checked read-only, gates
-- may still be shut, NOT WALKED. 6th field true = stay on this step until Leon has been there.
local CASTLE = {
    { "the big gate at the far end of the hall", -126.2, 14.2, 52.4, "Up the steps. Walk into the gate until I say F, then press F. It will not open, and the objective changes.", true },
    { "the corner where Ashley climbs", -136.5, 12.0, 44.6, "When I say F ready, press F at once, the prompt comes and goes. Leon boosts Ashley over. Wait until she is back with you, then press N.", true },
    { "the narrow way to the dungeons", -132.0, 12.0, 40.5, "Hold W." },
    { "the dungeons", -123.2, 8.5, 26.9, "Hold W. The game autosaves here." },
    { "the cell passage", -136.2, 8.0, 22.8, "Hold W." },
    { "the next cell", -138.0, 8.0, 20.5, "Hold W." },
    { "the way out of the cells", -134.6, 8.0, 19.5, "Hold W." },
    { "the prison corridor", -134.5, 8.0, 16.0, "Hold W. The game autosaves here. Stay in the middle of the corridor." },
    { "the Dungeon Key", -134.3, 8.0, 7.2, "Stay in the middle of the corridor. Press F for the key, Enter to keep it, then F once more if Leon does not move.", true },
    { "the middle of the corridor, going back", -134.5, 8.0, 10.2, "The floor breaks here and Leon falls to a Garrador. It is blind: walk, do not run. Shoot the parasite on its back.", true },
    { "the crank", -116.3, 4.5, 2.7, "Kill the Garrador first, it stops you turning the crank. Walk at the crank until I say F ready, then hold F about 7 seconds.", true },
    { "the ladder up", -111.1, 4.5, 14.2, "Through the gate the crank opened. Walk into the ladder and press F when I say.", true },
    { "Ashley", -118.0, 8.5, 22.7, "She waits near here." },
    { "the locked gate", -122.7, 8.5, 18.3, "Press F. On the key list press Enter on the Dungeon Key, then Enter on Use.", true },
    { "the ladder past the gate", -122.6, 8.5, 10.0, "Hold W. When Leon is on the ladder, keep holding W until he is at the top." },
    { "the room above", -121.2, 18.0, 16.0, "The game autosaves here. The Treasury door is right here, with a puzzle." },
    { "the iron gate", -113.5, 18.0, 23.0, "Shoot the gongs to open it. The Bloodied Sword is behind it. Use the Items list: not walked yet.", true },
    { "the shutter", -121.1, 18.0, 26.5, "The Bloodied Sword goes in the wall paintings here and opens the shutter. Not walked yet.", true },
    { "the upper floor of the hall", -132.4, 18.0, 42.9, "Hold W. Not walked yet." },
    { "the chandelier jump", -140.6, 18.0, 46.1, "F jumps when I say F ready. Not walked yet.", true },
    { "the far side of the chandeliers", -134.7, 18.0, 60.7, "Shoot the Snake gong from the far walkway; with the Dolphin gong it opens the iron gates.", true },
    { "the metal gate", -124.1, 18.0, 59.5, "Not walked yet." },
    { "the east door", -120.0, 20.3, 52.0, "Not walked yet." },
    { "the lower room", -116.4, 14.9, 50.6, "Not walked yet." },
    { "the gate to the Water Hall", -95.2, 13.9, 63.0, "A typewriter is near. Press F when I say. Not walked yet.", true },
    { "the middle of the Water Hall", -76.8, 14.0, 63.0, "Enemies on both levels. The Halo Wheel is on the lower level: N takes you to it.", true },
    { "the lower level", -65.7, 8.9, 62.7, "Not walked yet." },
    { "the far end of the lower level", -59.9, 9.0, 55.4, "Use the Halo Wheel on the machine to get back up. Not walked yet.", true },
    { "the way back up", -56.7, 11.7, 69.9, "Not walked yet." },
    { "the upper level", -44.4, 17.0, 63.1, "Use the Halo Wheel on the middle pedestal, then on the machine at the end. Ashley turns two cranks while enemies attack her. Protect her. Not walked yet.", true },
    { "the end of the upper level", -38.2, 17.0, 63.2, "Protect Ashley until she is back with you. Not walked yet.", true },
    { "the gate out of the Water Hall", 7.5, 21.0, 63.0, "Cross the bridge. Not walked yet." },
    { "the way out", 19.7, 21.4, 52.3, "Not walked yet." },
    { "the outside wall", 28.5, 21.0, 40.2, "Boost Ashley over the wall. That ends the chapter. Not walked yet.", true },
}
-- 11/2 live read: iron gate gm80_788 GmCrestPuzzleDoor _FrontCorrectPattern 13 = crests
-- 1 + 4 + 8 (Stag, Snake, Eagle; Dolphin 2 is wrong), Manager _CrestState holds the lit
-- ones. 11/8 live read: the plate (hit box, Colliders[0] coord) hangs 2.3 m above the object
-- and 0.3-0.7 m toward you; the old +1.2 m guess shot under the Eagle plate every time.
-- 11/8 PM: the gate has a crest panel (Lid_Front_0-3, x -112.66, y 19.3-19.7, z 22.8-23.3) at
-- chest height; from (-113.6,22) the Snake line crossed it and 2 shots missed. Snake spot moved so
-- the line crosses the gate at z 24.0, beside the panel.
local GONGS = {
    { bit = 1, name = "Stag gong", aim = { x = -113.59, y = 20.44, z = 19.98 }, spot = { x = -115.5, y = 17.95, z = 20.0 } },
    { bit = 8, name = "Eagle gong", aim = { x = -109.54, y = 21.51, z = 24.92 }, spot = { x = -113.6, y = 17.95, z = 22.0 } },
    { bit = 4, name = "Snake gong", aim = { x = -104.76, y = 20.31, z = 25.03 }, spot = { x = -114.6, y = 17.95, z = 23.7 } },
}
local function crest_door()
    local d = st.crest_door
    if d then
        local ok = pcall(function() return d:get_field("_TargetNum") end)
        if ok then return d end
    end
    st.crest_door = nil
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            if go:call("get_Name"):find("gm80_788", 1, true) then
                st.crest_door = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCrestPuzzleDoor"))
            end
        end) end
    end
    return st.crest_door
end
local function crest_state()
    local s = 0
    pcall(function() s = crest_door():get_field("_Manager"):get_field("_CrestState") end)
    return s
end
-- next gong to shoot, nil when the gate has its three
function F.gong_next()
    local done = false
    pcall(function()
        local d = crest_door()
        done = d:get_field("_LastCrestState") == 13 or RE4Access.game.gimmick_done(d:call("get_GameObject"))
    end)
    local s = crest_state()
    if done or s == 13 then return nil end
    for _, g in ipairs(GONGS) do
        if s & g.bit == 0 then return g end
    end
end
local gong_at = 0
local function gong_watch()
    local now = os.clock()
    if now - gong_at < 0.3 then return end
    gong_at = now
    local G = RE4Access.game
    local pos = G and G.player_pos and G.player_pos()
    if not pos or pos.y < 16 or pos.y > 21 or pos.x < -119 or pos.x > -112 or pos.z < 17 or pos.z > 28 then
        if st.gong_sel then st.gong_sel = nil G.set_selected(nil) end
        return
    end
    local s = crest_state()
    if st.gong_last and s ~= st.gong_last then
        log.info("[RE4Access] gong crest state " .. tostring(st.gong_last) .. " -> " .. tostring(s))
        if s == 13 then
            say("All three gongs rung. The iron gate opens. Press N for the Bloodied Sword.", true)
        elseif s > st.gong_last then
            say("Gong hit. Press N for the next one.", true)
        elseif s == 0 then
            say("The gongs reset. Press N and start again with the Stag gong.", true)
        end
        st.gong_sel = nil
    end
    st.gong_last = s
    local g = F.gong_next()
    if not g then
        if st.gong_sel then st.gong_sel = nil G.set_selected(nil) end
        return
    end
    local d = math.sqrt((g.spot.x - pos.x) ^ 2 + (g.spot.z - pos.z) ^ 2)
    if d < 1.7 and st.gong_sel ~= g.bit then   -- 1.3 missed: route stopped 1.1-1.4 m off (11/8)
        st.gong_sel = g.bit
        G.set_selected({ name = g.name, pos = g.aim, key = "gong" .. g.bit, dist = d,
            shoot = { x = g.aim.x, y = g.aim.y, z = g.aim.z, what = "lantern", label = g.name } })
        say("This is the spot. Hold L, it aims at the " .. g.name .. ". Press K when I say fire.", true)
    end
end
F.gong_watch = gong_watch

-- 11/8 PM live read: Great Hall upper floor ("Head for the courtyard"). Two iron gates
-- gm80_523 at the east ends of the near walkway (z 43.5) and far walkway (z 60.55) share
-- one crest manager: _FrontCorrectPattern 6 = Dolphin (2) + Snake (4), 2 hits judged.
-- Shown on Assisted: Dolphin plate (-124.80,20.26,44.15) on the near side, low-difficulty
-- Snake plate (-124.80,20.26,59.81) on the far side. Line of sight proven (ray hits the
-- plate): Dolphin from near walkway x -130..-135, Snake only from far walkway x -128..-136.
-- The walkways join only by the chandeliers gm84_578: F at A (z 46.93) swings to B (z 57.02),
-- x -140.39 and -150.07. Ledge floor: near side to z 47.0, far side from z 57.0.
-- N used to count 'near the jump point' as done -> 'No walking route found'.
local HALL_GONGS = {
    { bit = 2, name = "Dolphin gong", far = false, aim = { x = -124.80, y = 20.26, z = 44.15 }, spot = { x = -131.0, y = 17.95, z = 43.5 } },
    { bit = 4, name = "Snake gong", far = true, aim = { x = -124.80, y = 20.26, z = 59.81 }, spot = { x = -131.0, y = 17.95, z = 60.5 } },
}
local function hall_gate()
    local d = st.hall_gate
    if d then
        local ok = pcall(function() return d:get_field("_TargetNum") end)
        if ok then return d end
    end
    st.hall_gate = nil
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            if go:call("get_Name"):find("gm80_523", 1, true) then
                st.hall_gate = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCrestPuzzleDoor"))
            end
        end) end
    end
    return st.hall_gate
end
-- returns crest bits lit, gate open (nil when the gate is not loaded)
local function hall_state()
    local d = hall_gate()
    if not d then return nil end
    local s, open = 0, false
    pcall(function() s = d:get_field("_Manager"):get_field("_CrestState") end)
    pcall(function() open = d:get_field("_LastCrestState") == 6 or RE4Access.game.gimmick_done(d:call("get_GameObject")) end)
    return s, open or s == 6
end
F.hall_state = hall_state
local function hall_region(pos)
    return pos and pos.y > 16 and pos.y < 21 and pos.x > -160 and pos.x < -122 and pos.z > 38 and pos.z < 64
end
local hall_at = 0
local function hall_watch()
    local now = os.clock()
    if now - hall_at < 0.3 then return end
    hall_at = now
    local G = RE4Access.game
    local pos = G and G.player_pos and G.player_pos()
    if not hall_region(pos) then
        if st.hall_sel then st.hall_sel = nil G.set_selected(nil) end
        return
    end
    local s, open = hall_state()
    if not s then return end
    if st.hall_last and s ~= st.hall_last then
        log.info("[RE4Access] hall crest state " .. tostring(st.hall_last) .. " -> " .. tostring(s))
        if s == 6 or open then
            say("Both gongs rung. The iron gates open. Press N.", true)
        elseif s == 0 then
            say("The gongs reset. Press N, I take you to the next gong.", true)
        elseif s & 1 ~= 0 or s & 8 ~= 0 then
            say("Wrong gong. Only the Dolphin and the Snake count. Press N.", true)
        else
            say("Gong hit. Press N for the next step.", true)
        end
        st.hall_sel = nil
    end
    st.hall_last = s
    if open then
        if st.hall_sel then st.hall_sel = nil G.set_selected(nil) end
        return
    end
    for _, g in ipairs(HALL_GONGS) do
        if s & g.bit == 0 then
            local d = math.sqrt((g.spot.x - pos.x) ^ 2 + (g.spot.z - pos.z) ^ 2)
            if d < 1.7 and st.hall_sel ~= g.bit then
                st.hall_sel = g.bit
                G.set_selected({ name = g.name, pos = g.aim, key = "hallgong" .. g.bit, dist = d,
                    shoot = { x = g.aim.x, y = g.aim.y, z = g.aim.z, what = "lantern", label = g.name } })
                say("This is the spot. Hold L, it aims at the " .. g.name .. ". Press K when I say fire.", true)
            end
        end
    end
end
F.hall_watch = hall_watch

-- 11/8 live read: the Sword Wall. Four paintings (GmSwordWall) at z 27.59, each with
-- _CorrectItem/_CurrentItem (-1 = empty). F on a painting holding a sword takes it,
-- F on an empty one lets you put a sword from your case. All four right = shutter
-- gm80_596 opens (the Gold Bangle room behind it). Numbered 1-4 from the gong side.
local SWORD_NAMES = { [119260800] = "Golden Sword", [119262400] = "Iron Sword", [119278400] = "Bloodied Sword", [119280000] = "Rusted Sword" }
local function sword_walls()
    local out = {}
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            if go:call("get_Name"):find("gm84_8[12]%d_00_0_") then
                local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmSwordWall"))
                if c then
                    local q = go:call("get_Transform"):call("get_Position")
                    out[#out + 1] = { go = go, x = q.x, y = q.y, z = q.z, cur = c:get_field("_CurrentItem"), want = c:get_field("_CorrectItem") }
                end
            end
        end) end
    end
    table.sort(out, function(a, b) return a.x > b.x end)
    for i, w in ipairs(out) do w.n = i end
    return out
end
-- the next thing to do at the paintings, or nil when all four are right
function F.sword_next()
    local walls = sword_walls()
    if #walls < 4 then return nil end
    local on_wall, all_ok = {}, true
    for _, w in ipairs(walls) do
        if w.cur ~= -1 then on_wall[w.cur] = w end
        if w.cur ~= w.want then all_ok = false end
    end
    if all_ok then return nil end
    -- 1: an empty painting whose sword you carry: put it in
    for _, w in ipairs(walls) do
        if w.cur == -1 and not on_wall[w.want] then
            return { wall = w, put = true, sword = SWORD_NAMES[w.want] or "right sword" }
        end
    end
    -- 2: a wrong sword whose own painting is empty: take it
    for _, w in ipairs(walls) do
        if w.cur ~= -1 and w.cur ~= w.want then
            for _, v in ipairs(walls) do
                if v.want == w.cur and v.cur == -1 then return { wall = w, take = true, sword = SWORD_NAMES[w.cur] or "sword" } end
            end
        end
    end
    -- 3: any wrong sword: take it
    for _, w in ipairs(walls) do
        if w.cur ~= -1 and w.cur ~= w.want then return { wall = w, take = true, sword = SWORD_NAMES[w.cur] or "sword" } end
    end
end
-- the sword the empty painting you stand at needs (for the key item window, 11/8:
-- every sword says "can be used here"; the cursor sat on the Rusted Sword and the
-- user put it back into painting 2 three times)
function F.sword_wall_want(pos)
    local best, bd
    for _, w in ipairs(sword_walls()) do
        local d = math.sqrt((w.x - pos.x) ^ 2 + (w.z - pos.z) ^ 2)
        if w.cur == -1 and d < 3 and (not bd or d < bd) then best, bd = w, d end
    end
    return best and SWORD_NAMES[best.want], best and best.n
end
local sword_at, sword_sig = 0, nil
local function sword_watch()
    local now = os.clock()
    if now - sword_at < 0.5 then return end
    sword_at = now
    local G = RE4Access.game
    local pos = G and G.player_pos and G.player_pos()
    if not pos or pos.y < 16 or pos.y > 21 or pos.x < -127 or pos.x > -115 or pos.z < 22 or pos.z > 29 then sword_sig = nil return end
    local walls = sword_walls()
    if #walls < 4 then return end
    local sig = ""
    for _, w in ipairs(walls) do sig = sig .. tostring(w.cur) .. "," end
    if sword_sig and sig ~= sword_sig then
        log.info("[RE4Access] sword walls " .. sword_sig .. " -> " .. sig)
        local nx = F.sword_next()
        if not nx then
            say("All four swords are in the right paintings. The shutter opens. Press N.", true)
        else
            say("Done. Press N: next, painting " .. nx.wall.n .. ".", true)
        end
    end
    sword_sig = sig
end
F.sword_watch = sword_watch

local function castle_step(pos)
    local function d3(c) return math.sqrt((c[2] - pos.x) ^ 2 + (c[3] - pos.y) ^ 2 + (c[4] - pos.z) ^ 2) end
    local function near(c, r) return math.sqrt((c[2] - pos.x) ^ 2 + (c[4] - pos.z) ^ 2) < r and math.abs(c[3] - pos.y) < 2.5 end
    if not st.castle_i then
        -- after a restart: the point nearest Leon, counting height (the hall has two floors)
        local best, bd = 1, 12
        for i, c in ipairs(CASTLE) do
            if d3(c) < bd then best, bd = i, d3(c) end
        end
        st.castle_i = best
    end
    -- 11/2: standing near the crank moved N on to the ladder though the crank never
    -- turned (ladder is behind the gate it opens). Stay on the crank until it is turned.
    if (st.castle_i == 11 or st.castle_i == 12) and pos.y < 6 and pos.x < -113.5 then
        local turned = true
        pcall(function()
            for _, t in ipairs(RE4Access.game.scan_things({ x = -115.05, y = 4.5, z = 1.77 }, 2)) do
                if t.go:call("get_Name"):find("gm84_731", 1, true) then
                    local h = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmHoldHandle"))
                    turned = RE4Access.game.gimmick_done(t.go) or h:get_field("_Routine_") ~= 0
                end
            end
        end)
        if not turned then
            st.castle_i = 11
            log.info("[RE4Access] castle step 11 of " .. #CASTLE .. " crank not turned")
            -- crank faces west (rotation -90): stand at its front; old point was 1.6 m off, no prompt
            return { name = "the front of the crank", pos = { x = -116.0, y = 4.5, z = 1.8 }, key = "ch7_crankfront", walk_point = true,
                dist = math.sqrt((-116.0 - pos.x) ^ 2 + (1.8 - pos.z) ^ 2),
                tip = "Hold W. When I say stop, wait for F ready, then HOLD F down about 7 seconds. Do not tap it." }
        end
    end
    -- 11/2: top of the ladder: door with a bar (GmDeadDoor + DoorLockBar) shuts this side
    -- off; routes ignore it and walked Leon into it ('Blocked'). Lift the bar first.
    if st.castle_i >= 13 and st.castle_i <= 14 and pos.y > 7 and pos.y < 10 and pos.x > -117 and pos.x < -109 then
        local bar
        pcall(function()
            for _, t in ipairs(RE4Access.game.scan_things({ x = -116.98, y = 8.54, z = 22.21 }, 1)) do
                if t.go:call("get_Name") == "DoorLockBar" and not RE4Access.game.gimmick_done(t.go) then bar = t.go end
            end
        end)
        if bar then
            log.info("[RE4Access] castle: bar on the door still down")
            return { name = "the bar on the door", pos = { x = -116.5, y = 8.54, z = 23.1 }, key = "ch7_deadbar", walk_point = true,
                latch = true, face = { x = -116.98, y = 9.68, z = 23.08 }, go = bar, fname = "Door Lock", spoken = "bar on the door",
                after = "Wait for F ready, then HOLD F for 1 second to lift the bar. Then hold W to go through, and press N.",
                dist = math.sqrt((-116.5 - pos.x) ^ 2 + (23.1 - pos.z) ^ 2),
                tip = "A bar holds this door shut. Hold W until I say it is in front of you." }
        end
    end
    -- 11/2: gongs + sword. Standing near the iron gate or paintings moved N on though
    -- nothing was done, so the user reached the Sword Wall with no sword.
    if st.castle_i >= 17 and st.castle_i <= 20 and pos.y > 16 and pos.y < 21 then
        local G = RE4Access.game
        local sw
        pcall(function()
            for _, it in ipairs(G.items(pos, 30)) do
                if it.name:find("Bloodied Sword", 1, true) then sw = it break end
            end
        end)
        if sw then
            st.castle_i = 17
            local g = F.gong_next()
            if g then
                return { name = "the spot to shoot the " .. g.name, pos = g.spot, key = "ch7_gong" .. g.bit, walk_point = true,
                    dist = math.sqrt((g.spot.x - pos.x) ^ 2 + (g.spot.z - pos.z) ^ 2),
                    tip = "Three gongs open the iron gate: Stag, Eagle and Snake. Not the Dolphin. At the spot I tell you when to shoot." }
            end
            return { name = "Bloodied Sword", pos = sw.pos, key = sw.key, item = true, go = sw.go, dist = sw.dist,
                tip = "The iron gate is open. Hold W. When I say F ready, press F. Then press N." }
        end
        if st.castle_i < 18 then st.castle_i = 18 end
        if st.castle_i <= 19 and pos.z < 27.8 then
            local shut = false
            pcall(function()
                for _, t in ipairs(G.scan_things({ x = -121.13, y = 17.95, z = 27.8 }, 1)) do
                    if t.go:call("get_Name"):find("gm80_596", 1, true) and not G.gimmick_done(t.go) then shut = true end
                end
            end)
            if shut then
                st.castle_i = 18
                local nx = F.sword_next()
                if nx then
                    local w = nx.wall
                    local what = nx.put and ("put the " .. nx.sword .. " in it. Press F, then pick the " .. nx.sword .. " from your case and confirm.")
                        or ("take the " .. nx.sword .. " out of it. Press F only once: a second F puts it straight back.")
                    -- 11/8 live: walking along the wall from painting to painting got Leon
                    -- stuck at (-118.9,26.1), and a stop 2.1 m out gave no F at paintings 1
                    -- and 4. So: first a point 2.7 m out in the open, then the painting
                    -- itself as an F target (the route stops 0.7-1.1 m in front, faces it).
                    local ax, az = w.n == 4 and w.x + 0.45 or w.x, 24.9   -- a breakable crate at (-124.81,25.64) in front of painting 4
                    local da = math.sqrt((ax - pos.x) ^ 2 + (az - pos.z) ^ 2)
                    local dw = math.sqrt((w.x - pos.x) ^ 2 + (w.z - pos.z) ^ 2)
                    if da > 0.9 and dw > 1.4 and not (math.abs(pos.x - w.x) < 0.6 and pos.z > az) then
                        return { name = "the floor in front of painting " .. w.n, pos = { x = ax, y = 17.95, z = az }, key = "ch7_swordapp" .. w.n, walk_point = true,
                            dist = da,
                            tip = "Four paintings each need one sword; the right four open the shutter. When I say arrived, press N again: I step you up to painting " .. w.n .. ". There, " .. what }
                    end
                    return { name = "painting " .. w.n, pos = { x = w.x, y = w.y, z = w.z }, go = w.go, key = "ch7_sword" .. w.n .. (nx.put and "p" or "t"),
                        dist = dw,
                        tip = "Hold W until I say it is in front of you. Wait for F ready, then " .. what .. " Then press N." }
                end
                return { name = "the sword paintings", pos = { x = -121.1, y = 18, z = 26.5 }, key = "ch7_paintings", walk_point = true,
                    dist = math.sqrt((-121.1 - pos.x) ^ 2 + (26.5 - pos.z) ^ 2),
                    tip = "The paintings open the shutter. Press F at a painting and choose the sword." }
            end
        end
    end
    -- 11/8 PM: Great Hall upper floor. Gongs + chandelier jump, decided by which walkway
    -- Leon is on (near z < 52, far z > 52) and the live crest state, never by 'was near'.
    if st.castle_i >= 19 and st.castle_i <= 22 and hall_region(pos) then
        local s, open = hall_state()
        if s then
            local far = pos.z > 52
            if open then
                if st.castle_i < 22 then st.castle_i = 22 end
                -- on the near walkway: its gate opened too, go east to the east door
                if not far then st.castle_i = 23 end
            else
                st.castle_i = 20
                local mine, other
                for _, g in ipairs(HALL_GONGS) do
                    if s & g.bit == 0 then
                        if g.far == far then mine = g else other = g end
                    end
                end
                log.info("[RE4Access] hall step: far " .. tostring(far) .. " crest " .. tostring(s))
                if mine then
                    return { name = "the spot to shoot the " .. mine.name, pos = mine.spot, key = "ch7_hallgong" .. mine.bit, walk_point = true,
                        dist = math.sqrt((mine.spot.x - pos.x) ^ 2 + (mine.spot.z - pos.z) ^ 2),
                        tip = "Two gongs open the iron gates: the Dolphin on this side of the hall, the Snake on the far side. At the spot I tell you when to shoot." }
                end
                -- this side's gong is rung: the chandelier to the other side
                local jz, fz = far and 57.5 or 46.5, far and 57.02 or 46.93
                return { name = "the chandelier jump", pos = { x = -140.39, y = 17.95, z = jz }, key = "ch7_chandelier" .. (far and "b" or "a"), walk_point = true,
                    face = { x = -140.39, y = 19.23, z = fz },
                    dist = math.sqrt((-140.39 - pos.x) ^ 2 + (jz - pos.z) ^ 2),
                    tip = (other and ("The " .. other.name .. " is on the other side of the hall. ") or "")
                        .. "Hold W until I say stop, at the edge of the walkway. Wait for F ready, then press F: Leon jumps onto the chandelier and swings across. Then press N." }
            end
        end
    end
    -- 11/8 PM live read: Water Hall. The Halo Wheel lies on the LOWER level at (-53.01,9.15,62.97)
    -- (not in the middle as guessed). Two pedestals (GmHoldHandle, _NoHandle = empty):
    -- small gm84_582 (-61.19,8.48,71.59) lowers the small stairs gm84_725 (lower -> middle level),
    -- big gm84_582 (-78.31,13.95,62.97) lowers the big stairs gm84_581 (middle -> upper level).
    -- Stairs down when GmCorrelatedTerrain _CurRate >= 0.9. N said 'No walking route to the
    -- way back up' because the wheel was never picked up.
    if st.castle_i >= 26 and st.castle_i <= 30 and pos.x > -92 and pos.x < -44 and pos.z > 48 and pos.z < 80 and pos.y < 16 then
        local G = RE4Access.game
        local wheel, small, big, small_st, big_st
        pcall(function()
            for _, it in ipairs(G.items(pos, 60)) do
                if it.name:find("Halo Wheel", 1, true) then wheel = it break end
            end
        end)
        pcall(function()
            local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core then pcall(function()
                    local go = core:call("get_GameObject")
                    local n = go:call("get_Name")
                    if n:find("gm84_582", 1, true) then
                        local h = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmHoldHandle"))
                        local q = go:call("get_Transform"):call("get_Position")
                        local rec = { go = go, empty = h:get_field("_NoHandle"), x = q.x, y = q.y, z = q.z }
                        if n:find("小さい", 1, true) then small = rec else big = rec end
                    elseif n:find("gm84_725", 1, true) or n:find("gm84_581", 1, true) then
                        local t = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCorrelatedTerrain"))
                        local down = t:get_field("_CurRate") >= 0.85   -- 11/8 live: fully down reads 0.8999999
                        if n:find("gm84_725", 1, true) then small_st = down else big_st = down end
                    end
                end) end
            end
        end)
        local function ped(p0, name, tip)
            return { name = name, pos = { x = p0.x, y = p0.y, z = p0.z }, go = p0.go, key = "ch7_ped" .. math.floor(p0.x),
                dist = math.sqrt((p0.x - pos.x) ^ 2 + (p0.z - pos.z) ^ 2), tip = tip }
        end
        log.info("[RE4Access] water hall: wheel " .. tostring(wheel ~= nil) .. " small " .. tostring(small and small.empty) .. "/" .. tostring(small_st)
            .. " big " .. tostring(big and big.empty) .. "/" .. tostring(big_st) .. " y " .. string.format("%.1f", pos.y))
        if small and big then
            local lower = pos.y < 11
            if wheel then
                st.castle_i = 27
                return { name = "Halo Wheel", pos = wheel.pos, key = wheel.key, item = true, go = wheel.go, dist = wheel.dist,
                    tip = "It turns the stair machines. Hold W. When I say F ready, press F. Then press N." }
            end
            if lower and not small_st then
                st.castle_i = 28
                if small.empty then
                    return ped(small, "the small stair machine", "Hold W until I say it is in front of you. Wait for F ready, press F, pick the Halo Wheel and confirm. Then HOLD F until the stairs come down. Then press N.")
                end
                return ped(small, "the small stair machine", "The Halo Wheel is in it. Wait for F ready, then HOLD F until the stairs come down. Then press N.")
            end
            if lower and small_st and not small.empty and not big_st then
                st.castle_i = 28
                return ped(small, "the small stair machine", "The stairs are down. Take the Halo Wheel back out: wait for F ready, then hold F about 2 seconds. You need it upstairs. Then press N.")
            end
            if lower then
                st.castle_i = 29
                return { name = "the stairs up", pos = { x = -56.67, y = 11.67, z = 69.92 }, key = "ch7_smallstairs", walk_point = true,
                    dist = math.sqrt((-56.67 - pos.x) ^ 2 + (69.92 - pos.z) ^ 2), tip = "Hold W up the stairs. Then press N." }
            end
            if not big_st then
                st.castle_i = 29
                if big.empty and not small.empty then
                    return ped(small, "the small stair machine", "The Halo Wheel is still in it. Wait for F ready, then hold F about 2 seconds to take it out. Then press N.")
                end
                return ped(big, "the big stair machine", big.empty
                    and "Hold W until I say it is in front of you. Wait for F ready, press F, pick the Halo Wheel and confirm. Then HOLD F until the big stairs come down. Then press N."
                    or "The Halo Wheel is in it. Wait for F ready, then HOLD F until the big stairs come down. Then press N.")
            end
            if not big.empty then
                st.castle_i = 29
                return ped(big, "the big stair machine", "The big stairs are down. Take the Halo Wheel back out: wait for F ready, then hold F about 2 seconds. You need it upstairs. Then press N.")
            end
            st.castle_i = 30   -- the upper level, up the big stairs
        end
    end
    -- 11/8 PM live read: Water Hall upper level. The way out is a bridge of 3 movable floors
    -- gm84_584 (x -15.4/-20.8/-26.1, y 15.55, z 63; GmCorrelatedTerrain2 _CurRate 0 = down),
    -- raised by cranks gm84_583: A (-29.68,17.95,61.54) on Leon's level, B (-39.56,19.95,75.48)
    -- and C (-20.45,20.95,47.65) up on ledges, reached by boosting Ashley (gm91_006 '左',
    -- (-37.60,17.05,52.79)). N used to pass steps 30-31 just for being near them -> 'No route
    -- to the gate out'. Which crank raises which floor is not known: guided A, then Ashley.
    if st.castle_i >= 30 and st.castle_i <= 32 and pos.x > -46 and pos.x < 0 and pos.z > 44 and pos.z < 80 and pos.y > 16 then
        local G = RE4Access.game
        local cranks, floors_up, floors_n, boost = {}, 0, 0, nil
        pcall(function()
            local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core then pcall(function()
                    local go = core:call("get_GameObject")
                    local n = go:call("get_Name")
                    if n:find("gm84_583", 1, true) then
                        local h = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmHoldHandle"))
                        local q = go:call("get_Transform"):call("get_Position")
                        cranks[n:sub(-1)] = { go = go, x = q.x, y = q.y, z = q.z,
                            turned = G.gimmick_done(go) or h:get_field("_RotationHandleOld") > 6 }
                    elseif n:find("gm84_584", 1, true) then
                        local t = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCorrelatedTerrain2"))
                        floors_n = floors_n + 1
                        if t:get_field("_CurRate") >= 0.85 then floors_up = floors_up + 1 end
                    elseif n:find("gm91_006_00_1", 1, true) then
                        local q = go:call("get_Transform"):call("get_Position")
                        boost = { go = go, x = q.x, y = q.y, z = q.z, done = G.gimmick_done(go) }
                    end
                end) end
            end
        end)
        local ash_up = false
        pcall(function() ash_up = RE4Access.ashley.partner():call("get_Position").y > 19 end)
        log.info("[RE4Access] water bridge: floors " .. floors_up .. "/" .. floors_n .. " A " .. tostring(cranks.A and cranks.A.turned)
            .. " B " .. tostring(cranks.B and cranks.B.turned) .. " C " .. tostring(cranks.C and cranks.C.turned) .. " ashley up " .. tostring(ash_up))
        if floors_n == 3 and floors_up < 3 then
            st.castle_i = 31
            local a = cranks.A
            if a and not a.turned then
                return { name = "crank A, by the bridge", pos = { x = a.x, y = a.y, z = a.z }, go = a.go, key = "ch7_bridgeA",
                    dist = math.sqrt((a.x - pos.x) ^ 2 + (a.z - pos.z) ^ 2),
                    tip = "The way out is a bridge of three floors that cranks raise. Hold W until I say it is in front of you. Wait for F ready, then HOLD F until it stops turning. Then press N." }
            end
            if ash_up then
                -- 11/8: routing to her on the ledge failed every time (Leon cannot go up).
                -- Guard spot on Leon's level by crank A, in the middle between both ledges.
                return { name = "the guard spot below Ashley", pos = { x = -30.5, y = 17.95, z = 63.5 }, key = "ch7_protect", walk_point = true,
                    dist = math.sqrt((-30.5 - pos.x) ^ 2 + (63.5 - pos.z) ^ 2),
                    tip = "Ashley is up on the ledge turning cranks. You cannot go up there, and you do not need to. Stay down here, hold L and shoot every enemy: if she is grabbed I aim at her carrier, press K. When the bridge is up I tell you. Press N to check." }
            end
            if boost then
                return { name = "the spot to boost Ashley up", pos = { x = boost.x, y = boost.y, z = boost.z }, go = boost.go, key = "ch7_boostash",
                    dist = math.sqrt((boost.x - pos.x) ^ 2 + (boost.z - pos.z) ^ 2),
                    tip = "Ashley climbs up to turn the other cranks. Hold W until I say it is in front of you. When I say F ready, press F at once. Then protect her: hold L and shoot enemies near her. Press N any time." }
            end
        elseif floors_n == 3 then
            st.castle_i = 32   -- bridge up: the gate out of the Water Hall
        end
    end
    -- 11/8 PM live read: garden entrance past the Water Hall. Mesh door gm80_789 / gm84_865
    -- (20.22,21.43,52.27) is locked from the far side; boost Ashley over at gm91_006 '(3m)'
    -- (17.54,21.41,52.40), she unlocks it. N used to aim at a point past the door: Leon stood
    -- at the door, F did nothing.
    if st.castle_i >= 33 and pos.x > 10 and pos.x < 30 and pos.z > 44 and pos.z < 62 and pos.y > 19 then
        local G = RE4Access.game
        local boost
        pcall(function()
            for _, t in ipairs(G.scan_things({ x = 17.54, y = 21.41, z = 52.40 }, 1.5)) do
                if t.go:call("get_Name"):find("gm91_006", 1, true) and not G.gimmick_done(t.go) then boost = t end
            end
        end)
        log.info("[RE4Access] garden door: boost " .. tostring(boost ~= nil))
        if boost then
            st.castle_i = 34
            return { name = "the spot to boost Ashley over the wall", pos = { x = 17.54, y = 21.41, z = 52.40 }, go = boost.go, key = "ch7_gardenboost",
                dist = math.sqrt((17.54 - pos.x) ^ 2 + (52.40 - pos.z) ^ 2),
                tip = "The door here is locked from the other side, you cannot open it. Ashley climbs over and unlocks it. Hold W until I say it is in front of you. When I say F ready, press F. Ashley must be close to you." }
        end
    end
    local cur = CASTLE[st.castle_i]
    if near(cur, 2.0) then
        st.castle_i = math.min(st.castle_i + 1, #CASTLE)
    elseif not cur[6] then
        -- walked past an ordinary point: move on, but never past a step that must be done
        for i = st.castle_i + 1, math.min(st.castle_i + 3, #CASTLE) do
            if near(CASTLE[i], 1.5) then st.castle_i = math.min(i + 1, #CASTLE) break end
            if CASTLE[i][6] then break end
        end
    end
    local c = CASTLE[st.castle_i]
    local q = { x = c[2], y = c[3], z = c[4] }
    log.info("[RE4Access] castle step " .. st.castle_i .. " of " .. #CASTLE)
    return { name = c[1], pos = q, key = "ch7_castle" .. st.castle_i, walk_point = true,
        dist = math.sqrt((c[2] - pos.x) ^ 2 + (c[4] - pos.z) ^ 2), tip = c[5] }
end

-- N during the chase: always east (partial route); never back west.
function F.step(pos)
    -- 11/1 after Mendez: way out = slaughterhouse window, story key Csa_030 just past it.
    -- His False Eye drops in the room (guide: sells for 12,000).
    local okq, oq = pcall(RE4Access.game.objective_text)
    if okq and type(oq) == "string" and oq:lower():find("another way around", 1, true) then return castle_step(pos) end
    -- 11/8: right after Continue the objective text is not back yet; N fell through to
    -- 'the trail' 97 m back into the hall and 'Blocked'. In the Water Hall use the castle steps.
    if st.castle_i and st.castle_i >= 26 and pos.x > -95 and pos.x < 30 and pos.z > 40 and pos.z < 82 and pos.y > 7 then
        return castle_step(pos)
    end
    -- Chapter 7 start (11/1 live read, not walked yet): Merchant and typewriter come
    -- first, then the wooden door on the way into the castle grounds.
    if okq and type(oq) == "string" and oq:lower():find("head for the courtyard", 1, true) then
        local m = { x = -307.4, y = -6.8, z = 65.1 }
        if math.sqrt((m.x - pos.x) ^ 2 + (m.z - pos.z) ^ 2) < 4 then st.merchant7_done = true end
        if pos.x > -290 then st.merchant7_done = true end   -- 11/2: past him; after a restart N must not walk back
        if not st.merchant7_done then
            return { name = "the Merchant", pos = m, key = "ch7_merchant",
                dist = math.sqrt((m.x - pos.x) ^ 2 + (m.z - pos.z) ^ 2),
                tip = "The typewriter is right beside him. Buy all the healing you can here: the catapult field ahead has no herbs near the way, and the next Merchant is past it. Press N after that for the way on." }
        end
        -- 11/2 live: chain read from the game's own trigger names + checked with
        -- nav_points leg by leg, not walked yet. Each point is a walking point so the
        -- route's own door handling opens doors; aiming at a door itself stopped Leon at
        -- the frame and kept asking for F after it was open. The nearest point says how
        -- far along Leon is; the next one is the goal, even after running back.
        local chain = {
            { x = -284.4, y = -4.7, z = 78.0, name = "through the wooden door" },
            { x = -274.5, y = -4.7, z = 69.5, name = "the far door of this room, and through it",
                tip = "Hold W. An enemy is in this room, close to your way. Doors open as you walk or with F." },
            { x = -274.5, y = -4.7, z = 64.4, name = "the passage past the far door", tip = "Hold W. Stay on the route, there may be fire on your left." },
            { x = -273.8, y = -5.1, z = 57.0, name = "the way down the passage", tip = "Hold W. Enemies with crossbows are ahead." },
            { x = -266.2, y = -5.9, z = 52.4, name = "the autosave spot", tip = "Hold W. Enemies with crossbows are close." },
            { x = -261.8, y = -5.9, z = 52.8, name = "the next scene", tip = "Hold W. Walking in may start a scene." },
            { x = -247.1, y = -0.9, z = 53.2, name = "the crossbow enemies' position", tip = "Hold W. Expect crossbow fire." },
            { x = -240.9, y = -0.9, z = 57.0, name = "the way past the barricade", tip = "Hold W. There may be fire near here." },
            { x = -234.2, y = 1.5, z = 67.4, name = "the autosave spot before the catapults", tip = "Hold W. I have not mapped past this point yet." },
        }
        local bi, bd = 1, math.huge
        for i, c in ipairs(chain) do
            local d = math.sqrt((c.x - pos.x) ^ 2 + (c.z - pos.z) ^ 2)
            if d < bd then bi, bd = i, d end
        end
        -- 11/2 catapult field: the gate only opens to the cannon. Counterweight in the
        -- tower raises the cannon, cannon breaks the gate, Merchant is past it (guides +
        -- GmWeighingWeight, GmCannonV2, GmBigDoor read live; not walked).
        if bi == #chain or pos.x > -238 or (bi >= 7 and pos.y > 4) then   -- 11/2: on the upper walls x is -245, nearest chain point was the ground below: "no route"
            local dist = function(q) return math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) end
            local cannon_y, gate_open, gate_shot
            pcall(function()
                local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
                for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                    local core = e:get_field("value")
                    if core then pcall(function()
                        local go = core:call("get_GameObject")
                        local n = go:call("get_Name")
                        if n:find("gm84_572", 1, true) then
                            cannon_y = go:call("get_Transform"):call("get_Position").y
                            -- 11/2 live: set when the shot found its target, stays set after Leon gets off.
                            if go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCannonV2")):get_field("_CurrentTargetParam") then gate_shot = true end
                        end
                        if n:find("gm80_532", 1, true) and go:call("get_Transform"):call("get_Position").x > -190 then
                            gate_open = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmBigDoor")):get_field("IsOpen")
                            if not go:call("get_DrawSelf") then gate_open = true end
                        end
                    end) end
                end
            end)
            -- 11/2 live: after a reload the cannon forgets its shot and the gate reads shut. Leon east of a gate = it is done.
            if pos.x > -205 then gate_shot = true end
            if pos.x > -183.5 then gate_open = true end
            log.info("[RE4Access] ch7 field: cannon y " .. tostring(cannon_y) .. " gate open " .. tostring(gate_open))
            if gate_open then
                local q = { x = -168.5, y = 10.0, z = 58.7 }
                if dist(q) < 4 or pos.x > -160 then st.ch7_merchant2_done = true end
                if st.ch7_merchant2_done then return castle_step(pos) end
                return { name = "the Merchant, past the gate", pos = q, key = "ch7_merchant2", dist = dist(q),
                    tip = "A typewriter is beside him. Hold W." }
            end
            -- 11/2 live: the shot breaks the gate at x -207; a second gate at x -184.3 opens with F.
            if gate_shot then
                local q = { x = -185.2, y = 10.0, z = 52.0 }
                return { name = "the second gate", pos = q, key = "ch7_gate2", walk_point = true, dist = dist(q),
                    tip = "The cannon broke the first gate. Hold W to the second gate. When I say stop, let go of W and press F to open it. Then press N for the Merchant." }
            end
            if cannon_y and cannon_y > 5 then
                local q = { x = -228.9, y = 9.7, z = 63.5 }
                -- 11/2 ray map: boards at y 9 (x <= -243, z 42-47), floor at y 8 east of them.
                -- Between them a low wall at x -242.2, knee + waist high, open above from
                -- z 43.3 to 45.4. The route's own drop stopped 1 m short and F never came.
                local on_boards = (pos.z > 46.8 and pos.x < -235 and pos.y > 7)
                    or (pos.x < -242.2 and pos.y > 8.5 and pos.z > 41.5 and pos.z <= 46.8)
                if on_boards then
                    local g = { x = -242.85, y = 9.05, z = 44.45 }
                    st.gap_t = g
                    return { name = "the gap in the low wall", pos = g, key = "ch7_gap", walk_point = true, dist = dist(g),
                        tip = "Hold W. When I say you are there, hold W and tap F to get over it." }
                end
                -- The way back up: ladder, then a barred door opened from this side.
                local okc, pc = pcall(RE4Access.route.nav_points, pos, q)
                local ec = okc and pc and (pc.snap or pc[#pc])
                -- 11/2: door already open: never back to it. N sent the user back through the
                -- open door because nav to the cannon failed once; rocks took 36% while he stood there.
                local door_done = false
                pcall(function()
                    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
                    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                        local core = e:get_field("value")
                        if core then pcall(function()
                            local go = core:call("get_GameObject")
                            if go:call("get_Name"):find("gm84_637", 1, true) and core:call("get_Context"):call("hasDoneForMap") then
                                local dq = go:call("get_Transform"):call("get_Position")
                                if math.abs(dq.x + 237) < 2 and math.abs(dq.z - 37.9) < 2 then door_done = true end
                            end
                        end) end
                    end
                end)
                log.info("[RE4Access] ch7 cannon step: door done " .. tostring(door_done) .. " nav end " .. (ec and string.format("%.1f,%.1f,%.1f", ec.x, ec.y, ec.z) or "none"))
                st.ch7_door_done = door_done
                local reach = ec and math.sqrt((ec.x - q.x) ^ 2 + (ec.z - q.z) ^ 2) < 2 and math.abs(ec.y - q.y) < 2
                -- 11/2: nav_points here is sometimes empty for one call while route.go then finds
                -- the way. The fallback point + auto-next looped N 4 times a second: removed.
                if door_done then reach = true end
                if not reach then
                    local l = { x = -237.27, y = 8.0, z = 38.39 }
                    return { name = "the barred door", pos = l, key = "ch7_bardoor", dist = dist(l),
                        tip = "It is the way back to the cannon. Hold W. When I say F ready, press F to lift the bar, then press N. A chest with a treasure is close by." }
                end
                return { name = "the cannon", pos = q, key = "ch7_cannon", dist = dist(q),
                    tip = "Hold W. When I say F ready, hold F to take the cannon. On it, I tell you how to aim at the gate." }
            end
            -- GmWeighingWeight has a HitController: a shot drops it. Its body is at y 3.69
            -- (the object's own y 6.69 is the chain). L aims at target.shoot; target.go is
            -- not set so nothing else treats it as a nest.
            local w = { x = -227.07, y = 3.69, z = 59.33 }
            local spot = { x = -230.5, y = 2.1, z = 57.3 }
            -- 11/2: shoot stays off until cannon_watch says it is safe: while selected it
            -- took over L everywhere, so L aimed at the weight instead of the enemies
            -- on the deck and Ashley died.
            local wt = { name = "the spot to shoot the counterweight", pos = spot, key = "ch7_weight", walk_point = true,
                dist = dist(spot) }
            st.weight_t = wt
            st.weight_aim = { x = w.x, y = w.y, z = w.z, what = "lantern", label = "Counterweight" }
            wt.tip = "The big gate only opens to the cannon, and dropping this weight raises it. Hold W. You drop down into the tower on the way, press F when I say. Do not stop to fight up on the deck unless an enemy is on you. Ashley follows you. At the spot I tell you when to shoot."
            return wt
        end
        -- Still before the first door (it is at z 76.65, Merchant side).
        local i = (bi == 1 and pos.z < 76.65) and 1 or math.min(bi + 1, #chain)
        local c = chain[i]
        if not (i == #chain and bi == #chain and bd < 3) then
            return { name = c.name, pos = { x = c.x, y = c.y, z = c.z }, key = "ch7_" .. i, walk_point = true,
                dist = math.sqrt((c.x - pos.x) ^ 2 + (c.z - pos.z) ^ 2),
                tip = c.tip or "Hold W. Press N again when you stop." }
        end
    end
    if okq and type(oq) == "string" and oq:lower():find("escape from the slaughter", 1, true) then
        local eye
        pcall(function()
            for _, it in ipairs(RE4Access.game.items(pos, 40)) do
                if it.name:find("False Eye") then eye = it end
            end
        end)
        if eye then
            eye.tip = "It sells for a lot. Press F when I say. Then press N for the way out."
            return eye
        end
        local q = { x = 281.7, y = 10.0, z = -222.5 }
        return { name = "the window, the way out", pos = q, key = "slaughter_window",
            dist = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2),
            tip = "Hold W. When I say F ready, press F to jump out." }
    end
    -- 11/1 after the window: objective goes back to "Escape from the village", same
    -- words as before the chase, so N pointed back at the wire gate. East of x 270
    -- with this objective the way on is the stone bridge to the castle (Csa_031).
    if okq and type(oq) == "string" and oq:lower():find("escape from the village", 1, true) and pos.x > 270 then
        -- 11/1: Csa_031 fired nothing and N kept returning to it. Walkable ground goes
        -- on east to x 330; beyond it a Merchant fire (365.6,-178.4) and a chest are loaded.
        if pos.x > 316 then
            local e = { x = 365.6, y = 18.1, z = -178.4 }
            return { name = "the way on east, toward the castle", pos = e, key = "castle_east", walk_point = true,
                dist = math.sqrt((e.x - pos.x) ^ 2 + (e.z - pos.z) ^ 2),
                tip = "Hold W. If you stop and hear no more, press N again." }
        end
        local q = { x = 319.0, y = 18.2, z = -181.2 }
        return { name = "the stone bridge to the castle", pos = q, key = "castle_bridge", walk_point = true,
            dist = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2),
            tip = "Hold W. Walking in may start the next scene." }
    end
    if not in_flee() then return nil end
    if pos.x > 275 then
        -- 11/1: user pressed N, walked straight into the boss, never saw the Merchant.
        -- Merchant first; the boss step says plainly what it does.
        if not st.merchant_done then
            local m = { x = 279.2, y = 9.9, z = -240.2 }
            return { name = "the Merchant", pos = m, key = "flee_merchant",
                dist = math.sqrt((m.x - pos.x) ^ 2 + (m.z - pos.z) ^ 2),
                tip = "Shop and heal there. Press N after that for the boss fight." }
        end
        local q = { x = 284.5, y = 13.9, z = -235.7 }
        return { name = "the boss fight, upstairs", pos = q, key = "flee_next", walk_point = true,
            dist = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2),
            tip = "Warning: walking in starts the Mendez fight and you can't come back. Let go of W now if you are not ready." }
    end
    local d =math.sqrt((EAST.x - pos.x) ^ 2 + (EAST.z - pos.z) ^ 2)
    return { name = EAST.name, pos = { x = EAST.x, y = EAST.y, z = EAST.z }, dist = d, key = "flee_east", walk_point = true,
        tip = "Hold W and keep holding it. I turn you. Don't stop to fight." }
end

local function update()
    local G = RE4Access.game
    if not G or G.cam_busy ~= "chainsaw.PlayerCameraController" then return end
    if G.is_paused and G.is_paused() then return end
    -- 11/1: spoken help for each stage of the Mendez fight
    pcall(function()
        local ot = G.objective_text()
        if type(ot) ~= "string" or not ot:lower():find("defeat m", 1, true) then
            st.boss_stage, G.in_boss = nil, false
            return
        end
        G.in_boss = true
        local p0 = G.player_pos()
        local stage = 1
        for _, e in ipairs(enemies(p0)) do
            if e.t:find("^Ch1f5z1") then stage = 2 end
            -- 11/1 user: "I kept shooting him and he never died". He died at 1295 of 12000.
            if e.t:find("^Ch1f") then
                pcall(function()
                    local h = e.c:call("get_HitPoint")
                    local pct = math.floor(h:call("get_CurrentHitPoint") * 100 / h:call("get_DefaultHitPoint") + 0.5)
                    local step = pct <= 10 and 10 or pct <= 25 and 25 or pct <= 50 and 50 or pct <= 75 and 75 or 100
                    if st.boss_hp_t == e.t and st.boss_hp_step and step < st.boss_hp_step then
                        say(step == 10 and "Mendez almost dead, " .. pct .. " percent." or "Mendez " .. pct .. " percent.", false)
                    end
                    st.boss_hp_t, st.boss_hp_step = e.t, step
                end)
            end
            -- record his moves at any range, to find the wind-up of his throws
            if e.t:find("^Ch1f") then
                pcall(function()
                    local m = e.c:call("get_BodyGameObject"):call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
                    local l = m:call("getLayer", 0)
                    local id = tostring(l:call("get_MotionBankID")) .. "/" .. tostring(l:call("get_MotionID"))
                    if st.boss_motion ~= id then
                        st.boss_motion = id
                        log.info(string.format("[RE4Access] bossrec %s d=%.1f at (%.1f,%.1f,%.1f) motion %s", e.t, e.d, e.x, e.y, e.z, id))
                        -- 11/1 logs: 1/1020 then 1/1022 about 4 s later, hit about 1 s after
                        -- that (4 of 4). 1/1010 then 1/1012 is the same for the second throw,
                        -- taken to be the barrel (guides; unverified). 1/260 = he swings in.
                        if e.t:find("^Ch1f5z1") then
                            -- 11/1 1:20PM log: warning at 1/1022 left 0.85 s, and most throws
                            -- still hit. 1/1022 comes 3.1 to 4.1 s after 1/1020, so warn at
                            -- +2.3 s. 1/260: his hit lands 2.3 to 2.7 s later, warn at +1.4 s.
                            if id == "1/1020" then st.move_at = os.clock() + 2.3
                            elseif id == "1/1012" then st.move_at = os.clock()
                            elseif id == "1/1010" then say("Barrel! Hold L, press K.", true)
                            elseif id == "1/260" then st.move_at = os.clock() + 1.4
                            elseif id == "2/207" then
                                st.move_at = nil
                                log.info("[RE4Access] mendez staggered, barrel or shot")
                            end
                        end
                    end
                end)
            end
        end
        if st.boss_stage ~= stage then
            st.boss_stage = stage
            st.boss_pos, st.boss_since = p0, os.clock()
            say(stage == 1 and "Boss fight, Mendez. Hold L and press K to shoot. If he comes close, hold S to back away. If I say Evade, press E. If I say Grabbed, press Space."
                or "Stage 2. Hold W 2 seconds, then shoot. Do not back up with S. When I say Move, let go of L, hold Shift and A or D. When I say Barrel, shoot. When I say Evade, press E.", false)
        end
        -- 11/1: burns all happen at z -213 to -215.3, x 287 to 291 (behind Leon when he
        -- faces Mendez, so backing up walks him in); none south of z -215.5. The turn
        -- every 3 s + "Move" every 4 s ruined aiming: he did 1 % damage in the 13:05 run.
        -- One warning per entry, turned only when not aiming, nothing when dead.
        if stage == 2 and not G.is_dead then
            if st.move_at and os.clock() >= st.move_at then
                local late = os.clock() - st.move_at
                st.move_at = nil
                if late < 1 then
                    if RE4Access.sound then RE4Access.sound("move") end
                    say("Move! Shift and A or D.", true)
                end
            end
            -- 11/1: last two deaths at 20 and 22 percent with no heal; the game's low
            -- health line is only said once.
            pcall(function()
                local h = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_HitPoint")
                local pct = h:call("get_CurrentHitPoint") * 100 / h:call("get_DefaultHitPoint")
                if pct > 0 and pct <= 40 and os.clock() - (st.heal_at or 0) > 6 then
                    st.heal_at = os.clock()
                    say("Heal now! Press I.", true)
                end
            end)
            local inside =p0.x > 287 and p0.x < 291 and p0.z > -215.3 and p0.z < -213.2
            if inside and not st.fire_in then
                local c = os.clock()
                if c - (st.fire_warn or 0) > 6 then
                    st.fire_warn = c
                    if not reframework:is_key_down(0x4C) then pcall(G.face_point, { x = 289, y = 9.9, z = -219 }, true) end
                    say("Fire behind you! Hold W.", true)
                    log.info(string.format("[RE4Access] fire spot warning at (%.1f,%.1f,%.1f)", p0.x, p0.y, p0.z))
                end
            end
            st.fire_in = inside
        end
    end)
    if not in_flee() then
        if G.in_chase then
            G.in_chase = false
            G.combat_quiet = st.saved_quiet
        end
        st.told, st.still_since = false, nil
        return
    end
    local now = os.clock()
    if st.next_at and now < st.next_at then return end
    st.next_at = now + 1.0
    local pos = G.player_pos()
    if not pos then return end
    -- 11/1: objective stays "Flee" past the autosave at (278,-222). Past it the
    -- route must not pull Leon back and "Hold Shift and W" must stop.
    if pos.x > 275 then
        if math.sqrt((pos.x - 279.2) ^ 2 + (pos.z + 240.2) ^ 2) < 4 then st.merchant_done = true end
        if G.in_chase then
            G.in_chase = false
            G.combat_quiet = st.saved_quiet
            pcall(RE4Access.route.stop, true)
            log.info("[RE4Access] flee: chase over at autosave line")
        end
        st.told = true
        return
    end
    if not st.told then
        st.told = true
        -- 11/1: an F search left from before the scene turned Leon back to Mendez;
        -- lunge/close/aim talk buried the order to run.
        G.fsearch = nil
        G.in_chase = true
        st.saved_quiet = G.combat_quiet
        G.combat_quiet = true
        say(INTRO, true)
        -- Turn away from Mendez at once, even if no route comes: he starts west,
        -- the area trigger (217.1,-214.9) is the other way (route test gave nil
        -- with the game unfocused, so the route alone can't be trusted yet).
        pcall(G.face_point, { x = 217.1, y = 3.8, z = -214.9 }, true)
        st.last_pos, st.still_since = pos, now
        st.route_at = 0
    end
    -- the route starts by itself, and again whenever it has ended
    if not RE4Access.route.active() and now - (st.route_at or 0) > 8 then
        st.route_at = now
        local t = F.step(pos)
        if t then
            G.select(t)
            log.info("[RE4Access] flee: auto route east")
            pcall(RE4Access.route.go, t)
        end
    end
    -- standing still: remind to run (every 8 s at most)
    local moved = st.last_pos and math.sqrt((pos.x - st.last_pos.x) ^ 2 + (pos.z - st.last_pos.z) ^ 2) or 99
    if moved > 1 then st.last_pos, st.still_since = pos, now end
    -- 11/1 user: "it said I stopped but I never released the keys": W held but no
    -- movement = Leon is against something (3 runs stuck at 205.2,-208.1). Say
    -- that and plan again, don't blame the player.
    local held = reframework:is_key_down(0x57)
    if st.still_since and now - st.still_since > (held and 2 or 3) and now - (st.nag_at or 0) > 4 then
        st.nag_at = now
        if held then
            say("Blocked. Finding another way. Keep holding Shift and W.", true)
            log.info(string.format("[RE4Access] flee: blocked at (%.1f,%.1f,%.1f)", pos.x, pos.y, pos.z))
            pcall(RE4Access.route.stop, true)
            st.route_at = 0
        else
            say("Hold Shift and W.", true)
        end
    end
    -- Ashley falling behind (she is the other way to lose here)
    pcall(function()
        local q = RE4Access.ashley.partner():call("get_Position")
        local ad = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
        if ad > 8 and now - (st.ash_at or 0) > 6 then
            st.ash_at = now
            say("Ashley is behind you, " .. math.floor(ad + 0.5) .. " meters. Let go of W a moment.", false)
        end
    end)
    -- log gimmicks near Leon once each (to find the barrel / bridge / path for the real route)
    pcall(function()
        st.seen = st.seen or {}
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            pcall(function()
                local go = e:get_field("value"):call("get_GameObject")
                local k = go:get_address()
                if st.seen[k] then return end
                local q = go:call("get_Transform"):call("get_Position")
                if math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) < 25 then
                    st.seen[k] = true
                    log.info(string.format("[RE4Access] flee gimmick: %s (%.1f,%.1f,%.1f)", go:call("get_Name"), q.x, q.y, q.z))
                end
            end)
        end
    end)
    -- diagnostics every 2 s: where Leon runs, Ashley, what is near (mapping + death cause)
    if now - (st.log_at or 0) >= 2 then
        st.log_at = now
        local en = enemies(pos)
        local parts = {}
        for i = 1, math.min(6, #en) do
            parts[#parts + 1] = string.format("%s %.1f (%.1f,%.1f,%.1f)", en[i].t, en[i].d, en[i].x, en[i].y, en[i].z)
        end
        local ash = "none"
        pcall(function()
            local c = RE4Access.ashley.partner()
            local q = c:call("get_Position")
            local ahp = "?"
            pcall(function() ahp = tostring(c:call("get_HitPoint"):call("get_CurrentHitPoint")) end)
            ash = string.format("(%.1f,%.1f,%.1f) %.1f m kid=%s hp=%s", q.x, q.y, q.z,
                math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2), tostring(c:get_field("<IsKidnapped>k__BackingField")), ahp)
        end)
        local hp = "?"
        pcall(function()
            local h = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_HitPoint")
            hp = math.floor(h:call("get_CurrentHitPoint") * 100 / h:call("get_DefaultHitPoint") + 0.5) .. "%"
        end)
        local line = string.format("flee: leon (%.1f,%.1f,%.1f) hp %s | ashley %s | %s", pos.x, pos.y, pos.z, hp, ash, table.concat(parts, "; "))
        log.info("[RE4Access] " .. line)
        pcall(function()
            local old = fs.read("REAccess_flee_trail.txt") or ""
            fs.write("REAccess_flee_trail.txt", old .. os.date("%H:%M:%S ") .. line .. "\n")
        end)
    end
end

-- N: chase step first (same wrap pattern as siege.lua)
local function wrap()
    local G = RE4Access.game
    if not G or not G.next_step or G.next_step_flee then return end
    local orig = G.next_step
    G.next_step = function(...)
        local pos = G.player_pos()
        local ok, t = pcall(RE4Access.flee.step, pos)   -- 11/2: F.step kept the first-loaded code, so hot-loads never reached N
        if ok and t then
            say("Next: " .. t.name .. ", " .. math.floor(t.dist + 0.5) .. " meters. " .. t.tip, true)
            G.select(t)
            pcall(RE4Access.route.go, t)
            return
        end
        return orig(...)
    end
    G.next_step_flee = true
end

if not RE4Access.flee_hooked then
    RE4Access.flee_hooked = true
    re.on_frame(function()
        local ok, e = pcall(function() RE4Access.flee.update() end)
        if not ok then log.info("[RE4Access] flee error: " .. tostring(e)) end
    end)
end

-- 11/2 read-only: what the game reports while Leon is on the cannon, to build its aiming.
local cannon_log_at = 0
local function cannon_log()
    local now = os.clock()
    if now - cannon_log_at < 1 then return end
    cannon_log_at = now
    local G = RE4Access.game
    local pos = G and G.player_pos and G.player_pos()
    if not pos or math.sqrt((pos.x + 229.8) ^ 2 + (pos.z - 62) ^ 2) > 6 then return end
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            if go:call("get_Name"):find("gm84_572", 1, true) then
                local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCannonV2"))
                if c:get_field("_Routine") ~= 0 then
                    local q = go:call("get_Transform"):call("get_Position")
                    log.info(string.format("[RE4Access] cannon: routine %s rno %s yawmove %s pitchmove %s y %.1f cam %s",
                        tostring(c:get_field("_Routine")), tostring(c:get_field("_Rno")), tostring(c:get_field("_YawMovement")),
                        tostring(c:get_field("_PitchMovement")), q.y, tostring(G.cam_busy)))
                end
            end
        end) end
    end
end

-- 11/2: the cannon speaks. Keys read live: Left/Right arrows turn (Right lowers the angle
-- atan2(x,z) of calcFireDirection), Up/Down raise and lower, K fires. The shot that broke
-- the gate: yaw 113.55, pitch 3.16. A shot at yaw 113.9, pitch 15 missed. Tolerance is a
-- guess: only 1 hit seen. Long holds of Up/Down fired by themselves twice (unexplained),
-- so the speech says tap.
local GATE_YAW, GATE_PITCH, YAW_OK, PITCH_OK = 113.55, 3.16, 1.5, 1.5
local can = { on = false, said = 0, last = "", reload = false }
local function find_cannon()
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then
            local ok, c = pcall(function()
                local go = core:call("get_GameObject")
                if go:call("get_Name"):find("gm84_572", 1, true) then
                    return go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCannonV2"))
                end
            end)
            if ok and c then return c end
        end
    end
end
local function cannon_guide()
    local G = RE4Access.game
    local pos = G and G.player_pos and G.player_pos()
    if G then G.on_cannon = false end
    if not pos or pos.x < -240 or pos.x > -220 or pos.z < 52 or pos.z > 72 or pos.y < 7 then
        can.on = false
        can.c = nil
        return
    end
    if not can.c then can.c = find_cannon() end
    local c = can.c
    if not c then return end
    local routine = c:get_field("_Routine")
    if routine == 0 then
        if can.on and c:get_field("_CurrentTargetParam") then say("The gate is broken. Press N.", true) end
        can.on = false
        return
    end
    G.on_cannon = true
    if G.is_paused() then return end
    local now = os.clock()
    if not can.on then
        can.on = true
        can.said = now
        can.last = ""
        can.reload = false
        say("On the cannon. Left and Right arrows turn it. Tap Up and Down arrows to raise and lower it. K fires. I tell you where the gate is.", true)
        return
    end
    if routine ~= 1 then
        if not can.reload then
            can.reload = true
            log.info("[RE4Access] cannon fired: routine " .. tostring(routine))
            say("Fired. Reloading.", true)
        end
        return
    end
    if can.reload then
        can.reload = false
        can.last = ""
        say("Ready.", true)
    end
    local d = c:call("calcFireDirection")
    local yaw = math.deg(math.atan(d.x, d.z))
    local pitch = math.deg(math.asin(d.y))
    local ey = (yaw - GATE_YAW + 540) % 360 - 180
    local ep = pitch - GATE_PITCH
    local text
    if math.abs(ey) > YAW_OK then
        text = (ey > 0 and "Right " or "Left ") .. math.floor(math.abs(ey) + 0.5)
    elseif math.abs(ep) > PITCH_OK then
        text = (ep > 0 and "Down " or "Up ") .. math.floor(math.abs(ep) + 0.5)
    else
        text = "On target. Press K."
    end
    if text == "On target. Press K." then
        if can.last ~= text then
            can.last = text
            say(text, true)
            log.info(string.format("[RE4Access] cannon on target yaw %.2f pitch %.2f", yaw, pitch))
        end
    elseif now - can.said > 0.8 and text ~= can.last then
        can.said = now
        can.last = text
        say(text, true)
    end
end

-- 11/2: L only aims at the counterweight down in the tower, close to the spot, no enemy near.
local function weight_watch()
    local t = st.weight_t
    if not t then return end
    local G = RE4Access.game
    local pos = G.player_pos()
    if not pos then return end
    local safe = pos.y < 4 and math.sqrt((pos.x - t.pos.x) ^ 2 + (pos.z - t.pos.z) ^ 2) < 3
    if safe then
        for _, e in ipairs(G.enemies(pos, 10)) do
            if math.abs(e.pos.y - pos.y) < 1.5 then safe = false break end
        end
    end
    t.shoot = safe and st.weight_aim or nil
    if safe and not st.weight_told then
        st.weight_told = true
        say("This is the spot. Hold L, it aims at the counterweight. Press K when I say fire.", true)
    end
    if not safe and pos.y >= 4 then st.weight_told = false end
end

-- 11/2 user: hit by catapult rocks with no warning. GmCatapult _DoneRelease goes true
-- as a rock leaves; only Leon on the deck, not inside the tower. Lead time unmeasured:
-- 'catapult' log lines next to 'Hit from' lines show it.
local cat = { at = 0, done = {}, said = -10 }
local function catapult_watch()
    local now = os.clock()
    if now - cat.at < 0.1 then return end
    cat.at = now
    local G = RE4Access.game
    if not G or (G.is_paused and G.is_paused()) then return end
    local pos = G.player_pos()
    if not pos or pos.x < -255 or pos.x > -190 or pos.z < 20 or pos.z > 80 then return end
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            if go:call("get_Name"):find("gm84_569", 1, true) then
                local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCatapult"))
                local d = c:get_field("_DoneRelease")
                local a = go:get_address()
                if d and cat.done[a] == false then
                    log.info("[RE4Access] catapult release " .. go:call("get_Name"))
                    F.rock_at = now
                    if pos.y > 3 and now - cat.said > 2 then
                        cat.said = now
                        say("Rock coming! Keep moving.", true)
                    end
                end
                cat.done[a] = d
            end
        end) end
    end
end

-- At the gap: face over the wall, say the keys, say when the game offers F.
local gap = { said = -20, turned = -20 }
local function gap_watch()
    local g = st.gap_t
    if not g then return end
    local G = RE4Access.game
    if G.is_paused() then return end
    local pos = G.player_pos()
    if not pos then return end
    if pos.x > -242 and pos.y < 8.5 then
        st.gap_t = nil
        log.info("[RE4Access] gap crossed at " .. string.format("%.2f,%.2f,%.2f", pos.x, pos.y, pos.z))
        say("You are over. Press N for the barred door.", true)
        return
    end
    if math.sqrt((pos.x - g.x) ^ 2 + (pos.z - g.z) ^ 2) > 1.0 then return end
    local now = os.clock()
    local on = G.prompt_active()
    if on ~= gap.on then
        log.info(string.format("[RE4Access] gap prompt %s at %.2f,%.2f facing %.0f", tostring(on), pos.x, pos.z, G.facing() or -1))
        gap.on = on
    end
    if not reframework:is_key_down(0x57) and now - gap.turned > 2 then
        gap.turned = now
        pcall(G.face_point, { x = -240, y = 9, z = 44.45 }, true)
    end
    if now - gap.said > 8 then
        gap.said = now
        say("You are at the low wall. Hold W and tap F.", true)
    end
end

-- 11/2: 'Finding the F angle. Hold still.' under the rocks at a walking point. Past the
-- barred door the F search runs only by the cannon or an item; the fallback point goes
-- straight on to the next step.
local function field_f_guard()
    local G = RE4Access.game
    if RE4Access.f_guarded or not G or not G.expect_prompt or not G.start_f_search then return end
    RE4Access.f_guarded = true
    local function blocked()
        if not (RE4Access.flee and RE4Access.flee.state.ch7_door_done) then return false end
        local pos = G.player_pos()
        if not pos or pos.x < -255 or pos.x > -190 or pos.z < 20 or pos.z > 80 then return false end
        if math.sqrt((pos.x + 228.9) ^ 2 + (pos.z - 63.5) ^ 2) < 3 then return false end
        local ok, near = pcall(G.items, pos, 3)
        return not (ok and near and #near > 0)
    end
    local ep = G.expect_prompt
    G.expect_prompt = function(...) if blocked() then return end return ep(...) end
    local sf = G.start_f_search
    G.start_f_search = function(...)
        if blocked() then
            log.info("[RE4Access] F search blocked on the catapult field")
            return true
        end
        return sf(...)
    end
end
-- 11/2: all burn hits on the field were at x -230.3, z 53.3 to 55.9, on the ramp up to the
-- cannon deck, the only way there. 3 hits in 0.4 s killed Leon at 2:53:31.
local fire_told = -30
local function ramp_warn()
    local G = RE4Access.game
    if G.is_paused() then return end
    local pos = G.player_pos()
    if not pos or pos.y < 7 or math.abs(pos.x + 230.3) > 3 then return end
    local now = os.clock()
    if pos.z > 46 and pos.z < 53 or pos.z > 56 and pos.z < 62 then
        if now - fire_told > 20 then
            fire_told = now
            say("Fire on the ramp just ahead. Hold Shift and W, run through, do not stop.", true)
        end
    end
end

F.update = function() wrap() pcall(gong_watch) pcall(hall_watch) pcall(sword_watch) pcall(ramp_warn) pcall(field_f_guard) pcall(cannon_log) pcall(cannon_guide) pcall(weight_watch) pcall(catapult_watch) pcall(gap_watch) update() end
F.state = st
F.intro = INTRO
RE4Access.flee = F
return F
