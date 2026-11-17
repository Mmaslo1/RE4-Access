-- RE4 Access: the siege in Luis's house, "Stand your ground" (chapter 5, 10/22).
-- The user died there: the mod said "F ready: Item, pick it up" at the window
-- barricades and F did nothing; the ladders were never mentioned.
-- Live-read 10/22: chainsaw.GmSiegeBarricade (バリケード, 3 downstairs windows,
-- _Routine 0 at the start, get_IsBlocking / get_IsBroken, _KnockNum hits it
-- takes) and chainsaw.GmLeaningLadder (立てかけハシゴ, 2 outside, _Routine 5 at
-- the start; enemies stand them up to the upper floor, Leon kicks them off).
-- Routine numbers are logged ("siege:") because their meaning is not known yet.

local S = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end
local st = { told = false, bar = {}, lad = {} }

local function in_siege()
    local G = RE4Access.game
    local ok, ot = pcall(G.objective_text)
    return ok and type(ot) == "string" and ot:lower():find("stand your ground", 1, true) ~= nil
end

local function call(c, m)
    local ok, v = pcall(function() return c:call(m) end)
    if ok then return v end
end

-- { go, comp, pos, kind = "barricade"/"ladder", routine, blocking, broken, standing }
function S.things()
    local out = {}
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    if not gm then return out end
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        pcall(function()
            local go = e:get_field("value"):call("get_GameObject")
            for kind, tn in pairs({ barricade = "chainsaw.GmSiegeBarricade", ladder = "chainsaw.GmLeaningLadder" }) do
                local c = go:call("getComponent(System.Type)", sdk.typeof(tn))
                if c then
                    local q = go:call("get_Transform"):call("get_Position")
                    out[#out + 1] = { go = go, comp = c, kind = kind, key = go:get_address(),
                        pos = { x = q.x, y = q.y, z = q.z }, routine = c:get_field("_Routine"),
                        blocking = kind == "barricade" and call(c, "get_IsBlocking") or nil,
                        broken = kind == "barricade" and call(c, "get_IsBroken") or nil,
                        standing = kind == "ladder" and call(c, "get_SetStanding") or nil }
                end
            end
        end)
    end
    return out
end

-- Enemies within r m (same rules as game.lua: alive, no crows).
local function enemies_near(pos, r)
    local n = 0
    pcall(function()
        local l = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
        for i = 0, l:call("get_Count") - 1 do
            pcall(function()
                local e = l:call("get_Item", i)
                local live = true
                pcall(function() live = e:call("get_HitPoint"):call("get_IsLive") end)
                if live == false or e:get_type_definition():get_name():find("^Ch8g") then return end
                local q = e:call("get_Position")
                if math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) < r and math.abs(q.y - pos.y) < 2.5 then n = n + 1 end
            end)
        end
    end)
    return n
end
S.enemies_near = enemies_near

