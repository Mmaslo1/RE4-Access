-- RE4 Access: end-of-chapter screens. 10/17 the user finished Chapter 2 and
-- heard nothing: the "END CHAPTER" screen (Gui_ui5010) and its key line
-- (Gui_ui0200: Pause Menu, Chapter Results, Typewriter, Next) were never read,
-- nor the Chapter Results page. While the end screen is up, this reads it once,
-- and then reads every new screen that opens over it (results, save, ...).

local E = {}
local function say(text, interrupt) RE4Access.speak(text, interrupt) end

local SKIP = { Gui_ui0300 = true, Gui_ui2041 = true, WhiteFade = true, BlackFade = true }
local drawn, seen = {}, {}
local active, check_at = false, 0

re.on_pre_gui_draw_element(function(el, ctx)
    pcall(function()
        local go = el:call("get_GameObject")
        drawn[go:call("get_Name")] = go
    end)
    return true
end)

local function texts_of(go)
    local out = {}
    local M = RE4Access.menu
    local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
    local gui = go:call("getComponent(System.Type)", sdk.typeof("via.gui.GUI"))
    if not gui then return out end
    local function walk(c, d)
        if not c or d > 18 then return end
        pcall(function()
            local tn = c:get_type_definition():get_full_name()
            if (tn == "via.gui.Text" or tn == "via.gui.MaterialText") and c:call("get_ActualVisible") then
                local raw = mg:call(nil, c:call("get_MessageId")) or ""
                if raw == "" then raw = c:call("get_Message") or "" end
                local s = M and M.clean(raw) or raw
                if s ~= "" and s ~= "back" and s ~= "confirm" then out[#out + 1] = s end
            end
        end)
        local ch; pcall(function() ch = c:call("get_Child") end)
        while ch do walk(ch, d + 1); local nx; pcall(function() nx = ch:call("get_Next") end); ch = nx end
    end
    walk(gui:call("get_View"), 0)
    return out
end

-- Results pages draw the value before its label ("13. TIMES DAMAGED") and
-- leave placeholders ("{0} CP", "NEW", Japanese layout names). 10/17: "did not
-- read very well". Drop the junk, say label then value, in reading order.
local function tidy(t)
    local out = {}
    for _, x in ipairs(t) do
        local ok = x ~= "NEW" and not x:find("{%d") and not x:find("[\128-\255]") and x ~= ""
        if ok then out[#out + 1] = x end
    end
    local res, i = {}, 1
    while i <= #out do
        local v, l = out[i], out[i + 1]
        if l == "GAME MODE" then
            res[#res + 1] = "Game mode " .. v:lower()
            i = i + 2
        elseif l and v:match("^[%d%.:%%,]+$") and not l:match("^[%d%.:%%,]+$") then
            res[#res + 1] = l:sub(1, 1) .. l:sub(2):lower() .. " " .. v
            i = i + 2
        else
            res[#res + 1] = v
            i = i + 1
        end
    end
    -- the page title comes last in the layout: say it first
    if #res > 1 and res[#res]:match("^RESULTS$") then
        local title = (res[#res - 1] or "") .. " " .. res[#res]
        table.remove(res) table.remove(res)
        table.insert(res, 1, title)
    end
    return res
end

re.on_frame(function()
    local now = os.clock()
    if now < check_at then return end
    check_at = now + 0.4
    local guis = drawn
    drawn = {}
    pcall(function()
        local at_end = guis.Gui_ui5010 ~= nil
        if at_end and not active then
            active = true
            seen = { Gui_ui5010 = true, Gui_ui0200 = true }
            say("End of the chapter. "
                -- keys found by testing 10/19 (Escape and Backspace do nothing here)
                .. "Keys on this screen: Shift opens the Typewriter to save: Enter on Save Game, pick a slot with the arrows, Enter, then Yes. "
                .. "Tab or I shows the chapter results; the right mouse button closes them. "
                .. "P opens the pause menu. Enter goes on to the next chapter.", true)
            log.info("[RE4Access] end of chapter screen")
        elseif not at_end and active then
            active = false
            seen = {}
            log.info("[RE4Access] end of chapter screen closed")
        end
        if not active then return end
        -- anything new on top of the end screen: read it once
        for name, go in pairs(guis) do
            if not seen[name] and not SKIP[name] then
                local t = tidy(texts_of(go))
                if #t > 0 then
                    seen[name] = true
                    log.info("[RE4Access] end screen read " .. name)
                    local text = table.concat(t, ". ")
                    if text:find("confirm Next", 1, true) or text:find("Next", 1, true) then
                        text = text:gsub("%.? ?confirm Next", "") .. ". Press Enter to go on."
                    end
                    say(text, false)
                end
            end
        end
        for name in pairs(seen) do if not guis[name] and name ~= "Gui_ui5010" and name ~= "Gui_ui0200" then seen[name] = nil end end
    end)
end)

RE4Access.endscreen = E
return E
