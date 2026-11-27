-- RE4 Access - blind accessibility mod for Resident Evil 4 (2023)
-- Speech goes through the REAccessSpeech plugin (reframework\plugins\REAccessSpeech.dll).

local VERSION = "0.29.2"
local SPEECH_FILE = "REAccess_speech.txt"   -- inside reframework\data
local KEEP = 30                              -- recent messages kept in the file

local session = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
local next_id = 0
local recent = {}

local function write_channel()
    local lines = { "session " .. session }
    for _, m in ipairs(recent) do
        lines[#lines + 1] = m.id .. "\t" .. (m.interrupt and "1" or "0") .. "\t" .. m.text
    end
    lines[#lines + 1] = "END"
    fs.write(SPEECH_FILE, table.concat(lines, "\n") .. "\n")
end

-- speak(text, interrupt): interrupt=true cuts off whatever JAWS is saying.
local function speak(text, interrupt)
    if text == nil or text == "" then return end
    text = tostring(text):gsub("[\r\n\t]", " ")
    next_id = next_id + 1
    recent[#recent + 1] = { id = next_id, interrupt = interrupt and true or false, text = text }
    while #recent > KEEP do table.remove(recent, 1) end
    write_channel()
    log.info("[RE4Access] say: " .. text)
end

local last_spoken = ""
-- 0.25.3 (ON1XN 11/3): an arrival line ("Stop here ... press F") must not be cut
-- off by the next ordinary line. For a few seconds after it, other lines wait
-- their turn instead of interrupting. Danger lines and anything in a fight still
-- interrupt at once, and a fight ends the protection.
local DANGER = { "^Danger", "^Watch out", "^Look out", "^Enemy", "coming!", "behind you", "^Fire", "^Run", "^Dodge", "^Grab", "^Trap", "^Health", "^Low health", "^Ashley" }
local function protected_now(text)
    local p = RE4Access and RE4Access.protect_until
    if not p or os.clock() >= p then return false end
    local G = RE4Access.game
    local okf, fighting = pcall(function() return G and G.in_fight and G.in_fight() end)
    if okf and fighting then RE4Access.protect_until = nil return false end
    for _, pat in ipairs(DANGER) do if tostring(text):find(pat) then return false end end
    return true
end
local function speak_tracked(text, interrupt)
    if RE4Access and RE4Access.speak_hold then interrupt = false end
    if interrupt and text and tostring(text):sub(1, 1) ~= "#" and protected_now(text) then interrupt = false end
    if RE4Access and RE4Access.lang then text = RE4Access.lang.translate(text) end
    if text and text ~= "" then last_spoken = tostring(text) end
    speak(text, interrupt)
end

-- reframework\data\REAccess_owner.txt exists only on the owner's PC and is never packaged.
-- Without it: no unlimited ammo, no developer channel. fs.read gives "" for a missing file.
RE4Access = { speak = speak_tracked, version = VERSION, owner = (fs.read("REAccess_owner.txt") or "") ~= "" }
-- Warning sound: the plugin plays reframework\data\REAccess_<name>.wav (plugin 0.2.0+).
function RE4Access.sound(name) speak("#sound " .. name, false) end
function RE4Access.repeat_last()
    if last_spoken ~= "" then speak(last_spoken, true) else speak("Nothing to repeat", true) end
end

-- Developer channel: Claude drops Lua into reframework\data\REAccess_cmd.lua,
-- the result goes to REAccess_cmd_out.txt. Read-only inspection of the game.
local CMD_FILE, OUT_FILE = "REAccess_cmd.lua", "REAccess_cmd_out.txt"
local last_cmd = fs.read(CMD_FILE) or ""   -- don't rerun a leftover command
local frame = 0
re.on_frame(function()
    if not RE4Access.owner then return end
    frame = frame + 1
    if frame % 30 ~= 0 then return end
    local src = fs.read(CMD_FILE)
    if not src or src == "" or src == last_cmd then return end
    last_cmd = src
    local out = {}
    local function p(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        out[#out + 1] = table.concat(parts, "\t")
    end
    local env = setmetatable({ p = p, say = speak }, { __index = _G })
    local fn, err = load(src, "cmd", "t", env)
    if fn then
        local ok, e = pcall(fn)
        if not ok then out[#out + 1] = "ERROR: " .. tostring(e) end
    else
        out[#out + 1] = "COMPILE ERROR: " .. tostring(err)
    end
    out[#out + 1] = "DONE " .. os.time()
    fs.write(OUT_FILE, table.concat(out, "\n"))
end)

do
    local ok, lang = pcall(require, "RE4Access.lang")
    if ok then RE4Access.lang = lang else log.info("[RE4Access] language files off: " .. tostring(lang)) end
end

for _, mod in ipairs({ "RE4Access.menu", "RE4Access.game", "RE4Access.route", "RE4Access.places", "RE4Access.hex", "RE4Access.dial", "RE4Access.crystal", "RE4Access.money", "RE4Access.guide", "RE4Access.endscreen", "RE4Access.mapread", "RE4Access.stained", "RE4Access.ashley", "RE4Access.siege", "RE4Access.flee", "RE4Access.files", "RE4Access.explore", "RE4Access.describe", "RE4Access.ch10", "RE4Access.ch11", "RE4Access.minecart", "RE4Access.update" }) do
    local ok, err = pcall(require, mod)
    if not ok then log.info("[RE4Access] " .. mod .. " failed: " .. tostring(err)) end
end

log.info("[RE4Access] " .. VERSION .. " loaded, owner options " .. (RE4Access.owner and "on" or "off"))
speak("RE4 Access loaded", true)
