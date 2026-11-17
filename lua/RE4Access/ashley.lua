-- RE4 Access: Ashley's formation, Tight or Loose (10/22, user asked).
-- The game's own key is Ctrl; it works with JAWS (user 10/22), so the mod only
-- speaks every change. (A Minus-key toggle via IsRequestClosedPosition was
-- ignored by the game: Ctrl changes IsPlayerPossibleClosedPosition. Removed.)
-- Live-read 10/22: chainsaw.PartnerBaseContext (CharacterManager
-- getPartnerContextRef) _CurrentPositioningType (Npc.PositioningType: Open 0
-- = Loose, Close 1 = Tight); IsRequestClosedPosition is the request.

local A = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end

local KEY_MINUS, KEY_SHIFT = 0xBD, 0x10
local st = { last = nil, held = false }

local function partner()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    return cm and cm:call("getPartnerContextRef")
end

local function name_of(t) return t == 1 and "Tight" or "Loose" end

function A.toggle()
    local ok, err = pcall(function()
        local c = partner()
        if not c then say("Ashley is not with you.", true) return end
        local want = not c:call("get_IsRequestClosedPosition")
        c:call("set_IsRequestClosedPosition", want)
        log.info("[RE4Access] ashley: request tight = " .. tostring(want))
    end)
    if not ok then log.info("[RE4Access] ashley toggle error: " .. tostring(err)) end
end

function A.status()
    local ok, t = pcall(function() return partner():get_field("_CurrentPositioningType") end)
    if ok and t then
        say("Ashley: " .. name_of(t) .. (t == 1 and ", she stays close behind you." or ", she keeps her distance."), true)
    else
        say("Ashley is not with you.", true)
    end
end

