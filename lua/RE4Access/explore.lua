-- RE4 Access: Explore mode and Side quests (11/11/2026, user asked for both).
--
-- EXPLORE MODE (F9 on/off, saved): for players who want to find the way themselves,
-- the way a sighted player looks around a room instead of following a line.
--   N           no route: says the goal, how far and which way only.
--   Walking help (N routes, Shift+Backslash, B) is off while Explore mode is on.
--   F10         Look around: open space or walls in 8 directions, room size,
--               the nearest things worth knowing about.
--   F11         Next exit (doors, gates, ladders, shutters, elevators), with
--               distance, direction, up or down, and whether you have been through it.
--               It is also picked, so Backslash turns you to it. Shift+F11: all exits.
--
-- SIDE QUESTS (F12): picks one of your requests, or the main story again.
--   With a request picked, N leads to its next target instead of the story:
--   rats (shoot or knife them; L aims at the rat), blue medallions (L aims at it,
--   then K), and the Merchant when a request is done (for the reward).
--   Shift+F12: the picked request and its progress.
--
-- Keys stay silent in menus, the shop, cutscenes and while paused.

local X = {}
local function G() return RE4Access.game end
local function R() return RE4Access.route end
local function say(t, interrupt) RE4Access.speak(t, interrupt ~= false) end

X.explore = (fs.read("REAccess_explore.txt") or ""):find("1", 1, true) ~= nil
X.quest = nil          -- { id = document id, title = ..., kind = "rats" | "coins" | "other" }
X.exit_i = 0
X.passed = {}          -- door keys Leon has walked through (within 1.3 m)

-- ---------------- directions ----------------
local function bearing(dx, dz) return (math.deg(math.atan(dx, dz)) + 360) % 360 end
local function rel_word(pos, q)
    local f = G().facing() or 0
    local rel = (bearing(q.x - pos.x, q.z - pos.z) - f + 540) % 360 - 180
    local a = math.abs(rel)
    local side = rel < 0 and "left" or "right"
    if a < 25 then return "ahead"
    elseif a < 70 then return "ahead " .. side
    elseif a < 115 then return side
    elseif a < 155 then return "behind " .. side
    else return "behind" end
end
local function height_word(pos, q)
    local dy = q.y - pos.y
    if dy > 1.5 then return string.format(", %d meters up", math.floor(dy + 0.5)) end
    if dy < -1.5 then return string.format(", %d meters down", math.floor(-dy + 0.5)) end
    return ""
end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
X.rel_word, X.height_word = rel_word, height_word

-- ---------------- explore mode ----------------
function X.set_explore(on)
    X.explore = on
    pcall(fs.write, "REAccess_explore.txt", on and "1" or "0")
    if on then
        pcall(function() R().stop(true) end)
        say("Explore mode on. N says the goal only, no walking help. F10 look around, F11 exits. F9 turns it off.")
    else
        say("Explore mode off. N walks you again.")
    end
end

local SKIP = { ["Breakable crate"] = true, ["Smooth Wood Box"] = true, Crow = true, Fish = true, ["Loop Motion2"] = true,
    ["Map Icon Only"] = true, ["Keep In Camera"] = true, ["Port On Off Flag"] = true, ["Auto Save Indispensable"] = true }
local function notable(t)
    local n = tostring(t.name)
    if SKIP[n] or n:sub(1, 10) == "Path point" or n:find("Area", 1, true) or n:find("Hedge Jump", 1, true) then return false end
    return true
end

