-- RE4 Access: church stained glass puzzle (chainsaw.GmPuzzleStainedGlass,
-- Chapter 4, in front of the altar). Three coloured glasses each turn around
-- one axis with their own handle; the Blue Dial is the missing blue handle.
-- Live-read 10/22: start angles red 270, green 90, blue 180 (InitParam.Degree);
-- checkCorrect(rotation) is true only near no rotation, so every glass has to
-- go back to 0 degrees (CorrectRate 0.99 = within about 16 degrees).
-- _SelectGlass is the GlassType enum: Red 1, Green 2, Blue 3 (v1 read it as
-- 0-2 and named the wrong glass). IsHandleFitComp(type) = handle in place.
--
-- Manual: the mod names the picked glass, counts the degrees while it turns,
-- learns which key turns it closer, says "lined up".
-- Automatic (user asked 10/22 after W/A/S/D did not turn anything): Backslash
-- while in the puzzle turns all three glasses back to straight.

local S = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end

local NAMES = { "Red", "Green", "Blue" }
local FIELDS = { "_RedRotCur", "_GreenRotCur", "_BlueRotCur" }
local LINED = 6        -- degrees; the game accepts about 16
local AUTO_SPEED = 90  -- degrees per second while solving automatically

local st = { comp = nil, find_at = 0, angles = {}, sel = nil, fit = {}, active = false,
    key_sign = {}, said_at = 0, last_off = nil, lined = {}, solved = false, auto = false, keys_down = {} }

local function angle_of(q)
    -- rotation about the glass's own axis; the axis part sits in z (Axis 3)
    local a = math.deg(2 * math.atan(q.z, q.w))
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

local function find_comp()
    local best
    pcall(function()
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            pcall(function()
                local go = core:call("get_GameObject")
                if go:call("get_Name"):find("すてんどぐらすぱずる", 1, true) then
                    local q = go:call("get_Transform"):call("get_Position")
                    best = { c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPuzzleStainedGlass")),
                        pos = { x = q.x, y = q.y, z = q.z } }
                end
            end)
        end
    end)
    return best
end

local function fitted(i)
    local ok, v = pcall(function() return st.comp.c:call("IsHandleFitComp", i) end)
    return ok and v == true
end

local function key_for(i, off)
    -- off > 0: the angle must go down; a key whose turn made it go down helps
    local want = off > 0 and -1 or 1
    for name, s in pairs(st.key_sign[i] or {}) do
        if s == want then return name end
    end
end

local function glass_text(i)
    if not fitted(i) then return NAMES[i] .. " has no handle yet" end
    local a = st.angles[i]
    if not a then return NAMES[i] .. " unknown" end
    if math.abs(a) <= LINED then return NAMES[i] .. " lined up" end
    return string.format("%s %d degrees off", NAMES[i], math.floor(math.abs(a) + 0.5))
end

