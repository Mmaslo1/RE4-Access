-- RE4 Access: the map, read aloud (10/18 user: "the map does not read for me...
-- the map needs to be made accessible").
--
-- When the game's map opens (M), and with Shift+O at any time, the mod says:
--   1. the place names the map shows (Quarry, Church, ...), nearest objective first
--   2. your objective, how far and which way
--   3. the nearest typewriter and Merchant (or that none is in this part of the map)
--   4. treasure chests and locked doors nearby
--   5. ways out you have not used yet (doors and gates you have not gone through)
-- While the map is open, anything new the map shows (the name under the cursor,
-- for example "Typewriter") is read when it appears.
--
-- UNTESTED in the game (written 10/18 night with the game closed).

local A = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end
local function G() return RE4Access.game end

-- Words on the map screen that are not places: the legend, tabs and key hints.
local NOT_PLACES = {
    ["map"] = true, ["characters"] = true, ["current location"] = true, ["partner's location"] = true,
    ["objectives"] = true, ["objective"] = true, ["sub objective"] = true, ["exploration"] = true,
    ["typewriter"] = true, ["merchant"] = true, ["mechanism/device"] = true, ["shooting range"] = true,
    ["treasure"] = true, ["locked treasure"] = true, ["blue medallion"] = true, ["strong threat"] = true,
    ["boat"] = true, ["unlocked door"] = true, ["locked door"] = true, ["back"] = true, ["close"] = true,
    ["legend"] = true, ["zoom"] = true, ["floor"] = true, ["select"] = true, ["confirm"] = true,
}

local function map_texts()
    local out, seen = {}, {}
    local M = RE4Access.menu
    local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
    local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local guis = scene:call("findComponents(System.Type)", sdk.typeof("via.gui.GUI"))
    for i = 0, guis:get_size() - 1 do
        pcall(function()
            local gui = guis[i]
            local go = gui:call("get_GameObject")
            local name = go:call("get_Name")
            if not name:find("^Gui_ui31") or not go:call("get_DrawSelf") then return end
            local function walk(c, d)
                if not c or d > 16 then return end
                pcall(function()
                    local tn = c:get_type_definition():get_full_name()
                    if (tn == "via.gui.Text" or tn == "via.gui.MaterialText") and c:call("get_ActualVisible") then
                        local s = M.clean(mg:call(nil, c:call("get_MessageId")) or "")
                        if s == "" then s = M.clean(c:call("get_Message") or "") end
                        if s ~= "" and not seen[s] then seen[s] = true out[#out + 1] = s end
                    end
                end)
                local ch; pcall(function() ch = c:call("get_Child") end)
                while ch do walk(ch, d + 1); local nx; pcall(function() nx = ch:call("get_Next") end); ch = nx end
            end
            walk(gui:call("get_View"), 0)
        end)
    end
    return out
end
A.map_texts = map_texts

local function is_place(s)
    local l = s:lower()
    if NOT_PLACES[l] then return false end
    if #s > 40 or #s < 3 then return false end
    if l:find("^%a$") then return false end            -- key letters Q, E, T, G
    return true
end

local function nearest(list, test)
    for _, t in ipairs(list) do if test(t) then return t end end
end

-- The spoken summary. map_open: called because the map just opened.
function A.summary(map_open)
    local g = G()
    local pos = g.player_pos()
    if not pos then return end
    local f = g.facing()
    local parts = {}
    -- 1. place names the map shows (only when it is open)
    if map_open then
        local places = {}
        local okt, texts = pcall(map_texts)
        local obj
        pcall(function() obj = g.objective_spoken and g.objective_spoken() end)
        for _, s in ipairs(okt and texts or {}) do
            if is_place(s) and s ~= obj then places[#places + 1] = s end
        end
        if #places > 0 then
            while #places > 6 do places[#places] = nil end
            parts[#parts + 1] = "Places on the map: " .. table.concat(places, ", ")
        end
    end
    -- 2. the objective
    local okt, ot = pcall(function() return g.objective_spoken and g.objective_spoken() end)
    local op = g.objective_pos()
    if okt and ot then
        parts[#parts + 1] = "Objective: " .. ot .. (op and (", " .. g.describe_position(op, pos, f)) or "")
    end
    -- 3-5. from the game's own objects in the loaded part of the map
    local things = g.scan_things(pos, 300)
    local tw = nearest(things, function(t) return t.name == "Typewriter, save game" or t.name == "Typewriter" end)
    parts[#parts + 1] = tw and ("Nearest typewriter, " .. g.describe_position(tw.pos, pos, f))
        or "No typewriter in this part of the map"
    local mer = nearest(things, function(t) return t.name == "Merchant" end)
    if mer then parts[#parts + 1] = "Merchant, " .. g.describe_position(mer.pos, pos, f) end
    local chests = 0
    local first_chest
    for _, t in ipairs(things) do
        if t.name == "Treasure chest" and t.dist < 80 and not (g.gimmick_done and g.gimmick_done(t.go)) then
            chests = chests + 1
            first_chest = first_chest or t
        end
    end
    if first_chest then
        parts[#parts + 1] = chests .. (chests == 1 and " treasure chest" or " treasure chests") .. " not opened nearby, nearest " .. g.describe_position(first_chest.pos, pos, f)
    end
    local locked, unused = {}, {}
    for _, t in ipairs(things) do
        if (t.name == "Door" or t.name == "Gate") and t.dist < 60 and t.go then
            local okl, lk = pcall(g.door_locked, t.go)
            if okl and lk then
                locked[#locked + 1] = t
            elseif not RE4Access.used_doors[t.key] then
                unused[#unused + 1] = t
            end
        end
    end
    if #locked > 0 then
        parts[#parts + 1] = #locked .. (#locked == 1 and " locked door" or " locked doors") .. ", nearest " .. g.describe_position(locked[1].pos, pos, f)
    end
    if #unused > 0 then
        local w = {}
        for i = 1, math.min(3, #unused) do w[#w + 1] = unused[i].name:lower() .. " " .. g.describe_position(unused[i].pos, pos, f) end
        parts[#parts + 1] = "Ways you have not gone through yet: " .. table.concat(w, "; ")
    end
    if map_open then parts[#parts + 1] = "Press M to close the map. Shift+O repeats this in the game" end
    say(table.concat(parts, ". ") .. ".", true)
end

-- Map open/close and the cursor: new texts on the map screen are read.
local map_seen = nil
function A.on_map(open)
    if open then
        map_seen = {}
        local ok, texts = pcall(map_texts)
        for _, s in ipairs(ok and texts or {}) do map_seen[s] = true end
        local oks, err = pcall(A.summary, true)
        if not oks then log.info("[RE4Access] map summary error: " .. tostring(err)) say("Map screen open. Press M to close it.", true) end
    else
        map_seen = nil
    end
end
local next_check = 0
function A.on_frame()
    if not map_seen then return end
    local now = os.clock()
    if now < next_check then return end
    next_check = now + 0.3
    local ok, texts = pcall(map_texts)
    if not ok then return end
    -- read what appeared since the last look (a name under the cursor comes
    -- back each time you move onto it again)
    local now_set, new = {}, {}
    for _, s in ipairs(texts) do
        now_set[s] = true
        if not map_seen[s] then new[#new + 1] = s end
    end
    map_seen = now_set
    if #new > 0 then say(table.concat(new, ". "), false) end
end

RE4Access.mapread = A
re.on_frame(function() pcall(A.on_frame) end)
return A