function X.look()
    local g, r = G(), R()
    local pos = g.player_pos()
    if not pos then return end
    local f = g.facing() or 0
    local names = { "ahead", "ahead right", "right", "behind right", "behind", "behind left", "left", "ahead left" }
    local dist = {}
    local parts = {}
    for i = 0, 7 do
        local a = math.rad(f + i * 45)
        local far = 30
        local hit, dd = r.cast(pos.x, pos.y + 1.2, pos.z, pos.x + math.sin(a) * far, pos.y + 1.2, pos.z + math.cos(a) * far)
        dist[i] = hit and dd or far
    end
    for _, i in ipairs({ 0, 2, 4, 6 }) do
        local d = dist[i]
        parts[#parts + 1] = names[i + 1] .. (d >= 29.5 and " open" or string.format(" %d", math.floor(d + 0.5)))
    end
    local wide = math.floor(dist[2] + dist[6] + 0.5)
    local long = math.floor(dist[0] + dist[4] + 0.5)
    local size
    if wide >= 40 or long >= 40 then size = "Big open area"
    else size = string.format("Room about %d by %d meters", long, wide) end
    local text = size .. ". Walls: " .. table.concat(parts, ", ") .. "."
    -- 11/11: in some rooms (the Merchant's) the rays hit nothing, not even the floor
    local floor_hit = r.cast(pos.x, pos.y + 1.5, pos.z, pos.x, pos.y - 2, pos.z)
    if not floor_hit then text = "I can't measure the walls in this room." end
    -- the nearest things worth knowing about
    local things = {}
    for _, t in ipairs(g.scan_things(pos, 15)) do
        if notable(t) and math.abs(t.pos.y - pos.y) < 4 then things[#things + 1] = t end
    end
    table.sort(things, function(a, b) return a.dist < b.dist end)
    local tl = {}
    for i = 1, math.min(4, #things) do
        local t = things[i]
        tl[#tl + 1] = string.format("%s %d %s%s", t.name, math.floor(t.dist + 0.5), rel_word(pos, t.pos), height_word(pos, t.pos))
    end
    if #tl > 0 then text = text .. " Near: " .. table.concat(tl, ", ") .. "." end
    local ni = 0
    pcall(function() ni = #g.items(pos, 15) end)
    local ne = 0
    pcall(function() for _, e in ipairs(g.enemies(pos, 20)) do if math.abs(e.pos.y - pos.y) < 3 then ne = ne + 1 end end end)
    if ni > 0 then text = text .. " " .. ni .. (ni == 1 and " item" or " items") .. " within 15 meters." end
    if ne > 0 then text = text .. " " .. ne .. (ne == 1 and " enemy" or " enemies") .. " within 20 meters." end
    say(text)
end

local EXIT = { Door = true, Gate = true, Ladder = true, ["Foldable Ladder"] = true, Shutter = true, ["Elevator Door"] = true,
    ["Immediately Shutter"] = true, Trapdoor = true, Window = true, Stairs = true }
local function exits(pos)
    local out = {}
    for _, t in ipairs(G().scan_things(pos, 40)) do
        if EXIT[t.name] and math.abs(t.pos.y - pos.y) < 4.5 then
            local c = t.pos
            pcall(function() local ok, cc = pcall(G().door_center_of, t) if ok and cc then c = cc end end)
            out[#out + 1] = { t = t, c = c, dist = d2(c, pos) }
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end
local function exit_text(pos, e)
    local t = e.t
    local s = string.format("%s, %d meters, %s%s", t.name, math.floor(e.dist + 0.5), rel_word(pos, e.c), height_word(pos, e.c))
    if X.passed[t.key] then s = s .. ", been through" end
    pcall(function() if G().gimmick_done(t.go) and t.name ~= "Door" then s = s .. ", open" end end)
    return s
end
function X.next_exit(all)
    local pos = G().player_pos()
    if not pos then return end
    local list = exits(pos)
    if #list == 0 then say("No doors or ladders within 40 meters.") return end
    if all then
        local tl = {}
        for i = 1, math.min(8, #list) do tl[#tl + 1] = exit_text(pos, list[i]) end
        say(#list .. " exits. " .. table.concat(tl, ". ") .. ".")
        return
    end
    X.exit_i = X.exit_i % #list + 1
    local e = list[X.exit_i]
    pcall(G().select, { name = e.t.name, pos = e.c, dist = e.dist, key = e.t.key, go = e.t.go })
    say("Exit " .. X.exit_i .. " of " .. #list .. ": " .. exit_text(pos, e) .. ". Backslash faces it." ..
        ((e.t.name == "Door") and " Doors open when you hold W into them." or ""))
end

-- remember doors walked through
local pass = { at = 0 }
local function track_passed(pos, now)
    if now - pass.at < 0.5 then return end
    pass.at = now
    for _, t in ipairs(G().scan_things(pos, 3)) do
        if (t.name == "Door" or t.name == "Gate") and d2(t.pos, pos) < 1.6 then X.passed[t.key] = true end
    end
end

-- N in explore mode: the goal, no route
local function explore_n()
    local g = G()
    local pos = g.player_pos()
    if not pos then return end
    local st
    -- what the guide would pick, without walking there
    local okq, qt = pcall(X.quest_target, pos)
    if X.quest and okq and qt then st = qt end
    if not st then
        pcall(function()
            local ot = g.objective_text and g.objective_text() or ""
            local o = g.objective_pos and g.objective_pos()
            st = { name = "Objective: " .. tostring(ot), pos = o }
        end)
    end
    if not st then say("No goal known.") return end
    if st.pos then
        say(string.format("%s. %d meters, %s%s. Explore mode: find your own way.", st.name, math.floor(d2(st.pos, pos) + 0.5), rel_word(pos, st.pos), height_word(pos, st.pos)))
    else
        say(st.name .. ". Explore mode: find your own way.")
    end
end

-- ---------------- side quests ----------------
local QUEST_BASE = 20000
local function fm() return sdk.get_managed_singleton("chainsaw.FileManager") end
local function clean(s) return RE4Access.menu.clean(s or "") or "" end
local msg_get = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
local function title_of(id)
    local d = fm():call("getSingleDocumentData", id)
    if not d then return "" end
    return clean(msg_get:call(nil, d:get_field("<TitleGuid>k__BackingField")))
end
local function phase_of(id)
    local qm = sdk.get_managed_singleton("chainsaw.QuestManager")
    local o = qm:call("getQuestOrder(chainsaw.QuestFileID)", id - QUEST_BASE)
    return o and o:get_field("<CurrPhase>k__BackingField")
end
function X.requests()
    local m, out = fm(), {}
    for id = QUEST_BASE + 1, QUEST_BASE + 60 do
        local okd, d = pcall(m.call, m, "getSingleDocumentData", id)
        if okd and d and m:call("IsOpenedFile", id) then
            local ph = 0
            pcall(function() ph = phase_of(id) or 0 end)
            if ph ~= 5 and ph ~= 7 then
                local st = ""
                pcall(function() st = RE4Access.files.quest_status(id) end)
                local low = st:lower()
                local kind = "other"
                if low:find("rat", 1, true) then kind = "rats"
                elseif low:find("medallion", 1, true) then kind = "coins" end
                out[#out + 1] = { id = id, title = title_of(id), status = st, kind = kind, phase = ph }
            end
        end
    end
    return out
end

function X.pick_next()
    local list = X.requests()
    local i = 0
    if X.quest then
        for k, q in ipairs(list) do if q.id == X.quest.id then i = k end end
    end
    i = i + 1
    if i > #list then
        X.quest = nil
        say("Main story. N follows the story again." .. (#list > 0 and (" F12 for your " .. #list .. " requests.") or " You have no open requests."))
        return
    end
    X.quest = list[i]
    say("Side quest " .. i .. " of " .. #list .. ": " .. X.quest.title .. ". " .. X.quest.status .. ". N leads there. F12 again for the next one or the main story.")
end

function X.quest_info()
    if not X.quest then say("No side quest picked. Main story. F12 picks one.") return end
    local st = ""
    pcall(function() st = RE4Access.files.quest_status(X.quest.id) end)
    say(X.quest.title .. ". " .. st)
end

local function alive_rat(t)
    local ok, dead = pcall(function() return G().gimmick_done(t.go) or not t.go:call("get_DrawSelf") end)
    return ok and not dead
end
local function coin_left(t)
    local ok, done = pcall(function() return G().gimmick_done(t.go) or not t.go:call("get_DrawSelf") end)
    return ok and not done
end

function X.quest_target(pos)
    local q = X.quest
    if not q then return nil end
    local ph = 0
    pcall(function() ph = phase_of(q.id) or 0 end)
    if ph == 4 then
        -- done: the Merchant pays the reward
        local best
        for _, k in ipairs(G().known or {}) do
            if k.name == "Merchant" and (not best or d2(k.pos, pos) < d2(best.pos, pos)) then best = k end
        end
        if best then return { name = "the Merchant, for the reward", pos = best.pos, dist = d2(best.pos, pos), tip = "Request done. Talk to him with F, then the Requests tab." } end
        return { name = "Request done", no_route = true, tip = "Go to any Merchant for the reward." }
    end
    if ph == 5 or ph == 7 then X.quest = nil return { name = "Request finished", no_route = true, tip = "Back to the main story." } end
    local word, test = nil, nil
    if q.kind == "rats" then word, test = "ネズミ", alive_rat
    elseif q.kind == "coins" then word, test = "青コイン", coin_left end
    if not word then
        return { name = q.title, no_route = true, tip = q.status .. ". I can't lead you to this one yet." }
    end
    -- locked doors (11/11: a rat behind a locked door; the walking map goes through doors)
    local locked = {}
    for _, t in ipairs(G().scan_things(pos, 150)) do
        if t.name == "Door" then
            pcall(function()
                local c = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmDoor"))
                if c and c:get_field("_WasLocked") and (c:get_field("_OpenValue") or 0) < 1 then locked[#locked + 1] = t.pos end
            end)
        end
    end
    local function blocked(q2)
        local ok, pts = pcall(R().nav_points, pos, { x = q2.x, y = q2.y, z = q2.z })
        if not ok or not pts or #pts == 0 then return true end
        local e = pts[#pts]
        if d2(e, q2) > 3 then return true end
        for _, pt in ipairs(pts) do
            for _, L in ipairs(locked) do
                if d2(pt, L) < 1.6 and math.abs(pt.y - L.y) < 2 then return true end
            end
        end
        return false
    end
    local best, behind = nil, 0
    for _, t in ipairs(G().scan_things(pos, 150)) do
        local okn, n = pcall(function() return t.go:call("get_Name") end)
        if okn and n and n:find(word, 1, true) and test(t) then
            if q.kind == "rats" and blocked(t.pos) then behind = behind + 1
            elseif not best or t.dist < best.dist then best = t end
        end
    end
    if not best then
        local why = behind > 0 and (behind .. (behind == 1 and " is" or " are") .. " behind a locked door: later in the story. ") or "None of them is near here. "
        return { name = q.title, no_route = true, tip = why .. q.status }
    end
    local label = q.kind == "rats" and "Rat" or "Blue medallion"
    return { name = label, pos = best.pos, dist = best.dist, key = best.key, go = best.go,
        shoot = { x = best.pos.x, y = best.pos.y + (q.kind == "rats" and 0.1 or 0), z = best.pos.z, label = label },
        walk_point = true,
        tip = q.kind == "rats" and "When close, hold L to aim at the rat, then K. Or knife it with Space." or "Hold L to aim at it, then K." }
end

local function quest_n()
    local pos = G().player_pos()
    if not pos then return end
    local t = X.quest_target(pos)
    if not t then return false end
    if t.no_route then say(t.name .. ". " .. (t.tip or "")) return true end
    pcall(G().select, t)
    if t.dist and t.dist < 6 then
        say(string.format("%s, %d meters, %s%s. %s", t.name, math.floor(t.dist + 0.5), rel_word(pos, t.pos), height_word(pos, t.pos), t.tip or ""))
        return true
    end
    say("Side quest. Next: " .. t.name .. ". " .. (t.tip or ""))
    RE4Access.speak_hold = true
    pcall(R().go, t)
    RE4Access.speak_hold = nil
    return true
end

-- keep L aimed at a moving rat
local follow = { at = 0 }
local function follow_target(pos, now)
    if now - follow.at < 0.3 or not X.quest or X.quest.kind ~= "rats" then return end
    follow.at = now
    pcall(function()
        local t = X.quest_target(pos)
        if t and t.shoot and t.dist and t.dist < 15 then G().select(t) end
    end)
end

-- ---------------- hooks into N and walking help ----------------
-- N with Explore mode or a side quest: true when handled here
function X.handle_n()
    if X.explore then explore_n() return true end
    if X.quest then
        local ok, done = pcall(quest_n)
        if ok and done then return true end
        if not ok then log.info("[RE4Access] side quest N: " .. tostring(done)) end
    end
    return false
end

-- the wrappers always ask the CURRENT module (hot reloads replace it)
function X.install()
    local g = G()
    if g and g.next_step and not g.next_step_before_explore then
        g.next_step_before_explore = g.next_step
        g.next_step = function(...)
            local E = RE4Access.explore
            if E and E.handle_n then
                local ok, h = pcall(E.handle_n)
                if ok and h then return end
            end
            return g.next_step_before_explore(...)
        end
    end
    local r = R()
    if r and r.go and not r.go_before_explore then
        r.go_before_explore = r.go
        r.go = function(t, ...)
            local E = RE4Access.explore
            if E and E.explore then
                say("Explore mode: no walking help. F9 turns it off.")
                return
            end
            return r.go_before_explore(t, ...)
        end
    end
end

-- ---------------- weapon keys 1-8: say what is now in hand ----------------
-- 11/11 user: "I hit 2 and nothing happens": the mod only announced guns.
local NUM = { [0x31] = { 0, 0 }, [0x32] = { 0, 1 }, [0x33] = { 0, 2 }, [0x34] = { 0, 3 },
    [0x35] = { 2, 0 }, [0x36] = { 2, 1 }, [0x37] = { 2, 2 }, [0x38] = { 2, 3 } }
local numwas = {}
function X.say_slot(stype, dir)
    local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
    local infos = G().leon_inv():call("getShortcutInfos")
    for i = 0, infos:call("get_Count") - 1 do
        local si = infos:call("get_Item", i)
        if si:get_field("<ShortcutType>k__BackingField") == stype and si:get_field("<Direction>k__BackingField") == dir then
            local id = si:get_field("<ItemId>k__BackingField")
            if not id or id <= 0 then say("Nothing on this key.") return end
            local nm = clean(msg_get:call(nil, mm:call("getItemNameMsgId", id)))
            local n = si:get_field("<ItemCount>k__BackingField") or 0
            if nm:find("Grenade", 1, true) then
                if n <= 0 then say(nm .. ": none left.") else say(nm .. ". Hold L to aim, K to throw. Throw it far, the blast hurts you too.") end
            end
            return
        end
    end
end

-- ---------------- keys ----------------
local VK = { F9 = 0x78, F10 = 0x79, F11 = 0x7A, F12 = 0x7B, SHIFT = 0x10 }
local was = {}
local function quiet()
    local g = G()
    if not g then return true end
    local ok, paused = pcall(g.is_paused)
    if ok and paused then return true end
    if g.state_text and g.state_text ~= "In control" then return true end
    return false
end
re.on_frame(function()
    if RE4Access.explore ~= X then return end
    local now = os.clock()
    pcall(X.install)
    local okp, pos = pcall(function() return G().player_pos() end)
    if okp and pos then
        pcall(track_passed, pos, now)
        pcall(follow_target, pos, now)
    end
    for vk, sd in pairs(NUM) do
        local down = reframework:is_key_down(vk)
        if down and not numwas[vk] and not quiet() then pcall(X.say_slot, sd[1], sd[2]) end
        numwas[vk] = down
    end
    for name, vk in pairs(VK) do
        if name ~= "SHIFT" then
            local down = reframework:is_key_down(vk)
            if down and not was[name] and not quiet() then
                local shift = reframework:is_key_down(VK.SHIFT)
                local ok, e = pcall(function()
                    if name == "F9" then X.set_explore(not X.explore)
                    elseif name == "F10" then X.look()
                    elseif name == "F11" then X.next_exit(shift)
                    elseif name == "F12" then if shift then X.quest_info() else X.pick_next() end end
                end)
                if not ok then log.info("[RE4Access] explore key " .. name .. ": " .. tostring(e)) end
            end
            was[name] = down
        end
    end
end)

RE4Access.explore = X
return X
