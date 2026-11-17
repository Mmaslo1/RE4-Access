-- RE4 Access: generic menu reader (shared RE Engine core).
-- Watches every GUI the game draws. In any visible ScrollList it speaks the
-- selected item ("Option: value"), and speaks the value again when it changes.
-- Needs RE4Access.speak (set by RE4Access.lua).

local M = {}

local msgT = sdk.find_type_definition("via.gui.message")
local m_get = msgT:get_method("get(System.Guid)")
local m_guid_by_name = msgT:get_method("getGuidByName(System.String)")

-- Spoken names for button icons that appear inside menu text.
local ICONS = {
    DECIDE = "confirm", CANCEL = "back",
}

local ref_cache = {}
local function resolve_ref(name)
    local c = ref_cache[name]
    if c ~= nil then return c end
    local s = ""
    pcall(function()
        local g = m_guid_by_name:call(nil, name)
        if g then s = m_get:call(nil, g) or "" end
    end)
    ref_cache[name] = s
    return s
end

-- Combine recipes are drawn as ingredient pictures with "have: need" numbers; the
-- reader saw only "Mixed Herb (G+R): 0: 1: +: 1". Herb recipes are spelled out.
local HERB_LETTERS = { G = "Green Herb", R = "Red Herb", Y = "Yellow Herb" }
function M.readable_recipe(text)
    local name, letters = text:match("^(Mixed Herb %(([GRY%+]+)%))")
    if not name then return nil end
    local parts = {}
    for l in letters:gmatch("[GRY]") do parts[#parts + 1] = HERB_LETTERS[l] end
    return name .. ": combine " .. table.concat(parts, " and ") .. ". You need each one in your case."
end

-- Turn game message text into plain speech text.
function M.clean(s)
    if s == nil then return "" end
    s = tostring(s)
    for _ = 1, 4 do
        local n
        s, n = s:gsub("<REF%s+([^>]+)>", function(name) return resolve_ref(name) end)
        if n == 0 then break end
    end
    s = s:gsub("<ICON%s+([^>]+)>", function(icon)
        return ICONS[icon] and (" " .. ICONS[icon] .. " ") or ""
    end)
    s = s:gsub("<[^>]*>", "")         -- any other tag (colors, etc.)
    s = s:gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The same game text in English, whatever language the game runs in (10/31 live:
-- Language 1 = English). The mod's own logic compares English words like objectives.
local m_get_lang = msgT:get_method("get(System.Guid, via.Language)")
function M.text_en(guid)
    local s = m_get_lang:call(nil, guid, 1) or ""
    for _ = 1, 4 do
        local n
        s, n = s:gsub("<REF%s+([^>]+)>", function(name) return m_get_lang:call(nil, m_guid_by_name:call(nil, name), 1) or "" end)
        if n == 0 then break end
    end
    return M.clean(s)
end

-- get_Message often holds only the layout's placeholder text; the real
-- (translated) text comes from the message id.
local function text_of(ctrl)
    local msg
    pcall(function()
        local id = ctrl:call("get_MessageId")
        if id then msg = m_get:call(nil, id) end
    end)
    if msg == nil or msg == "" then
        pcall(function() msg = ctrl:call("get_Message") end)
    end
    return M.clean(msg)
end

local function type_name(ctrl)
    return ctrl:get_type_definition():get_full_name()
end

local function is_text(tn) return tn == "via.gui.Text" or tn == "via.gui.MaterialText" end

-- Visible text inside a control, in tree order, deduplicated.
local function collect_texts(ctrl, out, depth)
    local guard = 0
    while ctrl and guard < 200 do
        guard = guard + 1
        if ctrl:call("get_Visible") then
            if is_text(type_name(ctrl)) then
                local t = text_of(ctrl)
                if t ~= "" and out[#out] ~= t then out[#out + 1] = t end
            end
            local child = ctrl:call("get_Child")
            if child and depth < 10 then collect_texts(child, out, depth + 1) end
        end
        ctrl = ctrl:call("get_Next")
    end
    return out
end

-- Find visible ScrollLists and header texts in a GUI tree.
local function find_lists(ctrl, lists, depth)
    local guard = 0
    while ctrl and guard < 400 do
        guard = guard + 1
        if ctrl:call("get_Visible") then
            if type_name(ctrl) == "via.gui.ScrollList" then
                lists[#lists + 1] = ctrl
            else
                local child = ctrl:call("get_Child")
                if child and depth < 14 then find_lists(child, lists, depth + 1) end
            end
        end
        ctrl = ctrl:call("get_Next")
    end
    return lists
end

local function header_of(view)
    -- Most RE4 screens name the title text "m_header" or "m_title".
    local found
    local function walk(ctrl, depth)
        while ctrl and not found do
            local name = ctrl:call("get_Name")
            if (name == "m_header" or name == "m_title") and ctrl:call("get_Visible") then
                local t = text_of(ctrl)
                if t ~= "" then found = t return end
            end
            local child = ctrl:call("get_Child")
            -- 10/31: a row's own title is not the screen's header ("HDR Mode. HDR Mode: Off")
            if child and depth < 8 and type_name(ctrl) ~= "via.gui.ScrollList" then walk(child, depth + 1) end
            ctrl = ctrl:call("get_Next")
        end
    end
    walk(view, 0)
    return found
end

-- Description text that belongs to the selected option but sits outside
-- the list (e.g. the difficulty explanation on the GAME MODE screen).
local INFO_NAMES = { m_info = true, m_explain = true, m_description = true, m_desc = true, m_detail = true }
local function info_of(view)
    local found
    local function walk(ctrl, depth)
        local guard = 0
        while ctrl and not found and guard < 400 do
            guard = guard + 1
            if ctrl:call("get_Visible") then
                if INFO_NAMES[ctrl:call("get_Name")] then
                    local t = text_of(ctrl)
                    if t ~= "" then found = t return end
                end
                local child = ctrl:call("get_Child")
                if child and depth < 10 then walk(child, depth + 1) end
            end
            ctrl = ctrl:call("get_Next")
        end
    end
    walk(view, 0)
    return found
end

-- Item text: the option name, then its current value, without the
-- help text that sits outside the item.
local function describe_item(item)
    local child = item:call("get_Child")
    local parts = child and collect_texts(child, {}, 0) or {}
    return table.concat(parts, ": ")
end

-- Some values are drawn as pictures (the language names on the setup
-- screen). These providers return the spoken value for such items.
local LANGUAGE_NAMES = {
    JAPANESE = "Japanese", ENGLISH = "English", FRENCH = "French", ITALIAN = "Italian",
    GERMAN = "German", SPANISH = "Spanish", LATIN_AMERICAN_SPANISH = "Latin American Spanish",
    RUSSIAN = "Russian", CHINESE_TRADITIONAL = "Chinese Traditional",
    CHINESE_SIMPLIFIED = "Chinese Simplified", KOREAN = "Korean",
    BRAZILIAN_PORTUGUESE = "Brazilian Portuguese", ARABIC = "Arabic", POLISH = "Polish",
}
local lang_enum_names
local function language_name(value)
    if not lang_enum_names then
        lang_enum_names = {}
        local t = sdk.find_type_definition("chainsaw.option.AppLanguage")
        for _, f in ipairs(t:get_fields()) do
            if f:is_static() then
                pcall(function() lang_enum_names[f:get_data(nil)] = f:get_name() end)
            end
        end
    end
    local n = lang_enum_names[value]
    return n and (LANGUAGE_NAMES[n] or n) or tostring(value)
end

local function contains_control(root, target)
    local function walk(ctrl, depth)
        while ctrl do
            if ctrl:get_address() == target then return true end
            local child = ctrl:call("get_Child")
            if child and depth < 10 and walk(child, depth + 1) then return true end
            ctrl = ctrl:call("get_Next")
        end
        return false
    end
    return walk(root:call("get_Child"), 0)
end

local function picture_value(go, item)
    local beh = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InitLanguageSettingGuiBehavior"))
    if not beh then return nil end
    local sw = beh:get_field("ItemText")
    local guide = sw and sw:get_field("guideText")
    if not guide or not contains_control(item, guide:get_address()) then return nil end
    local langs = sw:call("get_MessageLangues"):get_elements()
    local l = langs[sw:call("get_SelectedIdx") + 1]
    if l == nil then return nil end
    if type(l) == "userdata" then l = l:get_field("value__") end
    return language_name(l)
end

-- State
local drawn = {}          -- GUI game objects drawn since last scan
-- Per-list memory, so two lists on screen at once (a menu and a popup)
-- don't make each other speak again and again.
local lists_state = {}    -- list address -> { item = addr, text = s, seen = scan_no }
local last_item_text      -- last thing spoken, for repeat
local last_header
local last_info
local pending_info        -- { view =, due = scan_no } : read description a moment later
local scan_tick = 0
local scan_no = 0

function M.on_draw(el)
    local ok, go = pcall(function() return el:call("get_GameObject") end)
    if ok and go then drawn[go:get_address()] = go end
end

-- Key Bindings screen (Gui_ui0416): keys are drawn as pictures, so read them from
-- the screen's own data. Spoken after the action: "Aim Weapon: L, or right mouse".
local KEY_SPOKEN = {
    LButton = "left mouse", RButton = "right mouse", MButton = "middle mouse",
    XButton1 = "mouse back button", XButton2 = "mouse forward button",
    LShift = "left shift", RShift = "right shift", LControl = "left control", RControl = "right control",
    LMenu = "left alt", RMenu = "right alt", Return = "Enter", Back = "Backspace",
    Up = "up arrow", Down = "down arrow", Left = "left arrow", Right = "right arrow",
}
local key_names
local function key_name(v)
    if not key_names then
        key_names = {}
        local t = sdk.find_type_definition("via.hid.KeyboardKey")
        for _, f in ipairs(t:get_fields()) do
            if f:is_static() then
                pcall(function()
                    local n = f:get_data(nil)
                    if type(n) == "number" and not key_names[n] then key_names[n] = f:get_name() end
                end)
            end
        end
    end
    local n = key_names[v]
    if not n or v == 0 then return nil end
    if KEY_SPOKEN[n] then return KEY_SPOKEN[n] end
    return (n:gsub("^Alpha", ""))
end

local function key_binding_text(go)
    local b = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.OptionKeyAssignBehavior"))
    if not b then return nil end
    local cmd = b:call("getSelectedCommand")
    local kb = b:get_field("_KeyBindData")
    for i = 0, kb:call("getSettingCount") - 1 do
        local st = kb:call("getChangedSetting", i)
        if st:get_field("_Command") == cmd then
            local a, c = key_name(st:get_field("_PrimaryKey")), key_name(st:get_field("_SecondaryKey"))
            if a and c then return a .. ", or " .. c end
            return a or c or "no key"
        end
    end
    return nil
end
M.key_binding_text = key_binding_text

-- Attache case (Tab): a grid of item pictures. The cursor's slot comes from
-- chainsaw.AcGridControlBehavior (Gui_ui3004) CurrSlotIndex Row/Column; the item
-- in that slot from the player's chainsaw.CsInventoryController item list
-- (ConnectedSlotIndexes = every square an item covers).
local case_state = { key = nil }
-- 10/22: chapter 5 has TWO CsInventoryControllers, the first one empty (Ashley's?);
-- the case read "Empty" everywhere and "No healing items" with herbs in it.
-- Leon's is the one holding items.
local function inventory_controller()
    local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
    local best, bn
    for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
        local c = e:get_field("value")
        if c and c:get_type_definition():get_full_name() == "chainsaw.CsInventoryController" then
            local ok, n = pcall(function() return c:call("getInventoryItemList()"):call("get_Count") end)
            n = ok and n or 0
            if not bn or n > bn then best, bn = c, n end
        end
    end
    return best
end
local function item_display_name(item)
    local id = item:get_field("_ItemId")
    local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
    local name = M.clean(sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)"):call(nil, mm:call("getItemNameMsgId", id)))
    return name ~= "" and name or "Item"
end
local function case_slot_text(row, col, slot_type)
    local ctrl = inventory_controller()
    if not ctrl then return nil end
    local lst = ctrl:call("getInventoryItemList()")
    for i = 0, lst:call("get_Count") - 1 do
        local it = lst:call("get_Item", i)
        if it:get_field("<CurrSlotType>k__BackingField") == slot_type then
            local idx = it:get_field("<ConnectedSlotIndexes>k__BackingField")
            for _, si in ipairs(idx and idx:get_elements() or {}) do
                if si:get_field("Row") == row and si:get_field("Column") == col then
                    local item = it:get_field("<Item>k__BackingField")
                    local text = item_display_name(item)
                    local okw, ammo = pcall(function() return it:call("get_CurrentAmmoCount") end)
                    local okm, amax = pcall(function() return it:call("get_CurrentAmmoMax") end)
                    if text:find("Knife", 1, true) then
                        -- Knives report durability as "ammo" (10/13: Kitchen Knife read
                        -- "0 of 1000 loaded"). Knives equip themselves; no Equip choice.
                        text = text .. ", knife, used automatically with Space"
                    elseif okw and okm and amax and amax > 1 then
                        text = text .. ", " .. ammo .. " of " .. amax .. " loaded"
                    else
                        local count = item:get_field("_CurrentItemCount")
                        if count and count > 1 then text = text .. ", " .. count end
                    end
                    if text == "Red Herb" or text == "Yellow Herb" then
                        text = text .. ", can't be used alone, combine it with a Green Herb"
                    end
                    return text
                end
            end
        end
    end
    return "Empty"
end
-- Healing items in the case, said when it opens ("Healing: Green Herb, row 2 column 1").
local HEAL_WORDS = { "Herb", "First Aid", "Spray", "Egg", "Fish", "Viper", "Bass" }
local function heal_summary()
    local ctrl = inventory_controller()
    if not ctrl then return nil end
    local lst = ctrl:call("getInventoryItemList()")
    local out = {}
    for i = 0, lst:call("get_Count") - 1 do
        local it = lst:call("get_Item", i)
        if it:get_field("<CurrSlotType>k__BackingField") == 0 then
            local item = it:get_field("<Item>k__BackingField")
            local name = item_display_name(item)
            for _, w in ipairs(HEAL_WORDS) do
                if name:find(w, 1, true) then
                    local si = it:get_field("<SlotIndex>k__BackingField")
                    local note = ""
                    if name == "Red Herb" or name == "Yellow Herb" then note = " (can't be used alone, combine it with a Green Herb)" end
                    out[#out + 1] = string.format("%s%s, row %d column %d", name, note, si:get_field("Row") + 1, si:get_field("Column") + 1)
                    break
                end
            end
        end
    end
    if #out == 0 then return "No healing items." end
    return "Healing: " .. table.concat(out, "; ") .. ". The game is paused while the case is open."
end

local function case_update(go)
    local grid = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.AcGridControlBehavior"))
    if not grid then return end
    -- The real cursor (keyboard and mouse) is kept by chainsaw.AttacheCaseGuiController,
    -- entry 3 of AttacheCaseManager._AcControlBehaviorTable (live-checked 10/11).
    local row, col, st
    pcall(function()
        local am = sdk.get_managed_singleton("chainsaw.AttacheCaseManager")
        for _, e in ipairs(am:get_field("_AcControlBehaviorTable"):get_field("_entries"):get_elements()) do
            local b = e:get_field("value")
            if b and b:get_type_definition():get_full_name() == "chainsaw.AttacheCaseGuiController" then
                local si = b:get_field("<CurrSlotIndex>k__BackingField")
                row, col = si:get_field("Row"), si:get_field("Column")
                st = b:get_field("<CurrSlotType>k__BackingField")
                break
            end
        end
    end)
    if not row or not st or st < 0 then
        local si = grid:call("get_CurrSlotIndex")
        row, col, st = si:get_field("Row"), si:get_field("Column"), grid:call("get_CurrSlotType")
    end
    case_state.seen = scan_no
    local key = row .. "," .. col .. "," .. st
    local text = case_slot_text(row, col, st) or ""
    if key ~= case_state.key or text ~= case_state.text then
        local just_opened = case_state.key == nil
        case_state.key, case_state.text = key, text
        RE4Access.speak(text .. ". Row " .. (row + 1) .. ", column " .. (col + 1), true)
        if just_opened then
            local okh, hs = pcall(heal_summary)
            if okh and hs then RE4Access.speak(hs, false) end
        end
    end
end

-- Item command menu (Enter on a case item: Use, Combine, Discard...). Its
-- ScrollList selection doesn't follow the arrow keys; the real cursor is
-- AcCommandMenuGuiBehavior._ItemCommandMenuGui get_CurrSelectedCommandType
-- (chainsaw.ItemCommandType), live-checked 10/12.
local COMMAND_WORDS = { [0] = "Use", [1] = "Equip", [2] = "Unequip", [3] = "Attachments", [4] = "Attach part",
    [5] = "Remove part", [6] = "Shortcut", [7] = "Craft", [8] = "Examine", [9] = "Combine", [10] = "Discard",
    [11] = "Remove gem", [12] = "Sell", [13] = "Store", [14] = "Buy", [15] = "Send to storage",
    [16] = "Equip case", [17] = "Charm slot 1", [18] = "Charm slot 2", [19] = "Charm slot 3", [20] = "Remove charm" }
local command_state = { key = nil, seen = -1 }

-- How many of an item are in the case (all stacks).
local function count_in_case(id)
    local n = 0
    pcall(function()
        local lst = inventory_controller():call("getInventoryItemList()")
        for i = 0, lst:call("get_Count") - 1 do
            local item = lst:call("get_Item", i):get_field("<Item>k__BackingField")
            if item and item:get_field("_ItemId") == id then n = n + (item:get_field("_CurrentItemCount") or 0) end
        end
    end)
    return n
end

-- "Needs 1 Gunpowder, you have 9; 1 Resources (S), you have 0." for the
-- recipe under the cursor (ItemCraftRecipe _RequiredItems).
local function recipe_needs(craft)
    local out = {}
    pcall(function()
        local want = craft:call("get_CurrSelectedRecipeID")
        local list = craft:call("get__CurrRecipeList")
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        local msg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
        for i = 0, list:call("get_Count") - 1 do
            local r = list:call("get_Item", i)
            if r:call("get_RecipeID") == want then
                for _, m in ipairs(r:call("get_RequiredItems"):get_elements()) do
                    local id, need = m:call("get_ItemID"), m:call("get_RequiredNum")
                    local name = M.clean(msg:call(nil, mm:call("getItemNameMsgId", id)))
                    out[#out + 1] = string.format("%d %s, you have %d", need, name, count_in_case(id))
                end
                break
            end
        end
    end)
    if #out == 0 then return nil end
    return "Needs " .. table.concat(out, "; ") .. "."
end
local t_cmd = sdk.typeof("chainsaw.AcCommandMenuGuiBehavior")
local t_popup = sdk.typeof("chainsaw.InventoryPopupGuiBehavior")
local function command_update(go)
    local beh = go:call("getComponent(System.Type)", t_cmd)
    local popup = false
    if not beh then
        -- the same command list over the key item window
        beh = go:call("getComponent(System.Type)", t_popup)
        popup = true
    end
    if not beh then return false end
    command_state.seen = scan_no
    local mode = beh:get_field("<CurrMode>k__BackingField")   -- CommandMenuMode: 1 COMMAND, 2 CRAFT
    if popup then mode = 1 end
    if mode < 0 then command_state.key = nil return true end
    if mode == 2 then
        -- Craft list (Craft on a herb): the recipe under the cursor, as words.
        local craft = beh:get_field("_CraftListGui")
        local idx = craft:call("get_CurrSelectedSlotIndex")
        local key = "craft:" .. tostring(idx)
        if key ~= command_state.key then
            command_state.key = key
            local items = craft:get_field("_AppSelectItems")
            local entry = items and idx and idx >= 0 and idx < items:call("get_Count") and items:call("get_Item", idx)
            local sel = entry and entry:get_field("_SelectItem")
            local text = sel and describe_item(sel) or ""
            text = M.readable_recipe(text) or text
            -- Crafting needs the confirm key HELD until the gauge fills (CraftListGui
            -- setCraftGauge); a tap does nothing (10/12).
            local okc, can = pcall(function() return craft:call("isCraftable", craft:call("get_CurrSelectedRecipeID")) end)
            local needs = recipe_needs(craft)
            local how = (okc and can == false) and (" You're missing an ingredient. " .. (needs or ""))
                or (" " .. (needs and (needs .. " ") or "") .. "Hold Enter for about 2 seconds to craft.")
            text = text:gsub("%.+$", "")
            if text ~= "" then RE4Access.speak(text .. "." .. how, true) end
        end
        return true
    end
    local menu = beh:get_field("_ItemCommandMenuGui")
    if not menu then return true end
    local ctype = menu:call("get_CurrSelectedCommandType")
    if ctype < 0 then command_state.key = nil return true end
    local slot = menu:call("get_CurrSelectedSlotIndex")
    local key = tostring(ctype) .. ":" .. tostring(slot)
    if key ~= command_state.key then
        command_state.key = key
        local word = COMMAND_WORDS[ctype] or ("Command " .. tostring(ctype))
        if ctype == 7 then word = word .. " (combine herbs and make ammo)" end
        RE4Access.speak(word, true)
    end
    return true
end

-- Key items / treasures window (Gui_ui3080, KeyTreasureInventoryGuiBehavior):
-- opens when F is pressed at a machine slot, wayshrine or locked door, and from
-- the case. Reads the selected item and whether it can be used here
-- (CurrUsableItemIds), live-checked 10/12 at the windmill machine.
local keywin_state = { key = nil }
local t_keywin = sdk.typeof("chainsaw.KeyTreasureInventoryGuiBehavior")
local function keywin_update(go)
    local beh = go:call("getComponent(System.Type)", t_keywin)
    if not beh then return false end
    keywin_state.seen = scan_no
    if not keywin_state.intro then
        -- 10/13: a locked drawer opened this window and only "Empty, row 1" was read.
        keywin_state.intro = true
        local n = 0
        pcall(function() n = beh:get_field("CurrUsableItemIds"):call("get_Count") end)
        local mode = 1
        pcall(function() mode = beh:get_field("<CurrMode>k__BackingField") end)
        if mode == 0 then
            -- 11/15: opened from the case (Mode DEFAULT), not at a lock or slot
            RE4Access.speak("Key items and treasures. Key items on the left, treasures on the right. W A S D move. On a gem or a piece of jewelry, Enter then Combine puts gems into jewelry; it sells for more.", true)
        elseif n == 0 then
            RE4Access.speak("Use a key item. Nothing you carry fits here; you need a key you don't have yet. Press Escape to close.", true)
        else
            keywin_state.want = nil
            pcall(function()
                local w, wn = RE4Access.flee.sword_wall_want(RE4Access.game.player_pos())
                if w then keywin_state.want = w keywin_state.want_n = wn end
            end)
            if keywin_state.want then
                RE4Access.speak("Use a key item. Painting " .. keywin_state.want_n .. " needs the " .. keywin_state.want .. ". Move with the arrow keys until I say " .. keywin_state.want .. ", this one. Other swords also fit but are wrong.", true)
            else
                RE4Access.speak("Use a key item. Pick the one that says can be used here.", true)
            end
        end
    end
    local info = beh:call("getCurrSelectedItemInfo")
    if not info then return true end
    local guid = info:get_field("ID")
    local si = info:get_field("SelectedSlotIndex")
    local inv = info:get_field("InventoryType")
    local row, col = si and si:get_field("Row") or 0, si and si:get_field("Column") or 0
    local key = tostring(inv) .. ":" .. row .. ":" .. col
    if key == keywin_state.key then return true end
    keywin_state.key = key
    local id
    for _, f in ipairs({ "<_KeyItemInventoryController>k__BackingField", "<_TreasureInventoryController>k__BackingField" }) do
        local ok, v = pcall(function() return beh:get_field(f):call("getItemId(System.Guid)", guid) end)
        if ok and v and v ~= -1 and v ~= 0 then id = v break end
    end
    if not id and (row < 0 or col < 0 or (row == 0 and col == 0)) then keywin_state.key = nil return true end
    local name = "Empty"
    local usable = false
    if id then
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        name = M.clean(sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)"):call(nil, mm:call("getItemNameMsgId", id)))
        pcall(function()
            local u = beh:get_field("CurrUsableItemIds")
            for i = 0, u:call("get_Count") - 1 do
                local v = u:call("get_Item", i)
                if (type(v) == "number" and v or v:get_field("value__")) == id then usable = true end
            end
        end)
    end
    local text = name .. (usable and ", can be used here. Press Enter, then choose Use." or "") .. " Row " .. (row + 1) .. ", column " .. (col + 1)
    -- 11/15: say "Treasures" / "Key items" when the cursor crosses to the other grid
    if inv ~= keywin_state.inv then
        do
            text = (inv == 2 and "Treasures: " or inv == 1 and "Key items: " or "") .. text
        end
        keywin_state.inv = inv
    end
    if keywin_state.want and id then
        if name == keywin_state.want then
            text = name .. ", this one. Press Enter, then choose Use. Row " .. (row + 1) .. ", column " .. (col + 1)
        elseif name:find("Sword", 1, true) then
            text = name .. ", wrong sword for this painting, keep moving. Row " .. (row + 1) .. ", column " .. (col + 1)
        end
    end
    RE4Access.speak(text, true)
    return true
end

-- 11/15: putting gems into jewelry (Gui_ui3090, KeyTreasureCombineGuiBehavior). Left: the
-- gems you carry (_SlotsGui._CurrSlotItems, ItemId each, CurrSelectedIndex); right: the
-- jewelry (text m_item), its value (m_price) and one "+N ptas." per gem hole (m_price0..2,
-- "+0" = empty). Q and E switch the jewelry. Live-inspected with the Elegant Mask.
local combine_state = { }
local function combine_texts(go)
    local t = { holes = {} }
    local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
    local gui = go:call("getComponent(System.Type)", sdk.typeof("via.gui.GUI"))
    local function walk(c, d)
        if not c or d > 18 then return end
        pcall(function()
            local tn = c:get_type_definition():get_full_name()
            if (tn == "via.gui.Text" or tn == "via.gui.MaterialText") and c:call("get_ActualVisible") then
                local s = M.clean(mg:call(nil, c:call("get_MessageId")))
                if s == "" then s = tostring(c:call("get_Message") or "") end
                local n = c:call("get_Name")
                if n == "m_item" then t.item = s
                elseif n == "m_price" then t.price = M.clean(s)
                elseif n:match("^m_price%d$") then t.holes[#t.holes + 1] = s
                -- 11/15: the total (base + gems + bonus) is the m_num text with "ptas"
                -- (_InfoGui._PriceGui._PriceText); m_price is only the base value
                elseif n == "m_num" and M.clean(tostring(c:call("get_Message") or "")):find("ptas", 1, true) and M.clean(tostring(c:call("get_Message") or "")):find("%d") then t.total = M.clean(tostring(c:call("get_Message")))
                elseif n == "mtxt_bonus" then
                    local raw = tostring(c:call("get_Message") or "")
                    local x = raw:match("%(x[%d%.]+%)")
                    t.bonus = (s ~= "" and s:match("^[%w%s%p]+$") and s) or (x and ("bonus " .. x:sub(2, -2))) or "a bonus"
                end
            end
        end)
        local ch = nil
        pcall(function() ch = c:call("get_Child") end)
        while ch do
            walk(ch, d + 1)
            local nx
            pcall(function() nx = ch:call("get_Next") end)
            ch = nx
        end
    end
    walk(gui:call("get_View"), 0)
    return t
end
-- Gem holes of a piece of jewelry, from the carried item (CombinableTreasureItem
-- ._TreasureCombineInfo._Datas: _Shape 0 round / 1 rectangle, _CombinedItemId -1 = empty).
-- 11/15: the user pressed Enter on gems that did not fit (wrong shape) and thought they went in.
local GEM_SHAPE = { Ruby = 0, Sapphire = 0, ["Yellow Diamond"] = 0, Emerald = 1, Alexandrite = 1, ["Red Beryl"] = 1 }
local SHAPE_WORD = { [0] = "round", [1] = "rectangle" }
local function jewel_holes(jname, gname)
    local holes = {}
    local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
    for _, en in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
        local c = en:get_field("value")
        if c and c:get_type_definition():get_name() == "TreasureInventoryController" then
            local lst = c:call("getItems")
            for k = 0, lst:call("get_Count") - 1 do
                local it = lst:call("get_Item", k)
                if it:get_type_definition():get_name() == "CombinableTreasureItem" and gname(it:get_field("_ItemId")) == jname then
                    local d = it:get_field("_TreasureCombineInfo"):get_field("_Datas")
                    for i = 0, d:call("get_Count") - 1 do
                        local e = d:call("get_Item", i)
                        local gid = e:get_field("_CombinedItemId")
                        holes[#holes + 1] = { shape = e:get_field("_Shape"), gem = (gid and gid ~= -1) and gname(gid) or nil, pos = e:get_field("_Position") }
                    end
                    return holes
                end
            end
        end
    end
    return holes
end
local function holes_text(holes)
    local out = {}
    for _, h in ipairs(holes) do out[#out + 1] = (SHAPE_WORD[h.shape] or "odd") .. " hole " .. (h.gem and ("with " .. h.gem) or "empty") end
    return table.concat(out, ", ")
end
local function fit_text(holes, gem)
    local sh = GEM_SHAPE[gem]
    if sh == nil then return "" end
    for _, h in ipairs(holes) do if h.shape == sh and not h.gem then return ", " .. SHAPE_WORD[sh] .. ", fits here" end end
    for _, h in ipairs(holes) do if h.shape == sh then return ", " .. SHAPE_WORD[sh] .. ", no empty " .. SHAPE_WORD[sh] .. " hole left here" end end
    return ", " .. SHAPE_WORD[sh] .. ", does not fit here, the holes are " .. SHAPE_WORD[1 - sh]
end

local function combine_update(go)
    local b = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.KeyTreasureCombineGuiBehavior"))
    if not b then return false end
    combine_state.seen = scan_no
    local slots = b:get_field("_SlotsGui")
    local list = slots:get_field("_CurrSlotItems")
    local sel = slots:get_field("<CurrSelectedIndex>k__BackingField")
    local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
    local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
    local function gem(i)
        local e = list:call("get_Item", i)
        local id = e:get_field("<ItemId>k__BackingField")
        local name = M.clean(mg:call(nil, mm:call("getItemNameMsgId", id)))
        -- count = the treasure stack's _CurrentItemCount (_Items holds one entry per stack)
        local cnt = 0
        pcall(function()
            local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
            for _, en in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
                local c = en:get_field("value")
                if c and c:get_type_definition():get_name() == "TreasureInventoryController" then
                    local lst = c:call("getItems")   -- List<chainsaw.Item>
                    for k = 0, lst:call("get_Count") - 1 do
                        local item = lst:call("get_Item", k)
                        if item and item:get_field("_ItemId") == id then cnt = cnt + (item:get_field("_CurrentItemCount") or 1) end
                    end
                end
            end
        end)
        return name, cnt
    end
    local t = combine_texts(go)
    local hl = {}
    if t.item then pcall(function() hl = jewel_holes(t.item, function(id) return M.clean(mg:call(nil, mm:call("getItemNameMsgId", id))) end) end) end
    local filled, holes = 0, #t.holes
    if #hl > 0 then holes = #hl for _, h in ipairs(hl) do if h.gem then filled = filled + 1 end end
    else for _, h in ipairs(t.holes) do if not h:find("+0 ", 1, true) and h:find("%d") then filled = filled + 1 end end end
    local parts = {}
    if t.item and t.item ~= combine_state.item then
        local n = list:call("get_Count")
        local gems = {}
        for i = 0, n - 1 do local nm, c = gem(i) gems[#gems + 1] = nm .. (c > 1 and (" " .. c) or "") end
        local intro = combine_state.item == nil and "Combine gems. Q and E switch the jewelry. A and D move through your gems, Enter puts the gem into the jewelry. Escape goes back. " or ""
        parts[#parts + 1] = intro .. t.item .. ", worth " .. tostring(t.total or t.price or "?") .. (t.bonus and (", with " .. t.bonus) or "") .. ", " .. holes .. (holes == 1 and " gem hole: " or " gem holes: ") .. (#hl > 0 and holes_text(hl) or (filled .. " filled")) .. "."
        parts[#parts + 1] = "Your gems: " .. table.concat(gems, ", ") .. "."
        combine_state.item = t.item
        combine_state.sel = nil
        combine_state.price = t.total or t.price
        combine_state.slots = filled
    elseif (t.total or t.price) and (t.total or t.price) ~= combine_state.price then
        parts[#parts + 1] = (filled ~= combine_state.slots and "Gem put in. " or "") .. "Now worth " .. (t.total or t.price) .. (t.bonus and (", with " .. t.bonus) or "") .. ". " .. (#hl > 0 and holes_text(hl) or (filled .. " of " .. holes .. " holes filled")) .. "."
        combine_state.price = t.total or t.price
        combine_state.slots = filled
    end
    -- 11/15: Enter on a gem opens the hole picker (TempJewelCombineGuideGui, CombinePositionSelectGui
    -- CurrPosition); A and D pick the hole, Enter puts the gem in (a gem already there comes back
    -- out: the user's Yellow Diamond was swapped out by the Ruby this way).
    local picking, ppos = false, nil
    pcall(function()
        local guide = b:get_field("_CombineGuideGui"):get_field("_JewelCombineGui")
        if guide:get_field("_RootPanel"):call("get_ActualVisible") then
            picking = true
            ppos = guide:get_field("_PositionSelectGui"):get_field("<CurrPosition>k__BackingField")
        end
    end)
    if picking and ppos ~= combine_state.ppos then
        local h
        -- CurrPosition counts from 1 (live 11/15: 1..3 on the mask; 3 = _Position 2)
        for _, x in ipairs(hl) do if x.pos == ppos - 1 then h = x end end
        local w = "Hole " .. ppos .. " of " .. holes .. (h and (", " .. (SHAPE_WORD[h.shape] or "") .. ", " .. (h.gem and ("has " .. h.gem .. ", it would be swapped out") or "empty")) or "")
        if combine_state.ppos == nil then w = "Pick a hole with A and D. Enter puts the gem in, Escape cancels. " .. w end
        parts[#parts + 1] = w .. "."
        combine_state.ppos = ppos
    elseif not picking then
        combine_state.ppos = nil
    end
    if sel and sel >= 0 and sel ~= combine_state.sel then
        local ok, nm, c = pcall(gem, sel)
        if ok and nm then parts[#parts + 1] = nm .. ", you have " .. c .. fit_text(hl, nm) .. "." end
        combine_state.sel = sel
    end
    if #parts > 0 then RE4Access.speak(table.concat(parts, " "), #parts > 1 or combine_state.sel == sel) end
    return true
end

-- Pop-ups read once when they appear (10/13: the "Blue Request Notes" tutorial
-- and the request details under a Pest Control note were silent).
local READ_ONCE = { Gui_ui2300 = "Tip", Gui_ui3210 = "Request", Gui_ui0410 = "Picture", Gui_ui0417 = "Picture" }
local read_once_seen = {}
local function visible_texts(go)
    local out = {}
    local gui = go:call("getComponent(System.Type)", sdk.typeof("via.gui.GUI"))
    if not gui then return out end
    local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
    local function walk(c, d)
        if not c or d > 16 then return end
        pcall(function()
            local tn = c:get_type_definition():get_full_name()
            if (tn == "via.gui.Text" or tn == "via.gui.MaterialText") and c:call("get_ActualVisible") then
                local s = M.clean(mg:call(nil, c:call("get_MessageId")))
                if s == "" then s = M.clean(c:call("get_Message") or "") end
                if s ~= "" and s ~= "back" and s ~= "Close" and s ~= "back Close" then out[#out + 1] = s end
            end
        end)
        local ch; pcall(function() ch = c:call("get_Child") end)
        while ch do walk(ch, d + 1); local nx; pcall(function() nx = ch:call("get_Next") end); ch = nx end
    end
    walk(gui:call("get_View"), 0)
    return out
end
local function read_once(go, gname, now_seen)
    local kind = READ_ONCE[gname]
    if not kind then return end
    now_seen[gname] = true
    if read_once_seen[gname] then return end
    local texts = visible_texts(go)
    if #texts == 0 then return end
    read_once_seen[gname] = true
    if kind == "Picture" then
        -- Brightness and Display Area: adjusted by looking at a test picture.
        RE4Access.speak(table.concat(texts, ". ") .. ". This screen is set by looking at a picture. Left and right change it. Escape goes back.", false)
    elseif kind == "Tip" then
        -- title first: the shortest line is the title in these pop-ups
        RE4Access.speak("Tip: " .. table.concat(texts, ". ") .. ". Press Escape to close it.", false)
    else
        RE4Access.speak(texts[1], false)   -- "Request: ... Area: ... Reward: ... Progress: ..."
    end
end

-- ---------------- Merchant ----------------
-- 10/14: the shop list read "{0}: NEW: Bolt Thrower" with no price, and there
-- was no way to hear your money. Prices come from InGameShopManager's item
-- settings (matched by the spoken item name); money from InventoryManager.
local function commas(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
function M.money_text()
    local t = "No money info"
    pcall(function()
        local ptas = sdk.get_managed_singleton("chainsaw.InventoryManager"):call("get_CurrPTAS")
        t = "You have " .. commas(ptas) .. " pesetas"
    end)
    pcall(function()
        local sp = sdk.get_managed_singleton("chainsaw.InGameShopManager"):call("get_CurrSpinelCount")
        t = t .. " and " .. sp .. (sp == 1 and " spinel" or " spinels")
    end)
    return t .. "."
end
local shop_prices, shop_gui_cache = nil, {}
local function build_shop_prices()
    local map = {}
    local sm = sdk.get_managed_singleton("chainsaw.InGameShopManager")
    local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
    for _, e in ipairs(sm:get_field("_ShopItemSettingTable"):get_field("_entries"):get_elements()) do
        local v = e:get_field("value")
        if v then pcall(function()
            local id = e:get_field("key")
            local nm = M.clean(m_get:call(nil, mm:call("getItemNameMsgId", id)))
            if nm ~= "" then
                local buy, sell = -1, -1
                pcall(function() buy = v:call("getPurchasePrice") end)
                pcall(function() sell = v:call("getSellingPrice") end)
                map[nm:lower()] = { buy = buy, sell = sell }
            end
        end) end
    end
    return map
end
local function is_shop_gui(go, gname)
    if shop_gui_cache[gname] == nil then
        local c
        pcall(function() c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InGameShopGuiBehavior")) end)
        shop_gui_cache[gname] = c ~= nil
        if c then log.info("[RE4Access] shop gui: " .. tostring(gname)) end
    end
    return shop_gui_cache[gname]
end
-- "{0}: NEW: Bolt Thrower" -> "Bolt Thrower, new, 10,000 pesetas. Sells for 5,000."
local function shop_text(text)
    -- "あああ...B" is the game's placeholder for an entry with no text yet.
    text = text:gsub("{%d}:?%s*", ""):gsub("\227\129\130", "")
    text = text:gsub("^%a$", ""):gsub("^[:%s]+", ""):gsub("[:%s]+$", "")
    text = text:gsub(":%s*%a$", "")
    local new = false
    text = text:gsub("NEW:%s*", function() new = true return "" end)
    if text == "" then return "Item not unlocked yet" end
    -- SELL rows, 11/1: "3,000: Ruby: 0/4" = price, name, marked to sell / owned
    do
        local price, nm, marked, owned = text:match("^([%d,]+):%s*(.-):%s*(%d+)/(%d+)$")
        if not nm then nm, marked, owned = text:match("^(.-):%s*(%d+)/(%d+)$") end
        if nm then
            return nm .. (price and (", " .. price .. " pesetas each") or "") .. ", you have " .. owned .. ", marked to sell " .. marked
        end
    end
    shop_prices = shop_prices or build_shop_prices()
    local pr = shop_prices[text:lower()] or shop_prices[((text:match("^([^:]+)") or text):lower():gsub("%s+$", ""))]
    local out = text .. (new and ", new" or "")
    if pr then
        local ptas = 0
        pcall(function() ptas = sdk.get_managed_singleton("chainsaw.InventoryManager"):call("get_CurrPTAS") end)
        if pr.buy and pr.buy > 0 then
            out = out .. ", " .. commas(pr.buy) .. " pesetas"
            -- PurchaseItemListGui.setDecideGauge: buying fills a gauge, so a tap does nothing.
            if pr.buy > ptas then out = out .. ", you can't afford it" else out = out .. ", hold F to buy" end
            if pr.sell and pr.sell > 0 then out = out .. ". Sells for " .. commas(pr.sell) end
        elseif pr.sell and pr.sell > 0 then
            out = out .. ", sells for " .. commas(pr.sell) .. " pesetas"
        end
    end
    return out
end
M.shop_text = shop_text

-- Merchant tabs and BUY categories (10/22 live-read): InGameShopGuiBehavior
-- (Gui_ui3500) -> InGameShopRootGui -> TabGui._TabListGui CurrFocusType
-- (InGameShopWindowType: Purchase 0 BUY, Custom 1 TUNE UP, Sell 2 SELL,
-- Reward 3 TRADE; names in _WindowTypeNameTable) and PurchaseRootGui.
-- _PurchaseCategoryListGui CurrSelectedCategory (names in InGameShopManager
-- _CategorySettingTable: ALL, STANDARD POWER, HIGH POWER, MISC, CASES, RECIPES,
-- REPURCHASE). The user heard only prices and stat rows and could not find
-- healing or a case. The keys that switch tabs are logged (not known yet).
local TAB_HELP = { [0] = "Weapons, ammo, healing and cases to buy.", [1] = "Upgrade your weapons.",
    [2] = "Pick an item with W and S. Press D to mark one to sell, A to unmark. Then hold F until it sells.",[3] = "Trade spinels for special items." }
local CAT_HELP = { MISC = "healing sprays and other items are usually here", CASES = "bigger attache cases" }
function M.shop_nav_update()
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    -- 10/27 live: findComponents returns nil every other frame while the shop
    -- is open, so the opening tab (TUNE UP) was never said. Keep the last one.
    local arr = sc:call("findComponents(System.Type)", sdk.typeof("chainsaw.InGameShopGuiBehavior"))
    local el = {}
    pcall(function() el = arr:get_elements() end)
    if #el > 0 then M.shop_beh = el[1] end
    if not M.shop_beh then return end
    local root = M.shop_beh:get_field("<InGameShopRootGui>k__BackingField")
    local tl = root:get_field("<TabGui>k__BackingField"):get_field("_TabListGui")
    local tab = tl:get_field("<CurrFocusType>k__BackingField")
    local cl = root:get_field("<PurchaseRootGui>k__BackingField"):get_field("_PurchaseCategoryListGui")
    local cat = cl:get_field("<CurrSelectedCategory>k__BackingField")
    local nav = M.shop_nav or {}
    M.shop_nav = nav
    if not nav.tab_names then
        nav.tab_names, nav.cat_names = {}, {}
        local getm = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
        for _, e in ipairs(tl:get_field("_WindowTypeNameTable"):get_field("_entries"):get_elements()) do
            pcall(function()
                local n = M.clean(getm:call(nil, e:get_field("value")))
                if n ~= "" then nav.tab_names[e:get_field("key")] = n end
            end)
        end
        for _, e in ipairs(sdk.get_managed_singleton("chainsaw.InGameShopManager"):get_field("_CategorySettingTable"):get_field("_entries"):get_elements()) do
            pcall(function()
                local v = e:get_field("value")
                nav.cat_names[e:get_field("key")] = M.clean(getm:call(nil, v:get_field("_MessageId")))
            end)
        end
    end
    local function keys_down()
        local d = {}
        for vk = 0x08, 0xDE do if reframework:is_key_down(vk) then d[#d + 1] = string.format("%02X", vk) end end
        return table.concat(d, " ")
    end
    -- 11/15: "Tab BUY" was cut off at once by the row text ("RECIPES", "Item not unlocked
    -- yet") spoken in the same frame with interrupt; the user never heard BUY. For 2 s after a
    -- tab or category announcement other speech queues behind it instead of cutting it.
    if nav.hold_until and os.clock() > nav.hold_until then RE4Access.speak_hold = nil nav.hold_until = nil end
    if tab ~= nav.tab then
        local name = nav.tab_names[tab] or tostring(tab)
        local list = {}
        for i = 0, 3 do if nav.tab_names[i] then list[#list + 1] = nav.tab_names[i] end end
        RE4Access.speak("Tab " .. name .. ", " .. ((tab or 0) + 1) .. " of " .. #list .. ". " .. (TAB_HELP[tab] or "")
            .. (tab == 0 and cat and cat >= 0 and (" Category " .. tostring(nav.cat_names[cat] or cat) .. ". A and D change the category, W and S the items.") or "")
            .. (nav.tab == nil and (" Tabs: " .. table.concat(list, ", ") .. ". Q and E switch tabs.") or ""), true)
        RE4Access.speak_hold = true
        nav.hold_until = os.clock() + 2
        log.info(string.format("[RE4Access] shop tab %s -> %s keys %s", tostring(nav.tab), tostring(tab), keys_down()))
        nav.tab = tab
    end
    if tab == 0 and cat ~= nav.cat and cat and cat >= 0 then
        local name = nav.cat_names[cat] or tostring(cat)
        RE4Access.speak("Category " .. name .. (CAT_HELP[name] and (", " .. CAT_HELP[name]) or "") .. ".", true)
        RE4Access.speak_hold = true
        nav.hold_until = os.clock() + 1.5
        log.info(string.format("[RE4Access] shop category %s -> %s keys %s", tostring(nav.cat), tostring(cat), keys_down()))
    end
    nav.cat = cat
    -- SELL, 11/1: marking changes only a number on the row, so say the total
    -- (SellItemScrollList: addSellCount, calcTotalPrice, setDecideGauge).
    if tab == 2 then
        local sl = root:get_field("<SellRootGui>k__BackingField"):get_field("<SellListGui>k__BackingField")
        local total = sl:get_field("<CurrTotalPrice>k__BackingField")
        if nav.sell_total and total ~= nav.sell_total and total >= 0 then
            RE4Access.speak(total > 0 and ("Marked to sell, total " .. commas(total) .. " pesetas. Hold F to sell.") or "Nothing marked to sell.", true)
            log.info(string.format("[RE4Access] shop sell total %s -> %s keys %s", tostring(nav.sell_total), tostring(total), keys_down()))
        end
        nav.sell_total = total
    else
        nav.sell_total = nil
    end
    -- money changed in the shop: the sale or purchase went through
    local ptas = sdk.get_managed_singleton("chainsaw.InventoryManager"):call("get_CurrPTAS")
    if nav.ptas and ptas ~= nav.ptas then
        RE4Access.speak((ptas > nav.ptas and "Sold. " or "Paid. ") .. "You have " .. commas(ptas) .. " pesetas.", true)
        log.info(string.format("[RE4Access] shop money %s -> %s keys %s", tostring(nav.ptas), tostring(ptas), keys_down()))
    end
    nav.ptas = ptas
end

-- Options (Gui_ui0400, chainsaw.OptionBehavior), read from the game's own data (10/31 live):
-- SubMenuControl.CurrMenuList = the rows, getSelectedIndex = the real cursor. The screen draws
-- two ScrollLists for its tab animation, one stale, and some values are pictures (languages).
local function element_text(v)
    if v == nil then return "" end
    if type(v) == "string" then return M.clean(v) end
    local s = ""
    pcall(function() s = v:call("ToString") end)
    return M.clean(s)
end
function M.option_value(row)
    local tn = row:get_type_definition():get_full_name()
    if tn:find("Slider", 1, true) then
        return tostring(row:get_field("CurrentStep"))
    end
    local idx
    pcall(function() idx = row:call("get_SelectedIdx") end)
    if idx == nil then return nil end
    local out
    pcall(function()
        local ids = row:call("get_MessageIDs")
        if ids then out = M.clean(m_get:call(nil, ids:get_elements()[idx + 1])) end
    end)
    if not out or out == "" then
        pcall(function()
            local ms = row:call("get_Messages")
            if ms then out = element_text(ms:get_elements()[idx + 1]) end
        end)
    end
    if not out or out == "" then
        pcall(function()
            local ls = row:call("get_MessageLangs")
            if ls then
                local l = ls:get_elements()[idx + 1]
                if type(l) == "userdata" then l = l:get_field("value__") end
                out = language_name(l)
            end
        end)
    end
    return (out ~= "" and out) or nil
end
function M.option_row_text(row)
    local caption = ""
    pcall(function() caption = M.clean(m_get:call(nil, row:call("get_CaptionMsgID"))) end)
    local value = M.option_value(row)
    return caption, value
end
local option_state = {}
-- PC Specifications: CPU, RAM, GPU... The values live in get_Message of m_num; two copies, one empty.
local function pc_info_text(go)
    local gui = go:call("getComponent(System.Type)", sdk.typeof("via.gui.GUI"))
    local out, seen = {}, {}
    local function walk(c, d)
        while c do
            local nm = c:call("get_Name")
            if nm and nm:find("^si_info") then
                local cat, num = "", ""
                local ch = c:call("get_Child")
                while ch do
                    local n2 = ch:call("get_Name")
                    if n2 == "m_category" then cat = text_of(ch)
                    elseif n2 == "m_num" then num = M.clean(ch:call("get_Message")) end
                    ch = ch:call("get_Next")
                end
                if cat ~= "" and num ~= "" and not seen[cat] then
                    seen[cat] = true
                    table.insert(out, 1, cat .. ": " .. num)
                end
            else
                local ch = c:call("get_Child")
                if ch and d < 14 then walk(ch, d + 1) end
            end
            c = c:call("get_Next")
        end
    end
    walk(gui:call("get_View"), 0)
    return table.concat(out, ". ")
end
local function options_update(go)
    local b = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.OptionBehavior"))
    if not b then return false end
    option_state.seen = scan_no
    local sub = b:get_field("<SubMenuControl>k__BackingField")
    local lst = sub:get_field("CurrMenuList")
    local menu_id = sub:get_field("CurrMenu")   -- changes when the rows do; the tab name moves earlier
    local idx = b:call("getSelectedIndex")
    if not lst or not idx or idx < 0 or idx >= lst:call("get_Count") then return true end
    local tab = ""
    pcall(function() tab = describe_item(b:get_field("<MainTabGuiList>k__BackingField"):call("get_SelectedItem")) end)
    local row = lst:call("get_Item", idx)
    local caption, value = M.option_row_text(row)
    if caption == "" and value == nil then return true end
    local pos, total = 0, 0
    for i = 0, lst:call("get_Count") - 1 do
        if lst:call("get_Item", i):call("get_EnableSelect") then
            total = total + 1
            if i <= idx then pos = total end
        end
    end
    local text = caption .. (value and (": " .. value) or "")
    local key = tostring(menu_id) .. "|" .. idx
    -- Camera has several "Normal Gameplay" rows: say the group heading above them when it changes.
    local group
    if row:call("get_IsSubContent") then
        for i = idx - 1, 0, -1 do
            local r2 = lst:call("get_Item", i)
            if not r2:call("get_IsSubContent") then
                group = M.option_row_text(r2)
                break
            end
        end
    end
    if key ~= option_state.key then
        local say = text .. ", " .. pos .. " of " .. total
        if group and group ~= "" and group ~= option_state.group then say = group .. ". " .. say end
        if row:call("get_IsEnable") == false then say = say .. ", not available" end
        if row:get_type_definition():get_full_name():find("Default", 1, true) then say = say .. ". Enter opens it" end
        if menu_id ~= option_state.menu and tab ~= "" then say = tab .. ". " .. say end
        RE4Access.speak(say, true)
        last_item_text = text
        local guide = ""
        pcall(function() guide = M.clean(m_get:call(nil, row:call("get_Detail"):call("get_GuideText"))) end)
        if guide ~= "" and guide ~= last_info then
            RE4Access.speak(guide, false)
            last_info = guide
        end
        option_state.pc_due = row:get_type_definition():get_full_name():find("GraphicsEnvionment", 1, true) and scan_no + 4 or nil
    elseif text ~= option_state.text then
        RE4Access.speak(value or text, true)   -- left or right changed the value
        last_item_text = text
    end
    if option_state.pc_due and scan_no >= option_state.pc_due then
        option_state.pc_due = nil
        local okp, pc = pcall(pc_info_text, go)
        if okp and pc ~= "" then RE4Access.speak(pc, false) end
    end
    option_state.key, option_state.text, option_state.menu, option_state.group = key, text, menu_id, group
    return true
end

local function scan()
    local guis = drawn
    drawn = {}
    scan_no = scan_no + 1
    -- The Options list stays drawn behind the Key Bindings screen; read only the front one.
    local front_keys = false
    for _, go in pairs(guis) do
        pcall(function() if go:call("get_Name") == "Gui_ui0416" then front_keys = true end end)
    end
    -- Photo mode (Gui_ui0700): Shift in the pause menu opens it. After Alt+Tab
    -- the game is paused, so Shift+Backslash there opened it by accident (10/13).
    local photo = false
    for _, go in pairs(guis) do
        pcall(function() if go:call("get_Name") == "Gui_ui0700" then photo = true end end)
    end
    if photo and not M.in_photo then
        RE4Access.speak("Photo mode. You pressed Shift while the game was paused. To leave: press the right mouse button, then W to move up to Yes, then Enter.", true)  -- 10/19: Escape did nothing; Yes is above No
    elseif not photo and M.in_photo then
        RE4Access.speak("Photo mode closed.", true)
    end
    M.in_photo = photo
    -- The map (M key, Gui_ui3100): Leon can't move while it is up (10/18: the
    -- map stayed open unnoticed and every key "did nothing" at the barn ladder).
    local map = false
    for _, go in pairs(guis) do
        pcall(function() if go:call("get_Name") == "Gui_ui3100" then map = true end end)
    end
    if map and not M.in_map then
        -- mapread.lua reads the map (places, objective, typewriter, ways out)
        if RE4Access.mapread then RE4Access.mapread.on_map(true)
        else RE4Access.speak("Map screen open. Leon can't move. Press M to close it.", true) end
    elseif not map and M.in_map then
        if RE4Access.mapread then RE4Access.mapread.on_map(false) end
        RE4Access.speak("Map closed.", true)
    end
    M.in_map = map
    -- Typewriter menu (Gui_ui0620, ArmourySelectGuiBehavior) and the save slots
    -- (Gui_ui0610, SaveLoadMenuGuiBehavior): their lists are drawn as one text,
    -- so the selection was never said (10/22 live: _SelectList SelectedIndex
    -- 0 Save Game, 1 Storage, 2 Customize Case; CurrSelectedIndex with
    -- _CurrSaveSlotDetails[i] IsEmpty).
    local tw_now, slot_now
    for _, go in pairs(guis) do
        local gn = ""
        pcall(function() gn = go:call("get_Name") end)
        if gn == "Gui_ui0620" then
            pcall(function()
                local b = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.ArmourySelectGuiBehavior"))
                tw_now = b:get_field("_SelectList"):call("get_SelectedIndex")
            end)
        elseif gn == "Gui_ui0610" then
            pcall(function()
                local b = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.SaveLoadMenuGuiBehavior"))
                local i = b:get_field("<CurrSelectedIndex>k__BackingField")
                local d = b:get_field("_CurrSaveSlotDetails")
                local empty = d and i < d:call("get_Count") and d:call("get_Item", i):get_field("<IsEmpty>k__BackingField")
                slot_now = { i = i, empty = empty, max = b:get_field("<CurrItemMax>k__BackingField") or 20 }
            end)
        end
    end
    local TW = { [0] = "Save Game", [1] = "Storage", [2] = "Customize Case" }
    if tw_now and tw_now ~= M.tw_idx and not slot_now then
        RE4Access.speak((TW[tw_now] or tostring(tw_now)) .. ", " .. (tw_now + 1) .. " of 3", true)
    end
    M.tw_idx = tw_now
    if slot_now and (not M.slot_idx or slot_now.i ~= M.slot_idx) then
        RE4Access.speak("Slot " .. (slot_now.i + 1) .. " of " .. slot_now.max .. ", "
            .. (slot_now.empty and "empty. Enter saves here." or "has a save. Saving here replaces it."), true)
    end
    M.slot_idx = slot_now and slot_now.i or nil
    -- Title screen (Gui_ui1001, "START GAME"): no list, so it was silent (10/31).
    -- It stays drawn behind the autosave notice (Gui_ui0210), so wait for that to close.
    local title_now, prompt_up = false, false
    for _, go in pairs(guis) do
        local gn = ""
        pcall(function() gn = go:call("get_Name") end)
        if gn == "Gui_ui0210" then prompt_up = true end
        if gn == "Gui_ui1001" then
            pcall(function()
                for _, s in ipairs(visible_texts(go)) do
                    if s == "START GAME" then title_now = true end
                end
                -- other languages: copyright line + the translated START GAME
                if RE4Access.lang and RE4Access.lang.current ~= "English" and #visible_texts(go) >= 2 then title_now = true end
            end)
        end
    end
    if title_now and not prompt_up and not M.at_title then
        M.at_title = true
        RE4Access.speak("Title screen. Press Enter to go to the main menu.", true)
    elseif not title_now then
        M.at_title = false
    end
    -- The game's own quick prompts (11/1 log: Gui_ui2191_3 "Evade" 1 s before a
    -- -14% hit, Gui_ui2191_Grab_3 "Break Free"). Key for Evade is unverified; the
    -- log records which keys were down during each prompt.
    local qte = {}
    for _, go in pairs(guis) do
        pcall(function()
            local gn = go:call("get_Name")
            if gn:find("^Gui_ui2191") then
                for _, s in ipairs(visible_texts(go)) do
                    if s:find("%a") then qte[gn] = s break end
                end
            end
        end)
    end
    M.qte_keys = M.qte_keys or {}
    for gn, s in pairs(qte) do
        if not (M.qte and M.qte[gn] == s) then
            local low = s:lower()
            -- 11/1 log: 0.6 to 1 s from prompt to hit, too short for speech alone
            if low == "evade" and RE4Access.sound then RE4Access.sound("evade") end
            RE4Access.speak(low == "evade" and "Evade! E" or low == "break free" and "Break free! Tap F fast" or (s .. "!"), true)
            log.info("[RE4Access] game prompt: " .. gn .. " " .. s)
        end
        for name, vk in pairs({ E = 0x45, F = 0x46, Space = 0x20, Shift = 0x10, W = 0x57, A = 0x41, S = 0x53, D = 0x44, L = 0x4C, K = 0x4B }) do
            if reframework:is_key_down(vk) and not M.qte_keys[gn .. name] then
                M.qte_keys[gn .. name] = true
                log.info("[RE4Access] game prompt " .. s .. ": key down " .. name)
            end
        end
    end
    for gn in pairs(M.qte or {}) do
        if not qte[gn] then
            log.info("[RE4Access] game prompt ended: " .. gn)
            for k in pairs(M.qte_keys) do if k:sub(1, #gn) == gn then M.qte_keys[k] = nil end end
        end
    end
    M.qte = qte
    -- Diagnostic, log only (10/31, tester: resolution and graphics screens not read):
    -- each screen's visible text once, one screen per scan, to see what the reader misses.
    M.logged_guis = M.logged_guis or {}
    for _, go in pairs(guis) do
        local gn = ""
        pcall(function() gn = go:call("get_Name") end)
        if gn ~= "" and not M.logged_guis[gn] then
            M.logged_guis[gn] = true
            pcall(function()
                local n = 0
                local gui = go:call("getComponent(System.Type)", sdk.typeof("via.gui.GUI"))
                if gui and gui:call("get_View") then n = #find_lists(gui:call("get_View"), {}, 0) end
                log.info("[RE4Access] screen " .. gn .. " lists=" .. n .. " texts: " .. table.concat(visible_texts(go), " | "))
            end)
            break
        end
    end
    -- Back in Options from a screen opened over it: say the row again.
    local sub_open = false
    for _, go in pairs(guis) do
        pcall(function()
            local n = go:call("get_Name")
            if n == "Gui_ui0434" or n == "Gui_ui0410" or n == "Gui_ui0417" then sub_open = true end
        end)
    end
    if M.sub_open and not sub_open then option_state.key = nil end
    M.sub_open = sub_open
    local once_now = {}
    -- Merchant opened: say your money once (10/14).
    local shop_now = false
    for _, go in pairs(guis) do
        local gn = ""
        pcall(function() gn = go:call("get_Name") end)
        if is_shop_gui(go, gn) then shop_now = true end
    end
    pcall(function()
        local ph = sdk.get_managed_singleton("chainsaw.InGameShopManager"):call("get_CurrPhase")
        if ph and ph > 0 then shop_now = true end
    end)
    -- 10/22: neither check above saw the open shop (CurrPhase -1); the shop
    -- GUI behaviour's own phase is Active (2) while it is open, Deactive (6) after.
    if not shop_now then
        pcall(function()
            local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local arr = sc:call("findComponents(System.Type)", sdk.typeof("chainsaw.InGameShopGuiBehavior"))
            local el = arr and arr:get_elements() or {}
            if #el > 0 and el[1]:get_field("<_Phase>k__BackingField") == 2 then shop_now = true end
        end)
    end
    if shop_now and not M.in_shop then
        shop_prices = nil
        RE4Access.speak("Merchant. " .. M.money_text() .. " Press Equals any time to hear your money.", false)
    end
    M.in_shop = shop_now
    if shop_now then
        local okn, en = pcall(M.shop_nav_update)
        if not okn then log.info("[RE4Access] shop nav error: " .. tostring(en)) end
    else
        if M.shop_nav and M.shop_nav.hold_until then RE4Access.speak_hold = nil end
        M.shop_nav = nil
        M.shop_beh = nil
    end
    for _, go in pairs(guis) do
        local gname = ""
        pcall(function() gname = go:call("get_Name") end)
        if READ_ONCE[gname] then pcall(read_once, go, gname, once_now) end
        if front_keys and gname == "Gui_ui0400" then goto next_gui end
        if gname == "Gui_ui0400" then
            local oko, is_opt = pcall(options_update, go)
            if oko and is_opt then goto next_gui end
            if not oko then log.info("[RE4Access] options reader error: " .. tostring(is_opt)) end
        end
        if gname == "Gui_ui3090" then
            local okc, is_c = pcall(combine_update, go)
            if okc and is_c then goto next_gui end
            if not okc then log.info("[RE4Access] combine reader error: " .. tostring(is_c)) end
        end
        local okk, is_kw = pcall(keywin_update, go)
        if okk and is_kw then goto next_gui end
        if not okk then log.info("[RE4Access] key item window error: " .. tostring(is_kw)) end
        local okm, is_cmd = pcall(command_update, go)
        if okm and is_cmd then goto next_gui end
        if not okm then log.info("[RE4Access] command menu error: " .. tostring(is_cmd)) end
        if gname == "Gui_ui3004" then
            local okc, errc = pcall(case_update, go)
            if not okc then log.info("[RE4Access] case reader error: " .. tostring(errc)) end
        end
        if gname == "Gui_ui0416" then
            -- ListModeValue 1 = choosing an action; anything else = waiting for a key.
            pcall(function()
                local kb = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.OptionKeyAssignBehavior"))
                local mode = kb:get_field("ListModeValue")
                if M.key_mode ~= nil and mode ~= M.key_mode then
                    if mode ~= 1 then
                        RE4Access.speak("Press the new key now. Escape cancels.", true)
                    else
                        local okk, kt = pcall(key_binding_text, go)
                        RE4Access.speak("Key set: " .. (okk and kt or ""), true)
                    end
                end
                M.key_mode = mode
            end)
        end
        local ok, err = pcall(function()
            local gui = go:call("getComponent(System.Type)", sdk.typeof("via.gui.GUI"))
            if not gui then return end
            local view = gui:call("get_View")
            if not view then return end
            local lists = find_lists(view, {}, 0)
            if #lists == 0 then return end

            local header
            for _, list in ipairs(lists) do
                local item = list:call("get_SelectedItem")
                if item then
                    local laddr = list:get_address()
                    local st = lists_state[laddr]
                    local text = describe_item(item)
                    if gname == "Gui_ui0434" then
                        pcall(function()
                            local c = item:call("get_Child")
                            while c do
                                if c:call("get_Name") == "m_option" then text = M.clean(c:call("get_Message")) break end
                                c = c:call("get_Next")
                            end
                        end)
                    end
                    if text == "" and not (st and st.item == item:get_address()) then
                        log.info("[RE4Access] silent menu item in " .. gname .. " list " .. tostring(list:call("get_Name")))
                    end
                    local rr = M.readable_recipe(text)
                    if rr then text = rr end
                    if gname == "Gui_ui0416" then
                        local okk, kt = pcall(key_binding_text, go)
                        if okk and kt then text = text .. ": " .. kt end
                    end
                    if M.in_shop then
                        -- the weapon stats panel ("Lv. 2: 5.60: Lv. 1: Increase power.: Power")
                        -- is a list too; it buried the item names (10/22). Not spoken.
                        if text:find("Lv%. %d") then goto next_list end
                        local oks, st2 = pcall(shop_text, text)
                        if oks then text = st2 end
                    end
                    local pv = picture_value(go, item)
                    if pv then text = text .. ": " .. pv end
                    local iaddr = item:get_address()
                    if not st or st.item ~= iaddr then
                        local say = text
                        header = header or header_of(view)
                        -- Yes/No/OK prompts: say the question too, once (10/31: exit
                        -- prompts and the OK screen before the main menu read only the button).
                        local question
                        if text == "Yes" or text == "No" or text == "OK" or gname == "Gui_ui0210" then
                            if scan_no - (M.prompt_seen or -100) > 25 and gname == "Gui_ui0210" and RE4Access.lang and RE4Access.lang.current ~= "English" then
                                -- other languages: the question is the window's first text
                                local first = visible_texts(go)[1]
                                if first and first ~= text then question = (first:gsub("%.$", "")) end
                            elseif scan_no - (M.prompt_seen or -100) > 25 then
                                local parts, seen = {}, {}
                                for _, s in ipairs(visible_texts(go)) do
                                    if s ~= "Yes" and s ~= "No" and s ~= "OK" and s ~= text and not seen[s] then
                                        seen[s] = true
                                        parts[#parts + 1] = s
                                    end
                                end
                                if #parts > 0 then question = (table.concat(parts, ". "):gsub("%.$", "")) end
                                log.info("[RE4Access] prompt " .. gname .. ": " .. tostring(question))
                            end
                        end
                        if question then
                            say = question .. ". " .. text
                        elseif header and header ~= last_header then
                            say = header .. ". " .. text
                            last_header = header
                        end
                        -- Two lists showing the same row in one screen: once is enough.
                        local now = os.clock()
                        local dup = M.said and M.said.list ~= laddr and now - M.said.at < 1.2 and (M.said.text == text or M.said.say == say)
                        if text ~= "" and not dup then
                            RE4Access.speak(say, true)
                            M.said = { list = laddr, text = text, say = say, at = now }
                        end
                        last_item_text = text
                        -- The game updates the description a frame or two later.
                        pending_info = { view = view, due = scan_no + 2, guide = gname == "Gui_ui0434" }
                    elseif text ~= st.text then
                        -- Same option, value changed (left/right).
                        local value = text:match(":%s*(.*)$") or text
                        local now = os.clock()
                        if not (M.said and M.said.list ~= laddr and M.said.text == text and now - M.said.at < 1.2) then
                            RE4Access.speak(value, true)
                            M.said = { list = laddr, text = text, say = value, at = now }
                        end
                        last_item_text = text
                    end
                    -- still on the same prompt: moving from No to Yes does not repeat the question
                    if text == "Yes" or text == "No" or text == "OK" or gname == "Gui_ui0210" then M.prompt_seen = scan_no end
                    lists_state[laddr] = { item = iaddr, text = text, seen = scan_no }
                    ::next_list::
                end
            end
        end)
        if not ok then log.info("[RE4Access] menu scan error: " .. tostring(err)) end
        ::next_gui::
    end
    for k in pairs(read_once_seen) do if not once_now[k] then read_once_seen[k] = nil end end
    -- Case closed: forget the slot, so opening it again reads the current item.
    if case_state.seen ~= scan_no then case_state.key = nil end
    if keywin_state.seen ~= scan_no then keywin_state.key = nil keywin_state.intro = nil keywin_state.want = nil keywin_state.inv = nil end
    if combine_state.seen ~= scan_no then combine_state.item = nil combine_state.sel = nil combine_state.price = nil combine_state.slots = nil end
    if command_state.seen ~= scan_no then command_state.key = nil end
    if option_state.seen ~= scan_no then option_state.key, option_state.menu, option_state.text, option_state.group = nil, nil, nil, nil end
    if pending_info and scan_no >= pending_info.due then
        local pv, want_guide = pending_info.view, pending_info.guide
        pending_info = nil
        INFO_NAMES.m_guide = want_guide or nil
        local ok, info = pcall(info_of, pv)
        INFO_NAMES.m_guide = nil
        if ok and info and info ~= last_info then
            RE4Access.speak(info, false)
            last_info = info
        end
    end
    -- Forget lists that have been gone for a while (about 2 seconds), so a
    -- menu that comes back is announced again.
    if scan_no % 25 == 0 then
        for k, st in pairs(lists_state) do
            if scan_no - st.seen > 25 then lists_state[k] = nil end
        end
    end
end

function M.on_frame()
    scan_tick = scan_tick + 1
    if scan_tick % 4 == 0 then scan() end
end

-- Hooks are registered once; they always call the newest module, so the
-- module can be reloaded while the game runs.
if not RE4Access.menu_hooked then
    RE4Access.menu_hooked = true
    re.on_pre_gui_draw_element(function(el, ctx)
        RE4Access.menu.on_draw(el)
        return true
    end)
    re.on_frame(function() RE4Access.menu.on_frame() end)
end

-- Read the current menu item again (used by a hotkey later).
function M.repeat_current()
    if last_item_text then RE4Access.speak(last_item_text, true) end
end

-- Forget what was spoken so the next scan announces again.
function M.reset()
    lists_state, last_item_text, last_header, last_info = {}, nil, nil, nil
end

RE4Access.menu = M
log.info("[RE4Access] menu reader loaded")
return M