-- Ashley grabbed (10/22: a villager carried her off in the graveyard, game
-- over, the user never knew). <IsKidnapped> on the partner context; while it
-- is true, say where she is every 2 s: shoot the one carrying her.
local function update_kidnap()
    local G = RE4Access.game
    local c = partner()
    if not c or not G then return end
    local k = c:get_field("<IsKidnapped>k__BackingField")
    local now = os.clock()
    -- paused or alt-tabbed: silent (10/22 user: "hearing Ashley over and over, especially when paused")
    local focus = true
    pcall(function() focus = sdk.call_native_func(sdk.get_native_singleton("via.Application"), sdk.find_type_definition("via.Application"), "get_HasFocus") end)
    local paused = (G.is_paused and G.is_paused()) or not focus
    if k and paused then return end
    if k and G.cam_busy == "chainsaw.PlayerCameraController" then
        local pos = G.player_pos()
        local q = c:call("get_Position")
        if pos and q and (not st.kid_at or now - st.kid_at > 2) then
            local a = { x = q.x, y = q.y, z = q.z }
            local d = math.sqrt((a.x - pos.x) ^ 2 + (a.z - pos.z) ^ 2)
            local route_on = RE4Access.route and RE4Access.route.active()
            -- 10/22: "Ashley, 15 meters, right" every 2 s was the straight line while
            -- the route went left round a house: the user could not follow either.
            -- Far away with a route: the route turns Leon, so only distance + hold W,
            -- every 5 s. Close (6 m): her direction, to aim at the carrier.
            -- carrier in range, same level, nothing in the way
            local in_sight = d <= 6
            pcall(function()
                local cr = G.ashley_carrier(pos)
                if cr and cr.dist <= 25 and math.abs(cr.pos.y - pos.y) < 4
                    and G.clear_shot({ x = pos.x, y = pos.y + 1.4, z = pos.z }, { x = cr.pos.x, y = cr.pos.y + 1.2, z = cr.pos.z }) then
                    in_sight = true
                end
            end)
            local level = (a.y - pos.y > 2.5) and ", above you" or (pos.y - a.y > 2.5) and ", below you" or ""
            local moved = st.kid_pos and math.sqrt((pos.x - st.kid_pos.x) ^ 2 + (pos.z - st.kid_pos.z) ^ 2) or 99
            -- 11/8 Water Hall: Ashley grabbed up on the crank ledge, 3 m above Leon, no way up:
            -- 'Hold W, I walk you to her' + 'No walking route' every time. Shoot from below.
            local up_high = a.y - pos.y > 2.0 and d < 25
            if up_high then
                if not st.kid_at or (not in_sight and now - (st.kid_said or 0) > 6) then
                    say("Ashley is grabbed, up on the ledge above you. You cannot get up there. Stay below, hold L: I aim at the villager carrying her, press K.", true)
                    st.kid_said = now
                elseif in_sight and now - (st.kid_said or 0) > 2 then
                    say("Her carrier, " .. G.describe_position(a, pos, G.facing()) .. ". Hold L, press K.", true)
                    st.kid_said = now
                end
            elseif not st.kid_at then
                say("Ashley is grabbed! Hold W, I walk you to her. Close up, hold L: I aim at the villager carrying her, press K. She is "
                    .. math.floor(d + 0.5) .. " meters away.", true)
                st.kid_said = now
            elseif in_sight then
                -- 11/2: shoot from wherever there is a clear line, not only within 6 m: he runs.
                say("Her carrier, " .. G.describe_position(a, pos, G.facing()) .. ". Hold L, press K.", true)
                st.kid_said = now
            elseif now - (st.kid_said or 0) > 10 and (moved < 0.5 or math.abs(d - (st.kid_d or 0)) >= 3) then
                local hint = (route_on and moved < 0.5) and ". Hold W, I steer you." or ""
                say("Ashley, " .. math.floor(d + 0.5) .. " meters" .. level .. hint, false)
                st.kid_said, st.kid_d = now, d
            end
            st.kid_at, st.kid_pos = now, { x = pos.x, z = pos.z }
            -- walk after her; new route when she moved 3 m or the route ended (10/22)
            -- not while aiming: a new route turned Leon away in the middle of the shot
            if not up_high and not in_sight and not reframework:is_key_down(0x4C) and RE4Access.route and (not route_on or not st.kid_goal or math.sqrt((a.x - st.kid_goal.x) ^ 2 + (a.z - st.kid_goal.z) ^ 2) > 3) then
                st.kid_goal = a
                G.select({ name = "Ashley", pos = a, dist = d, key = "ashley_kidnap", walk_point = true })
                RE4Access.speak_hold = true
                RE4Access.route_quiet = st.kid_routed   -- only the first route is spoken (10/27)
                pcall(RE4Access.route.go, { name = "Ashley", pos = a, dist = d, key = "ashley_kidnap", walk_point = true })
                RE4Access.route_quiet, RE4Access.speak_hold = nil, nil
                st.kid_routed = true
            end
        end
    elseif st.kid_at and not k then
        st.kid_at, st.kid_goal, st.kid_pos, st.kid_said, st.kid_routed = nil, nil, nil, nil, nil
        pcall(RE4Access.route.stop, true)
        say("Ashley is free.", true)
    end
end

local function update()
    pcall(update_kidnap)
    local ok, t = pcall(function()
        local c = partner()
        return c and c:get_field("_CurrentPositioningType")
    end)
    if not ok or t == nil then st.last = nil return end
    if st.last ~= nil and t ~= st.last then
        say("Ashley: " .. name_of(t) .. (t == 1 and ", close behind you." or ", keeping her distance."), true)
    end
    st.last = t
end

if not RE4Access.ashley_hooked then
    RE4Access.ashley_hooked = true
    re.on_frame(function()
        local ok, e = pcall(function() RE4Access.ashley.update() end)
        if not ok then log.info("[RE4Access] ashley error: " .. tostring(e)) end
    end)
end

A.update = update
A.state = st
A.partner = partner   -- game.lua: no trap aiming while she is carried off (10/27)
RE4Access.ashley = A
return A
