-- RE4 Access: Audio description for cutscenes (11/13/2026, user asked for it).
--
-- PLAYER: reframework\data\REAccess_audio_description.txt holds the descriptions:
--   [8_123] Optional title           <- scene key = Kind_ID of the playing timeline event
--   0    | Text spoken as the scene starts.
--   450  | Text for frame 450.        <- spoken at the first moment at or after frame 450
--                                        when no subtitle is on screen (waits up to 4 s,
--                                        then speaks anyway, without cutting anything off).
--   Lines starting with # are notes.
-- RECORDER: every cutscene writes reframework\data\REAccess_ad_record.txt: scene key,
--   length, each subtitle with its frame and time, and when subtitles go away. Claude
--   reads it to identify scenes and to place descriptions in the quiet gaps.
--
-- Proven 11/13 at the title screen (Claude, dev channel): chainsaw.TimelineEventManager is a
-- managed singleton; _PlayerInfoList holds chainsaw.TimelineEventPlayerInfo with
-- _Identifier (chainsaw.AppEventDefine.Identifier: _Kind enum 0-7, _ID UInt16),
-- _CurrentFrame, _MaxFrame, _CurrentStatus. Subtitles: chainsaw.SubTitleGuiBehavior with
-- _PlayingRequestList and setMessage(2 params). Not yet seen DURING a cutscene: the
-- first in-game run proves it (log lines "[RE4Access] AD").

local A = {}
local function log_ad(s) log.info("[RE4Access] AD " .. s) end

