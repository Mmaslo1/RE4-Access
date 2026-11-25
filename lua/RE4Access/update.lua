-- RE4 Access updater (0.29.0). The speech plugin (REAccessSpeech 0.5.0) asks
-- GitHub for a newer RE4 Access when the game starts and writes what it found to
-- reframework\data\REAccess_update.txt. This file speaks it and handles Shift+F1:
--   Shift+F1  download the new version (it installs by itself after the game closes),
--             or say whether you are up to date.
-- No checking at all: create reframework\data\REAccess_update_off.txt.

local U = {}
local STATUS, GO, LAST = "REAccess_update.txt", "REAccess_update_go.txt", "REAccess_last_version.txt"

local state, new_ver, have_ver = "", "", ""
local spoken = {}
local next_read = 0

local function say(t, interrupt) if RE4Access and RE4Access.speak then RE4Access.speak(t, interrupt) end end

local function read_status()
    local s = fs.read(STATUS) or ""
    local parts = {}
    for p in (s:gsub("[\r\n]+$", "") .. "\t"):gmatch("([^\t]*)\t") do parts[#parts + 1] = p end
    return parts[1] or "", parts
end

local READY = "Update downloaded. It installs by itself after you close the game. Windows asks for permission once: press Alt+Y."

local function announce(st, p)
    if st == "available" then
        say("Update available: RE4 Access " .. new_ver .. ". You have " .. have_ver .. ". Press Shift+F1 to download it.", false)
    elseif st == "ready" then
        say(READY, false)
    elseif st == "failed" then
        say("The update download failed. Press Shift+F1 to try again.", false)
    end
end

-- Shift+F1 (called from game.lua)
function U.key()
    if state == "available" or state == "failed" then
        fs.write(GO, "go")
        say("Downloading the update. Keep playing; I will tell you when it is ready.", true)
    elseif state == "downloading" then
        say("Still downloading the update.", true)
    elseif state == "ready" then
        say(READY, true)
    elseif state == "current" then
        say("RE4 Access " .. RE4Access.version .. " is the newest version.", true)
    elseif state == "error" then
        say("Could not check for updates. Maybe no internet. It checks again next time you start the game.", true)
    elseif state == "off" then
        say("Update check is off. Delete REAccess_update_off.txt in reframework data to turn it on.", true)
    else
        say("Still checking for updates.", true)
    end
end

re.on_frame(function()
    local now = os.clock()
    if now < next_read then return end
    next_read = now + 1
    local st, p = read_status()
    if st == state then return end
    state = st
    if st == "available" then new_ver, have_ver = p[2] or "", p[3] or "" end
    if (st == "downloading" or st == "ready" or st == "failed") and p[2] then new_ver = p[2] end
    -- each message once per game start ("failed" may repeat after a retry)
    if st == "failed" or not spoken[st] then
        spoken[st] = true
        announce(st, p)
    end
end)

-- "Updated to ..." once after a new version was installed.
do
    local last = (fs.read(LAST) or ""):gsub("%s+", "")
    if last ~= RE4Access.version then
        if last ~= "" then say("RE4 Access updated to version " .. RE4Access.version .. ".", false) end
        fs.write(LAST, RE4Access.version)
    end
end

RE4Access.update = U
return U
