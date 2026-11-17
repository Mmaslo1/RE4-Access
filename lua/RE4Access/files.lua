-- RE4 Access: the Files screen, missed documents and side requests (10/31).
-- Files screen: chainsaw.FileSelectGuiBehavior (the list) and FileDetailGuiBehavior
-- (a document opened). Their lateUpdateOnActive run only while they are on screen.
-- Minus: next document in this part of the game that was not picked up, read aloud.
-- Shift+Minus: the requests you have, with progress and reward.
-- Nothing here changes the game: no document gets marked as found or read.

local F = {}
-- On the Files screen the general menu reader said every name a second time and
-- "Requests" after each document (10/31 log), so only this module speaks there.
RE4Access.speak_all = RE4Access.speak_all or RE4Access.speak
local function say(text, interrupt) RE4Access.speak_all(text, interrupt) end
function RE4Access.speak(text, interrupt)
    local f = RE4Access.files
    if f and f.on_screen() then return end
    RE4Access.speak_all(text, interrupt)
end
local msg_get = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
local function clean(s) return RE4Access.menu.clean(s or "") or "" end
local function fm() return sdk.get_managed_singleton("chainsaw.FileManager") end

local TABS = { [1] = "Village documents", [2] = "Castle documents", [3] = "Island documents", [4] = "Radio logs", [5] = "Requests" }
local QUEST_BASE = 20000
local PHASE = { [1] = "not started", [2] = "in progress", [3] = "in progress", [4] = "done, go to the Merchant for the reward", [5] = "finished", [6] = "on hold", [7] = "finished" }

local function title_of(id)
    local d = fm():call("getSingleDocumentData", id)
    if not d then return "" end
    return clean(msg_get:call(nil, d:get_field("<TitleGuid>k__BackingField")))
end