-- Number keys 1-4 (10/22 live: pressed one by one): 1 = shortcut Direction 3,
-- 2 = Direction 0, 3 = Direction 2, 4 = Direction 1 (CsInventoryController
-- getShortcutInfos; Direction is not the key order).
local KEY_DIR = { 3, 0, 2, 1 }
function S.keys_text()
    local by_dir = {}
    pcall(function()
        local inv = RE4Access.game.leon_inv()
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        local getm = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
        local arr = inv:call("getShortcutInfos")
        for j = 0, arr:call("get_Count") - 1 do
            local si = arr:call("get_Item", j)
            local id = si:get_field("<ItemId>k__BackingField")
            if si:get_field("<ShortcutType>k__BackingField") == 0 and id and id > 0 then
                local n = RE4Access.menu.clean(getm:call(nil, mm:call("getItemNameMsgId", id)))
                local c = si:get_field("<ItemCount>k__BackingField") or 0
                if n:find("Grenade") then n = n .. (c > 0 and (", " .. c) or ", none left") end
                by_dir[si:get_field("<Direction>k__BackingField")] = n
            end
        end
    end)
    local out = {}
    for k, d in ipairs(KEY_DIR) do if by_dir[d] then out[#out + 1] = k .. " " .. by_dir[d] end end
    return #out > 0 and ("Number keys: " .. table.concat(out, ". ") .. ".") or ""
end

-- N during the siege: Wooden Planks lying in the house first (a barricade
-- takes one: F at the window opens "use a key item"; 10/22 the user had only
-- the Old Wayshrine Key there and nothing worked), then the nearest open window.
function S.step(pos)
    if not in_siege() then return nil end
    local open_left = false
    for _, t in ipairs(S.things()) do if t.kind == "barricade" and not t.blocking then open_left = true end end
    if not open_left then return nil end
    -- 10/22: walking to planks or a window with villagers on you gets you killed,
    -- and the game blocks both while an enemy is next to you or at the window.
    if enemies_near(pos, 4) > 0 then
        return { fight = true, tip = "Enemies are close. Fight first: hold L, press K, and press F after a hit to kick. Press N again when it is quiet." }
    end
    local plank
    for _, it in ipairs(RE4Access.game.items(pos, 30)) do
        if it.name:find("Wooden Plank", 1, true) and math.abs(it.pos.y - pos.y) < 3 and (not plank or it.dist < plank.dist) then plank = it end
    end
    if plank then
        return { name = "Wooden Planks", pos = plank.pos, dist = plank.dist, key = plank.key, go = plank.go, item = true,
            tip = "Pick them up with F. A window needs Wooden Planks to block it. Then press N again for the window." }
    end
    local best
    for _, t in ipairs(S.things()) do
        if t.kind == "barricade" and not t.blocking then
            t.dist = math.sqrt((t.pos.x - pos.x) ^ 2 + (t.pos.z - pos.z) ^ 2)
            if math.abs(t.pos.y - pos.y) < 3 and (not best or t.dist < best.dist) then best = t end
        end
    end
    if best then
        return { name = "Window barricade", pos = best.pos, dist = best.dist, key = best.key, go = best.go,
            tip = "Face the window and press F. A list opens: pick Wooden Planks and choose Use. If you have no planks, the list shows none: fight instead." }
    end
end

local function update()
    local G = RE4Access.game
    if not G or G.cam_busy ~= "chainsaw.PlayerCameraController" then return end
    if G.is_paused and G.is_paused() then return end
    if not in_siege() then st.told = false return end
    local now = os.clock()
    if st.next_at and now < st.next_at then return end
    st.next_at = now + 0.5
    local pos = G.player_pos()
    if not pos then return end
    local things = S.things()
    local open = 0
    for _, t in ipairs(things) do if t.kind == "barricade" and not t.blocking then open = open + 1 end end
    if not st.told then
        st.told = true
        -- What won it on 10/22 (Claude, live, Assisted): keep firing with the aim
        -- lock, kick after hits, grenade into groups, heal in the case (it pauses).
        say("Siege. Survive about 5 minutes until a cutscene ends it. Villagers come in at once. Stand still and fight: hold L, press K again and again, press F after a hit to kick. "
            .. "When 3 or more are close, throw a grenade: its number key, hold L, press K. Use the shotgun when they are right on you. When health is low, open the case with Tab: the game pauses, heal there. "
            .. S.keys_text() .. " When it is quiet, press N: Wooden Planks on the table block a window: F to take them, then F at a window, pick Wooden Planks, Use. Luis helps you: stay near him.", false)
    end
    for _, t in ipairs(things) do
        local old = (t.kind == "barricade" and st.bar or st.lad)[t.key]
        local where = G.describe_position(t.pos, pos, G.facing())
        if old and old.routine ~= t.routine then
            log.info(string.format("[RE4Access] siege: %s at (%.1f,%.1f,%.1f) routine %s -> %s blocking %s broken %s standing %s",
                t.kind, t.pos.x, t.pos.y, t.pos.z, tostring(old.routine), tostring(t.routine), tostring(t.blocking), tostring(t.broken), tostring(t.standing)))
        end
        if t.kind == "barricade" and old then
            if t.blocking and not old.blocking then say("Window blocked. " .. (open > 0 and (open .. " still open. Press N for the next.") or "All windows blocked."), true)
            elseif t.broken and not old.broken then say("A barricade broke, " .. where .. ". Enemies come in there.", true) end
        elseif t.kind == "ladder" and old and t.standing ~= old.standing and t.standing then
            say("A ladder is going up outside, " .. where .. ". Go upstairs and kick it off with F.", true)
        end
        (t.kind == "barricade" and st.bar or st.lad)[t.key] = { routine = t.routine, blocking = t.blocking, broken = t.broken, standing = t.standing }
    end
end

-- N: siege step first (wraps the game.lua key path, which calls G.next_step)
local function wrap()
    local G = RE4Access.game
    if not G or not G.next_step or G.next_step_siege then return end
    local orig = G.next_step
    G.next_step = function(...)
        local pos = G.player_pos()
        local ok, t = pcall(S.step, pos)
        if ok and t and t.fight then
            say(t.tip, true)
            return
        end
        if ok and t then
            say("Next: " .. t.name:lower() .. ", " .. G.describe_position(t.pos, pos, G.facing()) .. ". " .. t.tip, true)
            G.select(t)
            pcall(RE4Access.route.go, t)
            return
        end
        return orig(...)
    end
    G.next_step_siege = true
end

if not RE4Access.siege_hooked then
    RE4Access.siege_hooked = true
    re.on_frame(function()
        local ok, e = pcall(function() RE4Access.siege.update() end)
        if not ok then log.info("[RE4Access] siege error: " .. tostring(e)) end
    end)
end

S.update = function() wrap() update() end
S.state = st
RE4Access.siege = S
return S
