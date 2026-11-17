-- RE4 Access: crystal ball puzzle (chainsaw.GmPuzzleCrystalBall, Chief's house
-- bedroom door). After the Crystal Marble goes in, the ball is turned until its
-- white dots line up with the figure behind it. The ball starts turned away
-- (InitRot: 120, 80, -60 degrees, live-read 10/17); solved = rotation back near
-- none (_RotCur near identity).
--
-- 10/17 v1 only said a percent: the user turned for minutes around 50% - one
-- number can't tell which key to press. v2 says WHICH KEY to hold:
--  * it learns what A/D and W/S do from the user's own first taps (the axis each
--    key turns the ball around, measured from _RotCur before/after);
--  * the turn still needed is split into three simple turns: A/D, then W/S,
--    then A/D again (Euler angles about the two learned axes), and the mod says
--    "Hold D", "Stop. Now hold W", ... recomputed all the time, so overshooting
--    just changes the next instruction.

local C = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end

local KEYS = { D = 0x44, A = 0x41, W = 0x57, S = 0x53 }

-- quaternions as {x,y,z,w}
local function qmul(a, b)
    return { x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
             w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z }
end
local function qconj(a) return { x = -a.x, y = -a.y, z = -a.z, w = a.w } end
local function rot(q, v)   -- rotate vector v by q
    local r = qmul(qmul(q, { x = v.x, y = v.y, z = v.z, w = 0 }), qconj(q))
    return { x = r.x, y = r.y, z = r.z }
end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x } end
local function norm(a)
    local l = math.sqrt(dot(a, a))
    if l < 1e-6 then return nil end
    return { x = a.x / l, y = a.y / l, z = a.z / l }
end
local function axis_angle(q)
    if q.w < 0 then q = { x = -q.x, y = -q.y, z = -q.z, w = -q.w } end
    local s = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
    if s < 1e-6 then return nil, 0 end
    return { x = q.x / s, y = q.y / s, z = q.z / s }, 2 * math.atan(s, q.w)
end