-- "In progress. Progress 1 of 3. Where: ... Reward: 5 Spinels."
function F.quest_status(id)
    local qid = id - QUEST_BASE
    local qm = sdk.get_managed_singleton("chainsaw.QuestManager")
    local order = qm:call("getQuestOrder(chainsaw.QuestFileID)", qid)
    local data = fm():call("getSingleQuestFileData", qid)
    if not order or not data then return "" end
    local parts = {}
    local ph = PHASE[order:get_field("<CurrPhase>k__BackingField")]
    if ph then parts[#parts + 1] = ph end
    -- the game's strings carry their own labels: "Area: Abandoned Factory", "Progress: 0/3"
    for _, q in ipairs({ "getQuestCompleteHintMessage", "getQuestClearHintPositionString", "getQuestProgressNum", "getQuestRewardString" }) do
        local ok, s = pcall(function() return fm():call(q, order, data) end)
        s = ok and clean(s) or ""
        if s ~= "" and not s:find("None specified", 1, true) then parts[#parts + 1] = s end
    end
    return table.concat(parts, ". ")
end

local function full_text(id)
    local text = RE4Access.game.document_text(id) or ""
    if id > QUEST_BASE then
        local ok, st = pcall(F.quest_status, id)
        if ok and st ~= "" then text = text .. " " .. st .. "." end
    end
    return text
end
F.full_text = full_text

-- ---------------- Files screen ----------------
local scr = { sel = nil, tab = nil, mode = nil, read = nil, at = -10 }
function F.on_screen() return os.clock() - scr.at < 0.3 end

local function on_list(this)
    local m = fm()
    local tab = m:get_field("<CurrTab>k__BackingField")
    local id = this:get_field("<CurrSelectedDocumentID>k__BackingField")
    local mode = this:get_field("<CurrFileMode>k__BackingField")
    if os.clock() - scr.at > 1 then scr.tab, scr.sel, scr.mode, scr.read = nil, nil, nil, nil end   -- screen just opened
    scr.at = os.clock()
    if tab ~= scr.tab then
        scr.tab = tab
        scr.sel = nil
        say(TABS[tab] or "Files", true)
    end
    if id ~= scr.sel and id and id >= 0 then
        scr.sel = id
        scr.read = nil
        local unread = not m:call("HasReadFile", id)
        say(title_of(id) .. (unread and ", not read yet" or "") .. ". Enter reads it.", tab == nil)
    end
    if mode ~= scr.mode then
        log.info("[RE4Access] files: mode " .. tostring(scr.mode) .. " -> " .. tostring(mode))
        if scr.mode == 3 and mode == 2 and id and id >= 0 then
            say("Back in the list. " .. title_of(id) .. ". Up and Down Arrow move, Enter reads.", true)
        end
        scr.mode = mode
    end
    if mode == 3 and id and id >= 0 and scr.read ~= id then
        scr.read = id
        say(full_text(id) .. " Escape goes back.", true)
    elseif mode ~= 3 then
        scr.read = nil
    end
end

if not RE4Access.files_hooked then
    RE4Access.files_hooked = true
    local td = sdk.find_type_definition("chainsaw.FileSelectGuiBehavior")
    local ok, e = pcall(sdk.hook, td:get_method("lateUpdateOnActive"), function(args)
        local okl, el = pcall(function() RE4Access.files.on_list(sdk.to_managed_object(args[2])) end)
        if not okl and not RE4Access.files_err then
            RE4Access.files_err = true
            log.info("[RE4Access] files: " .. tostring(el))
        end
    end, function(r) return r end)
    log.info("[RE4Access] files hook: " .. tostring(ok) .. " " .. tostring(e))
end
F.on_list = on_list

-- ---------------- missed documents ----------------
-- Only parts of the game already reached, so nothing later gets spoiled.
local CAT = { 2, 4, 8 }
local function reached(m, id_list)
    local top = 2
    for _, id in ipairs(id_list) do
        if m:call("IsOpenedFile", id) then
            local c = m:call("getSingleDocumentData", id):get_field("CategoryAttr")
            for _, bit in ipairs(CAT) do
                if (c & bit) ~= 0 and bit > top then top = bit end
            end
        end
    end
    return top
end
function F.missed()
    local m = fm()
    local ids = {}
    for _, f in ipairs(sdk.find_type_definition("chainsaw.DocumentID"):get_fields()) do
        if f:is_static() and f:get_type():get_full_name() == "chainsaw.DocumentID" then
            local id = f:get_data(nil)
            if id > 0 and id < 10000 and m:call("getSingleDocumentData", id) then ids[#ids + 1] = id end
        end
    end
    table.sort(ids)
    local top, out = reached(m, ids), {}
    for _, id in ipairs(ids) do
        if not m:call("IsOpenedFile", id) then
            local c = m:call("getSingleDocumentData", id):get_field("CategoryAttr")
            local part = (c & 2 ~= 0 and 2) or (c & 4 ~= 0 and 4) or (c & 8 ~= 0 and 8) or 99
            if part <= top and title_of(id) ~= "" then out[#out + 1] = id end
        end
    end
    return out
end

local miss = { i = 0 }
function F.next_missed()
    local list = F.missed()
    if #list == 0 then say("No missed documents so far.", true) return end
    miss.i = miss.i % #list + 1
    say("Missed " .. miss.i .. " of " .. #list .. ". " .. RE4Access.game.document_text(list[miss.i]), true)
end

-- ---------------- requests you have ----------------
function F.requests()
    local m, out = fm(), {}
    for id = QUEST_BASE + 1, QUEST_BASE + 40 do
        local okd, d = pcall(m.call, m, "getSingleDocumentData", id)
        if okd and d and m:call("IsOpenedFile", id) then
            local ok, st = pcall(F.quest_status, id)
            out[#out + 1] = title_of(id) .. ": " .. (ok and st or "")
        end
    end
    if #out == 0 then return "No requests yet." end
    return #out .. " requests. " .. table.concat(out, ". ")
end

-- ---------------- keys ----------------
local VK_MINUS, VK_SHIFT = 0xBD, 0x10
local was_down = false
re.on_frame(function()
    local f = RE4Access.files
    if not f or f ~= F then return end
    local down = reframework:is_key_down(VK_MINUS)
    if down and not was_down then
        local ok, e = pcall(function()
            if reframework:is_key_down(VK_SHIFT) then say(F.requests(), true) else F.next_missed() end
        end)
        if not ok then log.info("[RE4Access] files key: " .. tostring(e)) end
    end
    was_down = down
end)

RE4Access.files = F
return F
