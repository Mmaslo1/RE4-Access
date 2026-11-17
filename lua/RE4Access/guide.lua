-- RE4 Access: puzzle guide. Everything a player needs to know about a puzzle is
-- spoken by the mod itself (10/17: the user only learned how the Chief's closet
-- dial lock and the crystal ball work from Claude in chat - "how would I know
-- any of this?"). Two parts:
--  * tips: walking up to an unsolved puzzle (2.5 m, same floor) says once what
--    it is, what it needs and which keys work. Y repeats it.
--  * step(pos): used by N / question mark: the next puzzle to do, if any.

local U = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end

local CRYSTAL_MARBLE = 119217600   -- ItemID, live-read 10/17

local TIPS = {
    attic_lever = "Lever for the attic hatch, behind the picture. The attic ladder needs Ashley: she climbs up and lowers it for you, later in the story. "
        .. "Pulling it now does nothing useful. Come back with Ashley; the attic has a Yellow Herb and an Antique Camera.",
    dial = "Dial lock on a cabinet. The code is a row of pictures, and the clue is in a document nearby: read documents with F, I read them aloud. "
        .. "Press F to use the lock. A and D pick a ring, W and S turn it. I say each picture, and I name the right one when a ring is right. When all are right, press F.",
    dial_chief = "Dial lock on the closet. The clue is the Iluminados document upstairs: the farmer's crop, the swineherd's pig, the grandam's babe. "
        .. "Press F to use the lock. A and D pick a ring, W and S turn it. Set crop, pig, baby, then press F. The Crystal Marble is inside.",
    crystal_need = "Crystal ball puzzle. It opens the door next to it. It needs the Crystal Marble, from the closet with the dial lock downstairs. "
        .. "Pick Crystal Marble in Items and press Backslash to go there.",
    crystal_have = "Crystal ball puzzle. You have the Crystal Marble: press F and choose it. "
        .. "Then press F again. When you hear Turning the crystal ball, press Backslash, and I turn it to the right spot for you.",
    crystal_turn = "Crystal ball. Press F. When you hear Turning the crystal ball, press Backslash, and I turn it to the right spot for you.",
}

local function dial_unsolved(go)
    local lk = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmLocker"))
    if not lk then return false end
    -- Opened already: the game marks the locker done; its rings stay wherever they
    -- were (10/18: Chief's closet opened 10/17 still read as unsolved).
    local okd, done = pcall(function() return lk:call("get_Context"):call("hasDoneForMap") end)
    if okd and done then return false end
    for _, dl in ipairs(lk:get_field("_DialLocks"):get_elements()) do
        for _, b in ipairs(dl:get_field("_Blocks"):get_elements()) do
            if b:get_field("_Index") ~= b:get_field("_Correct") then return true end
        end
    end
    return false
end

-- State of a crystal ball: nil when solved (its door is open / unlocked).
local function crystal_state(t)
    local G = RE4Access.game
    local c = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPuzzleCrystalBall"))
    if not c then return nil end
    for _, d in ipairs(G.scan_things(t.pos, 3)) do
        if d.name == "Door" and d.go:call("get_Name"):find("水晶パズル", 1, true) and not G.door_locked(d.go) then return nil end
    end
    local used = false
    pcall(function() used = c:call("hasUsedKeyItem") end)
    if used then return "crystal_turn" end
    return G.has_item(CRYSTAL_MARBLE) and "crystal_have" or "crystal_need"
end

-- The tip for a thing, or nil when it is not an unsolved puzzle.
local function tip_for(t)
    local ok, tip = pcall(function()
        if t.name == "Locker" and dial_unsolved(t.go) then
            return t.go:call("get_Name"):find("リッチクローゼット", 1, true) and "dial_chief" or "dial"
        end
        if t.name == "Puzzle Crystal Ball" then return crystal_state(t) end
        if t.name == "Lever" and t.go:call("get_Name"):find("屋根裏", 1, true) and not RE4Access.ashley_here then return "attic_lever" end
    end)
    return ok and tip or nil
end
U.tip_for = tip_for
U.TIPS = TIPS

local said, scan_at = {}, 0
re.on_frame(function()
    local now = os.clock()
    if now - scan_at < 0.5 then return end
    scan_at = now
    pcall(function()
        local G = RE4Access.game
        if G.state_text ~= "In control" then return end
        local pos = G.player_pos()
        if not pos then return end
        for _, t in ipairs(G.scan_things(pos, 2.6)) do
            if math.abs(t.pos.y - pos.y) < 2.2 then
                local tip = tip_for(t)
                local key = t.key .. ":" .. tostring(tip)
                if tip and not said[key] then
                    said[key] = true
                    say(TIPS[tip], false)
                    return
                end
            end
        end
    end)
end)

-- For N: the next unsolved puzzle within 40 m.
function U.step(pos)
    local G = RE4Access.game
    local best
    for _, t in ipairs(G.scan_things(pos, 40)) do
        local tip = tip_for(t)
        if tip and tip ~= "crystal_need" and tip ~= "attic_lever" and (not best or t.dist < best.dist) then
            best = { name = t.name == "Locker" and "Dial lock on the closet" or "Crystal ball puzzle", pos = t.pos, dist = t.dist, key = t.key, go = t.go, tip = TIPS[tip] }
        end
    end
    return best
end

RE4Access.guide = U
return U
