-- RE4 Access: dial locks on cabinets (chainsaw.GmDialLock inside GmLocker._DialLocks).
-- Each ring (DigitBlock) shows 6 pictures; _Index is the picture showing now,
-- _Correct the one that opens it. _CurDigit is the ring being turned (-1 = not
-- in use). Live-read 10/17 at the Chief's closet (rings 3, Correct "PYB").
-- Pictures are named where the clue names them (the Iluminados page: the
-- farmer's crop, the swineherd's pig, the grandam's babe); other pictures by number.

local D = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end

local CLUE_WORDS = {
    ["村長家クローゼット"] = { "crop", "pig", "baby" },
}

local locks, scan_at = {}, -10
local cur, prev

local function scan(now)
    if now - scan_at < 2 then return end
    scan_at = now
    locks = {}
    pcall(function()
        local pos = RE4Access.game.player_pos()
        if not pos then return end
        for _, t in ipairs(RE4Access.game.scan_things(pos, 4)) do
            pcall(function()
                local lk = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmLocker"))
                if not lk then return end
                for _, dl in ipairs(lk:get_field("_DialLocks"):get_elements()) do
                    local words
                    pcall(function()
                        local n = dl:call("get_GameObject"):call("get_Name")
                        for k, v in pairs(CLUE_WORDS) do if n:find(k, 1, true) then words = v end end
                    end)
                    locks[#locks + 1] = { dl = dl, words = words }
                end
            end)
        end
    end)
end

local function picture(l, ring, b)
    local idx, correct = b:get_field("_Index"), b:get_field("_Correct")
    if l.words and l.words[ring] and idx == correct then return l.words[ring] end
    return "picture " .. (idx + 1) .. " of " .. #tostring(b:get_field("_String"))
end

local function rings_text(l, blocks)
    local parts = {}
    for i, b in ipairs(blocks) do parts[#parts + 1] = picture(l, i, b) end
    return table.concat(parts, ", ")
end

re.on_frame(function()
    local now = os.clock()
    scan(now)
    local active
    for _, l in ipairs(locks) do
        local ok, d = pcall(function() return l.dl:get_field("_CurDigit") end)
        if ok and d and d >= 0 then active = l break end
    end
    if not active then
        if cur then
            -- left the lock: opened if every ring is on its picture
            local open = true
            pcall(function()
                for _, b in ipairs(cur.dl:get_field("_Blocks"):get_elements()) do
                    if b:get_field("_Index") ~= b:get_field("_Correct") then open = false end
                end
            end)
            if open then say("Dial lock opened.", true) end
        end
        cur, prev = nil, nil
        return
    end
    pcall(function()
        local blocks = active.dl:get_field("_Blocks"):get_elements()
        local ring = active.dl:get_field("_CurDigit") + 1
        local idx = {}
        for i, b in ipairs(blocks) do idx[i] = b:get_field("_Index") end
        -- same lock = same address (the scan builds new tables every 2 s; 10/17 the
        -- whole intro was repeated after every key press)
        local addr = active.dl:get_address()
        if not cur or cur.addr ~= addr then
            cur = active
            cur.addr = addr
            say("Dial lock, " .. #blocks .. " rings. A and D pick a ring, W and S turn it. Make the rings say crop, pig, baby, then press F. Now: " .. rings_text(active, blocks)
                .. ". Ring " .. ring .. " selected.", true)
        elseif prev then
            if ring ~= prev.ring then
                say("Ring " .. ring .. ": " .. picture(active, ring, blocks[ring]), true)
            elseif idx[ring] ~= prev.idx[ring] then
                say(picture(active, ring, blocks[ring]), true)
            end
        end
        prev = { ring = ring, idx = idx }
    end)
end)

RE4Access.dial = D
return D
