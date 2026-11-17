-- RE4 Access: emblem crank stand puzzle (CustomGmCrankHexCrest2).
-- After "Use" on the Hexagonal Emblem the emblem sits in the stand and must be
-- turned (Q / E, 6 positions) and flipped (A / D) until it fits; F pushes it
-- in. Live-checked 10/14: _ManiRno 10 -> 11 -> 0 = does not fit, 21 -> 22 =
-- fits. The factory stand fits flipped and turned once with Q (roll 5).

local H = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end

-- Known solutions by stand object name (found while playing).
local KNOWN = {
    ["六角クランクの台座Ver2"] = { flip = true, roll = 5, steps = "Press A to flip it, then Q once, then F." },
}

local crests, scan_at, tick_at = {}, -10, 0
local active, prev, said_fit

local function scan(now)
    if now - scan_at < 2 then return end
    scan_at = now
    crests = {}
    pcall(function()
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject")
                local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.CustomGmCrankHexCrest2"))
                if c then crests[#crests + 1] = { c = c, name = go:call("get_Name") } end
            end) end
        end
    end)
end

local function known_for(name)
    for k, v in pairs(KNOWN) do if name:find(k, 1, true) then return v end end
end

re.on_frame(function()
    local now = os.clock()
    if now - tick_at < 0.15 then return end
    tick_at = now
    scan(now)
    local cur
    for _, t in ipairs(crests) do
        local ok, u = pcall(function() return t.c:get_field("_User") end)
        if ok and u then cur = t break end
    end
    if not cur then active, prev = nil, nil return end
    local ok, roll, flip, mani = pcall(function()
        return cur.c:get_field("_CrestRoll"), cur.c:get_field("_CrestFlip"), cur.c:get_field("_ManiRno")
    end)
    if not ok then return end
    if active ~= cur then
        active, said_fit = cur, false
        prev = { roll = roll, flip = flip, mani = mani }
        local k = known_for(cur.name)
        local hint = k and (" " .. k.steps) or " Try F; if it does not fit, press E and F again, all 6 turns, then A to flip and try the 6 turns again."
        say("Emblem puzzle. Q and E turn it, A flips it, F pushes it in." .. hint, true)
        log.info("[RE4Access] hex puzzle open: " .. cur.name)
        return
    end
    if roll ~= prev.roll then say("Turn " .. (roll + 1) .. " of 6", true) end
    if flip ~= prev.flip then say(flip and "Flipped" or "Flipped back", true) end
    if mani ~= prev.mani then
        log.info(string.format("[RE4Access] hex mani %s -> %s roll %s flip %s", tostring(prev.mani), tostring(mani), tostring(roll), tostring(flip)))
        if prev.mani == 11 and mani == 0 then say("Does not fit.", true) end
        if (mani == 21 or mani == 22) and not said_fit then said_fit = true say("It fits!", true) end
    end
    prev = { roll = roll, flip = flip, mani = mani }
end)

RE4Access.hex = H
return H