function S.status()
    if not st.comp then say("Not at the stained glass stand", true) return end
    local parts = {}
    for i = 1, 3 do parts[#parts + 1] = glass_text(i) end
    local need = ""
    if not fitted(3) then
        need = " Press F at the stand, pick the Blue Dial and choose Use."
    elseif not st.active then
        need = " Press F at the stand to start. Then Backslash solves it for you."
    end
    say("Stained glass: " .. table.concat(parts, ", ") .. "." .. need, true)
end

local function guide_line(i)
    if not fitted(i) then return NAMES[i] .. " has no handle yet. The Blue Dial goes there." end
    local a = st.angles[i]
    if not a then return NAMES[i] end
    if math.abs(a) <= LINED then return NAMES[i] .. " glass, lined up already." end
    local k = key_for(i, a)
    local n = math.floor(math.abs(a) + 0.5)
    if k then return string.format("%s glass, %d degrees off. Hold %s.", NAMES[i], n, k) end
    return string.format("%s glass, %d degrees off.", NAMES[i], n)
end

-- Backslash in the puzzle: turn every glass back to straight, a bit per frame
function S.start_auto()
    if not st.comp then say("Not at the stained glass stand", true) return end
    if not fitted(3) then say("The Blue Dial is not in yet. Press F at the stand and use it first.", true) return end
    st.auto = { at = os.clock() }
    say("Solving the stained glass for you.", true)
    log.info("[RE4Access] stained glass: auto solve start")
end

local function step_auto(c, dt)
    local all = true
    for i = 1, 3 do
        local a = st.angles[i] or 0
        local stepd = AUTO_SPEED * dt
        local na = math.abs(a) <= stepd and 0 or (a - stepd * (a > 0 and 1 or -1))
        if na ~= 0 then all = false end
        local h = math.rad(na) / 2
        c:set_field(FIELDS[i], Quaternion.new(math.cos(h), 0, 0, math.sin(h)))
    end
    return all
end

local keys_log_at = 0
local function log_keys(now)
    -- manual mode: which keys the user tries (10/22: W/A/S/D did not turn)
    if now - keys_log_at < 0.3 then return end
    keys_log_at = now
    local down = {}
    for vk = 0x08, 0xDE do
        if reframework:is_key_down(vk) then down[#down + 1] = string.format("%02X", vk) end
    end
    local s = table.concat(down, " ")
    if s ~= st.keys_down_s and s ~= "" then
        local c = st.comp.c
        local inp = c:get_field("_Input")
        log.info(string.format("[RE4Access] stained glass: keys %s sel %s input (%.2f,%.2f,%.2f)", s,
            tostring(c:get_field("_SelectGlass")), inp.x, inp.y, inp.z))
    end
    st.keys_down_s = s
end

local last_t = os.clock()
local function update()
    local G = RE4Access.game
    local pos = G and G.player_pos()
    local now = os.clock()
    local dt = math.min(now - last_t, 0.1)
    last_t = now
    if not pos then return end
    if now >= st.find_at then
        st.find_at = now + 2
        local f = find_comp()
        if f and math.sqrt((f.pos.x - pos.x) ^ 2 + (f.pos.z - pos.z) ^ 2) < 8 then
            st.comp = f
        else
            if st.comp and st.active then RE4Access.in_puzzle = nil end
            st.comp, st.active = nil, false
            return
        end
    end
    if not st.comp then return end
    local c = st.comp.c
    local ok, err = pcall(function()
        -- the handle (the Blue Dial) placed
        for i = 1, 3 do
            local fit = fitted(i)
            if st.fit[i] == false and fit then say(NAMES[i] .. " handle is in place.", true) end
            st.fit[i] = fit
        end
        -- in the puzzle view (the walking camera is not the busy one)
        local active = st.comp ~= nil and G.cam_busy ~= nil and G.cam_busy ~= "chainsaw.PlayerCameraController"
            and math.sqrt((st.comp.pos.x - pos.x) ^ 2 + (st.comp.pos.z - pos.z) ^ 2) < 3
        if active ~= st.active then
            st.active = active
            log.info("[RE4Access] stained glass: active " .. tostring(active) .. " cam " .. tostring(G.cam_busy))
            if active then
                RE4Access.in_puzzle = true
                local parts = {}
                for i = 1, 3 do parts[#parts + 1] = glass_text(i) end
                say("Stained glass puzzle. " .. table.concat(parts, ", ")
                    .. ". Press Backslash and I solve it for you. Or turn the glasses yourself: I count the degrees.", true)
            else
                RE4Access.in_puzzle = nil
                st.auto = false
            end
        end
        if c:get_field("_ClearFlag") and not st.solved then
            st.solved = true
            say("Solved! The bars are opening.", true)
            log.info("[RE4Access] stained glass: solved")
        end
        for i = 1, 3 do st.angles[i] = angle_of(c:get_field(FIELDS[i])) end
        if not st.active then return end
        if reframework:is_key_down(0xDC) then
            if not st.bs_held and not st.auto and not st.solved then S.start_auto() end
            st.bs_held = true
        else
            st.bs_held = false
        end
        if st.auto then
            if step_auto(c, dt) and not st.auto.done then
                st.auto.done = now
                say("All three glasses are straight.", true)
                log.info("[RE4Access] stained glass: auto solve set all to 0, clear " .. tostring(c:get_field("_ClearFlag")))
            end
            if st.auto.done and now - st.auto.done > 4 and not st.solved and not st.auto.warned then
                st.auto.warned = true
                log.info("[RE4Access] stained glass: auto solve - no clear after 4 s")
                say("The glasses are straight but the game has not opened yet. Try turning any glass a tiny bit.", true)
            end
            return
        end
        log_keys(now)
        local sel = c:get_field("_SelectGlass")
        if sel ~= st.sel then
            if st.sel ~= nil and NAMES[sel] then say(guide_line(sel), true) end
            st.sel = sel
            st.last_off = nil
        end
        local a = NAMES[sel] and st.angles[sel]
        if not a then return end
        local old = st.prev and st.prev[sel]
        st.prev = st.prev or {}
        st.prev[sel] = a
        if not old or math.abs(a - old) < 0.5 or math.abs(a - old) > 90 then return end
        -- learn: which held key turned this glass which way
        for name, vk in pairs({ D = 0x44, A = 0x41, W = 0x57, S = 0x53, Q = 0x51, E = 0x45,
                Left = 0x25, Right = 0x27, Up = 0x26, Down = 0x28 }) do
            if reframework:is_key_down(vk) then
                st.key_sign[sel] = st.key_sign[sel] or {}
                local s = (a - old) > 0 and 1 or -1
                if st.key_sign[sel][name] ~= s then
                    st.key_sign[sel][name] = s
                    log.info(string.format("[RE4Access] stained glass: %s key %s sign %d", NAMES[sel], name, s))
                end
            end
        end
        local lined = math.abs(a) <= LINED
        if lined and not st.lined[sel] then
            st.lined[sel] = true
            local all = true
            for i = 1, 3 do if math.abs(st.angles[i] or 99) > LINED then all = false end end
            say(all and (NAMES[sel] .. " lined up. All three are lined up.") or (NAMES[sel] .. " lined up. Let go. Pick the next glass."), true)
            st.said_at = now
        elseif not lined then
            st.lined[sel] = nil
            if now - st.said_at > 0.7 then
                local n = math.floor(math.abs(a) + 0.5)
                local worse = st.last_off and math.abs(a) > st.last_off + 1
                local k = key_for(sel, a)
                say(worse and (n .. ", wrong way" .. (k and (", hold " .. k) or "")) or tostring(n), true)
                st.said_at = now
                st.last_off = math.abs(a)
            end
        end
    end)
    if not ok then log.info("[RE4Access] stained glass error: " .. tostring(err)) st.comp = nil end
end

if not RE4Access.stained_hooked then
    RE4Access.stained_hooked = true
    re.on_frame(function()
        local ok, e = pcall(function() RE4Access.stained.update() end)
        if not ok then log.info("[RE4Access] stained glass error: " .. tostring(e)) end
    end)
end

S.update = update
S.state = st
RE4Access.stained = S
return S