A.data = {}
function A.load()
    A.data = {}
    local src = fs.read("REAccess_audio_description.txt") or ""
    local cur, n = nil, 0
    A.src = src
    for raw in src:gmatch("[^\r\n]+") do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, title = line:match("^%[(%d+_%d+)%]%s*(.*)$")
            if key then
                cur = { title = title, lines = {} }
                A.data[key] = cur
                n = n + 1
            elseif cur then
                local f, t = line:match("^(%d+%.?%d*)%s*|%s*(.+)$")
                if f then cur.lines[#cur.lines + 1] = { frame = tonumber(f), text = t } end
            end
        end
    end
    for _, sc in pairs(A.data) do table.sort(sc.lines, function(a, b) return a.frame < b.frame end) end
    log_ad("loaded descriptions for " .. n .. " scenes")
end
pcall(A.load)

-- ---------------- recorder file ----------------
local rec = fs.read("REAccess_ad_record.txt") or ""
local rec_dirty = false
local function rec_line(s)
    rec = rec .. os.date("%m-%d %H:%M:%S") .. string.format(" %.2f ", os.clock()) .. s .. "\n"
    rec_dirty = true
    log_ad(s)
end
local function rec_flush()
    if rec_dirty then pcall(fs.write, "REAccess_ad_record.txt", rec) rec_dirty = false end
end

-- ---------------- subtitles ----------------
A.sub_inst = nil
A.last_sub = nil
local function arg_text(a)
    local ok, r = pcall(function()
        local o = sdk.to_managed_object(a)
        if o then
            local tn = o:get_type_definition():get_full_name()
            if tn == "System.String" then return "str:" .. o:call("ToString") end
            return "obj:" .. tn
        end
        return "num:" .. tostring(sdk.to_int64(a))
    end)
    return ok and r or "?"
end
local hooked = false
local function install_hooks()
    if hooked then return end
    local td = sdk.find_type_definition("chainsaw.SubTitleGuiBehavior")
    if not td then return end
    hooked = true
    local m = td:get_method("lateUpdate")
    if m then
        sdk.hook(m, function(args)
            if not A.sub_inst then A.sub_inst = sdk.to_managed_object(args[2]) end
        end, nil)
    end
    local sm = td:get_method("setMessage")
    if sm then
        sdk.hook(sm, function(args)
            if not A.sub_inst then A.sub_inst = sdk.to_managed_object(args[2]) end
            local t3, t4 = arg_text(args[3]), arg_text(args[4])
            A.last_sub = t3 .. " | " .. t4
            A.sub_set_at = os.clock()
        end, nil)
    end
    log_ad("subtitle hooks installed")
end
pcall(install_hooks)

-- Message text of the subtitle rows on screen (best effort, for the recording).
local function sub_count()
    local inst = A.sub_inst
    if not inst then return nil end
    local ok, n = pcall(function() return inst:get_field("_PlayingRequestList"):call("get_Count") end)
    return ok and n or nil
end

-- ---------------- playing scene ----------------
local function current_scene()
    local m = sdk.get_managed_singleton("chainsaw.TimelineEventManager")
    if not m then return nil end
    local l = m:get_field("_PlayerInfoList")
    if not l then return nil end
    local n = l:call("get_Count") or 0
    local best
    for i = 0, n - 1 do
        local pi = l:call("get_Item", i)
        if pi then
            local id = pi:get_field("_Identifier")
            local key = id and string.format("%d_%d", id:get_field("_Kind") or -1, id:get_field("_ID") or -1) or "?"
            local s = { key = key, frame = pi:get_field("_CurrentFrame") or 0, max = pi:get_field("_MaxFrame") or 0,
                status = tostring(pi:get_field("_CurrentStatus")), count = n }
            -- several can be loaded; the one whose frame moves is the one playing
            if not best or (s.frame > 0 and best.frame == 0) then best = s end
        end
    end
    return best
end

local S = nil          -- { key, max, next = index of next description line, waited_since }
local last_subn, last_logged_sub = 0, nil
local function scene_started(s)
    S = { key = s.key, max = s.max, next = 1, start = os.clock() }
    local d = A.data[s.key]
    pcall(fs.write, "REAccess_scene_now.txt", "1 " .. tostring(s.key))   -- 11/14: picture helper reads this at once (record file is flushed late)
    rec_line(string.format("SCENE START %s max %.0f status %s players %d%s", s.key, s.max, s.status, s.count,
        d and (" (described: " .. (d.title ~= "" and d.title or "yes") .. ")") or " (no description yet)"))
end
local function scene_ended(why)
    pcall(fs.write, "REAccess_scene_now.txt", "0")
    if S then rec_line(string.format("SCENE END %s (%s) after %.1f s", S.key, why, os.clock() - S.start)) end
    S = nil
    rec_flush()
end

local function tick()
    local okc, s = pcall(current_scene)
    if not okc then s = nil end
    if s and s.max > 0 then
        if not S or S.key ~= s.key then
            if S then scene_ended("next scene") end
            scene_started(s)
        end
        S.frame = s.frame
        -- recorder: subtitles on/off with frames
        local n = sub_count() or 0
        if A.last_sub and A.last_sub ~= last_logged_sub then
            last_logged_sub = A.last_sub
            rec_line(string.format("SUB %s frame %.0f: %s", S.key, s.frame, A.last_sub))
        end
        if n ~= last_subn then
            rec_line(string.format("SUBS %s frame %.0f: %d on screen", S.key, s.frame, n))
            last_subn = n
        end
        -- player
        local d = A.data[S.key]
        local ln = d and d.lines[S.next]
        if ln and s.frame >= ln.frame then
            local now = os.clock()
            S.waited_since = S.waited_since or now
            if n == 0 or now - S.waited_since > 4 then
                RE4Access.speak(ln.text, false)
                rec_line(string.format("DESCRIBED %s line %d at frame %.0f (wanted %.0f, subs %d)", S.key, S.next, s.frame, ln.frame, n))
                S.next = S.next + 1
                S.waited_since = nil
            end
        end
    elseif S then
        scene_ended("stopped")
    end
end

-- The description file is re-read every 5 s outside cutscenes, so Claude's updates work
-- without restarting the game.
local next_check = 0
re.on_frame(function()
    if RE4Access.describe ~= A then return end
    pcall(install_hooks)
    local ok, e = pcall(tick)
    if not ok then
        A.err_n = (A.err_n or 0) + 1
        if A.err_n < 5 then log_ad("tick error: " .. tostring(e)) end
    end
    if not S and os.clock() > next_check then
        next_check = os.clock() + 5
        local src = fs.read("REAccess_audio_description.txt") or ""
        if src ~= A.src then pcall(A.load) end
    end
end)

RE4Access.describe = A
return A