local balls, scan_at = {}, -10
local prev_q
-- learned turning axes per key, pre (view) and post (ball's own) frames
local learn = { pre = {}, post = {} }
local guide = { said = nil, said_at = 0, lined = false, intro = false, learn_said_at = 0 }

local function add(frame, k, ax)
    local L = learn[frame][k] or { x = 0, y = 0, z = 0, n = 0, cons = 0 }
    if L.n > 0 then
        local m = norm(L)
        if m then L.cons = L.cons + dot(m, ax) end
    end
    L.x, L.y, L.z, L.n = L.x + ax.x, L.y + ax.y, L.z + ax.z, L.n + 1
    learn[frame][k] = L
end

-- axis for "positive" key of a pair (D for A/D, W for W/S), in a frame
local function pair_axis(frame, pos_k, neg_k)
    local P, N = learn[frame][pos_k], learn[frame][neg_k]
    local v = { x = 0, y = 0, z = 0 }
    if P then local m = norm(P) if m then v = { x = v.x + m.x, y = v.y + m.y, z = v.z + m.z } end end
    if N then local m = norm(N) if m then v = { x = v.x - m.x, y = v.y - m.y, z = v.z - m.z } end end
    return norm(v)
end

local function frame_score(frame)
    local s, n = 0, 0
    for _, L in pairs(learn[frame]) do if L.n > 1 then s, n = s + L.cons / (L.n - 1), n + 1 end end
    return n > 0 and s / n or 0
end

-- The whole turn still needed as three simple turns (Euler angles about the two
-- learned axes): A/D, then W/S, then A/D. Planned once, then followed with
-- progress measured from the ball itself; replanned after the three turns.
-- (Simulated 10/17: re-deciding every frame oscillated; plan-then-follow solved
-- 40 of 40 random starts even with axis errors and 5-degree over/undershoots.)
local function make_plan(q)
    local frame = frame_score("post") > frame_score("pre") + 0.05 and "post" or "pre"
    local a = pair_axis(frame, "D", "A")
    local bw = pair_axis(frame, "W", "S")
    if not a or not bw then return nil end
    local b = norm({ x = bw.x - dot(bw, a) * a.x, y = bw.y - dot(bw, a) * a.y, z = bw.z - dot(bw, a) * a.z })
    if not b then return nil end
    local x = cross(b, a)
    local g = qconj(q)
    local E = { x, b, a }
    local M = {}
    for i = 1, 3 do
        M[i] = {}
        for j = 1, 3 do M[i][j] = dot(E[i], rot(g, E[j])) end
    end
    local function deg(r) local d = math.deg(r) % 360 if d > 180 then d = d - 360 end return d end
    local be = math.acos(math.max(-1, math.min(1, M[3][3])))
    local steps
    if math.abs(math.sin(be)) < 0.01 then
        steps = { { axis = a, pos = "D", neg = "A", amount = deg(math.atan(M[2][1], M[1][1])) } }
    else
        local al, ga = math.atan(M[2][3], M[1][3]), math.atan(M[3][2], -M[3][1])
        local first, last = ga, al
        if frame == "post" then first, last = al, ga end
        steps = { { axis = a, pos = "D", neg = "A", amount = deg(first) },
                  { axis = b, pos = "W", neg = "S", amount = deg(be) },
                  { axis = a, pos = "D", neg = "A", amount = deg(last) } }
    end
    local out = {}
    for _, st in ipairs(steps) do if math.abs(st.amount) > 3 then st.done = 0 out[#out + 1] = st end end
    log.info(string.format("[RE4Access] crystal plan (%s): %s", frame, (function()
        local t = {} for _, st in ipairs(out) do t[#t + 1] = st.pos .. string.format("%.0f", st.amount) end return table.concat(t, " ") end)()))
    return { steps = out, i = 1, frame = frame }
end

local function scan(now)
    if now - scan_at < 2 then return end
    scan_at = now
    balls = {}
    pcall(function()
        local pos = RE4Access.game.player_pos()
        if not pos then return end
        for _, t in ipairs(RE4Access.game.scan_things(pos, 4.5)) do
            local c = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPuzzleCrystalBall"))
            if c then balls[#balls + 1] = c end
        end
    end)
end

re.on_frame(function()
    local now = os.clock()
    scan(now)
    local c = balls[1]
    if not c then prev_q = nil return end
    pcall(function()
        if not c:call("hasUsedKeyItem") then return end
        -- solved = its door is unlocked: stay quiet for good
        if not guide.solved_check_at or now > guide.solved_check_at then
            guide.solved_check_at = now + 2
            pcall(function()
                local G = RE4Access.game
                local bp = c:call("get_GameObject"):call("get_Transform"):call("get_Position")
                for _, d in ipairs(G.scan_things({ x = bp.x, y = bp.y, z = bp.z }, 3)) do
                    if d.name == "Door" and d.go:call("get_Name"):find("水晶パズル", 1, true) and not G.door_locked(d.go) then guide.solved = true end
                end
            end)
        end
        if guide.solved then RE4Access.in_puzzle = nil return end
        -- only while turning the ball (10/17: walking with W near it counted
        -- down "167, 167" and learned walking as turns)
        -- Turning the ball = the puzzle camera is on, not Leon's camera. (The
        -- mod's state_text stays "In control" here: the puzzle camera has no
        -- name in its list - 10/17 Backslash did nothing because of that.)
        local cam = ""
        pcall(function()
            local mc = sdk.get_managed_singleton("chainsaw.CameraSystem"):call("get_MainCameraController")
            cam = mc:get_field("_BusyCameraController"):get_type_definition():get_full_name()
        end)
        -- Only the puzzle's own camera (10/17: photo mode's camera counted, and
        -- Backslash/Shift+Backslash said "turning the ball" after it was solved).
        local turning_ball = cam == "chainsaw.GimmickFixCameraController" and not guide.solved
        RE4Access.in_puzzle = turning_ball or nil
        if not turning_ball then
            if guide.active then guide.active = false pcall(function() c:set_field("SpeedMax", guide.speed0 or 70.0) end) end
            prev_q, guide.last_q = nil, nil
            return
        end
        if not guide.active then
            guide.active = true
            log.info("[RE4Access] crystal ball in use, camera " .. cam)
            say("Turning the crystal ball. Press Backslash now, and I turn it to the right spot for you.", true)
            guide.learn_said_at = now
            -- Slow ball: at full speed (70 degrees a second) the ball was past the
            -- spot before "Stop" was spoken (10/17). 12 a second is easy to stop.
            pcall(function()
                guide.speed0 = guide.speed0 or c:get_field("SpeedMax")
                c:set_field("SpeedMax", 12.0)
            end)
            guide.plan, guide.said = nil, nil
        end
        local r = c:get_field("_RotCur")
        local q = { x = r.x, y = r.y, z = r.z, w = r.w }
        -- One-key solution (10/17, user asked): Backslash while turning the ball
        -- turns it to the right spot by itself over 2 seconds (slerp to none);
        -- the game's own check (checkCorrect, live-verified: no rotation = right)
        -- then solves it.
        local bs = reframework:is_key_down(0xDC)
        if bs and not guide.bs_was and not guide.auto then
            guide.auto = { from = q, t0 = now }
            say("Turning the ball for you.", true)
        end
        guide.bs_was = bs
        if guide.auto then
            local A = guide.auto
            local t = math.min(1, (now - A.t0) / 2)
            local f = A.from
            if f.w < 0 then f = { x = -f.x, y = -f.y, z = -f.z, w = -f.w } end
            local th = math.acos(math.min(1, f.w))
            local k0 = th > 1e-4 and math.sin((1 - t) * th) / math.sin(th) or (1 - t)
            local k1 = th > 1e-4 and math.sin(t * th) / math.sin(th) or t
            local n = { x = f.x * k0, y = f.y * k0, z = f.z * k0, w = f.w * k0 + k1 }
            c:set_field("_RotCur", Quaternion.new(n.w, n.x, n.y, n.z))
            pcall(function() c:set_field("_Speed", Vector3f.new(0, 0, 0)) end)
            if t >= 1 then
                guide.auto = nil
                log.info("[RE4Access] crystal auto-turn done")
                say("Done. Lined up.", true)
                guide.lined = true
            end
            prev_q, guide.last_q = nil, nil
            return
        end
        local w = math.min(1, math.abs(q.w))
        local angle = 2 * math.deg(math.acos(w))
        -- learning: one key down and the ball turned
        if prev_q then
            local down
            for k, vk in pairs(KEYS) do
                if reframework:is_key_down(vk) then down = down and "many" or k end
            end
            local dq = qmul(q, qconj(prev_q))
            local ax, an = axis_angle(dq)
            if down and down ~= "many" and ax and an > 0.002 then
                add("pre", down, ax)
                local ax2 = axis_angle(qmul(qconj(prev_q), q))
                if ax2 then add("post", down, ax2) end
            end
        end
        prev_q = q
        local turning = false
        for _, vk in pairs(KEYS) do if reframework:is_key_down(vk) then turning = true end end
        if angle < 6 then
            if not guide.lined then guide.lined = true say("Lined up! Let go of the keys.", true) end
            return
        end
        guide.lined = false
        local plan = guide.plan
        if not plan then
            plan = make_plan(q)
            if not plan then
                if now - guide.learn_said_at > 20 and not turning then
                    guide.learn_said_at = now
                    say("Press Backslash and I turn the ball for you. Or turn it yourself: tap D once and W once, then I say which key to hold.", true)
                end
                return
            end
            guide.plan, guide.said, guide.last_q, guide.rate = plan, nil, q, 0
            if #plan.steps == 0 then guide.plan = nil return end
            say("Ball learned. " .. math.floor(angle + 0.5) .. " degrees off. " .. #plan.steps .. (#plan.steps == 1 and " turn" or " turns") .. " to do.", true)
        end
        local st = plan.steps[plan.i]
        if not st then guide.plan = nil return end   -- all done: plan again from here
        -- progress about this step's axis
        local step_d = 0
        if guide.last_q then
            local dq = plan.frame == "post" and qmul(qconj(guide.last_q), q) or qmul(q, qconj(guide.last_q))
            local ax, an = axis_angle(dq)
            if ax then step_d = math.deg(an) * dot(ax, st.axis) st.done = st.done + step_d end
        end
        local dt = now - (guide.last_t or now)
        if dt > 0 then guide.rate = 0.7 * (guide.rate or 0) + 0.3 * math.abs(step_d) / dt end
        guide.last_q, guide.last_t = q, now
        local left = st.amount - st.done
        -- "Stop" early by what the ball turns while the words are spoken (0.3 s)
        local lead = 3 + math.min(25, (guide.rate or 0) * 0.3)
        if math.abs(left) <= lead and (left * st.amount > 0 or math.abs(left) <= 3) then
            plan.i = plan.i + 1
            local nx = plan.steps[plan.i]
            if nx then
                local k = nx.amount > 0 and nx.pos or nx.neg
                guide.said, guide.said_at = k, now
                say("Stop. Now " .. (math.abs(nx.amount) > 25 and "hold " or "tap ") .. k .. ", " .. math.floor(math.abs(nx.amount) + 0.5) .. " degrees.", true)
            else
                guide.plan, guide.said = nil, nil
                say("Stop.", true)
            end
            return
        end
        local key = left > 0 and st.pos or st.neg
        if key ~= guide.said then
            local over = guide.said ~= nil
            guide.said, guide.said_at = key, now
            local verb = math.abs(left) > 25 and "hold " or "tap "
            say((over and "Too far. Now " or "") .. verb .. key .. ", " .. math.floor(math.abs(left) + 0.5) .. " degrees.", true)
        elseif turning and now - guide.said_at > 1.5 then
            guide.said_at = now
            say(tostring(math.floor(math.abs(left) + 0.5)), true)
        end
    end)
end)

C.learn = learn
C.make_plan = make_plan
C.guide = guide
RE4Access.crystal = C
return C
