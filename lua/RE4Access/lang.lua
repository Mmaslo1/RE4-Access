-- RE4 Access: language files. All speech passes through RE4Access.lang.translate.
-- The file is reframework\data\REAccess_lang_<language>.json, named after the game's
-- display language (German, Spanish, Japanese...): { "English sentence": "translation" }.
-- {1} {2} stand for names and numbers and may change order. A missing or empty entry
-- stays English and is noted in REAccess_lang_missing.txt. reframework\data\
-- REAccess_language.txt (one word, such as German) overrides the game's language.

local L = { current = "English" }
local exact, templates, cache, missing = {}, {}, {}, {}
local missing_count, checked_at = 0, -100
local MAX_MISSING = 3000

local function escape(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

-- "{1} meters to {2}" -> anchored Lua pattern; captures come in key order.
local function compile(key, value)
    local pat, pos = {}, 1
    while true do
        local a, b = key:find("{%d+}", pos)
        if not a then break end
        pat[#pat + 1] = escape(key:sub(pos, a - 1)) .. "(.-)"
        pos = b + 1
    end
    pat[#pat + 1] = escape(key:sub(pos))
    return { pat = "^" .. table.concat(pat) .. "$", value = value, key = key, literal = #(key:gsub("{%d+}", "")) }
end

function L.load_table(t)
    exact, templates, cache, missing = {}, {}, {}, {}
    for k, v in pairs(t or {}) do
        if type(v) == "string" and v ~= "" then
            if k:find("{%d+}") then
                -- at least 3 fixed characters, or "{1}, {2}" would swallow everything
                if #(k:gsub("{%d+}", "")) >= 3 then templates[#templates + 1] = compile(k, v) end
            else
                exact[k] = v
            end
        end
    end
    -- most specific first
    table.sort(templates, function(a, b)
        if a.literal ~= b.literal then return a.literal > b.literal end
        return a.key < b.key
    end)
end

local function try_templates(s)
    for _, t in ipairs(templates) do
        local caps = { s:match(t.pat) }
        if caps[1] ~= nil then
            return (t.value:gsub("{(%d+)}", function(n)
                local c = caps[tonumber(n)] or ""
                return exact[c] or c   -- names the mod itself says ("Door") are translated too
            end))
        end
    end
end

local function translate_piece(s)
    return exact[s] or try_templates(s)
end

local function note_missing(s)
    -- only English-looking text; game text in another language is already right
    if missing[s] or missing_count >= MAX_MISSING or not s:find("%a%a") or s:find("[\128-\255]") then return end
    missing[s] = true
    missing_count = missing_count + 1
    local lines = {}
    for k in pairs(missing) do lines[#lines + 1] = k end
    table.sort(lines)
    pcall(function() fs.write("REAccess_lang_missing.txt", table.concat(lines, "\n") .. "\n") end)
end

function L.translate_text(text)
    local hit = cache[text]
    if hit then return hit end
    local out = translate_piece(text)
    if not out then
        -- Long lines are built from sentences: translate each one alone.
        local parts, rest = {}, text
        while true do
            local a, b = rest:find("[%.!%?]%s+")
            if not a then parts[#parts + 1] = rest break end
            parts[#parts + 1] = rest:sub(1, a)
            rest = rest:sub(b + 1)
        end
        for i, p in ipairs(parts) do
            local t = translate_piece(p)
            if t then
                parts[i] = t
            else
                local bare, stop = p:match("^(.-)([%.!%?])$")
                t = bare and translate_piece(bare)
                if t then parts[i] = t .. stop else note_missing(p) end
            end
        end
        out = table.concat(parts, " ")
    end
    cache[text] = out
    return out
end

local function language_names()
    local names = {}
    for _, f in ipairs(sdk.find_type_definition("via.Language"):get_fields()) do
        if f:is_static() then
            pcall(function()
                local v = f:get_data(nil)
                if type(v) == "number" then names[v] = f:get_name() end
            end)
        end
    end
    return names
end

local function game_language()
    local forced = (fs.read("REAccess_language.txt") or ""):gsub("%s+", "")
    if forced ~= "" then return forced end
    local name
    pcall(function()
        L.names = L.names or language_names()
        local v = sdk.call_native_func(sdk.get_native_singleton("via.gui.GUISystem"), sdk.find_type_definition("via.gui.GUISystem"), "get_MessageLanguage")
        name = L.names[v]
    end)
    return name
end

function L.check_language()
    local lang = game_language()
    if not lang or lang == L.current then return end
    L.current = lang
    if lang == "English" then
        L.load_table({})
    else
        local data
        pcall(function() data = json.load_file("REAccess_lang_" .. lang .. ".json") end)
        L.load_table(data)
        log.info("[RE4Access] language " .. lang .. ": " .. (data and "file loaded" or "no file, staying in English"))
    end
end

function L.translate(text)
    if type(text) ~= "string" or text == "" or text:sub(1, 1) == "#" then return text end
    local now = os.clock()
    if now - checked_at > 3 then
        checked_at = now
        pcall(L.check_language)
    end
    if L.current == "English" then return text end
    local ok, out = pcall(L.translate_text, text)
    return ok and out or text
end

return L
