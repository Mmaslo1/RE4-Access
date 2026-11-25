-- RE4 Access: gameplay helpers.
--   State announcements: cutscene, you have control, merchant, game over, paused.
--   H            where am I: facing direction (and state)
--   [ / ]        previous / next nearby thing (closest first)
--   Backslash    turn the camera to face the selected thing (then walk with W)
--   Shift+Backslash  route on/off: find a walking way to the selected thing;
--                the camera keeps turning along it while you hold W
--   Semicolon    next category (Shift+Semicolon previous): everything, doors, buildings,
--                enemies, people and places, animals, other
--   B            trail back on/off: walk back the way you came (hold W)
--   Apostrophe   enemies: how many nearby and where the closest is
--   Y            repeat the last thing spoken
--   J            route status: how far to go and how far off the path you are
--   O            current objective
--   N            next: pick the next story step and walk there (route starts by itself)
--   U            your health
--   L (game key, aim): while held, the aim stays locked on the nearest enemy you
--                can see (upper chest); K then shoots it.
--   Combat speech: "On target", "Hit", "Enemy down", "Hurt, health 60 percent",
--   "You died".
--   Close to an item, door or document: "... in reach, press F".
-- Keys only work while the game window has focus.

local G = {}

local VK = { SLASH = 0xBF, X = 0x58, PERIOD = 0xBE, H = 0x48, Y = 0x59, LBRACKET = 0xDB, RBRACKET = 0xDD, BACKSLASH = 0xDC, QUOTE = 0xDE, SEMICOLON = 0xBA, B = 0x42, J = 0x4A, O = 0x4F, N = 0x4E, U = 0x55, L = 0x4C, SPACE = 0x20, SHIFT = 0x10, COMMA = 0xBC, EQUALS = 0xBB, F1 = 0x70, F2 = 0x71, F3 = 0x72, F4 = 0x73, F5 = 0x74, F6 = 0x75, F7 = 0x76, F8 = 0x77 }
local NEARBY_RANGE = 60      -- metres (Everything list)
local FAR_RANGE = 300        -- metres (single categories like Doors)
local YAW_SIGN = 1           -- live-verified 10/11: _Yaw (radians) == compass heading; never flipped

local function say(text, interrupt)
    if interrupt == nil then interrupt = true end
    -- 11/1: "Locked, keep holding L" talked over "Fire! Let go of L" until death
    local gg = RE4Access.game
    if gg and gg.fire_until and os.clock() < gg.fire_until and type(text) == "string"
        and not text:find("^Fire!") and not text:find("^You died") then return end
    -- 11/1: "1 enemy" kept repeating on the death screen
    if gg and gg.is_dead and type(text) == "string" and (text:find("^%d+ enem") or text:find("^Enemy,") or text:find("^Enemy close")) then return end
    -- 11/1: the boss fight had to compete with this chatter
    if gg and gg.in_boss and type(text) == "string" and (text:find("^No enemy in sight") or text:find("^Gun up") or text:find("^Gun down")
        or text:find("^Can't aim") or text:find("meters to go$") or text:find("^Dropped")
        or text:find("^Picked up") or (text:find("^F ready") and not text:find("kick"))
        or text:find("^F is ") or text:find("^Finding the F")) then return end
    RE4Access.speak(text, interrupt)
end

-- Your own keys (0.23.0): reframework\data\REAccess_keys.txt, lines like "health = H".
-- No file = the normal keys. Action names are in REAccess_keys_example.txt.
function G.load_keys(text, vk)
    local ACTIONS = { facing = "H", ["repeat"] = "Y", next_thing = "RBRACKET", previous_thing = "LBRACKET", walk = "BACKSLASH",
        fight_advice = "QUOTE", list = "SEMICOLON", trail_back = "B", route_status = "J", objective = "O", next_step = "N",
        health = "U", gun = "X", money = "EQUALS", items = "COMMA", next_turn = "PERIOD", short_messages = "SLASH" }
    local NAMES = { ["["] = 0xDB, ["]"] = 0xDD, ["\\"] = 0xDC, ["'"] = 0xDE, [";"] = 0xBA, [","] = 0xBC, ["."] = 0xBE, ["/"] = 0xBF, ["="] = 0xBB, ["-"] = 0xBD, ["`"] = 0xC0 }
    local changes, used = {}, {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local act, key = line:match("^%s*([%a_]+)%s*=%s*(%S+)%s*$")
        if act then
            local field = ACTIONS[act:lower()]
            local k = key:upper()
            local code = NAMES[key]
            if not code and k:match("^[A-Z0-9]$") then code = k:byte() end
            local fn = k:match("^F(%d+)$")
            if not code and fn and tonumber(fn) >= 9 and tonumber(fn) <= 12 then code = 0x6F + tonumber(fn) end
            if field and code then
                changes[field] = code
                if used[code] then log.info("[RE4Access] keys file: " .. key .. " used twice") end
                used[code] = true
            else
                log.info("[RE4Access] keys file: did not understand: " .. line)
            end
        end
    end
    for field, code in pairs(changes) do vk[field] = code end
end
pcall(function() G.load_keys(fs.read("REAccess_keys.txt"), VK) end)

local function tn(o)
    local ok, n = pcall(function() return o:get_type_definition():get_full_name() end)
    return ok and n or ""
end

-- ---------------- game objects ----------------

local app_t = sdk.find_type_definition("via.Application")
local function has_focus()
    local ok, v = pcall(function() return sdk.call_native_func(sdk.get_native_singleton("via.Application"), app_t, "get_HasFocus") end)
    return ok and v
end

local function player_ctx()
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    return cm and cm:call("getPlayerContextRef")
end

function G.player_pos()
    local ctx = player_ctx()
    if not ctx then return nil end
    return ctx:call("get_Position")
end

local function main_camera_controller()
    local cs = sdk.get_managed_singleton("chainsaw.CameraSystem")
    return cs and cs:call("get_MainCameraController")
end

local function player_camera()
    local mc = main_camera_controller()
    if not mc then return nil end
    return mc:get_field("_CameraControllerArray"):get_elements()[1]
end

-- Heading in degrees: 0 = north (+Z), 90 = east (+X).
local function heading_of(dx, dz)
    return (math.deg(math.atan(dx, dz)) + 360) % 360
end

-- Direction the camera looks (= the direction W walks).
function G.facing()
    local mc = main_camera_controller()
    local pos = G.player_pos()
    if not mc or not pos then return nil end
    local cam = mc:call("get_CameraPosition")
    local dx, dz = pos.x - cam.x, pos.z - cam.z
    if math.abs(dx) + math.abs(dz) < 0.01 then return nil end
    return heading_of(dx, dz)
end

local COMPASS = { "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west" }
local function compass(h)
    return COMPASS[math.floor(((h + 22.5) % 360) / 45) + 1]
end

local function relative(rel)
    rel = (rel + 540) % 360 - 180          -- -180..180, + = right
    local a = math.abs(rel)
    -- Higher heading is to the LEFT on screen (10/19: the camera right vector is
    -- heading - 90, and D in the boat lowered the heading). Was mirrored.
    local side = rel > 0 and "left" or "right"
    if a < 15 then return "ahead"
    elseif a < 60 then return "ahead " .. side
    elseif a < 120 then return side
    elseif a < 165 then return "behind " .. side
    else return "behind" end
end

local function describe_position(target, pos, facing)
    local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local s = string.format("%d meters", math.floor(dist + 0.5))
    if facing then s = s .. ", " .. relative(heading_of(dx, dz) - facing) end
    if dy > 2 then s = s .. ", above" elseif dy < -2 then s = s .. ", below" end
    return s, dist
end

-- ---------------- nearby things ----------------

-- Gimmick component -> spoken name. Components not listed and not in SKIP
-- are named from their class name (GmFooBar -> "Foo Bar").
local NAMES = {
    GmBigDoorLock = "Gate latch",   -- bar on a wooden gate, lifted with F (10/18)
    GmFallShutter = "Log gate",
    GmSiegeBarricade = "Window barricade", GmLeaningLadder = "Ladder against the house", -- Luis's house siege (10/22)
    GmFallenShelf = "Fallen shelf", -- push it over with F: a shortcut (behind the church, 10/18)
    GmDoor = "Door", GmMotionDoor = "Door", GmNpcMotionDoor = "Door", GmDoorBrokenChainsaw = "Door", GmLadder = "Ladder", GmWeaponMerchant = "Merchant",
    GmTypewriter = "Typewriter", GmViewPoint = "Lookout point", GmWindow = "Window",
    GmDrawer = "Drawer", GmTreasureBox = "Treasure chest", GmWoodBox = "Breakable crate",
    GmBarrel = "Barrel", GmCrow = "Crow", GmReadFile = "Document", GmFloorBoard = "Trapdoor", GmUprightLadder = "Ladder", GmPowerUnitLever = "Lever",
    GmHoldHandle = "Crank, hold F to turn it", GmMultiModify = "Machine slot", GmShutter = "Shutter", GmPushMove = "Cart, push it", GmSensorBomb = "Bomb trap", GmPadlock = "Padlock", GmBigDoor = "Gate", GmKeepBigDoor = "Gate", GmSavePoint = "Typewriter, save game", GmLegHoldTrap = "Bear trap",
}
local SKIP = {
    GmMiniDemo = true, GmCamera1Shot = true, GmWindActivator = true, GmAlwaysRigid = true,
    GmPortrayal = true, GmOptionSleep = true, GmWeaponMerchantLookAt = true, GmWeaponUpgrade = true, GmDummyDoor = true, GmWallUnseen = true, GmCamera1Shot = true,
}

local function split_camel(s)
    return (s:gsub("(%l)(%u)", "%1 %2"))
end

-- Small story animations (Y_...) are placed along the path the game wants you to
-- walk, so they make good "path points". Named from keywords in their Japanese names.
local PATH_WORDS = {
    { "両手枝払い", "Branches" }, { "鉄扉", "Fallen iron gate" }, { "鹿の死体", "Dead deer" },
    { "焚火", "Campfire" }, { "家に入る", "House entrance" }, { "遠く見", "Look out" },
    { "1stHut", "near first hut" }, { "スタート近く", "near start" },
    { "誰もいない", "Empty room" }, { "暖炉", "Fireplace, ammo" }, { "家の奥に扉", "Back door of house" },
    { "橋", "Bridge" }, { "犬の死体", "Dead dog" }, { "地獄門", "Village gate" },
}
-- "LevelKey_..." objects start story events (cutscenes, radio calls): the best
-- marker of where the story goes next.
local EVENT_WORDS = {
    { "地下", "basement" }, { "ハニガン", "radio call" }, { "暖炉", "fireplace" }, { "遭遇", "encounter" },
}
local function path_point_name(n)
    if n:sub(1, 9) == "LevelKey_" then
        local parts = {}
        for _, w in ipairs(EVENT_WORDS) do
            if n:find(w[1], 1, true) then parts[#parts + 1] = w[2] end
        end
        return "Path point, Story event" .. (#parts > 0 and (", " .. table.concat(parts, " ")) or "")
    end
    if n:sub(1, 2) ~= "Y_" then return nil end
    local parts = {}
    for _, w in ipairs(PATH_WORDS) do
        if n:find(w[1], 1, true) then parts[#parts + 1] = w[2] end
    end
    return "Path point" .. (#parts > 0 and (", " .. table.concat(parts, " ")) or "")
end

local function classify(go)
    local pp = path_point_name(go:call("get_Name"))
    if pp then return pp end
    if go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmVillageShrine")) then return "Wayshrine" end
    local comps = go:call("get_Components")
    local fallback
    for i = 0, comps:call("get_Count") - 1 do
        local n = tn(comps:call("get_Item", i)):match("^chainsaw%.(Gm%w+)$")
        if n and not SKIP[n] then
            if NAMES[n] then return NAMES[n] end
            fallback = fallback or split_camel(n:sub(3))
        end
    end
    return fallback
end

local name_cache = {}   -- game object address -> name or false
local visited = {}      -- path points Leon has walked past (address -> true)
G.visited = visited

local function scan_things(pos, range)
    range = range or NEARBY_RANGE
    local out = {}
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    if not gm then return out end
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then
            pcall(function()
                local go = core:call("get_GameObject")
                if not go or not go:call("get_DrawSelf") then return end
                local addr = go:get_address()
                local name = name_cache[addr]
                if name == nil then
                    name = classify(go) or false
                    name_cache[addr] = name
                end
                if not name then return end
                -- A kicked/broken padlock stays in the scene with durability 2 but its
                -- context says done (10/12 PM: L kept aiming at the boathouse padlock
                -- after the user had kicked the door open).
                if name == "Padlock" and core:call("get_Context"):call("hasDoneForMap") then return end
                -- 11/2: a smashed pot stayed listed; Backslash searched for an F it can never have
                if name == "Smooth Wood Box" and core:call("get_Context"):call("hasDoneForMap") then return end
                -- A freed dog: GmDogCaughtInTrap RoutineType 3 AfterRun / 4 AfterEvent / 5 Sleep
                -- (10/18: still listed after the user freed it on 10/17; live _Routine 4).
                if name == "Dog Caught In Trap" then
                    local okr, r = pcall(function() return go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmDogCaughtInTrap")):get_field("_Routine") end)
                    if okr and r and r >= 3 then return end
                end
                local p = go:call("get_Transform"):call("get_Position")
                -- The dog's F area (1 m) is round the trap on its leg, not the dog
                -- (10/17: F did nothing 2.4 m from the trap, next to the dog).
                if name == "Dog Caught In Trap" then
                    pcall(function()
                        local gm = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmDogCaughtInTrap"))
                        p = gm:get_field("_ObjTrap"):call("get_Transform"):call("get_Position")
                    end)
                end
                -- A document's F works only when the camera points at its icon
                -- (10/18 Lakeside Map: pinned on the wall 1.4 m above and 0.9 m
                -- from the object origin; turned toward the origin, F never came).
                -- Binoculars the same (10/19 lake lookout: F area r 1.0 is 1.1 m in
                -- front of the origin and F needs Leon facing the lake, toward the icon).
                local spot_thing = name == "Document" or name == "Lookout point"
                if spot_thing then
                    G.doc_icon = G.doc_icon or {}
                    G.doc_sensor = G.doc_sensor or {}
                    local ic = G.doc_icon[addr]
                    if ic == nil then
                        ic = false
                        -- the F area: the smallest layer-7 sphere (r 1.0 for the map)
                        pcall(function()
                            local cols = go:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
                            for ci = 0, cols:call("get_NumColliders") - 1 do
                                local sp = cols:call("getColliders", ci):call("get_TransformedShape"):call("get_Sphere")
                                if sp and (not G.doc_sensor[addr] or sp.r < G.doc_sensor[addr].r) then
                                    G.doc_sensor[addr] = { x = sp.pos.x, y = sp.pos.y, z = sp.pos.z, r = sp.r }
                                end
                            end
                        end)
                        pcall(function()
                            local ih = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InteractHolder"))
                            for _, tc in ipairs(ih:get_field("_Triggers"):get_elements()) do
                                local ip = tc:get_field("_Trigger"):get_field("_ObjIconPos")
                                if ip then local q = ip:call("get_Position") ic = { x = q.x, y = q.y, z = q.z } break end
                            end
                        end)
                        G.doc_icon[addr] = ic
                    end
                end
                local face_pt = spot_thing and G.doc_icon[addr] or nil
                local dx, dz = p.x - pos.x, p.z - pos.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d <= range then
                    out[#out + 1] = { name = name, pos = p, dist = d, key = addr, go = go, face = face_pt or nil, sensor = spot_thing and G.doc_sensor and G.doc_sensor[addr] or nil }
                end
            end)
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

local function enemies(pos, range)
    range = range or NEARBY_RANGE
    local out = {}
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    if not cm then return out end
    local list = cm:call("get_EnemyContextList")
    if not list then return out end
    for i = 0, list:call("get_Count") - 1 do
        pcall(function()
            local ctx = list:call("get_Item", i)
            local live = true
            pcall(function() live = ctx:call("get_HitPoint"):call("get_IsLive") end)
            if live == false then return end
            -- Crows (Ch8g2z0, 1 HP) are no danger (10/19: "1 enemy, Close" for a bird in the tunnel).
            if ctx:get_type_definition():get_name():find("^Ch8g") then return end
            -- 11/9 Ch8 storeroom: sleeping armor suits (Ch1d6z0, unaware, full HP)
            -- gave "Close" warnings as the user walked past them to the save.
            if ctx:get_type_definition():get_name():find("^Ch1d6") and (ctx:get_field("<TargetFindState>k__BackingField") or 0) == 0 then
                local hp = ctx:call("get_HitPoint")
                if hp:call("get_CurrentHitPoint") >= hp:call("get_DefaultHitPoint") then return end
            end
            -- Enemy contexts have no GameObject here; their position comes straight from the context.
            local p = ctx:call("get_Position")
            if not p then return end
            p = { x = p.x, y = p.y, z = p.z }
            local dx, dz = p.x - pos.x, p.z - pos.z
            local d = math.sqrt(dx * dx + dz * dz)
            if d <= range then out[#out + 1] = { name = "Enemy", pos = p, dist = d, key = ctx:get_address(), ctx = ctx } end
        end)
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- Pickups lying in the world (chainsaw.DropItemManager), with their English names.
local msg_get = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
local CONTAINER_WORDS = { { "木箱", "in a crate" }, { "樽", "in a barrel" }, { "たる", "in a barrel" },
    { "ケース", "in a case" }, { "ひきだし", "in a drawer" }, { "引き出し", "in a drawer" }, { "戸棚", "in a cupboard" },
    { "宝箱", "in a chest" }, { "チェスト", "in a chest" }, { "机", "in a desk" }, { "ほこら", "in a shrine" }, { "祠", "in a shrine" }, { "鳥の巣", "in a bird's nest" } }
-- Containers opened with F (the rest are broken with the knife).
local OPEN_WITH_F = { drawer = true, cupboard = true, chest = true, desk = true, case = true, shrine = true }
local FALLBACK_NAMES = { { "イエローハーブ", "Yellow Herb" }, { "レッドハーブ", "Red Herb" }, { "グリーンハーブ", "Green Herb" },
    { "ハーブ", "Green Herb" }, { "スプレー", "First Aid Spray" }, { "卵", "Egg" }, { "魚", "Fish" },
    { "ハンドガンの弾", "Handgun Ammo" }, { "ショットガンの弾", "Shotgun Shells" }, { "ライフルの弾", "Rifle Ammo" },
    { "火薬", "Gunpowder" }, { "素材", "Resources" }, { "ナイフ", "Knife" }, { "手榴弾", "Grenade" }, { "ペセタ", "Pesetas" } }
local item_name_cache = {}
local function item_name(di, go)
    local addr = di:get_address()
    if item_name_cache[addr] then return item_name_cache[addr] end
    local sd = di:get_field("_ItemData")
    local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
    local name = RE4Access.menu.clean(msg_get:call(nil, mm:call("getItemNameMsgId", sd:get_field("ItemID"))))
    local lost_count
    if name == "" then
        -- enemy drops keep the item in _Item (10/27)
        pcall(function()
            local it = di:get_field("_Item")
            name = RE4Access.menu.clean(msg_get:call(nil, mm:call("getItemNameMsgId", it:get_field("_ItemId"))))
            lost_count = it:get_field("_CurrentItemCount")
        end)
        name = name or ""
    end
    if name == "" then
        -- Some items have no English name text (10/13: herb in a crate in the
        -- Chapter 2 factory read as "Item"); fall back to the object's Japanese name.
        local gn = go:call("get_Name") or ""
        for _, w in ipairs(FALLBACK_NAMES) do
            if gn:find(w[1], 1, true) then name = w[2] break end
        end
        if name == "" then name = "Item" end
    end
    local count = lost_count or sd:get_field("Count")
    if count and count > 1 then name = name .. ", " .. count end
    local gname = go:call("get_Name")
    for _, w in ipairs(CONTAINER_WORDS) do
        if gname:find(w[1], 1, true) then name = name .. ", " .. w[2] break end
    end
    item_name_cache[addr] = name
    return name
end

-- Items inside containers: which crate/barrel holds them
-- (DropItemManager._ConnectedGmToItem, gimmick code -> item codes) and whether
-- that crate still exists. An item "inside" a crate that is gone can't be
-- reached (seen 10/11: Pesetas stuck with no crate), so it is left out.
local cont = { at = -10, item_to_gm = {}, gms = {} }
local function refresh_containers()
    local now = os.clock()
    if now - cont.at < 2 then return end
    cont.at = now
    cont.item_to_gm, cont.gms = {}, {}
    pcall(function()
        local dm = sdk.get_managed_singleton("chainsaw.DropItemManager")
        for _, e in ipairs(dm:get_field("_ConnectedGmToItem"):get_field("_entries"):get_elements()) do
            local k, lst = e:get_field("key"), e:get_field("value")
            if lst then
                for i = 0, lst:call("get_Count") - 1 do cont.item_to_gm[lst:call("get_Item", i)] = k end
            end
        end
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do cont.gms[e:get_field("key")] = e:get_field("value") or true end
    end)
end
-- Item kept in a slot gimmick that needs a key item Leon doesn't have (10/12:
-- Antique Pipe in the wayshrine needs the Old Wayshrine Key): name of the key.
local function container_needs(item_key)
    local g = cont.item_to_gm[item_key]
    local core = g and cont.gms[g]
    if type(core) ~= "userdata" then return nil end
    -- Locked drawers and lockers with a keyhole (gm84_701 "鍵のかかった...") take a
    -- Small Key (10/13: Elegant Mask in the factory gear room).
    local okn, gn = pcall(function() return core:call("get_GameObject"):call("get_Name") end)
    if okn and gn and gn:find("鍵のかかった", 1, true) then
        local done = false
        pcall(function() done = core:call("get_Context"):call("hasDoneForMap") end)
        if not done then return "Small Key" end
    end
    local need, _, have = G.slot_need(core:call("get_GameObject"))
    if need and not have then return need end
end
-- true when the item (key = its GameObject address) has left its nest,
-- false while it still sleeps inside (DropItem _Routine 3), nil if unknown.
function G.nest_down(go_key)
    local res
    pcall(function()
        local dm = sdk.get_managed_singleton("chainsaw.DropItemManager")
        res = true   -- gone from the list = picked up / fell
        for _, e in ipairs(dm:get_field("_DropItem"):get_field("_entries"):get_elements()) do
            local di = e:get_field("value")
            if di and di:call("get_GameObject"):get_address() == go_key then
                res = di:get_field("_Routine") ~= 3
                break
            end
        end
    end)
    return res
end
-- Item held by a shoot-down object (chainsaw.GmShootObj, 10/17: Sapphire 6 m up
-- over the path past the Chief's house; the mod said "break the box"): where to shoot.
function G.container_shoot_pos(item_key)
    local g = cont.item_to_gm[item_key]
    local core = g and cont.gms[g]
    if type(core) ~= "userdata" then return nil end
    local q
    pcall(function()
        local go = core:call("get_GameObject")
        if go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmShootObj")) then
            local t = go:call("get_Transform"):call("get_Position")
            q = { x = t.x, y = t.y, z = t.z, what = "nest" }
            -- The part a bullet must hit hangs below the object's origin (10/17: the
            -- Sapphire nest's BreakObj capsule is 0.46 m lower; 5 shots went over it).
            local ch = go:call("get_Transform"):call("get_Child")
            while ch do
                local okc = pcall(function()
                    local cs = ch:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
                    local sh = cs:call("getColliders", 0):call("get_TransformedShape")
                    local a, b = sh:call("get_PosA"), sh:call("get_PosB")
                    q = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2, what = "nest" }
                end)
                if okc then break end
                ch = ch:call("get_Next")
            end
        else
            -- The well by the Chief's manor (GmCesspoolLid gm84_512, 10/17): the
            -- pendant is in the lantern ("Cage") over the well; a "Stick" holds the
            -- well lid open. Shoot the stick first (lid shuts), then the lantern: the
            -- pendant lands on the lid clean. Lantern first = it falls in, dirty.
            if not go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCesspoolLid")) then return end
            local stick_up, cage
            local ch = go:call("get_Transform"):call("get_Child")
            while ch do
                local cg = ch:call("get_GameObject")
                local nm = cg:call("get_Name")
                if nm == "Stick" then
                    local cs = cg:call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
                    if cs and cs:call("get_NumColliders") > 0 then
                        local t = ch:call("get_Position")
                        stick_up = { x = t.x, y = t.y, z = t.z, what = "stick" }
                    end
                elseif nm == "Cage" then
                    local t = ch:call("get_Position")
                    cage = { x = t.x, y = t.y, z = t.z, what = "lantern" }
                    -- the lantern body (child capsule) hangs ~0.5 m below the hook
                    local c2 = ch:call("get_Child")
                    while c2 do
                        if pcall(function()
                            local cs = c2:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("via.physics.Colliders"))
                            local sh = cs:call("getColliders", 0):call("get_TransformedShape")
                            local a, b = sh:call("get_PosA"), sh:call("get_PosB")
                            cage = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2, what = "lantern" }
                        end) then break end
                        c2 = c2:call("get_Next")
                    end
                end
                ch = ch:call("get_Next")
            end
            q = stick_up or cage
        end
    end)
    return q
end
-- Containers opened by HOLDING F (InteractTriggerKey KeyHoldDownSec > 0; 10/17:
-- outhouse toilet lid GmCesspoolLid with the Dirty Pearl Pendant, user tapped F).
-- Returns a word for it, or nil.
function G.container_hold(item_key)
    local g = cont.item_to_gm[item_key]
    local core = g and cont.gms[g]
    if type(core) ~= "userdata" then return nil end
    local word
    pcall(function()
        local go = core:call("get_GameObject")
        if not G.hold_f(go) then return end
        word = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCesspoolLid")) and "toilet" or "lid"
    end)
    return word
end
-- True when this object's F prompt must be held down, not tapped.
function G.hold_f(go)
    local held = false
    pcall(function()
        local ih = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InteractHolder"))
        local arr = ih:get_field("_TrgAct")
        for i = 0, arr:call("get_Length") - 1 do
            local sec = arr:call("GetValue", i):get_field("<KeyHoldDownSec>k__BackingField")
            if sec and sec > 0 then held = true end
        end
    end)
    return held
end
local function container_gone(item_key)
    local g = cont.item_to_gm[item_key]
    return g ~= nil and not cont.gms[g]
end

local function items(pos, range)
    range = range or NEARBY_RANGE
    local out = {}
    local dm = sdk.get_managed_singleton("chainsaw.DropItemManager")
    if not dm then return out end
    refresh_containers()
    -- Enemy drops ("LostItem_...", _IsLostItem) are not in the manager's list
    -- (10/27: the Checkpoint Crank from the Chainsaw Sisters, plus money, a
    -- Sapphire, an Emerald and herbs were never listed). Scene scan, 1 s cache.
    local entries = {}
    for _, e in ipairs(dm:get_field("_DropItem"):get_field("_entries"):get_elements()) do
        entries[#entries + 1] = { di = e:get_field("value"), key = e:get_field("key") }
    end
    G.lost_cache = G.lost_cache or { at = -10, list = {} }
    if os.clock() - G.lost_cache.at > 1 then
        G.lost_cache.at, G.lost_cache.list = os.clock(), {}
        pcall(function()
            local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            for _, di in ipairs(sc:call("findComponents(System.Type)", sdk.typeof("chainsaw.DropItem")):get_elements()) do
                if di:get_field("_IsLostItem") then G.lost_cache.list[#G.lost_cache.list + 1] = di end
            end
        end)
    end
    for _, di in ipairs(G.lost_cache.list) do entries[#entries + 1] = { di = di, key = -1 } end
    for _, ent in ipairs(entries) do
        local di = ent.di
        local ikey = ent.key
        if di then
            pcall(function()
                -- chainsaw.DropItem.RoutineType: 7 Disappear (picked up), 8 SystemDisappear,
                -- 11 WaitDLC, 12 Error -> not really there.
                local r = di:get_field("_Routine")
                if r == 7 or r == 8 or r == 11 or r == 12 then return end
                if r == 3 and container_gone(ikey) then return end
                local go = di:call("get_GameObject")
                -- hidden stand-ins (10/27: 関所門の鍵(仮), the crank "in the house",
                -- invisible after the story scene; F did nothing on it)
                if r ~= 3 and not go:call("get_DrawSelf") then return end
                local p = go:call("get_Transform"):call("get_Position")
                local dx, dz = p.x - pos.x, p.z - pos.z
                local d = math.sqrt(dx * dx + dz * dz)
                if d <= range then
                    -- RoutineType 3 Sleep = still inside an unbroken crate or barrel.
                    local needs = container_needs(ikey)
                    local nm = item_name(di, go)
                    if needs then nm = nm .. ", locked, needs the " .. needs end
                    local shoot = r == 3 and G.container_shoot_pos(ikey)
                    if shoot and shoot.what == "stick" then nm = nm .. ", in the lantern over the well. First shoot the stick holding the well lid open"
                    elseif shoot and shoot.what == "lantern" then nm = nm .. ", in the lantern over the well. The lid is shut: shoot the lantern now"
                    elseif shoot and not nm:find("bird's nest", 1, true) then nm = nm .. ", in a bird's nest" end
                    if G.near_laser and G.near_laser(p) then nm = nm .. ", next to a tripwire bomb, shoot the bomb first" end
                    if G.near_bear_trap and G.near_bear_trap(p) then nm = nm .. ", next to a bear trap, walk in slowly" end
                    out[#out + 1] = { name = nm, pos = p, dist = d, key = go:get_address(), item = true, go = go, inside = (r == 3), locked = needs, shoot = shoot or nil, hold = r == 3 and not shoot and G.container_hold(ikey) or nil }
                end
            end)
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end
G.items = items

local selected   -- { key =, name =, pos = }
function G.set_selected(t) selected = t end   -- dev channel / tests
local walk = { last_pos = nil, still_since = nil, blocked_said = false, last_dist_said = nil }

-- Categories, switched with Semicolon (next) and Shift+Semicolon (previous).
local CATEGORIES = {
    { name = "Everything" },
    { name = "Path points", prefix = "Path point" },
    { name = "Items", items = true },
    -- 10/19 user: "a category for money, I found a lot of money but by accident".
    { name = "Money", items = true, money = true },
    { name = "Doors and ladders", match = { Door = true, Gate = true, Ladder = true } },
    { name = "Enemies", enemies = true },
    { name = "Buildings", buildings = true },
    { name = "Inside this building", inside = true },
    { name = "People and places", match = { Boat = true, Merchant = true, Typewriter = true, ["Typewriter, save game"] = true, ["Lookout point"] = true, Document = true } },
    { name = "Traps", match = { ["Bear trap"] = true, ["Bomb trap"] = true } },
    { name = "Puzzles", match = { ["Crank, hold F to turn it"] = true, Wayshrine = true, Lever = true, ["Machine slot"] = true, Shutter = true, ["Cart, push it"] = true, Trapdoor = true, ["Puzzle Crystal Ball"] = true, ["Dial Lock"] = true } },
    { name = "Animals", match = { Crow = true, ["Dog Caught In Trap"] = true } },
    { name = "Breakables", match = { ["Breakable crate"] = true } },
    { name = "Other", other = true },
}
local cat_index = 1
local KNOWN = {}
for _, c in ipairs(CATEGORIES) do
    if c.match then for k in pairs(c.match) do KNOWN[k] = true end end
end

-- 11/11 user: "the typewriter and merchant don't show up in my list": the game unloads
-- them when you are a room or two away. Merchants and typewriters seen once are
-- remembered (data\REAccess_known.txt) and listed while within 150 m.
G.known = G.known or nil
function G.with_known(all, pos)
    if not G.known then
        G.known = {}
        for line in (fs.read("REAccess_known.txt") or ""):gmatch("[^\n]+") do
            local nm, x, y, z = line:match("^(.-)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)$")
            if nm then G.known[#G.known + 1] = { name = nm, pos = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } } end
        end
    end
    local changed = false
    for _, t in ipairs(all) do
        if t.name == "Merchant" or t.name == "Typewriter, save game" then
            local have = false
            for _, k in ipairs(G.known) do
                if k.name == t.name and math.abs(k.pos.x - t.pos.x) < 1.5 and math.abs(k.pos.z - t.pos.z) < 1.5 and math.abs(k.pos.y - t.pos.y) < 2 then have = true break end
            end
            if not have then G.known[#G.known + 1] = { name = t.name, pos = { x = t.pos.x, y = t.pos.y, z = t.pos.z } } changed = true end
        end
    end
    if changed then
        local lines = {}
        for _, k in ipairs(G.known) do lines[#lines + 1] = string.format("%s|%.2f|%.2f|%.2f", k.name, k.pos.x, k.pos.y, k.pos.z) end
        pcall(fs.write, "REAccess_known.txt", table.concat(lines, "\n"))
    end
    for _, k in ipairs(G.known) do
        local loaded = false
        for _, t in ipairs(all) do
            if t.name == k.name and math.abs(k.pos.x - t.pos.x) < 1.5 and math.abs(k.pos.z - t.pos.z) < 1.5 then loaded = true break end
        end
        local dd = math.sqrt((k.pos.x - pos.x) ^ 2 + (k.pos.z - pos.z) ^ 2)
        if not loaded and dd < 150 then
            all[#all + 1] = { name = k.name, pos = k.pos, dist = dd, key = string.format("known_%.0f_%.0f", k.pos.x, k.pos.z) }
        end
    end
    table.sort(all, function(a, b) return (a.dist or 0) < (b.dist or 0) end)
    return all
end
local function current_list(pos)
    local c = CATEGORIES[cat_index]
    if c.enemies then
        local l = enemies(pos, FAR_RANGE)
        -- 11/9 user: "they all say Enemy, which one is he?": the cult leader
        -- (Summoner, Ch8) comes first in the list, with his own name.
        local oks, s = pcall(function() return G.summoner(pos, FAR_RANGE) end)
        if oks and s then
            for i, e in ipairs(l) do if e.key == s.key then table.remove(l, i) break end end
            s.name = "Cult leader with the bell, " .. (G.leader_in_view and "in view, shoot him" or "hidden")
            table.insert(l, 1, s)
            -- 11/9 user: "I don't see the drums in any category": the oil drums
            -- go right after him. Pick one and hold L: L aims at it when in view.
            local eye = { x = pos.x, y = pos.y + 1.4, z = pos.z }
            local at = 2
            for _, t in ipairs(scan_things(pos, 60)) do
                if t.name == "Oil Drum" and not G.gimmick_done(t.go) then
                    local ap = { x = t.pos.x, y = t.pos.y + 0.5, z = t.pos.z }
                    local _, d = G.clear_shot(eye, ap)
                    local full = math.sqrt((ap.x - eye.x) ^ 2 + (ap.y - eye.y) ^ 2 + (ap.z - eye.z) ^ 2)
                    local seen = (not d or d > full - 0.7)
                    local ld = math.sqrt((t.pos.x - s.pos.x) ^ 2 + (t.pos.z - s.pos.z) ^ 2)
                    local e = { pos = t.pos, dist = t.dist, key = t.key, go = t.go, drum = true }
                    e.name = "Oil drum" .. (ld < 4 and " under the cult leader" or "") .. ", " .. (seen and "in view, pick it and hold L" or "not in view")
                    table.insert(l, at, e)
                    at = at + 1
                end
            end
        end
        return l
    end
    if c.buildings or c.inside then
        local P = RE4Access.places
        if not P then return {} end
        return c.buildings and P.list(pos) or P.inside_list(pos)
    end
    if c.money then
        local out = {}
        for _, t in ipairs(items(pos, G.list_range or FAR_RANGE)) do
            if t.name:find("Pesetas", 1, true) or t.name:find("ペセタ", 1, true) then out[#out + 1] = t end
        end
        return out
    end
    if c.items then return items(pos, G.list_range or FAR_RANGE) end
    local all = scan_things(pos, (c.match or c.other or c.prefix) and (G.list_range or FAR_RANGE) or NEARBY_RANGE)
    if G.with_known then all = G.with_known(all, pos) end
    if c.match or c.other or c.prefix then
        local out = {}
        for _, t in ipairs(all) do
            local is_path = t.name:sub(1, 10) == "Path point"
            if is_path and visited[t.key] then is_path = false; if c.prefix then goto continue end end
            if (c.match and c.match[t.name]) or (c.prefix and is_path) or (c.other and not KNOWN[t.name] and not is_path) then out[#out + 1] = t end
            ::continue::
        end
        return out
    end
    -- Everything: skip breakables (dozens of pots and boxes) and visited path points.
    local kept = {}
    for _, t in ipairs(all) do
        if t.name ~= "Breakable crate" and not (t.name:sub(1, 10) == "Path point" and visited[t.key]) then kept[#kept + 1] = t end
    end
    all = kept
    for _, e in ipairs(enemies(pos)) do all[#all + 1] = e end
    for _, e in ipairs(items(pos)) do all[#all + 1] = e end
    table.sort(all, function(a, b) return a.dist < b.dist end)
    return all
end

-- Doors in lists say more than "Door" (10/13 user: "it has to give the player an
-- idea that this may be the exit they want"): its state, whether you came
-- through it, and whether the way to the objective goes through it.
RE4Access.used_doors = RE4Access.used_doors or {}
local obj_path = { at = -10, pts = nil }
local function objective_path(pos)
    local now = os.clock()
    if now - obj_path.at < 3 then return obj_path.pts end
    obj_path.at, obj_path.pts = now, nil
    local op = G.objective_pos()
    local R = RE4Access.route
    if op and R then
        local ok, pts = pcall(R.nav_points, pos, op)
        if ok then obj_path.pts = pts end
    end
    return obj_path.pts
end
function G.door_details(t, pos)
    local parts = {}
    local okc, c = pcall(G.door_center_of, t)
    local cpos = (okc and c) or t.pos
    local oko, open = pcall(G.door_is_open, t.go)
    local okl, locked = pcall(G.door_locked, t.go)
    if G.gimmick_near(t.pos, "スライド錠", 2.5) and not (oko and open) then
        parts[#parts + 1] = "barred; F unbars it from the bar side"
    elseif okl and locked then
        local padlock
        for _, q in ipairs(scan_things(t.pos, 3)) do if q.name == "Padlock" then padlock = true break end end
        if padlock then parts[#parts + 1] = "padlocked; shoot or kick the lock"
        else
            local okk, kt = pcall(G.door_key_text, t.go, pos)
            parts[#parts + 1] = "locked" .. ((okk and kt) and ("; " .. kt:gsub("%.$", "")) or "")
        end
    elseif oko and open then
        parts[#parts + 1] = "open"
    else
        parts[#parts + 1] = "closed"
    end
    if RE4Access.used_doors[t.key] then parts[#parts + 1] = "you came through it" end
    local pts = objective_path(pos)
    if pts then
        for _, q in ipairs(pts) do
            if math.sqrt((q.x - cpos.x) ^ 2 + (q.z - cpos.z) ^ 2) < 2 then
                parts[#parts + 1] = "on the way to the objective"
                break
            end
        end
    end
    return table.concat(parts, ", ")
end

local function switch_category(step)
    cat_index = (cat_index - 1 + step) % #CATEGORIES + 1
    selected = nil
    local pos = G.player_pos()
    local n = pos and #current_list(pos) or 0
    local c = CATEGORIES[cat_index]
    local s = c.name .. ", " .. n .. (n == 1 and " thing" or " things")
    if c.buildings then s = c.name .. ", " .. n .. (n == 1 and " building" or " buildings") end
    if (c.buildings or c.inside) and RE4Access.places then
        local note = RE4Access.places.note(c.inside)
        if note then s = s .. ". " .. note end
    end
    say(s)
end

local function cycle(step)
    local pos = G.player_pos()
    if not pos then return end
    local things = current_list(pos)
    if #things == 0 then say("Nothing nearby in " .. CATEGORIES[cat_index].name) selected = nil return end
    local idx = 0
    if selected then
        for i, t in ipairs(things) do if t.key == selected.key then idx = i break end end
    end
    idx = idx + step
    if idx < 1 then idx = #things elseif idx > #things then idx = 1 end
    selected = things[idx]
    walk.last_dist_said = nil
    local where = describe_position(selected.pos, pos, G.facing())
    local extra = ""
    if (selected.name == "Door" or selected.name == "Gate") and selected.go then
        local okd, dd = pcall(G.door_details, selected, pos)
        if okd and dd and dd ~= "" then extra = ", " .. dd end
    end
    if selected.note then extra = extra .. ", " .. selected.note end
    -- opened lockers are empty (10/20: user walked to one and F never came)
    if selected.name == "Locker" and selected.go and G.gimmick_done(selected.go) then extra = extra .. ", already opened, empty" end
    if selected.name == "Document" and selected.go then
        local okr, rd = pcall(G.doc_read, selected.go)
        if okr and rd ~= nil then extra = extra .. (rd and ", already read, Backslash reads it again" or ", not read yet") end
    end
    if selected.building and RE4Access.places then
        RE4Access.places.focus = selected.building
        local okb, bd = pcall(RE4Access.places.describe, selected, pos)
        if okb and bd ~= "" then extra = extra .. ", " .. bd end
    end
    say(selected.name .. ", " .. where .. extra .. ". " .. idx .. " of " .. #things)
end

-- Turn the camera so W walks toward the selected thing.
-- Turn the camera toward a world point. Returns true on success.
-- Directions mode (Shift+Period toggles, saved): "auto" = the mod turns the camera
-- for routes and cues; "spoken" = it only says where to turn and you turn
-- yourself with the arrow keys. Combat (aim lock, knife) and Backslash always turn.
local SETTINGS_FILE = "REAccess_settings.txt"
G.spoken = (fs.read(SETTINGS_FILE) or ""):find("spoken=1", 1, true) ~= nil
G.short = (fs.read(SETTINGS_FILE) or ""):find("short=1", 1, true) ~= nil
-- Walking reports (Shift+J, saved): the distance said every 10 m walked. Tester 10/31: too chatty.
-- Turns, blocked, doors and arrivals are not walking reports and stay on.
G.walk_reports = (fs.read(SETTINGS_FILE) or ""):find("walkreport=0", 1, true) == nil
-- Unlimited ammo exists only with the owner file (RE4Access.owner); tester builds never have it.
G.unlimited_ammo = RE4Access.owner and (fs.read(SETTINGS_FILE) or ""):find("ammo=1", 1, true) ~= nil
G.cant_die = RE4Access.owner and (fs.read(SETTINGS_FILE) or ""):find("cantdie=1", 1, true) ~= nil
local function save_settings()
    fs.write(SETTINGS_FILE, "spoken=" .. (G.spoken and 1 or 0) .. "\nshort=" .. (G.short and 1 or 0) .. "\nammo=" .. (G.unlimited_ammo and 1 or 0) .. "\nwalkreport=" .. (G.walk_reports and 1 or 0) .. "\ncantdie=" .. (G.cant_die and 1 or 0)
        .. "\ncombatquiet=" .. (G.combat_quiet and 1 or 0) .. "\nfightsound=" .. (G.fight_sound and 1 or 0) .. "\nhitsound=" .. (G.hit_sound and 1 or 0) .. "\nlistrange=" .. tostring(G.list_range))
end
-- 0.23.0 settings on function keys (tester 11/1). Quiet combat: only danger and "Enemy down".
do
    local st = fs.read(SETTINGS_FILE) or ""
    G.combat_quiet = st:find("combatquiet=1", 1, true) ~= nil
    G.fight_sound = st:find("fightsound=0", 1, true) == nil
    G.hit_sound = st:find("hitsound=1", 1, true) ~= nil
    G.list_range = tonumber(st:match("listrange=(%d+)")) or (RE4Access.owner and 300 or 100)
end
function G.toggle_combat_quiet()
    G.combat_quiet = not G.combat_quiet
    save_settings()
    say(G.combat_quiet and "Quiet combat. Only danger and enemy down." or "Full combat speech.", true)
end
function G.toggle_fight_sound()
    G.fight_sound = not G.fight_sound
    save_settings()
    say(G.fight_sound and "Fight sound on. It means an enemy is close or in your way, not that you were hit." or "Fight sound off.", true)
end
function G.toggle_hit_sound()
    G.hit_sound = not G.hit_sound
    save_settings()
    if G.hit_sound and RE4Access.sound then RE4Access.sound("hit") end
    say(G.hit_sound and "Hit sound on. It plays when you lose health." or "Hit sound off.", true)
end
function G.next_list_range()
    G.list_range = G.list_range == 300 and 100 or G.list_range == 100 and 60 or 300
    save_settings()
    say("Lists reach " .. G.list_range .. " meters.", true)
end
function G.settings_help()
    say("F2 combat speech, " .. (G.combat_quiet and "quiet" or "full") .. ". F3 walking reports, " .. (G.walk_reports and "on" or "off")
        .. ". F4 messages, " .. (G.short and "short" or "full") .. ". F5 turning, " .. (G.spoken and "spoken" or "automatic")
        .. ". F6 fight sound, " .. (G.fight_sound and "on" or "off") .. ". F7 hit sound, " .. (G.hit_sound and "on" or "off")
        .. ". F8 list range, " .. G.list_range .. " meters.", true)
end

-- Short messages (Slash toggles, saved): the how-to tails are dropped once you
-- know the keys ("Locked, 4 meters. Keep holding L, press K." -> "Locked 4.").
-- Applied to everything the mod says, menus included.
local SHORTEN = {
    { "^Press N for the next step%.$", "" },
    { "%s*Keep holding L, press K%.", "" },
    { "%s*Keep holding L; press K when I say fire%.", "" },
    { "%s*Turned you toward it%.", "" }, { "%s*Turned you to its middle%.", "" }, { "%s*Turned you toward the cart%.", "" },
    { "%s*Hold W%.", "" },
    { "^Route found, (%d+) meters to a (%a+) on the way%.", "Route %1, %2 on the way." },
    { "^Route found, (%d+) meters, winding%.", "Route %1." },
    { "^Route found, (%d+) meters%.", "Route %1." },
    { "^Part of the way known, (%d+) meters toward .-%.", "Route %1, partial." },
    { "^Locked, (%d+) meters, partly behind cover%.", "Locked %1, cover." },
    { "^Locked, (%d+) meters%.", "Locked %1." },
    { "Step around it, or shoot it to close it%.", "" },
    { "Back off and shoot the bomb: hold L, press K%.", "Shoot it." },
    { "Shoot it first: hold L, press K%.", "Shoot it." },
    { "Shoot the bomb: hold L, press K%.", "Shoot it." },
    { "%s*Stay back at least 4 meters%.", "" },
    { "Don't walk through its laser%.%s*", "" },
    { "%s*Choose Continue to try again%.", "" },
    { ", can't be used alone, combine it with a Green Herb", "" },
    { "%s*%(can't be used alone, combine it with a Green Herb%)", "" },
    { "%s*The game is paused while the case is open%.", "" },
    { "Hold Enter for about 2 seconds to craft%.", "Hold Enter." },
    { "%s*Press Enter, then choose Use%.", "" },
    { "Step toward it and press F%.", "Press F." },
    { "Hold Space and press K to slash%.", "Slash." },
    { "%s*Walk toward it yourself; Backslash faces it%.", "" },
    { "Open the case with Tab and equip one%.", "Switch guns." },
    { " is right here, ", ", " },
    { "%s*Don't step there%.", "" },
}
-- Fight mode (10/14: "too much talking, I can't concentrate", died in the
-- Valley): while a live enemy is within 12 m, only short, useful words.
local FIGHT_DROP = { "^F ready: Smooth Wood Box", "^F ready: Breakable crate", "^F ready: Padlock", "^F ready: Door",
    "^F ready: Locker", "^F ready: Drawer", "^Padlocked door%.", "^Padlock here", "^Crate with", "^Door ahead", "^Locked door ahead",
    "^No F yet", "^Entered Building", "^Left Building", "^Gun up$", "^Gun down$", "^Hold L while you press K$", "^No enemy in sight$",
    "^%d+ meters to go$", "^%d+ meters$", "^F ready%.$", "^Looking further$", "^Blocked$", "^Press N for the next step%.$",
    "^Route off$", "Low, heal soon%.$" }
local FIGHT_SHORT = {
    { "^Locked, %d+ meters, partly behind cover%..*", "Locked" },
    { "^Locked, %d+ meters%..*", "Locked" },
    { "^Enemy close, (.-)%. Hold Space and press K to slash%.", "Close, %1" },
    { "^Lunge, (.-)! Dodge: (.-)%.", "Lunge %1, %2" },
    { "^Grabbed! Press Space to knife free, or tap F fast%.", "Grabbed! Space" },
    { "^Hit by an enemy, .-%. Health (%d+) percent", "Hit, health %1" },
    { "^Hit from a distance, .-%. Health (%d+) percent", "Hit from far, health %1" },
    { "^(%d+) enemies%. Closest .*", "%1 enemies" },
    { "^Enemy, %d+ meters, .*", "1 enemy" },
    { "^Aiming at the dynamite man, %d+ meters%. Wait for fire%.", "Aiming, wait" },
    { "^Dynamite! (.-)%. Hold L, press K when I say fire%.", "Dynamite! %1" },
    { "%s*Heal now: press I, then the herb or spray%.", "" },
}
local fight = { at = 0, on = false }
local recent = {}
function G.in_fight()
    local now = os.clock()
    if now - fight.at > 0.5 then
        fight.at = now
        local on = false
        pcall(function()
            local pos = G.player_pos()
            if pos and #enemies(pos, 12) > 0 then on = true end
        end)
        fight.on = on
    end
    return fight.on
end
function G.shorten(text)
    if type(text) ~= "string" then return text end
    local now = os.clock()
    local ok, fighting = pcall(G.in_fight)
    if ok and fighting and text:sub(1, 1) ~= "#" then
        for _, pat in ipairs(FIGHT_DROP) do if text:find(pat) then return "" end end
        for _, r in ipairs(FIGHT_SHORT) do text = text:gsub(r[1], r[2]) end
        -- the same words again within 4 s: skip
        if recent[text] and now - recent[text] < 4 then return "" end
        recent[text] = now
    end
    if not G.short then return text end
    for _, r in ipairs(SHORTEN) do text = text:gsub(r[1], r[2]) end
    return (text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end
-- Wrap the speech function once (it survives module reloads).
if not RE4Access.speak_unshortened then
    RE4Access.speak_unshortened = RE4Access.speak
    RE4Access.speak = function(text, interrupt)
        local t = RE4Access.game and RE4Access.game.shorten and RE4Access.game.shorten(text) or text
        if t == "" then return end
        return RE4Access.speak_unshortened(t, interrupt)
    end
end
G.last_dir = nil
local function face_point(target, auto, force)
    local pos, facing, pc = G.player_pos(), G.facing(), player_camera()
    if not pos or not facing or not pc then return false end
    local want = heading_of(target.x - pos.x, target.z - pos.z)
    G.last_dir = relative(want - facing)
    if G.spoken and not force then return true end
    local delta = (want - facing + 540) % 360 - 180
    local yaw = pc:get_field("_Yaw") + YAW_SIGN * math.rad(delta)
    if yaw > math.pi then yaw = yaw - 2 * math.pi elseif yaw < -math.pi then yaw = yaw + 2 * math.pi end
    pc:set_field("_Yaw", yaw)
    G.turn_check = { want = want, at = os.clock() + 0.4, retried = false }
    return true
end

-- "Turned you toward it" in auto mode, "It is ahead left" in spoken mode
-- (call right after face_point / face_item).
function G.turned(what)
    if G.spoken then return "It is " .. (G.last_dir or "near") end
    return "Turned you " .. (what or "toward it")
end

-- Turn toward an item and tilt the camera down/up at it: the game offers
-- "pick up" for what the camera looks at (items in drawers sit low).
function G.face_item(target)
    if not face_point(target) then return false end
    if G.spoken then return true end
    pcall(function()
        local cam = main_camera_controller():call("get_CameraPosition")
        local dx, dz = target.x - cam.x, target.z - cam.z
        local pitch = math.atan(target.y - cam.y, math.sqrt(dx * dx + dz * dz))
        player_camera():set_field("_Pitch", math.max(-1.2, math.min(1.0, pitch)))
    end)
    return true
end

-- What is in the case for fighting: guns with rounds loaded and spare ammo.
-- Said when a gun clicks empty, so Leon doesn't keep fighting with an empty gun.
local AMMO_FOR = { ["Handgun Ammo"] = "handgun", ["Shotgun Shells"] = "shotgun", ["Rifle Ammo"] = "rifle",
    ["Submachine Gun Ammo"] = "submachine gun", ["Magnum Ammo"] = "magnum", ["Bolts"] = "bolt thrower" }
function G.ammo_advice()
    local loaded, spare, powder = {}, {}, 0
    pcall(function()
        local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
            local c = e:get_field("value")
            if c and c:get_type_definition():get_full_name() == "chainsaw.CsInventoryController" then
                local lst = c:call("getInventoryItemList()")
                for i = 0, lst:call("get_Count") - 1 do
                    local it = lst:call("get_Item", i)
                    local item = it:get_field("<Item>k__BackingField")
                    local name = RE4Access.menu.clean(msg_get:call(nil, mm:call("getItemNameMsgId", item:get_field("_ItemId"))))
                    local count = item:get_field("_CurrentItemCount") or 0
                    local okm, amax = pcall(function() return it:call("get_CurrentAmmoMax") end)
                    local oka, ammo = pcall(function() return it:call("get_CurrentAmmoCount") end)
                    if okm and amax and amax > 1 and oka and ammo and ammo > 0 then
                        loaded[#loaded + 1] = name .. " has " .. ammo
                    elseif AMMO_FOR[name] then
                        spare[#spare + 1] = count .. " " .. name
                    elseif name == "Gunpowder" then
                        powder = count
                    end
                end
            end
        end
    end)
    local s = "Out of ammo."
    if #spare > 0 then s = s .. " Press R to reload if you have ammo for this gun. Spare: " .. table.concat(spare, ", ") .. "." end
    if #loaded > 0 then s = s .. " Loaded guns: " .. table.concat(loaded, ", ") .. ". Open the case with Tab and equip one." end
    if #spare == 0 and #loaded == 0 then
        s = s .. " No ammo at all. Use the knife: hold Space and press K."
        if powder > 0 then s = s .. " You have " .. powder .. " gunpowder for crafting ammo." end
    end
    return s
end

-- Spoken mode: say which way to turn toward the next route point when that
-- changes ("Left", "Slightly right", "Straight ahead"), repeated every 3 s
-- while you are turned the wrong way.
local guide = { word = nil, at = 0 }
function G.guide_to(target, now)
    local pos, facing = G.player_pos(), G.facing()
    if not pos or not facing then return end
    local d = (heading_of(target.x - pos.x, target.z - pos.z) - facing + 540) % 360 - 180
    local a, side = math.abs(d), d > 0 and "left" or "right"   -- see relative()
    local word
    if a < 20 then word = "Straight ahead"
    elseif a < 50 then word = "Slightly " .. side
    elseif a < 110 then word = "Turn " .. side
    elseif a < 160 then word = "Sharp " .. side
    else word = "Turn around" end
    if word ~= guide.word or (word ~= "Straight ahead" and now - guide.at > 3) then
        if word == "Straight ahead" and guide.word == nil then guide.word = word return end
        guide.word, guide.at = word, now
        say(word, true)
    end
end
function G.guide_reset() guide.word = nil end

-- A window that can't be jumped through (GmWindow._OptionLock checkLocked).
function G.window_locked(w)
    local ok, locked = pcall(function()
        local ol = w:get_field("_OptionLock")
        return ol and ol:call("checkLocked")
    end)
    return ok and locked == true
end
local t_window = sdk.typeof("chainsaw.GmWindow")

-- Leon's case: the inventory controller holding items (10/22: chapter 5 has a
-- second, empty CsInventoryController listed first; gun/ammo info read that one).
function G.leon_inv()
    local best, bn
    pcall(function()
        local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
        for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
            local c = e:get_field("value")
            if c and c:get_type_definition():get_full_name() == "chainsaw.CsInventoryController" then
                local n = c:call("getInventoryItemList()"):call("get_Count")
                if not bn or n > bn then best, bn = c, n end
            end
        end
    end)
    return best
end

-- The gun in Leon's hands (CsInventoryController getEquippedWeapon(EquipType 0),
-- a chainsaw.WeaponItem): name, rounds loaded, magazine size, spare ammo in the
-- case (items whose id is the gun's get_CurrentAmmo).
function G.gun_info()
    local info
    pcall(function()
        local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
            local c = e:get_field("value")
            if c and c:get_type_definition():get_full_name() == "chainsaw.CsInventoryController" and c == G.leon_inv() then
                local w = c:call("getEquippedWeapon", 0)
                if not w then return end
                local ammo_id = w:call("get_CurrentAmmo")
                local spare = 0
                local lst = c:call("getInventoryItemList()")
                for i = 0, lst:call("get_Count") - 1 do
                    local item = lst:call("get_Item", i):get_field("<Item>k__BackingField")
                    if item and item:get_field("_ItemId") == ammo_id then spare = spare + (item:get_field("_CurrentItemCount") or 0) end
                end
                info = {
                    name = RE4Access.menu.clean(msg_get:call(nil, mm:call("getItemNameMsgId", w:call("get_ItemId")))),
                    loaded = w:call("get_CurrentAmmoCount"), max = w:call("get_CurrentAmmoMax"), spare = spare,
                    ammo = RE4Access.menu.clean(msg_get:call(nil, mm:call("getItemNameMsgId", ammo_id))),
                }
                return
            end
        end
    end)
    return info
end

-- X key: "W-870: 4 of 5 loaded. 6 Shotgun Shells spare."
-- Rough useful distances (the game has no hard range; damage and spread
-- get worse with distance). 10/14: user asked "how much range do my weapons have".
local RANGES = {
    { { "W%-870", "Riot Gun", "Striker", "Skull Shaker" }, "Shotgun: best within 5 meters, weak past 10." },
    { { "SR M1903", "Stingray", "CQBR" }, "Rifle: hits at any distance you can see, best for far enemies." },
    { { "TMP", "LE 5" }, "Submachine gun: best within 15 meters." },
    { { "Broken Butterfly", "Killer7", "Handcannon" }, "Magnum: strong to about 30 meters." },
    { { "Bolt Thrower" }, "Bolt thrower: about 20 meters." },
    { { "SG%-09", "Punisher", "Red9", "Blacktail", "Matilda", "Sentinel" }, "Handgun: best within 15 meters, still hits to about 25." },
}
function G.gun_range(name)
    for _, r in ipairs(RANGES) do
        for _, n in ipairs(r[1]) do if tostring(name):find(n) then return r[2] end end
    end
end

local function say_gun()
    local g = G.gun_info()
    if not g then say("No gun equipped") return end
    local s = string.format("%s: %d of %d loaded. ", g.name, g.loaded, g.max)
    if g.spare > 0 then s = s .. g.spare .. " " .. g.ammo .. " spare."
    else s = s .. "No spare " .. g.ammo .. "." end
    if g.loaded < g.max and g.spare > 0 then s = s .. " Press R to reload." end
    local r = G.gun_range(g.name)
    if r then s = s .. " " .. r end
    say(s, true)
end
G.say_gun = say_gun

-- While fighting: "2 left", "1 left", "Empty, press R" as rounds run out, and
-- "Reloaded, 5" after a reload. Also when switching guns: "<name>, 4 of 5".
local gun_watch = { at = 0 }
-- (10/14: a hook on WeaponItem.reduceAmmoCount never fired and was removed after
-- the game crashed; spare top-up below is what works.)
-- Unlimited ammo (10/14, final): the game's own check StatusEffectManager.isInfiniteAmmo
-- (used for infinite-ammo weapons and case perks) answers true while it is on. The
-- earlier refill/spare tricks did not stick, and adding case items crashed the game.
if not RE4Access.inf_hooked then
    RE4Access.inf_hooked = true
    local m = sdk.find_type_definition("chainsaw.StatusEffectManager"):get_method("isInfiniteAmmo")
    local okh, eh = pcall(sdk.hook, m, function(args) end, function(retval)
        if RE4Access.game and RE4Access.game.unlimited_ammo then return sdk.to_ptr(1) end
        return retval
    end)
    log.info("[RE4Access] isInfiniteAmmo hook: " .. tostring(okh) .. " " .. tostring(eh))
end
-- Unlimited grenades: REMOVED 11/11. Skipping Item.reduceCount never fired, and refilling
-- the count/ammo fields made a used-up "ghost" grenade (ammo 0) the game reset every frame:
-- key 2 then emptied Leon's hands. A throw sets WeaponItem _CurrentAmmoCount 1 -> 0.
-- Needs a different way (adding items crashed the game before, 10/14).
-- Unlimited grenades, try 2 (11/14). The 11/11 try refilled count/ammo fields and made a
-- "ghost" grenade; this one never writes items. CsInventoryController.useWeapon(EquipType,
-- int, int) -> bool is the game's "spend the equipped weapon" call (signature read live
-- 11/14). While unlimited ammo is on and Leon's equipped weapon is a grenade, the call is
-- skipped and answers true, so the grenade is thrown but never spent. Every call on a
-- grenade is logged ("grenade path"), and so are the other spend/remove calls, so the log
-- shows which one the game really uses if this one is not it.
if not RE4Access.grenade_hooked2 then
    RE4Access.grenade_hooked2 = true
    local GREN = { [277075456] = "Hand Grenade", [277078656] = "Flash Grenade" }
    local function leon_c()
        local G = RE4Access.game
        local f = G and (G.leon_inv_unwrapped or G.leon_inv)
        local ok, c = pcall(f)
        return ok and c or nil
    end
    local function grenade_of(c, et)
        local id
        pcall(function() local we = c:call("getEquippedWeapon", et); id = we and we:call("get_ItemId") end)
        return id, id and GREN[id]
    end
    local tdc = sdk.find_type_definition("chainsaw.CsInventoryController")
    local skip_ret = false
    for _, m in ipairs(tdc:get_methods()) do
        if m:get_name() == "useWeapon" and m:get_num_params() == 3 then
            local okh, eh = pcall(sdk.hook, m, function(args)
                skip_ret = false
                local c = sdk.to_managed_object(args[2])
                if not c or c ~= leon_c() then return end
                local et = sdk.to_int64(args[3]) & 0xFFFFFFFF
                local id, nm = grenade_of(c, et)
                if not nm then return end
                local G = RE4Access.game
                local on = G and G.unlimited_ammo
                log.info(string.format("[RE4Access] grenade path: useWeapon(%d, %d, %d) %s, unlimited %s", et,
                    sdk.to_int64(args[4]) & 0xFFFFFFFF, sdk.to_int64(args[5]) & 0xFFFFFFFF, nm, tostring(on)))
                if on then skip_ret = true return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(retval)
                if skip_ret then skip_ret = false return sdk.to_ptr(1) end
                return retval
            end)
            log.info("[RE4Access] unlimited grenades: useWeapon hook " .. tostring(okh) .. " " .. tostring(eh))
        end
    end
    -- diagnostics only (never skipped): which other spend/remove calls touch a grenade
    local function watch(tn, mn, np, describe)
        local td = sdk.find_type_definition(tn)
        for _, m in ipairs(td:get_methods()) do
            if m:get_name() == mn and m:get_num_params() == np then
                pcall(sdk.hook, m, function(args)
                    local ok, s = pcall(describe, args)
                    if ok and s then log.info("[RE4Access] grenade path: " .. tn:gsub("chainsaw%.", "") .. "." .. mn .. " " .. s) end
                end, function(r) return r end)
            end
        end
    end
    local function item_id(o) local id; pcall(function() id = o:get_field("_ItemId") end); if not id then pcall(function() id = o:call("get_ItemId") end) end return id end
    watch("chainsaw.CsInventoryController", "reduce", 2, function(args)
        local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
        if GREN[id] then return GREN[id] .. " x" .. (sdk.to_int64(args[4]) & 0xFFFFFFFF) end
    end)
    watch("chainsaw.CsInventoryController", "onForceRemoveItem", 1, function(args)
        local id = sdk.to_int64(args[3]) & 0xFFFFFFFF
        if GREN[id] then return GREN[id] end
    end)
    watch("chainsaw.CsInventoryController", "onRemoveItem", 3, function(args)
        local id = item_id(sdk.to_managed_object(args[3])); if id and GREN[id] then return GREN[id] end
    end)
    watch("chainsaw.WeaponItem", "reduceAmmoCount", 1, function(args)
        local id = item_id(sdk.to_managed_object(args[2])); if id and GREN[id] then return GREN[id] .. " by " .. (sdk.to_int64(args[3]) & 0xFFFFFFFF) end
    end)
    watch("chainsaw.Item", "reduceCount", 1, function(args)
        local id = item_id(sdk.to_managed_object(args[2])); if id and GREN[id] then return GREN[id] .. " by " .. (sdk.to_int64(args[3]) & 0xFFFFFFFF) end
    end)
end
-- (old) keep the equipped gun's magazine full - no longer used.
local ammo_fill = { at = 0, logged = false }
local function fill_ammo(now)
    if true then return end   -- replaced by the isInfiniteAmmo hook (10/14)
    if not G.unlimited_ammo then
        if ammo_fill.cost_off then
            pcall(function() ammo_fill.cost_off:call("enableCostAmmo", true) end)
            ammo_fill.cost_off = nil
        end
        return
    end
    if now - ammo_fill.at < 0.1 then return end
    RE4Access.fill_runs = (RE4Access.fill_runs or 0) + 1
    ammo_fill.at = now
    pcall(function()
        local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
        for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
            local c = e:get_field("value")
            if c and c:get_type_definition():get_full_name() == "chainsaw.CsInventoryController" and c == G.leon_inv() then
                local we = c:call("getEquippedWeapon", 0)
                if not we then return end
                -- getEquippedWeapon is a copy; the gun the game fires is the WeaponItem in
                -- the case list with the same ItemId (10/14: refilling the copy did nothing)
                local w = we
                pcall(function()
                    local id = we:call("get_ItemId")
                    local lst = c:call("getInventoryItemList()")
                    for i = 0, lst:call("get_Count") - 1 do
                        local item = lst:call("get_Item", i):get_field("<Item>k__BackingField")
                        if item and item:get_type_definition():get_name() == "WeaponItem" and item:call("get_ItemId") == id then w = item break end
                    end
                end)
                -- shots don't use ammo (WeaponItem.enableCostAmmo(false)); 10/14 refilling
                -- alone still let the gun run empty between refills
                if ammo_fill.cost_addr ~= w:get_address() then
                    ammo_fill.cost_addr = w:get_address()
                    local okc = pcall(function() w:call("enableCostAmmo", false) end)
                    ammo_fill.cost_off = w
                    log.info("[RE4Access] unlimited ammo: enableCostAmmo(false) " .. tostring(okc))
                end
                -- What really works (verified 10/14 16:58): keep SPARE rounds in the case.
                -- When the equipped gun's spare ammo drops under 15, fill its stack
                -- (setItemCount). Reload (R) then always works.
                if now - (ammo_fill.spare_at or 0) > 1 then
                    ammo_fill.spare_at = now
                    pcall(function()
                        local aid = we:call("get_CurrentAmmo")
                        if not aid or aid <= 0 or (we:call("get_CurrentAmmoMax") or 0) <= 0 then return end   -- knife, grenade
                        if ammo_fill.fail_until and ammo_fill.fail_id == aid and now < ammo_fill.fail_until then return end
                        local sum = c:call("getItemCountSum(chainsaw.ItemID)", aid)
                        -- 10/14 17:02 + 17:07 the game CRASHED a second after adding a new ammo
                        -- item (create_instance + forcePickupInstance). Now only an existing
                        -- stack is filled up (Item.setItemCount); it is kept from reaching 0.
                        if sum < 15 then
                            local lst = c:call("getInventoryItemList()")
                            for k = 0, lst:call("get_Count") - 1 do
                                local item = lst:call("get_Item", k):get_field("<Item>k__BackingField")
                                if item and item:get_field("_ItemId") == aid then
                                    local mx = item:call("get_StackMax") or 30
                                    item:call("setItemCount", mx)
                                    log.info(string.format("[RE4Access] unlimited ammo: stack %d -> %d (ammo %d)", sum, c:call("getItemCountSum(chainsaw.ItemID)", aid), aid))
                                    break
                                end
                            end
                        end
                    end)
                end
                local cur, max = w:call("get_CurrentAmmoCount"), w:call("get_CurrentAmmoMax")
                if cur and max and cur < max then
                    -- WeaponItem.forceSetAmmoCount / setAmmoCount (10/14: set_CurrentAmmoCount
                    -- does not exist; the first try left the gun at 5 of 10)
                    for _, how in ipairs({ "forceSetAmmoCount", "setAmmoCount" }) do
                        pcall(function() w:call(how, max) end)
                        if w:call("get_CurrentAmmoCount") >= max then break end
                    end
                    if w:call("get_CurrentAmmoCount") < max then pcall(function() w:set_field("_CurrentAmmoCount", max) end) end
                    pcall(function() we:call("forceSetAmmoCount", max) end)
                    if ammo_fill.logged ~= w:call("get_CurrentAmmoCount") then
                        ammo_fill.logged = w:call("get_CurrentAmmoCount")
                        log.info(string.format("[RE4Access] unlimited ammo: %d -> %d, now %s", cur, max, tostring(w:call("get_CurrentAmmoCount"))))
                    end
                end
                return
            end
        end
    end)
end

local function watch_gun(now)
    if now - gun_watch.at < 0.2 then return end
    gun_watch.at = now
    local g = G.gun_info()
    if not g then gun_watch.name = nil return end
    if g.name ~= gun_watch.name then
        if gun_watch.name then say(string.format("%s, %d of %d", g.name, g.loaded, g.max), false) end
    elseif g.loaded < gun_watch.loaded then
        if g.loaded == 0 then
            say(g.spare > 0 and "Empty, press R" or ("Empty, no spare " .. g.ammo), true)
        elseif g.loaded <= 2 then
            say(g.loaded .. " left", false)
        end
    elseif g.loaded > gun_watch.loaded then
        say("Reloaded, " .. g.loaded, false)
    end
    gun_watch.name, gun_watch.loaded = g.name, g.loaded
end
G.watch_gun = watch_gun

-- Carts (GmPushMove): you grab them at one end, the "icon" spot
-- (_IconPosOffset, in the cart's own space), by HOLDING F for _KeyHoldSec
-- seconds (3 for the road-block cart), then push along _Move. Returns the
-- floor spot at the handle and the hold time (10/12: F at the cart's middle
-- did nothing).
local t_push = sdk.typeof("chainsaw.GmPushMove")
local function rotate(q, v)
    -- v + 2 * cross(q.xyz, cross(q.xyz, v) + w * v)
    local cx = q.y * v.z - q.z * v.y + q.w * v.x
    local cy = q.z * v.x - q.x * v.z + q.w * v.y
    local cz = q.x * v.y - q.y * v.x + q.w * v.z
    return { x = v.x + 2 * (q.y * cz - q.z * cy), y = v.y + 2 * (q.z * cx - q.x * cz), z = v.z + 2 * (q.x * cy - q.y * cx) }
end
function G.cart_handle(go)
    local out
    pcall(function()
        local c = go:call("getComponent(System.Type)", t_push)
        if not c then return end
        local tr = go:call("get_Transform")
        local pos, q = tr:call("get_Position"), tr:call("get_Rotation")
        local off = c:get_field("_IconPosOffset")
        local o = rotate(q, { x = off.x, y = 0, z = off.z })
        local mv = c:get_field("_Move")
        local m = rotate(q, { x = mv.x, y = 0, z = mv.z })
        -- Stand 0.7 m beyond the handle: the handle itself is at the cart's edge,
        -- inside its collision, so a route to it circles forever (10/12).
        local ol = math.sqrt(o.x * o.x + o.z * o.z)
        local k = ol > 0.1 and (ol + 0.7) / ol or 1
        out = { pos = { x = pos.x + o.x * k, y = pos.y, z = pos.z + o.z * k }, center = { x = pos.x, y = pos.y, z = pos.z },
            push = m, hold = c:get_field("_KeyHoldSec") or 0 }
    end)
    return out
end

local t_bomb = sdk.typeof("chainsaw.GmSensorBomb")

-- A trap that hasn't gone off yet (GimmickContext hasDoneForMap turns true when a
-- bear trap snaps or a bomb explodes).
function G.trap_live(go)
    local ok, done = pcall(function()
        return go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore")):call("get_Context"):call("hasDoneForMap")
    end)
    return not (ok and done)
end

local back                  -- trail-back state, see breadcrumb trail below

local function face_selected()
    if not selected then say("Nothing selected. Use brackets to pick something.") return end
    if selected.name == "Locker" and selected.go and G.gimmick_done(selected.go) then
        say("This locker is already opened and empty. You took what was inside.", true)
        return
    end
    -- 11/2 Ch7: keyhole shelf with the Gold Bar, no key carried: no F angle exists, say why.
    -- Key found by its English name; other game languages fall through to the normal search.
    if selected.name == "Locker" and selected.go then
        local gn = ""
        pcall(function() gn = selected.go:call("get_Name") end)
        if gn:find("鍵のかかった", 1, true) then
            local has_key, read_ok = false, false
            pcall(function()
                local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
                local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
                local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
                for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
                    local c = e:get_field("value")
                    if c and c:get_type_definition():get_full_name() == "chainsaw.KeyItemInventoryController" then
                        local l = c:call("getInventoryItems")
                        for i = 0, l:call("get_Count") - 1 do
                            local id = l:call("get_Item", i):get_field("<Item>k__BackingField"):get_field("_ItemId")
                            local n = RE4Access.menu.clean(mg:call(nil, mm:call("getItemNameMsgId", id)))
                            read_ok = read_ok or n:find("%a") ~= nil
                            if n == "Small Key" then has_key = true end
                        end
                        break
                    end
                end
            end)
            if read_ok and not has_key then
                say("This locker has a keyhole and needs a Small Key. You have none, so F will not open it yet. Come back when you have one.", true)
                return
            end
        end
    end
    local pos = G.player_pos()
    -- Doors and gates: face the middle of the doorway, not the hinge.
    local target = selected.pos
    if selected.ctx then
        -- enemies move: use where it is now (10/13)
        pcall(function() local q = selected.ctx:call("get_Position"); target = { x = q.x, y = q.y, z = q.z }; selected.pos = target end)
    end
    if (selected.name == "Door" or selected.name == "Gate") and selected.go and G.door_center_of then
        local okc, c = pcall(G.door_center_of, selected)
        if okc and c then target = c end
    end
    -- Route on and the target far away: face the way the route goes, not the
    -- target through walls (10/14: Backslash pointed at the crank stand 74 m off
    -- and above, "something not even there").
    local R = RE4Access.route
    if pos and R and R.active() and R.next_point and math.sqrt((selected.pos.x - pos.x) ^ 2 + (selected.pos.z - pos.z) ^ 2) > 8 then
        local np = R.next_point()
        if np and face_point(np, false, true) then
            say("Facing the route. " .. selected.name:gsub("%..*$", "") .. " is " .. describe_position(selected.pos, pos, nil) .. ". Hold W.")
            return
        end
    end
    -- A document you read before: the game won't open a wall one again
    -- (10/18 Lakeside Map, no F from any angle), so the mod reads it itself.
    if selected.name == "Document" and selected.go and G.doc_read(selected.go) then
        local okt, txt = pcall(function()
            return G.document_text(selected.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmReadFile")):call("get_documentID"))
        end)
        if okt and txt then say(txt, true) return end
    end
    if selected.face then target = selected.face end
    if not pos or not face_point(target, false, true) then say("Can't turn now") return end
    local d = describe_position(selected.pos, pos, nil)
    say("Facing " .. selected.name .. ", " .. d)
    -- Up in a nest or on a hook: F can't reach it, shoot it down (10/18: Rifle
    -- Ammo 7 m up, Backslash went looking for an F angle).
    if selected.shoot and selected.item then
        say("It is up high, F can't reach it. Step back 3 to 6 meters, then hold L, I aim you at it, press K when I say fire. Then press F where it falls.")
        return
    end
    -- A walking point has nothing to press (10/19: "Way to the objective" -> "No F angle", user stuck).
    if selected.walk_point then say("This is only a point on the way, nothing to press here. Press N for the next step.") return end
    -- In a crate, barrel or box: F only works once it is open or broken (10/19:
    -- Flash Grenade in a crate, 1 m away, "No F angle" three times).
    if selected.item and selected.inside then
        local kind = tostring(selected.name):match(", in a (%a+)$")
        if kind == "crate" or kind == "barrel" or kind == "box" then
            say("It is in a " .. kind .. ". First HOLD F down for 1 second to open it. If nothing happens, break it: hold Space and press K a few times. Then press F to pick it up.")
            return
        end
    end
    if not selected.ctx and math.sqrt((selected.pos.x - pos.x) ^ 2 + (selected.pos.z - pos.z) ^ 2) < 2.5 then G.expect_prompt() end
end

-- Path points within 4 m count as visited and drop out of the Path points list.
local last_visit_check = 0
local function update_visited(pos, now)
    if now - last_visit_check < 1 then return end
    last_visit_check = now
    for _, t in ipairs(scan_things(pos, 6)) do
        if t.name:sub(1, 10) == "Path point" and t.dist < 4 and math.abs(t.pos.y - pos.y) < 2.5 then
            visited[t.key] = true
        end
        if (t.name == "Door" or t.name == "Gate") and t.dist < 3 then
            local okc, c = pcall(G.door_center_of, t)
            c = (okc and c) or t.pos
            if math.sqrt((c.x - pos.x) ^ 2 + (c.z - pos.z) ^ 2) < 1.0 then RE4Access.used_doors[t.key] = true end
        end
    end
end

-- Known ways on foot that the loaded walking map can't see from far away
-- (10/21). "Head for the church" in chapter 4 (walkthroughs: Push Square,
-- Vandal): the landing below the cliff (pier 9) is a dead end; the boat goes
-- to the Merchant's dock west of the Boat House (pier 6), then on foot back
-- through the Quarry (El Gigante ambush) and along the cliff path to the
-- church. Quarry -> church door checked on the walking map live (187 m; the
-- cliff path invisible walls are switched off in chapter 4). Pier 6 -> Quarry
-- not checked yet (not loaded from the far side of the lake).
G.LAND_WAYS = {
    -- (10/22: not plain "church": "Look for Ashley in the church" kept sending
    -- N back to the Insignia slot after the gate was open)
    { objective = "head for the church", min_chapter = 22100, pier = { x = 228.1, y = -7.6, z = 106.9, r = 7 }, pier_name = "the Merchant's dock",
      -- From the cliff side of the lake the straight way ends in a closed cove
      -- (10/21 live: circled there 2 min). West of x 196 the boat first goes
      -- through the north channel to this open-water point (live-driven:
      -- cliff landing -> channel -> west cave landing -> Merchant's dock).
      via = { x = 206, y = -8, z = 172, r = 0 }, via_west = 196,
      area = { x1 = 125, x2 = 262, z1 = 60, z2 = 175 },
      points = {
          -- the dock has no walking map; the way up is the ladder at its back
          -- (10/21 live: ladder -> Merchant -> door -> pre-merchant bonfire ->
          -- uphill path -> El Gigante autosave -> Quarry)
          { name = "the ladder up from the Merchant's dock", x = 218.1, y = -6.0, z = 110.0,
            tip = "Hold F to climb it. At the top press N again: the way goes past the Merchant, through a door and uphill." },
          { name = "Way to the Quarry", x = 184.5, y = 8.0, z = 131.0,
            tip = "Up from the Merchant's dock to the Quarry. El Gigante, a giant, ambushes you there: the gates close. Keep moving, shoot its face, and when the parasite comes out of its back press F to climb on and cut it." },
          { name = "the Quarry", x = 182.4, y = 8.2, z = 139.2,
            tip = "If El Gigante is here, keep moving and shoot its face. After the fight press N again." },
          -- (10/21: after the fight the cliff path is not loaded from the
          -- Quarry; N looped back to the Quarry. Steps in between.)
          { name = "the log gate", x = 178.0, y = 8.2, z = 152.7,
            tip = "It is open now. Go through it and follow the path west." },
          { name = "the path along the cliff", x = 160.4, y = 8.6, z = 150.9,
            tip = "Follow it west toward the church." },
          { name = "the cliff path to the church", x = 116.0, y = 9.0, z = 135.8,
            tip = "Through the log gate and along the cliff path." },
          -- the Insignia slot on the big front gate (GmBigDoorSeptum
          -- 教会門の隔壁, ItemUseSetting); 10/21: the first spot here (91,86) was
          -- the side gate to the graveyard, "won't open yet"
          { name = "the church front gate", x = 96.1, y = 11.2, z = 91.2,
            tip = "The Church Insignia goes into the slot on this big gate. Press F at it, pick the Church Insignia and choose Use." },
      } },
    -- Back to the church once the gate is open (10/22: N's old chapter 3
    -- "trail" walked the user 170 m from the church to the Quarry). Inside,
    -- G.church_inside_step takes over (lever, stained glass stand).
    { objective = "ashley in the church", min_chapter = 22100, all_walk = true,
      pier = { x = 228.1, y = -7.6, z = 106.9, r = 7 }, pier_name = "the Merchant's dock",
      area = { x1 = 88, x2 = 200, z1 = 84, z2 = 165 },
      points = {
          { name = "the log gate", x = 178.0, y = 8.2, z = 152.7, tip = "Go through it and follow the path west." },
          { name = "the path along the cliff", x = 160.4, y = 8.6, z = 150.9, tip = "Follow it west toward the church." },
          { name = "the cliff path to the church", x = 116.0, y = 9.0, z = 135.8, tip = "Keep following it to the church." },
          { name = "inside the church", x = 101.0, y = 11.2, z = 96.0,
            tip = "Through the open front gate into the church. Then press N again." },
      } },
    -- Chapter 5 "Head for the extraction point" (10/22: from behind the church
    -- N took the old trail back up a ladder; the objective 54,-145 is not on
    -- the loaded walking map). Walkthrough: graveyard, Village Square, Farm.
    -- The side gate to the graveyard is open now (nav reaches it). Points
    -- after the graveyard are places from chapter 3 (graveyard marker, the
    -- Merchant by the Town Hall, the typewriter south of it), not walked in Ch5.
    { objective = "extraction point", min_chapter = 22200, all_walk = true,
      pier = { x = 9999, y = 0, z = 9999, r = 0 }, pier_name = "",
      area = { x1 = -30, x2 = 130, z1 = -160, z2 = 130 },
      points = {
          { name = "the gate to the graveyard", x = 89.4, y = 10.1, z = 84.3,
            tip = "The small gate beside the church, now open. Villagers patrol the graveyard beyond it: you can tell Ashley to wait while you clear them." },
          { name = "the graveyard", x = 74.2, y = 2.1, z = 41.3, tip = "Down through the graveyard toward the village." },
          { name = "the Merchant by the Town Hall", x = 33.3, y = 1.0, z = 21.6,
            tip = "The Merchant is here, with a typewriter. He sells a bigger case, and you can sell treasures." },
          -- 10/22 live probe: from the village square (-2,0,-18) a plain walk east up a
          -- gentle slope (no ladder); the planner had picked a ladder and upper floors.
          { name = "the path south-east out of the village", x = 23.0, y = 2.2, z = -32.0,
            tip = "A plain walk east and up a gentle slope, no ladder." },
          { name = "the typewriter south of the village", x = 47.1, y = 3.6, z = -55.4,
            tip = "On the way south toward the Farm and the extraction point." },
      } },
    -- Chapter 6 "Escape from the village" (10/27: the game gives no map
    -- marker, N said "not sure" at Luis's house). Live 10/27: the walking map
    -- reaches the gate south of the house (81.6,-177.4), the Checkpoint
    -- entrance (129.4,-229) and the Checkpoint gate 関所の門Ver2 (157.3,-197.7)
    -- whose CrankBase is empty. Walkthroughs (Push Square, PowerPyx): the
    -- Checkpoint Crank is in the house in the middle; taking it starts a fight
    -- (Chainsaw Sisters), the crank opens the gate. Story trigger
    -- LevelKey_Ev_Csa_125 (149.2,4,-208.1) = taken as that house, not walked.
    -- "must" points can't be skipped by "furthest point in reach".
    { objective = "escape from the village", min_chapter = 22300, all_walk = true,
      pier = { x = 9999, y = 0, z = 9999, r = 0 }, pier_name = "",
      area = { x1 = 50, x2 = 300, z1 = -275, z2 = -130 },
      points = {
          { name = "the gate south of Luis's house", x = 81.6, y = 8.0, z = -177.4,
            tip = "The Merchant and a typewriter are near Luis's house, about 20 meters away: good time to buy, heal and save first. Then through this gate." },
          { name = "the Checkpoint entrance", x = 129.4, y = 4.7, z = -229.0,
            tip = "The Checkpoint, a walled village area. Villagers come. The gate out is locked; its crank is in the house in the middle." },
          { name = "the house in the middle of the Checkpoint", x = 149.2, y = 4.0, z = -208.1, must = true, need_item = "Checkpoint Crank", need_id = 119246400,
            tip = "The Checkpoint Crank is in here. Taking it starts a big fight, with the Chainsaw Sisters. Keep moving, use grenades, fight one at a time. The crank drops from them: pick it up, then press N." },
          { name = "the Checkpoint gate", x = 157.3, y = 2.5, z = -197.7,
            tip = "Press F at the crank holder, pick the Checkpoint Crank and choose Use, then hold F to turn it." },
          -- 10/27 live: past the Checkpoint gate the way on (Csa_126, autosave
          -- 197.6,-199.4) is behind a wire-mesh gate 金網ドア (190.9,-191.9) with a
          -- padlock (191.8,3.6,-191.6, 2 hits); the route circled 3 times.
          { name = "the wire gate with a padlock", x = 191.5, y = 2.6, z = -190.7, must = true, lock_at = { x = 191.8, z = -191.6 },
            tip = "Its padlock blocks the way. Press F here to kick it. If F does nothing, step back about 4 steps with S, hold L and press K twice to shoot the padlock. Then press N." },
          { name = "the way on past the wire gate", x = 197.6, y = 3.1, z = -199.4,
            tip = "Through the wire gate. The game autosaves here." },
          -- 10/27 live: Csa_126 is a story trigger (TimelineEventSensor at
          -- 203.4,4.6,-206.2, 1 m up); nothing east is walkable before it. Stand
          -- spot found on the walking map 0.9 m west of it.
          { name = "the story spot east of the wire gate", x = 202.5, y = 3.8, z = -206.2, must = true, story = true,
            tip = "Stand here facing east. If you hear F ready: Story event, press F; if not, hold W a step east into it. A scene plays, then press N." },
          { name = "further east", x = 280.0, y = 10.9, z = -222.2,
            tip = "Keep going east. The game autosaves here; Chief Mendez waits ahead." },
      } },
    { objective = "flee from the villagers", min_chapter = 22300, all_walk = true,
      pier = { x = 9999, y = 0, z = 9999, r = 0 }, pier_name = "",
      area = { x1 = 50, x2 = 320, z1 = -275, z2 = -130 },
      points = {
          { name = "the Checkpoint gate", x = 157.3, y = 2.5, z = -197.7, tip = "Through the gate, then east." },
          { name = "the way on past the Checkpoint gate", x = 203.4, y = 4.6, z = -206.2, tip = "Follow the path east." },
          { name = "further east", x = 280.0, y = 10.9, z = -222.2, tip = "Keep going east." },
      } },
}
function G.land_way(ot)
    if not ot then return nil end
    ot = ot:lower()
    local ch = G.chapter and G.chapter()
    for _, w in ipairs(G.LAND_WAYS) do
        if ot:find(w.objective, 1, true) and not (w.min_chapter and ch and ch < w.min_chapter) then return w end
    end
end
-- The next point of a known way, or nil (not on that way's land, or the
-- objective itself can be walked to).
function G.land_way_step(pos, ot)
    local w = G.land_way(ot)
    if not w then return nil end
    local R = RE4Access.route
    local function reaches(q)
        local pts = R.nav_points(pos, q)
        if not pts then return false end
        local e = pts.snap or pts[#pts]
        return math.sqrt((e.x - q.x) ^ 2 + (e.z - q.z) ^ 2) < 3
    end
    local function pick(i, extra)
        local q = w.points[i]
        local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
        return { name = q.name, pos = { x = q.x, y = q.y, z = q.z }, dist = d, key = "landway" .. i,
            walk_point = i < #w.points or w.all_walk, tip = (extra or "") .. q.tip }
    end
    local op = G.objective_pos()
    if op and reaches(op) then return nil end
    -- Points already reached never come back (10/22: past the Merchant in
    -- Building G, N sent the user back to him through a window).
    -- kept in a file across game restarts (10/27: a fresh start would send the
    -- user back to the crank house - the crank is used up by then)
    if not G.land_way_passed then
        G.land_way_passed = {}
        pcall(function()
            for k, v in (fs.read("REAccess_landway.txt") or ""):gmatch("([^=\n]+)=(%d+)") do G.land_way_passed[k] = tonumber(v) end
        end)
    end
    local passed = G.land_way_passed[w.objective or w] or 0
    local passed_before = passed
    for i = passed + 1, #w.points do
        local q = w.points[i]
        -- (10/27 live: walking upstairs past the crank house marked it done
        -- without the crank; a point with need_item counts only once you carry it)
        -- key items (the crank) are in the key item list, not the case: G.has_item by id
        local have = q.need_item and ((q.need_id and G.has_item(q.need_id)) or (G.carried and G.carried(q.need_item) > 0))
        if q.need_item and not have then break end
        -- a story trigger: done only once the next point can be walked to (10/27)
        if q.story then
            if w.points[i + 1] and reaches(w.points[i + 1]) then passed = i goto next_point end
            break
        end
        -- a padlock still holding the way: not passed until it breaks (10/27)
        if q.lock_at then
            local intact = false
            pcall(function()
                for _, t in ipairs(scan_things(pos, 60)) do
                    if t.name == "Padlock" and math.abs(t.pos.x - q.lock_at.x) < 1.5 and math.abs(t.pos.z - q.lock_at.z) < 1.5 then
                        local comp = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPadlock"))
                        if comp:get_field("_CurrentDurability") > 0 then intact = true end
                    end
                end
            end)
            if intact then break end
            have = true
        end
        if math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) < 6 or have then passed = i end
        ::next_point::
    end
    G.land_way_passed[w.objective or w] = passed
    if passed ~= passed_before and w.objective then
        pcall(function()
            local lines = {}
            for k, v in pairs(G.land_way_passed) do if type(k) == "string" then lines[#lines + 1] = k .. "=" .. v end end
            fs.write("REAccess_landway.txt", table.concat(lines, "\n") .. "\n")
        end)
    end
    -- no skipping past a "must" point not reached yet (10/27: the Checkpoint
    -- gate is in reach but needs the crank from the house first)
    local last = #w.points
    for i = passed + 1, #w.points do
        if w.points[i].must then last = i break end
    end
    -- the needed item lies on the ground nearby (10/27: the crank dropped by a
    -- Chainsaw Sister): go straight to it
    local nq = w.points[last]
    if nq.need_item then
        for _, t in ipairs(items(pos, 40)) do
            if t.name:find(nq.need_item, 1, true) then
                return { name = t.name, pos = t.pos, dist = t.dist, key = t.key, item = true, go = t.go,
                    tip = "It dropped here. Walk to it and press F to pick it up, then press N." }
            end
        end
    end
    -- the way's end in reach from anywhere: straight there (10/21: from the
    -- barn N took an old chapter 3 trail down the trapdoor; the church door
    -- was 33 m away out of the barn door)
    if reaches(w.points[last]) and not (last < #w.points and math.sqrt((w.points[last].x - pos.x) ^ 2 + (w.points[last].z - pos.z) ^ 2) < 6) then return pick(last) end
    local a = w.area
    if pos.x < a.x1 or pos.x > a.x2 or pos.z < a.z1 or pos.z > a.z2 then return nil end
    -- the furthest point along the way that the walking map reaches; when
    -- you already stand there, the next one (partial route toward it)
    for i = last, passed + 1, -1 do
        if reaches(w.points[i]) then
            local q = w.points[i]
            if i < #w.points and not q.story and math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) < 6 then return pick(i + 1) end
            return pick(i)
        end
    end
    if passed > 0 then return pick(math.min(passed + 1, #w.points)) end
    -- just off the boat and nothing loaded yet: head for the first point
    if math.sqrt((w.pier.x - pos.x) ^ 2 + (w.pier.z - pos.z) ^ 2) < 40 then
        return pick(1)
    end
end

-- Inside the church, "Look for Ashley in the church" (Chapter 4, 10/22): the
-- lever left of the altar (教会のレバー, GmLever) raises the stained-glass
-- stand (GmPuzzleStainedGlass); the Blue Dial goes in, the puzzle opens the
-- bars (GmStainedGlassShutter) to the ladder up to Ashley. The lever counted as
-- "behind bars, later" (chapter 3 rule), so N had nothing to offer.
function G.church_inside_step(pos)
    local lever, stand
    pcall(function()
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            pcall(function()
                local go = core:call("get_GameObject")
                local n = go:call("get_Name")
                local which = (n:find("教会のレバー", 1, true) and "lever") or (n:find("すてんどぐらすぱずる", 1, true) and "stand")
                if not which then return end
                local q = go:call("get_Transform"):call("get_Position")
                local t = { go = go, key = go:get_address(), pos = { x = q.x, y = q.y, z = q.z },
                    dist = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2), done = G.gimmick_done(go) }
                if which == "lever" then lever = t else stand = t end
            end)
        end
    end)
    if lever and not lever.done then
        lever.name = "Church lever"
        lever.tip = "It is on the wall left of the altar. Press F to pull it: a stand with dials rises in front of the altar."
        return lever
    end
    if stand and not stand.done then
        stand.name = "Stained glass stand"
        stand.tip = "Press F at it. If it has an empty slot, pick the Blue Dial and choose Use. Then turn the dials so the coloured glass lines up over the symbol on the floor: green over the centre, red over the body, blue over the rest. That opens the bars to Ashley."
        return stand
    end
    -- Puzzle solved (10/22: N went back to "inside the church ... for the
    -- lever"): through the opened bars, up the ladder (foot 112.1,11.2,99.6,
    -- top 16.2), then the upper floor to Ashley (LevelKey csa024アシュリー確保).
    if stand and stand.done then
        if pos.y < 14 then
            for _, c in ipairs(RE4Access.route.connectors({ x = 112.2, y = 11.2, z = 99.6 })) do
                if c.kind == "ladder" and math.abs(c.a.x - 112.1) < 1 and math.abs(c.a.z - 99.56) < 1 then
                    local d = math.sqrt((c.a.x - pos.x) ^ 2 + (c.a.z - pos.z) ^ 2)
                    return { name = "the ladder behind the open bars", pos = c.a, face = { x = c.b.x, y = c.a.y + 0.5, z = c.b.z }, dist = d,
                        key = "church_ladder", latch = true, fname = "Ladder", spoken = "ladder behind the bars",
                        after = "HOLD F down for 1 second to climb up. At the top press N again.",
                        tip = "The bars are open. I walk you to the foot of the ladder; when I say Ladder, HOLD F down for 1 second to climb up. At the top press N again." }
                end
            end
        end
        local q = { x = 102.6, y = 16.5, z = 107.1 }
        return { name = "the way to Ashley", pos = q, dist = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2), key = "church_ashley",
            walk_point = true, tip = "Along the upper floor of the church. Ashley is behind the iron door there; walking up to it starts a cutscene." }
    end
end

-- Chapter 5 "Escape from the church" (10/22 live): Ashley's boost lowers the
-- attic ladder 強力おろしハシゴ教会用 (foot 108.2,16.2,95.7, top 20.2); the attic
-- leads to the window where Leon jumps and catches Ashley (LevelKey csa086,
-- 111.3,22.2,105.1; nav from the ladder top verified, 9 points).
function G.church_escape_step(pos)
    if pos.y < 19 then
        for _, c in ipairs(RE4Access.route.connectors({ x = 108.8, y = 16.2, z = 96.2 })) do
            if c.kind == "ladder" and math.abs(c.a.x - 108.22) < 1 and math.abs(c.a.z - 95.74) < 1 then
                local d = math.sqrt((c.a.x - pos.x) ^ 2 + (c.a.z - pos.z) ^ 2)
                if d < 40 then
                    return { name = "the ladder up to the attic", pos = c.a, face = { x = c.b.x, y = c.a.y + 0.5, z = c.b.z }, dist = d,
                        key = "church_attic_ladder", latch = true, fname = "Ladder", spoken = "attic ladder",
                        after = "HOLD F down for 1 second to climb up. At the top press N again.",
                        tip = "Ashley lowered it for you. When I say Ladder, HOLD F down for 1 second to climb up. At the top press N again." }
                end
            end
        end
        return nil
    end
    local q = { x = 111.3, y = 22.2, z = 105.1 }
    return { name = "the attic window", pos = q, dist = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2), key = "church_window",
        walk_point = true, tip = "Through the attic to the window. Walking up to it starts a scene: you jump out and catch Ashley. The attic also has ammo, mines and pesetas; the Items list finds them." }
end

-- Chapter 4 church door: two head statues (生首像1 north = Blasphemer's Head,
-- 生首像2 south = Apostate's Head) go on the emblem holder. 10/20: "arrived at
-- objective but there is absolutely nothing" - the mod never said heads are needed.
G.HEADS = { { jp = "生首像1", name = "Blasphemer's Head", where = "in the small cave in the north of the lake" },
    { jp = "生首像2", name = "Apostate's Head", where = "in the cave in the south of the lake" } }
function G.church_heads(pos)
    local out = { have = {}, missing = {} }
    pcall(function()
        local dm = sdk.get_managed_singleton("chainsaw.DropItemManager")
        for _, e in ipairs(dm:get_field("_DropItem"):get_field("_entries"):get_elements()) do
            local di = e:get_field("value")
            pcall(function()
                local go = di:call("get_GameObject")
                local n = go:call("get_Name")
                for _, h in ipairs(G.HEADS) do
                    if n:find(h.jp, 1, true) then
                        local r = di:get_field("_Routine")
                        if r == 7 or r == 8 then out.have[#out.have + 1] = h
                        else
                            local q = go:call("get_Transform"):call("get_Position")
                            out.missing[#out.missing + 1] = { h = h, go = go, key = go:get_address(), pos = { x = q.x, y = q.y, z = q.z },
                                dist = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) }
                        end
                    end
                end
            end)
        end
    end)
    return out
end
-- Say it when a head is taken (10/20: "I do not know if I have the head").
function G.watch_heads(now)
    if now < (G.heads_at or 0) then return end
    G.heads_at = now + 1
    local pos = G.player_pos()
    if not pos then return end
    local st = G.church_heads(pos)
    local n = #st.have
    if G.heads_have and n > G.heads_have then
        local last = st.have[#st.have]
        if #st.missing == 0 then
            say("You have the " .. last.name .. ". That is both heads. Now take them to the church door: press N, I lead you to the boat, then across the lake.", true)
        else
            say("You have the " .. last.name .. ". Still missing: the " .. st.missing[1].h.name .. ".", true)
        end
    end
    if #st.have + #st.missing > 0 then G.heads_have = n end
    -- both heads placed: the stand moves and the door behind it opens
    -- (gm80_567 "opens when the heads are offered", 10/20)
    pcall(function()
        for _, t in ipairs(scan_things(pos, 6)) do
            if t.name == "Church Emblem Holder" then
                local c = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmChurchEmblemHolder"))
                local r = c:get_field("_Routine")
                if G.holder_routine and r ~= G.holder_routine then
                    if r == 3 then say("Both heads placed. The stand is moving and the door behind it opens. Wait a moment.", true)
                    elseif r == 4 then say("The door behind the stand is open. Press N and walk through.", true) end
                end
                G.holder_routine = r
            end
        end
    end)
end
-- The heads go on the two Head Statues beside the emblem stand (GmHeadStatue
-- with InteractHolder: 10/20 F never came at the stand itself). Stand in front
-- of a statue (toward its DispInItemUse child), face its IconPos.
function G.head_statue_step(pos)
    local best
    for _, t in ipairs(scan_things(pos, 15)) do
        if t.name == "Head Statue" and not G.gimmick_done(t.go) then
            pcall(function()
                local icon, disp
                local ch = t.go:call("get_Transform"):call("get_Child")
                while ch do
                    local n = ch:call("get_GameObject"):call("get_Name")
                    local q = ch:call("get_Position")
                    if n == "IconPos" then icon = { x = q.x, y = q.y, z = q.z } end
                    if n == "DispInItemUse" then disp = { x = q.x, y = q.y, z = q.z } end
                    ch = ch:call("get_Next")
                end
                if not icon or not disp then return end
                local dx, dz = disp.x - icon.x, disp.z - icon.z
                local l = math.max(0.01, math.sqrt(dx * dx + dz * dz))
                local stand = { x = icon.x + dx / l * 0.9, y = t.pos.y, z = icon.z + dz / l * 0.9 }
                local d = math.sqrt((stand.x - pos.x) ^ 2 + (stand.z - pos.z) ^ 2)
                if not best or d < best.dist then
                    best = { name = "the head statue", pos = stand, face = icon, dist = d, key = t.key, go = t.go, latch = true,
                        fname = "Head Statue", spoken = "head statue",
                        after = "Press F. Your case opens: pick a head and press Enter to place it. If the game says it does not fit, pick the other head. Then press N for the other statue." }
                end
            end)
        end
    end
    return best
end
-- Spoken help when standing at the emblem holder (nil when not there or done).
function G.church_heads_text(pos)
    local holder
    for _, t in ipairs(scan_things(pos, 5)) do
        if t.name == "Church Emblem Holder" or t.name == "Head Statue" then holder = t break end
    end
    if not holder or G.gimmick_done(holder.go) then return nil end
    local st = G.church_heads(pos)
    if #st.have + #st.missing == 0 then return nil end
    if #st.missing == 0 then
        return "This is the church door. You have both heads. They go on the two head statues on each side of the door. Press N: I walk you in front of one, then press F."
    end
    local m = st.missing[1]
    local t = "This is the church door. It needs two heads to open. "
    if #st.have > 0 then t = t .. "You have the " .. st.have[1].name .. ". " end
    return t .. "Still missing: the " .. m.h.name .. ", " .. m.h.where .. ", " .. math.floor(m.dist + 0.5) .. " meters. Press N to go there."
end

-- After arriving somewhere: point at the N key.
function G.on_arrived()
    -- 11/9 sneak route: on to the next waypoint by itself (keep holding W)
    if G.sneak_on then
        local ok, e = pcall(G.next_step)
        if not ok then log.info("[RE4Access] sneak next error: " .. tostring(e)) end
        return
    end
    -- Arrived at the objective itself: stop following (10/12 PM: "Arrived at
    -- Objective" / "Route 1" repeated about 30 times in 2 s and JAWS crashed).
    if G.follow and G.follow.on then
        local op, pos = G.objective_pos(), G.player_pos()
        local now = os.clock()
        G.follow.arrivals = G.follow.arrivals or {}
        table.insert(G.follow.arrivals, now)
        while #G.follow.arrivals > 0 and now - G.follow.arrivals[1] > 10 do table.remove(G.follow.arrivals, 1) end
        if (op and pos and math.sqrt((op.x - pos.x) ^ 2 + (op.z - pos.z) ^ 2) < 4) or #G.follow.arrivals >= 3 then
            G.follow.on = false
            G.follow.arrivals = {}
            local okh, ht = pcall(G.church_heads_text, pos)
            say(okh and ht or "You are at the objective. Look around here; press F on what is in reach.", false)
            return
        end
    end
    if G.follow and G.follow.on then
        G.follow.quiet = true
        RE4Access.n_story_now = true
        local ok, err = pcall(G.next_step)
        RE4Access.n_story_now = nil
        if not ok then log.info("[RE4Access] follow error: " .. tostring(err)) end
        return
    end
    say("Press N for the next step.", false)
end

-- ---------------- things to press F on ----------------
-- (The game's own prompt flag can't be read reliably, so this goes by distance
-- and direction.)
--   Doors: "Door ahead, press F to open" when one is within 2 m in front of you.
--          Doors close by themselves behind you. Locked ones say so.
--   Items, documents: "<name> here. Face it and press F" within 1.6 m.
--   Story events started with F: Leon is turned toward it, "... Press F."
--   Crates holding an item: "Crate with <item>. Face it, then Space to slash".
--   Items that were close and disappear: "Picked up <name>".
local DOOR_TYPES = { "chainsaw.GmDoor", "chainsaw.GmMotionDoor", "chainsaw.GmNpcMotionDoor", "chainsaw.GmDoorBrokenChainsaw" }
local function door_locked(go)
    for _, tname in ipairs(DOOR_TYPES) do
        local c = go:call("getComponent(System.Type)", sdk.typeof(tname))
        if c then
            -- _OptionLock:checkLocked() is the live state (_WasLocked stays set after unlocking).
            local ok, v = pcall(function()
                local ol = c:get_field("_OptionLock")
                if ol then return ol:call("checkLocked") end
                return false
            end)
            return ok and v == true
        end
    end
    return false
end

G.door_locked = door_locked

-- Big gates the story keeps shut for now (GmBigDoor._OptionSleep:checkSleep()
-- true). 10/14: the Chapter 2 factory gate stays asleep until the Merchant
-- unlocks it; the route went through it and said "Closed door" over and over.
local function gate_asleep(go)
    local ok, v = pcall(function()
        for _, tname in ipairs({ "chainsaw.GmBigDoor", "chainsaw.GmKeepBigDoor" }) do
            local c = go:call("getComponent(System.Type)", sdk.typeof(tname))
            if c then
                local s = c:get_field("_OptionSleep")
                return s ~= nil and s:call("checkSleep") == true
            end
        end
        return false
    end)
    return ok and v == true
end
G.gate_asleep = gate_asleep

-- Spoken when a closed-for-now gate is in the way. 10/14: the factory back
-- gate is iron bars raised by a crank stand next to it (GmHoldHandle with no
-- handle + CustomGmCrankHexCrest2): the Hexagonal Emblem from the Valley goes in.
function G.asleep_gate_text(pos, gate_pos)
    local t = "This gate won't open yet. The story opens it later"
    pcall(function()
        for _, q in ipairs(scan_things(gate_pos or pos, 6)) do
            local hex = q.go and q.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.CustomGmCrankHexCrest2"))
            if hex then
                t = "These iron bars won't open yet. A crank stand is next to them" .. (gate_pos and "" or (", " .. describe_position(q.pos, pos, G.facing())))
                    .. ", but it needs the Hexagonal Emblem, which is in the Valley. Get it first, then come back, press F at the stand and choose it"
                return
            end
        end
    end)
    return t .. "."
end

-- A door's transform sits at its hinge; its "IconPos" child (where the game
-- draws the F icon) is the middle of the doorway.
local door_center_cache = {}
local function door_center(t)
    local c = door_center_cache[t.key]
    if c then return c end
    c = { x = t.pos.x, y = t.pos.y, z = t.pos.z }
    -- GmDoor knows its own middle (_CenterPos).
    local okd, cp = pcall(function()
        return t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmDoor")):get_field("_CenterPos")
    end)
    if okd and cp and (cp.x ~= 0 or cp.z ~= 0) then
        c = { x = cp.x, y = t.pos.y, z = cp.z }
        door_center_cache[t.key] = c
        return c
    end
    pcall(function()
        local ch = t.go:call("get_Transform"):call("get_Child")
        while ch do
            if ch:call("get_GameObject"):call("get_Name") == "IconPos" then
                local q = ch:call("get_Position")
                c = { x = q.x, y = t.pos.y, z = q.z }
                break
            end
            ch = ch:call("get_Next")
        end
    end)
    door_center_cache[t.key] = c
    return c
end

function G.door_center_of(t) return door_center(t) end

-- Doors listed with their doorway middle instead of the hinge.
local function doors_near(pos, range)
    local out = {}
    for _, t in ipairs(scan_things(pos, range + 1.5)) do
        if t.name == "Door" or t.name == "Gate" then
            local c = door_center(t)
            local d = math.sqrt((c.x - pos.x) ^ 2 + (c.z - pos.z) ^ 2)
            if d <= range then out[#out + 1] = { name = t.name, pos = c, dist = d, key = t.key, go = t.go } end -- Door or Gate
        end
    end
    return out
end

local function ahead_of_camera(t, pos, max_angle)
    local f = G.facing()
    if not f then return true end
    local rel = (heading_of(t.pos.x - pos.x, t.pos.z - pos.z) - f + 540) % 360 - 180
    return math.abs(rel) <= max_angle
end

-- Which item opens a locked door (GmDoor._OptionLock.Items, each an
-- InteractTriggerUseItem.ItemData with the key's ItemID), its name, and where it
-- is if it is lying in the loaded world.
local function item_name_by_id(id)
    local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
    local n = RE4Access.menu.clean(msg_get:call(nil, mm:call("getItemNameMsgId", id)))
    return n ~= "" and n or nil
end
local function door_key_ids(go)
    local ids = {}
    for _, tname in ipairs(DOOR_TYPES) do
        local c = go:call("getComponent(System.Type)", sdk.typeof(tname))
        if c then
            pcall(function()
                local ol = c:get_field("_OptionLock")
                local arr = ol and ol:get_field("Items")
                for _, d in ipairs(arr and arr:get_elements() or {}) do
                    local id
                    for _, f in ipairs({ "ItemId", "_ItemId", "ItemID", "_ItemID", "Id", "ID" }) do
                        local ok, v = pcall(function() return d:get_field(f) end)
                        if ok and v ~= nil then id = v break end
                    end
                    if type(id) == "userdata" then pcall(function() id = id:get_field("value__") end) end
                    if id then ids[#ids + 1] = id end
                end
            end)
            break
        end
    end
    return ids
end
function G.door_key_text(go, pos)
    -- A padlock hanging on the door: shoot or slash it instead of a key.
    local okp, dp = pcall(function() return go:call("get_Transform"):call("get_Position") end)
    if okp and dp then
        for _, q in ipairs(scan_things({ x = dp.x, y = dp.y, z = dp.z }, 3)) do
            if q.name == "Padlock" then
                return "It has a padlock. Step back 3 to 6 meters, hold L, the aim locks onto it, press K. Two hits."
            end
            -- a latch bar on a wooden gate, not lifted yet (10/18: 汎用門の内鍵 on the
            -- gate past the howl; the gate stays shut until F at the latch)
            if q.name == "Gate latch" and q.dist < 2.5 then
                local okd, done = pcall(function() return q.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore")):call("get_Context"):call("hasDoneForMap") end)
                if not (okd and done) then
                    return "It is barred with a latch. Stand at the middle of the gate, press F to lift the latch, then hold W to push the gate open."
                end
            end
            -- a lock knob on this side (10/18: the Chief's front door from inside)
            if q.name == "Thumb Turn" and q.dist < 2 then
                return "It locks with a knob on this side. Press F to turn the knob, then walk through. No key needed."
            end
        end
    end
    local ids = door_key_ids(go)
    if #ids == 0 then return nil end
    local parts = {}
    for _, id in ipairs(ids) do
        local name = item_name_by_id(id) or ("item " .. tostring(id))
        local where = ""
        -- is it lying somewhere loaded?
        pcall(function()
            local dm = sdk.get_managed_singleton("chainsaw.DropItemManager")
            for _, e in ipairs(dm:get_field("_DropItem"):get_field("_entries"):get_elements()) do
                local di = e:get_field("value")
                if di then
                    local r = di:get_field("_Routine")
                    if r ~= 7 and r ~= 8 and di:get_field("_ItemData"):get_field("ItemID") == id then
                        local p = di:call("get_GameObject"):call("get_Transform"):call("get_Position")
                        where = ". It is " .. describe_position(p, pos, G.facing()) .. ". Find it in Items"
                        break
                    end
                end
            end
        end)
        if where == "" then
            local have = false
            pcall(function()
                local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
                for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
                    local c = e:get_field("value")
                    if c and c:get_type_definition():get_full_name() == "chainsaw.CsInventoryController" then
                        have = have or c:call("getItemCountSum(chainsaw.ItemID)", id) > 0
                    end
                end
            end)
            where = have and ". You have it: press F and choose it" or ". Not found nearby; it is somewhere further on"
        end
        parts[#parts + 1] = name .. where
    end
    return "It needs: " .. table.concat(parts, "; ")
end

-- Doors near Leon, for the route finder (routes may pass through doors).
function G.door_positions(pos, range)
    local out = {}
    for _, t in ipairs(doors_near(pos, range or 80)) do
        -- asleep gates are walls; so are locked doors with no padlock to shoot or
        -- bar to slide (10/14 6:27PM: route through the Village Chief's locked
        -- front door, 'Locked door' over and over)
        local blocked = gate_asleep(t.go)
        if not blocked and door_locked(t.go) then
            local okp, open_way = pcall(function()
                for _, q in ipairs(scan_things(t.pos, 3)) do if q.name == "Padlock" then return true end end
                return G.gimmick_near(t.pos, "スライド錠", 2.5)
            end)
            blocked = not (okp and open_way)
        end
        if not blocked then out[#out + 1] = t.pos end
    end
    return out
end

-- Called by the route finder when Leon is blocked: a door right in front?
-- GmDoor <Rno0>: 10 = closed (live-checked); 1/3 = opening/open.
local function door_is_open(go)
    local ok, r = pcall(function()
        return go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmDoor")):get_field("<Rno0>k__BackingField")
    end)
    return ok and r ~= nil and r ~= 10
end
G.door_is_open = door_is_open

function G.door_in_front(pos)
    for _, t in ipairs(doors_near(pos, 2.5)) do
        if math.abs(t.pos.y - pos.y) < 2 and ahead_of_camera(t, pos, 60) and not door_is_open(t.go) then
            if gate_asleep(t.go) then return t, true, true end
            return t, door_locked(t.go)
        end
    end
    return nil
end

-- Story events started by pressing F (their trigger is called "PushKey").
local needs_f_cache = {}
function G.needs_f(t)
    local c = needs_f_cache[t.key]
    if c ~= nil then return c end
    c = false
    pcall(function()
        local ih = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InteractHolder"))
        for _, a in ipairs(ih:get_field("_TrgAct"):get_elements()) do
            if a:get_field("UniqueName") == "PushKey" then c = true end
        end
    end)
    needs_f_cache[t.key] = c
    return c
end

local reach = {}            -- key -> { said = bool, item = name or nil, dist = }
local laser_said = {}       -- tripwire bomb key -> { said = bool }
local last_reach_check = 0
local F_NAMES = { ["Window barricade"] = "block the window: a list opens, pick Wooden Planks and choose Use. You need Wooden Planks; without them, fight", ["Ladder against the house"] = "kick it off",
    Window = "jump through it", Ladder = "climb", Lever = "pull it", ["Machine slot"] = "put an item in. Choose it from your case",
    ["Cart, push it"] = "grab it, then walk to push", Padlock = "kick it. Or hold Space and press K a few times to slash it", ["Lookout point"] = "look through the binoculars. If nothing happens, HOLD F down for 1 second", Document = "read it aloud", Trapdoor = "open it and go down: HOLD F down for 1 second. If F says Typewriter, tap A or D first", Typewriter = "use", ["Typewriter, save game"] = "save", Merchant = "talk", Ladder = "climb", Drawer = "open", ["Treasure chest"] = "open", ["Dog Caught In Trap"] = "free the dog: HOLD F down for 2 seconds, do not just tap it. The dog helps you in a big fight later", ["Gate latch"] = "lift the latch: HOLD F down for 1 second. Then hold W into the gate to push it open", ["Fallen shelf"] = "push it over. That opens a short way through" }
local function update_reach(pos, now)
    if now - last_reach_check < 0.25 then return end
    last_reach_check = now
    local near = {}
    for _, t in ipairs(items(pos, 3)) do near[#near + 1] = t end
    for _, t in ipairs(scan_things(pos, 3)) do
        if t.name ~= "Door" and t.name ~= "Gate" and (t.name:sub(1, 10) ~= "Path point" or G.needs_f(t)) then near[#near + 1] = t end
    end
    for _, t in ipairs(doors_near(pos, 3)) do near[#near + 1] = t end
    -- Tripwire lasers within 4 m of you (the beam reaches 2.6 m from the bomb, so
    -- the bomb's own distance isn't enough).
    pcall(function()
        for _, b in ipairs(G.laser_bombs(pos, 10)) do
            local ax, az, bx, bz = b.a.x, b.a.z, b.b.x, b.b.z
            local dx, dz = bx - ax, bz - az
            local l2 = dx * dx + dz * dz
            local t = l2 > 0 and math.max(0, math.min(1, ((pos.x - ax) * dx + (pos.z - az) * dz) / l2)) or 0
            local cx, cz = ax + dx * t, az + dz * t
            local d = math.sqrt((pos.x - cx) ^ 2 + (pos.z - cz) ^ 2)
            local st = laser_said[b.key] or {}
            laser_said[b.key] = st
            local where = describe_position({ x = cx, y = pos.y, z = cz }, pos, G.facing()):match("^%d+ meters, (.*)$") or "near"
            if d < 5 and math.abs(b.a.y - pos.y) < 2.5 then
                -- 5 m: warning once. Under 2.5 m: urgent, repeated every 2 s
                -- (10/12: one warning, then Leon walked into it two minutes later).
                if not st.far then
                    st.far = true
                    say(string.format("Stop! Tripwire laser %d meters, %s. Back off and shoot the bomb: hold L, press K.", math.floor(d + 0.5), where), true)
                elseif d < 2.5 and G.state_text == "In control" and not G.is_dead and now - (st.near_at or -10) > 2
                    and (st.near_n or 0) < 3 and (not st.near_d or d < st.near_d - 0.4) then
                    -- At most 3 times per approach, and only when you got closer
                    -- (10/12: it repeated every 2 s, even after dying).
                    st.near_at, st.near_n, st.near_d = now, (st.near_n or 0) + 1, d
                    say(string.format("Laser %d meters, %s! Don't step there.", math.floor(d + 0.5), where), true)
                end
            elseif d > 7 then
                st.far, st.near_at, st.near_n, st.near_d = false, nil, nil, nil
            end
        end
    end)
    -- Bear trap guard (10/12: caught again after five spoken warnings). Only when
    -- Leon's walking line runs onto a live trap (less than 0.9 m to the side of it,
    -- within 2.2 m ahead): the mod turns him just enough to pass it 1.3 m away, on
    -- his side of it, and the route waits 1 s. (First version turned him away from
    -- any trap within 1.8 m; next to the lane trap at (182.7,-108.2) he and the
    -- route took turns and he stood still: "Blocked".) Spoken once per trap.
    -- 10/27 Checkpoint: caught while backing away with S (told to by the mod)
    -- or sideways: the guard only looked where the camera faced. Now: walking
    -- toward a live trap in any other direction than forward = spoken STOP.
    pcall(function()
        if G.state_text ~= "In control" or G.is_dead then return end
        local mv = G.trap_mv or {}
        G.trap_mv = mv
        if not mv.p or now - mv.t >= 0.2 then
            if mv.p then
                local vx, vz = (pos.x - mv.p.x) / (now - mv.t), (pos.z - mv.p.z) / (now - mv.t)
                mv.vx, mv.vz = vx, vz
            end
            mv.p, mv.t = { x = pos.x, z = pos.z }, now
        end
        local sp = math.sqrt((mv.vx or 0) ^ 2 + (mv.vz or 0) ^ 2)
        if sp < 0.6 then return end
        local mx, mz = mv.vx / sp, mv.vz / sp
        local f = G.facing()
        local fwd = f and (mx * math.sin(math.rad(f)) + mz * math.cos(math.rad(f))) > 0.7
        if fwd and not G.aim_held() then return end   -- forward walking: the steering guard below handles it
        -- W held (or a route walking you) = forward: the guard below steers.
        -- 10/27 live: both steered in turns beside a trap, Leon stood 20 s.
        if reframework:is_key_down(0x57) or (RE4Access.route and RE4Access.route.active()) then return end
        for _, t in ipairs(scan_things(pos, 3)) do
            if t.name == "Bear trap" and G.trap_live(t.go) and math.abs(t.pos.y - pos.y) < 1.5 then
                local dx, dz = t.pos.x - pos.x, t.pos.z - pos.z
                local along = dx * mx + dz * mz
                local lat = math.abs(dx * mz - dz * mx)
                if along > -0.2 and along < 2.5 and lat < 0.9 and now - (mv.said or -10) > 1.0 then
                    mv.said = now
                    local where = f and describe_position(t.pos, pos, f) or "close"
                    if f and not G.aim_held() then
                        -- 10/27 user: "I want the mod to walk me around the bear trap".
                        -- Turn the camera so the way you are walking (back or sideways)
                        -- passes the trap 1.3 m to the side; keep holding the same key.
                        local side = (dx * mz - dz * mx) > 0 and -1 or 1   -- trap on your right: pass it on your left (your side)
                        local px, pz = t.pos.x + mz * side * 1.3 + mx * 0.3, t.pos.z - mx * side * 1.3 + mz * 0.3
                        local off = heading_of(mx, mz) - f
                        local want = heading_of(px - pos.x, pz - pos.z) - off
                        face_point({ x = pos.x + math.sin(math.rad(want)) * 3, y = pos.y, z = pos.z + math.cos(math.rad(want)) * 3 }, true, true)
                        G.guard_at, G.guard_until = now, now + 1.0
                        say("Bear trap " .. where .. ". Steered you around it, keep holding the same key.", true)
                    else
                        say("Stop! Bear trap " .. where .. ", you are walking onto it.", true)
                    end
                end
            end
        end
    end)
    pcall(function()
        if G.state_text ~= "In control" or G.is_dead or G.aim_held() then return end
        local f = G.facing()
        if not f then return end
        local hx, hz = math.sin(math.rad(f)), math.cos(math.rad(f))
        local rx, rz = hz, -hx                      -- Leon's right
        for _, t in ipairs(scan_things(pos, 2.5)) do
            if t.name == "Bear trap" and G.trap_live(t.go) and math.abs(t.pos.y - pos.y) < 1.5 then
                local dx, dz = t.pos.x - pos.x, t.pos.z - pos.z
                local along, lat = dx * hx + dz * hz, dx * rx + dz * rz
                -- 0.75 m (was 0.9): a route passing 0.9 m beside the trap at the
                -- Resources (S) lane (189.8,-117.1) was stopped every time (10/12 PM).
                if along > -0.2 and along < 2.2 and math.abs(lat) < 0.75 and now - (G.guard_at or -10) > 0.5 then
                    G.guard_at, G.guard_until = now, now + 1.0
                    local side = lat > 0 and -1 or 1     -- trap on the right -> pass it on the left
                    -- Pass 1.3 m away, or closer (0.95 m) when a wall leaves no room
                    -- (10/12 PM: steered into the lane wall, "Blocked" 5 times).
                    local off = 1.3
                    local R = RE4Access.route
                    for _, o in ipairs({ 1.3, 0.95 }) do
                        off = o
                        local px, pz = t.pos.x + rx * side * (o + 0.3), t.pos.z + rz * side * (o + 0.3)
                        local okc, hit = pcall(R.cast, pos.x, pos.y + 0.5, pos.z, px, pos.y + 0.5, pz)
                        if not (okc and hit) then break end
                    end
                    face_point({ x = t.pos.x + rx * side * off + hx * 0.3, y = pos.y, z = t.pos.z + rz * side * off + hz * 0.3 }, true, true)
                    local k = "trap" .. tostring(t.key)
                    if not laser_said[k] then
                        laser_said[k] = { at = now }
                        say("Bear trap ahead. Steered you around it.", true)
                    end
                    laser_said[k].at = now
                end
            end
        end
        for k, st in pairs(laser_said) do
            if type(k) == "string" and k:sub(1, 4) == "trap" and st.at and now - st.at > 30 then laser_said[k] = nil end
        end
    end)
    -- In a fight, only the thing you are going to (selected) gets a cue: no
    -- "Padlock here, turned you toward it" or box talk that turns your camera away
    -- from the enemies (10/14 Valley).
    local okf, fighting = pcall(G.in_fight)
    if okf and fighting then
        local keep = {}
        for _, t in ipairs(near) do
            if selected and selected.key == t.key then keep[#keep + 1] = t end
        end
        near = keep
    end
    -- Just climbed a ladder (height changed 2 m+ within 6 s): no "Ladder here,
    -- press F" for it, that only sends Leon back (10/18 barn trapdoor ladder).
    if G.last_y and math.abs(pos.y - G.last_y) > 2 then G.climbed_at = now end
    pcall(G.update_level, pos, now)
    -- Went back up by accident right after climbing down (10/18 barn: holding W
    -- at the ladder foot twice took Leon back up; could not be reproduced)
    if G.last_y and pos.y < G.last_y - 2 then G.down_at, G.down_y = now, pos.y end
    if G.down_at and now - G.down_at < 12 and pos.y > G.down_y + 2 then
        G.down_at = nil
        say("You went back up the ladder by accident. Press N: I walk you to the top again. Hold F 1 second to climb down, then tap S once before you hold W.", true)
    end
    G.last_y = pos.y
    if G.climbed_at and now - G.climbed_at < 6 then
        for _, t in ipairs(near) do
            if t.name == "Ladder" then local st = reach[t.key] or {} st.said = true reach[t.key] = st end
        end
    end
    -- Several F things close together (10/18 barn: typewriter, trapdoor and a
    -- document within 2 m each said "X here, turned you toward it" in turn and
    -- turned Leon back and forth): only the one you picked (selected), else the
    -- nearest, gets the cue. Traps and doors are kept.
    do
        local fthings, keep = {}, {}
        for _, t in ipairs(near) do
            local kept_kind = t.name == "Door" or t.name == "Gate" or t.name == "Bear trap" or t.name == "Bomb trap" or t.name == "Breakable crate"
            local opened = t.name == "Trapdoor" and G.gimmick_done(t.go)
            if opened then
                -- an opened trapdoor is just a hole now: no "Trapdoor here" (10/18)
            elseif kept_kind then keep[#keep + 1] = t elseif t.dist < 2.8 then fthings[#fthings + 1] = t else keep[#keep + 1] = t end
        end
        if #fthings > 1 then
            local pick
            for _, t in ipairs(fthings) do if selected and selected.key == t.key then pick = t end end
            if not pick then for _, t in ipairs(fthings) do if not pick or t.dist < pick.dist then pick = t end end end
            keep[#keep + 1] = pick
            near = keep
        end
    end
    local loot = {}
    for _, it in ipairs(near) do if it.item then loot[#loot + 1] = it end end
    local seen = {}
    for _, t in ipairs(near) do
        seen[t.key] = true
        local st = reach[t.key] or {}
        reach[t.key] = st
        st.item = t.item and t.name or nil
        if t.item and st.was_inside and not t.inside then st.said = false end
        st.was_inside = t.inside
        st.dist = t.dist
        local dy = math.abs(t.pos.y - pos.y)
        local route_on = RE4Access.route and RE4Access.route.active()
        if t.dist > 2.8 then
            st.said = false
        elseif route_on and (t.name == "Ladder" or t.name == "Window") then
            -- The route itself says when to press F at a ladder or window; a cue for
            -- the ladder just climbed down (10/12) would only send Leon back up.
        elseif not st.said then
            if t.name == "Door" or t.name == "Gate" then
                if t.dist < 2.5 and dy < 2 and ahead_of_camera(t, pos, 70) and not (t.name == "Door" and door_is_open(t.go)) then
                    st.said = true
                    if t.name == "Gate" and gate_asleep(t.go) then
                        say(G.asleep_gate_text(pos), false)
                    elseif t.name == "Gate" then
                        face_point(t.pos)
                        local okk, kt = pcall(G.door_key_text, t.go, pos)
                        say("Big gate ahead. " .. G.turned("to its middle") .. ". " .. ((okk and kt) or "Hold W to push it open, or press F."), false)
                    elseif door_locked(t.go) then
                        local padlock
                        for _, q in ipairs(scan_things(t.pos, 3)) do if q.name == "Padlock" then padlock = q break end end
                        if padlock then
                            say("Padlocked door. Step back 3 to 6 meters, hold L, the aim locks onto the padlock, press K. Two hits.", false)
                        elseif G.gimmick_near(t.pos, "スライド錠", 2.5) then
                            say("Barred door. Press F to unbar it, if the bar is on your side.", false)
                            G.expect_prompt()
                        else
                            local okk, kt = pcall(G.door_key_text, t.go, pos)
                            say("Locked door ahead. " .. ((okk and kt) or "Press F; if you have the key, choose it."), false)
                        end
                    else
                        -- Doors open when you walk into their middle (F only works lined up).
                        face_point(t.pos)
                        say("Door ahead. " .. G.turned("to its middle") .. ". Hold W to walk through, or press F.", false)
                        G.expect_prompt()
                    end
                end
            elseif t.name == "Bear trap" or t.name == "Bomb trap" then
                if t.dist < 3 and dy < 2 and t.go and G.trap_live(t.go)
                    and t.name == "Bomb trap" then
                    -- Bear traps: only when ahead, once per 30 s (10/12: "Bear trap, 3
                    -- meters, behind left" over and over during a fight).
                    st.said, st.trap_at = true, now
                    if t.name == "Bomb trap" then
                        say("Stop! Tripwire bomb, " .. describe_position(t.pos, pos, G.facing()) .. ". Don't walk through its laser. Shoot the bomb: hold L, press K.", true)
                    else
                        say("Bear trap, " .. describe_position(t.pos, pos, G.facing()) .. ". Step around it, or shoot it to close it.", true)
                    end
                end
            elseif t.name == "Breakable crate" then
                if t.dist < 1.6 and dy < 1.2 then
                    for _, it in ipairs(loot) do
                        -- Only items still INSIDE a crate (10/12: the cog lying on a table next
                        -- to a crate got "slash it", and the user wasted a shot).
                        if it.inside and (it.pos.x - t.pos.x) ^ 2 + (it.pos.y - t.pos.y) ^ 2 + (it.pos.z - t.pos.z) ^ 2 < 1.0 then
                            st.said = true
                            say("Crate with " .. it.name:gsub(", in a %a+$", "") .. ". Hold Space and press K to slash it", false)
                            break
                        end
                    end
                end
            elseif t.name:sub(1, 10) == "Path point" then
                -- 11/1: in the chase this spun Leon back toward Mendez
                if t.dist < 1.8 and dy < 2 and not G.in_chase and not (G.story_is_done and G.story_is_done(t)) then
                    st.said = true
                    face_point(t.pos)
                    say(t.name:gsub("^Path point, ", "") .. " here. " .. G.turned() .. ". Press F.", false)
                    G.want_f(t)
                end
            elseif t.item and t.locked then
                if t.dist < 2.0 and dy < 2 then
                    st.said = true
                    say(t.name .. ". Can't take it yet.", false)
                end
            elseif t.name == "Cart, push it" and t.go then
                local h = G.cart_handle(t.go)
                if h then
                    local d = math.sqrt((h.pos.x - pos.x) ^ 2 + (h.pos.z - pos.z) ^ 2)
                    if d < 1.2 and dy < 2 then
                        st.said = true
                        face_point(h.center)
                        local secs = h.hold > 0 and string.format("Hold F for %d seconds to grab it", math.floor(h.hold + 0.5)) or "Press F to grab it"
                        local shelf = G.is_shelf(t.go)
                        say((shelf and "Bookshelf here. " or "Cart handle here. ") .. G.turned(shelf and "toward the shelf" or "toward the cart") .. ". " .. secs .. ", then hold W to push.", false)
                    else
                        st.said = false
                    end
                end
            elseif (t.name == "Machine slot" or t.name == "Wayshrine") and t.go then
                if t.dist < 1.6 and dy < 2 then
                    st.said = true
                    face_point(t.pos)
                    local need, _, have = G.slot_need(t.go)
                    if need and have then
                        say(t.name .. " here, needs the " .. need .. ". You have it. " .. G.turned() .. ". Press F and choose it.", false)
                    elseif need then
                        say(t.name .. " here, needs the " .. need .. ". You don't have it yet.", false)
                    else
                        say(t.name .. " here. " .. G.turned() .. ". Press F.", false)
                        G.want_f(t)
                    end
                end
            elseif t.item and t.name:find("in a bird's nest", 1, true) and t.inside then
                if t.dist < 6 then
                    st.said = true
                    local sp = t.shoot or t.pos
                    say(t.name:gsub(", in a bird's nest", "") .. " is in a bird's nest, " .. describe_position(sp, pos, G.facing())
                        .. string.format(", %d meters up. Shoot the nest down: hold L, I aim you at it, press K when I say fire. Then it falls to the ground: press F to pick it up.", math.floor(sp.y - pos.y + 0.5)), false)
                end
            elseif t.item and not t.inside and t.dist < 2.0 and dy < 2 and G.wall_before({ x = pos.x, y = pos.y + 1.2, z = pos.z }, { x = t.pos.x, y = t.pos.y + 0.15, z = t.pos.z }) then
                -- Close but behind a wall (10/12: shotgun shells inside a hut, Leon outside).
                st.said = true
                say(t.name .. " is behind a wall, " .. describe_position(t.pos, pos, G.facing()) .. ". Go around to reach it: Shift+Backslash.", false)
            elseif t.item and t.inside then
                if t.dist < 1.6 and dy < 2 then
                    st.said = true
                    G.face_item(t.pos)
                    if t.locked then
                        say(t.name:gsub(", locked, needs the .*$", "") .. " is locked away. It needs the " .. t.locked .. ", which you don't have yet. Come back when you find one.", false)
                        goto locked_done
                    end
                    if t.shoot and t.shoot.what ~= "nest" then
                        say(t.name .. ". Step back 3 steps with S, pick it in Items, hold L, I aim you, press K when I say fire.", false)
                        goto locked_done
                    end
                    local kind = t.hold or t.name:match(", in a (%a+)$") or "box"
                    local how = t.hold and ". HOLD F down for 2 seconds to open it, do not just tap. Then press F to take it."
                        or OPEN_WITH_F[kind] and ". Press F to open it, then F again to take it."
                        or (G.has_knife() == false and ". You need a knife to break it, and you have none. Find a knife first, then come back.")
                        or ". Hold Space and press K to break it, then F to pick up."
                    say(t.name:gsub(", in a (%a+)$", "") .. " is inside a " .. kind .. ". " .. G.turned() .. how, false)
                    ::locked_done::
                end
            elseif t.name == "Window" and t.go and (function()
                    local w = t.go:call("getComponent(System.Type)", t_window)
                    return w and G.window_locked(w)
                end)() then
                st.said = true    -- locked window: no "press F" cue
            elseif t.name == "Lookout point" and t.go and (function()
                    local ok, gn = pcall(function() return t.go:call("get_Name") end)
                    return ok and gn and G.views_seen[gn]
                end)() then
                st.said = true    -- story binoculars already used: no "press F" cue
            elseif t.name == "Lever" and t.go and G.gimmick_done(t.go) then
                st.said = true    -- pulled already (10/22: the church lever turned the user away from the ladder route)
            elseif route_on and not (selected and selected.key == t.key) and (t.item or F_NAMES[t.name]) then
                st.said = true    -- walking a route elsewhere: don't turn Leon back (10/22: N from the Merchant kept turning to him)
            elseif t.item or F_NAMES[t.name] then
                -- Items on tables can't be walked up to as close: 2 m for items.
                -- 11/1: "Ladder here, turned you" spun Leon around 7 times during the boss
                -- 11/8: the Spinel on a desk edge: 'here' at 1.9 m stopped the route, which was
                -- going to the floor spot right under it (0.3 m); no F came from 1.9 m. While
                -- the route walks to this item, it goes on until 0.9 m (or its own end).
                local walking_here = t.item and route_on and selected and selected.key == t.key
                if t.dist < (walking_here and 0.9 or t.item and 2.0 or 1.6) and dy < 2 and not G.in_boss then
                    st.said = true
                    face_point(t.face or t.pos)
                    local verb = t.item and "pick up" or F_NAMES[t.name]
                    if t.name == "Document" and G.doc_read(t.go) then verb = verb .. ". You read this one already; if F does not come, press Backslash and I read it to you" end
                    local kind = t.item and t.inside and tostring(t.name):match(", in a (%a+)$")
                    if kind == "crate" or kind == "barrel" or kind == "box" then
                        verb = "pick up, after you open the " .. kind .. ": HOLD F for 1 second, or break it with Space and K"
                    end
                    if t.item then G.face_item(t.pos) end
                    -- Reached the item the route was going to: route done, one message.
                    if t.item and route_on and selected and selected.key == t.key then RE4Access.route.stop(true) end
                    say(t.name .. " here. " .. G.turned() .. ". Press F to " .. verb, true)
                    G.expect_prompt()
                    G.want_f(t)
                end
            end
        end
    end
    -- Items that were close and are now gone from the game's list were picked up.
    -- Not after a jump in position (death/Continue, loading): 10/14 the mod said
    -- "Picked up Hexagonal Emblem" when the game had just put it back on the roof.
    local jumped = G.state_text ~= "In control" or G.is_dead
    if G.reach_last_pos and math.sqrt((pos.x - G.reach_last_pos.x) ^ 2 + (pos.z - G.reach_last_pos.z) ^ 2) > 3 then jumped = true end
    if G.after_death_at then jumped = true end
    G.reach_last_pos = { x = pos.x, z = pos.z }
    if jumped then
        for key in pairs(reach) do if not seen[key] then reach[key] = nil end end
    end
    local all_items
    for key, st in pairs(reach) do
        if not seen[key] then
            if st.item and st.dist and st.dist < 2 then
                if not all_items then
                    all_items = {}
                    for _, t in ipairs(items(pos, 100000)) do all_items[t.key] = true end
                end
                if not all_items[key] then say("Picked up " .. st.item, false) G.picked_at = os.clock() end
            end
            reach[key] = nil
        end
    end
end

-- ---------------- objective ----------------
-- chainsaw.PurposeManager: spoken when it changes, O repeats it.
local last_objective
local last_obj_check = 0
-- English, for the mod's logic: routes and hints are keyed on the English objective.
local function objective_text()
    local pm = sdk.get_managed_singleton("chainsaw.PurposeManager")
    local it = pm and pm:call("get_CurrPurposeItem")
    if not it then return nil end
    local t
    pcall(function() t = RE4Access.menu.text_en(it:call("get_Message")) end)
    if not t or t == "" then t = RE4Access.menu.clean(msg_get:call(nil, it:call("get_Message"))) end
    return t ~= "" and t or nil
end
-- The game's language, for speech.
function G.objective_spoken()
    local pm = sdk.get_managed_singleton("chainsaw.PurposeManager")
    local it = pm and pm:call("get_CurrPurposeItem")
    if not it then return nil end
    local t = RE4Access.menu.clean(msg_get:call(nil, it:call("get_Message")))
    return t ~= "" and t or nil
end
local function update_objective(now)
    if now - last_obj_check < 1 then return end
    last_obj_check = now
    local t = G.objective_spoken()
    if t and t ~= last_objective then
        if last_objective ~= nil then say("New objective: " .. t, false) end
        last_objective = t
    end
end
-- Where the objective is: the map's objective icon keeps the world position
-- (chainsaw.GameConditionCollector.StatementMapObjective _InGameObjectivePos).
function G.objective_pos()
    local out
    pcall(function()
        local ib = sdk.get_managed_singleton("chainsaw.MapManager"):call("get_IconBehavior")
        local lst = ib:get_field("IconObjectiveHandler"):get_field("IdentifiersList")
        for i = 0, lst:call("get_Count") - 1 do
            local st = lst:call("get_Item", i):get_field("<identifier>k__BackingField")
            if st and st:get_field("_Enable") then
                local q = st:get_field("_InGameObjectivePos")
                out = { x = q.x, y = q.y, z = q.z }
                break
            end
        end
    end)
    return out
end

G.objective_text = objective_text
local function say_objective()
    local ok, t = pcall(G.objective_spoken)
    local text = ok and t and ("Objective: " .. t) or "No objective"
    local op, pos = G.objective_pos(), G.player_pos()
    if op and pos then text = text .. ". " .. describe_position(op, pos, G.facing()) end
    say(text)
end

-- ---------------- enemy warnings ----------------
-- Every half second: the closest enemy within 10 m. Spoken when it first comes
-- in range and each time it gets 3 m closer: "Enemy, 9 meters, ahead left".
-- Under 3 m: "Enemy close, <direction>" (knife: Space).
-- 10/12: in the village fight it said "Enemy, 15 meters" every 2 s as the closest
-- villager kept changing. Now: 10 m range, each enemy remembered for 15 s, and
-- at most one distance warning every 5 s (close warnings always).
local warn = { key = nil, said_dist = nil, per = {}, last_at = -10 }
local last_warn_check = 0
local function update_enemy_warning(pos, now)
    if G.is_paused and G.is_paused() then return end   -- 11/2: "1 enemy" every 15 s in the pause menu
    if now - last_warn_check < 0.5 then return end
    last_warn_check = now
    local list = enemies(pos, 10)
    local e = list[1]
    if not e or math.abs(e.pos.y - pos.y) > 3 then warn.key, warn.said_dist = nil, nil return end
    local f = G.facing()
    local dir = f and relative(heading_of(e.pos.x - pos.x, e.pos.z - pos.z) - f) or ""
    local pe = warn.per[e.key]
    if e.dist < 3 then
        if not (pe and pe.close) then
            warn.per[e.key] = { d = e.dist, at = now, close = true }
            warn.last_at = now
            if not G.combat_quiet then say("Enemy close, " .. dir .. ". Hold Space and press K to slash.") end
        end
        return
    end
    if pe and pe.close and e.dist > 5 then pe.close = false end
    local fresh = not pe or now - pe.at > 15
    if (fresh or e.dist <= pe.d - 3) and now - warn.last_at > 5 then
        warn.per[e.key] = { d = e.dist, at = now }
        warn.last_at = now
        local n = #list
        if not G.combat_quiet then say((n > 1 and (n .. " enemies. Closest ") or "Enemy, ") .. math.floor(e.dist + 0.5) .. " meters, " .. dir) end
    end
end

-- ---------------- documents (10/12 PM) ----------------
-- A sighted player reads every file; so does the mod. When a document you
-- opened with F is on screen (GmReadFile <FileFlow> set), its title and every
-- page are spoken: chainsaw.FileManager:getSingleDocumentData(id) ->
-- TitleGuid + PageDataList[i].<Guid> -> via.gui.message. Y repeats it.
local docs = { near = {}, at = 0, poll = 0, reading = {} }
local t_readfile = sdk.typeof("chainsaw.GmReadFile")
function G.document_text(id)
    local fm = sdk.get_managed_singleton("chainsaw.FileManager")
    local d = fm:call("getSingleDocumentData", id)
    if not d then return nil end
    local title = RE4Access.menu.clean(msg_get:call(nil, d:get_field("<TitleGuid>k__BackingField"))) or ""
    local parts, words = { "Document: " .. title .. "." }, 0
    G.doc_smudged = false
    local pl = d:get_field("<PageDataList>k__BackingField")
    local n = pl:call("get_Count")
    for i = 0, n - 1 do
        local raw = msg_get:call(nil, pl:call("get_Item", i):get_field("<Guid>k__BackingField")) or ""
        -- smudged notes: the game itself leaves letters out (gaps of 2+ spaces
        -- inside lines, 10/18 Lakeside Map) - say so, the words are not our bug
        local _, gaps = raw:gsub("%S  +%S", "")
        if gaps >= 3 then G.doc_smudged = true end
        local txt = RE4Access.menu.clean(raw) or ""
        if txt ~= "" and txt ~= title then
            words = words + 1
            parts[#parts + 1] = (n > 2 and ("Page " .. i .. ". ") or "") .. txt
        end
    end
    if words == 0 then parts[#parts + 1] = "There are no words on it; it is a picture you look at." end
    if G.doc_smudged then table.insert(parts, 2, "This paper is smudged: some letters are missing in the game too.") end
    return table.concat(parts, " ")
end

-- The FileFlow poll did not fire when the user opened the Charred Picture Frame
-- (10/12 PM), so also hook the game's own start of reading.
function G.on_doc_start(this)
    local id = this:call("get_documentID")
    local now = os.clock()
    if docs.last_id == id and now - (docs.last_at or -10) < 3 then return end
    docs.last_id, docs.last_at = id, now
    log.info("[RE4Access] document opened (hook): " .. tostring(id))
    local text = G.document_text(id)
    if text then say(text, true) end
end
if not RE4Access.doc_hooked then
    RE4Access.doc_hooked = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.GmReadFile")
        for _, mname in ipairs({ "onStartRead", "startRead" }) do
            local m = td:get_method(mname)
            if m then
                sdk.hook(m, function(args)
                    pcall(function() RE4Access.game.on_doc_start(sdk.to_managed_object(args[2])) end)
                end, function(r) return r end)
            end
        end
    end)
end

-- A document or picture view is still on screen (10/20: after the Tattered
-- Officer's Cap the view stayed open 45 s and W said "Blocked" 6 times).
function G.doc_reading()
    -- 11/2 Ch7: a document hides itself once read, so it left docs.near while still
    -- marked open: W then said "still open" 28 m away, for the rest of the session.
    -- Only a document still near Leon counts.
    for _, t in ipairs(docs.near) do if docs.reading[t.key] then return true end end
    return false
end
function G.update_documents(now)
    local pos = G.player_pos()
    if not pos then return end
    if now - docs.at > 1 then
        docs.at = now
        docs.near = {}
        for _, t in ipairs(scan_things(pos, 4)) do
            if t.name == "Document" then docs.near[#docs.near + 1] = t end
        end
    end
    if now - docs.poll < 0.2 then return end
    docs.poll = now
    for _, t in ipairs(docs.near) do
        pcall(function()
            local c = t.go:call("getComponent(System.Type)", t_readfile)
            local open = c:get_field("<FileFlow>k__BackingField") ~= nil
            if open and not docs.reading[t.key] then G.on_doc_start(c) end
            if not open and docs.reading[t.key] then say("Document closed. You can walk.", false) end
            docs.reading[t.key] = open
        end)
    end
end

-- ---------------- attack warning (10/12 PM, EXPERIMENTAL) ----------------
-- User: "is there a way to know before I get hit?" The game gives no attack flag we
-- know of yet, so: a villager within 3.5 m who suddenly closes in fast (a lunge or a
-- grab run, over 2.2 m/s) -> "Lunge, behind left! Back off or slash." Plus a
-- recorder: every animation change of villagers within 5 m goes to the log with the
-- distance, so the real wind-up animations can be found and warned about later.
local atk = { last = {}, motion = {}, said = {}, at = 0 }
local t_motion = sdk.typeof("via.motion.Motion")
function G.update_attack(pos, now)
    if now - atk.at < 0.1 then return end
    local dt = now - atk.at
    atk.at = now
    if dt > 0.5 then atk.last = {} end
    local f = G.facing()
    local seen = {}
    for _, e in ipairs(enemies(pos, 6)) do
        if math.abs(e.pos.y - pos.y) < 2.5 then
            seen[e.key] = true
            local was = atk.last[e.key]
            atk.last[e.key] = e.dist
            if was and e.dist < 3.5 then
                local speed = (was - e.dist) / dt
                if speed > 2.2 and now - (atk.said[e.key] or -10) > 3 and now - (atk.any or -10) > 1 then
                    atk.said[e.key], atk.any = now, now
                    local dir = f and relative(heading_of(e.pos.x - pos.x, e.pos.z - pos.z) - f) or ""
                    -- which way to dodge (10/14: "I hear lunge and have no clue how to get around it")
                    local key = dir:find("left") and "D" or dir:find("right") and "A" or dir:find("behind") and "W" or "A or D"
                    if not G.combat_quiet then say("Lunge, " .. dir .. "! Dodge: " .. key .. ".", true) end
                    log.info(string.format("[RE4Access] lunge warn d=%.1f speed %.1f", e.dist, speed))
                end
            end
            -- recorder: animation (motion bank / id) changes within 5 m
            if e.dist < 5 then
                pcall(function()
                    local body = e.ctx:call("get_BodyGameObject")
                    local m = body:call("getComponent(System.Type)", t_motion)
                    local layer = m:call("getLayer", 0)
                    local id = tostring(layer:call("get_MotionBankID")) .. "/" .. tostring(layer:call("get_MotionID"))
                    if atk.motion[e.key] ~= id then
                        atk.motion[e.key] = id
                        log.info(string.format("[RE4Access] atkrec E%d d=%.1f motion %s", e.key % 100000, e.dist, id))
                        -- 11/1 log: Mendez (Ch1b5z1) plays 6/5700 or 6/5705 about 1 s before his grab (2 of 2)
                        if id:find("^6/57") and e.ctx:get_type_definition():get_name():find("^Ch1b5z1") then
                            say("Grab coming! Keep running.", true)
                            log.info("[RE4Access] mendez grab warning")
                        end
                    end
                end)
            end
        end
    end
    for k in pairs(atk.last) do if not seen[k] then atk.last[k] = nil end end
end

-- ---------------- combat feedback ----------------
local combat = { hp = nil, dead = false, aiming = false, target = nil, enemy_hp = {}, last_hit = 0, low_said = false, traps_seen = {} }

local function update_combat(now)
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    local pc = cm and cm:call("getPlayerContextRef")
    if not pc then return end
    -- Your health.
    local hp = pc:call("get_HitPoint")
    local cur, max = hp:call("get_CurrentHitPoint"), hp:call("get_DefaultHitPoint")
    local pct = max > 0 and math.floor(cur * 100 / max + 0.5) or 0
    if cur <= 0 or hp:call("get_IsDead") then
        G.is_dead = true
        if not combat.dead then
            combat.dead = true
            if RE4Access.route then RE4Access.route.stop(true) end
            if G.follow then G.follow.on = false end
            say("You died. Choose Continue to try again. After that, press N.")
            -- 10/14: after Continue the game may go back to before an item was
            -- picked up; remember what you carried to tell you afterwards.
            pcall(function() G.carried_at_death = { emblem = G.has_item(119203200) } end)
        end
        return
    end
    if combat.dead then G.after_death_at = os.clock() + 3 end
    if G.after_death_at and os.clock() > G.after_death_at then
        G.after_death_at = nil
        pcall(function()
            local had = G.carried_at_death and G.carried_at_death.emblem
            local has = G.has_item(119203200)
            if had and not has then
                say("The game went back to before you picked up the Hexagonal Emblem. It is on the roof again; press N to go and get it.", false)
            elseif has then
                say("You still have the Hexagonal Emblem.", false)
            end
        end)
    end
    combat.dead = false
    G.is_dead = false
    if combat.hp and cur < combat.hp then
        -- What did it: a trap that just went off next to you, an enemy in reach,
        -- or something from further away (dynamite, thrown axes).
        local lost = math.floor((combat.hp - cur) * 100 / max + 0.5)
        -- F7 (tester 11/1: "is it the nearby cue or am I being attacked?"). Not on grab/fire drain ticks.
        if G.hit_sound and RE4Access.sound and not combat.grabbed and not combat.burning and now - (combat.hit_snd or -1) > 0.3 then
            combat.hit_snd = now
            RE4Access.sound("hit")
        end
        log.info(string.format("[RE4Access] atkrec PLAYER HIT -%d percent", lost))
        -- 10/27 diagnostic: what each hit was (Checkpoint road: many -4% ticks, no
        -- attacker within 3 m, deaths in seconds).
        pcall(function()
            local pc = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef")
            local pp = G.player_pos()
            local ne = {}
            for _, e in ipairs(enemies(pp, 8)) do
                ne[#ne + 1] = string.format("%s %.1f dy%.1f grap=%s", e.ctx:get_type_definition():get_name(), e.dist, e.pos.y - pp.y, tostring(e.ctx:call("get_IsConstOnGrapple")))
                if #ne >= 4 then break end
            end
            local tr = {}
            for _, t in ipairs(scan_things(pp, 2.5)) do
                if t.name == "Bear trap" then tr[#tr + 1] = string.format("trap %.1f live=%s", t.dist, tostring(G.trap_live(t.go))) end
            end
            log.info(string.format("[RE4Access] hitinfo type=%s part=%s burn=%s grapple=%s at (%.1f,%.1f,%.1f) | %s | %s",
                tostring(pc:call("get_DamageType")), tostring(pc:call("get_LastDamageCategory")), tostring(pc:call("get_IsInBurnDamage")),
                tostring(pc:call("get_IsInGrappleDamage")), pp.x, pp.y, pp.z, table.concat(ne, "; "), table.concat(tr, "; ")))
        end)
        local cause
        if lost >= 5 then
            local pos = G.player_pos()
            pcall(function()
                for _, t in ipairs(scan_things(pos, 12)) do   -- bomb blasts reach far
                    if (t.name == "Bear trap" or t.name == "Bomb trap") and not G.trap_live(t.go) and not combat.traps_seen[t.key] then
                        combat.traps_seen[t.key] = true
                        cause = t.name == "Bomb trap" and "A tripwire bomb exploded" or "Caught in a bear trap"
                    end
                end
                if not cause then
                    local es = enemies(pos, 3)
                    if #es > 0 then cause = "Hit by an enemy, " .. describe_position(es[1].pos, pos, G.facing())
                    elseif RE4Access.flee and RE4Access.flee.rock_at and os.clock() - RE4Access.flee.rock_at < 4 then cause = "Hit by a catapult rock"
                    else cause = "Hit from a distance, maybe dynamite or a thrown weapon" end
                end
            end)
        end
        -- Speak once per 10 percent step (a grab drains health 1 percent at a time).
        local step = math.floor(pct / 10)
        if cause then
            combat.hurt_step = step
            say(cause .. ". Health " .. pct .. " percent", true)
        elseif step ~= combat.hurt_step then
            combat.hurt_step = step
            if not G.combat_quiet then say("Hurt, health " .. pct .. " percent", false) end
        end
        if pct <= 35 and not combat.low_said then
            combat.low_said = true
            say("Health low. Press I and heal with a herb.", false)
        end
    end
    -- Low health: remind every 60 s while under 35 percent, at most 3 times
    -- (10/12: every 20 s was chatter, and useless with no herbs left).
    if pct <= 35 and not G.is_paused() and combat.low_said and (combat.low_n or 0) < 3 and now - (combat.low_at or 0) > 60 and G.state_text == "In control" then
        combat.low_at, combat.low_n = now, (combat.low_n or 0) + 1
        say("Health " .. pct .. " percent. Heal now: press I, then the herb or spray.", false)  -- 10/19: I opens the case, Tab does nothing
    end
    if pct <= 35 and not combat.low_at then combat.low_at = now end
    if pct > 50 then combat.low_said, combat.low_at, combat.low_n = false, nil, 0 end
    -- Grabbed by a villager (enemy context get_IsConstOnGrapple, live-seen 10/12):
    -- the grab drains health fast; the knife frees Leon.
    pcall(function()
        local pos = G.player_pos()
        local grabbed = false
        local list = cm:call("get_EnemyContextList")
        for i = 0, list:call("get_Count") - 1 do
            local ctx = list:call("get_Item", i)
            local q = ctx:call("get_Position")
            if (q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2 < 6.25 and ctx:call("get_IsConstOnGrapple") then grabbed = true break end
        end
        -- 10/27 user: "add a sound when I am grabbed, too much is going on and I don't hear it"
        if grabbed and not combat.grabbed then
            if RE4Access.sound then RE4Access.sound("grab") end
            say(G.combat_quiet and "Grabbed!" or "Grabbed! Press Space to knife free, or tap F fast.", true)
            combat.grabbed_at = os.clock()
        end
        -- 10/27 live (hitinfo burn=true): the real killer on the Checkpoint road
        -- was FIRE - villagers on the cliff throw fire bottles, the ground burns,
        -- -4% every 0.1 s. Buzz + "move" the moment Leon burns.
        pcall(function()
            local burn = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_IsInBurnDamage")
            if burn and not combat.burning then
                if RE4Access.sound then RE4Access.sound("grab") end
                -- 11/1: burned from 36 % to dead in 2 s standing still; turn away from the nearest fire
                local turned = false
                pcall(function()
                    local p0, best, bd = G.player_pos(), nil, 10
                    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
                    for _, en in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                        pcall(function()
                            local go = en:get_field("value"):call("get_GameObject")
                            if go:call("get_Name"):find("^gm90_037") then
                                local q = go:call("get_Transform"):call("get_Position")
                                local dd = math.sqrt((q.x - p0.x) ^ 2 + (q.z - p0.z) ^ 2)
                                if dd < bd then best, bd = q, dd end
                            end
                        end)
                    end
                    if best then
                        turned = face_point({ x = p0.x + (p0.x - best.x), y = p0.y, z = p0.z + (p0.z - best.z) }, true) and true or false
                    end
                end)
                say(turned and "Fire! Let go of L and hold W now. I turned you away." or "Fire! Let go of L and hold W now.", true)
            end
            combat.burning = burn
            if burn then
                G.fire_until = os.clock() + 1
                local nowb = os.clock()
                if nowb - (combat.burn_log or 0) > 0.5 then
                    combat.burn_log = nowb
                    local kd = {}
                    for nm, vk in pairs({ W = 0x57, A = 0x41, S = 0x53, D = 0x44, L = 0x4C, K = 0x4B, Shift = 0x10 }) do
                        if reframework:is_key_down(vk) then kd[#kd + 1] = nm end
                    end
                    log.info("[RE4Access] burning, keys down: " .. table.concat(kd, " "))
                end
            end
        end)
        -- 10/27 live: 3 deaths standing in a shut bear trap (last hit on the
        -- legs, -4% ticks, no "Caught" line because each tick is under 5%).
        -- A trap shut within 1.3 m of Leon = caught: buzz + how to get out.
        pcall(function()
            local caught
            for _, t in ipairs(scan_things(pos, 1.6)) do
                if t.name == "Bear trap" and not G.trap_live(t.go) and t.dist < 1.3 then caught = t.key end
            end
            if caught and combat.trap_caught ~= caught then
                if RE4Access.sound then RE4Access.sound("grab") end
                say("Caught in a bear trap! Tap F fast to break free, then walk on.", true)
            elseif not caught and combat.trap_caught then
                say("Out of the trap.", true)
            end
            combat.trap_caught = caught
        end)
        -- 10/27 user: "how do I know when I am free?"
        -- 11/1: in the chase "Free!" came right before Mendez's kill scene (2 of 2)
        if not grabbed and combat.grabbed and not G.is_dead and not G.in_chase then
            say(G.combat_quiet and "Free!" or "Free! Back away with S, then aim.", true)
        end
        combat.grabbed = grabbed
    end)
    if combat.hp and cur > combat.hp then combat.hurt_step = nil end
    combat.hp = cur
    -- Aiming and the aim-assist target.
    -- get_IsHolding = gun raised (live-checked 10/11; get_IsAiming stays false).
    local aiming = pc:call("get_IsHolding") and true or false
    local target = aiming and pc:call("get_AimTargetEnemy") or nil
    -- Log every change of the game's own aim state; speak it once it is steady.
    if aiming ~= combat.aiming then
        log.info(string.format("[RE4Access] game aim %s (L held %s)", aiming and "ON" or "OFF", tostring(reframework:is_key_down(0x4C))))
        combat.aim_changed = now
    end
    if combat.aim_changed and now - combat.aim_changed > 0.3 and combat.aim_said ~= aiming then
        combat.aim_said = aiming
        if not G.combat_quiet then say(aiming and "Gun up" or "Gun down", false) end
    end
    combat.aiming, combat.target = aiming, target
    -- Padlocks near you: "Padlock hit, 1 more" / "Padlock broken".
    pcall(function()
        local pos = G.player_pos()
        for _, t in ipairs(scan_things(pos, 25)) do
            if t.name == "Padlock" and t.dist <= 15 then
                local comp = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPadlock"))
                local d = comp:get_field("_CurrentDurability")
                combat.pad = combat.pad or {}
                local was = combat.pad[t.key]
                if was and d < was then
                    say(d <= 0 and "Padlock broken. Walk into the middle of the door." or ("Padlock hit, " .. d .. " more"), true)
                end
                combat.pad[t.key] = d
            end
            -- Tripwire bombs: "Bomb destroyed" when one within 25 m goes off while
            -- Leon is far enough not to be the one who walked into it.
            if t.name == "Bomb trap" then
                local live = G.trap_live(t.go)
                combat.bombs = combat.bombs or {}
                if combat.bombs[t.key] == true and not live and t.dist > 3.5 then
                    say("Tripwire bomb destroyed.", true)
                    combat.traps_seen[t.key] = true   -- not "A tripwire bomb exploded" on the next hit (10/12 PM)
                end
                combat.bombs[t.key] = live
            end
        end
    end)
    -- After a shot at a tripwire bomb: "Missed the bomb" if it is still there.
    if combat.bomb_shot and now > combat.bomb_shot.at then
        local b = combat.bomb_shot
        combat.bomb_shot = nil
        if G.trap_live(b.go) then say("Missed the bomb. Keep holding L and press K again.", true) end
    end
    -- After a shot at a bird's nest: did it fall? (10/20: no word either way)
    if combat.nest_shot and now > combat.nest_shot.at then
        local b = combat.nest_shot
        combat.nest_shot = nil
        local down = G.nest_down(b.key)
        if down == true then
            say("Hit! The nest fell. The item dropped to the ground. Press Backslash to walk to it, then press F.", true)
        elseif down == false then
            local pos = G.player_pos()
            if pos and not G.clear_shot({ x = pos.x, y = pos.y + 1.5, z = pos.z }, b.pos) then
                say("Missed. A branch is in the way from here. Let go of L, press Backslash to walk to a clear spot, then shoot again.", true)
            else
                say("Missed, the nest is still up. Keep holding L, wait for fire, press K again.", true)
            end
        end
    end
    -- Enemy health: "Hit" when it drops, "Enemy down" when it reaches zero.
    local list = cm:call("get_EnemyContextList")
    if not list then return end
    for i = 0, list:call("get_Count") - 1 do
        pcall(function()
            local ctx = list:call("get_Item", i)
            local ehp = ctx:call("get_HitPoint")
            local k = ctx:get_address()
            local v = ehp:call("get_CurrentHitPoint")
            local was = combat.enemy_hp[k]
            if was and v < was then
                if v <= 0 or not ehp:call("get_IsLive") then
                    say("Enemy down", true)
                elseif now - combat.last_hit > 0.3 then
                    combat.last_hit = now
                    if not G.combat_quiet then say("Hit", true) end
                end
            end
            combat.enemy_hp[k] = v
        end)
    end
end

-- Aim lock. While the game says Leon is aiming (L, the game's aim key), the
-- player camera is pointed at the nearest enemy that a ray from the camera can
-- reach, every frame. The camera's _Yaw is the compass heading in radians and
-- _Pitch the up/down angle (live-checked), so they can be set directly.
local AIM_HEIGHT = 1.4      -- metres above an enemy's feet: upper chest
local AIM_RANGE = 30
local aim = { target = nil, picked_at = 0, said = nil }
-- True while L (aim) is held: the route must not turn the camera then.
function G.aim_held() return reframework:is_key_down(0x4C) end

-- Line of sight from Leon's chest (not the camera: behind his shoulder it is
-- often inside a wall in small rooms). The enemy's own body may stop the ray
-- up to about a metre early, which still counts as visible.
local function visible_from(eye, t)
    local R = RE4Access.route
    if not R then return true end
    local ok, hit, d = pcall(R.cast, eye.x, eye.y, eye.z, t.x, t.y, t.z)
    if not ok or not hit then return true end
    local full = math.sqrt((t.x - eye.x) ^ 2 + (t.y - eye.y) ^ 2 + (t.z - eye.z) ^ 2)
    return d and d > full - 1.2
end

-- Lit dynamite in a villager's hand (10/12 recorder: the enemy body gets a child
-- "wp5806" = dynamite; when he lights it, "wp5806/effect_wp5806" (the fuse) appears,
-- and about 3.5 s later he throws it). Shooting it then blows it up in his hands.
local DYN_NAME, DYN_FUSE = "wp5806", "effect_wp5806"
function G.lit_dynamite(pos, range)
    local out = {}
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    local list = cm and cm:call("get_EnemyContextList")
    if not list then return out end
    for i = 0, list:call("get_Count") - 1 do
        pcall(function()
            local ctx = list:call("get_Item", i)
            local p = ctx:call("get_Position")
            local d = math.sqrt((p.x - pos.x) ^ 2 + (p.z - pos.z) ^ 2)
            if d > (range or 25) then return end
            local body = ctx:call("get_BodyGameObject")
            if not body then return end
            local c = body:call("get_Transform"):call("get_Child")
            local n = 0
            while c and n < 40 do
                n = n + 1
                if c:call("get_GameObject"):call("get_Name") == DYN_NAME then
                    local f = c:call("get_Child")
                    while f do
                        if f:call("get_GameObject"):call("get_Name") == DYN_FUSE then
                            local q = c:call("get_Position")
                            out[#out + 1] = { name = "Dynamite", pos = { x = q.x, y = q.y, z = q.z }, dist = d,
                                key = "dyn" .. tostring(ctx:get_address()), tr = c, dyn = true, ctx = ctx,
                                body = { x = p.x, y = p.y, z = p.z } }
                            return
                        end
                        f = f:call("get_Next")
                    end
                    return
                end
                c = c:call("get_Next")
            end
        end)
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- Nearest live bear trap within range that Leon can see (aim point just above it).
function G.shootable_trap(pos, range)
    local eye = { x = pos.x, y = pos.y + 1.5, z = pos.z }
    for _, t in ipairs(scan_things(pos, range or 10)) do
        if t.name == "Bear trap" and math.abs(t.pos.y - pos.y) < 3 and G.trap_live(t.go) then
            local aimp = { x = t.pos.x, y = t.pos.y + 0.15, z = t.pos.z }
            -- clear_shot counts the trap itself / the ground under it as a wall
            -- (10/12: hit 0.08 m short at 1.2 m); a hit within 0.7 m of it is fine.
            local _, d = G.clear_shot(eye, aimp)
            local full = math.sqrt((aimp.x - eye.x) ^ 2 + (aimp.y - eye.y) ^ 2 + (aimp.z - eye.z) ^ 2)
            if not d or d > full - 0.7 then
                return { name = "Bear trap", pos = aimp, dist = t.dist, key = t.key, fixed = true, go = t.go }
            end
        end
    end
end

-- "Bear trap, 6 meters, ahead right. You can shoot it: hold L, press K." once per
-- trap per minute when one comes within 8 m in view and no villager is within
-- 10 m; "Bear trap closed." when one you were told about snaps shut.
local trap_told = {}
local last_trap_tell = 0
function G.update_trap_shots(pos, now)
    if now - last_trap_tell < 0.5 then return end
    last_trap_tell = now
    for k, st in pairs(trap_told) do
        if st.go and not G.trap_live(st.go) then
            trap_told[k] = nil
            combat.traps_seen[k] = true   -- shot shut: not "Caught in a bear trap" on the next hit
            say("Bear trap closed.", true)
        elseif now - st.at > 60 then
            trap_told[k] = nil
        end
    end
    for _, e in ipairs(enemies(pos, 10)) do if math.abs(e.pos.y - pos.y) < 3 then return end end
    if (RE4Access.route and RE4Access.route.active()) or (G.timed_target and G.timed_target()) then return end
    local t = G.shootable_trap(pos, 8)
    if t and not trap_told[t.key] then
        trap_told[t.key] = { at = now, go = t.go }
        say("Bear trap, " .. describe_position(t.pos, pos, G.facing()) .. ".", false)
    end
end

-- Spoken the moment a villager lights dynamite (once per lighting).
local dyn_said = {}
local last_dyn_check = 0
local function update_dynamite(pos, now)
    if now - last_dyn_check < 0.15 then return end
    last_dyn_check = now
    local lit = {}
    for _, d in ipairs(G.lit_dynamite(pos, 25)) do
        lit[d.key] = true
        if not dyn_said[d.key] and math.abs(d.pos.y - pos.y) < 6 then
            dyn_said[d.key] = { ctx = d.ctx, at = now }
            if RE4Access.sound then RE4Access.sound("dynamite") end
            local where = describe_position(d.pos, pos, G.facing())
            say("Dynamite! " .. where .. ". Hold L, press K when I say fire.", true)
        end
    end
    -- The fuse is gone: either he died (shot) or he THREW it (10/12 recorder: the fuse
    -- child vanishes and his weapon id goes to -1 about 3.5 s after lighting). A thrown
    -- stick lands where Leon stands about 1.5 s later: run to the side.
    for k, st in pairs(dyn_said) do
        -- wait 0.3 s: when he is shot, the fuse goes before his health reads 0
        -- (10/12 PM: "Thrown!" was said, then "Enemy down" 0.13 s later)
        if not lit[k] and not st.gone then st.gone = now end
        if lit[k] then st.gone = nil end
        if st.gone and now - st.gone > 0.3 then
            dyn_said[k] = nil
            local alive = false
            pcall(function()
                local hp = st.ctx:call("get_HitPoint")
                alive = hp:call("get_CurrentHitPoint") > 0 and hp:call("get_IsLive")
            end)
            if alive and type(st) == "table" and now - st.at < 8 then
                say("Thrown! Run sideways now, hold Shift.", true)
                log.info("[RE4Access] dynamite thrown")
            elseif not alive then
                log.info("[RE4Access] dynamite man down")
            end
        end
    end
end
G.update_dynamite = update_dynamite

-- 11/2: the enemy carrying Ashley = the live enemy closest to her while she is
-- kidnapped. The speech promised L aims at him since 10/22, but nothing did: L took
-- the usual nearest target and she was carried 70 m to game over.
function G.ashley_carrier(pos)
    local out
    pcall(function()
        local a = RE4Access.ashley and RE4Access.ashley.partner and RE4Access.ashley.partner()
        if not a or not a:get_field("<IsKidnapped>k__BackingField") then return end
        local q = a:call("get_Position")
        local best = 3
        for _, e in ipairs(enemies(pos, 60)) do
            local d = math.sqrt((e.pos.x - q.x) ^ 2 + (e.pos.y - q.y) ^ 2 + (e.pos.z - q.z) ^ 2)
            if d < best then best, out = d, e end
        end
    end)
    return out
end

-- 11/8 Ch8 storeroom (Summoner room): the cult leader with the bell
-- (Ch1c0z1, weapon 5826, 4500 HP, on the far upper floor) turns the others into
-- Plaga monsters after a while. The user died twice under 8+ enemies at 3% HP.
G.SUMMONER_WEAPON = 5826
function G.summoner(pos, range)
    local best
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    local list = cm and cm:call("get_EnemyContextList")
    if not list then return nil end
    for i = 0, list:call("get_Count") - 1 do
        pcall(function()
            local ctx = list:call("get_Item", i)
            if not ctx:get_type_definition():get_name():find("^Ch1c0z1") then return end
            if ctx:get_field("<initialEquipWeaponID>k__BackingField") ~= G.SUMMONER_WEAPON then return end
            if not ctx:call("get_HitPoint"):call("get_IsLive") then return end
            local q = ctx:call("get_Position")
            local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
            if d <= (range or 50) and (not best or d < best.dist) then
                best = { name = "Enemy", pos = { x = q.x, y = q.y, z = q.z }, dist = d, key = ctx:get_address(), ctx = ctx, leader = true }
            end
        end)
    end
    return best
end

-- Spoken once when the leader comes within 45 m, and when he falls.
G.leader_told, G.leader_alive_key = {}, nil
function G.update_summoner(pos, now)
    if now - (G.leader_check_at or -10) < 0.4 then return end
    G.leader_check_at = now
    local s = G.summoner(pos, 60)
    if s then
        G.leader_alive_key = s.key
        -- 11/9 user: "I need to know by sound and verbally when he comes out
        -- of hiding". In view = clear line from Leon's eyes to his chest,
        -- 2 checks in a row (0.8 s) before it changes, so it does not flicker.
        local eye = { x = pos.x, y = pos.y + 1.4, z = pos.z }
        local seen = s.dist <= 45 and visible_from(eye, { x = s.pos.x, y = s.pos.y + AIM_HEIGHT, z = s.pos.z })
        if seen == G.leader_seen_raw then G.leader_seen_n = (G.leader_seen_n or 0) + 1 else G.leader_seen_n = 1 end
        G.leader_seen_raw = seen
        if G.leader_seen_n >= 2 and (seen and true or false) ~= (G.leader_in_view and true or false) then
            G.leader_in_view = seen
            log.info(string.format("[RE4Access] leader %s (%.1f,%.1f,%.1f) %.1f m, Leon (%.1f,%.1f,%.1f)", seen and "IN VIEW" or "hidden", s.pos.x, s.pos.y, s.pos.z, s.dist, pos.x, pos.y, pos.z))
            if seen then
                RE4Access.sound("leader")
                say("Leader in view, " .. describe_position(s.pos, pos, G.facing()) .. ". Hold L, press K.", true)
                G.leader_view_at = now
            elseif now - (G.leader_hidden_said or -10) > 5 then
                G.leader_hidden_said = now
                say("Leader hidden.", false)
            end
        end
        if not G.leader_told[s.key] then
            G.leader_told[s.key] = true
            local dy = s.pos.y - pos.y
            local up = dy > 1.5 and ", on a higher floor" or ""
            log.info(string.format("[RE4Access] summoner seen (%.1f,%.1f,%.1f) %.1f m", s.pos.x, s.pos.y, s.pos.z, s.dist))
            say("Cult leader, the one with the bell, " .. describe_position(s.pos, pos, G.facing()) .. up
                .. ". Kill him FIRST: after a while he turns the others into monsters. Hold L: I lock on him first whenever he is in view, then press K again and again."
                .. " If enemies get close, back off with S, then aim again. Heal early: at half health press I and use a First Aid Spray.", false)
        end
    elseif G.leader_alive_key then
        -- gone from the list or dead
        -- dead only when his own context says so (a reload replaces all
        -- contexts: then just forget him, no false "down")
        local dead, found = false, false
        pcall(function()
            local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
            local list = cm:call("get_EnemyContextList")
            for i = 0, list:call("get_Count") - 1 do
                local ctx = list:call("get_Item", i)
                if ctx:get_address() == G.leader_alive_key then
                    found = true
                    dead = not ctx:call("get_HitPoint"):call("get_IsLive")
                end
            end
        end)
        if not found then G.leader_alive_key = nil end
        G.leader_in_view, G.leader_seen_raw, G.leader_seen_n = nil, nil, 0
        if dead then
            G.leader_alive_key = nil
            say("The cult leader is down. Now the rest.", false)
        end
    end
end

-- 11/9 Ch8 storeroom chandelier (gm84_602 巨大シャンデリア, GmFallChandelier,
-- _Radius 3.5, lands at child FallEndPos (8.01,24.94,-3.13)). Its lever
-- gm84_603 落としシャンデリアレバー is upstairs. The pulleys have no hit zone
-- (plain colliders, checked live): only the lever drops it.
function G.chandelier_info(pos)
    local out
    for _, t in ipairs(scan_things(pos, 60)) do
        local okn, nm = pcall(function() return t.go:call("get_Name") end)
        if okn and nm then
            if nm:find("巨大シャンデリア", 1, true) then
                out = out or {}
                out.go = t.go
                pcall(function()
                    local tr = t.go:call("get_Transform"):call("get_Child")
                    while tr do
                        if tr:call("get_GameObject"):call("get_Name") == "FallEndPos" then
                            local q = tr:call("get_Position")
                            out.land = { x = q.x, y = q.y, z = q.z }
                        end
                        tr = tr:call("get_Next")
                    end
                end)
                local done = false
                pcall(function()
                    local core = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore"))
                    done = core:call("get_Context"):call("hasDoneForMap")
                end)
                pcall(function()
                    local c = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmFallChandelier"))
                    if c:get_field("_Routine") ~= 0 then done = true end
                end)
                out.done = done
            elseif nm:find("落としシャンデリアレバー", 1, true) then
                out = out or {}
                out.lever = t
            end
        end
    end
    if out and out.land and out.lever then return out end
end

function G.update_chandelier(pos, now)
    if now - (G.chand_check_at or -10) < 0.5 then return end
    G.chand_check_at = now
    local okc, c = pcall(G.chandelier_info, pos)
    if not okc or not c then return end
    if c.done then
        if not G.chand_fell_said then
            G.chand_fell_said = true
            log.info("[RE4Access] chandelier fell")
            say("The chandelier fell. Now the cult leader: press N.", false)
        end
        return
    end
    G.chand_fell_said = nil
    local ld = math.sqrt((c.lever.pos.x - pos.x) ^ 2 + (c.lever.pos.z - pos.z) ^ 2)
    if ld > 5 or math.abs(c.lever.pos.y - pos.y) > 1.5 then G.chand_under = nil return end
    local n = 0
    for _, e in ipairs(enemies(c.land, 3.5)) do
        if math.abs(e.pos.y - c.land.y) < 1.5 then n = n + 1 end
    end
    if n ~= (G.chand_under or 0) then
        G.chand_under = n
        log.info(string.format("[RE4Access] chandelier: %d enemies under it", n))
        if n >= 2 then
            say(n .. " enemies under the chandelier. Pull the lever NOW: face it and press F.", true)
        elseif n == 1 then
            say("1 enemy under the chandelier. Wait for more if you can.", false)
        end
    end
end

-- 11/9 Ch8: explosive oil drums (gm84_575 火薬樽, HitController). One sits
-- below the cult leader's platform (2.7,24.9,-4.6), ~3 m from him, shootable
-- from ~50 ground-floor spots 6-15 m away (ray test). L aims at a drum when the
-- leader or 2+ enemies stand within 3.5 m of it, it is in clear view, 5-30 m
-- away, and no enemy is on Leon. Whether the blast reaches the leader: unproven.
function G.storeroom_drum(pos, which)
    for _, t in ipairs(scan_things(pos, 45)) do
        if t.name == "Oil Drum" and not (G.gimmick_done and G.gimmick_done(t.go)) then
            local okn, nm = pcall(function() return t.go:call("get_Name") end)
            if okn and nm == "gm84_575_00_0_火薬樽(" .. which .. ")" then return t end
        end
    end
end
function G.drum_target(pos)
    local eye = { x = pos.x, y = pos.y + 1.4, z = pos.z }
    local function sees(ap)
        local _, d = G.clear_shot(eye, ap)
        local full = math.sqrt((ap.x - eye.x) ^ 2 + (ap.y - eye.y) ^ 2 + (ap.z - eye.z) ^ 2)
        return not d or d > full - 0.7
    end
    local function as_target(t, why)
        return { name = "Oil drum", pos = { x = t.pos.x, y = t.pos.y + 0.5, z = t.pos.z }, dist = t.dist, key = t.key, fixed = true, go = t.go, why = why }
    end
    -- an enemy right on Leon (under 2 m) comes first
    for _, e in ipairs(enemies(pos, 2)) do
        if math.abs(e.pos.y - pos.y) < 1.5 then return nil end
    end
    -- a drum you picked in the list (bracket keys): L aims at it
    if selected and (selected.drum or selected.name == "Oil Drum") and selected.go and not (G.gimmick_done and G.gimmick_done(selected.go)) then
        local ap = { x = selected.pos.x, y = selected.pos.y + 0.5, z = selected.pos.z }
        if sees(ap) then
            local d = math.sqrt((ap.x - pos.x) ^ 2 + (ap.z - pos.z) ^ 2)
            return { name = "Oil drum", pos = ap, dist = d, key = selected.key, fixed = true, go = selected.go, why = ", the one you picked" }
        end
    end
    local leader = G.summoner(pos, 60)
    local best, best_score
    for _, t in ipairs(scan_things(pos, 40)) do
        if t.name == "Oil Drum" and t.dist >= 5 and not (G.gimmick_done and G.gimmick_done(t.go)) then
            local ap = { x = t.pos.x, y = t.pos.y + 0.5, z = t.pos.z }
            local n, with_leader = 0, false
            for _, e in ipairs(enemies(ap, 3.8)) do
                local d3 = math.sqrt((e.pos.x - ap.x) ^ 2 + (e.pos.y + 1 - ap.y) ^ 2 + (e.pos.z - ap.z) ^ 2)
                if d3 < 3.8 then
                    n = n + 1
                    if leader and e.key == leader.key then with_leader = true end
                end
            end
            if (with_leader or n >= 2) and sees(ap) then
                local score = n + (with_leader and 10 or 0)
                if not best_score or score > best_score then
                    best_score = score
                    best = as_target(t, with_leader and " next to the cult leader" or (" with " .. n .. " enemies next to it"))
                end
            end
        end
    end
    return best
end

G.WINDOW_FIGHT_SPOT = { x = 33.85, y = 25.94, z = -0.76 }   -- Continue spot, ~11 m from the window
G.WINDOW_POS = { x = 22.66, y = 27.0, z = 1.10 }
-- Cultists still alive in the room (not the leader, not the sleeping armour suits Ch1d6).
function G.cultists_left(pos)
    local n = 0
    pcall(function()
        local list = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
        for i = 0, list:call("get_Count") - 1 do
            local c = list:call("get_Item", i)
            if c:get_type_definition():get_name():find("^Ch1c0z1") and c:call("get_HitPoint"):call("get_IsLive")
                and c:get_field("<initialEquipWeaponID>k__BackingField") ~= G.SUMMONER_WEAPON then
                local q = c:call("get_Position")
                if math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) < 60 then n = n + 1 end
            end
        end
    end)
    return n
end
-- Window fight: "N cultists left" after each kill, heal at half health, "press N" at 2 left.
function G.update_window_fight(pos, now)
    if now - (G.wf_check_at or -10) < 0.5 then return end
    G.wf_check_at = now
    local s = G.summoner(pos, 60)
    if not s then G.wf_left = nil return end
    local left = G.cultists_left(pos)
    if G.wf_left and left < G.wf_left then
        log.info("[RE4Access] window fight: " .. left .. " cultists left")
        if left <= 2 then
            say(left .. " cultists left. Now the cult leader.", false)
        else
            say(left .. " cultists left.", false)
        end
    end
    G.wf_left = left
    -- heal reminder at half health, at most every 20 s
    local hp, mx
    pcall(function()
        local h = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_HitPoint")
        hp, mx = h:call("get_CurrentHitPoint"), h:call("get_DefaultHitPoint")
    end)
    -- not while paused or on the game over screen (11/11: repeated over and over while paused)
    if hp and mx and mx > 0 and hp > 0 and hp / mx < 0.5 and now - (G.wf_heal_at or -100) > 20
        and not G.is_paused() and G.state_text == "In control" and not G.is_dead then
        G.wf_heal_at = now
        say("Half health. Heal now: press I, then a First Aid Spray.", true)
    end
end

G.SNEAK_WPS = {
    { x = 19.3, y = 24.94, z = -1.0 }, { x = 16.8, y = 24.94, z = -2.4 }, { x = 16.8, y = 24.94, z = -6.1 },
    { x = 17.2, y = 24.94, z = -9.9 }, { x = 15.1, y = 24.94, z = -10.0 }, { x = 12.7, y = 24.94, z = -9.8 },
    { x = 10.9, y = 24.94, z = -10.2 }, { x = 9.5, y = 24.94, z = -11.4 }, { x = 7.2, y = 24.94, z = -12.2 },
    { x = 5.0, y = 24.94, z = -12.7, say = "The back stairs are just ahead." },
    { x = 4.7, y = 24.94, z = -14.8 },
    { x = 8.0, y = 26.0, z = -15.0, say = "Up the stairs." }, { x = 11.0, y = 27.0, z = -15.0 },
    { x = 14.5, y = 28.94, z = -15.0, say = "Upstairs. Now along the walkway." },
    { x = 15.7, y = 28.94, z = -12.0 }, { x = 15.7, y = 28.94, z = -9.6 },
    { x = 13.0, y = 28.94, z = -9.4, say = "Almost at the lever. A crossbow cultist stands 4 meters past it; he did not notice me." },
}
-- While sneaking: crouch reminder, "suspicious" / "spotted" warnings (enemy
-- context <TargetFindState>: 0 unaware, 1 suspicious, 2 alerted; read live 11/9).
function G.update_sneak(pos, now)
    if not G.sneak_on then return end
    if now - (G.sneak_check_at or -10) < 0.4 then return end
    G.sneak_check_at = now
    local worst = 0
    pcall(function()
        local list = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
        for i = 0, list:call("get_Count") - 1 do
            local c = list:call("get_Item", i)
            if c:call("get_HitPoint"):call("get_IsLive") then
                local f = c:get_field("<TargetFindState>k__BackingField") or 0
                if f > worst then worst = f end
            end
        end
    end)
    if worst ~= (G.sneak_worst or 0) then
        G.sneak_worst = worst
        log.info("[RE4Access] sneak: awareness " .. worst .. string.format(" at (%.1f,%.1f,%.1f)", pos.x, pos.y, pos.z))
        if worst == 1 then say("Careful! Someone is suspicious. Stop and stay still.", true)
        elseif worst >= 2 then
            G.sneak_on = nil
            say("You were spotted! Everyone is coming. Hold L and press K, back off with S, heal at half health.", true)
            return
        else say("Calm again. Keep going with W.", false) end
    end
    if pos.x < 23 and now - (G.crouch_said or -100) > 12 then
        local cr = true
        pcall(function() cr = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_IsCrouch") end)
        if not cr then
            G.crouch_said = now
            say("Press E to crouch.", false)
        end
    end
end

local function pick_aim_target(pos)
    -- Lit dynamite comes first: shoot it before he throws it.
    local okd, dyn = pcall(G.lit_dynamite, pos, 25)
    if okd and dyn and dyn[1] then return dyn[1] end
    -- Ashley carried off: L aims at her carrier, unless another enemy is right on Leon.
    local carrier = G.ashley_carrier(pos)
    if carrier and carrier.dist <= AIM_RANGE then
        local on_me = false
        for _, e in ipairs(enemies(pos, 1.5)) do
            if e.key ~= carrier.key and math.abs(e.pos.y - pos.y) < 1.5 then on_me = true break end
        end
        if not on_me then
            return { name = "Enemy", pos = carrier.pos, dist = carrier.dist, key = carrier.key, ctx = carrier.ctx, picked = true, carrier = true }
        end
    end
    -- 10/14: an enemy you picked in the Enemies list is the one L aims at
    -- (unless another one is right on you, under 3 m).
    if selected and selected.ctx then
        local sel
        pcall(function()
            local live = true
            pcall(function() live = selected.ctx:call("get_HitPoint"):call("get_IsLive") end)
            if live == false then return end
            local q = selected.ctx:call("get_Position")
            local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
            if d > AIM_RANGE then return end
            for _, e in ipairs(enemies(pos, 3)) do
                if e.ctx ~= selected.ctx and math.abs(e.pos.y - pos.y) < 1.5 then return end
            end
            sel = { name = "Enemy", pos = { x = q.x, y = q.y, z = q.z }, dist = d, key = selected.key, ctx = selected.ctx, picked = true }
        end)
        if sel then return sel end
    end
    -- An item you picked that hangs up high (bird's nest, shoot-down object) comes
    -- before bear traps (10/17: L kept aiming at a trap 5 m away, not the Sapphire nest).
    if selected and selected.shoot then
        local sp = selected.shoot
        local d = math.sqrt((sp.x - pos.x) ^ 2 + (sp.z - pos.z) ^ 2)
        if d < (sp.range or 15) then   -- 11/21 Ch10 low counterweight: 20 m
            return { name = sp.label or sp.what == "stick" and "Stick" or sp.what == "lantern" and "Lantern" or "Bird's nest", pos = { x = sp.x, y = sp.y, z = sp.z }, dist = d, key = selected.key, fixed = true, go = selected.go }
        end
    end
    -- 11/9 Ch8: an oil drum next to the leader or a group comes first
    do
        local okd2, dr = pcall(G.drum_target, pos)
        if okd2 and dr then return dr end
    end
    -- 11/8 Ch8: the cult leader comes before nearer cultists when he is in clear
    -- view, unless an enemy is right on Leon (under 3 m on his floor).
    do
        local okl, s = pcall(G.summoner, pos, 45)
        if okl and s then
            local on_me = false
            -- 11/11 user: "I need him to be the focus when he is visible": only an
            -- enemy right on Leon (1.6 m) beats him now (was 3 m: in crowds L never switched)
            for _, e in ipairs(enemies(pos, 1.6)) do
                if e.key ~= s.key and math.abs(e.pos.y - pos.y) < 1.5 then on_me = true break end
            end
            local eye0 = { x = pos.x, y = pos.y + 1.4, z = pos.z }
            local t = { x = s.pos.x, y = s.pos.y + AIM_HEIGHT, z = s.pos.z }
            if not on_me and visible_from(eye0, t) then return s end
        end
    end
    -- A live bear trap within 10 m in clear view, while no villager is within 8 m:
    -- shooting it snaps it shut (10/12: a lane trap kept blocking the way).
    -- 10/27 Checkpoint: L locked on a trap while villagers rushed in from past
    -- 8 m and Ashley was grabbed; the user died twice. Traps only when no
    -- villager is within 25 m and Ashley is not carried off. Any height (10/27
    -- live: the attackers stood 6-8 m higher up the slope and didn't count).
    local okt, trap = pcall(G.shootable_trap, pos, 10)
    if okt and trap then
        local close_enemy = #enemies(pos, 25) > 0
        pcall(function()
            local ac = RE4Access.ashley and RE4Access.ashley.partner and RE4Access.ashley.partner()
            if ac and ac:get_field("<IsKidnapped>k__BackingField") then close_enemy = true end
        end)
        if not close_enemy then return trap end
    end
    local eye = { x = pos.x, y = pos.y + 1.4, z = pos.z }
    -- A clear line that may end ON the target itself (its own collision stops the
    -- ray up to 1 m early: 10/12 PM the nest failed this and the aim went to a
    -- villager 15 m away behind cover).
    local function sees(t)
        local _, d = G.clear_shot(eye, t)
        local full = math.sqrt((t.x - eye.x) ^ 2 + (t.y - eye.y) ^ 2 + (t.z - eye.z) ^ 2)
        return not d or d > full - 1.0
    end
    local near_enemy = false
    for _, e in ipairs(enemies(pos, 6)) do if math.abs(e.pos.y - pos.y) < 2 then near_enemy = true break end end
    -- You picked a bird's nest: aim at it unless a villager is within 6 m.
    if selected and selected.item and tostring(selected.name):find("bird's nest", 1, true) and selected.dist then
        local d = math.sqrt((selected.pos.x - pos.x) ^ 2 + (selected.pos.z - pos.z) ^ 2)
        if not near_enemy and d < 15 and sees(selected.pos) then
            local sp = selected.shoot or selected.pos
            return { name = "Bird's nest", pos = { x = sp.x, y = sp.y, z = sp.z }, dist = d, key = selected.key, fixed = true, go = selected.go }
        end
    end
    -- A padlock within 8 m in view comes before far villagers and tripwire bombs
    -- (10/12 PM: at the boathouse padlock spot L aimed at the bomb inside, 14 m).
    if not near_enemy then
        for _, t in ipairs(scan_things(pos, 8)) do
            if t.name == "Padlock" and math.abs(t.pos.y - pos.y) < 4 then
                local c
                pcall(function()
                    local comp = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPadlock"))
                    if comp:get_field("_CurrentDurability") <= 0 then return end
                    local q = G.padlock_point(t.go, comp)
                    c = { x = q.x, y = q.y, z = q.z }
                end)
                if c and sees(c) then return { name = "Padlock", pos = c, dist = t.dist, key = t.key, fixed = true, go = t.go } end
            end
        end
        -- A tripwire bomb within 12 m in clear view comes before far villagers
        -- (10/12 PM: at the boathouse bomb spot L locked a villager 12 m away behind
        -- cover and the shot went to him; the bomb stayed live).
        for _, b in ipairs(G.laser_bombs(pos, 12)) do
            local ap = G.bomb_aim_point(b.go)
            if ap and sees(ap) then
                return { name = "Tripwire bomb", pos = ap, dist = b.dist, key = b.key, fixed = true, go = b.go }
            end
        end
    end
    for _, e in ipairs(enemies(pos, AIM_RANGE)) do
        local t = { x = e.pos.x, y = e.pos.y + AIM_HEIGHT, z = e.pos.z }
        -- Very close enemies on your floor are always taken; others need a clear line
        -- (an enemy upstairs behind a wall must not steal the aim).
        local dy = math.abs(e.pos.y - pos.y)
        if (e.dist < 4 and dy < 1.5) or (dy < 5 and visible_from(eye, t)) then return e end
    end
    -- Enemies you can't see clearly (huts, fences): the nearest within 15 m on
    -- about your level, so L never says "no enemy" while you are being attacked.
    -- 11/9 Ch8: "Locked 13, cover" on an enemy behind the wall, every shot hit
    -- the wall. In the cult leader's room only enemies within 6 m count.
    local hid_range = 15
    pcall(function() if G.summoner(pos, 60) then hid_range = 6 end end)
    for _, e in ipairs(enemies(pos, hid_range)) do
        if math.abs(e.pos.y - pos.y) < 3 then e.hidden = true return e end
    end
    -- A tripwire bomb within 15 m: shoot it from a distance.
    for _, b in ipairs(G.laser_bombs(pos, 25)) do   -- 25 m: the fishing-village bomb is 18 m from the autosave
        if not sees(G.bomb_aim_point(b.go) or b.a) then goto next_bomb end
        local c = b.a
        pcall(function()
            -- the game's own aim-assist point on the bomb (child of the Sender)
            local tr = b.go:call("getComponent(System.Type)", t_bomb):get_field("_Sender"):call("get_Transform")
            local q = tr:call("get_Position")
            local ch = tr:call("get_Child")
            while ch do
                if ch:call("get_GameObject"):call("get_Name") == "AimAssistPointObj" then q = ch:call("get_Position") break end
                ch = ch:call("get_Next")
            end
            c = { x = q.x, y = q.y, z = q.z }
        end)
        do return { name = "Tripwire bomb", pos = c, dist = b.dist, key = b.key, fixed = true, go = b.go } end
        ::next_bomb::
    end
    -- A bird's nest holding an item, within 15 m and in clear view: shoot it down.
    for _, it in ipairs(items(pos, 15)) do
        local sp = it.shoot or it.pos
        if it.inside and it.name:find("in a bird's nest", 1, true) and G.clear_shot(eye, sp) then
            return { name = "Bird's nest", pos = { x = sp.x, y = sp.y, z = sp.z }, dist = it.dist, key = it.key, fixed = true, go = it.go }
        end
    end
    -- No enemy: a padlock within 12 m (doors locked with a padlock are opened by
    -- shooting or slashing the lock). Aimed at the lock itself, not chest height.
    -- Aimed at the lock's own centre (GmPadlock._CenterObj), the actual target.
    for _, t in ipairs(scan_things(pos, 12)) do
        if t.name == "Padlock" and math.abs(t.pos.y - pos.y) < 4 then
            local c = t.pos
            pcall(function()
                local comp = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPadlock"))
                if comp:get_field("_CurrentDurability") <= 0 then c = nil return end
                local q = G.padlock_point(t.go, comp)
                c = { x = q.x, y = q.y, z = q.z }
            end)
            -- Only when it is really in view and close enough to hit (no aiming through walls).
            local rays_work = RE4Access.route and RE4Access.route.cast(pos.x, pos.y + 1.8, pos.z, pos.x, pos.y - 1, pos.z) ~= nil
            local in_view = c and t.dist <= 8
            if in_view and rays_work then
                local hit, d = RE4Access.route.cast(eye.x, eye.y, eye.z, c.x, c.y, c.z)
                local full = math.sqrt((c.x - eye.x) ^ 2 + (c.y - eye.y) ^ 2 + (c.z - eye.z) ^ 2)
                in_view = (not hit) or (d and d > full - 0.6)
            end
            if in_view then return { name = "Padlock", pos = c, dist = t.dist, key = t.key, fixed = true, go = t.go } end
        end
    end
    return nil
end

G.pick_aim_target = function(pos) return pick_aim_target(pos) end
function G.select(t) selected = t end   -- developer channel (10/20 boat tests)

local function aim_lock_frame(now)
    local cm = sdk.get_managed_singleton("chainsaw.CharacterManager")
    local pc = cm and cm:call("getPlayerContextRef")
    local aiming = pc and pc:call("get_IsHolding")
    -- Paused (pause menu open, e.g. after switching windows): keys do nothing in
    -- the game, so say so instead of talking about targets.
    local paused = false
    pcall(function() paused = sdk.get_managed_singleton("chainsaw.GuiManager"):call("get_hasOccupiedPauseMenuSystemLock") end)
    if paused then
        local l_now = reframework:is_key_down(0x4C)
        
        aim.l_was_paused = l_now
        aim.target, aim.said, aim.started = nil, nil, nil
        aim.settled, aim.frozen, aim.fire_said = nil, nil, nil
        return
    end
    aim.l_was_paused = false
    -- Diagnostics + help: K presses, aim ending, empty gun.
    local l_down = reframework:is_key_down(0x4C)
    local k_down = reframework:is_key_down(0x4B)
    if l_down and not aim.l_was then aim.l_since = now end
    aim.l_was = l_down
    if k_down and not aim.k_was then
        local shoot_ok, dry = false, false
        pcall(function() shoot_ok = pc:call("get_IsShootEnable") dry = pc:call("get_IsShootDryFire") end)
        log.info(string.format("[RE4Access] K pressed: aiming %s, L held %s, can shoot %s, target %s",
            tostring(aiming), tostring(l_down), tostring(shoot_ok), aim.target and string.format("%.1f m", aim.target.dist) or "none"))
        -- 11/2: L tapped with K: the gun was not up yet, no shot, no word. L must stay down.
        if G.on_cannon then
            -- 11/2: K fires the cannon; the gun hints are wrong here.
        elseif l_down and not shoot_ok and now - (aim.l_since or now) < 1.0 then
            if now - (aim.notready_at or -10) > 2 then
                aim.notready_at = now
                say("Not ready. Keep holding L.", true)
            end
        -- once every 6 s at most (10/12: said 20 times in a row)
        elseif not aiming and not reframework:is_key_down(0x20) and now - (aim.hint_at or -10) > 6 then
            aim.hint_at = now
            -- 10/27 Checkpoint: L and K both held, the game would not aim (Leon
            -- hit or grabbed, enemy 0.3 m away); "Hold L" only confused the user.
            if l_down then
                if not G.combat_quiet then say("Can't aim right now, Leon is being hit or grabbed. If grabbed press Space. Then back away with S and aim again.", true) end
            else
                if not G.combat_quiet then say("Hold L while you press K", true) end
            end
        end
        if aiming and aim.target and aim.target.name == "Tripwire bomb" then
            combat.bomb_shot = { go = aim.target.go, at = now + 0.8 }
        end
        if aiming and aim.target and aim.target.name == "Bird's nest" then
            combat.nest_shot = { key = aim.target.key, pos = aim.target.pos, at = now + 1.2 }
        end
    end
    aim.k_was = k_down
    pcall(function()
        if pc:call("get_IsShootDryFire") and not aim.dry_said then
            aim.dry_said = true
            say(G.ammo_advice(), true)
        elseif not pc:call("get_IsShootDryFire") then
            aim.dry_said = false
        end
    end)
    if not l_down then
        if aim.started then
            log.info(string.format("[RE4Access] aim end after %.1f s, L held %s", now - aim.started, tostring(l_down)))
            if l_down then say("Aim interrupted", true) end
        end
        aim.target, aim.said, aim.started = nil, nil, nil
        aim.settled, aim.frozen, aim.fire_said = nil, nil, nil
        return
    end
    aim.started = aim.started or now
    local mc = main_camera_controller()
    local pcc = player_camera()
    local pos = G.player_pos()
    if not mc or not pcc or not pos then return end
    local cam = mc:call("get_CameraPosition")
    -- Re-pick the target 5 times a second (the closest one may change or die).
    if not aim.target or now - aim.picked_at > 0.2 then
        aim.picked_at = now
        local prev = aim.target
        aim.target = pick_aim_target(pos)
        -- Stay on a bear trap once locked, until it closes or dynamite is lit (10/12:
        -- the pick flipped trap <-> villager 26 m away five times a second and the
        -- shot went to the villager).
        if prev and prev.name == "Bear trap" and prev.go and G.trap_live(prev.go)
            and not (aim.target and aim.target.dyn)
            and #enemies(pos, 25) == 0 then   -- a villager coming in beats the trap (10/27)
            aim.target = prev
        end
        local key = aim.target and aim.target.key or false
        if key ~= aim.said then
            aim.said = key
            if aim.target then
                if aim.target.fixed then
                    local what = aim.target.name == "Oil drum" and ("the oil drum" .. (aim.target.why or "")) or aim.target.name == "Tripwire bomb" and "the tripwire bomb" or aim.target.name == "Bird's nest" and "the bird's nest" or aim.target.name == "Stick" and "the stick holding the well lid open" or aim.target.name == "Counterweight" and "the counterweight" or aim.target.name == "Lantern" and "the lantern over the well" or aim.target.name == "Bear trap" and "the bear trap" or tostring(aim.target.name):find(" gong$") and ("the " .. aim.target.name) or "the padlock"
                    local tip = aim.target.dist < 3 and " Step back a few steps first, it aims better from 3 to 6 meters." or ""
                    if aim.target.name == "Tripwire bomb" and aim.target.dist < 4 then tip = " Too close: back off first, the blast hurts." end
                    if aim.target.name == "Tripwire bomb" and not G.clear_shot({ x = pos.x, y = pos.y + 1.5, z = pos.z }, aim.target.pos) then
                        -- once a minute (10/12: said on nearly every L press)
                        if now - (aim.bomb_block_at or -100) > 60 then
                            aim.bomb_block_at = now
                            say("Something is in the way of the bomb from here.", true)
                        end
                        goto announced
                    end
                    if aim.target.name == "Bird's nest" then
                        local eye = { x = pos.x, y = pos.y + 1.5, z = pos.z }
                        local full = math.sqrt((aim.target.pos.x - eye.x) ^ 2 + (aim.target.pos.y - eye.y) ^ 2 + (aim.target.pos.z - eye.z) ^ 2)
                        local _, d = G.clear_shot(eye, aim.target.pos)
                        if d and d < full - 0.5 then
                            say("A branch is in the way of the nest from here, shots will miss. Let go of L and press Backslash: I walk you to a clear spot.", true)
                            goto announced
                        end
                    end
                    say(string.format("Aiming at %s, %d meters. Keep holding L; press K when I say fire.%s", what, math.floor(aim.target.dist + 0.5), tip), true)
                elseif aim.target.dyn then
                    say(string.format("Aiming at the dynamite man, %d meters. Wait for fire.", math.floor(aim.target.dist + 0.5)), true)
                    aim.dyn_on, aim.dyn_fire = nil, nil
                elseif aim.target.hidden then
                    if not G.combat_quiet then say(string.format("Locked, %d meters, partly behind cover. Keep holding L, press K.", math.floor(aim.target.dist + 0.5)), true) end
                else
                    -- 11/2: "Locked 21, Locked 22, Locked 23" on each L press at the same enemy
                    local same = aim.lock_key == aim.target.key and now - (aim.lock_at or -10) < 8
                    aim.lock_key, aim.lock_at = aim.target.key, now
                    if not same and not G.combat_quiet then
                        if aim.target.leader then RE4Access.sound("leader") say("On the leader! K, K, K.", true)
                        elseif aim.target.carrier then say("Locked on her carrier. Keep holding L. Press K when I say ready.", true)
                        elseif aim.target.leader then say(string.format("Locked on the cult leader, %d meters. Keep holding L, press K again and again.", math.floor(aim.target.dist + 0.5)), true)
                        else say(string.format("Locked, %d meters. Keep holding L, press K.", math.floor(aim.target.dist + 0.5)), true) end
                    end
                end
            else
                say("No enemy in sight", true)
            end
            ::announced::
        end
    end
    local e = aim.target
    if not e then return end
    -- Follow the enemy as it moves (positions are re-read from the live context).
    local tx, ty, tz = e.pos.x, e.pos.y + (e.fixed and 0 or AIM_HEIGHT), e.pos.z
    pcall(function()
        local cm2 = sdk.get_managed_singleton("chainsaw.CharacterManager")
        local list = cm2:call("get_EnemyContextList")
        for i = 0, list:call("get_Count") - 1 do
            local ctx = list:call("get_Item", i)
            if ctx:get_address() == e.key then
                local q = ctx:call("get_Position")
                tx, ty, tz = q.x, q.y + AIM_HEIGHT, q.z
                break
            end
        end
    end)
    -- Dynamite: aim at the CHEST of the villager holding it, not the stick (10/12 PM:
    -- every shot at the small moving stick 13-15 m away missed). A hit on him while
    -- he holds lit dynamite kills him and the dynamite goes off in his hands.
    if e.dyn then
        pcall(function() local q = e.ctx:call("get_Position") tx, ty, tz = q.x, q.y + 1.3, q.z end)
    end
    -- Aim from the camera actually drawn: while the gun is up it sits further over
    -- the shoulder than get_CameraPosition, and from that wrong spot the shot passed
    -- beside small targets (10/12: five misses on a tripwire bomb at 10-13 m).
    pcall(function()
        local rc = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform"):call("get_Position")
        if rc and (math.abs(rc.x) + math.abs(rc.z)) > 0.01 and (rc.x - pos.x) ^ 2 + (rc.z - pos.z) ^ 2 < 25 then cam = rc end
    end)
    local dx, dy, dz = tx - cam.x, ty - cam.y, tz - cam.z
    local yaw = math.atan(dx, dz)                                -- heading in radians
    local pitch = math.atan(dy, math.sqrt(dx * dx + dz * dz))
    -- Closed loop on the drawn camera: measure where its centre (the crosshair)
    -- really points and correct the remaining error, so small targets like
    -- tripwire bombs are hit too (10/12: still missing after the camera fix).
    -- The camera looks along its local -Z or +Z; the one near the wanted heading
    -- is taken. Correction builds up while the same target is held.
    if aim.corr_key ~= e.key then aim.corr_key, aim.cy, aim.cp = e.key, 0, 0 end
    local err_y, err_p
    pcall(function()
        local tr = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
        local q = tr:call("get_Rotation")
        local best
        for _, sgn in ipairs({ -1, 1 }) do
            local f = rotate(q, { x = 0, y = 0, z = sgn })
            local h = math.atan(f.x, f.z)
            local dh = (h - yaw + math.pi) % (2 * math.pi) - math.pi
            if not best or math.abs(dh) < math.abs(best.dh) then best = { dh = dh, f = f } end
        end
        if best and math.abs(best.dh) < math.rad(25) then
            local fp = math.asin(math.max(-1, math.min(1, best.f.y)))
            err_y = -best.dh
            err_p = pitch - fp
            -- Gentle: 0.5 per frame wound up to the 11 deg limit and swung the aim
            -- 11 deg off target (10/12 PM log, padlock + nest misses).
            if now - (aim.started or now) > 0.25 then
                aim.cy = aim.cy + err_y * 0.08
                aim.cp = aim.cp + err_p * 0.08
                aim.cy = math.max(-0.09, math.min(0.09, aim.cy))
                aim.cp = math.max(-0.09, math.min(0.09, aim.cp))
            end
        end
    end)
    -- Fixed targets (bombs, padlocks): once the crosshair sits on the target, stop
    -- moving the camera so the game's reticle can tighten (it spreads while the
    -- aim moves; 10/12: error 0.01 deg at 15 m and still every shot missed), then
    -- say "Steady. Fire."
    if e.fixed and err_y and math.abs(err_y) < math.rad(0.5) and math.abs(err_p) < math.rad(0.5) then
        aim.settled = aim.settled or now
    elseif not (e.fixed and aim.frozen and err_y and math.abs(err_y) < math.rad(1.5) and math.abs(err_p) < math.rad(1.5)) then
        aim.settled, aim.frozen, aim.fire_said = nil, nil, nil
    end
    if aim.settled and now - aim.settled > 0.25 then aim.frozen = true end
    if aim.frozen and not aim.fire_said and now - aim.settled > 1.2 then
        aim.fire_said = true
        say("Steady. Fire.", true)
    end
    -- Dynamite man: "Fire!" once the crosshair has been on his chest for 0.3 s and the
    -- gun can shoot (10/12 PM log: K came 0.3 s after L, before the gun was up or on him).
    if e.dyn and not aim.dyn_fire then
        local on = err_y and math.abs(err_y) < math.rad(2) and math.abs(err_p) < math.rad(2)
        local can = false
        pcall(function() can = pc:call("get_IsShootEnable") end)
        if on and can then
            aim.dyn_on = aim.dyn_on or now
            if now - aim.dyn_on > 0.3 then aim.dyn_fire = true say("Fire!", true) end
        else
            aim.dyn_on = nil
        end
    end
    if e.carrier then
        local on = err_y and math.abs(err_y) < math.rad(3) and math.abs(err_p) < math.rad(3)
        local can = false
        pcall(function() can = pc:call("get_IsShootEnable") end)
        if on and can and now - (aim.ready_at or -10) > 1.5 then
            aim.ready_at = now
            say("Ready. K.", true)
        end
    end
    if not aim.frozen then
        pcc:set_field("_Yaw", YAW_SIGN * (yaw + (aim.cy or 0)))
        pcc:set_field("_Pitch", pitch + (aim.cp or 0))
    end
    if not aim.logged or now - aim.logged > 1 then
        aim.logged = now
        log.info(string.format("[RE4Access] aim lock: target %.1f m, yaw %.1f pitch %.1f, now yaw %.1f pitch %.1f, cam error yaw %s pitch %s, corr %.2f %.2f",
            e.dist, math.deg(yaw), math.deg(pitch), math.deg(pcc:get_field("_Yaw")), math.deg(pcc:get_field("_Pitch")),
            err_y and string.format("%.2f", math.deg(err_y)) or "?", err_p and string.format("%.2f", math.deg(err_p)) or "?",
            math.deg(aim.cy or 0), math.deg(aim.cp or 0)))
    end
end

-- Knife help: Space (the game's knife key) first turns Leon to the nearest
-- enemy within 4 m, so the slash goes the right way.
local function knife_face()
    local pos = G.player_pos()
    if not pos then return end
    -- A padlock within reach comes first (slash it off a door).
    for _, t in ipairs(scan_things(pos, 2.5)) do
        if (t.name == "Padlock" or (t.name == "Glass Box" and G.glass_intact and G.glass_intact(t.go))) and math.abs(t.pos.y - pos.y) < 2 then
            face_point(t.pos, false, true)
            return
        end
    end
    -- Otherwise the nearest enemy on your floor that you can actually see.
    local eye = { x = pos.x, y = pos.y + 1.4, z = pos.z }
    for _, e in ipairs(enemies(pos, 4)) do
        if math.abs(e.pos.y - pos.y) < 1.5 and visible_from(eye, { x = e.pos.x, y = e.pos.y + 1.2, z = e.pos.z }) then
            face_point(e.pos, false, true)
            return
        end
    end
end

-- New pickups appearing near you (enemies drop ammo, money, herbs).
local drops = { known = nil, last = 0 }
local function update_drops(pos, now)
    if now - drops.last < 0.5 then return end
    drops.last = now
    local list = items(pos, 15)
    if not drops.known then
        drops.known = {}
        for _, t in ipairs(items(pos, 100000)) do drops.known[t.key] = true end
        return
    end
    for _, t in ipairs(list) do
        if not drops.known[t.key] then
            drops.known[t.key] = true
            if t.dist < 10 and not t.name:find(", in a ") then
                say("Dropped: " .. t.name .. ", " .. describe_position(t.pos, pos, G.facing()), false)
            end
        end
    end
end

local function say_health()
    local ok, text = pcall(function()
        local pc = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef")
        local hp = pc:call("get_HitPoint")
        local cur, max = hp:call("get_CurrentHitPoint"), hp:call("get_DefaultHitPoint")
        local pct = math.floor(cur * 100 / max + 0.5)
        local note = pct <= 35 and ". Low, heal soon." or (pct <= 70 and ". Hurt." or "")
        return "Health " .. pct .. " percent" .. note
    end)
    say(ok and text or "Health unknown")
end

function G.no_route_hint(goal)
    local pos = G.player_pos()
    if not pos or not goal then return "" end
    local dy = goal.y - pos.y
    -- Far away, a height difference is just hills, not "a higher floor" (10/14:
    -- crank stand 50 m off, 2.5 m higher -> sent the user up a useless ladder).
    if math.sqrt((goal.x - pos.x) ^ 2 + (goal.z - pos.z) ^ 2) > 20 then dy = 0 end
    local hint = ""
    -- Shut in a corner whose way out is a fallen shelf (10/18, behind the church)
    local oksh, sh = pcall(G.shelf_step, pos)
    if oksh and sh then
        selected = sh
        return ". First push over the fallen shelf " .. describe_position(sh.face, pos, G.facing()) .. ", it opens the way out. Press N to walk there"
    end
    -- a closed-off corner whose way out is a fallen shelf (behind the church, 10/18)
    for _, t in ipairs(scan_things(goal, 18)) do
        if t.name == "Fallen shelf" and not G.gimmick_done(t.go) then
            return ". It is in a closed-off corner. The way in is a jump down from the roof above it; once inside, the fallen shelf there opens the way back out"
        end
    end
    if G.behind_closed_bars(goal, 12) then
        return ". It is behind iron bars that open later in the story. Skip it for now, press N for the way on"
    end
    -- A closed-for-now gate counts only when it is next to the goal (10/18: the
    -- church bars were blamed for every item in a corner they had nothing to do with).
    for _, t in ipairs(doors_near(goal, 10)) do
        if t.name == "Gate" and gate_asleep(t.go) then
            t.dist = math.sqrt((t.pos.x - pos.x) ^ 2 + (t.pos.z - pos.z) ^ 2)
            return ". The way there is through iron bars " .. math.floor(t.dist + 0.5) .. " meters from you. " .. G.asleep_gate_text(pos, t.pos)
        end
    end
    if dy > 2 then hint = " It is " .. math.floor(dy + 0.5) .. " meters above you, on a higher floor."
    elseif dy < -2 then hint = " It is " .. math.floor(-dy + 0.5) .. " meters below you." end
    if math.abs(dy) > 2 then
        for _, t in ipairs(scan_things(pos, 40)) do
            if t.name == "Ladder" then
                hint = hint .. " Nearest ladder " .. describe_position(t.pos, pos, G.facing()) .. ": go there, press F to climb."
                selected = t
                break
            end
        end
    end
    return hint
end

local function route_status()
    local pos = G.player_pos()
    if not pos then return end
    local R = RE4Access.route
    local st = R and R.status(pos)
    if st then say(st) return end
    if selected then
        say(selected.name .. ", " .. describe_position(selected.pos, pos, G.facing()) .. ". No route on.")
    else
        say("No route. Nothing selected.")
    end
end

-- ---------------- next story step ----------------
-- Story events ("LevelKey_mvaNNN...") are numbered in story order. An event is
-- done once a cutscene started near it (or Leon stood at it). N picks the
-- lowest-numbered event not done; if there is none, the closest unvisited
-- path point.
G.story_done = {}
-- Finished story numbers are kept in reframework\data\REAccess_story.txt (one
-- number per line) so they survive a restart. Anything numbered below the
-- highest finished one counts as finished too.
local STORY_FILE = "REAccess_story.txt"
local story_max = 0
pcall(function()
    for n in (fs.read(STORY_FILE) or ""):gmatch("%d+") do
        story_max = math.max(story_max, tonumber(n))
    end
end)
local function story_finished(n)
    if n > story_max then
        story_max = n
        pcall(fs.write, STORY_FILE, tostring(n) .. "\n")
    end
end
local function story_number(t)
    local ok, n = pcall(function() return t.go:call("get_Name"):match("^LevelKey_mva(%d+)") end)
    return ok and n and tonumber(n) or nil
end

-- Binoculars whose story scene was seen, by object name, kept in a file
-- (10/19: after the lake scene and a reload N sent the user back to them).
G.VIEWS_FILE = "REAccess_views_seen.txt"
G.views_seen = G.views_seen or {}
pcall(function() for l in (fs.read(G.VIEWS_FILE) or ""):gmatch("[^\n]+") do G.views_seen[l] = true end end)
function G.view_seen(go)
    local ok, gn = pcall(function() return go:call("get_Name") end)
    if not ok or not gn or G.views_seen[gn] then return end
    G.views_seen[gn] = true
    local all = {}
    for k in pairs(G.views_seen) do all[#all + 1] = k end
    pcall(fs.write, G.VIEWS_FILE, table.concat(all, "\n") .. "\n")
end
local function mark_story_near(pos, radius)
    for _, t in ipairs(scan_things(pos, radius)) do
        -- binoculars used for a story scene count as done too
        if t.name == "Lookout point" and math.abs(t.pos.y - pos.y) < 3 then
            G.story_done[t.key] = true
            pcall(G.view_seen, t.go)
        end
        if story_number(t) and math.abs(t.pos.y - pos.y) < 3 then
            if not G.story_done[t.key] then log.info("[RE4Access] story done: " .. t.name) end
            G.story_done[t.key] = true
            story_finished(story_number(t))
        end
    end
end
G.mark_story_near = mark_story_near
G.story_number = story_number
function G.story_is_done(t)
    if G.story_done[t.key] then return true end
    local n = story_number(t)
    return n ~= nil and n <= story_max
end

-- Hidden waypoints: the game's trigger areas along the intended road
-- (LevelAreaHit_..., Y_..., LevelKey_...). Not listed anywhere; N uses them as
-- stepping stones toward the objective.
local function waypoints(pos, range)
    local out = {}
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    if not gm then return out end
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        pcall(function()
            local go = e:get_field("value"):call("get_GameObject")
            local n = go:call("get_Name")
            if n:find("^LevelAreaHit") or n:find("^Y_") or n:find("^LevelKey_") then
                local q = go:call("get_Transform"):call("get_Position")
                local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
                if d <= range then out[#out + 1] = { pos = { x = q.x, y = q.y, z = q.z }, dist = d, key = go:get_address(), raw = n } end
            end
        end)
    end
    return out
end

local follow = { on = false, used = {} }     -- following the objective, waypoint by waypoint
G.follow = follow

-- A puzzle slot (GmMultiModify, e.g. the windmill machine) within 100 m that
-- takes an item Leon is carrying (GmMultiModify._Items vs the case): the next
-- step is to put it in, before following the objective (10/12: N went toward the
-- lake while the Wooden Cog had to go into the windmill first).
-- Does Leon carry this item (case grid or key items)? Cached for 1 s.
local have_cache = { at = -10 }
function G.has_item(id)
    local now = os.clock()
    local have = have_cache
    if now - have.at > 1 then
        have = { at = now }
        have_cache = have
        pcall(function()
            local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
            for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
                local c = e:get_field("value")
                local tn = c and c:get_type_definition():get_full_name()
                if tn == "chainsaw.CsInventoryController" then
                    local lst = c:call("getInventoryItemList()")
                    for i = 0, lst:call("get_Count") - 1 do
                        local item = lst:call("get_Item", i):get_field("<Item>k__BackingField")
                        if item then have[item:get_field("_ItemId")] = true end
                    end
                elseif tn == "chainsaw.KeyItemInventoryController" then
                    -- key items (the cog) live here, not in the case grid
                    have.key_ctrl = c
                end
            end
        end)
    end
    if have[id] then return true end
    local ok, r = pcall(function() return have.key_ctrl and have.key_ctrl:call("existsItem(chainsaw.ItemID)", id) end)
    return ok and r == true
end

-- Does Leon carry any knife? (10/13: Chapter 2 starts with an empty case; a
-- herb crate can't be broken until he picks up a Kitchen Knife.)
-- Returns nil when the inventory can't be read.
function G.has_knife()
    local ok, r = pcall(function()
        local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
            local c = e:get_field("value")
            if c and c:get_type_definition():get_full_name() == "chainsaw.CsInventoryController" then
                local lst = c:call("getInventoryItemList()")
                for i = 0, lst:call("get_Count") - 1 do
                    local item = lst:call("get_Item", i):get_field("<Item>k__BackingField")
                    if item then
                        local n = RE4Access.menu.clean(msg_get:call(nil, mm:call("getItemNameMsgId", item:get_field("_ItemId"))))
                        if n:find("Knife", 1, true) then return true end
                    end
                end
                return false
            end
        end
    end)
    if ok then return r end
end

-- What a slot gimmick (GmMultiModify: machine slot, wayshrine) needs:
-- returns item name, item id, and whether Leon has it; nil if it needs nothing.
local t_mm = sdk.typeof("chainsaw.GmMultiModify")
function G.slot_need(go)
    local name, id, have
    pcall(function()
        local c = go:call("getComponent(System.Type)", t_mm)
        local arr = c and c:get_field("_Items")
        for _, v in ipairs(arr and arr:get_elements() or {}) do
            local i = type(v) == "number" and v or v:get_field("value__")
            local h = G.has_item(i)
            if not id or h then name, id, have = item_name_by_id(i), i, h end
            if h then break end
        end
    end)
    return name, id, have
end

local function puzzle_step(pos)
    -- dial locks and crystal balls (guide.lua, 10/17)
    local okg, gs = pcall(function() return RE4Access.guide and RE4Access.guide.step(pos) end)
    if okg and gs then return gs end
    local has = G.has_item
    local t_mm = sdk.typeof("chainsaw.GmMultiModify")
    for _, t in ipairs(scan_things(pos, 100)) do
        -- wayshrines hold bonus treasure, not story: only when close by, never
        -- from far away instead of the objective (10/20: N steered the boat 444 m
        -- to a wayshrine while the objective was the church)
        if (t.name == "Machine slot" or (t.name == "Wayshrine" and t.dist < 20 and not G.in_boat)) and not G.gimmick_done(t.go) then
            local found
            pcall(function()
                local c = t.go:call("getComponent(System.Type)", t_mm)
                local arr = c and c:get_field("_Items")
                for _, v in ipairs(arr and arr:get_elements() or {}) do
                    local id = type(v) == "number" and v or v:get_field("value__")
                    if has(id) then found = id break end
                end
            end)
            if found and t.name == "Wayshrine" then
                -- optional: told once, N stays on the story (10/22 user: "taking me to the wayshrine thing")
                G.wayshrine_told = G.wayshrine_told or {}
                if not G.wayshrine_told[t.key] then
                    G.wayshrine_told[t.key] = true
                    RE4Access.speak("Optional: a Wayshrine, " .. describe_position(t.pos, pos, G.facing()) .. ", takes your " .. item_name_by_id(found) .. " for a treasure. To go there, find it in the list with the bracket keys and press Backslash.", false)
                end
            elseif found then
                return { name = t.name .. ", put in the " .. item_name_by_id(found), pos = t.pos, dist = t.dist, key = t.key, go = t.go }
            end
        end
    end
    -- Puzzle pieces that are ready and not done yet (GimmickContext hasDoneForMap):
    -- a lever whose machine has its part (GmPowerUnitLever get_IsPowerActive),
    -- then carts to push. Nearest first, same order the game expects.
    local t_lever = sdk.typeof("chainsaw.GmPowerUnitLever")
    local best
    for _, t in ipairs(scan_things(pos, 60)) do
        if t.name == "Lever" or t.name == "Cart, push it" or t.name == "Trapdoor" then
            local ready = false
            -- the Chief's attic lever: needs Ashley, later (guide.lua says so)
            local okn, nm = pcall(function() return t.go:call("get_Name") end)
            if okn and nm:find("屋根裏", 1, true) and not RE4Access.ashley_here then goto skip_piece end
            -- behind iron bars the story opens later (10/18: the church lever
            -- 教会のレバー, bars 1.5 m away, won over the barn trapdoor)
            if G.behind_closed_bars(t.pos) then goto skip_piece end
            pcall(function()
                local core = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore"))
                if core:call("get_Context"):call("hasDoneForMap") then return end
                if t.name == "Lever" then
                    local lv = t.go:call("getComponent(System.Type)", t_lever)
                    ready = (not lv) or lv:call("get_IsPowerActive")
                else
                    ready = true
                end
            end)
            if ready and (not best or (best.name ~= "Lever" and t.name == "Lever") or (best.name == t.name and t.dist < best.dist)) then
                best = t
            end
            ::skip_piece::
        end
    end
    if best then
        local what = best.name == "Lever" and "Lever, pull it" or "Cart handle, hold F to grab it"
        -- 11/8 Ch8 storeroom: 落としシャンデリアレバー drops the giant chandelier.
        -- Optional help in the fight, not the way on (user: "unsure if the route is correct").
        local tip
        do
            local okn, nm = pcall(function() return best.go:call("get_Name") end)
            if okn and nm and nm:find("シャンデリア", 1, true) then
                what = "the chandelier lever, upstairs"
                tip = "It is OPTIONAL help: pulling it drops the giant chandelier on enemies standing under it in the middle of the room. The real goal here: kill the cult leader with the bell, then the rest, then pick up the Crimson Lantern he drops."
            end
        end
        -- GmPushMove can be a bookshelf (ルイスの小屋の動かし棚 in the boathouse, 10/12 PM)
        if best.name ~= "Lever" and G.is_shelf(best.go) then what = "Bookshelf, hold F to grab it, then push" end
        if best.name == "Trapdoor" then what = "Trapdoor, press F to break through it" end
        local target = best.pos
        if best.name == "Trapdoor" then
            -- the board itself is off the navmesh: stand on walkable floor next to it
            local R = RE4Access.route
            for _, r in ipairs({ 1.0, 1.3, 1.6 }) do
                for k = 0, 11 do
                    local a = k * math.pi / 6
                    local q = { x = best.pos.x + math.sin(a) * r, y = best.pos.y, z = best.pos.z + math.cos(a) * r }
                    local okn, pts = pcall(R.nav_points, pos, q)
                    if okn and pts then target = q break end
                end
                if target ~= best.pos then break end
            end
        end
        if best.name == "Cart, push it" then
            local h = G.cart_handle(best.go)
            if h then target = h.pos end
        end
        -- Trapdoor with its F icon at one edge (10/18 barn: the typewriter 2 m
        -- away kept the F): stand just outside the icon edge, face the icon, HOLD F.
        if best.name == "Trapdoor" then
            local st = G.trapdoor_spot(best.go, best.pos, best.key)
            if st then return st end
        end
        return { name = what, pos = target, dist = math.sqrt((target.x - pos.x) ^ 2 + (target.z - pos.z) ^ 2), key = best.key, go = best.go, tip = tip }
    end
end

-- Closed crank-worked shutters/bars (10/14: the Valley entrance wooden lattice
-- shutter dropped behind the user; the navmesh still walked through it).
local SHUTTER_TYPES = { "chainsaw.GmCorrelatedThroughShutter", "chainsaw.GmCorrelatedDoubleShutter" }
function G.closed_shutters(pos, range)
    local out = {}
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    if not gm then return out end
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            local gp = go:call("get_Transform"):call("get_Position")
            if math.sqrt((gp.x - pos.x) ^ 2 + (gp.z - pos.z) ^ 2) > (range or 80) then return end
            -- drop gates (GmFallShutter, the log gate at the quarry, 10/18):
            -- _Routine 1 = down/closed
            local fs = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmFallShutter"))
            if fs then
                if fs:get_field("_Routine") == 1 then out[#out + 1] = { x = gp.x, y = gp.y, z = gp.z, go = go } end
                return
            end
            for _, tn in ipairs(SHUTTER_TYPES) do
                local c = go:call("getComponent(System.Type)", sdk.typeof(tn))
                if c then
                    local r = c:get_field("_OldRate") or 0
                    if r < 0.9 then out[#out + 1] = { x = gp.x, y = gp.y, z = gp.z, go = go } end
                    return
                end
            end
        end) end
    end
    return out
end

-- Gates the story keeps shut and closed shutters, near pos (route.lua keeps
-- navmesh paths out of them).
function G.asleep_gate_positions(pos, range)
    local out = {}
    for _, t in ipairs(doors_near(pos, range or 80)) do
        if t.name == "Gate" and gate_asleep(t.go) then out[#out + 1] = t.pos end
    end
    for _, q in ipairs(G.closed_shutters(pos, range)) do out[#out + 1] = q end
    return out
end

-- 10/14: the factory back gate is iron bars raised by a crank stand that needs
-- the Hexagonal Emblem (item 119203200) from the Valley. The objective lies past
-- the bars, so N walked to them and got "Blocked". While those bars are shut, N
-- leads to the emblem first: Valley entrance -> the emblem -> back to the stand.
local HEX_EMBLEM = 119203200
local function hex_detour(pos)
    local stand
    for _, t in ipairs(scan_things(pos, 150)) do
        local ok, hex = pcall(function() return t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.CustomGmCrankHexCrest2")) end)
        if ok and hex then
            for _, g in ipairs(doors_near(t.pos, 5)) do
                if g.name == "Gate" and gate_asleep(g.go) then stand = t break end
            end
        end
        if stand then break end
    end
    if not stand then return nil end
    if G.has_item(HEX_EMBLEM) then
        -- Still in the Valley with its entrance shutter down: the way out is the
        -- crank on the hill by the Ruby chest (gm84_891 渓谷入り口柵のハンドル).
        local fence
        pcall(function()
            local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core then pcall(function()
                    local go = core:call("get_GameObject")
                    if go:call("get_Name"):find("渓谷入り口柵のハンドル", 1, true) then
                        local h = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmHoldHandle"))
                        local v = h:get_field("_ProcessValue"):get_field("Value")
                        local gp = go:call("get_Transform"):call("get_Position")
                        -- stand in FRONT of it (its AxisZ side; 10/14 F never came from the east side)
                        local ax = go:call("get_Transform"):call("get_AxisZ")
                        if v < 0.99 then fence = { x = gp.x + ax.x * 0.9, y = gp.y, z = gp.z + ax.z * 0.9, go = go, crank = { x = gp.x, y = gp.y + 1.1, z = gp.z } } end
                    end
                end) end
                if fence then break end
            end
        end)
        local shut = false
        for _, q in ipairs(G.closed_shutters(pos, 80)) do
            pcall(function() if q.go:call("get_Name"):find("木製格子シャッター", 1, true) then shut = true end end)
        end
        if fence and shut and math.sqrt((fence.x - pos.x) ^ 2 + (fence.z - pos.z) ^ 2) < 60 then
            local d = math.sqrt((fence.x - pos.x) ^ 2 + (fence.z - pos.z) ^ 2)
            return { name = "Valley fence crank", tip = "It is up on a hill by a chest. The only way up is the long path around the northeast side, so the walk is much longer than the straight distance. At the crank: clear enemies, then hold F to turn it; it opens the way out.", pos = { x = fence.x, y = fence.y, z = fence.z }, dist = d, key = "valley_fence_crank", face_at = fence.crank }
        end
        return { name = "Crank stand", tip = "Press F there and choose the Hexagonal Emblem.", pos = stand.pos, dist = stand.dist, key = stand.key, go = stand.go }
    end
    local emblem
    for _, it in ipairs(items(pos, 150)) do
        if it.name:find("Hexagonal Emblem", 1, true) then emblem = it break end
    end
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    local entrance
    pcall(function()
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject")
                if go:call("get_Name"):find("渓谷入り口", 1, true) then
                    local gp = go:call("get_Transform"):call("get_Position")
                    entrance = { x = gp.x, y = gp.y, z = gp.z }
                end
            end) end
            if entrance then break end
        end
    end)
    local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
    -- Valley entrance first while you are further from the emblem than it is.
    -- Far from the emblem: first the ladder inside its house (the roof has no
    -- other way up; 10/14 from the lookout platform no route reached the roof).
    if emblem and math.abs(pos.y - emblem.pos.y) > 2.5 then   -- below the roof: ladder first (10/14: right under the emblem)
        local foot
        pcall(function()
            for _, c in ipairs(RE4Access.route.connectors(emblem.pos)) do
                if c.kind == "ladder" and d2(c.b, emblem.pos) < 9 and math.abs(c.b.y - (emblem.pos.y - 1.4)) < 1.5 then foot = c.a break end
            end
        end)
        if foot and d2(pos, foot) > 2 then
            return { name = "Ladder to the emblem roof", tip = "Inside the house; then press F to climb up. The emblem is at the top.", pos = { x = foot.x, y = foot.y, z = foot.z }, dist = d2(pos, foot), key = "emblem_ladder" }
        end
    end
    if emblem and not (entrance and d2(pos, entrance) > 8 and d2(pos, emblem.pos) > d2(entrance, emblem.pos)) then
        return { name = "Hexagonal Emblem", tip = "It is on the roof of the building. Way in: jump through the window on its southeast side, then climb the ladder inside.",
            pos = emblem.pos, dist = emblem.dist, key = emblem.key, go = emblem.go, item = emblem.item }
    end
    if entrance then
        local d = d2(entrance, pos)
        if d > 8 then
            return { name = "Valley entrance", tip = "The Hexagonal Emblem for the iron bars is in the Valley.", pos = entrance, dist = d, key = "valley_entrance" }
        end
        return { hint = "You are in the Valley. The Hexagonal Emblem is on the roof of the large building on the right. Its doors are locked: go around to its southeast side and jump through the window, then climb the ladder inside to the roof. Comma lists items when you are close." }
    end
    return nil
end

G.hex_detour = hex_detour
local function next_step()
    local pos = G.player_pos()
    if not pos then return end
    -- Timed shutter open: N (and question mark) lead to the shutter, nothing
    -- else (10/13: N replaced the shutter run with a route to a bolted door).
    if G.timed_target then
        local tt = G.timed_target()
        if tt then
            selected = tt
            say("Next: the shutter. Sprint, Shift and W.", true)
            RE4Access.speak_hold = true
            if RE4Access.route then RE4Access.route.go(tt) end
            RE4Access.speak_hold = nil
            return
        end
    end
    local best, best_n
    -- "Cross the lake" needs the Boat Fuel from the fish farm first (10/19: N
    -- said "no walking route" to the objective across the water, and later led
    -- to "the trail" with the fuel 8 m away). Its building is padlocked: the
    -- padlock comes first.
    do
        local okt, ot = pcall(objective_text)
        local fuel
        local need_boat, pre = false, ""
        -- inside the church: lever, then the stained glass stand (10/22);
        -- chapter 5: attic ladder, then the window
        local esc = okt and ot and ot:lower():find("escape from the church", 1, true)
        if okt and ot and (esc or ot:lower():find("ashley in the church", 1, true)) and not G.in_boat then
            local okc, ct = pcall(esc and G.church_escape_step or G.church_inside_step, pos)
            -- at the stand: all three glasses (stained.lua)
            if okc and ct and ct.name == "Stained glass stand" and ct.dist < 3 and RE4Access.stained then
                RE4Access.stained.status()
                return
            end
            if okc and ct then
                follow.on = false
                selected = ct
                say("Next: " .. ct.name .. ", " .. describe_position(ct.pos, pos, G.facing()) .. ". " .. ct.tip, true)
                if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(ct) RE4Access.speak_hold = nil end
                return
            end
        end
        if okt and ot and ot:lower():find("church") and not ot:lower():find("ashley", 1, true) then
            local okh, st = pcall(G.church_heads, pos)
            local m = okh and st.missing[1]
            -- In the north cave the head sits behind a shutter that a symbol button
            -- puzzle opens (10/20): the puzzle first.
            if m and not G.in_boat and m.dist < 60 then
                for _, t in ipairs(scan_things(pos, 40)) do
                    if t.name == "Hepta Puzzle" and not G.gimmick_done(t.go) then
                        follow.on = false
                        selected = t
                        say("Next: the symbol button puzzle, " .. describe_position(t.pos, pos, G.facing())
                            .. ". It opens the shutter to the " .. m.h.name .. ". Like in the south cave: press F at it, then I tell you the symbols to press.", true)
                        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(t) RE4Access.speak_hold = nil end
                        return
                    end
                end
            end
            -- both heads in the case: back to the church door (10/20: N went for
            -- the objective 329 m away "behind a bolted door", the cave gate)
            if okh and #st.missing == 0 and #st.have > 0 then
                local holder
                for _, t in ipairs(scan_things(pos, 450)) do
                    if t.name == "Church Emblem Holder" then holder = t break end
                end
                -- at the door: the statues, one after the other
                local okst, statue = false, nil
                if holder and holder.dist < 15 then okst, statue = pcall(G.head_statue_step, pos) end
                if okst and statue then
                    follow.on = false
                    selected = statue
                    say("Next: a head statue beside the church door. I walk you in front of it.", true)
                    if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(statue) RE4Access.speak_hold = nil end
                    return
                end
                if holder and not G.gimmick_done(holder.go) then
                    local okn, pts = pcall(RE4Access.route.nav_points, pos, holder.pos)
                    local l = okn and pts and pts[#pts]
                    if G.in_boat or (l and math.sqrt((l.x - holder.pos.x) ^ 2 + (l.z - holder.pos.z) ^ 2) < 2) then
                        follow.on = false
                        selected = holder
                        say("Next: the church door, to place both heads. " .. describe_position(holder.pos, pos, G.facing()) .. "."
                            .. (G.in_boat and " Press Backslash and I drive." or ""), true)
                        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(holder) RE4Access.speak_hold = nil end
                        return
                    end
                    need_boat = true
                    pre = "You have both heads. Take them to the church door, across the lake. "
                end
            end
            if m then
                local okn, pts = pcall(RE4Access.route.nav_points, pos, m.pos)
                local l = okn and pts and pts[#pts]
                -- close by (10/20: head 20 m away up a ledge behind the cave gate; the
                -- walk test failed and N sent the user back into the boat)
                if G.in_boat or m.dist < 60 or (l and math.sqrt((l.x - m.pos.x) ^ 2 + (l.z - m.pos.z) ^ 2) < 2) then
                    follow.on = false
                    selected = { name = m.h.name, pos = m.pos, dist = m.dist, key = m.key, go = m.go, item = true }
                    say("Next: the " .. m.h.name .. ", for the church door. " .. describe_position(m.pos, pos, G.facing()) .. ".", true)
                    if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(selected) RE4Access.speak_hold = nil end
                    return
                end
                -- across the water: the boat first; in the boat N steers to it
                need_boat = true
                pre = "The church door needs the " .. m.h.name .. ", " .. m.h.where .. ". Go by boat. "
            end
        end
        -- A known way on foot from its landing (G.LAND_WAYS, 10/21: church via
        -- the Quarry from the Merchant's dock)
        if not need_boat and not G.in_boat and okt and ot then
            local okw, wt = pcall(G.land_way_step, pos, ot)
            if okw and wt then
                follow.on = false
                selected = wt
                say("Next: " .. wt.name .. ", " .. describe_position(wt.pos, pos, G.facing()) .. ". " .. wt.tip, true)
                if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(wt) RE4Access.speak_hold = nil end
                return
            end
        end
        -- Any objective with no walking way from the lake side while a boat is
        -- near: the boat first; in the boat N steers to the landing closest to
        -- the objective (10/20: "Head for the church" from the lake, N said
        -- "not open yet, skip it" - the landing below the cliff is 57 m from it).
        if not need_boat and not G.in_boat and okt and ot and not ot:lower():find("lake") then
            pcall(function()
                local op = G.objective_pos()
                if not op or math.sqrt((op.x - pos.x) ^ 2 + (op.z - pos.z) ^ 2) < 25 then return end
                local pts = RE4Access.route.nav_points(pos, op)
                local l = pts and pts[#pts]
                if l and math.sqrt((l.x - op.x) ^ 2 + (l.z - op.z) ^ 2) < 8 then return end
                for _, t in ipairs(scan_things(pos, 80)) do
                    if t.name == "Boat" then
                        need_boat = true
                        local lw = G.land_way(ot)
                        pre = "No walking way to the objective from here. Go by boat: in the boat press N, then Backslash, and I drive you to "
                            .. (lw and lw.pier_name or "the landing closest to it") .. ". "
                        return
                    end
                end
            end)
        end
        if okt and ot and ot:lower():find("lake") then
            for _, it in ipairs(items(pos, 400)) do
                if it.name == "Boat Fuel" then
                    fuel = { name = "Boat Fuel, in the fish farm building", pos = it.pos, dist = it.dist, key = it.key, go = it.go, item = true }
                    for _, t in ipairs(scan_things(pos, 400)) do
                        if t.name == "Padlock" and math.sqrt((t.pos.x - it.pos.x) ^ 2 + (t.pos.z - it.pos.z) ^ 2) < 12 then fuel = t break end
                    end
                    break
                end
            end
        end
        -- fuel taken: the boat (10/19: N went for the objective across the water,
        -- "no walking route"). Walk to the shore spot next to it, face it.
        if not fuel and okt and ot and (need_boat or ot:lower():find("lake")) then
            pcall(function()
                local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
                local boat, bd
                for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                    local core = e:get_field("value")
                    local go = core and core:call("get_GameObject")
                    if go and go:call("get_DrawSelf") and go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmBoat")) then
                        local p = go:call("get_Transform"):call("get_Position")
                        local d = math.sqrt((p.x - pos.x) ^ 2 + (p.z - pos.z) ^ 2)
                        if not bd or d < bd then boat, bd = { go = go, pos = { x = p.x, y = p.y, z = p.z } }, d end
                    end
                end
                if not boat or not RE4Access.route then return end
                local b = boat.pos
                for r = 1.5, 6, 1.5 do
                    for k = 0, 15 do
                        local a = k * math.pi / 8
                        local t = { x = b.x + math.sin(a) * r, z = b.z + math.cos(a) * r }
                        local g = RE4Access.route.cast(t.x, b.y + 12, t.z, t.x, b.y - 4, t.z)
                        if g then
                            t.y = g.y
                            local okn, pts = pcall(RE4Access.route.nav_points, pos, t)
                            local l = okn and pts and pts[#pts]
                            if l and math.sqrt((l.x - t.x) ^ 2 + (l.z - t.z) ^ 2) < 0.8 then
                                fuel = { name = "the boat", pos = t, face = { x = b.x, y = b.y + 0.5, z = b.z }, dist = bd, key = "boat", go = boat.go,
                                    latch = true, fname = "Boat", spoken = "boat", after = "Press F to get in the boat." }
                                return
                            end
                        end
                    end
                end
            end)
        end
        if fuel then
            follow.on = false
            selected = fuel
            say(pre .. "Next: " .. fuel.name .. ", " .. describe_position(fuel.pos, pos, G.facing()) .. ".", true)
            if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(fuel) RE4Access.speak_hold = nil end
            return
        end
    end
    -- (10/12 PM: the "shooting spot for the tripwire bomb" step is gone - user asked
    -- to remove it; L still aims at a bomb in clear view.)
    local okho, ho = pcall(G.hole_step, pos)
    if okho and ho then
        follow.on = false
        selected = ho
        say("Next: " .. ho.name .. ". " .. ho.tip, true)
        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(ho) RE4Access.speak_hold = nil end
        return
    end
    local oksh, sh = pcall(G.shelf_step, pos)
    if oksh and sh then
        follow.on = false
        selected = sh
        say("Next: the fallen shelf, " .. describe_position(sh.face, pos, G.facing()) .. ". " .. sh.tip, true)
        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(sh) RE4Access.speak_hold = nil end
        return
    end
    -- 11/9 Ch8 storeroom: the cult leader first. Clear view now: shoot. Else walk
    -- to the nearest spot with a clear shot at him (he moves: N again re-checks).
    do
        local okl, s = pcall(G.summoner, pos, 60)
        -- 11/9 1:15 AM: SNEAK ROUTE, walked by Claude crouched with nobody
        -- noticing (TargetFindState stayed 0): window, right-hand wall, back
        -- stairs, upper walkway to the chandelier lever. The leader turns
        -- suspicious on the north path at (12.7,3.3): never go that way.
        -- 11/9 1:40 AM user chose the WINDOW FIGHT: stand outside, make noise,
        -- shoot them as they climb out one by one; leader last, up close.
        if okl and s then
            local left = G.cultists_left(pos)
            if left > 2 and pos.x > 23.5 then
                follow.on = false
                local spot = G.WINDOW_FIGHT_SPOT
                local sd = math.sqrt((pos.x - spot.x) ^ 2 + (pos.z - spot.z) ^ 2)
                G.window_fight = true
                if sd > 1.5 then
                    local t = { name = "the window fight spot", pos = spot, dist = sd }
                    selected = t
                    say("Window fight. Next: the fight spot outside, " .. describe_position(spot, pos, G.facing()) .. ". Do not climb in.", true)
                    if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(t) RE4Access.speak_hold = nil end
                    return
                end
                pcall(G.face_item, G.WINDOW_POS)
                say("You are at the fight spot. I turned you to the window, " .. describe_position(G.WINDOW_POS, pos, G.facing()) .. ". "
                    .. left .. " cultists inside. To call them: hold L and press K once, into the room. Then stay here. They climb out through the window toward you: hold L, press K. Back off with S if one gets close. Heal at half health: I, then a First Aid Spray. When only 2 are left I tell you, then press N for the cult leader.", true)
                return
            end
            G.window_fight = nil
        end
        local okc, ch = pcall(G.chandelier_info, pos)
        if okl and s and okc and ch and not ch.done and G.sneak_wanted then
            local W = G.SNEAK_WPS
            local i = G.sneak_i or 1
            -- outside: start over
            if pos.x > 23.5 then i = 1 end
            -- skip waypoints already reached (within 1.5 m on the same level)
            while i <= #W do
                local w = W[i]
                local dd = math.sqrt((pos.x - w.x) ^ 2 + (pos.z - w.z) ^ 2)
                if dd < 1.5 and math.abs(pos.y - w.y) < 1.2 then i = i + 1 else break end
            end
            -- jumped ahead (e.g. Continue): nearest later waypoint on Leon's level
            if pos.x <= 23.5 then
                local best_j, best_d
                for j = i, #W do
                    local w = W[j]
                    local dd = math.sqrt((pos.x - w.x) ^ 2 + (pos.z - w.z) ^ 2)
                    if math.abs(pos.y - w.y) < 1.2 and (not best_d or dd < best_d) then best_j, best_d = j, dd end
                end
                if best_j and best_j > i and best_d < 2.5 then i = best_j end
            end
            G.sneak_i = i
            G.sneak_on = true
            follow.on = false
            if i > #W then
                local lv = ch.lever
                local t = { name = "the chandelier lever", pos = lv.pos, dist = lv.dist, key = lv.key, go = lv.go }
                selected = t
                if lv.dist < 2 then
                    G.sneak_on = nil
                    say("You are at the chandelier lever. Face it and press F to drop the chandelier on the enemies below. After that EVERYONE wakes up: stay up here, hold L and press K, heal at half health.", true)
                    return
                end
                say("The lever is " .. describe_position(lv.pos, pos, G.facing()) .. ".", true)
                if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(t) RE4Access.speak_hold = nil end
                return
            end
            local w = W[i]
            local t = { name = w.say or "the next sneak point", pos = { x = w.x, y = w.y, z = w.z }, dist = math.sqrt((pos.x - w.x) ^ 2 + (pos.z - w.z) ^ 2) }
            selected = t
            if i == 1 then
                say("Sneak route to the chandelier lever, the way I tested it: nobody noticed me. Through the window, then press E to CROUCH and stay crouched. Keep holding W: I lead you along the right-hand wall to the back stairs, up, and along the walkway to the lever. Do not shoot. If I say someone is suspicious, stop.", true)
            elseif w.say then
                say(w.say, true)
            end
            if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(t) RE4Access.speak_hold = nil end
            return
        end
        G.sneak_on = nil
        if okl and s then
            local eye = { x = pos.x, y = pos.y + 1.4, z = pos.z }
            local chest = { x = s.pos.x, y = s.pos.y + AIM_HEIGHT, z = s.pos.z }
            if s.dist <= 45 and visible_from(eye, chest) then
                say("The cult leader is in view now, " .. describe_position(s.pos, pos, G.facing()) .. ". Stand still, hold L, press K again and again.", true)
                return
            end
            local oks, spot = pcall(G.shoot_spot, chest, pos, { 4, 5.5, 7, 10, 14, 18, 22, 26 })
            log.info("[RE4Access] leader shoot spot: " .. (oks and spot and string.format("(%.1f,%.1f,%.1f)", spot.x, spot.y, spot.z) or tostring(spot)))
            if oks and spot then
                follow.on = false
                local t = { name = "a spot to shoot the cult leader from", pos = spot, dist = math.sqrt((spot.x - pos.x) ^ 2 + (spot.z - pos.z) ^ 2) }
                selected = t
                say("Next: a spot where you can see the cult leader, " .. describe_position(spot, pos, G.facing()) .. ". He is " .. describe_position(s.pos, pos, G.facing()) .. ". When you hear the leader sound, stop, hold L, press K.", true)
                if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(t) RE4Access.speak_hold = nil end
                return
            end
            say("The cult leader is " .. describe_position(s.pos, pos, G.facing()) .. ", hidden from here, and I found no clear spot to shoot him from. Move a little and press N again.", true)
            return
        end
    end
    local okp, ps = pcall(puzzle_step, pos)
    if okp and ps then
        follow.on = false
        selected = ps
        say("Next: " .. ps.name .. ", " .. describe_position(ps.pos, pos, G.facing()) .. "." .. (ps.tip and (" " .. ps.tip) or ""), true)
        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(ps) RE4Access.speak_hold = nil end
        return
    end
    local okh, hd = pcall(hex_detour, pos)
    if not okh then log.info("[RE4Access] hex detour error: " .. tostring(hd)) end
    if okh and hd then
        follow.on = false
        if hd.hint then say(hd.hint, true) return end
        selected = hd
        local have = G.has_item(119203200) and "You have the emblem. " or (hd.name == "Hexagonal Emblem" and "You don't have the emblem yet. " or "")
        say(have .. "Next: " .. hd.name .. ", " .. describe_position(hd.pos, pos, G.facing()) .. ". " .. (hd.tip or ""), true)
        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(hd) RE4Access.speak_hold = nil end
        return
    end
    local okug, ug = pcall(G.unlocked_gate_step, pos)
    if okug and ug then
        follow.on = false
        selected = ug
        say("Next: " .. ug.name .. ", " .. describe_position(ug.pos, pos, G.facing()) .. ". " .. ug.tip, true)
        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(ug) RE4Access.speak_hold = nil end
        return
    end
    local okk, kh = pcall(G.keyhole_step, pos)
    if okk and kh then
        follow.on = false
        selected = kh
        say("Next: " .. kh.spoken .. ", " .. describe_position(kh.face, pos, G.facing()) .. ". " .. kh.tip, true)
        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(kh) RE4Access.speak_hold = nil end
        return
    end
    local okl, lt = pcall(G.latch_step, pos)
    if okl and lt then
        follow.on = false
        selected = lt
        say("Next: the gate latch, " .. describe_position(lt.face, pos, G.facing()) .. ". " .. lt.tip, true)
        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(lt) RE4Access.speak_hold = nil end
        return
    end
    local oktr, tr = pcall(G.trail_step, pos)
    if oktr and tr and not tr.hold and G.away_from_objective(tr, pos) then tr = nil end
    if oktr and tr and tr.hold then
        say("No more of the trail is known from here. Walk on ahead, away from the gate, then press N again.", true)
        return
    end
    if oktr and tr then
        follow.on = false
        selected = tr
        say("Next: " .. tr.name .. ", " .. describe_position(tr.pos, pos, G.facing()) .. ". " .. tr.tip, true)
        if RE4Access.route then RE4Access.speak_hold = true RE4Access.route.go(tr) RE4Access.speak_hold = nil end
        return
    end
    for _, t in ipairs(scan_things(pos, FAR_RANGE)) do
        local n = story_number(t)
        if n and n > story_max and not G.story_done[t.key] and (not best_n or n < best_n) then best, best_n = t, n end
    end
    if best and G.away_from_objective(best, pos) then best = nil end
    if not best then
        -- Binoculars that start a cutscene (GO name "ViewPoint_...cs...") are story steps.
        for _, t in ipairs(scan_things(pos, 80)) do
            if t.name == "Lookout point" and not G.story_done[t.key] then
                local okn, gn = pcall(function() return t.go:call("get_Name") end)
                if okn and gn and gn:find("cs") and not G.views_seen[gn] then
                    best = { name = "Binoculars, story scene", pos = t.pos, dist = t.dist, key = t.key, go = t.go, face = t.face, sensor = t.sensor }
                    break
                end
            end
        end
    end
    if best then follow.on = false end
    if not best then
        local op = G.objective_pos()
        if op then
            local d_obj = math.sqrt((op.x - pos.x) ^ 2 + (op.z - pos.z) ^ 2)
            if d_obj < 15 then
                best = { name = "Objective", pos = op, dist = d_obj, key = "objective", walk_point = true }
            else
                -- The nearest trigger point on the way: at least 2 m closer to the
                -- objective than you are, not much of a detour, not used yet.
                local best_d
                for _, w in ipairs(waypoints(pos, 60)) do
                    if w.dist > 5 and not follow.used[w.key] and math.abs(w.pos.y - pos.y) < 8 then
                        local to_obj = math.sqrt((op.x - w.pos.x) ^ 2 + (op.z - w.pos.z) ^ 2)
                        local detour = w.dist + to_obj - d_obj
                        if to_obj < d_obj - 2 and detour < 20 and (not best_d or w.dist < best_d) then
                            best, best_d = w, w.dist
                        end
                    end
                end
                if best then
                    follow.used[best.key] = true
                    best = { name = "Way to the objective", pos = best.pos, dist = best.dist, key = best.key, walk_point = true }
                else
                    best = { name = "Objective", pos = op, dist = d_obj, key = "objective", walk_point = true }
                end
            end
            follow.on = true
        end
    end
    if not best then
        local hint = G.objective_hint()
        say(hint and ("I'm not sure of the exact next spot here. What the walkthrough says: " .. hint)
            or "I'm not sure of the next step here. Press O for the objective.")
        return
    end
    selected = best
    walk.last_dist_said = nil
    local where = describe_position(best.pos, pos, G.facing())
    if follow.on and follow.quiet then
        follow.quiet = false
    else
        say("Next: " .. best.name:gsub("^Path point, ", "") .. ", " .. where .. ".")
    end
    back = nil
    if RE4Access.route then RE4Access.route.go(best) end
end

G.next_step = next_step

-- Read-ahead (10/22, user asked): walkthrough steps per objective, spoken
-- when N has no exact spot. Sources: Push Square / PowerPyx chapter 4-5
-- guides (summaries, not checked in the game yet). Matched on lower case.
G.OBJECTIVE_HINTS = {
    { "ashley in the church", "The stained glass puzzle opens the bars beside the altar. Climb the ladder behind them, follow the upper floor to the iron door; Ashley is behind it." },
    { "escape from the church", "Climb the ladder Ashley lowered, up to the attic, then walk to the attic window: a scene plays where you jump out and catch Ashley. Optional: in the room where Ashley was, shoot the metal container hanging from the ceiling for a Yellow Diamond." },
    { "extraction point", "After the call, go back through the graveyard, where villagers patrol, then through the Village Square and the Farm. A Brute is on the way. Before the bridge, a Wayshrine is on the right. Across the bridge Luis takes you into a house. Optional with Ashley now: the attic of the Chief's manor, a gap in a wall in the Village Square, and the Merchant's request by the Town Hall." },
    { "stand your ground", "Survive in the house. Ashley hides, you don't have to protect her. Board up the downstairs windows with F when you can. When a ladder goes up to the second floor, go upstairs and push it over with F. Grenades help. A Brute comes last: kill it, then follow Ashley out." },
    -- Chapter 6 (10/27; Push Square / PowerPyx summaries, not checked in game)
    { "escape from the village", "Through the gate south of Luis's house to the Checkpoint, a walled area. Its gate out needs the Checkpoint Crank, which is in the house in the middle. Taking the crank starts a big fight with the Chainsaw Sisters; the crank drops from them. Then use the crank on the gate and go east." },
    { "another way around", "Press N for each step. Boost Ashley, then the dungeons and the Dungeon Key, then a blind Garrador: walk, do not run, shoot the parasite on its back. A crank takes 7 seconds of holding F. After the room above, the steps have not been walked yet: the gongs and sword, the chandeliers, the Water Hall and its bridge." },
    { "head for the courtyard", "Press N for each step. On the catapult field the big gate only opens to the cannon. First drop into the cannon tower and shoot the counterweight, that raises the cannon. Then the ladder and a barred door lead back up to the cannon. On the cannon I tell you how to aim: arrow keys, K fires. It breaks the first gate. A second gate opens with F, and the Merchant is past it. Catapults throw rocks, so keep moving when I say Rock coming. Ashley follows you: stay moving, and if I say she is grabbed, go to her. If she dies the game ends." },
    { "flee from the villagers", "A chase, not a boss. Chief Mendez is right behind you. If he grabs you, you die, and fighting does not help. Hold Shift and W the whole time: the route starts by itself and I steer you. Do not press L or K. If I say Ashley is behind you, let go of W a moment, then hold Shift and W again." },
    -- 11/1: the objective has an accented e, so "defeat mendez" never matched
    { "defeat m", "Boss fight with Chief Mendez, in two stages. Stage 1: he comes at you. Hold L: I aim at him. Press K again and again. If he comes close, hold S to back away, then aim again. If I say Evade, press E. If I say Grabbed, press Space. Stage 2: he stays far away on the beams and throws burning wood, two pieces at a time. Standing still kills you. Keep moving sideways with A or D, and shoot in short bursts with L and K. If you burn, let go of L and hold W at once. When health is at half, press I: the game pauses, heal there." },
    { "slaughterhouse", "After Mendez, get out of the burning building. Press N for the way." },
}
function G.objective_hint()
    local ok, ot = pcall(objective_text)
    if not ok or not ot then return nil end
    ot = ot:lower()
    for _, h in ipairs(G.OBJECTIVE_HINTS) do
        if ot:find(h[1], 1, true) then return h[2] end
    end
end

-- Safety check for N's guesses (10/22: the chapter 3 "trail" walked the user
-- 170 m from the church to the Quarry while the objective was in the church).
-- A guessed step far away that ends much further from the objective than
-- Leon is now is dropped; N then falls back to the objective itself or says
-- it is not sure. With no objective point, guesses over 60 m are dropped.
function G.away_from_objective(t, pos)
    if not (t and t.pos and pos) then return false end
    local d = math.sqrt((t.pos.x - pos.x) ^ 2 + (t.pos.z - pos.z) ^ 2)
    if d < 30 then return false end
    local op = G.objective_pos()
    local bad
    if op then
        local now_d = math.sqrt((op.x - pos.x) ^ 2 + (op.z - pos.z) ^ 2)
        local then_d = math.sqrt((op.x - t.pos.x) ^ 2 + (op.z - t.pos.z) ^ 2)
        bad = then_d > now_d + 25
    else
        bad = d > 60
    end
    if bad then
        log.info(string.format("[RE4Access] N safety: dropped %s %.0f m away (leads away from the objective)", tostring(t.name), d))
    end
    return bad
end

-- A locked door between you and a place with no walking route (10/12: the Small
-- Key and Green Herb lie behind the crest-key door 廃村奥の紋章鍵ドア at
-- (211,-139); routes kept failing without saying why).
-- The lock body itself: child "Padlock" (10/12 PM: _CenterObj sits 8 cm off the
-- lock body; a shot on the center at 3.7 m missed).
function G.padlock_point(go, comp)
    local tr = go:call("get_Transform")
    local ch = tr:call("get_Child")
    while ch do
        if ch:call("get_GameObject"):call("get_Name") == "Padlock" then return ch:call("get_Position") end
        ch = ch:call("get_Next")
    end
    return comp:get_field("_CenterObj"):call("get_Transform"):call("get_Position")
end

-- Where to stand to KICK the nearest unbroken padlock (10/12 PM: F kicked the
-- boathouse door open; user wants routes to take them there, saving bullets):
-- 0.9 m in front of the lock, on your side of its door.
function G.padlock_kick_spot(from)
    local best
    for _, t in ipairs(scan_things(from, 40)) do
        if t.name == "Padlock" and (not best or t.dist < best.dist) then best = t end
    end
    if not best then return nil end
    local spot
    pcall(function()
        local comp = best.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPadlock"))
        local lp = G.padlock_point(best.go, comp)
        local door = comp:get_field("_GmDoor"):call("get_GameObject")
        local hinge = door:call("get_Transform"):call("get_Position")
        local c = door_center({ go = door, pos = hinge, key = door:get_address() }) or lp
        local wx, wz = c.x - hinge.x, c.z - hinge.z
        local wl = math.sqrt(wx * wx + wz * wz)
        if wl < 0.05 then return end
        local nx, nz = wz / wl, -wx / wl
        local side = ((from.x - c.x) * nx + (from.z - c.z) * nz) >= 0 and 1 or -1
        spot = { x = lp.x + nx * side * 0.9, y = hinge.y, z = lp.z + nz * side * 0.9 }   -- door floor (10/14)
    end)
    return spot
end

function G.is_shelf(go)
    local ok, n = pcall(function() return go:call("get_Name") end)
    return ok and n and n:find("棚", 1, true) ~= nil
end

-- A spot 3.5-6 m from the nearest unbroken padlock within 40 m, with a clear shot
-- and a walking way (10/12 PM: boathouse door padlock (224.7,-126.9); N only said
-- "behind a locked door, it has a padlock" and the user walked into walls).
function G.padlock_spot(from)
    local best
    for _, t in ipairs(scan_things(from, 40)) do
        if t.name == "Padlock" and (not best or t.dist < best.dist) then
            local c
            pcall(function()
                local comp = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPadlock"))
                if comp:get_field("_CurrentDurability") <= 0 then return end
                local q = G.padlock_point(t.go, comp)
                c = { x = q.x, y = q.y, z = q.z }
            end)
            if c then best = { dist = t.dist, c = c } end
        end
    end
    if not best then return nil end
    return G.shoot_spot(best.c, from, { 4, 5, 6, 3.5 })
end

function G.locked_door_between(from, goal)
    local straight = math.sqrt((goal.x - from.x) ^ 2 + (goal.z - from.z) ^ 2)
    local best
    for _, d in ipairs(doors_near(from, 35)) do
        local gn = ""
        pcall(function() gn = d.go:call("get_Name") end)
        local crest = gn:find("紋章鍵", 1, true) ~= nil
        if crest or door_locked(d.go) then
            local a = d.dist
            local b = math.sqrt((goal.x - d.pos.x) ^ 2 + (goal.z - d.pos.z) ^ 2)
            -- the place must lie beyond the door, on the far side from you
            local beyond = ((goal.x - d.pos.x) * (from.x - d.pos.x) + (goal.z - d.pos.z) * (from.z - d.pos.z)) < 0
            if beyond and a + b < straight + 8 and (not best or a < best.dist) then
                best = d
                best.crest = crest
            end
        end
    end
    if not best then return nil end
    local kt
    -- Slide bolt on the far side (10/13: Chapter 2 factory, the room with Leon's
    -- gear): no key opens it; a crank opens a shutter that leads round instead.
    if G.gimmick_near(best.pos, "スライド錠", 2.5) then
        return "behind a door bolted from the other side, " .. describe_position(best.pos, from, G.facing())
            .. ". No key opens it. Find another way in", true
    end
    pcall(function() kt = RE4Access.route.door_opener_text(best) end)
    if not kt then
        kt = best.crest and "It needs a crest key, which you don't have yet. Come back later in the story."
            or "It is locked, and I can't tell what opens it: maybe a key, maybe it opens from the other side. Look for another way in."
    end
    return "behind a locked door, " .. describe_position(best.pos, from, G.facing()) .. ". " .. kt
end

-- Nearest gimmick whose Japanese object name contains `word`, within `range`
-- of `pos`: returns its position and distance.
function G.gimmick_near(pos, word, range)
    local best, bd
    pcall(function()
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then
                pcall(function()
                    local go = core:call("get_GameObject")
                    if go:call("get_Name"):find(word, 1, true) then
                        local q = go:call("get_Transform"):call("get_Position")
                        local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
                        if d <= range and (not bd or d < bd) then best, bd = { x = q.x, y = q.y, z = q.z }, d end
                    end
                end)
            end
        end
    end)
    return best, bd
end

-- Bear traps near a position, so routes keep away from them.
function G.trap_positions(pos)
    local out = {}
    for _, t in ipairs(scan_things(pos, 150)) do
        if (t.name == "Bear trap" or t.name == "Bomb trap") and G.trap_live(t.go) then out[#out + 1] = { x = t.pos.x, z = t.pos.z } end
    end
    return out
end

-- Tripwire bombs (GmSensorBomb): the laser runs from its Sender to its Receiver
-- child; walking through it sets the bomb off (10/12: took the user from full
-- to 13 percent). Returns live bombs with their laser ends and aim point.
-- Is a point within 2.2 m of a live bear trap? (cached, 1 s)
local beartrap_cache = { at = -10, list = {} }
function G.near_bear_trap(p)
    local now = os.clock()
    if now - beartrap_cache.at > 1 then
        beartrap_cache.at = now
        beartrap_cache.list = {}
        local pos = G.player_pos()
        if pos then
            for _, t in ipairs(scan_things(pos, 80)) do
                if t.name == "Bear trap" and G.trap_live(t.go) then beartrap_cache.list[#beartrap_cache.list + 1] = t.pos end
            end
        end
    end
    for _, q in ipairs(beartrap_cache.list) do
        if (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 < 4.84 and math.abs(q.y - p.y) < 2 then return true end
    end
    return false
end

-- Is a point within 2 m of a live tripwire laser? (cached list, 1 s)
local laser_cache = { at = -10, list = {} }
function G.near_laser(p)
    local now = os.clock()
    if now - laser_cache.at > 1 then
        laser_cache.at = now
        local pos = G.player_pos()
        laser_cache.list = pos and G.laser_bombs(pos, 80) or {}
    end
    for _, b in ipairs(laser_cache.list) do
        local dx, dz = b.b.x - b.a.x, b.b.z - b.a.z
        local l2 = dx * dx + dz * dz
        local t = l2 > 0 and math.max(0, math.min(1, ((p.x - b.a.x) * dx + (p.z - b.a.z) * dz) / l2)) or 0
        if math.sqrt((p.x - b.a.x - dx * t) ^ 2 + (p.z - b.a.z - dz * t) ^ 2) < 2 and math.abs(p.y - b.a.y) < 2.5 then return true end
    end
    return false
end

-- The point to shoot on a bomb (its AimAssistPointObj).
function G.bomb_aim_point(go)
    local c
    pcall(function()
        local tr = go:call("getComponent(System.Type)", t_bomb):get_field("_Sender"):call("get_Transform")
        local q = tr:call("get_Position")
        local ch = tr:call("get_Child")
        while ch do
            if ch:call("get_GameObject"):call("get_Name") == "AimAssistPointObj" then q = ch:call("get_Position") break end
            ch = ch:call("get_Next")
        end
        c = { x = q.x, y = q.y, z = q.z }
    end)
    return c
end

-- Is the line from an eye point to a target free of walls, fences and rocks?
-- (10/12: from the fishing-village entrance a fence 1.7 m ahead took every shot.)
-- A wall well before the target (not the thing it hangs on). 10/14: the
-- Hexagonal Emblem is mounted on a post on the Valley roof; the ray hit the post
-- 0.4 m short of it and the mod said "behind a wall" with Leon right there.
function G.wall_before(eye, tgt)
    local clear, d = G.clear_shot(eye, tgt)
    if clear then return false end
    local full = math.sqrt((tgt.x - eye.x) ^ 2 + (tgt.y - eye.y) ^ 2 + (tgt.z - eye.z) ^ 2)
    return not (d and d > full - 0.8)
end

function G.clear_shot(eye, tgt)
    local R = RE4Access.route
    if not R then return true end
    local full = math.sqrt((tgt.x - eye.x) ^ 2 + (tgt.y - eye.y) ^ 2 + (tgt.z - eye.z) ^ 2)
    -- layer 8 = tree branches that stop bullets (10/20: Velvet Blue nest, the
    -- crosshair sat on it but 4 shots hit a branch 1.5 m under it)
    for _, cfg in ipairs({ { layer = 2, mask = 788, group = 12 }, { layer = 4, mask = 0xFFFFFFFF, group = 0 }, { layer = 8, mask = 0xFFFFFFFF, group = 0 } }) do
        local ok, hit, d = pcall(R.cast, eye.x, eye.y, eye.z, tgt.x, tgt.y, tgt.z, cfg)
        -- hits in the first 0.3 m are Leon's own head/arm, not a wall (10/18:
        -- tripwire bomb by the cliff path, eye at 1.6 m hit at 0.02 m, so L
        -- flipped between the bomb and "No enemy in sight" and never said fire)
        -- layer 4 (bodies) also hits Leon's raised gun/arm at 0.6 m while aiming
        local own = cfg.layer == 4 and 1.0 or 0.3
        if ok and hit and d and d > own and d < full - 0.3 then return false, d end
    end
    return true
end

-- A spot 6-12 m from the bomb with a clear line to it, that you can walk to
-- without crossing its laser; nearest to you first.
function G.bomb_shoot_spot(bomb, pos)
    -- 4-6 m first (10/12 PM: inside the boathouse no spot 8-12 m away sees the bomb)
    return G.shoot_spot(G.bomb_aim_point(bomb.go), pos, { 5, 4.5, 6, 4, 8 })
end

-- A floor spot at one of the given distances from a target, with a clear line to
-- it, reachable without crossing a laser and not next to a bear trap.
function G.shoot_spot(tgt, pos, radii)
    local R = RE4Access.route
    if not R or not tgt then return nil end
    local best, best_len
    for _, r in ipairs(radii) do
        for k = 0, 17 do
            local a = k * math.pi / 9
            local x, z = tgt.x + math.sin(a) * r, tgt.z + math.cos(a) * r
            local g = R.cast(x, tgt.y + 3, z, x, tgt.y - 4, z)
            if not g or math.abs(g.y - pos.y) >= 3 then g = R.cast(x, pos.y + 2.5, z, x, pos.y - 3, z) end
            if g and math.abs(g.y - pos.y) < 3 and G.clear_shot({ x = x, y = g.y + 1.5, z = z }, tgt) then
                local spot = { x = x, y = g.y, z = z }
                local pts, len
                -- at least 3.5 m from any live trap (10/12: caught right after arriving)
                local trap_near = G.near_bear_trap(spot)
                for _, tp in ipairs(G.trap_positions(spot)) do
                    if (tp.x - x) ^ 2 + (tp.z - z) ^ 2 < 12.25 then trap_near = true end
                end
                if not trap_near then pts, len = R.nav_points(pos, spot) end
                if pts then
                    local _, lasers = R.avoid_traps(pts)
                    if #lasers == 0 and (not best_len or len < best_len) then best, best_len = spot, len end
                end
            end
        end
        if best then break end
    end
    return best, best_len
end

function G.laser_bombs(pos, range)
    local out = {}
    for _, t in ipairs(scan_things(pos, range or 80)) do
        if t.name == "Bomb trap" and G.trap_live(t.go) then
            pcall(function()
                local b = t.go:call("getComponent(System.Type)", t_bomb)
                local s = b:get_field("_Sender"):call("get_Transform"):call("get_Position")
                local r = b:get_field("_Receiver"):call("get_Transform"):call("get_Position")
                out[#out + 1] = { pos = t.pos, dist = t.dist, key = t.key, go = t.go,
                    a = { x = s.x, y = s.y, z = s.z }, b = { x = r.x, y = r.y, z = r.z } }
            end)
        end
    end
    return out
end

local function toggle_route()
    local R = RE4Access.route
    if not R then say("Route finder not loaded") return end
    if R.active() then follow.on = false G.chase = nil R.stop() return end
    if not selected then say("Nothing selected. Use brackets to pick something.") return end
    back = nil
    -- A place you picked yourself: don't carry on to the objective on arrival
    -- (10/12: arriving at the lever started a 24 m route to the lake).
    follow.on = false
    if selected.ctx then
        -- 10/13 user: "Backslash should take me to the enemy". Route to where it
        -- is now; update_chase re-routes as it moves and stops 3 m short.
        local okp, q = pcall(function() return selected.ctx:call("get_Position") end)
        if okp and q then selected.pos = { x = q.x, y = q.y, z = q.z } end
        G.chase = { ctx = selected.ctx, at = os.clock(), goal = selected.pos }
        R.go({ name = "the enemy", pos = selected.pos })
        return
    end
    G.chase = nil
    if selected.building and RE4Access.places then RE4Access.places.go(selected) return end
    R.go(selected)
end

-- Walking to an enemy: re-route when it moved 2 m, stop 3 m short and turn to it.
local function update_chase(pos, now)
    local c = G.chase
    if not c or now - c.at < 0.5 then return end
    c.at = now
    local R = RE4Access.route
    local live = true
    pcall(function() live = c.ctx:call("get_HitPoint"):call("get_IsLive") end)
    if not live then G.chase = nil if R and R.active() then R.stop(true) end say("Enemy down.") return end
    local ok, q = pcall(function() return c.ctx:call("get_Position") end)
    if not ok or not q then G.chase = nil return end
    local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
    if d < 3.2 then
        G.chase = nil
        if R and R.active() then R.stop(true) end
        face_point({ x = q.x, y = q.y + 1.2, z = q.z }, false, true)
        say("Enemy right in front, " .. math.floor(d + 0.5) .. " meters. Hold L and press K to shoot, or hold Space and press K to slash.", true)
        return
    end
    local moved = math.sqrt((q.x - c.goal.x) ^ 2 + (q.z - c.goal.z) ^ 2)
    if R and moved > 2 then
        c.goal = { x = q.x, y = q.y, z = q.z }
        RE4Access.speak_hold = true
        R.go({ name = "the enemy", pos = c.goal })
        RE4Access.speak_hold = nil
    elseif R and not R.active() then
        G.chase = nil
    end
end

-- ---------------- what now? (Shift+Slash, the question mark key) ----------------
-- 10/13 (user: "how would I know this if you had not told me?"): a sighted player
-- sees the bolt on the door and the crank on the wall. This says what blocks the
-- way to the objective, then the things nearby you can use, most likely first.
-- It selects the first one (Shift+Backslash walks there); pressing again within
-- 30 s moves on to the next suggestion.
local USE_RANK = {
    ["Crank, hold F to turn it"] = 1, Lever = 1, ["Machine slot"] = 1, Wayshrine = 1, ["Cart, push it"] = 1,
    Trapdoor = 1, ["Key Hole"] = 1, ["Hold Handle"] = 1, Ladder = 2, Window = 2, Gate = 3, Door = 4,
}
local NOT_USEFUL = {
    ["Breakable crate"] = true, Barrel = true, ["Bear trap"] = true, ["Bomb trap"] = true, Crow = true,
    ["Map Icon Only"] = true, ["Door Lock"] = true, ["Correlated Shutter"] = true, Padlock = true, Enemy = true,
}
local whatnow = { list = nil, idx = 0, at = -100 }

local function suggestions(pos)
    local R = RE4Access.route
    local cands = {}
    for _, t in ipairs(scan_things(pos, 35)) do
        local rank = USE_RANK[t.name]
        local is_path = t.name:sub(1, 10) == "Path point"
        if is_path then rank = (not visited[t.key] and not G.story_done[t.key]) and 2 or nil end
        if not rank and not NOT_USEFUL[t.name] and not KNOWN[t.name] and not is_path then rank = 5 end
        if rank and math.abs(t.pos.y - pos.y) < 6 then
            local done = false
            pcall(function()
                local core = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore"))
                done = core:call("get_Context"):call("hasDoneForMap")
            end)
            if t.name == "Door" or t.name == "Gate" then
                -- open doors are not news; locked ones are listed by the blocker line
                local okd, open = pcall(G.door_is_open, t.go)
                local okl, locked = pcall(door_locked, t.go)
                if (okd and open) or (okl and locked) then done = true end
            end
            if not done then cands[#cands + 1] = { t = t, rank = rank } end
        end
    end
    -- Key items lying around (keys, emblems, cranks) count as puzzle pieces.
    for _, it in ipairs(items(pos, 35)) do
        local n = it.name:lower()
        if n:find("key") or n:find("emblem") or n:find("crank") or n:find("cog") then
            cands[#cands + 1] = { t = it, rank = 1 }
        end
    end
    table.sort(cands, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.t.dist < b.t.dist
    end)
    -- Only places Leon can walk to (checked for the first few, it costs time).
    local out = {}
    for _, c in ipairs(cands) do
        if #out >= 4 then break end
        local ok, pts = true, true
        if R and c.t.dist > 3 then ok, pts = pcall(R.nav_points, pos, c.t.pos) end
        if ok and pts then out[#out + 1] = c.t end
    end
    return out
end

local function what_now()
    local pos = G.player_pos()
    if not pos then return end
    if G.timed_target and G.timed_target() then
        local tt = G.timed_target()
        selected = tt
        say("The shutter is open but closing. Sprint to it: Shift and W, and follow the route. Press N if the route stopped.", true)
        return
    end
    local now = os.clock()
    local f = G.facing()
    -- Pressed again soon: next suggestion.
    if whatnow.list and now - whatnow.at < 30 and #whatnow.list > 0 then
        whatnow.idx = whatnow.idx % #whatnow.list + 1
        whatnow.at = now
        local t = whatnow.list[whatnow.idx]
        selected = t
        walk.last_dist_said = nil
        say(t.name .. ", " .. describe_position(t.pos, pos, f) .. ". " .. whatnow.idx .. " of " .. #whatnow.list .. ". Shift+Backslash walks there.")
        return
    end
    local parts = {}
    local okt, ot = pcall(objective_text)
    if okt and ot then parts[#parts + 1] = "Objective: " .. ot end
    local op = G.objective_pos()
    local blocked = false
    if op then
        local R = RE4Access.route
        local okn, pts = false, nil
        if R then okn, pts = pcall(R.nav_points, pos, op) end
        local okl, msg = pcall(G.locked_door_between, pos, op)
        if okl and msg then
            blocked = true
            parts[#parts + 1] = "The way there is " .. msg:gsub("%.$", "")
        elseif okn and pts then
            parts[#parts + 1] = "The way there is open. Press N to walk toward it"
        elseif R and not R.cast(op.x, op.y + 0.5, op.z, op.x, op.y - 3, op.z) then
            parts[#parts + 1] = "It is far away, in a part of the map not loaded yet. Press N to head that way"
        else
            blocked = true
            parts[#parts + 1] = "I found no walking way there from here"
        end
    end
    local okp, ps = pcall(puzzle_step, pos)
    local list = suggestions(pos)
    if okp and ps then table.insert(list, 1, ps) end
    whatnow.list, whatnow.idx, whatnow.at = list, 0, now
    if #list == 0 then
        parts[#parts + 1] = blocked and "Nothing to use nearby. Explore the rooms you can reach; press Semicolon to browse everything"
            or "Nothing special to use nearby"
    else
        local t = list[1]
        whatnow.idx = 1
        selected = t
        walk.last_dist_said = nil
        parts[#parts + 1] = (blocked and "Try this: " or "Nearby to use: ") .. t.name .. ", " .. describe_position(t.pos, pos, f)
            .. ". Shift+Backslash walks there"
        if #list > 1 then parts[#parts + 1] = "Press question mark again for " .. (#list - 1) .. " more" end
    end
    say(table.concat(parts, ". ") .. ".", true)
end
G.what_now = what_now

-- ---------------- looting ----------------
-- Comma: pick the nearest item not picked up yet (ground, drawer, chest,
-- crate), same floor first. Shift+Comma: next one in that order. It only
-- selects: walk there yourself, or Backslash to face it / Shift+Backslash route.
local LOOT_RANGE = 60
local loot = { list = nil, idx = 0, at = -100 }

-- Inside a building (10/13, user wants "the loot is in a house"): a roof above
-- the item and walls on at least 3 of 4 sides within 12 m. Only ever says
-- "inside"; when the rays can't tell, nothing is added.
local indoors_cache = {}
function G.indoors(t)
    local c = indoors_cache[t.key]
    if c ~= nil then return c end
    local R = RE4Access.route
    if not (R and R.cast) then return false end
    local p = t.pos
    local ok, res = pcall(function()
        if not R.cast(p.x, p.y + 0.6, p.z, p.x, p.y + 10, p.z) then return false end
        local walls = 0
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            if R.cast(p.x, p.y + 1.2, p.z, p.x + d[1] * 12, p.y + 1.2, p.z + d[2] * 12) then walls = walls + 1 end
        end
        return walls >= 3
    end)
    c = ok and res == true
    indoors_cache[t.key] = c
    return c
end
local function where_text(t, pos)
    local s = describe_position(t.pos, pos, G.facing())
    if t.item and G.indoors(t) then
        local here = G.indoors({ key = "leon", pos = pos })
        indoors_cache.leon = nil
        s = (here and "indoors" or "inside a building") .. ", " .. s
    end
    return s
end
local function loot_next(next_one)
    local pos = G.player_pos()
    if not pos then return end
    local now = os.clock()
    if not next_one or not loot.list or now - loot.at > 60 then
        local l = {}
        -- locked ones (need a key item) can't be looted yet
        for _, t in ipairs(items(pos, LOOT_RANGE)) do if not t.locked then l[#l + 1] = t end end
        table.sort(l, function(a, b)
            return a.dist + math.abs(a.pos.y - pos.y) * 10 < b.dist + math.abs(b.pos.y - pos.y) * 10
        end)
        loot.list, loot.idx = l, 0
    end
    loot.at = now
    if #loot.list == 0 then say("Nothing left to loot nearby") return end
    loot.idx = loot.idx % #loot.list + 1
    local t = loot.list[loot.idx]
    selected = t
    walk.last_dist_said = nil
    say("Loot: " .. t.name .. ", " .. where_text(t, pos) .. ". " .. loot.idx .. " of " .. #loot.list, true)
end

function G.toggle_walk_reports()
    G.walk_reports = not G.walk_reports
    save_settings()
    say(G.walk_reports and "Walking reports on: distance every 10 meters." or "Walking reports off. You still hear turns, blocked, doors and arrival. J tells the distance.", true)
end

local function toggle_short()
    G.short = not G.short
    save_settings()
    say(G.short and "Short messages." or "Full messages, with the keys to press.", true)
end

-- Period: how far to the next turn or door, and what comes after (10/13, user).
-- Shift+Period switches spoken directions / automatic turning.
local function next_turn()
    local pos = G.player_pos()
    if not pos then return end
    local R = RE4Access.route
    if R and R.active() then
        say(R.next_turn_text(pos) or "No route", true)
    elseif selected and selected.pos then
        say(selected.name .. ", " .. describe_position(selected.pos, pos, G.facing()) .. ". No route; Shift+Backslash starts one.", true)
    else
        say("No route. Pick something with brackets or Comma, then Shift+Backslash.", true)
    end
end

local function toggle_directions()
    G.spoken = not G.spoken
    G.guide_reset()
    save_settings()
    say(G.spoken and "Spoken directions. You turn yourself with the arrow keys; I say which way."
        or "Automatic turning. Routes turn the camera for you.", true)
end

-- ---------------- breadcrumb trail ----------------
-- Every 2 metres walked a point is stored. B turns on "trail back": the
-- camera turns toward the previous point; each time you reach one it turns
-- to the next, so holding W walks you back the way you came.
local trail = {}            -- list of positions, oldest first
local TRAIL_STEP, TRAIL_MAX = 2.0, 600
back = nil                  -- { target = index } while following the trail back

local function trail_length_from(i, pos)
    local total, prev = 0, pos
    for j = i, 1, -1 do
        local t = trail[j]
        total = total + math.sqrt((t.x - prev.x) ^ 2 + (t.z - prev.z) ^ 2)
        prev = t
    end
    return total
end

local function update_trail(pos)
    pos = { x = pos.x, y = pos.y, z = pos.z }   -- keep a copy, not a live reference
    local last = trail[#trail]
    if not last then trail[1] = pos return end
    local d = math.sqrt((pos.x - last.x) ^ 2 + (pos.z - last.z) ^ 2)
    if d > 15 then
        -- Big jump (cutscene, area change): start a new trail.
        trail = { pos }
        if back then back = nil say("Trail reset", false) end
        return
    end
    if back then
        local t = trail[back.target]
        local dt = math.sqrt((t.x - pos.x) ^ 2 + (t.z - pos.z) ^ 2)
        if G.spoken then G.guide_to(t, os.clock()) end
        if dt < 1.2 then
            -- Reached this point: drop it and everything after it.
            for j = #trail, back.target, -1 do trail[j] = nil end
            back.target = back.target - 1
            if back.target < 1 then
                back = nil
                trail = { pos }
                say("End of trail")
            else
                face_point(trail[back.target])
            end
        end
        return
    end
    if d >= TRAIL_STEP then
        trail[#trail + 1] = pos
        if #trail > TRAIL_MAX then table.remove(trail, 1) end
    end
end

local function toggle_back()
    if back then back = nil say("Trail back off") return end
    if RE4Access.route then RE4Access.route.stop(true) end
    local pos = G.player_pos()
    if not pos then return end
    -- Skip points that are right next to us.
    local i = #trail
    while i >= 1 and math.sqrt((trail[i].x - pos.x) ^ 2 + (trail[i].z - pos.z) ^ 2) < 1.5 do i = i - 1 end
    if i < 1 then say("No trail yet. Walk somewhere first.") return end
    back = { target = i }
    face_point(trail[i])
    say(string.format("Trail back on, %d meters. Hold W.", math.floor(trail_length_from(i, pos) + 0.5)))
end
G.trail = function() return trail end

-- Self-calibration: if the camera ended up turned the wrong way, flip the
-- sign once and turn again.
local function check_turn()
    local tc = G.turn_check
    if not tc or os.clock() < tc.at then return end
    G.turn_check = nil
    local f = G.facing()
    if not f then return end
    local err = (tc.want - f + 540) % 360 - 180
    log.info(string.format("[RE4Access] turn check: want %.0f got %.0f err %.0f sign %d", tc.want, f, err, YAW_SIGN))
    -- The sign is verified; a big error now means something else moved the camera
    -- (aim lock, a cutscene), so only log it. Flipping here once mirrored the aim.
    if false and math.abs(err) > 25 and not tc.retried then
        YAW_SIGN = -YAW_SIGN
        local pc = player_camera()
        if pc then
            local yaw = pc:get_field("_Yaw") + YAW_SIGN * math.rad(err)
            if yaw > math.pi then yaw = yaw - 2 * math.pi elseif yaw < -math.pi then yaw = yaw + 2 * math.pi end
            pc:set_field("_Yaw", yaw)
            G.turn_check = { want = tc.want, at = os.clock() + 0.4, retried = true }
        end
    end
end

local function where_am_i()
    local pos = G.player_pos()
    if not pos then return end
    local f = G.facing()
    local s = f and ("Facing " .. compass(f)) or "Facing unknown"
    local okl, lt = pcall(G.ladder_end, pos)
    say(s .. ". " .. (G.state_text or "") .. ((okl and lt) and (". " .. lt) or ""))
end

-- Apostrophe: run or fight? (10/14: "not sure when I need to fight and when it
-- is safe to run", died many times in the Valley.) Looks at where you are going
-- (the route's next point, else the selected thing, else straight ahead).
-- Run or fight: "fight_now" (enemy under 3.5 m), "fight_first" (enemy in your
-- way), "run" (enemies beside/behind), "far", "safe". Looks where you are going:
-- the route's next point, else the selected thing, else straight ahead.
function G.fight_verdict(pos)
    local list = enemies(pos, 25)
    if #list == 0 then return "safe", list end
    local f = G.facing() or 0
    local goal
    local R = RE4Access.route
    if R and R.active() and R.next_point then goal = R.next_point() end
    if not goal and selected and selected.pos and not selected.ctx then goal = selected.pos end
    local go_dir = goal and heading_of(goal.x - pos.x, goal.z - pos.z) or f
    local goal_d = goal and math.sqrt((goal.x - pos.x) ^ 2 + (goal.z - pos.z) ^ 2) or 30
    local ahead = 0
    for _, e in ipairs(list) do
        if math.abs(e.pos.y - pos.y) < 3 then
            local rel = math.abs((heading_of(e.pos.x - pos.x, e.pos.z - pos.z) - go_dir + 540) % 360 - 180)
            if rel < 50 and e.dist < math.max(goal_d, 8) + 3 then ahead = ahead + 1 end
        end
    end
    local c = list[1]
    if c.dist < 7 and math.abs(c.pos.y - pos.y) < 2 then return "fight_now", list, ahead end   -- 7 m (was 3.5): more time to react, user 10/14
    if ahead > 0 and c.dist < 20 then return "fight_first", list, ahead end
    if c.dist > 15 then return "far", list, ahead end
    return "run", list, ahead
end

-- Apostrophe: run or fight? (10/14: "not sure when I need to fight and when it
-- is safe to run", died many times in the Valley.)
local function enemy_report()
    local pos = G.player_pos()
    if not pos then return end
    local v, list, ahead = G.fight_verdict(pos)
    if v == "safe" then say("Safe. No enemies near. Go.", true) return end
    local c = list[1]
    local where = describe_position(c.pos, pos, G.facing())
    local n = #list
    if v == "fight_now" then
        say("Fight now. Enemy " .. where .. ". Hold L and press K, or Space and K to slash. Then move.", true)
    elseif v == "fight_first" then
        say("Fight first. " .. ahead .. (ahead == 1 and " enemy is" or " enemies are") .. " in your way. Closest " .. where .. ". Hold L, press K.", true)
    elseif v == "far" then
        say("Safe to go. " .. n .. (n == 1 and " enemy" or " enemies") .. " far away, closest " .. math.floor(c.dist + 0.5) .. " meters. Hold W.", true)
    else
        say("Run now. Your way is clear; " .. n .. (n == 1 and " enemy" or " enemies") .. " beside or behind you, closest " .. where .. ". Hold Shift and W.", true)
    end
end

-- Fight sound (10/14, user: "a sound to let me know when to fight; if I can
-- run no sound is needed"): REAccess_fight.wav when the verdict turns to fight,
-- again every 6 s while it stays so. Silent when running is fine.
-- After Continue on the Valley lookout platform Leon sometimes hangs in a jump
-- (PlayerContext IsTerrainAction + IsJumping) and W does nothing: "Blocked" over
-- and over (10/14, twice). Enter (the confirm key) frees him.
local stuck_jump = { since = nil, said = 0 }
function G.is_paused()
    local pz = false
    pcall(function() pz = sdk.get_managed_singleton("chainsaw.GuiManager"):call("get_hasOccupiedPauseMenuSystemLock") and true or false end)
    return pz
end
local function update_stuck_jump(now)
    local pos = G.player_pos()
    if not pos then return end
    -- 10/14: coming back from another window the pause menu is still open; W
    -- does nothing and the route said "Blocked" over and over.
    if G.is_paused() then
        if reframework:is_key_down(0x57) then
            stuck_jump.psince = stuck_jump.psince or now
            if now - stuck_jump.psince > 1.2 and now - stuck_jump.said > 6 then
                stuck_jump.said = now
                say("The game is paused. Press Enter on Return to game, then hold W.", true)
            end
        else
            stuck_jump.psince = nil
        end
        return
    end
    stuck_jump.psince = nil
    local pc = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef")
    local hang = pc and pc:call("get_IsTerrainAction") and pc:call("get_IsJumping")
    local w = reframework:is_key_down(0x57)
    if hang and w then
        if not stuck_jump.since then stuck_jump.since, stuck_jump.pos = now, pos end
        local moved = math.sqrt((pos.x - stuck_jump.pos.x) ^ 2 + (pos.z - stuck_jump.pos.z) ^ 2)
        if moved < 0.2 and now - stuck_jump.since > 2 and now - stuck_jump.said > 8 then
            stuck_jump.said = now
            say("Leon is stuck. Press Enter once, then hold W.", true)
        end
    else
        stuck_jump.since = nil
    end
end

-- Grenade timing (10/14, user asked "a word that tells me the best time to throw
-- the grenade or the flash"): "Flash now" when 3+ enemies are within 4 m of you;
-- "Grenade now" when 3+ are bunched 5-12 m ahead (60 degree cone) and none is
-- closer than 4 m (the blast would hurt you). Only if you carry one. 12 s apart.
local gren = { at = 0, said = 0 }
local function carried(word)
    local n = 0
    pcall(function()
        local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
            local c = e:get_field("value")
            if c and c:get_type_definition():get_full_name() == "chainsaw.CsInventoryController" then
                local lst = c:call("getInventoryItemList()")
                for i = 0, lst:call("get_Count") - 1 do
                    local item = lst:call("get_Item", i):get_field("<Item>k__BackingField")
                    local nm = RE4Access.menu.clean(msg_get:call(nil, mm:call("getItemNameMsgId", item:get_field("_ItemId"))))
                    if nm == word then n = n + (item:get_field("_CurrentItemCount") or 1) end
                end
            end
        end
    end)
    return n
end
G.carried = carried
local function update_grenade_cue(now)
    if now - gren.at < 0.5 or now - gren.said < 12 then return end
    gren.at = now
    if G.is_paused() or G.is_dead then return end
    local pos = G.player_pos()
    if not pos then return end
    local list = enemies(pos, 12)
    if #list < 3 then return end
    local f = G.facing() or 0
    local near4, ahead = 0, 0
    for _, e in ipairs(list) do
        if math.abs(e.pos.y - pos.y) < 2.5 then
            if e.dist < 4 then near4 = near4 + 1 end
            local rel = math.abs((heading_of(e.pos.x - pos.x, e.pos.z - pos.z) - f + 540) % 360 - 180)
            if e.dist >= 5 and rel < 30 then ahead = ahead + 1 end
        end
    end
    if near4 >= 3 and carried("Flash Grenade") > 0 then
        gren.said = now
        -- 10/27 user: "how do I throw the flash grenade?" - say how, every time
        if not G.combat_quiet then say("Flash now, " .. near4 .. " on you. Press 2, then hold L and press K to throw it.", true) end
    elseif near4 == 0 and ahead >= 3 and carried("Hand Grenade") > 0 then
        gren.said = now
        if not G.combat_quiet then say("Grenade now. " .. ahead .. " ahead.", true) end
    end
end

local fight_cue = { at = 0, last = 0, was = false }
local function update_fight_cue(now)
    if now - fight_cue.at < 0.4 then return end
    fight_cue.at = now
    if G.state_text ~= "In control" or G.is_dead then fight_cue.was = false return end
    -- not while paused (10/14: thudded every 6 s for minutes during a phone call)
    local paused = false
    pcall(function() paused = sdk.get_managed_singleton("chainsaw.GuiManager"):call("get_hasOccupiedPauseMenuSystemLock") and true or false end)
    if paused or not has_focus() then fight_cue.was = false return end
    local pos = G.player_pos()
    if not pos then return end
    local v = G.fight_verdict(pos)
    local fight = v == "fight_now" or v == "fight_first"
    if fight and (not fight_cue.was or now - fight_cue.last > 6) then
        fight_cue.last = now
        if RE4Access.sound and G.fight_sound then RE4Access.sound("fight") end
    end
    fight_cue.was = fight
end

-- ---------------- state announcements ----------------

local STATE_NAMES = {
    ["chainsaw.EventCameraController"] = "Cutscene",
    ["chainsaw.PlayerCameraController"] = "You have control",
    ["chainsaw.MerchantCameraController"] = "Merchant",
    ["chainsaw.GameOverCameraController"] = "Game over",
    -- 10/19 lake monster fight: the boat has its own camera; without this the
    -- state stayed "Cutscene" and no hot key worked
    ["chainsaw.VehicleCameraController"] = "In the boat",
}
local last_cam, cam_since, announced_cam = nil, 0, nil
G.state_text = nil

local was_paused = false
local function update_pause()
    local gm = sdk.get_managed_singleton("chainsaw.GuiManager")
    if not gm then return end
    local paused = gm:call("get_hasOccupiedPauseMenuSystemLock") and true or false
    if paused ~= was_paused then
        was_paused = paused
        -- opening is announced by the menu reader. Wait a moment: Quit Game also ends
        -- the pause, and Leon is gone by then (10/31: "Back in game" on the title screen).
        G.back_in_game_at = not paused and os.clock() + 1 or nil
    end
    if G.back_in_game_at and os.clock() >= G.back_in_game_at then
        G.back_in_game_at = nil
        if G.player_pos() then say("Back in game") end
    end
    pcall(G.focus_pause, paused)
end

-- The game opens its pause menu by itself when its window loses focus (10/18:
-- paused mid-route, the user stuck at "Return to game"). When focus comes back
-- and that pause was the focus one (not Escape), press Return to game for them.
G.fp = { had = true }
function G.focus_pause(paused)
    local fp, now, f = G.fp, os.clock(), has_focus() and true or false
    if not paused then fp.paused_since = nil elseif not fp.paused_since then fp.paused_since = now end
    if fp.had and not f then
        -- the menu can open a moment before the window reports the loss (Alt+Tab)
        local before = paused and fp.paused_since and now - fp.paused_since > 1.0
        fp.lost_at, fp.paused_before, fp.auto, fp.close_at = now, before, false, nil
    elseif not f and fp.lost_at and paused and not fp.paused_before and fp.paused_since and fp.paused_since > fp.lost_at - 1.0 and now - fp.lost_at < 3 then
        fp.auto = true
    elseif f and not fp.had then
        -- 11/9 user: it resumed before he was ready (rocks hit him). Wait 2.5 s, say so.
        if fp.auto and paused then fp.close_at = now + 2.5 RE4Access.speak("Game resumes in 2 seconds.", true) end
        fp.auto = false
    end
    fp.had = f
    if fp.close_at and now >= fp.close_at then
        fp.close_at = nil
        if f and paused then
            local sm = sdk.get_native_singleton("via.SceneManager")
            local sc = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local go = sc:call("findGameObject(System.String)", "Gui_ui0500")
            local b = go and go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InGameMenuGuiBehavior"))
            if b then
                b:call("decideActReturnToGame")
                log.info("[RE4Access] focus pause closed by the mod")
            end
        end
    end
end

local function update_state(now)
    pcall(update_pause)
    local mc = main_camera_controller()
    if not mc then return end
    local busy = tn(mc:get_field("_BusyCameraController"))
    G.cam_busy = busy   -- stained.lua: puzzle view vs walking (10/22)
    if busy ~= last_cam then last_cam, cam_since = busy, now end
    -- Announce only once the camera has stayed the same for half a second.
    if busy ~= announced_cam and now - cam_since > 0.5 then
        announced_cam = busy
        local text = STATE_NAMES[busy]
        -- 10/31: the title screen has this camera too, with no Leon yet: not "You have control"
        if text == "You have control" and not G.player_pos() then
            announced_cam = nil
        elseif text then
            G.state_text = text == "You have control" and "In control" or text
            say(text, false)
            if text == "Cutscene" then
                local pos = G.player_pos()
                if pos then pcall(mark_story_near, pos, 12) end
            end
        end
    end
end

-- ---------------- keys ----------------

local was_down = {}
local function pressed(vk)
    local down = reframework:is_key_down(vk)
    local edge = down and not was_down[vk]
    was_down[vk] = down
    return edge
end

-- ---------------- walking feedback ----------------
-- While W is held: "Blocked" when Leon stops moving, distance updates and
-- "Arrived" for the selected thing.
local function update_walk(now)
    if G.is_paused and G.is_paused() then return end   -- no "Blocked" while the pause menu is open
    local pos = G.player_pos()
    if not pos then return end
    local moving_key = reframework:is_key_down(0x57) or reframework:is_key_down(0x41)
        or reframework:is_key_down(0x53) or reframework:is_key_down(0x44)
    local lp = walk.last_pos
    local moved = lp and math.sqrt((pos.x - lp.x) ^ 2 + (pos.z - lp.z) ^ 2) or 0
    walk.last_pos = pos
    -- Blocked = under 0.15 m in 0.8 s while a walk key is held (10/12: the old
    -- per-frame 2 cm test fired while Leon limped slowly at 1 percent health, so
    -- every route "blocked" at its first point).
    if moving_key and G.state_text == "In control" then
        local an = walk.anchor
        if not an or math.sqrt((pos.x - an.x) ^ 2 + (pos.z - an.z) ^ 2) > 0.15 then
            walk.anchor = { x = pos.x, z = pos.z, at = now }
            walk.still_since, walk.blocked_said = nil, false
        else
            walk.still_since = an.at
            if not walk.blocked_said and now - walk.still_since > 0.8 then
                walk.blocked_said = true
                local R = RE4Access.route
                -- Leon "acting" (PlayerDefine.RestrictionType Acting = 16384): an action or a
                -- small item screen is still open, so he can't walk at all.
                local acting = false
                pcall(function()
                    local pc = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef")
                    -- Acting alone is set in some rooms while walking works (10/12, barn):
                    -- only a walk restriction really means Leon can't move.
                    acting = pc:call("get_IsRestrictionWalk") or pc:call("get_IsRestrictionAll")
                end)
                if G.doc_reading() then
                    say("The document is still open. Press Escape to close it, then walk.")
                elseif acting then
                    say("Leon is busy with an action or an item screen. Press Escape to cancel it, then walk.")
                elseif R and R.active() then
                    R.on_blocked(pos)
                    -- still stuck 2 s later: tell the route again (nudge, then a new way)
                    walk.anchor.at, walk.blocked_said = now + 1.2, false
                else say("Blocked") end
            end
        end
    else
        walk.anchor, walk.still_since, walk.blocked_said = nil, nil, false
    end
    -- Walking feedback every 5 m actually walked (10/12 PM, user: "I don't know if
    -- I am moving"): "25 meters to go" on a route / to the selected place, else
    -- "Walked 5 meters". Quiet while a villager is within 8 m (fight speech first).
    if G.state_text == "In control" then
        local o = walk.odo
        if not o then
            walk.odo = { x = pos.x, z = pos.z, sum = 0 }
        else
            local step = math.sqrt((pos.x - o.x) ^ 2 + (pos.z - o.z) ^ 2)
            if step > 3 then step = 0 end   -- teleport / reload
            o.x, o.z, o.sum = pos.x, pos.z, o.sum + step
            if o.sum >= 10 then
                o.sum = 0
                local fight = G.timed_target and G.timed_target() ~= nil   -- run: countdown only (10/13 "way too much talking")
                for _, e in ipairs(enemies(pos, 8)) do if math.abs(e.pos.y - pos.y) < 3 then fight = true break end end
                if not fight and G.walk_reports then
                    local R = RE4Access.route
                    local left
                    if R and R.active() and R.left then left = R.left(pos) end
                    if not left and selected and selected.pos then
                        left = math.sqrt((selected.pos.x - pos.x) ^ 2 + (selected.pos.z - pos.z) ^ 2)
                    end
                    -- Spoken mode on a route: the next turn with its distance instead (10/13).
                    local turn_text = G.spoken and R and R.active() and R.next_turn_text and R.next_turn_text(pos)
                    if turn_text then say(turn_text, false)
                    elseif left and left >= 2 then say(math.floor(left + 0.5) .. " meters to go", false)
                    elseif not left then say("Walked 10 meters", false) end
                end
            end
        end
    else
        walk.odo = nil
    end
    if selected and moved > 0 then
        local d = math.sqrt((selected.pos.x - pos.x) ^ 2 + (selected.pos.z - pos.z) ^ 2)
        if d < 1.5 and math.abs(selected.pos.y - pos.y) < 1.8 then
            if walk.last_dist_said ~= 0 then
                if not (RE4Access.route and RE4Access.route.active()) then say("Arrived at " .. selected.name) end
                walk.last_dist_said = 0
            end
        else
            -- Keeps the arrival check below in step with the distance.
            local bucket = math.floor(d / 10) * 10
            -- 10/31: no speech here. With a thing selected this said "20 meters" on top of
            -- the "23 meters to go" above, two distance reports for the same walk.
            if walk.last_dist_said == nil or bucket < walk.last_dist_said or walk.last_dist_said == 0 and d > 3 then
                walk.last_dist_said = bucket
            end
        end
    end
end

local last_state_check = 0
-- ---------------- the game's own F prompt (10/13) ----------------
-- The game offers F only from the right spot and facing (the barred gate took
-- "tap A, then F" to find it). chainsaw.InteractManager._LastData[i].HasInteract
-- is true while a prompt is shown. Rising edge: "F ready". Asked to check
-- (Backslash on something close, "door ahead"): if no prompt within 0.8 s,
-- "No F yet: tap A or D to step sideways until I say F ready."
local prompt = { on = false, at = 0, check_at = nil, said_at = -10 }
function G.prompt_active()
    local ok, r = pcall(function()
        local im = sdk.get_managed_singleton("chainsaw.InteractManager")
        for _, d in ipairs(im:get_field("_LastData"):get_elements()) do
            if d:get_field("<HasInteract>k__BackingField") then return true end
        end
        return false
    end)
    return ok and r
end
function G.expect_prompt() prompt.check_at = os.clock() + 0.8 end
-- Which object the prompt belongs to: InteractManager.activateKeySub(list, owner
-- GameObject, sensor, work index, target type, trigger) runs for active prompts.
if not RE4Access.act_hooked2 then
    RE4Access.act_hooked2 = true
    pcall(function()
        local m = sdk.find_type_definition("chainsaw.InteractManager"):get_method("activateKeySub")
        sdk.hook(m, function(args)
            if RE4Access.act_pre then return RE4Access.act_pre(args) end
            pcall(function()
                -- args[4] is Leon; the trigger (args[8]) knows its owner object
                local tr = sdk.to_managed_object(args[8])
                local go = tr and tr:get_field("<Owner>k__BackingField")
                if go then RE4Access.last_act = { go = go, at = os.clock() } end
            end)
        end, function(r) return r end)
    end)
end
RE4Access.act_pre = function(args)
    pcall(function()
        local tr = sdk.to_managed_object(args[8])
        local go = tr and tr:get_field("<Owner>k__BackingField")
        if go then RE4Access.last_act2 = { go = go, at = os.clock() } end
    end)
end
local t_dropitem = sdk.typeof("chainsaw.DropItem")

-- 10/15 (live-verified at the Chief's typewriter): activateKeySub runs for EVERY
-- F candidate each frame, so its owner flipped herb/typewriter twice a second
-- while the screen showed only "Red Herb". What the player sees is the truth:
-- the F icon (Gui_FloatIcon, drawn AT the object: 14.46,14.08,97.61 = typewriter)
-- and the item label (Gui_ui2060 m_item "Red Herb", only for items).
local fi = { at = -10, icons = {}, item_go = nil, item_text = nil, cache_pos = nil, cache = nil }
fi.t_floaticon = sdk.typeof("chainsaw.FloatIconGuiBehavior")
function fi.refresh(now)
    if now - fi.at < 5 and #fi.icons > 0 then return end
    fi.at = now
    fi.icons, fi.item_go, fi.item_text = {}, nil, nil
    local sm = sdk.get_native_singleton("via.SceneManager")
    local sc = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = sc:call("findComponents(System.Type)", sdk.typeof("via.gui.GUI"))
    for i = 0, arr:call("get_Count") - 1 do
        pcall(function()
            local gui = arr:call("get_Item", i)
            local go = gui:call("get_GameObject")
            local nm = go:call("get_Name")
            if nm == "Gui_FloatIcon" then
                fi.icons[#fi.icons + 1] = { go = go, beh = go:call("getComponent(System.Type)", fi.t_floaticon) }
            elseif nm == "Gui_ui2060" then
                fi.item_go = go
                local function walk(c, d)
                    if not c or d > 8 or fi.item_text then return end
                    pcall(function() if c:call("get_Name") == "m_item" then fi.item_text = c end end)
                    local ch; pcall(function() ch = c:call("get_Child") end)
                    while ch do walk(ch, d + 1); local nx; pcall(function() nx = ch:call("get_Next") end); ch = nx end
                end
                walk(gui:call("get_View"), 0)
            end
        end)
    end
end
-- Position of the F icon on screen now (nil = none), and the item label if shown.
function G.f_icon()
    local now = os.clock()
    fi.refresh(now)
    local pos, label
    for _, ic in ipairs(fi.icons) do
        local ok = pcall(function()
            if ic.go:call("get_DrawSelf") then
                local msg = ic.beh and tostring(ic.beh:get_field("<LastIconTextMessage>k__BackingField")) or ""
                if msg:find("INTERACT", 1, true) then
                    local p = ic.go:call("get_Transform"):call("get_Position")
                    pos = { x = p.x, y = p.y, z = p.z }
                end
            end
        end)
        if not ok then fi.at = -10 end   -- stale after loading: find them again
        if pos then break end
    end
    pcall(function()
        if fi.item_go and fi.item_go:call("get_DrawSelf") and fi.item_text and fi.item_text:call("get_ActualVisible") then
            local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
            local s = RE4Access.menu.clean(mg:call(nil, fi.item_text:call("get_MessageId")))
            if s ~= "" then label = s end
        end
    end)
    return pos, label
end
-- The thing the F icon sits on: name, game object.
function G.icon_owner()
    local ipos, label = G.f_icon()
    local p = G.player_pos()
    if label and p then
        -- the item label names it: the nearest item with that name
        local best
        for _, it in ipairs(items(p, 3)) do
            if it.name:sub(1, #label) == label and not it.inside and (not best or it.dist < best.dist) then best = it end
        end
        if best then return label .. ", pick it up", best.go end
    end
    if not ipos then return nil end
    if fi.cache_pos and math.abs(fi.cache_pos.x - ipos.x) + math.abs(fi.cache_pos.y - ipos.y) + math.abs(fi.cache_pos.z - ipos.z) < 0.05 then
        return fi.cache and fi.cache[1], fi.cache and fi.cache[2]
    end
    local best, bd
    for _, q in ipairs(scan_things(ipos, 1.5)) do
        local d = math.sqrt((q.pos.x - ipos.x) ^ 2 + (q.pos.y - ipos.y) ^ 2 + (q.pos.z - ipos.z) ^ 2)
        if d < 1.0 and (not bd or d < bd) then best, bd = q, d end
    end
    for _, it in ipairs(items(ipos, 1.5)) do
        local d = math.sqrt((it.pos.x - ipos.x) ^ 2 + (it.pos.y - ipos.y) ^ 2 + (it.pos.z - ipos.z) ^ 2)
        if d < 1.0 and (not bd or d < bd) then best, bd = { name = it.name:gsub(", in a %a+$", "") .. ", pick it up", go = it.go }, d end
    end
    fi.cache_pos, fi.cache = ipos, best and { best.name, best.go } or nil
    if best then return best.name, best.go end
    return nil
end

local function prompt_owner()
    -- what the screen shows first; the hook only when no icon is found
    local oki, iname, igo = pcall(G.icon_owner)
    if oki and iname then return iname, igo end
    local a = RE4Access.last_act2
    if not a or os.clock() - a.at > 0.5 then return nil end
    local go = a.go
    -- the trigger may sit on a child object: walk up to a named gimmick
    for _ = 1, 4 do
        if not go then break end
        local okc, n = pcall(classify, go)
        if okc and n then return n, go end
        -- loose items (10/14: Red Herb next to the typewriter had no name here,
        -- so a switch of F to the typewriter was never said)
        local oki, iname = pcall(function()
            local di = go:call("getComponent(System.Type)", t_dropitem)
            return di and (item_name(di, go):gsub(", in a %a+$", "") .. ", pick it up")
        end)
        if oki and iname then return iname, go end
        local okp, par = pcall(function() return go:call("get_Transform"):call("get_Parent"):call("get_GameObject") end)
        go = okp and par or nil
    end
    return nil
end

-- 10/15: user report "close items, the mod faces the WRONG item" (10/14 the
-- mod turned toward the Red Herb and F then opened the typewriter next to it).
-- After "X here, press F" the mod now checks whose F prompt it really is; if it
-- is another thing, it turns the camera step by step until F is on X.
local want = nil
local function same_thing(ogo, w)
    if not ogo or not w then return false end
    local go = ogo
    for _ = 1, 5 do
        if not go then break end
        if w.go and go == w.go then return true end
        local okp, par = pcall(function() return go:call("get_Transform"):call("get_Parent"):call("get_GameObject") end)
        go = okp and par or nil
    end
    local okp, p = pcall(function() return ogo:call("get_Transform"):call("get_Position") end)
    return okp and p and w.pos and ((p.x - w.pos.x) ^ 2 + (p.y - w.pos.y) ^ 2 + (p.z - w.pos.z) ^ 2) < 0.35 ^ 2 or false
end
function G.want_f(t)
    if not t or not t.pos or G.spoken then return end
    local wp = t.face or t.pos
    want = { go = t.go, pos = { x = wp.x, y = wp.y, z = wp.z }, name = (tostring(t.name or "it"):gsub("^Path point, ", ""):gsub(", in a %a+$", "")),
        check_at = os.clock() + 0.6, until_t = os.clock() + 12, searched = false }
end
local function update_want(now, on)
    local w = want
    if not w then return end
    if now > w.until_t or G.state_text ~= "In control" then want = nil return end
    if now < w.check_at or not on or G.fsearch then return end
    local owner, ogo = prompt_owner()
            if owner then owner = owner:gsub("Cannon V2", "cannon") end
    if not ogo then
        -- F is on something without a name: let the usual 'F ready' speak
        if now > w.check_at + 0.5 then want = nil prompt.reannounce = true end
        return
    end
    -- same name counts too (10/18: "F is on the Trapdoor, not the Trapdoor")
    local oname = owner and (owner:gsub(", pick it up$", ""):gsub(", save game$", "")) or nil
    -- the story binoculars are the game's "Lookout point" (10/19: "F is on the
    -- Lookout point, not the Binoculars, story scene", then it turned away)
    if same_thing(ogo, w) or (oname and (oname == w.name or (oname == "Lookout point" and w.name:find("^Binoculars")) or (oname:lower():find("cannon") and w.name:lower():find("cannon")))) then
        want = nil
        prompt.said_at = now
        log.info("[RE4Access] F check: on " .. w.name)
        say(w.searched and ("F is on the " .. w.name .. " now. Press F.") or ("F ready: " .. w.name .. "."), w.searched)
        return
    end
    log.info("[RE4Access] F check: wanted " .. w.name .. ", F is for " .. tostring(owner))
    if not w.searched then
        w.searched = true
        prompt.said_at = now
        say("F is on the " .. owner:gsub(", pick it up$", ""):gsub(", save game$", "") .. ", not the " .. w.name .. ". Turning. Hold still.", true)
        G.start_f_search(w)
    else
        want = nil
        say("F stays on the " .. owner:gsub(", pick it up$", ""):gsub(", save game$", "") .. ". Take one step with A or D, then press Backslash on the " .. w.name .. " again.", true)
    end
end

local function update_prompt(now)
    local on = G.prompt_active()
    -- looking through binoculars: no F talk (10/19: "Finding the F angle" as the view opened)
    if G.bino_active then G.fsearch = nil want = nil prompt.check_at = nil prompt.on = on return end
    -- F just went away, most likely because it was pressed: wait before searching
    if prompt.on and not on then prompt.off_at = now end
    -- 11/1: no turning toward an old F target during the chase
    if G.in_chase or G.in_boss then G.fsearch = nil want = nil prompt.check_at = nil else pcall(update_want, now, on) end
    if on and (not prompt.on or prompt.reannounce) and not want then
        prompt.reannounce = nil
        prompt.check_at = nil
        local moving = RE4Access.route and RE4Access.route.active()
        if not moving and now - prompt.said_at > 2 and not (G.timed_target and G.timed_target()) then
            prompt.said_at = now
            local owner, ogo = prompt_owner()
            if owner then owner = owner:gsub("Cannon V2", "cannon") end
            -- a picked-up item stays selected; don't compare against it (10/13)
            local sel_ok = selected and selected.go and not (selected.item and not (function()
                local okx, gone = pcall(function() return selected.go:call("get_DrawSelf") end)
                return okx and gone end)())
            if owner and sel_ok and ogo and ogo ~= selected.go and selected.name ~= owner
                and selected.pos and (function() local p2 = G.player_pos(); return p2 and math.sqrt((selected.pos.x - p2.x) ^ 2 + (selected.pos.z - p2.z) ^ 2) < 3 end)() then
                -- 10/13: F at the typewriter did nothing; the prompt was for something else
                say("F is for the " .. owner:gsub("^Path point, ", "") .. ". Tap A or D.", false)
            else
                -- No named owner (10/14: the Valley emblem and kicks in a fight said just
                -- "F ready."): an item within 2 m, else an enemy within 3 m = kick.
                if not owner then
                    local p2 = G.player_pos()
                    pcall(function()
                        -- at a drop the route stopped at: the prompt is the jump (10/14)
                        local act = RE4Access.route and RE4Access.route.current_action and RE4Access.route.current_action()
                        if act and act.kind == "drop" and math.sqrt((act.entry.x - p2.x) ^ 2 + (act.entry.z - p2.z) ^ 2) < 3 then
                            owner = "jump down. Press F now" return
                        end
                        local best
                        for _, it in ipairs(items(p2, 2.2)) do
                            -- same floor only (10/14: "F ready: Small Key" on the roof; the key is in a locker below)
                            if math.abs(it.pos.y - p2.y) < 2.2 and not it.inside and (not best or it.dist < best.dist) then best = it end
                        end
                        if best then owner = best.name .. ", pick it up" return end
                        for _, e in ipairs(enemies(p2, 3)) do owner = "kick the enemy" break end
                    end)
                end
                -- 10/14: "F ready: Ladder" but F did nothing; an enemy stood at the top
                -- (2-3 m above). The game won't let you climb into an enemy.
                if owner == "Ladder" then
                    pcall(function()
                        local p2 = G.player_pos()
                        -- enemies right on you: say that, not "at the other end" (10/14:
                        -- four enemies within 2.5 m at the foot, none at the top)
                        local nearme = 0
                        for _, e in ipairs(enemies(p2, 3)) do if math.abs(e.pos.y - p2.y) < 1.5 then nearme = nearme + 1 end end
                        if nearme > 0 then
                            owner = "Ladder, but " .. nearme .. (nearme == 1 and " enemy is" or " enemies are") .. " right next to you. Kick or knife first, then climb fast"
                            return
                        end
                        for _, c in ipairs(RE4Access.route.connectors(p2)) do
                            if c.kind == "ladder" and math.sqrt((c.a.x - p2.x) ^ 2 + (c.a.z - p2.z) ^ 2) < 2.5 then
                                local other = (math.abs(c.a.y - p2.y) < math.abs(c.b.y - p2.y)) and c.b or c.a
                                for _, e in ipairs(enemies(other, 3.5)) do
                                    if math.abs(e.pos.y - other.y) < 2 then
                                        owner = "Ladder, but an enemy is at the other end and blocks it. Step back 3 steps with S, wait for it to come down, shoot it, then climb"
                                        break
                                    end
                                end
                                break
                            end
                        end
                    end)
                end
                say(owner and ("F ready: " .. owner:gsub("^Path point, ", "") .. ".") or "F ready.", false)
            end
        end
    end
    -- Prompt stays on but moves to another object (document -> typewriter).
    if on and prompt.on then
        local owner, ogo = prompt_owner()
            if owner then owner = owner:gsub("Cannon V2", "cannon") end
        if ogo and prompt.ogo and ogo ~= prompt.ogo and now - prompt.said_at > 1 and not want
            and not (RE4Access.route and RE4Access.route.active()) then
            prompt.said_at = now
            say("F ready: " .. owner:gsub("^Path point, ", "") .. ".", false)
        end
    end
    if on then
        local _, ogo = prompt_owner()
        prompt.ogo = ogo or prompt.ogo
    else
        prompt.ogo = nil
    end
    prompt.on = on
    if prompt.check_at and now > prompt.check_at and not (prompt.off_at and now - prompt.off_at < 1.5) then
        prompt.check_at = nil
        if not on then
            -- 10/14: at the Valley ladder and the emblem the user pressed F for a
            -- minute; the prompt only comes at one camera angle. Search for it:
            -- turn and tilt the camera step by step until the game offers F.
            local close = false
            pcall(function() close = #enemies(G.player_pos(), 4) > 0 end)
            if close then
                say("Enemy too close for the ladder or item. Fight or kick first.", false)
            elseif G.start_f_search and G.start_f_search() then
                say("Finding the F angle. Hold still.", false)
            else
                say("No F yet. Tap A or D to step sideways, until I say F ready.", false)
            end
        end
    end
    -- the search itself
    local fs = G.fsearch
    if fs then fs.last_t = fs.last_t or now end
    if fs then
        local moving = reframework:is_key_down(0x57) or reframework:is_key_down(0x41) or reframework:is_key_down(0x53)
            or reframework:is_key_down(0x44) or reframework:is_key_down(0x4C)
        -- a kick prompt (enemy right here, no gimmick owner) is not the one we want
        local kick = false
        if on then
            local owner, ogo = prompt_owner()
            if owner then owner = owner:gsub("Cannon V2", "cannon") end
            if not owner then
                pcall(function() kick = #enemies(G.player_pos(), 3) > 0 end)
            end
            -- searching for one thing (10/15): F on another thing doesn't count
            if fs.want and not same_thing(ogo, fs.want) then kick = true end
        end
        if on and not kick and fs.want then
            G.fsearch = nil
            want = nil
            prompt.said_at = now
            log.info(string.format("[RE4Access] F moved to %s at step %d", fs.want.name, fs.i))
            say("F is on the " .. fs.want.name .. " now. Press F.", true)
        elseif fs.want and not moving and G.state_text == "In control" and (now > fs.until_t or not fs.steps[fs.i + 1]) and now >= fs.next_at then
            G.fsearch = nil
            -- not found: look back at the thing itself, not at the last search angle
            pcall(G.face_item, fs.want.pos)
            if want then want.check_at = now + 0.6 end   -- update_want says what F is on
            if not on then
                want = nil
                say("No F on the " .. fs.want.name .. " from here. Press Backslash on it again: I walk you closer, right up to it.", true)
            end
        elseif on and not kick then
            G.fsearch = nil
            log.info(string.format("[RE4Access] F angle found at step %d", fs.i))
            if now - prompt.said_at > 0.3 then say("F ready. Press F now.", true) end
        elseif moving or G.state_text ~= "In control" or now > fs.until_t then
            G.fsearch = nil
            if not moving and G.state_text == "In control" then
                say("No F angle found here. Take one small step toward it with W, then press Backslash again.", false)
            end
        elseif (function() local pz = false pcall(function() pz = sdk.get_managed_singleton("chainsaw.GuiManager"):call("get_hasOccupiedPauseMenuSystemLock") end) return pz or not has_focus() end)() then
            fs.next_at, fs.until_t = now + 0.2, fs.until_t + (now - (fs.last_t or now))
        elseif now >= fs.next_at then
            fs.i = fs.i + 1
            local st = fs.steps[fs.i]
            if not st then
                fs.until_t = 0
            else
                fs.next_at = now + 0.2
                pcall(function()
                    local pos = G.player_pos()
                    local t = fs.target
                    local dx, dz = t.x - pos.x, t.z - pos.z
                    local a = math.rad(st[1])
                    local rx, rz = dx * math.cos(a) + dz * math.sin(a), -dx * math.sin(a) + dz * math.cos(a)
                    face_point({ x = pos.x + rx, y = t.y, z = pos.z + rz }, true, true)
                    local cam = main_camera_controller():call("get_CameraPosition")
                    local cx, cz = t.x - cam.x, t.z - cam.z
                    local pitch = math.atan(t.y - cam.y, math.sqrt(cx * cx + cz * cz)) + st[2]
                    player_camera():set_field("_Pitch", math.max(-1.2, math.min(1.0, pitch)))
                end)
            end
        end
    end
end

-- The thing to find the F angle for: the selected thing within 3 m, else the
-- nearest item, ladder or F-thing within 2.5 m.
function G.start_f_search(w)
    local pos = G.player_pos()
    if not pos or G.spoken then return false end
    if w then
        -- F must land on this one thing: finer and wider steps, items sit low
        local steps = {}
        for _, dp in ipairs({ 0, -0.2, -0.4, 0.2, -0.6 }) do
            for _, dy in ipairs({ 0, -8, 8, -16, 16, -25, 25, -35, 35, -50, 50 }) do steps[#steps + 1] = { dy, dp } end
        end
        w.searched = true
        G.fsearch = { target = w.pos, want = w, steps = steps, i = 0, next_at = 0, until_t = os.clock() + 14 }
        return true
    end
    -- a wanted thing that F hasn't reached yet: search for that one
    if want and want.pos then return G.start_f_search(want) end
    local t
    if selected and selected.pos and not selected.ctx and math.sqrt((selected.pos.x - pos.x) ^ 2 + (selected.pos.z - pos.z) ^ 2) < 3 then t = selected.face_at or selected.pos end
    if not t then
        local best
        for _, it in ipairs(items(pos, 2.5)) do
            if math.abs(it.pos.y - pos.y) < 2.2 and not it.inside and (not best or it.dist < best.dist) then best = it end
        end
        for _, q in ipairs(scan_things(pos, 2.5)) do
            if (q.name == "Ladder" or F_NAMES[q.name]) and math.abs(q.pos.y - pos.y) < 2.2 and (not best or q.dist < best.dist) then best = q end
        end
        t = best and best.pos
    end
    if not t then return false end
    local steps = {}
    for _, dp in ipairs({ 0, -0.3, 0.3, -0.6 }) do
        for _, dy in ipairs({ 0, -12, 12, -25, 25, -40, 40 }) do steps[#steps + 1] = { dy, dp } end
    end
    G.fsearch = { target = { x = t.x, y = t.y, z = t.z }, steps = steps, i = 0, next_at = 0, until_t = os.clock() + 7 }
    return true
end

-- ---------------- timed shutter (10/13, Chapter 2 factory) ----------------
-- A wheel (GmHoldHandle "シャッターハンドル") raises a shutter (GmCorrelatedShutter)
-- that sinks again on its own (_EternalReduce). The sighted way: turn the wheel,
-- sprint round through the hall, vault the window, slide under before it shuts.
-- While turning: "Turning, 60 percent". Fully turned: "Let go, sprint!" and a
-- route to the shutter starts. While it sinks: seconds left every 4 s.
local timed = { at = 0, h = nil, scan_at = -10, last = 0, run = false, said_pct = -1, said_at = 0, rate = nil, shutter = nil }
local function update_timed_shutter(pos, now)
    if now - timed.at < 0.25 then return end
    local dt = now - timed.at
    timed.at = now
    if not timed.h and now - timed.scan_at > 5 then
        timed.scan_at = now
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject")
                local n = go:call("get_Name")
                if n:find("シャッターハンドル", 1, true) then
                    timed.h = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmHoldHandle"))
                    local wq = go:call("get_Transform"):call("get_Position")
                    timed.wheel_pos = { x = wq.x, y = wq.y, z = wq.z }
                elseif n:find("次元シャッター", 1, true) then
                    local q = go:call("get_Transform"):call("get_Position")
                    timed.shutter = { x = q.x, y = q.y, z = q.z }
                end
            end) end
        end
    end
    if not timed.h then return end
    local ok, v = pcall(function() return timed.h:get_field("_ProcessValue"):get_field("Value") end)
    if not ok or type(v) ~= "number" then timed.h = nil return end
    local last = timed.last
    timed.last = v
    -- Grabbed the wheel (_Routine_ leaves 0): say how to turn it (10/13: F made
    -- a noise and nothing was said).
    local okr, rt = pcall(function() return timed.h:get_field("_Routine_") end)
    if okr and rt ~= timed.routine then
        if timed.routine ~= nil and rt ~= 0 and v < 0.9 and not timed.run then
            say("Holding the wheel. Keep holding F, and tap F quickly if it does not turn.", true)
            timed.said_at = now
        elseif timed.routine ~= nil and rt == 0 and timed.routine ~= 0 and v < 0.9 and not timed.run then
            say("Let go of the wheel.", true)
        end
        log.info("[RE4Access] wheel routine " .. tostring(timed.routine) .. " -> " .. tostring(rt) .. " value " .. string.format("%.3f", v))
        timed.routine = rt
    end
    if v > last + 0.001 then
        -- turning
        local pct = math.floor(v * 10 + 0.5) * 10
        if v >= 0.97 and not timed.run then
            timed.run, timed.rate, timed.faced, timed.done = true, nil, false, false
            say("Wheel fully turned! Let go of F. Sprint now: hold Shift and W. Out of this room, along the corridor, up the hall, jump through the window, then slide under the shutter with F.", true)
            if timed.shutter and RE4Access.route then
                RE4Access.speak_hold = true
                RE4Access.route.go({ name = "the shutter, press F to slide under", pos = timed.shutter })
                RE4Access.speak_hold = nil
            end
        elseif pct ~= timed.said_pct and now - timed.said_at > 1.2 and not timed.run then
            timed.said_pct, timed.said_at = pct, now
            say("Turning, " .. pct .. " percent. Keep holding F.", true)
        end
    elseif v < last - 0.0005 then
        -- sinking
        local r = (last - v) / math.max(dt, 0.05)
        timed.rate = timed.rate and (timed.rate * 0.8 + r * 0.2) or r
        if not timed.run and not timed.done and v > 0.1 and timed.wheel_pos and math.sqrt((pos.x - timed.wheel_pos.x) ^ 2 + (pos.z - timed.wheel_pos.z) ^ 2) > 2.5 then
            timed.run = true   -- away from the wheel while it is open: this is the run
        end
        -- At the shutter: keep Leon turned to it so F slides under (10/13: arrived
        -- 1 m from it with 22 s left, not facing it, F did nothing, "Blocked").
        if timed.run and timed.shutter then
            local ds = math.sqrt((pos.x - timed.shutter.x) ^ 2 + (pos.z - timed.shutter.z) ^ 2)
            if ds < 2.5 and not timed.faced then
                timed.faced = true
                if RE4Access.route and RE4Access.route.active() then RE4Access.route.stop(true) end
                face_point({ x = timed.shutter.x, y = timed.shutter.y + 1.0, z = timed.shutter.z }, false, true)
                say("Shutter in front of you. Let go of W. Press F to slide under.", true)
                timed.said_at = now
            end
        end
        -- Through (or gave up): was at the shutter and is now 3 m away from it.
        if timed.run and timed.faced and timed.shutter
            and math.sqrt((pos.x - timed.shutter.x) ^ 2 + (pos.z - timed.shutter.z) ^ 2) > 3 then
            timed.run, timed.done = false, true
        end
        if timed.run and now - timed.said_at > 10 and timed.rate > 0 then
            timed.said_at = now
            say(string.format("Shutter closes in %d seconds.", math.floor(v / timed.rate + 0.5)), false)
        end
        if not timed.run and v > 0.3 and v < 0.9 and now - timed.said_at > 6 then
            timed.said_at = now
            say("You let go too early; the wheel turns back. Hold F until I say fully turned.", true)
        end
    end
    if v <= 0.01 and last > 0.01 then
        timed.said_pct = -1
        timed.done = false
        if timed.run then
            timed.run = false
            say("The shutter has closed. Go back to the wheel and try again: question mark, then Shift+Backslash. When it says fully turned, sprint with Shift and W and do not press N or other route keys; the route is already running.", true)
        end
    end
end

-- While the shutter is open after a full turn: the place to run to.
function G.timed_target()
    if timed.run and timed.shutter and timed.last > 0.05 then
        return { name = "the shutter, press F to slide under", pos = timed.shutter, key = "timed_shutter" }
    end
end

-- The selected item is gone (picked up earlier): after loading a save the game
-- can list an item it marks as taken only when Leon gets near (10/18: 1000
-- Pesetas taken from the Chief's closet on 10/17 were listed again).
-- Say what a cupboard, drawer or closet held when it opens (10/18: a low chest
-- opened empty and the user heard nothing, so did not know if it worked).
G.lw = {}
G.lw_at = 0
function G.locker_watch(pos, now)
    if now < G.lw_at then return end
    G.lw_at = now + 0.4
    for _, t in ipairs(scan_things(pos, 3)) do
        local lk = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmLocker"))
        if lk then
            local okd, done = pcall(function() return lk:call("get_Context"):call("hasDoneForMap") end)
            done = okd and done and true or false
            local prev = G.lw[t.key]
            G.lw[t.key] = done
            if prev == false and done then
                local inside = {}
                for _, it in ipairs(items(t.pos, 1.8)) do
                    if math.abs(it.pos.y - t.pos.y) < 2.2 then inside[#inside + 1] = it.name end
                end
                if #inside == 0 then
                    say("Opened. It is empty.", true)
                else
                    say("Opened. Inside: " .. table.concat(inside, ", ") .. ". Press F to pick up.", true)
                end
            end
        end
    end
end

-- A big gate whose key hole you have used is the way on (10/18: the Insignia
-- Key gate outside the Chief's manor; the objective, the church, lies the other
-- way, so "Way to the objective" kept leading back into the house). Far side =
-- the side Leon was not on when first seen unlocked; done once he is through.
G.gate_far, G.gate_passed, G.trail_used = {}, {}, {}
-- far sides survive restarts (keyed by the gate's name): REAccess_gates.txt
pcall(function()
    for name, v in (fs.read("REAccess_gates.txt") or ""):gmatch("([^\t\n]+)\t(%-?%d)") do G.gate_far[name] = tonumber(v) end
end)
-- gates Leon has been through, with their place, so the trail beyond still works
-- once the gate itself is out of range (10/18: 80 m on, the trail said nothing)
pcall(function()
    for line in (fs.read("REAccess_gates_passed.txt") or ""):gmatch("[^\n]+") do
        local n, cx, cz, fx, fz, far = line:match("^([^\t]+)\t(%S+)\t(%S+)\t(%S+)\t(%S+)\t(%S+)$")
        if n then G.gate_passed[n] = { c = { x = tonumber(cx), z = tonumber(cz) }, f = { x = tonumber(fx), z = tonumber(fz) }, far = tonumber(far) } end
    end
end)
function G.unlocked_gate_step(pos)
    for _, kh in ipairs(scan_things(pos, 60)) do
        if kh.name == "Key Hole" then
            local core = kh.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore"))
            local gk = kh.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmKeyHole"))
            local gate = gk and gk:get_field("_ParentGate")
            if core and gate and core:call("get_Context"):call("hasDoneForMap") and not gate:get_field("IsOpen") then
                local tr = gate:call("get_GameObject"):call("get_Transform")
                local c, f = tr:call("get_Position"), tr:call("get_AxisZ")
                pcall(function() local q = gate:call("get_GameObject") local cc = G.door_center_of({ go = q, pos = c, name = "Gate" }) if cc then c = cc end end)
                local side = (pos.x - c.x) * f.x + (pos.z - c.z) * f.z
                local gname = gate:call("get_GameObject"):call("get_Name")
                if not G.gate_far[gname] then
                    G.gate_far[gname] = side >= 0 and -1 or 1
                    pcall(function()
                        local lines = {}
                        for n, v in pairs(G.gate_far) do lines[#lines + 1] = n .. "\t" .. v end
                        fs.write("REAccess_gates.txt", table.concat(lines, "\n") .. "\n")
                    end)
                end
                local far = G.gate_far[gname]
                if side * far > 1 then
                    -- through it: the trail beyond takes over (G.trail_step)
                    if not G.gate_passed[gname] then
                        G.gate_passed[gname] = { c = { x = c.x, z = c.z }, f = { x = f.x, z = f.z }, far = far }
                        pcall(function()
                            local lines = {}
                            for n, g in pairs(G.gate_passed) do
                                lines[#lines + 1] = string.format("%s\t%.3f\t%.3f\t%.4f\t%.4f\t%d", n, g.c.x, g.c.z, g.f.x, g.f.z, g.far)
                            end
                            fs.write("REAccess_gates_passed.txt", table.concat(lines, "\n") .. "\n")
                        end)
                    end
                    return nil
                else
                    return { name = "the gate you unlocked with the key", pos = { x = c.x + f.x * 3 * far, y = c.y, z = c.z + f.z * 3 * far }, dist = kh.dist, key = "gate:" .. tostring(kh.key),
                        tip = "Walk into the gate and keep holding W to push it open, then go on through." }
                end
            end
        end
    end
end

-- Past an unlocked gate the way on is the trail beyond it, not the straight
-- line to the objective (10/18: the church lies back past the manor, so "Way to
-- the objective" led back through the gate, and N then offered the gate again).
-- Next point: the nearest thing or enemy on the far side that is at least 10 m
-- further from the gate than Leon and has a walking route.
function G.trail_step(pos)
    -- The objective has a walking route of its own: no trail needed.
    local op0 = G.objective_pos()
    if op0 then
        for _, h in ipairs({ 0, 1, 2 }) do
            local okn, pts = pcall(RE4Access.route.nav_points, pos, { x = op0.x, y = op0.y - h, z = op0.z })
            local e = okn and pts and (pts.snap or pts[#pts])
            if e and math.sqrt((e.x - op0.x) ^ 2 + (e.z - op0.z) ^ 2) < 3 then return nil end
        end
    end
    for _, g in pairs(G.gate_passed) do
        if type(g) == "table" then
            local function along(q) return ((q.x - g.c.x) * g.f.x + (q.z - g.c.z) * g.f.z) * g.far end
            local function from_gate(q) return math.sqrt((q.x - g.c.x) ^ 2 + (q.z - g.c.z) ^ 2) end
            local mine = from_gate(pos)
            if along(pos) > 0.5 and mine < 150 then
                -- The game's own trigger points on the trail first (10/18 past the
                -- manor gate: bats 33 m, the howl 55 m, crows 68 m, square 94 m);
                -- the next one further from the gate than Leon.
                -- Pick by the shortest way via the point on to the objective, among
                -- points not back toward the gate and not reached yet (10/18: "the
                -- nearest further from the gate" led west out of the village gate
                -- instead of on to the square).
                local op = G.objective_pos()
                local best, bd
                local scored = {}
                for _, w in ipairs(waypoints(pos, 140)) do
                    if w.dist < 4 then G.trail_used[w.raw .. string.format("%.0f,%.0f", w.pos.x, w.pos.z)] = true end
                    local used = G.trail_used[w.raw .. string.format("%.0f,%.0f", w.pos.x, w.pos.z)]
                    local fg = from_gate(w.pos)
                    -- (LevelAreaHitForEm_ points are for enemies only, off the trail)
                    if not used and not w.raw:find("ForEm", 1, true) and along(w.pos) > 0 and fg > mine + 3 and w.dist > 4 then
                        -- the objective counts 1.5 times: a near point the wrong way loses
                        -- (10/18 at the west gate: a point 10 m further west beat the square)
                        local score = w.dist + (op and 1.5 * math.sqrt((op.x - w.pos.x) ^ 2 + (op.z - w.pos.z) ^ 2) or fg * -1)
                        scored[#scored + 1] = { w = w, score = score }
                        if not bd or score < bd then best, bd = w, score end
                    end
                end
                -- Best-scored point that has a walking route now (a far point in an
                -- unloaded part has none; 10/18 past the Town Hall it chose the
                -- church front 87 m away over the Colmillos spot 24 m on).
                table.sort(scored, function(a, b) return a.score < b.score end)
                for i = 1, math.min(#scored, 8) do
                    local w = scored[i].w
                    local reach = false
                    for _, h in ipairs({ 0, 1, 2 }) do
                        local okn, pts = pcall(RE4Access.route.nav_points, pos, { x = w.pos.x, y = w.pos.y - h, z = w.pos.z })
                        local e = okn and pts and (pts.snap or pts[#pts])
                        if e and math.sqrt((e.x - w.pos.x) ^ 2 + (e.z - w.pos.z) ^ 2) < 3 then reach = true break end
                    end
                    if reach then best = w break end
                end
                if best then
                    return { name = "the trail", pos = best.pos, dist = best.dist, key = "trail", tip = "Follow the trail on from the gate." }
                end
                local cands = {}
                for _, t in ipairs(scan_things(pos, 80)) do cands[#cands + 1] = { pos = t.pos, dist = t.dist, what = t.name } end
                for _, e in ipairs(enemies(pos, 80)) do cands[#cands + 1] = { pos = e.pos, dist = e.dist, what = "enemy" } end
                table.sort(cands, function(a, b) return a.dist < b.dist end)
                for _, cd in ipairs(cands) do
                    if cd.dist > 8 and along(cd.pos) > 0 and from_gate(cd.pos) > mine + 10 and math.abs(cd.pos.y - pos.y) < 10 then
                        local tip = "Follow the trail on from the gate."
                        if cd.what == "enemy" then tip = tip .. " An enemy is there; get ready to fight." end
                        return { name = "the trail", pos = cd.pos, dist = cd.dist, key = "trail", tip = tip }
                    end
                end
                -- Past the gate, never fall back to the straight line to the
                -- objective (it leads back through the gate).
                return { hold = true }
            end
        end
    end
end

-- The spot the game wants you on to use a thing: its interact trigger's NPC
-- position (where Leon's hands go) and icon position (10/18: the gate latch
-- only reacts from that spot; the middle of the gate gave no F at all).
function G.interact_spot(go)
    local ih = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InteractHolder"))
    if not ih then return nil end
    for _, tc in ipairs(ih:get_field("_Triggers"):get_elements()) do
        local tr = tc:get_field("_Trigger")
        local np = tr and tr:get_field("_ObjNPCPos")
        local ip = tr and tr:get_field("_ObjIconPos")
        if np then
            local a = np:call("get_Position")
            local b = ip and ip:call("get_Position") or a
            local hold = 0
            pcall(function() hold = tr:get_field("<KeyHoldDownSec>k__BackingField") or 0 end)
            return { x = a.x, y = a.y, z = a.z }, { x = b.x, y = b.y, z = b.z }, hold
        end
    end
end

-- A door or gate key hole not used yet: the way on (10/18: after the village
-- square the Town Hall door takes the Insignia Key; the trail led elsewhere).
function G.keyhole_step(pos)
    local best
    for _, t in ipairs(scan_things(pos, 120)) do
        if t.name == "Key Hole" and (not best or t.dist < best.dist) then
            local okd, done = pcall(function() return t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore")):call("get_Context"):call("hasDoneForMap") end)
            local gk = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmKeyHole"))
            local gate = gk and gk:get_field("_ParentGate")
            if gate and not (okd and done) then
                local gname = ""
                pcall(function() gname = gate:call("get_GameObject"):call("get_Name") end)
                local spoken = gname:find("タウンホール", 1, true) and "the key hole on the Town Hall door" or "a key hole on a locked door"
                local spot, face = G.interact_spot(t.go)
                face = face or t.pos
                local okn, pts
                if spot then okn, pts = pcall(RE4Access.route.nav_points, pos, spot) end
                if not (okn and pts) then
                    -- no stand spot given: the floor below the key hole (it sits up on the door)
                    for _, h in ipairs({ 1.2, 1.6, 0.8, 2.0, 0.4 }) do
                        local g = { x = t.pos.x, y = t.pos.y - h, z = t.pos.z }
                        okn, pts = pcall(RE4Access.route.nav_points, pos, g)
                        if okn and pts then
                            local e = pts.snap or pts[#pts]
                            if e and math.sqrt((e.x - g.x) ^ 2 + (e.z - g.z) ^ 2) < 1.5 then spot = { x = e.x, y = e.y, z = e.z } break end
                            pts = nil
                        end
                    end
                end
                if spot and okn and pts then
                    -- Walking up to use the key: the far side of this door is the
                    -- other side from Leon (10/18: first seen only after using the
                    -- Town Hall key from beyond, the mod sent the user back through).
                    pcall(function()
                        local tr = gate:call("get_GameObject"):call("get_Transform")
                        local c, f = tr:call("get_Position"), tr:call("get_AxisZ")
                        local side = (pos.x - c.x) * f.x + (pos.z - c.z) * f.z
                        local far = side >= 0 and -1 or 1
                        if G.gate_far[gname] ~= far then
                            G.gate_far[gname] = far
                            local lines = {}
                            for n, v in pairs(G.gate_far) do lines[#lines + 1] = n .. "\t" .. v end
                            fs.write("REAccess_gates.txt", table.concat(lines, "\n") .. "\n")
                        end
                    end)
                    local dx, dz = pos.x - spot.x, pos.z - spot.z
                    local dl = math.sqrt(dx * dx + dz * dz)
                    best = { name = spoken, spoken = spoken, pos = spot, face = face, dist = t.dist, key = t.key, go = t.go, latch = true, fname = "Key Hole",
                        after = "Press F at the key hole and choose the key; if it asks, pick the Insignia Key.",
                        tip = "Use your key there: press F at the key hole." }
                end
            end
        end
    end
    return best
end

-- A gate latch not lifted yet, close by: the next step (10/18).
function G.latch_step(pos)
    for _, t in ipairs(scan_things(pos, 15)) do
        if t.name == "Gate latch" then
            local okd, done = pcall(function() return t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore")):call("get_Context"):call("hasDoneForMap") end)
            if not (okd and done) then
                local spot, face, hold = G.interact_spot(t.go)
                -- same level only (10/18: from the tunnel under the barn N sent
                -- Leon back up the ladder to the church-side gate latch)
                if spot and math.abs(spot.y - pos.y) > 1.5 then spot = nil end
                if spot then
                    -- a spot right against the gate: stand 0.5 m back from it, toward Leon
                    local dx, dz = pos.x - spot.x, pos.z - spot.z
                    local dl = math.sqrt(dx * dx + dz * dz)
                    local stand = dl > 0.6 and { x = spot.x + dx / dl * 0.5, y = spot.y, z = spot.z + dz / dl * 0.5 } or spot
                    return { name = "the gate latch", pos = stand, face = face, dist = dl, key = t.key, go = t.go, latch = true,
                        tip = "Stand there, then HOLD F down for " .. (hold and hold > 0.3 and math.floor(hold + 0.5) or 1) .. " second to lift the latch. Then hold W to push the gate open." }
                end
            end
        end
    end
end

-- Closed-for-now iron bars or gate within r m (default 4) of q: asleep gates,
-- shut shutters, and the church's stained-glass bars (GmStainedGlassShutter,
-- opened by the church puzzle in a later chapter, 10/18).
G.t_sgs = sdk.typeof("chainsaw.GmStainedGlassShutter")
function G.behind_closed_bars(q, r)
    r = r or 4
    for _, b in ipairs(G.asleep_gate_positions(q, r)) do
        if math.sqrt((b.x - q.x) ^ 2 + (b.z - q.z) ^ 2) < r then return true end
    end
    for _, t in ipairs(scan_things(q, r)) do
        local ok, shut = pcall(function()
            if not t.go:call("getComponent(System.Type)", G.t_sgs) then return false end
            return not t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore")):call("get_Context"):call("hasDoneForMap")
        end)
        if ok and shut then return true end
    end
    return false
end

-- A fallen shelf (GmFallenShelf) not pushed over yet, whose push spot Leon can
-- walk to: it is the way out (10/18: the corner behind the church with the
-- Elegant Headdress is a one-way drop; the shelf opens it back to the barn).
function G.shelf_step(pos)
    local R = RE4Access.route
    for _, t in ipairs(scan_things(pos, 30)) do
        if t.name == "Fallen shelf" then
            local okd, done = pcall(function() return t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore")):call("get_Context"):call("hasDoneForMap") end)
            if not (okd and done) then
                local spot, face, hold = G.interact_spot(t.go)
                local okn, pts = false, nil
                if spot then okn, pts = pcall(R.nav_points, pos, spot) end
                if spot and okn and pts and math.abs(pts[#pts].y - spot.y) < 1.5 then
                    local how = (hold and hold > 0.3) and ("HOLD F down for " .. math.floor(hold + 0.5) .. (math.floor(hold + 0.5) == 1 and " second" or " seconds")) or "press F"
                    return { name = "the fallen shelf", pos = spot, face = face, dist = t.dist, key = t.key, go = t.go, latch = true,
                        fname = "Fallen shelf", spoken = "fallen shelf",
                        after = how .. " to push it over. It opens a short way through. Then press N again.",
                        tip = "It opens the way out of this corner. Stand there, then " .. how .. " to push it over." }
                end
            end
        end
    end
end

-- Where to stand for a trapdoor (GmFloorBoard): 0.6 m out from its IconPos,
-- away from the board middle, facing the icon. Returns a latch-style target.
function G.trapdoor_spot(go, mid, key)
    local icon, hold
    pcall(function()
        local ih = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.InteractHolder"))
        for _, tc in ipairs(ih:get_field("_Triggers"):get_elements()) do
            local tr = tc:get_field("_Trigger")
            local ip = tr and tr:get_field("_ObjIconPos")
            if ip then
                local q = ip:call("get_Position")
                icon = { x = q.x, y = q.y, z = q.z }
                hold = tr:get_field("<KeyHoldDownSec>k__BackingField") or 0
                return
            end
        end
    end)
    if not icon then return nil end
    local dx, dz = icon.x - mid.x, icon.z - mid.z
    local dl = math.sqrt(dx * dx + dz * dz)
    if dl < 0.1 then return nil end
    local stand = { x = icon.x + dx / dl * 0.6, y = icon.y, z = icon.z + dz / dl * 0.6 }
    local how = (hold and hold > 0.3) and ("HOLD F down for " .. math.floor(hold + 0.5) .. (math.floor(hold + 0.5) == 1 and " second" or " seconds")) or "press F"
    local pos = G.player_pos()
    return { name = "Trapdoor", pos = stand, face = icon, key = key or go:get_address(), go = go, latch = true,
        dist = pos and math.sqrt((stand.x - pos.x) ^ 2 + (stand.z - pos.z) ^ 2) or 0,
        fname = "Trapdoor", spoken = "trapdoor",
        after = how .. " to open the trapdoor and go down. Wait for F ready first; if F says Typewriter, tap A or D.",
        tip = "Stand at its edge, away from the typewriter, then " .. how .. "." }
end

-- Has this document been read? (FileManager:IsOpenedFile(documentID); 10/18
-- user asked to hear it). nil when unknown.
function G.doc_read(go)
    local ok, r = pcall(function()
        local id = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmReadFile")):call("get_documentID")
        return sdk.get_managed_singleton("chainsaw.FileManager"):call("IsOpenedFile", id)
    end)
    if ok then return r == true end
end

-- "At the top of the ladder" / "At the bottom of the ladder" when Leon stands
-- at one end of a ladder, else nil (10/18: user lost track of up or down).
function G.ladder_end(pos)
    local R = RE4Access.route
    for _, c in ipairs(R.connectors(pos)) do
        if c.kind == "ladder" then
            local lo, hi = c.a, c.b
            if lo.y > hi.y then lo, hi = hi, lo end
            local h = math.floor(hi.y - lo.y + 0.5)
            if math.sqrt((pos.x - hi.x) ^ 2 + (pos.z - hi.z) ^ 2) < 1.8 and math.abs(pos.y - hi.y) < 1 then
                return "At the top of a ladder, " .. h .. " meters down"
            end
            if math.sqrt((pos.x - lo.x) ^ 2 + (pos.z - lo.z) ^ 2) < 1.8 and math.abs(pos.y - lo.y) < 1 then
                return "At the bottom of a ladder, " .. h .. " meters up"
            end
        end
    end
end

-- Say when Leon has settled on a new level (ladder, rope, stairs, a drop):
-- "At the top of the ladder" / "Down a level, 3 meters lower". Also once when
-- you get control at a ladder end (after loading a save).
function G.update_level(pos, now)
    -- cutscene, loading, menus: start fresh (the next settle only says a ladder end)
    if G.state_text ~= "In control" then G.level_hist, G.level_y = nil, nil return end
    G.level_hist = G.level_hist or {}
    local h = G.level_hist
    h[#h + 1] = { t = now, y = pos.y }
    while #h > 0 and now - h[1].t > 1.0 do table.remove(h, 1) end
    local lo, hi = pos.y, pos.y
    for _, e in ipairs(h) do lo, hi = math.min(lo, e.y), math.max(hi, e.y) end
    if hi - lo > 0.15 or #h < 3 then return end        -- still moving up or down
    if not G.level_y then
        G.level_y = pos.y
        local okl, lt = pcall(G.ladder_end, pos)
        if okl and lt then say(lt .. ".", false) end
        return
    end
    local dy = pos.y - G.level_y
    if math.abs(dy) < 2 then return end
    G.level_y = pos.y
    local okl, lt = pcall(G.ladder_end, pos)
    if okl and lt then
        say(lt .. ".", true)
    else
        say((dy > 0 and "Up a level, " or "Down a level, ") .. math.floor(math.abs(dy) + 0.5) .. " meters " .. (dy > 0 and "higher." or "lower."), true)
    end
end

function G.gimmick_done(go)
    local ok, d = pcall(function() return go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GimmickCore")):call("get_Context"):call("hasDoneForMap") end)
    return ok and d == true
end

-- Standing by an opened trapdoor: the way on is the ladder down into it
-- (10/18 barn: N jumped to a gate latch 11 m off "via a ladder", confusing).
-- The game's chapter number (chapter 3 = 21300, chapter 4 = 22100; 10/21).
function G.chapter()
    local ok, c = pcall(function() return sdk.get_managed_singleton("chainsaw.CampaignManager"):call("get_CurrentChapter") end)
    return ok and c or nil
end
function G.hole_step(pos)
    -- The barn trapdoor was the chapter 3 way to the lake. In chapter 4 you
    -- come back up it, and the church is the way on (10/21: N kept sending the
    -- user down the trapdoor again).
    local ch = G.chapter()
    if ch and ch >= 22100 then return nil end
    for _, t in ipairs(scan_things(pos, 5)) do
        if t.name == "Trapdoor" and G.gimmick_done(t.go) and pos.y > t.pos.y - 1 then
            local R = RE4Access.route
            for _, c in ipairs(R.connectors(t.pos)) do
                if c.kind == "ladder" and math.sqrt((c.b.x - t.pos.x) ^ 2 + (c.b.z - t.pos.z) ^ 2) < 2.5 and math.abs(c.b.y - t.pos.y) < 1.5 then
                    -- walk to the game's F box at the top (c.b), face the ladder: the
                    -- exact-spot walk (latch) - a plain route stopped 0.7 m off (10/18)
                    return { name = "the ladder down the trapdoor", pos = c.b, face = { x = c.face.x, y = c.b.y - 0.5, z = c.face.z }, dist = t.dist, key = "hole_ladder",
                        latch = true, fname = "Ladder", spoken = "ladder at the trapdoor", after = "HOLD F down for 1 second to climb down. Then follow the tunnel to its far end, and press N again.",
                        tip = "The trapdoor is open. I walk you to the top of the ladder; when I say Ladder, HOLD F down for 1 second to climb down. Then follow the tunnel to its far end, and press N again." }
                end
            end
        end
    end
end

G.gone_check_at = 0
function G.check_selected_gone(now)
    if now < G.gone_check_at or not selected or not selected.item or not selected.go then return end
    G.gone_check_at = now + 1
    local ok, r = pcall(function()
        return selected.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.DropItem")):get_field("_Routine")
    end)
    if ok and (r == 7 or r == 8) then
        local name = selected.name
        selected = nil
        if RE4Access.route and RE4Access.route.active() then pcall(RE4Access.route.stop, true) end
        -- just picked up by you: "Picked up" was already said (10/20: the extra
        -- "already picked up" right after made the user think it failed)
        if os.clock() - (G.picked_at or -100) > 5 then
            say(tostring(name) .. " is already picked up. You took it before.", true)
        end
    end
end

-- Binoculars (10/19 lake lookout): the story scene starts only when the view
-- is within 5 degrees of its target and zoomed in, and zoom is the mouse wheel.
-- So the mod turns and zooms the binocular view itself, like L aims the gun.
do
local LOOK_NAMES = { derurago = "the boat on the lake", Shiro = "the castle", Taigan = "the far shore" }
local bino = nil
function G.update_binoculars(now)
    local mc = main_camera_controller()
    local g = mc and mc:get_field("_BusyCameraController")
    if not g or g:get_type_definition():get_name() ~= "GimmickOperateCameraController" then
        bino = nil
        G.bino_active = false
        return
    end
    if not bino then bino = { g = g, start = now, scan_at = now } end
    -- the same camera is used by other gimmicks: binoculars only
    G.bino_active = bino.vp and true or false
    if bino.not_vp then return end
    -- find the target; retry a few times (10/19: right after a cutscene the
    -- player position isn't there yet and the first look found nothing)
    if not bino.target and not bino.gave_up then
        if now < bino.scan_at then return end
        bino.scan_at = now + 0.5
        pcall(function()
            local pos = G.player_pos()
            local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local list = scene:call("findComponents(System.Type)", sdk.typeof("chainsaw.GmViewPoint"))
            for i = 0, list:get_size() - 1 do
                local vp = list:get_element(i)
                local q = vp:call("get_GameObject"):call("get_Transform"):call("get_Position")
                if math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) < 3 then
                    bino.vp = true
                    for _, lp in ipairs(vp:get_field("_LookPositions"):get_elements()) do
                        -- the story target has a scene (event) number
                        if lp:get_field("_EventID") >= 0 then
                            local t = lp:get_field("TargetPos")
                            bino.target = { x = t.x, y = t.y, z = t.z }
                            bino.fov = lp:get_field("TargetFov")
                            bino.name = LOOK_NAMES[lp:get_field("CallKey")] or "the target"
                            break
                        end
                    end
                end
            end
        end)
        if bino.target then
            bino.at, bino.until_t = now + 0.4, now + 6
            say("Binoculars. Turning you to " .. bino.name .. " and zooming in. Hold still.", true)
        elseif now > bino.start + 2 then
            bino.gave_up = true
            if bino.vp then say("Binoculars. Press Escape to stop looking.", true) else bino.not_vp = true end
        end
        return
    end
    if not bino.target or now < bino.at or now > bino.until_t then return end
    bino.at = now + 0.15
    local c, r = mc:get_field("_CameraPosition"), mc:get_field("_CameraRotation")
    -- camera forward is -z
    local fx = -(2 * (r.x * r.z + r.w * r.y))
    local fy = -(2 * (r.y * r.z - r.w * r.x))
    local fz = -(1 - 2 * (r.x * r.x + r.y * r.y))
    local T = bino.target
    local dx, dy, dz = T.x - c.x, T.y - c.y, T.z - c.z
    local yaw_err = math.atan(dx, dz) - math.atan(fx, fz)
    if yaw_err > math.pi then yaw_err = yaw_err - 2 * math.pi elseif yaw_err < -math.pi then yaw_err = yaw_err + 2 * math.pi end
    local pitch_err = math.atan(dy, math.sqrt(dx * dx + dz * dz)) - math.atan(fy, math.sqrt(fx * fx + fz * fz))
    g:set_field("_Yaw", g:get_field("_Yaw") + yaw_err)
    g:set_field("_Pitch", g:get_field("_Pitch") + pitch_err)
    local want_fov = (bino.fov or 20) - 2
    if g:get_field("_Fov") > want_fov then
        g:set_field("_TargetFov", want_fov)
        g:set_field("_Fov", math.max(want_fov, g:get_field("_Fov") - 4))
    end
    if math.abs(yaw_err) < 0.02 and math.abs(pitch_err) < 0.02 and g:get_field("_Fov") <= want_fov + 0.5 and not bino.said then
        bino.said = true
        log.info("[RE4Access] binoculars on target")
        say("On " .. bino.name .. ". Hold still. If nothing happens in 5 seconds, you saw it already: press Escape.", true)
    end
end
end

-- Water route for the boat (10/19: steering straight at a landing ran the boat
-- onto land and rocks). A* over a 3 m grid at water level; a step is open when
-- rays at two heights just above the water hit nothing. Rays start in open
-- water, so shores and rock pillars (one-sided meshes) are hit from outside.
-- Runs as a coroutine, a few hundred rays per frame, so the game never stalls.
do
local CELL, WY1, WY2 = 3, -7.4, -6.5
local SIDE_CLEAR = 1.6   -- the boat is about 2 m wide and swings at turns
-- Ground under a point higher than just below the water = beach, shallows or
-- land the side rays pass over (10/20: route over the church shore).
local function dry(x, z, wy)
    local g = RE4Access.route.cast(x, wy + 3, z, x, wy - 0.4, z)
    return g ~= nil
end
local function open_step(ax, az, bx, bz, wy, lax)
    local R = RE4Access.route
    local y1, y2 = wy + (WY1 + 8), wy + (WY2 + 8)
    if R.cast(ax, y1, az, bx, y1, bz) or R.cast(ax, y2, az, bx, y2, bz) then return false end
    if dry(bx, bz, wy) then return false end
    if not lax then
        -- long shortcut lines: no dry ground along them either
        local l = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
        for t = 3, l - 1, 3 do
            if dry(ax + (bx - ax) * t / l, az + (bz - az) * t / l, wy) then return false end
        end
    end
    -- lines 1.6 m to each side (10/19: the centre line was clear, the boat
    -- still cut a corner into a cave wall)
    if lax then return true end   -- first step off a wall: centre line only
    local dx, dz = bx - ax, bz - az
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 0.01 then return true end
    local ox, oz = -dz / l * SIDE_CLEAR, dx / l * SIDE_CLEAR
    if R.cast(ax + ox, y1, az + oz, bx + ox, y1, bz + oz) or R.cast(ax - ox, y1, az - oz, bx - ox, y1, bz - oz) then return false end
    return true
end
G.boat_open_step = open_step
-- Cells where the boat got stuck (W held, no headway): the planner avoids them.
G.boat_blocked = G.boat_blocked or {}
function G.boat_block_ahead(pos, h)
    local a = math.rad(h or 0)
    for _, r in ipairs({ 1.5, 3, 4.5 }) do
        for _, side in ipairs({ -1.5, 0, 1.5 }) do
            local x = pos.x + math.sin(a) * r + math.cos(a) * side
            local z = pos.z + math.cos(a) * r - math.sin(a) * side
            G.boat_blocked[math.floor(x / CELL + 0.5) * 100000 + math.floor(z / CELL + 0.5)] = os.clock() + 90
        end
    end
end
-- forget blocked cells after 90 s (10/20: 88 cells piled up and walled the
-- landing off, the route went 650 m round the lake)
function G.boat_blocked_live()
    local now, out = os.clock(), {}
    for k, t in pairs(G.boat_blocked) do
        if t == true or t > now then out[k] = true else G.boat_blocked[k] = nil end
    end
    return out
end
-- a shortcut line must not cross a blocked cell
function G.boat_line_blocked(a, b)
    local l = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
    for t = 0, l, 1.5 do
        local x, z = a.x + (b.x - a.x) * t / l, a.z + (b.z - a.z) * t / l
        local t0 = G.boat_blocked[math.floor(x / CELL + 0.5) * 100000 + math.floor(z / CELL + 0.5)]
        if t0 and (t0 == true or t0 > os.clock()) then return true end
    end
    return false
end
function G.boat_plan_start(from, goal)
    local co = coroutine.create(function()
        local wy = from.y              -- water surface (boat height)
        local sx, sz = math.floor(from.x / CELL + 0.5), math.floor(from.z / CELL + 0.5)
        local gx, gz = goal.x / CELL, goal.z / CELL
        local function key(x, z) return x * 100000 + z end
        -- (10/20: the grid cell next to the boat was also a start; from it the route
        -- went SW through a rock 2 m from the boat, "Blocked" 6 times)
        local open, came, cost = {}, {}, {}
        local blocked = G.boat_blocked_live()
        local rays, best, bestd = 0, nil, nil
        local closed = {}
        local n = 0
        -- Start from the boat itself, not its grid cell (10/20: parked at a dock
        -- the cell centre was inside the dock, only one step was open and the
        -- route ended at the start, "only part of the water route is known").
        local start = { x = from.x / CELL, z = from.z / CELL }
        local fx0, fz0 = math.floor(start.x), math.floor(start.z)
        for ix = fx0 - 1, fx0 + 2 do
            for iz = fz0 - 1, fz0 + 2 do
                local k = key(ix, iz)
                -- rays start 1.2 m out: closer in they hit the boat's own hull
                local ddx, ddz = ix * CELL - from.x, iz * CELL - from.z
                local dl = math.max(0.01, math.sqrt(ddx * ddx + ddz * ddz))
                local ox, oz = from.x + ddx / dl * math.min(1.2, dl * 0.5), from.z + ddz / dl * math.min(1.2, dl * 0.5)
                if not blocked[k] and open_step(ox, oz, ix * CELL, iz * CELL, wy, true) then
                    local g = math.sqrt((ix - start.x) ^ 2 + (iz - start.z) ^ 2)
                    if not cost[k] or g < cost[k] then
                        cost[k] = g
                        came[k] = start
                        open[#open + 1] = { x = ix, z = iz, f = g + math.sqrt((ix - gx) ^ 2 + (iz - gz) ^ 2) }
                    end
                end
            end
        end
        while #open > 0 and n < 14000 do   -- 6000 ran out 26 m short of the north cave (10/20)
            -- pop lowest f
            local bi = 1
            for i = 2, #open do if open[i].f < open[bi].f then bi = i end end
            local c = table.remove(open, bi)
            local ck = key(c.x, c.z)
            if not closed[ck] then
                closed[ck] = true
                n = n + 1
                local d = math.sqrt((c.x - gx) ^ 2 + (c.z - gz) ^ 2) * CELL
                if not bestd or d < bestd then best, bestd = c, d end
                if d < 6 then break end
                for _, o in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
                    local nx, nz = c.x + o[1], c.z + o[2]
                    local nk = key(nx, nz)
                    if not closed[nk] and not blocked[nk] then
                        rays = rays + 4
                        if rays > 240 then rays = 0 coroutine.yield() end
                        if open_step(c.x * CELL, c.z * CELL, nx * CELL, nz * CELL, wy, n <= 2) then
                            local g = cost[ck] + ((o[1] ~= 0 and o[2] ~= 0) and 1.414 or 1)
                            if not cost[nk] or g < cost[nk] then
                                cost[nk] = g
                                came[nk] = c
                                open[#open + 1] = { x = nx, z = nz, f = g + math.sqrt((nx - gx) ^ 2 + (nz - gz) ^ 2) }
                            end
                        end
                    end
                end
            end
        end
        -- path back from the closest cell reached
        local pts = {}
        local c = best
        while c do
            table.insert(pts, 1, { x = c.x * CELL, y = wy, z = c.z * CELL })
            if c == start then break end
            c = came[key(c.x, c.z)]
        end
        -- keep only turning points that can't be skipped
        local out, i = { pts[1] }, 1
        while i < #pts do
            local j = #pts
            while j > i + 1 do
                rays = rays + 2
                if rays > 240 then rays = 0 coroutine.yield() end
                if open_step(pts[i].x, pts[i].z, pts[j].x, pts[j].z, wy) and not G.boat_line_blocked(pts[i], pts[j]) then break end
                j = j - 1
            end
            out[#out + 1] = pts[j]
            i = j
        end
        return { pts = out, reached = bestd and bestd < 8, left = bestd }
    end)
    G.boat_planning = co
end
function G.boat_plan_step()
    local co = G.boat_planning
    if not co then return nil end
    local ok, res = coroutine.resume(co)
    if not ok then G.boat_planning = nil log.info("[RE4Access] boat plan error: " .. tostring(res)) return false end
    if coroutine.status(co) == "dead" then G.boat_planning = nil return res end
    return nil
end
end

-- The boat (10/19 lake monster fight): hold L and the mod turns the boat
-- camera to the monster, then says fire; K throws the harpoon.
do
local boat = {}
G.boat_ys = G.boat_ys or 1
-- The boat's own heading (GmBoat._BoatLook) and speed: the camera lags and
-- swings, so turn numbers from it sat at 155-160 (10/20).
function G.boat_state()
    local h, sp
    pcall(function()
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        local bo = boat.obj
        if not bo then
            -- one pcall per entry: a nil entry stopped the whole search (10/20:
            -- heading fell back to the camera, turn numbers never went down)
            for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                pcall(function()
                    local go = e:get_field("value"):call("get_GameObject")
                    local b = go:call("get_DrawSelf") and go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmBoat"))
                    if b and not bo then bo = b end
                end)
            end
            boat.obj = bo
        end
        local v = bo:get_field("_BoatLook")
        if math.abs(v.x) + math.abs(v.z) > 0.01 then h = heading_of(v.x, v.z) end
        sp = bo:get_field("_Speed")
    end)
    return h, sp
end
-- Hook GmBoat.UpdateBoat(Single, Single): learn which argument / field is the
-- stick (matches _Pad_AxisLX/LY while you drive), then feed G.boat_auto.
if not RE4Access.boat_hooked then
    RE4Access.boat_hooked = true
    pcall(function()
        local m = sdk.find_type_definition("chainsaw.GmBoat"):get_method("UpdateBoat")
        sdk.hook(m, function(args)
            pcall(function() RE4Access.game.boat_hook(args) end)
        end, function(r) return r end)
    end)
end
-- Writing the stick fields did nothing (10/20 log: auto -1 -1, speed 0): the
-- boat reads the stick through its getters. Hook those too and answer with
-- the auto drive values while it drives.
if not RE4Access.boat_getters_hooked then
    RE4Access.boat_getters_hooked = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.GmBoat")
        local function over(name, pick)
            local m = td:get_method(name)
            if not m then log.info("[RE4Access] boat getter missing: " .. name) return end
            sdk.hook(m, function(args) end, function(r)
                local au = RE4Access.game and RE4Access.game.boat_auto
                if not au then return r end
                RE4Access.boat_getter_hits = (RE4Access.boat_getter_hits or 0) + 1
                return pick(au)
            end)
        end
        over("get_Pad_AxisLX", function(au) return sdk.float_to_ptr(au.lx) end)
        over("get_Pad_AxisLY", function(au) return sdk.float_to_ptr(au.ly) end)
        over("get_KeyInputDeg", function(au)
            return sdk.float_to_ptr(math.deg(math.atan(-(RE4Access.boat_map and RE4Access.boat_map.a_sign or 1) * au.lx, au.ly)))
        end)
    end)
end
G.boat_map = G.boat_map or RE4Access.boat_map
function G.boat_hook(args)
    local b = sdk.to_managed_object(args[2])
    if not b then return end
    local fx, fy = b:get_field("_Pad_AxisLX"), b:get_field("_Pad_AxisLY")
    local a3, a4 = sdk.to_float(args[3]), sdk.to_float(args[4])
    local mp = RE4Access.boat_map or {}
    RE4Access.boat_map, G.boat_map = mp, mp
    -- learn: a stick value that is not 0 and shows up in an argument
    if math.abs(fx) > 0.2 then
        mp.lx = math.abs(a3 - fx) < 0.001 and 3 or (math.abs(a4 - fx) < 0.001 and 4 or "field")
        if reframework:is_key_down(0x41) then mp.a_sign = fx > 0 and 1 or -1 end
        if reframework:is_key_down(0x44) then mp.a_sign = fx > 0 and -1 or 1 end
    end
    if math.abs(fy) > 0.2 then
        mp.ly = math.abs(a3 - fy) < 0.001 and 3 or (math.abs(a4 - fy) < 0.001 and 4 or "field")
    end
    if not mp.logged_at or os.clock() - mp.logged_at > 2 then
        mp.logged_at = os.clock()
        local kd, kf, acc = -1, "?", -1
        pcall(function() kd = b:call("get_KeyInputDeg") kf = tostring(b:get_field("_KeyFront")) acc = b:get_field("_FreeBoatMoveAccel") end)
        log.info(string.format("[RE4Access] boat hook: getter hits %d,", RE4Access.boat_getter_hits or 0))
        log.info(string.format("[RE4Access] boat hook: keys W%s A%s D%s keydeg %.2f keyfront %s accel %.2f speed %.2f args %.3f %.3f fields %.3f %.3f map lx %s ly %s a_sign %s auto %s",
            tostring(reframework:is_key_down(0x57)), tostring(reframework:is_key_down(0x41)), tostring(reframework:is_key_down(0x44)), kd, kf, acc, b:get_field("_Speed"),
            a3, a4, fx, fy, tostring(mp.lx), tostring(mp.ly), tostring(mp.a_sign), G.boat_auto and string.format("%.2f %.2f", G.boat_auto.lx, G.boat_auto.ly) or "off"))
    end
    local au = G.boat_auto
    if not au then return end
    b:set_field("_Pad_AxisLX", au.lx)
    b:set_field("_Pad_AxisLY", au.ly)
    pcall(function()
        b:set_field("_FreeBoatMoveAccel", math.max(0, au.ly))
        b:set_field("_FreeBoatMoveBack", math.max(0, -au.ly))
        b:set_field("_KeyFront", au.ly >= 0)
    end)
    if mp.lx == 3 then args[3] = sdk.float_to_ptr(au.lx) elseif mp.lx == 4 then args[4] = sdk.float_to_ptr(au.lx) end
    if mp.ly == 3 then args[3] = sdk.float_to_ptr(au.ly) elseif mp.ly == 4 then args[4] = sdk.float_to_ptr(au.ly) end
end
function G.boat_debug() return boat end
-- Backslash in the boat: the mod drives the whole way (10/20 user kept
-- ending in dead ends and could not turn round in tight coves)
function G.boat_toggle_drive()
    if not boat.cur_goal then say("Pick a place first: press N, or pick one in a list.", true) return end
    boat.drive_all = not boat.drive_all
    boat.auto_cancel = nil
    if not boat.drive_all then boat.auto_on = false say("Auto drive off. You steer.", true)
    else say("Auto drive. Starting.", true) end
end
-- N while in the boat: say the steering line now (route.lua R.go)
function G.boat_kick() boat.steer_at, boat.steer_key, boat.gname_said = 0, nil, nil end
function G.update_boat(now)
    local mc = main_camera_controller()
    local v = mc and mc:get_field("_BusyCameraController")
    if not v or v:get_type_definition():get_name() ~= "VehicleCameraController" then
        boat.on = false
        boat.in_at = nil
        boat.cur_goal, boat.gname_said, boat.obj = nil, nil, nil
        boat.auto_on, boat.auto_cancel, boat.auto_done = false, nil, nil
        G.boat_auto = nil
        G.in_boat = false
        return
    end
    G.in_boat = true
    if not boat.on then
        boat.on = true
        -- the camera flips away and back during the fight: the long help once a minute
        if now - (boat.intro_at or -100) < 60 then return end
        boat.intro_at = now
        -- monster help only during the lake monster fight (10/20: said again on a
        -- plain boat trip in Chapter 4, objective "Find the key to the church")
        local fight = false
        pcall(function() fight = (objective_text() or ""):lower():find("monster") ~= nil end)
        if fight then
            say("In the boat. W goes forward, A and D steer. Hold L: I turn you to the monster. Press K when I say fire.", true)
        else
            say("In the boat. W goes forward, S backs up, A and D steer. Pick a place in a list and I tell you where to steer.", true)
        end
    end
    if G.is_paused and G.is_paused() then return end
    -- Blocked: W held, the boat hardly moves for 3 s (10/19: nose against a cave wall)
    do
        local pos = G.player_pos()
        if pos and reframework:is_key_down(0x57) then
            local an = boat.anchor
            if not an or math.sqrt((pos.x - an.x) ^ 2 + (pos.z - an.z) ^ 2) > 1.5 then
                boat.anchor = { x = pos.x, z = pos.z, at = now }
            elseif now - an.at > 4 and not boat.block_said then
                boat.block_said = true
                boat.plan_goal = nil   -- plan again from here
                pcall(function() G.boat_block_ahead(pos, G.boat_state() or G.facing()) end)
                say("Blocked. Let go of W, hold S for 2 seconds to back up, then hold W again. Or press Backslash and I drive.", true)
            end
        else
            boat.anchor, boat.block_said = nil, false
        end
    end
    -- water route planning runs a bit every frame
    if G.boat_planning then
        local res = G.boat_plan_step()
        if res then
            boat.route, boat.wp = res.pts, 2
            log.info(string.format("[RE4Access] boat route: %d turning points, reached %s, %.0f m short", #res.pts, tostring(res.reached), res.left or -1))
            local t = {}
            for _, q in ipairs(res.pts) do t[#t + 1] = string.format("(%.0f,%.0f)", q.x, q.z) end
            log.info("[RE4Access] boat route path: " .. table.concat(t, " "))
            say(res.reached and ("Water route found, " .. (#res.pts - 1) .. " legs. Hold W and steer as I say.")
                or "Only part of the water route is known. Hold W and steer as I say, then I look further.", false)
            boat.steer_at = 0
        end
    end
    -- F to get off: the game offers it at landing spots (10/19 Chapter 4: the
    -- Apostate's Head is on a small dock only the boat reaches)
    local fon = false
    pcall(function() fon = G.prompt_active() end)
    -- not right after getting in (the boarding F prompt is still up then)
    boat.in_at = boat.in_at or now
    if fon and not boat.f_was and now - boat.in_at > 4 then say("F ready. Press F to get off the boat here.", true) end
    boat.f_was = fon
    -- AUTO DRIVE (10/20). Close to the landing (20 m) it takes over by itself;
    -- Backslash in the boat = the mod drives the whole water route. It steers
    -- the boat (hook on GmBoat.UpdateBoat writes the stick fields), backs out
    -- when the nose is stuck or the way on is behind, stops at the F spot.
    -- S takes the boat back.
    G.boat_auto = nil
    do
        local pos = G.player_pos()
        local pier = boat.cur_goal and boat.pier
        local pkey = pier and string.format("%.0f,%.0f", pier.x, pier.z)
        if reframework:is_key_down(0x53) and boat.auto_on then
            boat.auto_on, boat.drive_all, boat.auto_cancel = false, false, pkey
            say("Auto drive off. You steer.", true)
        end
        local dp = pier and pos and math.sqrt((pier.x - pos.x) ^ 2 + (pier.z - pos.z) ^ 2)
        if fon and dp and dp < 25 then
            if boat.auto_on then
                boat.auto_on, boat.drive_all = false, false
                boat.auto_hold = now
                say("Stopped at the landing. Press F to get off.", true)
            end
            if boat.auto_hold and now - boat.auto_hold < 2 then G.boat_auto = { lx = 0, ly = 0 } end
        elseif pier and pos and not boat.boss and boat.auto_cancel ~= pkey and (boat.drive_all or dp < 20) then
            if not boat.auto_on then
                if not G.boat_map or not G.boat_map.ly then
                    if now - (boat.nomap_said or -100) > 15 then
                        boat.nomap_said = now
                        say("Auto drive can't take over yet: hold W and steer once so I learn the keys.", true)
                    end
                else
                    boat.auto_on = true
                    boat.man = { mode = "fwd", since = now }
                    say(boat.drive_all and "Auto drive on. Let go of the keys. S stops it." or "Auto drive. Let go of the keys, I drive you to the landing. S stops it.", true)
                end
            end
            if boat.auto_on then
                -- Route far longer than the straight line to a landing that is close:
                -- drive straight at it and back out of what is in the way (10/20:
                -- 60 m from the landing the route went 650 m round the lake).
                local direct = dp < 20
                if not direct and dp < 150 and boat.route and boat.wp then
                    local len, prev = 0, pos
                    for k = boat.wp, #boat.route do
                        local q = boat.route[k]
                        len = len + math.sqrt((q.x - prev.x) ^ 2 + (q.z - prev.z) ^ 2)
                        prev = q
                    end
                    if len > dp * 2.5 and now > (boat.no_direct_until or 0) then
                        -- only when the straight line really is open water (10/20: drove
                        -- straight into the shore 80 m from the cliff landing, the
                        -- long way round was the real one)
                        if not boat.line_at or now - boat.line_at > 2 then
                            boat.line_at = now
                            local okl, open = pcall(G.boat_open_step, pos.x, pos.z, pier.x, pier.z, pos.y)
                            boat.line_open = okl and open
                        end
                        if boat.line_open then direct = true end
                    end
                end
                if direct ~= boat.was_direct then
                    boat.was_direct = direct
                    log.info("[RE4Access] auto drive: " .. (direct and "straight at the landing" or "following the water route"))
                end
                -- Turning points: checked every frame while it drives (10/20: at
                -- 10 m/s the 2.5 s steering check let the boat shoot past a
                -- point, turn round for it, and go back and forth). A point is
                -- passed within 10 m, or once the boat is beyond it along the leg.
                if not direct and boat.route and boat.wp then
                    while boat.wp < #boat.route do
                        local w, nx = boat.route[boat.wp], boat.route[boat.wp + 1]
                        local dw = math.sqrt((w.x - pos.x) ^ 2 + (w.z - pos.z) ^ 2)
                        local lx, lz = nx.x - w.x, nx.z - w.z
                        local beyond = (pos.x - w.x) * lx + (pos.z - w.z) * lz > 0
                        if dw < 10 or (beyond and dw < 30) then boat.wp = boat.wp + 1 else break end
                    end
                    boat.cur_goal = boat.route[boat.wp]
                    -- The game loads walls and shores only near the boat: a far leg
                    -- planned over "open water" can run into land that shows up as
                    -- the boat gets close (10/20: an invisible wall at x 198 in front
                    -- of the cliff landing, stuck 30+ times). Re-check the leg ahead
                    -- every second; blocked -> plan again from here.
                    if now - (boat.leg_check or 0) > 1 and not G.boat_planning then
                        boat.leg_check = now
                        local w = boat.cur_goal
                        local dw = w and math.sqrt((w.x - pos.x) ^ 2 + (w.z - pos.z) ^ 2) or 0
                        if w and dw > 12 then
                            local ah = math.min(dw, 40)
                            local ex, ez = pos.x + (w.x - pos.x) / dw * ah, pos.z + (w.z - pos.z) / dw * ah
                            local okl, open = pcall(G.boat_open_step, pos.x, pos.z, ex, ez, pos.y, true)
                            if okl and open == false and now - (boat.replan_at or -100) > 6 then
                                boat.replan_at = now
                                log.info(string.format("[RE4Access] auto drive: leg ahead blocked at (%.0f,%.0f), planning again", pos.x, pos.z))
                                boat.plan_goal = nil
                            end
                        end
                    end
                end
                local tg = direct and pier or boat.cur_goal
                local h, spd = G.boat_state()
                h = h or G.facing()
                spd = spd or 0
                local rel = h and ((heading_of(tg.x - pos.x, tg.z - pos.z) - h + 540) % 360 - 180) or 0   -- + = left
                -- measured 10/20 13:38: stick -1 forward raised the heading (= turned
                -- LEFT); the learned sign was backwards and the boat circled
                local sgn = -1
                local turn = math.max(-1, math.min(1, rel / 25))
                local man = boat.man or { mode = "fwd", since = now }
                boat.man = man
                -- room in front of the nose?
                local front = 99
                pcall(function()
                    local a = math.rad(h)
                    local hit, d = RE4Access.route.cast(pos.x + math.sin(a) * 1.2, pos.y + 1.0, pos.z + math.cos(a) * 1.2,
                        pos.x + math.sin(a) * 6, pos.y + 1.0, pos.z + math.cos(a) * 6)
                    if hit then front = d + 1.2 end
                end)
                if man.mode == "fwd" then
                    -- stuck = under 0.6 m moved in 1.5 s (10/20: _Speed reads 0.05 while
                    -- the boat moves 1-2 m a second, so the speed test backed up every 3 s)
                    local an = man.anchor
                    if not an or math.sqrt((pos.x - an.x) ^ 2 + (pos.z - an.z) ^ 2) > 0.6 then
                        man.anchor = { x = pos.x, z = pos.z, at = now }
                        man.slow_at = nil
                    else
                        man.slow_at = an.at
                    end
                    local stuck = man.slow_at and now - man.slow_at > 1.5 and now - man.since > 2
                    -- way on behind and the nose close to a wall: back out; after a
                    -- back-up give the forward swing 2.5 s before backing again
                    local behind_tight = math.abs(rel) > 110 and front < 3 and now - man.since > 2.5
                    if stuck or behind_tight then
                        man.mode, man.since, man.slow_at, man.anchor = "rev", now, nil, nil
                        man.rev_lx = -sgn * (rel >= 0 and 1 or -1)   -- back out swinging the nose toward the way on
                        man.tries = (man.tries or 0) + 1
                        log.info(string.format("[RE4Access] auto drive: back up (%s), rel %.0f, front %.1f, try %d", stuck and "stuck" or "way behind", rel, front, man.tries))
                        -- stuck 3 times within 4 m: mark it and plan another way
                        if stuck then
                            local sp = man.stuck_pos
                            if sp and math.sqrt((sp.x - pos.x) ^ 2 + (sp.z - pos.z) ^ 2) < 4 then
                                man.stuck_n = (man.stuck_n or 0) + 1
                            else
                                man.stuck_pos, man.stuck_n = { x = pos.x, z = pos.z }, 1
                            end
                            if man.stuck_n >= 3 then
                                man.stuck_n = 0
                                if direct then
                                    boat.no_direct_until = now + 60
                                    log.info("[RE4Access] auto drive: straight line blocked, following the water route")
                                else
                                    pcall(function() G.boat_block_ahead(pos, h) end)
                                    boat.plan_goal = nil
                                end
                            end
                        end
                    else
                        local ly = 1
                        if math.abs(rel) > 70 then ly = 0.6 end
                        if not direct and boat.route and boat.wp and boat.wp < #boat.route then
                            local w, nx = boat.route[boat.wp], boat.route[boat.wp + 1]
                            local dw = math.sqrt((w.x - pos.x) ^ 2 + (w.z - pos.z) ^ 2)
                            local h1, h2 = heading_of(w.x - pos.x, w.z - pos.z), heading_of(nx.x - w.x, nx.z - w.z)
                            local bend = math.abs((h2 - h1 + 540) % 360 - 180)
                            if dw < 20 and bend > 45 then ly = math.min(ly, 0.6) end
                        end
                        if tg == pier then ly = dp > 8 and 1 or (dp > 3 and 0.6 or 0.4) end
                        G.boat_auto = { lx = sgn * turn, ly = ly }
                    end
                end
                if man.mode == "rev" then
                    G.boat_auto = { lx = man.rev_lx, ly = -1 }
                    man.rev_from = man.rev_from or { x = pos.x, z = pos.z }
                    local moved = math.sqrt((pos.x - man.rev_from.x) ^ 2 + (pos.z - man.rev_from.z) ^ 2)
                    -- (10/20: 1 s of reverse moved the boat 0.1 m, then it hit the shore again)
                    if moved > 3 or now - man.since > 2.5 then man.mode, man.since, man.rev_from = "fwd", now, nil end
                end
                -- forward swing right after backing: full lock toward the way on
                if man.mode == "fwd" and now - man.since < 2.5 and math.abs(rel) > 60 and G.boat_auto and G.boat_auto.ly > 0 then
                    G.boat_auto.lx = sgn * (rel >= 0 and 1 or -1)
                end
                if now - (boat.auto_log or 0) > 1 then
                    boat.auto_log = now
                    log.info(string.format("[RE4Access] auto drive: pos (%.1f,%.1f) hdg %.0f rel %.0f speed %.2f front %.1f mode %s stick %s to (%.0f,%.0f) landing %.0f m",
                        pos.x, pos.z, h or -1, rel, spd, front, man.mode, G.boat_auto and string.format("%.1f %.1f", G.boat_auto.lx, G.boat_auto.ly) or "-", tg.x, tg.z, dp))
                end
                if now - (boat.auto_said or 0) > 6 then
                    boat.auto_said = now
                    say(math.floor((dp or 0) + 0.5) .. " meters to the landing", false)
                end
            end
        end
        if not pier then boat.auto_on, boat.drive_all, boat.auto_cancel = false, false, nil end
        if boat.auto_hold and not fon and now - boat.auto_hold > 3 then boat.auto_hold = nil end
    end
    local l = reframework:is_key_down(0x4C)
    -- Turning feedback (10/20: "no clue whether it is turning or how many
    -- degrees"): while A or D is held, the degrees still to turn every 0.7 s,
    -- "Straight" when on course; with nothing picked, the compass every 45 deg.
    do
        local turning = reframework:is_key_down(0x41) or reframework:is_key_down(0x44)
        local h, spd
        if turning then h, spd = G.boat_state() h = h or G.facing() end
        -- A/D with the boat standing still: it turns only while moving
        if turning and spd and math.abs(spd) < 0.3 then
            boat.still_at = boat.still_at or now
            if now - boat.still_at > 1.5 and now - (boat.still_said or -100) > 20 then
                boat.still_said = now
                say("Hold W too. The boat turns only while it moves.", true)
            end
        else
            boat.still_at = nil
        end
        local pos = h and G.player_pos()
        if pos and boat.cur_goal and not l and not boat.auto_on then
            local g = boat.cur_goal
            local rel = (heading_of(g.x - pos.x, g.z - pos.z) - h + 540) % 360 - 180   -- + = left
            local a = math.abs(rel)
            if a < 10 then
                if not boat.straight_said then
                    boat.straight_said = true
                    say("Straight. Let go.", true)
                end
                boat.turn_at = now
            elseif now - (boat.turn_at or 0) > 0.7 then
                boat.turn_at = now
                boat.straight_said = false
                local want = rel > 0 and "A" or "D"
                local wrong = boat.turn_last and a > boat.turn_last + 3
                say(string.format("%d%s", math.floor(a / 5 + 0.5) * 5, wrong and (", wrong way, " .. want) or ""), true)
                boat.turn_last = a
            end
            boat.steer_at = now   -- the turn numbers replace the slow steering line
        elseif pos and not boat.cur_goal and not boat.boss then
            local c = compass(h)
            if c ~= boat.compass_said then boat.compass_said = c say(c, true) end
        end
        if not turning then boat.turn_last, boat.straight_said = nil, false end
    end
    -- Steering to the thing you picked in a list: direction and distance every 2.5 s
    local boss = false
    pcall(function() boss = (objective_text() or ""):lower():find("monster") ~= nil end)
    boat.boss = boss
    if boss or not (selected and selected.pos and selected.name ~= "Boat") then boat.cur_goal = nil end
    -- (not when the picked thing is the boat itself: 10/19 "landing for Boat here, get off")
    if not l and not boss and selected and selected.pos and selected.name ~= "Boat" and now - (boat.steer_at or 0) > 2.5 then
        local pos = G.player_pos()
        local h = G.facing()
        -- Steer to the boat landing (pier) nearest the picked thing, not the thing
        -- itself (10/19: the Apostate's Head dock has no landing; the boat pushed
        -- into rocks). Piers come from the boat's own PierData.
        local goal, gname = selected.pos, selected.name
        pcall(function()
            local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                local go = core and core:call("get_GameObject")
                local b = go and go:call("get_DrawSelf") and go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmBoat"))
                if b then
                    local gl = b:get_field("_PierData"):get_field("PierGroupList")
                    local best, bd
                    for i = 0, gl:call("get_Count") - 1 do
                        local g = gl:call("get_Item", i)
                        if g:get_field("Enable") then
                            local cp = g:get_field("InputKeyCenterPos")
                            local d = math.sqrt((cp.x - selected.pos.x) ^ 2 + (cp.z - selected.pos.z) ^ 2)
                            if not bd or d < bd then best, bd = { x = cp.x, y = cp.y, z = cp.z, r = g:get_field("InputKeyRadius") }, d end
                        end
                    end
                    -- a known landing for the objective (G.LAND_WAYS), not the nearest one
                    local lw = (selected.key == "objective" or selected.name == "Objective") and G.land_way(objective_text())
                    if lw then
                        best = lw.pier
                        if lw.via and pos and pos.x < lw.via_west then best = lw.via end
                    end
                    if best then goal, gname = best, lw and lw.pier_name or ("landing for " .. selected.name) boat.pier = best end
                    return
                end
            end
        end)
        -- water route to the goal: plan when the goal changes, then steer to
        -- one turning point after the other
        if pos and (not boat.plan_goal or math.abs(boat.plan_goal.x - goal.x) + math.abs(boat.plan_goal.z - goal.z) > 3) then
            boat.plan_goal = { x = goal.x, z = goal.z }
            boat.route, boat.wp = nil, nil
            G.boat_plan_start(pos, goal)
            say("Finding a water route to " .. gname .. ".", false)
            return
        end
        if G.boat_planning then return end
        local final = goal
        if boat.route and boat.wp and boat.route[boat.wp] and pos then
            local w = boat.route[boat.wp]
            local function passed(w)
                if math.sqrt((w.x - pos.x) ^ 2 + (w.z - pos.z) ^ 2) < 7 then return true end
                local nx = boat.route[boat.wp + 1]
                return nx and math.sqrt((w.x - pos.x) ^ 2 + (w.z - pos.z) ^ 2) < 15 and G.boat_open_step(pos.x, pos.z, nx.x, nx.z, pos.y, true)
            end
            while w and boat.wp < #boat.route and passed(w) do
                boat.wp = boat.wp + 1
                w = boat.route[boat.wp]
            end
            if w and boat.wp < #boat.route then goal = w end
            -- at the end of a part route and still far: plan again from here
            if w and boat.wp >= #boat.route and math.sqrt((w.x - pos.x) ^ 2 + (w.z - pos.z) ^ 2) < 6
                and math.sqrt((final.x - pos.x) ^ 2 + (final.z - pos.z) ^ 2) > 10 then
                boat.plan_goal = nil
            end
        end
        h = G.boat_state() or h
        if pos and h then
            boat.steer_at = now
            boat.cur_goal = goal
            local dx, dz = goal.x - pos.x, goal.z - pos.z
            local d = math.sqrt(dx * dx + dz * dz)
            local dir = relative(heading_of(dx, dz) - h)
            local key = dir .. math.floor(d / 5)
            -- say it when it changed, or every 10 s
            if key ~= boat.steer_key or now - (boat.steer_said or 0) > (dir == "ahead" and 10 or 5) then
                boat.steer_key, boat.steer_said = key, now
                -- straight behind: keep turning the same way (10/19: "behind left, A",
                -- "behind, D" flipped every 2.5 s and the boat never turned round)
                local side = dir:find("left") and "A" or (dir:find("right") and "D") or boat.side or "D"
                if dir ~= "ahead" then boat.side = side end
                local tip = dir == "ahead" and "" or (", steer with " .. side)
                -- distance still to go along the route
                local left = d
                if boat.route and boat.wp then
                    local prev = goal
                    for k = boat.wp + 1, #boat.route do
                        local q = boat.route[k]
                        left = left + math.sqrt((q.x - prev.x) ^ 2 + (q.z - prev.z) ^ 2)
                        prev = q
                    end
                end
                d = left
                local fd = math.sqrt((final.x - pos.x) ^ 2 + (final.z - pos.z) ^ 2)
                if boat.pier and fd < (boat.pier.r or 5) then
                    say(gname .. " here. Let go of W and press F to get off.", false)
                else
                    -- short, key first (10/20: "the message is so long before I hear
                    -- anything meaningful"): "D, 40 degrees, 13 meters" / "Straight, 31 meters"
                    local rel = (heading_of(dx, dz) - h + 540) % 360 - 180
                    local a = math.abs(rel)
                    local line
                    if a < 10 then line = string.format("Straight, %s, %d meters", compass(heading_of(dx, dz)), math.floor(d + 0.5))
                    else
                        local k = a > 165 and side or (rel > 0 and "A" or "D")
                        line = string.format("Turn %s with %s, %d degrees, to face %s. %d meters", k == "A" and "left" or "right", k, math.floor(a / 5 + 0.5) * 5, compass(heading_of(dx, dz)), math.floor(d + 0.5))
                    end
                    if gname ~= boat.gname_said then boat.gname_said = gname line = gname .. ". " .. line end
                    if not boat.auto_on then say(line, false) end
                end
            end
        end
    end
    if not l then boat.fire_said, boat.none_said, boat.l_at = false, false, nil return end
    boat.l_at = boat.l_at or now
    local pos = G.player_pos()
    local tgt, td
    pcall(function()
        local list = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
        for i = 0, list:call("get_Count") - 1 do
            local ctx = list:call("get_Item", i)
            local hp = ctx:call("get_HitPoint")
            if hp:call("get_IsLive") and hp:call("get_CurrentHitPoint") > 1 then
                local p = ctx:call("get_Position")
                local d = math.sqrt((p.x - pos.x) ^ 2 + (p.z - pos.z) ^ 2)
                if not td or d < td then tgt, td = { x = p.x, y = p.y + 0.6, z = p.z }, d end
            end
        end
    end)
    if not tgt then
        if not boat.none_said then
            boat.none_said = true
            if boss then say("The monster is under water. Steer with W, A and D, and wait.", true)
            else say("No enemy in sight", true) end
        end
        return
    end
    local c, r = mc:get_field("_CameraPosition"), mc:get_field("_CameraRotation")
    local fx = -(2 * (r.x * r.z + r.w * r.y))
    local fy = -(2 * (r.y * r.z - r.w * r.x))
    local fz = -(1 - 2 * (r.x * r.x + r.y * r.y))
    local dx, dy, dz = tgt.x - c.x, tgt.y - c.y, tgt.z - c.z
    local yaw_err = math.atan(dx, dz) - math.atan(fx, fz)
    if yaw_err > math.pi then yaw_err = yaw_err - 2 * math.pi elseif yaw_err < -math.pi then yaw_err = yaw_err + 2 * math.pi end
    local pitch_err = math.atan(dy, math.sqrt(dx * dx + dz * dz)) - math.atan(fy, math.sqrt(fx * fx + fz * fz))
    v:set_field("_Yaw", v:get_field("_Yaw") + G.boat_ys * yaw_err * 0.5)
    v:set_field("_Pitch", v:get_field("_Pitch") + pitch_err * 0.5)
    G.boat_err = { yaw = yaw_err, pitch = pitch_err }
    if math.abs(yaw_err) < 0.06 and math.abs(pitch_err) < 0.08 then
        if not boat.fire_said and now - boat.l_at > 0.3 and now - (boat.fire_at or -10) > 2 then
            boat.fire_said = true
            boat.fire_at = now
            say("Fire. " .. math.floor(td + 0.5) .. " meters", true)
        end
    elseif math.abs(yaw_err) > 0.25 then
        boat.fire_said = false
    end
end
end

-- Symbol button puzzle (GmHeptaPuzzle, 10/19 south cave: 8 symbols, press the
-- 3 that are painted in yellow around the cave - a sighted player reads the
-- walls; the mod says which ones those are). Says the symbol under the cursor.
do
local hp = {}
-- 10/20 north cave: symbols 2, 4, 6, 8 need two direction keys held together
-- ("impossible as it is"). ] and [ now move the cursor one symbol; the hook
-- on calcSelectIndex (the game sets the cursor from the stick every frame)
-- writes the picked symbol. A direction key gives the stick back.
-- Writing SelectIndex was ignored (10/20 log: want 6, index 8): the game
-- picks the symbol from the stick angle. Answer the angle getters instead:
-- symbol i (0-based) sits at i * 45 degrees (W = 1, D = 3, S = 5, A = 7).
if not RE4Access.hepta_deg_hooked then
    RE4Access.hepta_deg_hooked = true
    pcall(function()
        local td = sdk.find_type_definition("chainsaw.GmHeptaPuzzle")
        for _, name in ipairs({ "calcKeyDeg", "get_StickDegree" }) do
            local m = td:get_method(name)
            if m then
                sdk.hook(m, function(args) end, function(r)
                    local G2 = RE4Access.game
                    local deg = sdk.to_float(r)
                    if G2 and G2.hepta_log_deg and deg ~= G2.hepta_last_deg then
                        G2.hepta_last_deg = deg
                        log.info(string.format("[RE4Access] hepta: %s = %.1f", name, deg))
                    end
                    local want = G2 and G2.hepta_want
                    if want then return sdk.float_to_ptr(want * 45.0 * (G2.hepta_deg_sign or 1)) end
                    return r
                end)
            end
        end
    end)
end
G.hepta_log_deg = true
if not RE4Access.hepta_hooked then
    RE4Access.hepta_hooked = true
    pcall(function()
        local m = sdk.find_type_definition("chainsaw.GmHeptaPuzzle"):get_method("calcSelectIndex")
        local this_obj
        sdk.hook(m, function(args) this_obj = args[2] end, function(r)
            local want = RE4Access.game and RE4Access.game.hepta_want
            if want and this_obj then
                pcall(function()
                    local h = sdk.to_managed_object(this_obj)
                    h:set_field("SelectIndex", want)
                end)
            end
            return r
        end)
    end)
end
function G.hepta_active() return hp.active == true end
-- Landing on a symbol pushes it (10/20 log: stepping 4 -> 5 -> 6 pushed all
-- three and the puzzle reset). So the brackets jump straight to the next
-- painted symbol not pushed yet, never over the others.
function G.hepta_step(dir)
    local h = hp.gm
    if not h then return end
    local ans = {}
    pcall(function()
        local l = h:get_field("_Data"):get_field("_Answers")
        for i = 0, l:call("get_Count") - 1 do ans[#ans + 1] = l:call("get_Item", i) end
    end)
    table.sort(ans)
    local todo = {}
    local btn = h:get_field("_Buttons")
    for _, a in ipairs(ans) do
        local pushed = false
        pcall(function() pushed = btn:call("get_Item", a):call("get_IsPushed") end)
        if not pushed then todo[#todo + 1] = a end
    end
    if #todo == 0 then todo = ans end
    if #todo == 0 then return end
    hp.jump = ((hp.jump or 0) + (dir > 0 and 1 or -1) - 1) % #todo + 1
    G.hepta_want = todo[hp.jump]
    log.info("[RE4Access] hepta: jump to symbol " .. (G.hepta_want + 1))
end
function G.update_hepta(now)
    if now < (hp.at or 0) then return end
    hp.at = now + 0.1
    local pos = G.player_pos()
    if not pos then return end
    if not hp.gm or now > (hp.scan_at or 0) then
        hp.scan_at = now + 3
        hp.gm = nil
        pcall(function()
            local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                local go = core and core:call("get_GameObject")
                local h = go and go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmHeptaPuzzle"))
                if h then
                    local p = go:call("get_Transform"):call("get_Position")
                    if math.sqrt((p.x - pos.x) ^ 2 + (p.z - pos.z) ^ 2) < 6 then hp.gm = h break end
                end
            end
        end)
    end
    local h = hp.gm
    if not h then hp.active = false return end
    local using = false
    pcall(function() using = h:get_field("_User") ~= nil end)
    if not using then
        if hp.active then hp.active = false end
        G.hepta_want = nil
        return
    end
    if reframework:is_key_down(0x57) or reframework:is_key_down(0x41) or reframework:is_key_down(0x53) or reframework:is_key_down(0x44) then
        G.hepta_want = nil
    end
    if G.hepta_want then
        pcall(function()
            h:set_field("SelectIndex", G.hepta_want)
            h:set_field("_OldSelectIndex", G.hepta_want)
        end)
    end
    local ans = {}
    pcall(function()
        local l = h:get_field("_Data"):get_field("_Answers")
        for i = 0, l:call("get_Count") - 1 do ans[l:call("get_Item", i)] = true end
    end)
    local idx = h:get_field("SelectIndex")
    if not hp.active then
        hp.active, hp.idx = true, nil
        local list = {}
        for i = 0, 7 do if ans[i] then list[#list + 1] = tostring(i + 1) end end
        -- The cursor follows the direction keys like a stick (10/19 test: W, D, S, A
        -- gave symbols 1, 3, 5, 7); the in-between symbols need two keys held.
        local KEYS = { [0] = "W", "W and D together", "D", "S and D together", "S", "S and A together", "A", "W and A together" }
        local how = {}
        for i = 0, 7 do if ans[i] then how[#how + 1] = "hold " .. KEYS[i] .. ", then press Enter" end end
        hp.done, hp.jump = {}, 0
        say("Symbol puzzle. Push the painted symbols: " .. table.concat(list, ", ")
            .. ". Press Right bracket: I jump to the next painted symbol. Then press Enter to push it. I say Pushed when it worked.", true)
    end
    if idx ~= hp.idx then
        hp.idx = idx
        say("Symbol " .. (idx + 1) .. (ans[idx] and ", painted one, press Enter" or ""), true)
    end
    -- say when a symbol really got pushed (10/19: F only moved on; the push key is unclear)
    local okn, pushed = pcall(function() return h:call("get_PushedButtonNum") end)
    if okn and pushed and pushed ~= hp.pushed then
        hp.done = hp.done or {}
        if (hp.pushed or 0) > 0 and pushed < hp.pushed then hp.done, hp.jump = {}, 0 end
        if pushed > (hp.pushed or 0) then hp.done[idx] = true hp.jump = 0 G.hepta_want = nil end
        log.info(string.format("[RE4Access] hepta: pushed %d, index %d, want %s", pushed, idx + 1, tostring(G.hepta_want and G.hepta_want + 1)))
        if hp.pushed ~= nil then
            say(pushed > (hp.pushed or 0) and ("Pushed. " .. pushed .. " of 3.") or "The symbols reset. Start again.", true)
        end
        hp.pushed = pushed
    end
end
end

-- Autosaves and typewriter saves: the save icon (share.SaveDataManager
-- IsShowSaveIcon) comes on while the game writes (10/20: user asked to be told).
function G.watch_save(now)
    if now < (G.save_at or 0) then return end
    G.save_at = now + 0.25
    local sm = sdk.get_managed_singleton("share.SaveDataManager")
    if not sm then return end
    local on = sm:call("get_IsShowSaveIcon")
    if on and not G.save_icon and now - (G.save_said or -100) > 10 then
        G.save_said = now
        local auto = false
        pcall(function() auto = sm:call("IsAutoSaveFlow") end)
        say(auto and "Autosaved." or "Game saved.", false)
        log.info("[RE4Access] save icon on, auto " .. tostring(auto))
    end
    G.save_icon = on
end
function G.on_frame()
    local now = os.clock()
    pcall(G.watch_heads, now)
    pcall(G.watch_save, now)
    pcall(G.update_hepta, now)
    pcall(G.update_binoculars, now)
    pcall(G.update_boat, now)
    pcall(G.check_selected_gone, now)
    local okdoc, errdoc = pcall(G.update_documents, now)
    if not okdoc then log.info("[RE4Access] document error: " .. tostring(errdoc)) end
    if now - last_state_check > 0.1 then
        last_state_check = now
        pcall(update_state, now)
        pcall(check_turn)
        local okt, errt = pcall(function()
            if G.state_text == "In control" then
                local pos = G.player_pos()
                if pos then
                    update_trail(pos)
                    update_visited(pos, now)
                    pcall(G.locker_watch, pos, now)
                    local okr, errr = pcall(update_reach, pos, now)
                    if not okr then log.info("[RE4Access] reach error: " .. tostring(errr)) end
                end
                pcall(update_objective, now)
                if G.state_text == "In control" then
                    local pos2 = G.player_pos()
                    if pos2 then
                        local okts, errts = pcall(G.update_trap_shots, pos2, now)
                        if not okts then log.info("[RE4Access] trap shot error: " .. tostring(errts)) end
                        local okwf, errwf = pcall(G.update_window_fight, pos2, now)
                        if not okwf then log.info("[RE4Access] window fight error: " .. tostring(errwf)) end
                        local oksn, errsn = pcall(G.update_sneak, pos2, now)
                        if not oksn then log.info("[RE4Access] sneak error: " .. tostring(errsn)) end
                        local okch8, errch8 = pcall(G.update_chandelier, pos2, now)
                        if not okch8 then log.info("[RE4Access] chandelier error: " .. tostring(errch8)) end
                        local oksm, errsm = pcall(G.update_summoner, pos2, now)
                        if not oksm then log.info("[RE4Access] summoner error: " .. tostring(errsm)) end
                        local okd, errd = pcall(update_dynamite, pos2, now)
                        if not okd then log.info("[RE4Access] dynamite error: " .. tostring(errd)) end
                        local oka2, erra2 = pcall(G.update_attack, pos2, now)
                        if not oka2 then log.info("[RE4Access] attack warn error: " .. tostring(erra2)) end
                        local okpr, errpr = pcall(update_prompt, now)
                        if not okpr then log.info("[RE4Access] prompt error: " .. tostring(errpr)) end
                        local okch, errch = pcall(update_chase, pos2, now)
                        if not okch then log.info("[RE4Access] chase error: " .. tostring(errch)) end
                        local oksh, errsh = pcall(update_timed_shutter, pos2, now)
                        if not oksh then log.info("[RE4Access] timed shutter error: " .. tostring(errsh)) end
                        local oke, erre = pcall(update_enemy_warning, pos2, now)
                        if not oke then log.info("[RE4Access] enemy warning error: " .. tostring(erre)) end
                        if RE4Access.places then
                            local okb, errb = pcall(RE4Access.places.update, pos2, now)
                            if not okb then log.info("[RE4Access] buildings error: " .. tostring(errb)) end
                        end
                    end
                end
            end
        end)
        if not okt then log.info("[RE4Access] trail error: " .. tostring(errt)) end
        local okw, errw = pcall(update_walk, now)
        -- Combat feedback runs in every state, so a death is noticed too.
        if G.state_text == "In control" then
            local pd = G.player_pos()
            if pd then pcall(update_drops, pd, now) end
        end
        local okc, errc = pcall(update_combat, now)
        if not okc then log.info("[RE4Access] combat error: " .. tostring(errc)) end
        if not okw then log.info("[RE4Access] walk error: " .. tostring(errw)) end
    end
    if RE4Access.route then
        local okr, errr = pcall(RE4Access.route.on_frame, now)
        if not okr then log.info("[RE4Access] route error: " .. tostring(errr)) end
    end
    if G.state_text == "In control" and RE4Access.places and not RE4Access.places.rays_dead then
        local okw2, errw2 = pcall(RE4Access.places.work)
        if not okw2 then log.info("[RE4Access] buildings map error: " .. tostring(errw2)) end
    end
    if G.state_text == "In control" then
        pcall(watch_gun, now)
        pcall(fill_ammo, now)
        pcall(update_fight_cue, now)
        pcall(update_grenade_cue, now)
        pcall(update_stuck_jump, now)
        local oka, erra = pcall(aim_lock_frame, now)
        if not oka then log.info("[RE4Access] aim lock error: " .. tostring(erra)) end
    end
    if not has_focus() then
        was_down = {}
        return
    end
    local shift = reframework:is_key_down(VK.SHIFT)
    local ok, err = pcall(function()
        -- 0.23.0 (tester 11/1): keys are silent in cutscenes and the shop, so an
        -- accidental press never talks over a subtitle.
        if G.cam_busy == "chainsaw.EventCameraController" or G.state_text == "Merchant" then
            was_down = {}
            return
        end
        if pressed(VK.F1) then if shift and RE4Access.update then RE4Access.update.key() else G.settings_help() end end
        if pressed(VK.F2) then G.toggle_combat_quiet() end
        if pressed(VK.F3) then G.toggle_walk_reports() end
        if pressed(VK.F4) then toggle_short() end
        if pressed(VK.F5) then toggle_directions() end
        if pressed(VK.F6) then G.toggle_fight_sound() end
        if pressed(VK.F7) then G.toggle_hit_sound() end
        if pressed(VK.F8) then G.next_list_range() end
        -- Pause menu: only Y (repeat) speaks. Holding W there still explains itself.
        if G.is_paused and G.is_paused() then
            if pressed(VK.Y) then RE4Access.repeat_last() end
            return
        end
        if pressed(VK.H) then where_am_i() end
        if pressed(VK.Y) then RE4Access.repeat_last() end
        if pressed(VK.RBRACKET) then if G.hepta_active and G.hepta_active() then G.hepta_step(1) else cycle(1) end end
        if pressed(VK.LBRACKET) then if G.hepta_active and G.hepta_active() then G.hepta_step(-1) else cycle(-1) end end
        -- (in a puzzle Backslash belongs to the puzzle helper, e.g. crystal.lua)
        -- one pressed() call: a second one never sees the press (10/20: Backslash
        -- dead on land after the boat branch was added)
        local bs = pressed(VK.BACKSLASH)
        if bs and G.in_boat then G.boat_toggle_drive()
        elseif bs and not RE4Access.in_puzzle then if shift then toggle_route() else face_selected() end end
        if pressed(VK.QUOTE) then enemy_report() end
        if pressed(VK.SEMICOLON) then switch_category(shift and -1 or 1) end
        if pressed(VK.B) then toggle_back() end
        if pressed(VK.J) then if shift then G.toggle_walk_reports() else route_status() end end
        if pressed(VK.O) then
            -- Shift+O: the map summary (mapread.lua, 10/18)
            if shift and RE4Access.mapread then RE4Access.mapread.summary(false) else say_objective() end
        end
        -- Shift+N = same as J while a route runs. Without a route it stays N, because Shift is also run.
        if pressed(VK.N) then
            if shift and RE4Access.route and RE4Access.route.active() then route_status() else RE4Access.n_story_now = true local okn, en = pcall(G.next_step) RE4Access.n_story_now = nil if not okn then log.info("[RE4Access] N error: " .. tostring(en)) end end
        end   -- via G so a hot-loaded next_step is used (10/22)
        if pressed(VK.U) then
            if shift and RE4Access.owner then
                -- Shift+U: can't die on/off (11/14: user asked after Ashley died 6 times to the
                -- armor knights on the way back with the insignia). Owner builds only, saved.
                G.cant_die = not G.cant_die
                save_settings()
                say(G.cant_die and "Can't die on. Shift U turns it off." or "Can't die off.", true)
            else
                say_health()
            end
        end
        if pressed(VK.X) then
            if shift and RE4Access.owner then
                -- Shift+X: unlimited ammo on/off (10/14: user asked for it after ~100 deaths in the Valley)
                G.unlimited_ammo = not G.unlimited_ammo
                save_settings()
                say(G.unlimited_ammo and "Unlimited ammo on. Shift X turns it off." or "Unlimited ammo off.", true)
            else
                say_gun()
            end
        end   -- X: free in the game (I opens the case)
        if pressed(VK.EQUALS) then say(RE4Access.menu.money_text(), true) end   -- Equals: your money (10/14)
        if pressed(VK.COMMA) then loot_next(shift) end
        if pressed(VK.PERIOD) then if shift then toggle_directions() else next_turn() end end
        if pressed(VK.SLASH) then if shift then what_now() else toggle_short() end end
        if pressed(VK.SPACE) and G.state_text == "In control" then knife_face() end
    end)
    if not ok then log.info("[RE4Access] game key error: " .. tostring(err)) end
end

function G.set_yaw_sign(s) YAW_SIGN = s end
G.face_point = face_point
G.scan_things, G.enemies, G.cycle, G.where_am_i = scan_things, enemies, cycle, where_am_i
G.describe_position = describe_position
-- 11/9 2AM Ch8 storeroom, after the cult leader: Crimson Lantern on the floor
-- -> the lantern statue (GmUseItem gm84_616, child "Cantera") 8 m from the
-- window, by the locked door -> then the autosave spot past the door
-- (再探索用_貯蔵庫～製本室 AutoSave area, (30.8,26.9,-31.8)). Runs before the
-- old hole_step, so N never sends the user up to the chandelier lever.
G.LANTERN_SAVE_SPOT = { x = 30.8, y = 26.9, z = -31.8 }
function G.lantern_step(pos)
    if not pos or pos.x < -15 or pos.x > 45 or pos.z < -40 or pos.z > 12 or pos.y < 23 or pos.y > 31 then return nil end
    local statue
    for _, t in ipairs(G.scan_things(pos, 60)) do
        local okn, nm = pcall(function() return t.go:call("get_Name") end)
        if okn and nm and nm:find("gm84_616", 1, true) then statue = t break end
    end
    if not statue then return nil end
    -- the leader must be dead
    local okl, s = pcall(G.summoner, pos, 80)
    if okl and s then return nil end
    local done = G.gimmick_done(statue.go)
    if not done then
        for _, it in ipairs(G.items(pos, 80)) do
            if tostring(it.name):find("Crimson Lantern", 1, true) then
                return { name = "the Crimson Lantern on the floor", pos = it.pos, dist = it.dist,
                    tip = "When I say F ready, press F to pick it up. Then press N again." }
            end
        end
        -- lantern in the case: stand in front of the statue, face its icon
        local icon = { x = 21.3, y = 26.7, z = -9.3 }
        pcall(function()
            local c = statue.go:call("get_Transform"):call("get_Child")
            while c do
                if c:call("get_GameObject"):call("get_Name") == "IconPos" then local p = c:call("get_Position") icon = { x = p.x, y = p.y, z = p.z } end
                c = c:call("get_Next")
            end
        end)
        local sp = statue.pos
        local dx, dz = icon.x - sp.x, icon.z - sp.z
        local dl = math.sqrt(dx * dx + dz * dz)
        if dl < 0.05 then dx, dz, dl = 0, 1, 1 end
        local stand
        local R = RE4Access.route
        local base = math.atan(dx, dz)
        for _, rr in ipairs({ 1.0, 1.3, 0.8, 1.6 }) do
            for k = 0, 6 do
                local a = base + (k % 2 == 0 and 1 or -1) * math.floor((k + 1) / 2) * math.pi / 8
                local q = { x = sp.x + math.sin(a) * rr, y = 24.94, z = sp.z + math.cos(a) * rr }
                local okn, pts = pcall(R.nav_points, pos, q)
                local last = okn and pts and pts[#pts]
                if last and math.sqrt((last.x - q.x) ^ 2 + (last.z - q.z) ^ 2) < 0.3 then stand = { x = last.x, y = last.y, z = last.z } break end
            end
            if stand then break end
        end
        stand = stand or { x = sp.x + dx / dl * 1.1, y = 24.94, z = sp.z + dz / dl * 1.1 }
        return { name = "the lantern statue", pos = stand, face = icon, dist = math.sqrt((stand.x - pos.x) ^ 2 + (stand.z - pos.z) ^ 2),
            key = statue.key, go = statue.go, latch = true, fname = "Use Item", spoken = "lantern statue",
            after = "Press F. Your case opens: pick the Crimson Lantern and press Enter. That opens the door next to it. Careful: 4 armor suits stand close by. If one moves, hold L and press K, or run on through the door. Then press N again.",
            tip = "It is 8 meters from the window, next to the locked door. Careful, 4 armor suits stand near it; leave them alone." }
    end
    -- statue done: on to the autosave spot past the door
    local S = G.LANTERN_SAVE_SPOT
    local d = math.sqrt((S.x - pos.x) ^ 2 + (S.z - pos.z) ^ 2)
    if d < 3 then return nil end
    return { name = "the autosave spot, through the door by the lantern statue", pos = S, dist = d,
        tip = "The lantern is on the statue, that part is done. Keep holding W: along the wall, around a corner, up some steps, through a door. At the door press F. The armor suits are asleep, walk past them. When the game says it saved, you are safe to quit." }
end
if not G.hole_step_before_lantern then G.hole_step_before_lantern = G.hole_step end
G.hole_step = function(pos)
    local ok, st = pcall(G.lantern_step, pos)
    if ok and st then return st end
    if not ok then log.info("[RE4Access] lantern step error: " .. tostring(st)) end
    return G.hole_step_before_lantern(pos)
end
-- 11/9 1:58AM: after the statue, N stays on the save (it fell back to the old
-- chandelier lever, 70 m, at the save spot). Short speech (user: way too much talking).
if not G.lantern_speak_wrapped and RE4Access.speak then
    G.lantern_speak_wrapped = true
    local sp = RE4Access.speak
    RE4Access.speak = function(text, ...)
        if type(text) == "string" and text:find("Game saved", 1, true) then G.lantern_saved = true end
        return sp(text, ...)
    end
end
if RE4Access.route and not RE4Access.route.lantern_go_wrapped then
    local R = RE4Access.route
    R.lantern_go_wrapped = true
    local go = R.go
    R.go = function(t, ...) if t and t.no_route then return end return go(t, ...) end
end
G.lantern_step_v1 = G.lantern_step_v1 or G.lantern_step
G.lantern_step = function(pos)
    local st = G.lantern_step_v1(pos)
    if st and st.name:find("Crimson Lantern", 1, true) then st.tip = "Press F at F ready." end
    if st and st.name == "the lantern statue" then st.tip = "8 meters." st.after = "Press F, pick the lantern, Enter." end
    if st and st.name:find("autosave", 1, true) then
        st.name = "the save spot"
        st.tip = G.lantern_saved and "" or "Past the door."
        if G.lantern_saved then return { name = "Saved", tip = "You can quit.", no_route = true } end
    end
    if not st and pos and pos.z < -20 and pos.z > -40 and pos.x > 24 and pos.x < 37 then
        if G.lantern_saved then return { name = "Saved", tip = "You can quit.", no_route = true } end
        return { name = "You are at the save spot", tip = "No save yet. Walk 2 steps forward with W, then wait.", no_route = true }
    end
    return st
end

-- Steady hold keys. With a screen reader running, a held key can reach the game
-- as rapid presses and releases, so "hold L to aim" kept dropping the aim. The
-- game reads keys through via.hid.KeyboardDevice isDown/isRelease; for the keys
-- below the answer is replaced by the physical key state (what the hand does).
local STEADY_KEYS = { [0x4C] = true }      -- L = aim
RE4Access.steady_stats = { forced = 0, release_blocked = 0 }
-- OFF since 10/11 8:45 AM: after it was added the game stopped raising the gun at
-- all (no "game aim ON" while L was held, with or without JAWS). Kept for testing.
local STEADY_HOOK = false
if STEADY_HOOK and not RE4Access.hid_hooked then
    RE4Access.hid_hooked = true
    local kd = sdk.find_type_definition("via.hid.KeyboardDevice")
    local tls = {}
    local function pre(args)
        local key = sdk.to_int64(args[3]) & 0xFFFFFFFF
        tls.key = key
    end
    local function post_down(retval)
        local key = tls.key
        if key and STEADY_KEYS[key] and reframework:is_key_down(key) then
            if (sdk.to_int64(retval) & 1) == 0 then RE4Access.steady_stats.forced = RE4Access.steady_stats.forced + 1 end
            return sdk.to_ptr(1)
        end
        return retval
    end
    local function post_release(retval)
        local key = tls.key
        if key and STEADY_KEYS[key] and reframework:is_key_down(key) then
            if (sdk.to_int64(retval) & 1) ~= 0 then RE4Access.steady_stats.release_blocked = RE4Access.steady_stats.release_blocked + 1 end
            return sdk.to_ptr(0)
        end
        return retval
    end
    local ok1, e1 = pcall(sdk.hook, kd:get_method("isDown"), pre, post_down)
    local ok2, e2 = pcall(sdk.hook, kd:get_method("isRelease"), pre, post_release)
    log.info("[RE4Access] steady keys hook: " .. tostring(ok1) .. " " .. tostring(e1) .. " / " .. tostring(ok2) .. " " .. tostring(e2))
end

if not RE4Access.game_hooked then
    RE4Access.game_hooked = true
    re.on_frame(function() RE4Access.game.on_frame() end)
end

RE4Access.game = G
log.info("[RE4Access] game helpers loaded")
-- 11/9 3:50AM Ch8 Bindery: N leads to each Lithographic Stone, then the stone
-- puzzle table (gm84_760 Puzzle Books). Before this N fell back to "the trail"
-- and walked into the table.
do
local G = RE4Access.game
function G.bindery_step(pos)
    if not pos or pos.x < -45 or pos.x > 12 or pos.z < -72 or pos.z > -28 or pos.y < 24 or pos.y > 33 then return nil end
    local table_t
    for _, t in ipairs(G.scan_things(pos, 50)) do
        local okn, nm = pcall(function() return t.go:call("get_Name") end)
        if okn and nm and nm:find("gm84_760", 1, true) then table_t = t break end
    end
    if not table_t then return nil end
    if G.gimmick_done(table_t.go) then return nil end
    local best
    for _, it in ipairs(G.items(pos, 60)) do
        local nm = tostring(it.name)
        if nm:find("Lithographic Stone", 1, true) and math.abs(it.pos.y - pos.y) < 4 and (not best or it.dist < best.dist) then best = it end
    end
    if best then
        local tip = "Press F at F ready."
        for _, t in ipairs(G.scan_things(best.pos, 2)) do
            local okn, nm = pcall(function() return t.go:call("get_Name") end)
            if okn and nm and nm:find("gm84_761", 1, true) then tip = "It is in a glass case. If F does nothing, hold L and press K to break the glass, then F." break end
        end
        return { name = best.name, pos = best.pos, dist = best.dist, tip = tip }
    end
    return { name = "the stone puzzle table", pos = table_t.pos, dist = table_t.dist, key = table_t.key, go = table_t.go,
        tip = "All stones found. Press F at the table." }
end
if not G.hole_step_before_bindery then G.hole_step_before_bindery = G.hole_step end
G.hole_step = function(pos)
    local ok, st = pcall(G.bindery_step, pos)
    if ok and st then return st end
    if not ok then log.info("[RE4Access] bindery step error: " .. tostring(st)) end
    return G.hole_step_before_bindery(pos)
end
log.info("[RE4Access] bindery step loaded")
end
-- 11/9 4:00AM Bindery glass case (chainsaw.GmGlassBox): F only says "Glass Box";
-- the glass must be broken with the knife (Hittable true = still whole).
do
local G = RE4Access.game
function G.glass_intact(go)
    local ok, h = pcall(function()
        local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmGlassBox"))
        return c and c:get_field("Hittable")
    end)
    return ok and h == true
end
G.bindery_step_v1 = G.bindery_step_v1 or G.bindery_step
G.bindery_step = function(pos)
    local st = G.bindery_step_v1(pos)
    if st and st.pos and tostring(st.name):find("Lithographic Stone", 1, true) then
        for _, t in ipairs(G.scan_things(st.pos, 2)) do
            if t.name == "Glass Box" then
                if G.glass_intact(t.go) then
                    st.tip = "It is in a glass case. Go there, then hold Space and press K. Space turns you to the glass. Then press F."
                else
                    st.tip = "The glass is broken. Press F at F ready."
                end
                break
            end
        end
    end
    return st
end
-- running game only: knife_face is local, so turn to the glass on Space here
-- (the file version does it inside knife_face).
if RE4Access.glass_hot ~= nil and not RE4Access.glass_hot_frame then
    RE4Access.glass_hot_frame = true
    local was = false
    re.on_frame(function()
        local down = reframework:is_key_down(0x20)
        if down and not was then
            pcall(function()
                local pos = G.player_pos()
                for _, t in ipairs(G.scan_things(pos, 2.5)) do
                    if t.name == "Glass Box" and G.glass_intact(t.go) then G.face_item(t.pos) break end
                end
            end)
        end
        was = down
    end)
end
end
-- 11/9 4:10AM Bindery stone table (chainsaw.GmPuzzleBooks): speaks where each
-- stone is and what is still wrong, from the game's own answer (_Data
-- CorrectPos/CorrectFace). Spots 0 bottom, 1 right, 2 left, 3 top (child BookN).
do
local G = RE4Access.game
local SPOT = { [0] = "bottom", [1] = "right", [2] = "left", [3] = "top" }
local STONE = { [0] = "Stone A", [1] = "Stone B", [2] = "Stone C", [3] = "Stone D" }
local function books_comp(pos)
    for _, t in ipairs(G.scan_things(pos, 4)) do
        local okn, nm = pcall(function() return t.go:call("get_Name") end)
        if okn and nm and nm:find("gm84_760", 1, true) then
            return t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPuzzleBooks")), t
        end
    end
end
function G.books_report(c, short)
    local data = c:get_field("_Data"):get_elements()
    local wrong, at = {}, {}
    for i = 0, 3 do
        local put = c:call("isBookPut", i)
        local p = c:call("getBookPosIndex", i)
        local f = c:call("isBookFace", i) == true
        local d = data[i + 1]
        local cp, cf = d:get_field("CorrectPos"), d:get_field("CorrectFace") == true
        if not put then wrong[#wrong + 1] = STONE[i] .. " is not on the table yet"
        else
            at[p] = STONE[i]
            if p ~= cp then wrong[#wrong + 1] = STONE[i] .. " goes " .. SPOT[cp] .. (f ~= cf and ", and turn it" or "")
            elseif f ~= cf then wrong[#wrong + 1] = STONE[i] .. " is in the right spot, turn it" end
        end
    end
    if #wrong == 0 then return "All stones are right." end
    local s = ""
    if not short then s = "Now: top " .. (at[3] or "empty") .. ", left " .. (at[2] or "empty") .. ", right " .. (at[1] or "empty") .. ", bottom " .. (at[0] or "empty") .. ". " end
    return s .. "To do: " .. table.concat(wrong, ". ") .. "."
end
local W = { sig = nil, t = 0 }
if not RE4Access.books_frame then
    RE4Access.books_frame = true
    re.on_frame(function()
        local now = os.clock()
        if now - W.t < 0.25 then return end
        W.t = now
        local ok, err = pcall(function()
            local pos = G.player_pos()
            if not pos or pos.z > -38 or pos.z < -50 or pos.x < -14 or pos.x > -3 then W.sig = nil return end
            local c = books_comp(pos)
            if not c then return end
            local cb, cm = c:get_field("_CursorBook"), c:get_field("_CursorMove")
            local parts = { tostring(c:get_field("_Routine")), tostring(cb), tostring(cm) }
            for i = 0, 3 do parts[#parts + 1] = tostring(c:call("getBookPosIndex", i)) .. tostring(c:call("isBookFace", i)) .. tostring(c:call("isBookPut", i)) end
            local sig = table.concat(parts, ",")
            if sig == W.sig then return end
            local first = W.sig == nil
            local old = W.sig and {} or nil
            W.sig = sig
            log.info("[RE4Access] books: routine,cursorBook,cursorMove,books = " .. sig)
            if first then return end
            if cb < 0 and cm < 0 then return end
            -- cursor speech: which spot, what stone is there
            local msg = ""
            local who
            for i = 0, 3 do if c:call("isBookPut", i) and c:call("getBookPosIndex", i) == cm then who = STONE[i] end end
            if cm >= 0 then msg = SPOT[cm] .. ": " .. (who or "empty") .. ". " end
            if cb >= 0 and STONE[cb] then msg = "Holding " .. STONE[cb] .. ". " .. msg end
            RE4Access.speak(msg .. G.books_report(c, true), true)
        end)
        if not ok then log.info("[RE4Access] books error: " .. tostring(err)) end
    end)
end
-- N at the table (puzzle not solved): say the full state
G.bindery_step_v2 = G.bindery_step_v2 or G.bindery_step
G.bindery_step = function(pos)
    local st = G.bindery_step_v2(pos)
    if st and st.name == "the stone puzzle table" then
        local c = books_comp(pos)
        if c and c:call("isAllBookPut") then
            local okr, r = pcall(G.books_report, c, false)
            st.tip = "Press F at the table. " .. (okr and r or "")
        end
    end
    return st
end
end
-- 11/9 4:25AM stone table v2 (keys found live by Claude): F at table starts,
-- arrows move the cursor (slots 0 left, 1 top, 2 right, 3 bottom), F picks up a
-- stone / drops it (dropping on a stone swaps: you then hold that one), Q or E
-- turns the held stone, right mouse button leaves. Live state: _PosBook (slot ->
-- book), _HaveBook, book <IsFace>; answer: _Data CorrectPos / CorrectFace.
do
local G = RE4Access.game
G.books_report = function() error("old books reader off") end
local SPOT = { [0] = "left", [1] = "top", [2] = "right", [3] = "bottom" }
local function comp(pos)
    for _, t in ipairs(G.scan_things(pos, 4)) do
        local okn, nm = pcall(function() return t.go:call("get_Name") end)
        if okn and nm and nm:find("gm84_760", 1, true) then
            return t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPuzzleBooks")), t
        end
    end
end
local function state(c)
    local books = c:get_field("_Book"):get_elements()
    local data = c:get_field("_Data"):get_elements()
    local idx, S = {}, { slot = {}, book = {} }
    for i, b in ipairs(books) do
        idx[b:get_address()] = i - 1
        S.book[i - 1] = { name = "Stone " .. string.char(64 + i), face = b:get_field("<IsFace>k__BackingField") == true,
            want = data[i]:get_field("CorrectPos"), wantface = data[i]:get_field("CorrectFace") == true }
    end
    for s, b in ipairs(c:get_field("_PosBook"):get_elements()) do
        if b then S.slot[s - 1] = idx[b:get_address()] S.book[idx[b:get_address()]].at = s - 1 end
    end
    local hb = c:get_field("_HaveBook")
    S.held = hb and idx[hb:get_address()] or nil
    S.mode = c:get_field("_Routine")
    S.cursor = S.held and c:get_field("_CursorMove") or c:get_field("_CursorBook")
    return S
end
G.books_state = state
function G.books_next(S)
    if S.held then
        local b = S.book[S.held]
        local s = "Holding " .. b.name .. ". "
        if b.face ~= b.wantface then s = s .. "Press Q to turn it. Then " end
        return s .. "Take it " .. SPOT[b.want] .. " with the arrows, press F."
    end
    for i = 0, 3 do
        local b = S.book[i]
        if b.at ~= b.want or b.face ~= b.wantface then
            return "Next: " .. b.name .. ", " .. SPOT[b.at or 0] .. ". Arrow there, press F to pick it up."
        end
    end
    return "All stones are right."
end
local W = { sig = nil, t = 0, cur = nil, held = nil }
G.books_gen = (G.books_gen or 0) + 1
local GEN = G.books_gen
do
    re.on_frame(function()
        if G.books_gen ~= GEN then return end
        local now = os.clock()
        if now - W.t < 0.2 then return end
        W.t = now
        local ok, err = pcall(function()
            local pos = G.player_pos()
            if not pos or pos.z > -38 or pos.z < -50 or pos.x < -14 or pos.x > -3 then W.sig = nil return end
            local c = comp(pos)
            if not c then return end
            local S = state(c)
            local parts = { S.mode, S.cursor, S.held or "-" }
            for i = 0, 3 do parts[#parts + 1] = (S.slot[i] or "-") .. (S.book[i].face and "F" or "") end
            local sig = table.concat(parts, ",")
            if sig == W.sig then return end
            local old = W.sig
            W.sig = sig
            log.info("[RE4Access] books2: mode,cursor,held,slots = " .. sig)
            if not old or S.mode ~= 2 then return end
            local msg
            local oldp = {} for v in old:gmatch("[^,]+") do oldp[#oldp + 1] = v end
            if tostring(oldp[3]) ~= tostring(S.held or "-") or oldp[4] ~= parts[4] or oldp[5] ~= parts[5] or oldp[6] ~= parts[6] or oldp[7] ~= parts[7] then
                msg = G.books_next(S)
            else
                local here = S.slot[S.cursor]
                msg = (SPOT[S.cursor] or "?") .. ": " .. (here and S.book[here].name or "empty")
                if S.held then
                    local b = S.book[S.held]
                    if S.cursor == b.want then msg = msg .. ". Right spot for " .. b.name .. (b.face ~= b.wantface and ", press Q first" or "") .. ", press F." end
                end
            end
            RE4Access.speak(msg, true)
        end)
        if not ok then log.info("[RE4Access] books2 error: " .. tostring(err)) end
    end)
end
G.bindery_step_v3 = G.bindery_step_v3 or G.bindery_step
G.bindery_step = function(pos)
    local st = G.bindery_step_v3(pos)
    if st and st.name == "the stone puzzle table" then
        local c = comp(pos)
        if c and c:call("isAllBookPut") then
            local okr, S = pcall(state, c)
            st.tip = "Press F at the table. Arrows move, F picks up and puts down, Q turns. " .. (okr and G.books_next(S) or "")
        end
    end
    return st
end
end
-- 11/9 4:35AM after the stone table: N looped between "the trail" back in the
-- Bindery and the far objective marker (100 m, the wrong way). Real way: west
-- up the ramp, Small Key on the way, through the fallen-shelf gap, south, down
-- the stairs past the Merchant + typewriter, Weighing Weight (gm84_764, F) opens
-- the shutter (gm80_752) to the Battlements (AutoSave at (-27.2,25,-88)).
do
local G = RE4Access.game
local function find(pos, key, r)
    for _, t in ipairs(G.scan_things(pos, r or 80)) do
        local okn, nm = pcall(function() return t.go:call("get_Name") end)
        if okn and nm and nm:find(key, 1, true) then return t end
    end
end
function G.wall_step(pos)
    if not pos or pos.x < -45 or pos.x > 12 or pos.z < -95 or pos.z > -28 or pos.y < 23 or pos.y > 33 then return nil end
    local tbl = find(pos, "gm84_760")
    if tbl and not G.gimmick_done(tbl.go) then return nil end
    if not tbl and pos.z > -60 then return nil end
    local w = find(pos, "gm84_764", 90)
    if not w then return nil end
    local sh = find(pos, "gm80_752", 90)
    if G.gimmick_done(w.go) or (sh and G.gimmick_done(sh.go)) then return nil end
    for _, it in ipairs(G.items(pos, 60)) do
        local nm = tostring(it.name)
        if nm:find("Small Key", 1, true) and not nm:find("needs", 1, true) and math.abs(it.pos.y - pos.y) < 4 then
            return { name = it.name, pos = it.pos, dist = it.dist, tip = "It is on the way. Press F at F ready." }
        end
    end
    -- the two treasures left in the stone room, while you are still in it
    if pos.z > -66 and pos.x > -20 then
        local best
        for _, it in ipairs(G.items(pos, 40)) do
            local nm = tostring(it.name)
            if (nm:find("Brass Pocket Watch", 1, true) or nm:find("Extravagant Clock", 1, true)) and (not best or it.dist < best.dist) then best = it end
        end
        if best then
            local short = best.name:gsub(",.*$", "")
            return { name = "treasure: " .. short, pos = best.pos, dist = best.dist,
                tip = (best.name:find("Pocket Watch", 1, true) and "Your Small Key opens its drawer. Press F at F ready." or "Press F to open the chest, then F to take it.") .. " After the treasures, N goes to the way out." }
        end
    end
    local stand = { x = -29.5, y = 25.0, z = -87.3 }
    local d = math.sqrt((stand.x - pos.x) ^ 2 + (stand.z - pos.z) ^ 2)
    local tip
    if pos.z > -72 then
        tip = "Hold W. West up a ramp, then left through the gap by the fallen shelf, then down some stairs. You pass the Merchant and a typewriter. At the weight press F."
    elseif pos.y > 27 then
        tip = "Hold W. Down the stairs, past the Merchant and a typewriter. At the weight press F."
    else
        tip = "Press F at F ready. It opens the shutter."
    end
    return { name = "the hanging weight that opens the shutter", pos = stand, dist = d, key = w.key, go = w.go, tip = tip }
end
if not G.hole_step_before_wall then G.hole_step_before_wall = G.hole_step end
G.hole_step = function(pos)
    local ok, st = pcall(G.wall_step, pos)
    if ok and st then return st end
    if not ok then log.info("[RE4Access] wall step error: " .. tostring(st)) end
    return G.hole_step_before_wall(pos)
end
end
-- 11/9 4:50AM Ch8 past the weight shutter (Great Wall entrance): N fell back to
-- the far objective marker. Chain (Game8 order): shoot the drawbridge weight
-- (gm84_764 at (4.9,29.2,-114.3), body/BrokenWeight (4.92,26.3,-114.2)) from the
-- bridge's west end -> cross, lever on the lower floor (gm84_778 (13.5,23,-116.1))
-- -> ladder inside the tower (gm91_005 塔A_内部 (18.9,23,-115.8)) -> lever upstairs
-- (gm84_778 (3) (12.4,27,-118.3)), which opens the second gate below.
do
local G = RE4Access.game
local function find_at(name, x, z, r, y)
    for _, t in ipairs(G.scan_things({ x = x, y = y or 25, z = z }, r or 1.5)) do
        local okn, nm = pcall(function() return t.go:call("get_Name") end)
        if okn and nm and nm:find(name, 1, true) then return t end
    end
end
local SPOT = { x = -2.0, y = 23.0, z = -105.0 }
local AIM = { x = 4.92, y = 26.3, z = -114.2, what = "lantern", label = "Counterweight" }
G.bridge = G.bridge or {}
local B = G.bridge
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
function G.bridge_step(pos)
    if not pos or pos.x < -35 or pos.x > 95 or pos.z < -125 or pos.z > 40 or pos.y < 17 or pos.y > 40 then return nil end
    local sh = find_at("gm80_752_00_0_", -27.4, -87.7, 1.5, 25)
    -- (far east the shutter is not loaded: you are long past it)
    if sh and not G.gimmick_done(sh.go) then return nil end
    if not sh and pos.x < 0 then return nil end
    local w = find_at("gm84_764", 4.9, -114.3, 1.5, 29.2)
    if w and not G.gimmick_done(w.go) then
        local t = { name = "the spot to shoot the bridge weight", pos = SPOT, dist = d2(SPOT, pos), key = "ch8_bridge_spot", walk_point = true }
        if d2(SPOT, pos) > 2.5 then
            t.tip = ""
        else
            t.tip = "Hold L, press K."
        end
        B.t = t
        return t
    end
    B.t = nil
    -- 11/9 8:15AM: a healing item lying loose close by on your floor comes first
    -- (user: 'it said a green herb fell but it does not show up').
    for _, it in ipairs(G.items(pos, 15)) do
        local nm = tostring(it.name)
        if not it.inside and math.abs(it.pos.y - pos.y) < 1.5 and (nm:find("Herb", 1, true) or nm:find("First Aid", 1, true)) then
            local c = {} for k, v in pairs(it) do c[k] = v end
            c.tip = "Press F at F ready."
            return c
        end
    end
    -- 11/9 6:45AM below the wall by tower C: the sun shutter (81.5,23,-57.2) blocks
    -- the way north to the cannon; lever (4) at (82.2,23,-81.1) flips it.
    if pos.x > 70 and pos.x < 95 and pos.z > -85 and pos.z < -35 and pos.y < 25.5 then
        local open
        pcall(function()
            for _, t in ipairs(G.scan_things({ x = 81.5, y = 23.0, z = -57.2 }, 0.8)) do
                if t.go:call("get_Name"):find("gm80_756", 1, true) then
                    open = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmShutter")):get_field("_Routine") == 2
                end
            end
        end)
        if open == false then
            local L4 = { x = 82.2, y = 23.0, z = -80.5 }
            local l4 = find_at("gm84_778_00_0_切り替えシャッターレバー(4)", 82.2, -81.1, 0.8, 23)
            return { name = "the lever that opens the way to the cannon", pos = L4, dist = d2(L4, pos), key = l4 and l4.key or "ch8_l4", go = l4 and l4.go, tip = "Press F once." }
        elseif open == true then
            local st = G.cannon_step(pos)
            if st then return st end
            return { name = "Stop here", no_route = true, tip = "Tell Claude you are here." }
        end
    end
    if pos.x > 60 and pos.x < 95 and pos.z > -60 and pos.z < 10 then
        local st = G.cannon_step(pos)
        if st then return st end
    end
    if pos.x > 45 and pos.x < 95 and pos.z >= 0 and pos.z < 40 and pos.y > 23.5 then
        local gate = G.ch8_gate()
        if gate and G.gimmick_done(gate.go) then
            local st = G.ch8_end_step(pos)
            if st then return st end
        end
    end
    -- 11/9 6:05AM past the tower B gate (lock done): up the stairs to the top of
    -- the wall, then east along the wall walk (the Armored Gigante throws rocks),
    -- Green Herb on the way, to the next tower (lever (4) at (82.2,23,-81.1)).
    if pos.x > 44 and pos.x < 95 and pos.z > -125 and pos.z < -60 then
        local lock = find_at("gm84_759", 51.6, -114.0, 0.8, 23)
        if lock and G.gimmick_done(lock.go) then
            if pos.y < 30.5 and pos.x < 56.5 and pos.z < -108 then
                local TOP = { x = 52.0, y = 31.0, z = -115.0 }
                return { name = "the top of the castle wall", pos = TOP, dist = d2(TOP, pos), key = "ch8_walltop", walk_point = true, tip = "" }
            end
            -- 11/9 6:35AM: herb crate dropped (user died there to rocks). Straight on
            -- past the next tower and down off the wall, out of the giant's view.
            local E = { x = 84.0, y = 22.0, z = -69.0 }
            if not (pos.y < 24.5 and pos.z > -72) then
                return { name = "the drop down off the wall", pos = E, dist = d2(E, pos), key = "ch8_walldrop", walk_point = true, tip = "Run, Shift and W." }
            end
            return { name = "Stop here", no_route = true, tip = "Tell Claude you are here." }
        end
    end
    -- 11/9 5:35AM bottom-floor west room (after vaulting down): the way out is a
    -- moon shutter. Every switch lever flips ALL sun/moon shutters, so the truth
    -- is the shutter itself (GmShutter _Routine 2 = open), not F presses.
    if pos.y < 21 and pos.x < 19 and pos.z < -105 then
        local mo = G.moon_open()
        if mo == false then
            local L2 = { x = 6.4, y = 19.0, z = -118.2 }
            local l2 = find_at("gm84_778_00_0_切り替えシャッターレバー(2)", 6.4, -118.2, 0.8, 19)
            return { name = "the lever on the west side", pos = L2, dist = d2(L2, pos), key = l2 and l2.key or "ch8_l2", go = l2 and l2.go,
                tip = "Press F once at F ready." }
        end
    end
    -- moon shutters open: east along the bottom, Ornate Necklace, tower B
    if G.moon_open() == true and pos.y < 25 and pos.x > 0 and pos.z < -105 then
        for _, it in ipairs(G.items(pos, 60)) do
            if tostring(it.name):find("Ornate Necklace", 1, true) then
                -- close by: hand over the game's own item entry, so the usual
                -- chest help runs (face it, HOLD F to open the lid, F to take)
                if it.dist < 6 then
                    local c = {}
                    for k, v in pairs(it) do c[k] = v end
                    c.tip = ""
                    return c
                end
                local CS = { x = 36.8, y = 19.0, z = -115.2 }
                return { name = "treasure: Ornate Necklace, in a chest", pos = CS, dist = d2(CS, pos),
                    tip = "" }
            end
        end
        local lock = find_at("gm84_759", 51.6, -114.0, 0.8, 23)
        if lock and not G.gimmick_done(lock.go) then
            if pos.y < 21.5 then
                local LB = { x = 46.6, y = 19.0, z = -111.0 }
                local ld = find_at("塔B_内部", 46.6, -111.0, 0.8, 19)
                return { name = "the ladder in the second tower", pos = LB, dist = d2(LB, pos), key = ld and ld.key or "ch8_ladderB", go = ld and ld.go,
                    tip = "" }
            end
            -- stand where the game puts a person working the lock (NpcPos), face its icon
            local NP = { x = 51.07, y = 23.0, z = -113.6 }
            return { name = "the gate lock", pos = NP, face = { x = 50.84, y = 24.15, z = -114.30 }, dist = d2(NP, pos), key = lock.key, go = lock.go,
                tip = "" }
        end
        return { name = "Stop here", no_route = true, tip = "Tell Claude you are here." }
    end
    -- fixed points: the tower is not loaded when you are far away
    local L1 = { x = 13.5, y = 23.0, z = -116.1 }
    local LD = { x = 18.9, y = 23.0, z = -115.8 }
    local L3 = { x = 12.4, y = 27.0, z = -118.3 }
    local final, upper
    if not B.l1_done then final, upper = "l1", false
    elseif not B.l3_done then final, upper = "l3", true
    elseif not B.l2_done then final, upper = "l2", false
    else final, upper = "after", false end
    if pos.z > -87 then
        local q = { x = -27.0, y = 25.0, z = -88.0 }
        return { name = "the open shutter", pos = q, dist = d2(q, pos), key = "ch8_wp_shutter", walk_point = true,
            tip = "" }
    end
    if pos.x < 6 then
        local q = { x = 8.0, y = 23.0, z = -110.5 }
        return { name = "the far end of the bridge", pos = q, dist = d2(q, pos), key = "ch8_wp_bridge", walk_point = true,
            tip = "" }
    end
    if final == "l1" then
        local l1 = find_at("gm84_778_00_0_切り替えシャッターレバー", 13.5, -116.1, 0.8, 23)
        return { name = "the lever on the lower floor", pos = L1, dist = d2(L1, pos), key = l1 and l1.key or "ch8_l1", go = l1 and l1.go,
            tip = "Press F once." }
    end
    if upper and not (pos.y > 26 and d2(L3, pos) < 10) then
        local ld = find_at("塔A_内部", 18.9, -115.8, 0.8, 23)
        return { name = "the ladder up in the tower", pos = LD, dist = d2(LD, pos), key = ld and ld.key or "ch8_ladder", go = ld and ld.go,
            tip = "" }
    end
    if final == "l3" then
        local l3 = find_at("gm84_778_00_0_切り替えシャッターレバー(3)", 12.4, -118.3, 0.8, 27)
        return { name = "the lever upstairs", pos = L3, dist = d2(L3, pos), key = l3 and l3.key or "ch8_l3", go = l3 and l3.go,
            tip = "Press F once." }
    end
    if final == "l2" then
        local L2 = { x = 6.4, y = 19.0, z = -118.2 }
        local l2 = find_at("gm84_778_00_0_切り替えシャッターレバー(2)", 6.4, -118.2, 0.8, 19)
        return { name = "the lever on the bottom floor, west side", pos = L2, dist = d2(L2, pos), key = l2 and l2.key or "ch8_l2", go = l2 and l2.go,
            tip = "Press F once." }
    end
    if pos.y < 21 and d2({ x = 6.4, z = -118.2 }, pos) < 4 then
        return { name = "Stop here", no_route = true, tip = "Tell Claude you are here." }
    end
    if d2(L3, pos) > 3 then
        return { name = "the second lever room", pos = L3, dist = d2(L3, pos), key = "ch8_l3_back", walk_point = true,
            tip = "" }
    end
    return { name = "Stop here", no_route = true,
        tip = "Tell Claude you are here." }
end

function G.moon_open()
    local r
    pcall(function()
        for _, t in ipairs(G.scan_things({ x = 15.5, y = 23.0, z = -114.5 }, 0.8)) do
            local n = t.go:call("get_Name")
            if n:find("gm80_754", 1, true) then
                local c = t.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmShutter"))
                r = c:get_field("_Routine") == 2
            end
        end
    end)
    return r
end
-- say it when the sun/moon shutters flip
if not RE4Access.moon_frame then
    RE4Access.moon_frame = true
    local last, at = nil, 0
    re.on_frame(function()
        local now = os.clock()
        if now - at < 0.5 then return end
        at = now
        local pos = G.player_pos()
        if not pos or pos.x < 0 or pos.x > 60 or pos.z > -100 or pos.z < -130 then last = nil return end
        local mo = G.moon_open()
        if mo == nil then return end
        if last ~= nil and mo ~= last then
            log.info("[RE4Access] moon shutters " .. (mo and "open" or "closed"))
            RE4Access.speak(mo and "Lever pulled. Moon shutters open, sun shutters closed. Press N." or "Lever pulled. Sun shutters open, moon shutters closed. Press N.", true)
        end
        last = mo
    end)
end

-- 11/9 5:50AM user: N says too much. N stays short; a few warnings come only
-- when you get to the place they are about.
local HINTS = {
    { x = 31.4, y = 22, z = -121.0, r = 2.5, text = "Lever here. Do not press F on it." },
    { x = 35.5, y = 22, z = -118.0, r = 1.8, text = "Drop down here. Press F if asked." },
    { x = 54.5, y = 31, z = -114.0, r = 2.5, text = "A giant throws rocks from far away. Keep moving, stay close to walls." },
    { x = 84.5, y = 23, z = -77.5, r = 2.5, text = "Crossbow enemies may shoot through the other door. Shoot them first." },
}
if not RE4Access.hint_frame then
    RE4Access.hint_frame = true
    local at = 0
    re.on_frame(function()
        local now = os.clock()
        if now - at < 0.3 then return end
        at = now
        pcall(function()
            local pos = G.player_pos()
            if not pos then return end
            for _, h in ipairs(G.CH8_HINTS or {}) do
                local d = math.sqrt((pos.x - h.x) ^ 2 + (pos.z - h.z) ^ 2)
                if d < h.r and math.abs(pos.y - h.y) < 1.5 then
                    if not h.inside then h.inside = true RE4Access.speak(h.text, true) end
                elseif d > h.r + 2 then h.inside = false end
            end
        end)
    end)
end
G.CH8_HINTS = HINTS
-- L aims at the weight only at the spot with no enemy close on your floor
if not RE4Access.bridge_frame then
    RE4Access.bridge_frame = true
    local told, at = false, 0
    re.on_frame(function()
        local now = os.clock()
        if now - at < 0.2 then return end
        at = now
        pcall(function()
            local t = G.bridge.t
            if not t then return end
            local pos = G.player_pos()
            if not pos then return end
            local safe = d2(SPOT, pos) < 3
            if safe then
                for _, e in ipairs(G.enemies(pos, 8)) do
                    if math.abs(e.pos.y - pos.y) < 1.5 then safe = false break end
                end
            end
            t.shoot = safe and AIM or nil
            if safe and not told then told = true RE4Access.speak("This is the spot. Hold L, it aims at the bridge weight. Press K.", true) end
            if not safe and d2(SPOT, pos) > 5 then told = false end
        end)
    end)
end
-- lever presses: remember them (a pulled switch lever may not report done)
if not RE4Access.bridge_f then
    RE4Access.bridge_f = true
    local was = false
    re.on_frame(function()
        local down = reframework:is_key_down(0x46)
        if down and not was then
            pcall(function()
                local pos = G.player_pos()
                if math.sqrt((pos.x - 13.5) ^ 2 + (pos.z + 116.1) ^ 2) < 2 and math.abs(pos.y - 23) < 1 then if not G.bridge.l1_done then RE4Access.speak("Lever pulled. Do not press F on it again. Press N.", true) end G.bridge.l1_done = true log.info("[RE4Access] bridge: F at lever 1") end
                if math.sqrt((pos.x - 6.4) ^ 2 + (pos.z + 118.2) ^ 2) < 2 and math.abs(pos.y - 19) < 1 then log.info("[RE4Access] bridge: F at lever 2") end
                if math.sqrt((pos.x - 51.6) ^ 2 + (pos.z + 114.0) ^ 2) < 2 and math.abs(pos.y - 23) < 1 then log.info("[RE4Access] bridge: F at gate lock") end
                if math.sqrt((pos.x - 12.4) ^ 2 + (pos.z + 118.3) ^ 2) < 2 and math.abs(pos.y - 27) < 1 then if not G.bridge.l3_done then RE4Access.speak("Lever pulled. Do not press F on it again. Press N.", true) end G.bridge.l3_done = true log.info("[RE4Access] bridge: F at lever 3") end
            end)
        end
        was = down
    end)
end
if not G.hole_step_before_bridge then G.hole_step_before_bridge = G.hole_step end
G.hole_step = function(pos)
    local ok, st = pcall(G.bridge_step, pos)
    if ok and st then return st end
    if not ok then log.info("[RE4Access] bridge step error: " .. tostring(st)) end
    return G.hole_step_before_bridge(pos)
end
end

do
local G = RE4Access.game

-- 11/9 7:00AM Ch8 cannon (Game8: drop the weight to raise the cannon lift one
-- level, ladder to the 2nd floor, up to the cannon, fire at the Armored Gigante).
-- Weights: (83.3,26.8,-45.9) ground floor, (3) (82.7,29.8,-38.2) 2nd floor.
-- Ladder (83.9,23,-41). Cannon gm84_572 on GmCannonLift.
local function wgo(x, y, z)
    for _, t in ipairs(G.scan_things({ x = x, y = y, z = z }, 0.5)) do
        if t.name == "Weighing Weight" then return t end
    end
end
function G.cannon_go3()
    local t
    for _, x in ipairs(G.scan_things({ x = 78.7, y = 26, z = -46.9 }, 8)) do
        if x.go:call("get_Name"):find("gm84_572", 1, true) then t = x end
    end
    return t
end
-- 11/9 9:15AM past the broken gate (Game8: two rooms left, a balcony over the
-- hedge maze, the door at the far end = end of Chapter 8): through the door
-- (86.8,27,15.5), west along the balcony (y 25), slide lock gm84_759 on door
-- 城扉C (58.2,24.9,16.6) worked from NpcPos (58.46,24.92,17.09), then the room
-- with the objective marker (51.8,25,18). Route 68 m checked live.
function G.ch8_end_step(pos)
    local function d(a) return math.sqrt((a.x - pos.x) ^ 2 + (a.z - pos.z) ^ 2) end
    local lock
    for _, t in ipairs(G.scan_things({ x = 58.2, y = 24.9, z = 16.6 }, 0.5)) do
        if t.go:call("get_Name"):find("gm84_759", 1, true) then lock = t end
    end
    if lock and not G.gimmick_done(lock.go) then
        local NP = { x = 58.46, y = 24.92, z = 17.09 }
        return { name = "the door at the end of the balcony", pos = NP, face = { x = 58.16, y = 26.06, z = 17.47 }, dist = d(NP), key = lock.key, go = lock.go,
            latch = true, fname = "Door Lock", spoken = "door lock", after = "Press F to slide the lock.", tip = "" }
    end
    local O = { x = 51.8, y = 25.0, z = 18.0 }
    if d(O) > 2 then
        return { name = "the room past the door", pos = O, dist = d(O), key = "ch8_end", walk_point = true, tip = "That ends Chapter 8." }
    end
end
function G.ch8_gate()
    for _, t in ipairs(G.scan_things({ x = 76.0, y = 27.0, z = 2.8 }, 1.5)) do
        if t.go:call("get_Name"):find("gm82_557", 1, true) then return t end
    end
end
G.cannon_go = G.cannon_go3
G.cannon_go2 = G.cannon_go3
function G.cannon_step(pos)
    local function d(a) return math.sqrt((a.x - pos.x) ^ 2 + (a.z - pos.z) ^ 2) end
    local gate = G.ch8_gate()
    if gate and G.gimmick_done(gate.go) then
        if pos.z < -2 then
            return { name = "the broken gate", pos = { x = 76.0, y = 27.0, z = 1.0 }, dist = d({ x = 76.0, z = 1.0 }), key = "ch8_gate", walk_point = true, tip = "" }
        end
        return G.ch8_end_step(pos)
    end
    local w1 = wgo(83.3, 26.8, -45.9)
    if w1 and not G.gimmick_done(w1.go) then
        local P = { x = 83.42, y = 23.0, z = -46.8 }
        return { name = "the weight that raises the cannon", pos = P, face = { x = 83.42, y = 24.7, z = -46.01 }, dist = d(P), key = w1.key, go = w1.go, tip = "Press F." }
    end
    -- 11/9 7:55AM VERIFIED LIVE (Claude hands-on): weight 1 (F, ground floor)
    -- lifts the cannon to y 27; weight (2) (F, 2nd floor, stand (76.3,27,-51.4))
    -- lifts it to y 31 (top floor); spiral stairs on the east side lead up; the
    -- cannon is taken (HOLD F 1.3 s) from (80.75,31,-43.63). Rocks only reach the
    -- top floor and the stairs: the giant does not throw while you are on the
    -- 2nd floor. Weight (3) is not part of it (unreachable).
    local c0 = G.cannon_go3()
    if c0 and c0.pos.y > 26 and c0.pos.y < 29.5 then
        if pos.y < 25.5 then
            local LD = { x = 83.9, y = 23.0, z = -41.0 }
            local ld
            for _, t in ipairs(G.scan_things({ x = 83.9, y = 23.0, z = -41.0 }, 0.8)) do
                if t.go:call("get_Name"):find("gm91_005", 1, true) then ld = t end
            end
            return { name = "the ladder up", pos = LD, dist = d(LD), key = ld and ld.key or "ch8_ladderD", go = ld and ld.go, tip = "Hold F." }
        end
        local w2 = wgo(77.3, 30.9, -52.3)
        local P = { x = 76.3, y = 27.0, z = -51.4 }
        return { name = "the second weight", pos = P, face = { x = 77.32, y = 28.71, z = -52.36 }, dist = d(P), key = w2 and w2.key or "ch8_w2", go = w2 and w2.go, tip = "Press F." }
    end
    if c0 and c0.pos.y >= 29.5 then
        -- 11/9 8:40AM: JackPos/IconPos are children of the cannon and turn with
        -- it (after the giant shot JackPos moved from (80.37,-44.83) to
        -- (80.97,-48.29)): read them live, stand on the nearest walkable point.
        local jack, icon = { x = 80.37, y = 31.08, z = -44.83 }, nil
        pcall(function()
            local ch = c0.go:call("get_Transform"):call("get_Child")
            while ch do
                local n = ch:call("get_GameObject"):call("get_Name")
                local q = ch:call("get_Position")
                if n == "JackPos" then jack = { x = q.x, y = q.y, z = q.z } end
                if n == "IconPos" then icon = { x = q.x, y = q.y, z = q.z } end
                ch = ch:call("get_Next")
            end
        end)
        local CS
        local R = RE4Access.route
        for _, rr in ipairs({ 0, 0.3, 0.5, 0.7, 0.9 }) do
            for k = 0, (rr == 0 and 0 or 11) do
                local a = k * math.pi / 6
                local q = { x = jack.x + math.sin(a) * rr, y = 31.0, z = jack.z + math.cos(a) * rr }
                local okn, pts = pcall(R.nav_points, pos, q)
                local last = okn and pts and pts[#pts]
                if last and math.sqrt((last.x - q.x) ^ 2 + (last.z - q.z) ^ 2) < 0.2 and math.abs(last.y - 31) < 1 then CS = q break end
            end
            if CS then break end
        end
        CS = CS or { x = jack.x, y = 31.0, z = jack.z }
        -- 11/9 9:05AM: from the south side of the top floor the route to the
        -- default JackPos kept saying Blocked; go round by the east side first.
        if pos.y > 30.5 and pos.z < -46 and jack.z > -46 then
            local WP = { x = 82.6, y = 31.0, z = -44.4 }
            return { name = "the east side of the cannon", pos = WP, dist = d(WP), key = "ch8_cannon_east", walk_point = true, tip = "" }
        end
        local FACE = icon or { x = c0.pos.x, y = 32, z = c0.pos.z }
        if pos.y < 29.5 then
            local SB = { x = 89.3, y = 27.0, z = -46.5 }
            if d(SB) > 2 then
                return { name = "the stairs to the cannon", pos = SB, dist = d(SB), key = "ch8_stairs", walk_point = true, tip = "Safe from rocks down here." }
            end
            return { name = "the cannon, up the stairs", pos = CS, face = FACE, dist = d(CS), key = c0.key, go = c0.go,
                latch = true, fname = "Cannon", spoken = "cannon", after = "HOLD F now.",
                tip = "Rocks only hit up top. Run, Shift and W." }
        end
        -- latch mode: the route stops within 0.45 m of the exact spot and turns
        -- you to the cannon (plain arrival stopped up to 1.3 m off: F never came)
        return { name = "the cannon", pos = CS, face = FACE, dist = d(CS), key = c0.key, go = c0.go,
            latch = true, fname = "Cannon", spoken = "cannon", after = "HOLD F now.", tip = "" }
    end
    local c = G.cannon_go3()
    if c then
        return { name = "the cannon", pos = c.pos, dist = d(c.pos), key = c.key, go = c.go, tip = "Hold F to take it." }
    end
end
-- On the cannon: aim help at the giant (same keys as Chapter 7: Left/Right turn,
-- tap Up/Down, K fires). Straight-line aim at his chest; each shot is logged.
-- the tick is a G function so it can be replaced while the game runs
G.ch8_cs = G.ch8_cs or { on = false, said = 0, last = "", reload = false, hp = nil }
function G.ch8_cannon_tick()
    local cs = G.ch8_cs
            local pos = G.player_pos()
    if not pos or pos.x < 70 or pos.x > 95 or pos.z < -60 or pos.z > -30 then cs.on = false return end
    local cg = G.cannon_go3()
    if not cg then return end
    local c = cg.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmCannonV2"))
    local routine = c:get_field("_Routine")
    if routine == 0 then cs.on = false return end
    if G.is_paused() then return end
    local giant
    for _, e in ipairs(G.enemies(pos, 150)) do
        if e.ctx:get_type_definition():get_name():find("^Ch1f0z0") then giant = e end
    end
    local now = os.clock()
    if not cs.on then
        cs.on, cs.said, cs.last, cs.reload = true, now, "", false
        RE4Access.speak("On the cannon. Left and Right arrows turn. Tap Up and Down. K fires.", true)
        return
    end
    if routine ~= 1 then
        if not cs.reload then
            cs.reload = true
            cs.hp = giant and giant.ctx:call("get_HitPoint"):call("get_CurrentHitPoint")
            log.info("[RE4Access] ch8 cannon fired, giant hp " .. tostring(cs.hp))
            RE4Access.speak("Fired.", true)
        end
        return
    end
    if cs.reload then
        cs.reload = false
        cs.last = ""
        local hp = giant and giant.ctx:call("get_HitPoint"):call("get_CurrentHitPoint")
        log.info("[RE4Access] ch8 cannon ready, giant hp " .. tostring(hp) .. ", gate done " .. tostring(G.ch8_gate() and G.gimmick_done(G.ch8_gate().go)))
        RE4Access.speak((hp and cs.hp and hp < cs.hp) and "Hit! Ready." or "Ready.", true)
    end
    -- target: the giant, then the castle gate (cannon _TargetParam[2]
    -- TargetPos (76.02,30.29,2.19), gate gm82_557 Broken Gate)
    local tx, ty, tz
    if giant then
        tx, ty, tz = giant.pos.x, giant.pos.y + 3.0, giant.pos.z
    else
        local gate = G.ch8_gate()
        if gate and G.gimmick_done(gate.go) then
            if cs.last ~= "gatedone" then cs.last = "gatedone" RE4Access.speak("The gate is broken. Press N.", true) end
            return
        end
        if not cs.gate_said then cs.gate_said = true RE4Access.speak("Now the gate. Follow my calls.", true) end
        tx, ty, tz = 76.02, 30.29, 2.19
    end
    -- the ball flies straight (GimmickSubCannonBallV2 _Speed 50, no
    -- gravity) from the muzzle joint, ~1.5 m above and 2.5 m ahead of the
    -- cannon's base: aim from there (11/9: 4 gate shots passed 3 m high).
    local cp = cg.go:call("get_Transform"):call("get_Position")
    pcall(function() cp = c:get_field("_CannonBall"):get_field("_BaseJoint"):call("get_Position") end)
    local dx, dy, dz = tx - cp.x, ty - cp.y, tz - cp.z
    local want_yaw = math.deg(math.atan(dx, dz))
    local want_pitch = math.deg(math.atan(dy, math.sqrt(dx * dx + dz * dz)))
    local dv = c:call("calcFireDirection")
    local yaw = math.deg(math.atan(dv.x, dv.z))
    local pitch = math.deg(math.asin(dv.y))
    local ey = (yaw - want_yaw + 540) % 360 - 180
    local ep = pitch - want_pitch
    local text
    if math.abs(ey) > 2 then text = (ey > 0 and "Right " or "Left ") .. math.floor(math.abs(ey) + 0.5)
    elseif math.abs(ep) > 2 then text = (ep > 0 and "Down " or "Up ") .. math.floor(math.abs(ep) + 0.5)
    else text = "On target. Press K." end
    if text ~= cs.last and (text == "On target. Press K." or now - cs.said > 0.8) then
        cs.last, cs.said = text, now
        RE4Access.speak(text, true)
        if text == "On target. Press K." then
            log.info(string.format("[RE4Access] ch8 cannon on target yaw %.1f pitch %.1f target (%.0f,%.0f,%.0f)", yaw, pitch, tx, ty, tz))
        end
    end

end
if not RE4Access.ch8_cannon_tick then
    RE4Access.ch8_cannon_tick = true
    local errsaid = 0
    re.on_frame(function()
        local ok, err = pcall(G.ch8_cannon_tick)
        if not ok and os.clock() - errsaid > 5 then errsaid = os.clock() log.info("[RE4Access] ch8 cannon tick error: " .. tostring(err)) end
    end)
end
end
-- 11/9 6:15AM Ch8 wall walk: the Armored Gigante (Ch1f0z0) throws rocks from
-- ~35 m. Recorder: log its motion bank/id changes (to find the throw for a
-- 'Rock coming' warning).
do
local G = RE4Access.game
if not RE4Access.giant_rec then
    RE4Access.giant_rec = true
    local last, at = nil, 0
    local tm = sdk.typeof("via.motion.Motion")
    re.on_frame(function()
        local now = os.clock()
        if now - at < 0.05 then return end
        at = now
        pcall(function()
            local pos = G.player_pos()
            if not pos or pos.x < 30 or pos.z > -40 then return end
            for _, e in ipairs(G.enemies(pos, 90)) do
                if e.ctx:get_type_definition():get_name():find("^Ch1f0z0") then
                    local m = e.ctx:call("get_BodyGameObject"):call("getComponent(System.Type)", tm)
                    local layer = m:call("getLayer", 0)
                    local id = tostring(layer:call("get_MotionBankID")) .. "/" .. tostring(layer:call("get_MotionID"))
                    if id ~= last then
                        last = id
                        log.info(string.format("[RE4Access] giant motion %s d=%.0f at (%.0f,%.0f,%.0f)", id, e.dist, e.pos.x, e.pos.y, e.pos.z))
                    end
                    return
                end
            end
        end)
    end)
end
end
-- 11/9 6:25AM Armored Gigante rocks: motion 5/3005 starts the throw, the rock
-- lands ~7.0 s later (2 of 2 in the 05:21-05:22 log). Warn at the start and
-- again just before it lands.
do
local G = RE4Access.game
if not RE4Access.rock_warn then
    RE4Access.rock_warn = true
    local last, t0, said2, at = nil, nil, false, 0
    local tm = sdk.typeof("via.motion.Motion")
    re.on_frame(function()
        local now = os.clock()
        if now - at < 0.05 then return end
        at = now
        pcall(function()
            if G.is_paused and G.is_paused() then return end
            local pos = G.player_pos()
            if not pos or pos.x < 30 or pos.z > -40 then return end
            for _, e in ipairs(G.enemies(pos, 90)) do
                if e.ctx:get_type_definition():get_name():find("^Ch1f0z0") then
                    local layer = e.ctx:call("get_BodyGameObject"):call("getComponent(System.Type)", tm):call("getLayer", 0)
                    local id = tostring(layer:call("get_MotionBankID")) .. "/" .. tostring(layer:call("get_MotionID"))
                    if id ~= last then
                        if id == "5/3005" then t0, said2 = now, false RE4Access.speak("Rock coming.", true) end
                        last = id
                    end
                    if t0 and not said2 and now - t0 > 4.6 then
                        said2 = true
                        RE4Access.speak("Rock! Run!", true)
                    end
                    if t0 and now - t0 > 9 then t0 = nil end
                    return
                end
            end
        end)
    end)
end
-- Space near an item in a breakable crate (no enemy close): turn to it first
if not RE4Access.crate_face then
    RE4Access.crate_face = true
    local was = false
    re.on_frame(function()
        local down = reframework:is_key_down(0x20)
        if down and not was then
            pcall(function()
                local pos = G.player_pos()
                for _, e in ipairs(G.enemies(pos, 4)) do if math.abs(e.pos.y - pos.y) < 1.5 then return end end
                local best
                for _, it in ipairs(G.items(pos, 2.5)) do
                    if it.inside and (not best or it.dist < best.dist) then best = it end
                end
                if best then G.face_item(best.pos) log.info("[RE4Access] knife: turned to " .. tostring(best.name)) end
            end)
        end
        was = down
    end)
end
end
-- 11/9 9:45AM Chapter 9 start, the hedge maze ("Head for the ballroom"; Game8 order:
-- Ashley holds a lever, then three flag levers (GmFlagLever 旗揚げ台 上/真ん中/下),
-- then the door the three flags open (gm80_549), stairs into the castle, Merchant).
-- N goes by the live state: the First Aid Spray first (no heals left), then the
-- nearest flag lever you can walk to, else Ashley's lever, then the flag door.
do
local G = RE4Access.game
local FLAGS = {
    { key = "旗揚げ台_上", name = "the first flag lever", x = 57.66, y = 24.4, z = 36.60, icon = { x = 57.66, y = 25.98, z = 36.60 } },
    { key = "旗揚げ台_真ん中", name = "the middle flag lever", x = 61.92, y = 24.4, z = 42.76, icon = { x = 61.92, y = 25.98, z = 42.76 } },
    { key = "旗揚げ台_下", name = "the far flag lever", x = 87.76, y = 24.4, z = 55.38, icon = { x = 87.76, y = 25.98, z = 55.38 } },
}
local function find(name, x, y, z, r)
    for _, t in ipairs(G.scan_things({ x = x, y = y, z = z }, r or 0.8)) do
        local ok, n = pcall(function() return t.go:call("get_Name") end)
        if ok and n and n:find(name, 1, true) then return t end
    end
end
local function reach(pos, x, y, z)
    local R = RE4Access.route
    local best, bl
    for _, rr in ipairs({ 0.7, 1.0, 1.3 }) do
        for k = 0, 11 do
            local a = k * math.pi / 6
            local q = { x = x + math.sin(a) * rr, y = y, z = z + math.cos(a) * rr }
            local ok, pts = pcall(R.nav_points, pos, q)
            local e = ok and pts and pts[#pts]
            if e and math.sqrt((e.x - q.x) ^ 2 + (e.z - q.z) ^ 2) < 0.25 and math.abs(e.y - y) < 1 then
                local L = 0
                for i = 2, #pts do L = L + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].z - pts[i - 1].z) ^ 2) end
                if not bl or L < bl then best, bl = q, L end
            end
        end
        if best then return best, bl end
    end
end
G.ch9 = G.ch9 or { pulled = {} }
-- 11/11 live map (nav checked, not walked): middle + far flag levers reachable at start;
-- the first (top) flag lever only from north of Ashley's gate gm80_566 (53.2,55.2),
-- which her lever gm84_646 opens. Flag door gm80_549 is entered from its WEST side
-- (74.2,24.1,40.5) and leads east to the castle gate gm80_532 (88.7,24.1,40.3);
-- past it the slide-lock door (108.5,24.2,36) (castle not loaded at map time).
function G.ch9_step(pos)
    if not pos or pos.x < 10 or pos.x > 150 or pos.z < 5 or pos.z > 100 or pos.y < 18 or pos.y > 36 then return nil end
    local ot = tostring(G.objective_text and G.objective_text() or "")
    if not ot:lower():find("ballroom", 1, true) then return nil end
    local function d(a) return math.sqrt((a.x - pos.x) ^ 2 + (a.z - pos.z) ^ 2) end
    -- past the flag door: castle gate, then the slide-lock door
    if pos.y > 23 and ((pos.x > 76.2 and (pos.x > 90 or (pos.z > 30 and pos.z < 50))) or (pos.y > 25.5 and pos.z > 55)) then
        if pos.x < 87.5 and pos.z < 55 then
            -- GmBigDoor gm80_532: Push trigger, HOLD F 1 s, from close up facing east
            local gd = find("gm80_532", 88.69, 24.08, 40.35)
            return { name = "the castle gate", pos = { x = 88.0, y = 24.1, z = 40.35 }, face = { x = 88.69, y = 25.08, z = 40.35 }, dist = d({ x = 88.0, z = 40.35 }),
                key = gd and gd.key, go = gd and gd.go, latch = true, fname = "Gate", spoken = "gate", after = "Hold F.", tip = "" }
        end
        -- 11/11 live: the slide-lock door (108.5,36) has its lock on the FAR side (NpcPos z35.75):
        -- a shortcut, not the way. Way on: hallway east, up to y27.4, door gm80_642(4) (131,27.2,32.5).
        -- Ballroom objective ~ (184.7,26.3,56.2): go straight there once the game has a route.
        local o = G.objective_pos and G.objective_pos()
        if o then
            local ok, pts = pcall(RE4Access.route.nav_points, pos, o)
            local e = ok and pts and pts[#pts]
            if e and math.sqrt((e.x - o.x) ^ 2 + (e.z - o.z) ^ 2) < 2 then
                return { name = "the ballroom", pos = o, dist = d(o), tip = "" }
            end
        end
        if pos.x < 95 and pos.z < 55 then
            return { name = "past the gate", pos = { x = 95, y = 24.1, z = 40 }, dist = d({ x = 95, z = 40 }), tip = "" }
        end
        -- 11/11: a cult leader alive nearby comes first: N walks to a spot on Leon's
        -- floor with a clear shot at him (north wing: balcony leader (83.4,30.3,82.5)).
        do
            local okl, s = pcall(G.summoner, pos, 45)
            if okl and s then
                local tgt = { x = s.pos.x, y = s.pos.y + 1.3, z = s.pos.z }
                local function clear(q)
                    local eye = { x = q.x, y = q.y + 1.4, z = q.z }
                    local _, dd = G.clear_shot(eye, tgt)
                    local full = math.sqrt((tgt.x - eye.x) ^ 2 + (tgt.y - eye.y) ^ 2 + (tgt.z - eye.z) ^ 2)
                    return not dd or dd > full - 0.7
                end
                local best, bd
                if clear(pos) then best, bd = pos, 0 end
                if not best then
                    for r = 8, 17, 3 do
                        for a = 0, 345, 15 do
                            local q = { x = s.pos.x + math.sin(math.rad(a)) * r, y = pos.y, z = s.pos.z + math.cos(math.rad(a)) * r }
                            local ok, pts = pcall(RE4Access.route.nav_points, pos, q)
                            local e = ok and pts and pts[#pts]
                            if e and math.sqrt((e.x - q.x) ^ 2 + (e.z - q.z) ^ 2) < 0.6 and math.abs(e.y - pos.y) < 1 and clear(e) then
                                local dd2 = d(e)
                                if not bd or dd2 < bd then best, bd = e, dd2 end
                            end
                        end
                    end
                end
                if best then
                    return { name = "a spot to shoot the cult leader", pos = { x = best.x, y = best.y, z = best.z }, face = tgt, dist = bd,
                        latch = true, fname = "Leader", spoken = "leader", after = "Hold L. When I say On the leader, K, K, K.", tip = "" }
                end
                return { name = "Stop here", no_route = true, tip = "Kill the cult leader first. He is " .. math.floor(s.dist + 0.5) .. " meters away. Hold L when you hear the bell." }
            end
        end
        -- 11/11: heads for the Chimera statue gm84_642 (3 slots). Serpent from the dining chairs,
        -- Goat Head lies upstairs north (97.0,32.7,93.4; floor y31.7, via door (5) upstairs), Lion not found yet.
        local case6 = find("gm84_699", 143.8, 27.3, 26.6, 1.0)
        -- remembered: the dining hall unloads when you are far away (11/11 after death N fell back to the dining door)
        if case6 and G.gimmick_done(case6.go) and not G.ch9.serpent then
            G.ch9.serpent = true
            pcall(fs.write, "REAccess_ch9state.txt", "serpent")
        end
        if G.ch9.serpent == nil then G.ch9.serpent = (fs.read("REAccess_ch9state.txt") or ""):find("serpent", 1, true) ~= nil end
        if G.ch9.serpent then
            local inv = {}
            pcall(function()
                local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
                local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
                local lst = G.leon_inv():call("getInventoryItemList()")
                for i = 0, lst:call("get_Count") - 1 do
                    local item = lst:call("get_Item", i):get_field("<Item>k__BackingField")
                    if item then inv[tostring(mg:call(nil, mm:call("getItemNameMsgId", item:get_field("_ItemId"))))] = true end
                end
            end)
            -- 11/11: the heads go in the KEY ITEMS list (KeyItemInventoryController), not the case
            pcall(function()
                local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
                local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
                local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
                for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
                    local c = e:get_field("value")
                    if c and c:get_type_definition():get_full_name() == "chainsaw.KeyItemInventoryController" then
                        local items = c:call("getInventoryItems")
                        for i = 0, items:call("get_Count") - 1 do
                            local it = items:call("get_Item", i):get_field("<Item>k__BackingField")
                            if it then inv[tostring(mg:call(nil, mm:call("getItemNameMsgId", it:get_field("_ItemId"))))] = true end
                        end
                    end
                end
            end)
            local function has(w) for k in pairs(inv) do if k:find(w, 1, true) then return true end end end
            local held_head = has("Serpent Head") or has("Goat Head") or has("Lion Head")
            local loose
            for _, it in ipairs(G.items(pos, 200)) do
                local nm = tostring(it.name)
                if nm:find("Head", 1, true) and not it.inside and not (math.abs(it.pos.x - 143.8) < 1.5 and math.abs(it.pos.z - 26.6) < 1.5) then loose = it end
            end
            if held_head then
                return { name = "the statue in the hall", pos = { x = 131.4, y = 27.3, z = 39.4 }, face = { x = 132.3, y = 27.9, z = 40.4 },
                    dist = d({ x = 131.4, z = 39.4 }), latch = true, fname = "Statue", spoken = "statue", after = "Press F.", tip = "" }
            end
            -- 11/11 live: the Goat Head (97,32.7,93.4) is at the end of the east walkway (x96.8, y30.4).
            -- From the west balcony (y30.3): ladder down (74.51, top y30.26, stand north of it),
            -- stairs up on the south side (82.7,27.5,64.1 -> 88,30.5,64.1), walkway north.
            -- 11/11 live: the east walkway is a RISING BRIDGE (gm84_649 GmShiftStage), floor y27.29 when down,
            -- entrance fence at (96.7,65.6). Its lever gm84_781 GmSwitchRiseLever is on the WEST balcony
            -- (93.37,30.26,81.86), stand StartPos (91.18,30.26,84.74). Balcony only by the ladder (74.51,73.15).
            local bridge_down = false
            if loose and loose.pos.x > 95 and loose.pos.z > 88 and pos.z > 55 then
                pcall(function()
                    local h = RE4Access.route.cast(96.8, 34, 76, 96.8, 22, 76)
                    bridge_down = h and h.y < 28.5
                end)
            end
            if bridge_down then
                if pos.y > 29.5 and pos.x < 95.5 and pos.z > 66 then
                    return { name = "the bridge lever", pos = { x = 92.45, y = 30.26, z = 81.86 }, face = { x = 93.37, y = 31.26, z = 81.86 },
                        dist = d({ x = 92.45, z = 81.86 }), latch = true, fname = "Lever", spoken = "lever",
                        after = "Hold F. It raises the bridge to the Goat Head.", tip = "" }
                end
                return { name = "the ladder up to the balcony", pos = { x = 74.51, y = 27.26, z = 72.45 }, face = { x = 74.51, y = 28.3, z = 73.15 },
                    dist = d({ x = 74.51, z = 72.45 }), latch = true, fname = "Ladder", spoken = "ladder",
                    after = "Hold F to climb up. Then N.", tip = "The bridge to the Goat Head is down. Its lever is on the balcony." }
            end
            if loose and loose.pos.x > 95 and loose.pos.z > 88 and pos.z > 55 then
                if pos.y > 29.5 and pos.x < 95.5 and pos.z > 66 then
                    return { name = "the ladder down", pos = { x = 74.51, y = 30.26, z = 73.85 }, face = { x = 74.51, y = 30.26, z = 72.5 },
                        dist = d({ x = 74.51, z = 73.85 }), latch = true, fname = "Ladder", spoken = "ladder", after = "Press F to climb down.", tip = "" }
                end
                -- 11/11: on the stairs (y 28.5-30) N fell through to a route via the ladder back up
                if pos.y < 29 and pos.z > 66 then
                    return { name = "the stairs up", walk_point = true, pos = { x = 89.0, y = 30.4, z = 64.2 }, dist = d({ x = 89.0, z = 64.2 }), tip = "" }
                end
                if pos.z <= 66 or (pos.y < 29.5 and pos.x > 80) then
                    if pos.x < 86 and pos.y < 29.5 then
                        return { name = "the stairs up", walk_point = true, pos = { x = 89.0, y = 30.4, z = 64.2 }, dist = d({ x = 89.0, z = 64.2 }), tip = "" }
                    end
                    return { name = "the walkway north", walk_point = true, pos = { x = 96.8, y = 30.4, z = 72 }, dist = d({ x = 96.8, z = 72 }), tip = "" }
                end
                if pos.x < 95.5 then
                    return { name = "the ladder down", pos = { x = 74.51, y = 30.26, z = 73.85 }, face = { x = 74.51, y = 30.26, z = 72.5 },
                        dist = d({ x = 74.51, z = 73.85 }), latch = true, fname = "Ladder", spoken = "ladder", after = "Press F to climb down.", tip = "" }
                end
            end
            if loose then
                local fy = loose.pos.y - 1.0
                local st = reach(pos, loose.pos.x, fy, loose.pos.z) or { x = loose.pos.x, y = fy, z = loose.pos.z - 0.7 }
                return { name = tostring(loose.name), pos = st, face = loose.pos, dist = d(st), latch = true,
                    fname = tostring(loose.name), spoken = "head", after = "Press F.", tip = "Doors: hold W into them." }
            end
            -- 11/11 user was told the Lion Head is in the room by the rat (south, past the slide-lock
            -- door (108.5,36) whose lock is on the far side). Way in: upstairs door (2) gm80_642 (105.5,30.2,32.4),
            -- then south. Any Head item that loads is picked up by the 'loose' check above.
            if pos.z > 31.2 then
                return { name = "the upstairs door to the south rooms", walk_point = true, pos = { x = 105.5, y = 30.25, z = 31.0 },
                    dist = d({ x = 105.5, z = 31.0 }), tip = "Upstairs. Hold W into the door." }
            end
            return { name = "Stop here", no_route = true, tip = "The Lion Head is not loaded yet. Walk on south through these rooms, then press N again. Or tell Claude." }
        end
        -- 11/11 live (Claude hands-on): castle doors open by HOLDING W into them (OpenSideAStick), F does nothing.
        -- Dining hall past door (4): chair puzzle GmPuzzleChair2Control, correct chairs = (6) (142.60,18.26)
        -- for Ashley (OrderNpc = Left Ctrl hold) and (4) (139.31,11.26) for Leon (Sit F, Ring F).
        -- Solved -> Serpent head in case gm84_699 (143.8,27.3,26.6) -> Chimera statue gm84_642 (132.3,27.5,40.4).
        if pos.y > 26.5 and pos.x > 126 and pos.z < 32.4 then
            local case = find("gm84_699", 143.8, 27.3, 26.6, 1.0)
            local solved = case and G.gimmick_done(case.go)
            if not solved then
                local a
                pcall(function() a = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPartnerContextRef"):call("get_Position") end)
                local seated = a and math.sqrt((a.x - 142.6) ^ 2 + (a.z - 18.26) ^ 2) < 1.0
                local near_a = a and math.sqrt((a.x - 142.75) ^ 2 + (a.z - 19.2) ^ 2) < 3
                if not seated and pos and math.sqrt((pos.x - 142.75) ^ 2 + (pos.z - 19.2) ^ 2) < 1 and not near_a then
                    return { name = "Stop here", no_route = true, tip = "Wait for Ashley to come close." }
                end
                if not seated then
                    return { name = "Ashley's chair", pos = { x = 142.75, y = 27.27, z = 19.2 }, face = { x = 142.6, y = 27.77, z = 18.26 },
                        dist = d({ x = 142.75, z = 19.2 }), latch = true, fname = "Chair", spoken = "chair",
                        after = "Wait for F ready. Then hold Left Control until Ashley answers.", tip = "" }
                end
                return { name = "your chair", pos = { x = 139.45, y = 27.27, z = 10.3 }, face = { x = 139.31, y = 27.77, z = 11.26 },
                    dist = d({ x = 139.45, z = 10.3 }), latch = true, fname = "Chair", spoken = "chair",
                    after = "Wait for F ready. Press F to sit. Then F to ring.", tip = "" }
            end
            for _, it in ipairs(G.items(pos, 40)) do
                if it.pos and math.sqrt((it.pos.x - 143.8) ^ 2 + (it.pos.z - 26.6) ^ 2) < 1.5 then
                    -- the head sits 1.3 m up on the case; the case is used from its front (south, z 25.4)
                    return { name = tostring(it.name), pos = { x = 143.78, y = 27.27, z = 25.45 }, face = it.pos,
                        dist = d({ x = 143.78, z = 25.45 }), latch = true, fname = tostring(it.name), spoken = "head",
                        after = "Press F.", tip = "" }
                end
            end
            return { name = "the statue in the hall", pos = { x = 131.4, y = 27.3, z = 39.4 }, face = { x = 132.3, y = 27.9, z = 40.4 },
                dist = d({ x = 131.4, z = 39.4 }), latch = true, fname = "Statue", spoken = "statue", after = "Press F.", tip = "" }
        end
        if not (pos.y > 26.5 and pos.x > 126 and pos.z < 33) then
            local dr = find("城扉C", 131.0, 27.2, 32.5, 1.0)
            -- door middle (IconPos) is x131.9, plane z32.5: stand in front of the middle, face south
            return { name = "the door at the end of the hall", pos = { x = 131.9, y = 27.25, z = 33.3 }, face = { x = 131.91, y = 28.23, z = 32.5 },
                dist = d({ x = 131.9, z = 33.3 }), key = dr and dr.key, go = dr and dr.go, latch = true, fname = "Door", spoken = "door", after = "Hold W into it.", tip = "" }
        end
        return { name = "Stop here", no_route = true, tip = "End of my map. Tell Claude." }
    end
    -- healing first
    for _, it in ipairs(G.items(pos, 120)) do
        local nm = tostring(it.name)
        if nm:find("First Aid", 1, true) and not it.inside then
            local ok, pts = pcall(RE4Access.route.nav_points, pos, { x = it.pos.x, y = it.pos.y - 0.7, z = it.pos.z })
            if ok and pts and #pts > 0 then
                local c = {} for k, v in pairs(it) do c[k] = v end
                if it.dist > 3 then c.pos = pts[#pts] end
                c.tip = "Press F at F ready."
                return c
            end
        end
    end
    local door = find("gm80_549", 75.4, 24.1, 40.5)
    local left = 0
    local cand
    local top_left = false
    for _, f in ipairs(FLAGS) do
        local t = find(f.key, f.x, f.y, f.z)
        if t and not G.gimmick_done(t.go) and not G.ch9.pulled[f.key] then
            left = left + 1
            if f.key:find("上", 1, true) then top_left = true end
            local st, L = reach(pos, f.x, f.y, f.z)
            if st and (not cand or L < cand.L) then cand = { f = f, t = t, st = st, L = L } end
        end
    end
    if cand then
        return { name = cand.f.name, pos = cand.st, face = cand.f.icon, dist = d(cand.st), key = cand.t.key, go = cand.t.go,
            latch = true, fname = "Flag lever", spoken = "flag lever", after = "Press F.",
            tip = left .. (left == 1 and " flag left." or " flags left.") }
    end
    if left > 0 then
        local lv = find("gm84_646", 48.7, 21.0, 52.4)
        local lever_done = false
        -- 11/11: GmLeverKeep _User = whoever holds it now (F must be HELD 0.5 s; a tap does nothing)
        pcall(function()
            local c = lv.go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmLeverKeep"))
            -- Ashley (not Leon) holds it: someone on it and Ashley at her lever spot (48.12,52.42)
            if c:get_field("_User") ~= nil then
                local a = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPartnerContextRef"):call("get_Position")
                lever_done = math.sqrt((a.x - 48.12) ^ 2 + (a.z - 52.42) ^ 2) < 1.2
            end
        end)
        -- ordered = Ctrl HELD (tap does nothing) and Ashley still by her lever spot (not following Leon)
        local ordered = false
        if G.ch9.ordered_hold and os.clock() - G.ch9.ordered_hold < 90 then
            pcall(function()
                local a = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPartnerContextRef"):call("get_Position")
                ordered = math.sqrt((a.x - 48.12) ^ 2 + (a.z - 52.42) ^ 2) < 2.5
            end)
        end
        if top_left and (lever_done or ordered) then
            -- Ashley holds the gate open: walk through it, north
            if pos.z < 55.6 then
                return { name = "the gate", pos = { x = 53.2, y = 21.0, z = 54.3 }, face = { x = 53.2, y = 21.5, z = 57.0 }, dist = d({ x = 53.2, z = 54.3 }),
                    latch = true, no_f = true, fname = "Gate", spoken = "gate",
                    after = "Wait for the gate. Then W.",
                    tip = "" }
            end
            return { name = "Stop here", no_route = true, tip = "Through the gate. Walk forward, then press N again." }
        end
        if lv and not lever_done then
            -- 11/14 replay: Leon stood ON Ashley's lever spot (48.12,52.42) - she answered the
            -- order but stopped beside him and never took the lever (as on 11/11). Leon now waits
            -- 1 m south of her spot, the only free floor there (48.3,21.0,51.3).
            local st = { x = 48.3, y = 21.0, z = 51.3 }
            return { name = "the spot beside Ashley's lever", pos = st, face = { x = 48.7, y = 22.0, z = 52.4 }, dist = d(st), key = lv.key,
                latch = true, no_f = true, fname = "Lever", spoken = "lever", after = "Do not press F. Hold Left Control for 1 second, until Ashley answers. She walks to the lever and holds it. Then press N.",
                tip = "Ashley holds this lever, not you. Stand beside it, not on her spot." }
        end
        return { name = "Stop here", no_route = true, tip = left .. " flags left, no way found. Tell Claude." }
    end
    if door and not G.gimmick_done(door.go) then
        local st = reach(pos, 74.2, 24.1, 40.5)
        if st then return { name = "the door the flags opened", pos = st, face = { x = 75.4, y = 25.1, z = 40.5 }, dist = d(st), key = door.key, go = door.go,
            tip = "Go through it, east." } end
    end
    local st = reach(pos, 77.4, 24.1, 40.5)
    if st then return { name = "through the flag door", pos = st, dist = d(st), tip = "" } end
    return { name = "Stop here", no_route = true, tip = "The flags are done. Tell Claude." }
end
-- the Ashley gate has no F: no F-angle search there
if not G.want_f_before_ch9gate and G.want_f then
    G.want_f_before_ch9gate = G.want_f
    G.want_f = function(o)
        if o and o.pos and math.abs(o.pos.x - 53.2) < 0.05 and math.abs(o.pos.z - 57.0) < 0.05 then return end
        if o and o.name == "Leader" then return end
        return G.want_f_before_ch9gate(o)
    end
end
-- remember Ashley ordered to the lever (game key Command Ashley = Left Ctrl, hold 1 s)
if not RE4Access.ch9_ctrl then
    RE4Access.ch9_ctrl = true
    local since
    re.on_frame(function()
        if reframework:is_key_down(0xA2) then
            since = since or os.clock()
            if os.clock() - since > 0.8 then
                pcall(function()
                    local pos = G.player_pos()
                    if math.sqrt((pos.x - 48.7) ^ 2 + (pos.z - 52.4) ^ 2) < 4 and math.abs(pos.y - 21) < 1 and not G.ch9.ordered_now then
                        G.ch9.ordered_hold = os.clock()
                        log.info("[RE4Access] ch9 Ashley ordered to lever")
                    end
                end)
                G.ch9.ordered_now = true
            end
        else since = nil; G.ch9.ordered_now = nil end
    end)
end
-- remember Ashley's lever pressed
if not RE4Access.ch9_lever_f then
    RE4Access.ch9_lever_f = true
    local was = false
    re.on_frame(function()
        local down = reframework:is_key_down(0x46)
        if down and not was then
            pcall(function()
                local pos = G.player_pos()
                if math.sqrt((pos.x - 48.7) ^ 2 + (pos.z - 52.4) ^ 2) < 1.8 and math.abs(pos.y - 21) < 1 and G.prompt_active() then
                    G.ch9.lever = true
                    log.info("[RE4Access] ch9 Ashley lever F")
                end
            end)
        end
        was = down
    end)
end
-- remember a flag lever pressed (in case the game's done flag does not change)
if not RE4Access.ch9_f then
    RE4Access.ch9_f = true
    local was = false
    re.on_frame(function()
        local down = reframework:is_key_down(0x46)
        if down and not was then
            pcall(function()
                local pos = G.player_pos()
                for _, f in ipairs(FLAGS) do
                    if math.sqrt((pos.x - f.x) ^ 2 + (pos.z - f.z) ^ 2) < 1.6 and math.abs(pos.y - f.y) < 1 and G.prompt_active() then
                        G.ch9.pulled[f.key] = true
                        log.info("[RE4Access] ch9 flag lever F: " .. f.key)
                    end
                end
            end)
        end
        was = down
    end)
end
if not G.hole_step_before_ch9 then G.hole_step_before_ch9 = G.hole_step end
G.hole_step = function(pos)
    local ok, st = pcall(G.ch9_step, pos)
    if ok and st then return st end
    if not ok then log.info("[RE4Access] ch9 step error: " .. tostring(st)) end
    return G.hole_step_before_ch9(pos)
end
end
-- 11/11 maze ladders DOWN: the game offers "climb down" only standing at the ladder top
-- facing the drop. When N's next place is down in the maze and Leon is up on the hedge
-- walkway, N goes to the nearest ladder top first (latch, face the ladder).
do
local G = RE4Access.game
local LADDERS = {
    { stand = { x = 86.74, y = 24.45, z = 54.40 }, face = { x = 86.74, y = 24.45, z = 53.00 } },
    { stand = { x = 62.90, y = 24.45, z = 43.77 }, face = { x = 64.30, y = 24.45, z = 43.77 } },
}
if not G.ch9_step_before_ladder then G.ch9_step_before_ladder = G.ch9_step end
G.ch9_step = function(pos)
    local st = G.ch9_step_before_ladder(pos)
    if not st or not st.pos or not pos or pos.y < 23.5 or st.pos.y > 23 or pos.x > 95 then return st end
    local best, bd
    for _, l in ipairs(LADDERS) do
        local d = math.sqrt((l.stand.x - pos.x) ^ 2 + (l.stand.z - pos.z) ^ 2)
        if not bd or d < bd then best, bd = l, d end
    end
    if not best or bd > 45 then return st end
    return { name = "the ladder down", pos = best.stand, face = best.face, dist = bd, latch = true,
        fname = "Ladder", spoken = "ladder", after = "Press F to climb down.", tip = "" }
end
end

-- 11/14 Knights' Hall (after the Lion Head armor fight): Ashley waits up on the ledge
-- (116.6,28.1,8.6) and calls "Leon!" until he stands under her and catches her: gimmick
-- gm91_007_00_2c_姫キャッチ_騎士の間 (chainsaw.GmCoopMoveUp) at (117.2,24.1,8.6). The
-- route to the statue failed because the hall's shutter (gm80_550, 122.4,24.1,16.6) stays
-- shut until then. Any undone "姫キャッチ" (catch Ashley) gimmick within 40 m with Ashley
-- 2 m or more above it comes first in N.
do
local G = RE4Access.game
local function catch_target(pos)
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    if not gm or not pos then return nil end
    local a = RE4Access.ashley and RE4Access.ashley.partner and RE4Access.ashley.partner()
    if not a then return nil end
    local ap = a:call("get_Position")
    local best, bd
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            if not go:call("get_Name"):find("姫キャッチ", 1, true) then return end
            if G.gimmick_done and G.gimmick_done(go) then return end
            local q = go:call("get_Transform"):call("get_Position")
            local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
            local ad = math.sqrt((q.x - ap.x) ^ 2 + (q.z - ap.z) ^ 2)
            if d < 40 and ap.y - q.y > 2 and ad < 4 and (not bd or d < bd) then best, bd = { x = q.x, y = q.y, z = q.z }, d end
        end) end
    end
    if not best then return nil end
    return { name = "the spot under Ashley", pos = best, face = { x = ap.x, y = best.y, z = ap.z }, dist = bd, latch = true,
        fname = "Catch", spoken = "catch",
        after = "Ashley is on the ledge above you, waiting to jump down. When I say F ready, press F to catch her. Then press N.",
        tip = "Ashley calls your name because she is waiting for you to catch her." }
end
G.ch9_catch_target = catch_target
if not G.ch9_step_before_catch then G.ch9_step_before_catch = G.ch9_step end
G.ch9_step = function(pos)
    local ok, t = pcall(G.ch9_catch_target, pos)
    if ok and t then return t end
    return G.ch9_step_before_catch(pos)
end
end

-- 11/14 Knights' Hall exit: the shutter gm80_550 (122.4,24.1,16.6) is blocked by the Centaur
-- statue gm84_676 (chainsaw.GmDoubleInteract, Leon + Ashley move it together). Its children
-- "Left" (124.17,24.10,15.52) and "Right" (120.89,24.10,15.52) are the two stand spots.
-- Generic: any undone GmDoubleInteract within 25 m (Ashley along) comes first in N: walk to the
-- floor next to the nearer reachable stand spot, face the statue, press F.
do
local G = RE4Access.game
local function double_target(pos)
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    local R = RE4Access.route
    if not gm or not pos or not R then return nil end
    -- 11/14 PM replay: before the Lion Head, Ashley stands up on the Knights' Hall ledge
    -- (y 28.1) and this step hid the Lion Head step. Only with Ashley near, same floor.
    local near = false
    pcall(function()
        local a = RE4Access.ashley.partner():call("get_Position")
        near = math.abs(a.y - pos.y) < 1.5 and math.sqrt((a.x - pos.x) ^ 2 + (a.z - pos.z) ^ 2) < 8
    end)
    if not near then return nil end
    local best, bd
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            if not go:call("get_DrawSelf") then return end
            local di = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmDoubleInteract"))
            if not di then return end
            if G.gimmick_done and G.gimmick_done(go) then return end
            local c = go:call("get_Transform"):call("get_Position")
            if math.sqrt((c.x - pos.x) ^ 2 + (c.z - pos.z) ^ 2) > 25 then return end
            local ch = go:call("get_Transform"):call("get_Child")
            while ch do
                local nm = ch:call("get_GameObject"):call("get_Name")
                if nm == "Left" or nm == "Right" then
                    local q = ch:call("get_Position")
                    -- the stand spot itself is off the walking map (statue footprint): take
                    -- the nearest reachable floor within 1.4 m of it (R.reach_spot)
                    local e2
                    for _, r in ipairs({ 0, 0.8, 1.1, 1.4 }) do
                        for k = 0, (r == 0 and 0 or 7) do
                            local an = k * math.pi / 4
                            local okn, pts, tot = pcall(R.nav_points, pos, { x = q.x + math.sin(an) * r, y = q.y, z = q.z + math.cos(an) * r })
                            local en = okn and pts and (pts.snap or pts[#pts])
                            if en and en.y and math.sqrt((en.x - q.x) ^ 2 + (en.z - q.z) ^ 2) < 1.4 and math.abs(en.y - q.y) < 0.6 then
                                e2 = { x = en.x, y = en.y, z = en.z, walk = tot or 0 } break
                            end
                        end
                        if e2 then break end
                    end
                    if e2 and (not bd or (e2.walk or 0) < bd) then
                        best, bd = { stand = { x = e2.x, y = e2.y, z = e2.z }, face = { x = c.x, y = e2.y, z = c.z }, go = go }, e2.walk or 0
                    end
                end
                ch = ch:call("get_Next")
            end
        end) end
    end
    if not best then return nil end
    local d = math.sqrt((best.stand.x - pos.x) ^ 2 + (best.stand.z - pos.z) ^ 2)
    return { name = "the statue you move with Ashley", pos = best.stand, face = best.face, dist = d, latch = true, go = best.go,
        fname = "Statue", spoken = "statue",
        after = "Keep Ashley close. When I say F ready, press F: Leon and Ashley move the statue together. Then press N.",
        tip = "The statue blocks the door out of this room. You and Ashley move it together." }
end
G.ch9_double_target = double_target
if not G.ch9_step_before_double then G.ch9_step_before_double = G.ch9_step end
G.ch9_step = function(pos)
    local ok, t = pcall(G.ch9_double_target, pos)
    if ok and t then return t end
    return G.ch9_step_before_double(pos)
end
end

-- 11/14 Chapter 9 ASHLEY PART (objective "Rescue Leon"; player body ch0a1z0_body, start
-- (125.3,27.3,56.2)). N had kept running Leon's chain (trail, hall statue) and the routes
-- failed (Leon's walking map was gone; route.lua fixed). Ashley's own steps come first here.
-- Steps are read live from the game; each is added as the player reaches it.
--   1. hidden wall gm84_770_00_1 カンテラで動く隠し壁 (121.8,27.3,59.8, chainsaw.GmPortrayal,
--      no weapon IDs) opens on flags 隠し扉開く_LookAt / _Timer at (120.5,27.3,57.7): stand
--      there, face the wall, raise the lantern and hold it (tutorial flag カンテラ構え nearby).
do
local G = RE4Access.game
local A = {}
local function say(t, i) RE4Access.speak(t, i ~= false) end
local function find_gimmick(part)
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    if not gm then return nil end
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then
            local ok, go = pcall(function() return core:call("get_GameObject") end)
            if ok and go then
                local okn, n = pcall(function() return go:call("get_Name") end)
                if okn and n and n:find(part, 1, true) then return go end
            end
        end
    end
end
function A.active()
    local ok, t = pcall(G.objective_text)
    return ok and t and t:find("Rescue Leon", 1, true) ~= nil
end
-- 0. 11/14 live: the lantern still sat on its stand gm84_767 カンテラ台座 (GmAshleyLantern,
--    child lantern "A" drawn) - the hidden wall's flags wait for Ashley to take it (F).
local function lantern_on_stand()
    -- only the stand in Ashley's first room (121.5,27.3,59.1); 5:55PM the library pedestal
    -- (132.4,95.6), same name, was taken for it and N said "take the lantern" again
    local st
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core and not st then pcall(function()
            local go = core:call("get_GameObject")
            if go:call("get_Name"):find("カンテラ台座", 1, true) then
                local q = go:call("get_Transform"):call("get_Position")
                if math.abs(q.x - 121.5) < 1.5 and math.abs(q.z - 59.1) < 1.5 then st = go end
            end
        end) end
    end
    if not st then return nil end
    local on = false
    pcall(function()
        local c = st:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmAshleyLantern"))
        for _, x in ipairs(c:get_field("_Lantern"):get_elements()) do if x:call("get_DrawSelf") then on = true end end
    end)
    if not on then return nil end
    local q = st:call("get_Transform"):call("get_Position")
    return { x = q.x, y = q.y, z = q.z, go = st }
end
function A.step(pos)
    A.reached = A.reached or {}
    -- low debris crawl going west (stuck spot 115.1,63.2 three times today): aim a little right
    -- of the line, at (113.2,64.4); this used to live only in the way-back branch.
    if pos and math.abs(pos.y - 27.3) < 0.8 and pos.x > 114.4 and pos.x < 117.6 and pos.z > 62.6 and pos.z < 64.2 then
        return { name = "through the low debris", pos = { x = 114.3, y = 27.3, z = 63.7 }, face = { x = 113.2, y = 27.6, z = 64.4 }, short = true,
            tip = "Stay crouched and keep holding W, do not press E.",
            arrive = "Through the debris. Press E to stand up, then press N." }
    end
    -- 7. 11/14 RETURN WITH THE INSIGNIA (once the mausoleum insignia is gone from the floor):
    --    mausoleum -> hall -> elevator (bottom 13.1) up to 19 -> stairs -> passage behind the
    --    clock -> clock room -> deer corridor -> hidden wall -> Ashley's start room: the door
    --    gm80_505 汎用扉A (127.2,27.3,56.0, ItemUseSetting, where the knocking was) takes the
    --    insignia. Guides: armor knights wake up on the way back.
    -- (12:35 live: Ashley died on the way back; the game reloaded a save from before the
    --  pickup, the insignia lay in the mausoleum again, but the remembered flag still said
    --  "taken". The loose item decides now.)
    local loose
    if pos then
        for _, it in ipairs(G.items(pos, 80) or {}) do if it.name == "Salazar Family Insignia" then loose = it end end
        if loose then A.reached.insignia = false end
    end
    -- carried? (key items list; 13:20 the hot-reload wiped the remembered flag and N went
    -- back to "the low gap past the grate" with the insignia in her pocket)
    if not loose then
        pcall(function()
            local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
            local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
            local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
            for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
                local c = e:get_field("value")
                if c and c:get_type_definition():get_full_name() == "chainsaw.KeyItemInventoryController" then
                    local items = c:call("getInventoryItems")
                    for i = 0, items:call("get_Count") - 1 do
                        local it = items:call("get_Item", i):get_field("<Item>k__BackingField")
                        if it and tostring(mg:call(nil, mm:call("getItemNameMsgId", it:get_field("_ItemId")))):find("Insignia", 1, true) then A.reached.insignia = true end
                    end
                end
            end
        end)
    end
    local crouched = false
    pcall(function() crouched = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_IsCrouch") end)
    -- the low gap behind the grate (x 52-58.5, y 12.1) only lets a crouched Ashley through
    -- the low gap is bounded by two "adult-height" walls that stop a standing Ashley
    -- (gm91_038 PL通さずアルマ通すオトナ壁 at x 57.61 and 59.27); 13:20 live she stood at 58.85
    -- between them, outside the old x < 58.6 zone, and N said "the elevator".
    local in_gap = pos and pos.y > 11 and pos.y < 13.5 and pos.x > 51.5 and pos.x < 59.9 and pos.z > 105 and pos.z < 112
    -- 6:20PM (Claude playing): after the gongs the insignia also lies in the CAGE while the
    -- lantern puzzle is unsolved; then N must lead to the lantern stands, not "back to the insignia".
    if loose then
        pcall(function()
            local gmz = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gmz:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core then
                    local c = core:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPuzzleLantern2"))
                    if c and not c:call("checkCorrect") then loose = nil end
                end
            end
        end)
    end
    if loose and pos and pos.y >= 11.5 and pos.y < 16.5 then
        return { name = "the insignia, back in the mausoleum", pos = { x = 44.0, y = 9.4, z = 79.2 }, face = { x = loose.pos.x, y = loose.pos.y, z = loose.pos.z }, go = loose.go,
            tip = (in_gap and not crouched and "Press E to crouch first: the low gap only lets you through crouched. " or "")
                .. "When you died, the game went back to before you took the insignia. It lies in the middle of the mausoleum again.",
            arrive = "Press F now to take the insignia." }
    end
    if A.reached.insignia and pos then
        if in_gap and not crouched then
            return { name = "the low gap, crouched", pos = { x = 60.6, y = 12.1, z = 108.4 }, face = { x = 62.0, y = 12.6, z = 108.4 }, short = true,
                tip = "Press E to crouch first: the low gap only lets you through crouched. Then hold W.",
                arrive = "You are through. Press E to stand up, then press N." }
        end
        if pos.y < 16.5 then
            local carY, btn
            pcall(function()
                -- (6:40PM Claude playing: the buttons are children of "Box", not of the
                --  elevator, and the car floor (13.14) is 1 m above the hall floor (12.13):
                --  the old check never found the button, N kept the outside call switch.)
                local car = find_gimmick("gm81_512")
                local ch = car:call("get_Transform"):call("get_Child")
                while ch do
                    local nm = ch:call("get_GameObject"):call("get_Name")
                    if nm == "Box" then
                        carY = ch:call("get_Position").y
                        local c2 = ch:call("get_Child")
                        while c2 do
                            if c2:call("get_GameObject"):call("get_Name") == "ButtonB" then btn = c2:call("get_Position") end
                            c2 = c2:call("get_Next")
                        end
                    end
                    ch = ch:call("get_Next")
                end
            end)
            -- (6:45PM: the car waits below but its outer doors stay shut until the call switch
            --  (88.64,109.13) is pressed; Ashley stood at the shut doors and was caught. Outside
            --  the car (x < 88.9) N first gives the switch; the next N within 40 s, once she
            --  stood at the switch, goes inside.)
            local at_sw = math.sqrt((pos.x - 87.6) ^ 2 + (pos.z - 108.6) ^ 2) < 1.2
            if at_sw then A.sw_at = os.clock() end
            local inside = pos.x > 88.9
            if carY and math.abs(carY - pos.y) < 1.3 and btn and (inside or (A.sw_first and os.clock() - A.sw_first > 4)) then
                -- (6:46PM live: F ready came at (90.66,109.28), 1 m west of ButtonB; the old spot
                --  (btn - 0.45/0.55) was never reached inside the car)
                return { name = "the button inside the elevator", pos = { x = btn.x - 1.0, y = pos.y, z = btn.z - 0.15 }, face = { x = btn.x, y = btn.y, z = btn.z }, short = true,
                    tip = "Into the elevator.",
                    arrive = "Press F now." }
            end
            return { name = "the elevator switch", pos = { x = 87.6, y = 13.1, z = 108.6 }, face = { x = 88.64, y = 14.27, z = 109.13 }, short = true,
                tip = "Run, Shift and W.",
                arrive = "Press F now: the doors open, or the elevator comes. Then press N to go in." }
        end
        if pos.y < 25 then
            return { name = "the passage behind the clock", pos = { x = 111.2, y = 27.3, z = 91.7 },
                tip = "Up the stairs and through the passage behind the clock.",
                arrive = "You are by the clock. Press N." }
        end
        -- 7:00PM (Claude playing, after the library door, keys, clock 1 and the hallway crank
        -- are all open): the navigation finds the whole way back by itself - library, lobby,
        -- sliding door, hallway, curtain stairs up, passage behind clock 1 - to the insignia
        -- slot gm84_791 (129.6,34.8,51.6) on the upper floor, beside the typewriter.
        do
            local slot = find_gimmick("gm84_791")
            if not slot or not G.gimmick_done(slot) then
                return { name = "the insignia slot upstairs", pos = { x = 129.6, y = 33.21, z = 52.7 }, face = { x = 129.6, y = 34.8, z = 51.6 }, go = slot,
                    tip = "Run, Shift and W. The way: through the library, the lobby, the sliding door, the hallway, up the stairs and through the passage behind the first clock.",
                    arrive = "Press F to put the Salazar Family Insignia in. Then press N." }
            end
        end
        -- (13:10 live check: gm80_505 in Ashley's first room is only barred - its lock lists no
        --  item - so it is NOT the insignia slot. Guides: back into the library (crouch under
        --  the shelves left of the entrance), up the east stairs, slot beside the gate near
        --  Leon's cell (upper floor, y about 33, csa140 Leon talk trigger 131.3,33.2,56.5). An
        --  armor knight breaks into the library on the way back (アルマ_復路で起動 131.2,27.3,78.2).
        --  Not mapped live yet: stop at the library door and hand over to Claude.)
        -- 13:45 hands-on: the corridor-end library door never opens (stood, crouched, 3 lines).
        --  Data: the library entrance flag 書庫入口を抜けた is SOUTH of the library (129.2,27.7,71.5),
        --  by the study, and the study is behind the barred door gm80_505 of Ashley's first room
        --  (bar gm84_756 on her side). Way: west through the clock-room door, the deer-head
        --  corridor, the opened wall, the first room: lift the bar, then the study -> library.
        -- 14:05 hands-on: F at the bar does nothing for Ashley (bar visible on her side, Rno 1,
        --  not done) - the barred door is NOT the way. TheGamer: "crouch through the destroyed
        --  bookshelf on the left" at the first dead end = the corridor end (library door 125.6,79):
        --  facing the door, left = the shelf wall on the north side. Untested.
        -- 14:30 hands-on: crouched Ashley stuck at (115.1,63.2) under the debris going west;
        --  aiming a little right of the line, at (114.6,64.3), got her through at once.
        if pos.x > 114.4 and pos.x < 117.6 and pos.z > 62.6 and pos.z < 64.2 then
            return { name = "through the low debris", pos = { x = 114.3, y = 27.3, z = 63.7 }, face = { x = 113.2, y = 27.6, z = 64.4 }, short = true,
                tip = "Stay crouched and keep holding W, do not press E.",
                arrive = "Through the debris. Press E to stand up, then press N." }
        end
        -- 14:45 user chose (after the bookshelf failed): switch off the library doorway blocker
        --  gm91_035 DummyDoor (125.6,79.0) collider, live only (RE4Access.library_dummy_off), and
        --  get the Bunch of Keys upstairs in the library first.
        if RE4Access.library_dummy_off and pos.y > 25 then
            for _, it in ipairs(G.items(pos, 120) or {}) do
                if it.name == "Bunch of Keys" and not it.inside then
                    local spot = RE4Access.route.reach_spot(pos, it.pos)
                    local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or it.pos
                    return { name = "the Bunch of Keys, upstairs in the library", pos = sp, face = it.pos, go = it.go,
                        tip = "Through the library door at the end of the corridor, then up the stairs. Run past knights.",
                        arrive = "Press F now to take the Bunch of Keys. Then press N." }
                end
            end
            return { name = "the upstairs of the library", pos = { x = 134.2, y = 31.4, z = 100.6 },
                tip = "You have the keys.",
                arrive = "You are upstairs in the library. Tell Claude: I read the way to the insignia slot from here." }
        end
        if pos.x < 127.0 and pos.y > 25 then
            if not (pos.x > 122.5 and pos.z > 80.2) then
                return { name = "the broken bookshelf at the end of the corridor", pos = { x = 124.0, y = 27.3, z = 79.4 }, face = { x = 124.0, y = 27.8, z = 81.5 },
                    tip = "Back to the corridor that ends at the library door. Guides: Ashley crawls through a broken bookshelf on the left there. If the corridor with the deer heads blocks you, crouch with E.",
                    arrive = "The bookshelf is in front of you. Press E to crouch, then hold W to crawl through. If you cannot get through, tell Claude." }
            end
            local barred = true
            pcall(function() local d = find_gimmick("gm80_505_00_0"); if d then barred = G.door_locked(d) end end)
            -- 13:55 live: "Blocked" x4 at (111.8,27.3,70.7) in the deer-head corridor, standing.
            -- Guides: "crouch under the debris" in the corridor with the mounted animal heads.
            if barred and not crouched and pos.x > 108.5 and pos.x < 118.5 and pos.z > 60 and pos.z < 78 then
                return { name = "the barred door in the first room", pos = { x = 126.4, y = 27.3, z = 56.6 }, face = { x = 127.6, y = 28.3, z = 56.6 },
                    tip = "Press E to crouch first: low debris blocks this corridor. Then hold W. Stand up again with E after the opened wall.",
                    arrive = "The barred door is in front of you. Press F to lift the bar. Then hold W into the door and press N." }
            end
            if barred then
                return { name = "the barred door in the first room", pos = { x = 126.4, y = 27.3, z = 56.6 }, face = { x = 127.6, y = 28.3, z = 56.6 },
                    tip = "The library door here never opens. The way in is from the other side, through the room where Ashley started: its door has a bar on her side. Back west through the clock room, the corridor with the deer heads and the opened wall.",
                    arrive = "The barred door is in front of you. Press F to lift the bar. Then hold W into the door and press N." }
            end
            return { name = "the library entrance, through the study", pos = { x = 129.2, y = 27.3, z = 71.5 },
                tip = "Through the door, across the study, to the library entrance.",
                arrive = "You are at the library entrance. Press N." }
        end
        if pos.y > 25 and pos.y < 30 and pos.z < 100 then
            return { name = "the stairs up in the library", pos = { x = 134.2, y = 31.4, z = 100.6 },
                tip = "Through the library to the stairs on the far side, then up. Armor knights may be here: keep moving.",
                arrive = "You are upstairs in the library. Tell Claude: I read the way to the insignia slot from here." }
        end
    end
    local ls = lantern_on_stand()
    if ls and math.sqrt((ls.x - pos.x) ^ 2 + (ls.z - pos.z) ^ 2) < 30 then
        local spot = RE4Access.route.reach_spot(pos, { x = ls.x, y = ls.y + 0.75, z = ls.z }, 1.0, 1.5)
        local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or { x = ls.x - 0.4, y = ls.y, z = ls.z - 0.8 }
        return { name = "the lantern on its stand", pos = sp, face = { x = ls.x, y = ls.y + 0.75, z = ls.z }, go = ls.go,
            tip = "Ashley needs the lantern first.",
            arrive = "The lantern stand is in front of you. Press F to take the lantern. If no F comes, press Backslash. Then press N." }
    end
    local wall = find_gimmick("カンテラで動く隠し壁")
    if wall and not G.gimmick_done(wall) then
        return { name = "the hidden wall", pos = { x = 120.5, y = 27.3, z = 57.7 }, face = { x = 121.8, y = 28.3, z = 59.8 },
            tip = "A wall in this room slides open when Ashley shines the lantern at it.",
            arrive = "You are facing the hidden wall. Wait a moment: it may slide open by itself. If not, hold L to raise the lantern at it. Then press N." }
    end
    -- 2. 11/14 (guides: Gamerant/PowerPyx/Gameranx Ch9 Ashley): lantern -> hidden wall ->
    --    deer-head corridor -> clock room -> door left of the grandfather clock (gm80_508(2),
    --    now open; a DummyDoor stops going back) -> the library. "Crouch under the bookshelves":
    --    the corridor end (125.6,27.3,79.0, gm91_035 DummyDoor) is where Ashley stood and pushed;
    --    the way on is crouching (E) under the shelf there. (The barred start-room door and
    --    the west door were wrong guesses from 09:20-09:40.)
    -- 11/14 10:20: the library door at the corridor end stayed shut (twice, also after a
    --    reload). The clock-room grandfather clock gm84_777 柱時計パズル(2) (111.2,27.3,92.7)
    --    set to its CorrectTime (11:04 here) opens a passage behind it - the known shortcut
    --    past the library (only optional treasures are missed). Stand (111.3,27.3,91.8).
    local clk = find_gimmick("柱時計パズル(2)")
    -- 11/14 PM (replay, user: no shortcut - the mod must work for everyone): the normal route
    -- goes into the library for the Bunch of Keys before any clock. N leads to the library door
    -- at the corridor end and stops there; Claude studies the way in live.
    -- (15:50 bug: "keys still lying there" needed the library loaded; far away it is not, so
    --  N fell through to the clock again. Now: not carrying the Bunch of Keys = library first.)
    local has_keys = false
    pcall(function()
        local mm = sdk.get_managed_singleton("chainsaw.ItemManager"):call("get_ItemMessageManager")
        local mg = sdk.find_type_definition("via.gui.message"):get_method("get(System.Guid)")
        local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
        for _, e in ipairs(im:get_field("_ControllerTable"):get_field("_entries"):get_elements()) do
            local c = e:get_field("value")
            if c and c:get_type_definition():get_full_name() == "chainsaw.KeyItemInventoryController" then
                local items = c:call("getInventoryItems")
                for i = 0, items:call("get_Count") - 1 do
                    local it = items:call("get_Item", i):get_field("<Item>k__BackingField")
                    if it and tostring(mg:call(nil, mm:call("getItemNameMsgId", it:get_field("_ItemId")))):find("Bunch of Keys", 1, true) then has_keys = true end
                end
            end
        end
    end)
    -- 11/14 5:10PM LIVE: after the camera look-around at the corridor-end door (lookwatch) Ashley
    -- walked through it into the library ("Autosaved" = 書庫到着). Library steps (live data):
    --  pedestal gm84_767 (132.4,27.3,95.6): put the lantern on it -> shelves gm84_769 slide;
    --  loft crank gm84_772 (132.4,27.3,101.5, GmHoldHandle): hold F -> stairs gm84_771 down;
    --  take the lantern back from the pedestal; loft: Bunch of Keys (127.0,32.3,97.1).
    if not has_keys and pos and pos.x > 125.9 and pos.z > 66 and pos.z < 106 and pos.y < 33.5 then   -- z > 66: the elevator lobby counts
        local function gm_at(part, x, z)
            local gm4 = sdk.get_managed_singleton("chainsaw.GimmickManager")
            local found
            for _, e in ipairs(gm4:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core and not found then pcall(function()
                    local go = core:call("get_GameObject")
                    if go:call("get_Name"):find(part, 1, true) then
                        local q = go:call("get_Transform"):call("get_Position")
                        if math.abs(q.x - x) < 1.5 and math.abs(q.z - z) < 1.5 then found = go end
                    end
                end) end
            end
            return found
        end
        local function floor_spot(q, reach)
            local sp = RE4Access.route.reach_spot(pos, { x = q.x, y = q.y + 0.75, z = q.z }, reach or 1.1, 1.5)
            return sp and { x = sp.x, y = sp.y, z = sp.z } or { x = q.x, y = 27.3, z = q.z - 0.9 }
        end
        -- 5:35PM: the pottery shelf gm82_549 (130.5,78.2) blocks the way north (look-around: no
        -- effect). The walking map has a crouch passage SOUTH under the shelves (129.5,73.8, low)
        -- to the library's entrance (129.2,71.5) - test it.
        local pot = gm_at("棚と棚の上に置いてある陶器", 130.5, 78.2)
        if pot and not G.gimmick_done(pot) and pos.x < 130.2 and pos.z > 74.5 and pos.z < 80.5 and pos.y < 29 and not A.reached.south_gap then
            return { name = "the low gap to the south", pos = { x = 129.6, y = 27.3, z = 71.8 }, short = true,
                tip = "The shelf with the pots blocks the way ahead. There is a low passage to the south: crouch with E and hold W.",
                arrive = "You are through the low passage. Press E to stand up, then press N and tell Claude where it leads." }
        end
        if pos.z < 72.5 then A.reached.south_gap = true end
        -- 5:45PM live: through the south gap Ashley is in the elevator lobby (129.6,72.2). The
        -- walking map has a second way north on the shelf's east side, x 132.5: round the
        -- lobby to (132.6,72.3), then north to (132.5,78.7), then the library aisle.
        if A.reached.south_gap and pos.z < 76.0 and pos.y < 29 then
            if pos.x < 132.0 then
                return { name = "the east side of the lobby", pos = { x = 132.6, y = 27.3, z = 72.3 },
                    tip = "Round the lobby, past the elevator, to the passage on the east side of the shelves.",
                    arrive = "Press N for the way north." }
            end
            return { name = "the passage north, back into the library", pos = { x = 132.5, y = 27.3, z = 78.7 },
                tip = "North along the east side of the shelves.",
                arrive = "You are back in the library, past the shelf with the pots. Press N." }
        end
        local shelf = gm_at("カンテラで動く本棚", 132.3, 96.0)
        local stand = gm_at("カンテラ台座", 132.4, 95.6)
        local crank = gm_at("書斎エリアのクランク", 132.4, 101.5)
        local stairs = gm_at("ロフトの降ろし階段", 134.3, 100.6)
        local lantern_on = false
        pcall(function()
            local c = stand:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmAshleyLantern"))
            for _, x in ipairs(c:get_field("_Lantern"):get_elements()) do if x:call("get_DrawSelf") then lantern_on = true end end
        end)
        local stairs_down = stairs and G.gimmick_done(stairs)
        if not stairs_down and stand and not lantern_on and pos.y < 29 then
            local q = { x = 132.4, y = 27.3, z = 95.6 }
            return { name = "the lantern pedestal", pos = floor_spot(q), face = { x = q.x, y = q.y + 0.75, z = q.z }, go = stand, short = true,
                tip = "Through the library to a pedestal. An armor knight walks here: hold L to raise the lantern at it, the light freezes it.",
                arrive = "Press F to put the lantern on the pedestal. A bookshelf slides away. Then press N." }
        end
        if not stairs_down and crank and pos.y < 29 then
            local q = { x = 132.4, y = 27.3, z = 101.5 }
            return { name = "the crank behind the bookshelf", pos = floor_spot(q, 1.3), face = { x = q.x, y = q.y + 0.9, z = q.z }, go = crank, short = true,
                tip = "Through the gap where the bookshelf was, to a crank.",
                arrive = "Hold F to turn the crank until it stops. It lowers stairs to the loft. Then press N." }
        end
        if stairs_down and lantern_on and pos.y < 29 then
            local q = { x = 132.4, y = 27.3, z = 95.6 }
            return { name = "the lantern pedestal, to take the lantern back", pos = floor_spot(q), face = { x = q.x, y = q.y + 0.75, z = q.z }, go = stand, short = true,
                tip = "The stairs are down. Take your lantern back first: you need it against the knights.",
                arrive = "Press F to take the lantern back. Then press N." }
        end
    end
    -- 16:05 test (first visit, normal route): the library entrance flag 書庫入口を抜けた is at
    -- (129.2,27.7,71.5), south of the library, reached through the study behind the barred door
    -- of Ashley's first room. On the return trip F at the bar did nothing; test it now, first visit.
    if not has_keys and pos and pos.x > 125.9 and pos.z > 73 and pos.z < 106 then
        for _, it in ipairs(G.items(pos, 60) or {}) do
            if it.name == "Bunch of Keys" and not it.inside then
                local spot = RE4Access.route.reach_spot(pos, it.pos)
                local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or it.pos
                return { name = "the Bunch of Keys, up in the loft", pos = sp, face = it.pos, go = it.go, short = true,
                    tip = "Up the stairs to the loft.",
                    arrive = "Press F to take the Bunch of Keys. Then press N." }
            end
        end
    end
    if not has_keys and A.try_bar then
        return { name = "the barred door in the first room", pos = { x = 126.6, y = 27.3, z = 56.5 }, face = { x = 128.0, y = 28.4, z = 56.6 },
            tip = "Test: the way into the library may be through the study, behind the barred door in the first room.",
            arrive = "The bar is in front of you. Press F. If the bar lifts, hold W into the door. Tell Claude what happened." }
    end
    if clk and not G.gimmick_done(clk) and not has_keys and not A.allow_clock then
        -- 16:20: the game uses camera LookAt checks here (復路アルマ起動前_LookAt, 隠し扉開く_LookAt):
        -- events fire when the CAMERA looks at a spot. A blind player's camera points at the
        -- floor, so they may never fire. On arrival the mod looks around at eye level.
        return { name = "the library door at the end of the corridor", pos = { x = 123.8, y = 27.3, z = 79.2 },
            look = { { x = 126.6, y = 28.7, z = 79.0 }, { x = 126.0, y = 28.7, z = 81.5 }, { x = 126.0, y = 28.7, z = 76.5 }, { x = 128.5, y = 28.9, z = 79.0 }, { x = 126.6, y = 28.7, z = 79.0 } },
            tip = "Through the opened wall, the corridor with the deer heads, the clock room and the door beside the clock, to the corridor that ends at the library door. Crouch with E where it is low.",
            arrive = "You are at the library door. Hold still: I turn the camera to look at the door and around it, the way a sighted player would. Then tell Claude what happened." }
    end
    -- 6PM: with the keys, next is the lobby elevator (gm81_519 書斎のエレベーター, GmElevatorTrouble):
    -- key lock "Keys" (130.8,28.4,65.5, 3rd key), then its button, up; the lift sticks short of
    -- the top - get out (F) to the upper floor (insignia slot gm84_791 129.6,34.8,51.6 is there).
    -- 6:20PM live: UPPER FLOOR (salon, y 33.2) after the lobby elevator. Lift stops short:
    -- "Elevator Trouble" F climbs out. Here: Leon talk trigger csa140 (131.3,33.2,56.5), typewriter
    -- (133.8,33.8,52.0), librarian's notes File_014 (127.2,33.2,52.4), Sapphire chest③ (123.6,34.1,54.0,
    -- 4th key), clock 1 gm84_777 (135.7,33.2,55.7) -> 11:04 (wallclock reader), insignia slot
    -- gm84_791 (129.6,34.8,51.6) for the end of the section.
    -- 7:05PM (Claude playing): insignia placed in gm84_791 -> the barred gate by Leon's cell
    -- opens; walking through it starts the next scene (trigger アシュリーさらわれる_CS 131.2,32.8,49.8).
    do
        local slot = pos and pos.y > 32.3 and find_gimmick("gm84_791")
        if slot and G.gimmick_done(slot) then
            return { name = "through the opened gate, to Leon", pos = { x = 131.2, y = 32.8, z = 49.6 },
                tip = "The insignia opened the barred gate beside it. Walk through: a scene starts.",
                arrive = "Keep walking forward with W until the scene starts." }
        end
    end
    if has_keys and pos and pos.y > 32.3 and pos.y < 36 and pos.x > 115 and pos.x < 145 and pos.z > 45 and pos.z < 70 then
        if pos.z > 62.8 and math.abs(pos.x - 131.4) < 1.6 then
            return { name = "out of the stuck lift", pos = { x = pos.x, y = pos.y, z = pos.z }, face = { x = 131.4, y = 34.0, z = 61.0 }, short = true, no_route = true,
                tip = "The lift stopped just short of the top.",
                arrive = "Press F to climb out of the lift. Then press N." }
        end
        A.reached = A.reached or {}
        if pos.z < 58 then A.reached.salon = true end
        local function gmn(part)
            local found
            local gm6 = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm6:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core and not found then pcall(function()
                    local go = core:call("get_GameObject")
                    if go:call("get_Name"):find(part, 1, true) then
                        local q = go:call("get_Transform"):call("get_Position")
                        if q.y > 32 then found = go end
                    end
                end) end
            end
            return found
        end
        local chest = gmn("鍵の束用アタッチメント③")
        if chest and not G.gimmick_done(chest) and not A.skip_chest3 then
            local q = { x = 123.6, y = 34.4, z = 53.8 }
            local spot = RE4Access.route.reach_spot(pos, q, 1.3, 1.6)
            local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or { x = 123.6, y = 33.2, z = 54.9 }
            return { name = "the treasure chest with a key lock", pos = sp, face = q, go = chest, short = true,
                tip = "A Sapphire is in a chest here; your keys open it.",
                arrive = "Press F at the lock. Turn the keys with A or D until I say it is the right one, the fourth. Then F. Then take the Sapphire with F, and press N." }
        end
        -- 6:35PM live: the key lock opened (attachment ③ done) but the chest lid gm84_800 still
        -- needs HOLD F, then the Sapphire inside is taken with F. Ashley stood 1 m off, facing
        -- 30 degrees away: no prompt.
        local locker = gmn("鍵の束用宝箱")
        local saph
        for _, it in ipairs(G.items(pos, 6) or {}) do if it.name:find("Sapphire", 1, true) then saph = it end end
        if chest and G.gimmick_done(chest) and saph and not A.skip_chest3 then
            local lid_shut = locker and not G.gimmick_done(locker)
            return { name = lid_shut and "the chest lid" or "the Sapphire in the chest", pos = { x = 123.5, y = 33.2, z = 53.2 }, face = { x = 123.56, y = 34.1, z = 54.05 }, go = locker, short = true,
                tip = "The lock is open.",
                arrive = lid_shut and "Facing the chest. HOLD F for 2 seconds to open the lid. Then press F to take the Sapphire. Then press N."
                    or "Facing the chest. Press F to take the Sapphire. Then press N." }
        end
        local note = gmn("File_014_00")
        if note and not A.reached.note then
            if math.sqrt((pos.x - 127.2) ^ 2 + (pos.z - 53.2) ^ 2) < 1.0 then A.reached.note = true end
            return { name = "the librarian's notes", pos = { x = 127.2, y = 33.2, z = 53.2 }, face = { x = 127.2, y = 34.0, z = 52.4 }, go = note, short = true,
                tip = "A note on the desk has the time for the grandfather clock.",
                arrive = "Press F to read the note, then close it. The time is 11:04. Then press N." }
        end
        local clk1 = gmn("gm84_777_00_0_柱時計パズル")   -- (not the "..柱時計パズルクリア後_Autosave" trigger, same words)
        if clk1 and not G.gimmick_done(clk1) then
            -- (6:45PM live: the clock face looks WEST - its light child at x 134.99 - so Ashley
            --  stands west of it, not north; from (134.85,57.03) there was no F.)
            return { name = "the grandfather clock up here", pos = { x = 134.75, y = 33.2, z = 55.72 }, face = { x = 135.7, y = 34.3, z = 55.72 }, go = clk1, short = true,
                tip = "Set this clock to 11:04: it opens a passage with stairs down.",
                arrive = "Press F to use the clock. Turn the hands with A and D, and W and S. I say the time. Set it to 11:04, then confirm. Then press N." }
        end
        -- clock 1 done: fall through to the crank step below
    end
    -- 6:55PM live: behind clock 1 the passage runs east (141.5,33.2,55.7), down the curtain
    -- stairs (143.2, z 57->68, armor from below), along a hallway to the study crank gm84_772
    -- (138.1,27.3,72.8, hold F) that opens the sliding door gm80_757 (137.3,72.1) to the lobby.
    -- Then through the library and the west corridor back to clock 2 in the clock room.
    if has_keys and pos and A.reached and A.reached.salon then
        local scrank
        local gm7 = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm7:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core and not scrank then pcall(function()
                local go = core:call("get_GameObject")
                if go:call("get_Name"):find("gm84_772", 1, true) then
                    local q = go:call("get_Transform"):call("get_Position")
                    if math.abs(q.x - 138.1) < 1 and math.abs(q.z - 72.8) < 1 then scrank = go end
                end
            end) end
        end
        if scrank and not G.gimmick_done(scrank) then
            return { name = "the crank in the hallway downstairs", pos = { x = 138.9, y = 27.3, z = 72.5 }, face = { x = 138.1, y = 28.4, z = 72.8 }, go = scrank, short = true,
                tip = "Through the passage behind the clock and down the stairs. An armor knight comes up the stairs: hold L to freeze it with the lantern, then run past.",
                arrive = "Hold F to turn the crank until it stops. It opens a sliding door. Then press N." }
        end
    end
    if has_keys and pos and pos.y < 33.5 then   -- (the loft is at y 31.3)
        local klock, elev
        local gm5 = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm5:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject"); local n = go:call("get_Name")
                local q = go:call("get_Transform"):call("get_Position")
                if n == "Keys" and math.abs(q.x - 130.8) < 1 and math.abs(q.z - 65.5) < 1 then klock = go end
                if n:find("gm81_519", 1, true) then elev = go end
            end) end
        end
        if klock and not G.gimmick_done(klock) then
            local q = { x = 130.8, y = 28.4, z = 65.5 }
            local spot = RE4Access.route.reach_spot(pos, q, 1.2, 1.6)
            local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or { x = 130.8, y = 27.3, z = 66.4 }
            return { name = "the key lock on the elevator", pos = sp, face = q, go = klock, short = true,
                tip = "Back down the loft stairs and through the library to the elevator in the lobby, south of the library. Knights: hold L, the lantern freezes them.",
                arrive = "Press F at the lock. Turn the keys with A or D: I say which key you are on and when it is the right one, the third. Then press F. Then press N." }
        end
        if elev and not G.gimmick_done(elev) then
            -- 6:10PM live: the lock opened the outer doors; the car (child Box 131.34,27.32,63.85)
            -- is here; its inside button is ButtonB (132.4,28.4,62.7). ButtonA (130.3,65.0) is outside.
            return { name = "the button inside the elevator", pos = { x = 131.8, y = 27.3, z = 63.3 }, face = { x = 132.4, y = 28.4, z = 62.7 }, short = true,
                tip = "The doors are open. Walk into the elevator.",
                arrive = "Press F now. If the lift stops before the top, press F to climb out. Then press N." }
        end
    end
    if clk and not G.gimmick_done(clk) then
        return { name = "the grandfather clock", pos = { x = 111.3, y = 27.3, z = 91.8 }, face = { x = 111.2, y = 28.3, z = 92.9 }, go = clk,
            tip = "Setting this clock to the right time opens a secret passage behind it.",
            arrive = "The clock is in front of you. Press F to use it. Turn the hands, try A and D, and W and S. I say the time the clock shows. Set it to 11:04. When it is right, confirm it with F or Enter. Then press N." }
    end
    -- 11/14 10:30: clock solved (11:04). Behind it a passage runs north (111.2,27.3,95) and
    --    down stairs west to y 19: the basement elevator. Call switch gm84_675
    --    書斎地下のエレベータ呼び出しスイッチ (92.5,20.1,107.6), outer door gm80_564 (92.4,19.0,108.4),
    --    car gm81_512 (90.5,13.1,108.4) goes down to y 13.1 (armor hall / gong room).
    if clk and G.gimmick_done(clk) then A.reached.clock2 = true end
    -- far from the clock room (not loaded) and not solved yet: walk there (keys in hand)
    if has_keys and not clk and not A.reached.clock2 and pos and pos.y > 25 then
        return { name = "the grandfather clock in the clock room", pos = { x = 111.3, y = 27.3, z = 91.8 }, face = { x = 111.2, y = 28.3, z = 92.9 },
            tip = "Back through the library and the west corridor to the room with the other grandfather clock. Knights: hold L to freeze them, keep moving.",
            arrive = "The clock is in front of you. Press F, set it to 11:04 while I read the time, and confirm. Then press N." }
    end
    -- (not loaded: past it only if down in the basement/mausoleum (y < 22) or seen solved;
    --  6:58PM: from the east hallway the clock-room clock is unloaded but NOT solved yet)
    if (clk and G.gimmick_done(clk)) or (not clk and pos and (pos.y < 22 or A.reached.clock2)) then
        local sw
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject")
                if go:call("get_Name"):find("エレベータ呼び出しスイッチ", 1, true) then
                    local q = go:call("get_Transform"):call("get_Position")
                    if q.y > 19.5 and not sw then sw = { go = go, pos = { x = q.x, y = q.y, z = q.z } } end
                end
            end) end
        end
        -- 4. gong hall below the elevator (y 12.1): four gongs gm84_726/727 銅鑼 (GmCrestButton
        --    _Crest bits 1 stag (84.5,12.2,101.9), 2 dolphin (76.8,12.2,111.9), 4 snake
        --    (70.8,12.2,101.9), 8 eagle (66.3,12.1,114.9)); ringing wakes armor knights; when all
        --    four are rung the crest grate gm80_764 書斎地下の紋章格子 (58.5,12.1,108.4) opens.
        -- 6. MAUSOLEUM LANTERN PUZZLE (11/14 live): LightC gm GmPuzzleLantern2 (43.71,9.35,78.62),
        --    _Stand = StandA (40.55,9.84,80.44), StandB (43.71,9.84,74.97), StandC (46.87,9.84,80.44)
        --    (GmAshleyLantern, get_CurLantern / getPlLantern: LanternType A 0, B 1, C 2, None 10),
        --    _CorrectLight per stand; checkCorrect(). Live answer: A<-1, B<-0, C<-2. N walks to the
        --    stand that should get the lantern Ashley holds (F swaps or puts it down); with empty
        --    hands, to a wrong stand to take its lantern.
        if pos and pos.y < 11.5 then
            local puzzle
            local gm3 = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm3:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core and not puzzle then pcall(function()
                    local go = core:call("get_GameObject")
                    local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmPuzzleLantern2"))
                    if c then puzzle = c end
                end) end
            end
            if puzzle then
                local okc, solved = pcall(function() return puzzle:call("checkCorrect") end)
                if okc and not solved then
                    local stands, correct = {}, {}
                    for i, x in ipairs(puzzle:get_field("_Stand"):get_elements()) do stands[i] = x end
                    for i, x in ipairs(puzzle:get_field("_CorrectLight"):get_elements()) do correct[i] = x:get_field("value__") end
                    -- held lantern: getPlLantern() kept saying 0 after the swap (12:10 live), so it
                    -- is worked out instead: three lanterns exist (0,1,2); the one on no stand is
                    -- in Ashley's hand.
                    local on = {}
                    for _, st in ipairs(stands) do on[st:call("get_CurLantern")] = true end
                    local held = 10
                    for t = 0, 2 do if not on[t] then held = t end end
                    local side = { "the right-hand stand", "the middle stand", "the left-hand stand" }   -- seen coming in from the entrance
                    local pick, action
                    for i, st in ipairs(stands) do
                        local cur = st:call("get_CurLantern")
                        if held ~= 10 and correct[i] == held and cur ~= held then
                            pick = i
                            action = (cur == 10) and "Press F to put your lantern on it." or "Press F to swap: your lantern goes on, you take its lantern."
                            break
                        end
                    end
                    if not pick and held == 10 then
                        for i, st in ipairs(stands) do
                            local cur = st:call("get_CurLantern")
                            if cur ~= 10 and cur ~= correct[i] then pick = i action = "Press F to take its lantern." break end
                        end
                    end
                    if pick then
                        local st = stands[pick]
                        local sgo = st:call("get_GameObject")
                        local q = sgo:call("get_Transform"):call("get_Position")
                        local spot = RE4Access.route.reach_spot(pos, { x = q.x, y = q.y, z = q.z }, 1.3, 1.2)
                        local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or { x = q.x, y = pos.y, z = q.z + 1.0 }
                        log.info(string.format("[RE4Access] lantern puzzle: held %s, go to stand %d (%s)", tostring(held), pick, action))
                        return { name = side[pick] or "a lantern stand", pos = sp, face = { x = q.x, y = q.y + 0.5, z = q.z }, go = sgo, short = true,
                            tip = "Lantern puzzle: I read the right answer from the game.",
                            arrive = action .. " Then press N." }
                    end
                elseif okc and solved then
                    local ins
                    for _, it in ipairs(G.items(pos, 15) or {}) do if it.name == "Salazar Family Insignia" then ins = it end end
                    if ins then
                        return { name = "the Salazar Family Insignia", pos = { x = 44.0, y = 9.4, z = 79.2 }, face = { x = ins.pos.x, y = ins.pos.y, z = ins.pos.z }, go = ins.go, short = true,
                            tip = "The lantern puzzle is solved. The insignia lies in the middle.",
                            arrive = "Press F now to take the insignia." }
                    end
                    A.reached.insignia = true
                    return A.step(pos)   -- straight on to the way back (12:45: said "not mapped" here)
                end
            end
        end
        if pos and pos.y < 16.5 and pos.x < 92 then
            local names = { ["牡鹿"] = "the stag gong", ["イルカ"] = "the dolphin gong", ["ヘビ"] = "the snake gong", ["ワシ"] = "the eagle gong" }
            local best, bd
            local gm2 = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm2:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core then pcall(function()
                    local go = core:call("get_GameObject"); local n = go:call("get_Name")
                    if not n:find("銅鑼", 1, true) or G.gimmick_done(go) then return end
                    local q = go:call("get_Transform"):call("get_Position")
                    if q.y > 16 then return end
                    local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
                    local nm = "a gong"
                    for k, v in pairs(names) do if n:find(k, 1, true) then nm = v end end
                    -- 7:15PM (death at the snake gong, 7 knights awake): ring the gong FARTHEST from
                    -- the grate first, so the last ring leaves Ashley closest to the way out.
                    local dg = -math.sqrt((q.x - 58.5) ^ 2 + (q.z - 108.4) ^ 2)
                    if not bd or dg < bd then best, bd = { name = nm, pos = { x = q.x, y = q.y, z = q.z }, go = go }, dg end
                end) end
            end
            if best then
                local spot = RE4Access.route.reach_spot(pos, best.pos, 1.2, 1.5)
                local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or best.pos
                return { name = best.name, pos = sp, face = { x = best.pos.x, y = best.pos.y + 1, z = best.pos.z }, go = best.go,
                    tip = "Ring all four gongs, the farthest from the exit first. Each gong wakes armor knights. The lantern only freezes a knight in front of you: never stand still, keep moving. After the last gong run straight to the grate.",
                    arrive = "The gong is in front of you. Press F to ring it. Then press N for the next one." }
            end
            -- 5. 11/14 live: grate gm80_764 (GmCrestPuzzleDoor, pattern 15) open; just past it a
            --    wall that stops a standing player (gm91_038 PL通さずアルマ通すオトナ壁, 57.6,108.4) and
            --    the crawl tutorial trigger チュートリアル_ハイハイ (54.1,12.1,108.4): crouch (E) and crawl
            --    west. Then on to the room with three lanterns (44.0,9.4,94.8) = mausoleum puzzle.
            -- (11:55 live: Ashley stood at (55.9,12.1,107.6), already west of the grate wall at
            --  57.6, and the old stand spot (59.6) sent her back east into it, "Blocked".)
            if pos.x > 52.0 and pos.x <= 57.3 then
                return { name = "the way west, crouched", pos = { x = 50.5, y = 12.1, z = 107.6 }, short = true,
                    tip = "You are past the grate. Crouch with E and keep going west through the low part. I say Crouching or Standing when it changes.",
                    arrive = "You are through. Press E to stand up, then press N." }
            end
            if pos.x > 57.3 then
                return { name = "the low gap past the grate", pos = { x = 59.6, y = 12.1, z = 108.4 }, face = { x = 54.0, y = 12.6, z = 108.4 }, short = true,
                    tip = "The grate is open. Right behind it Ashley has to crawl through a low gap, to the west.",
                    arrive = "Facing the gap, west. Press E to crouch, then hold W to crawl through. When you are through, press E to stand up and press N." }
            end
            return { name = "the room with the three lanterns", pos = { x = 44.0, y = 9.4, z = 94.8 },
                tip = "On through the hall and down to the mausoleum room. Armor knights may follow: hold L at one to freeze it.",
                arrive = "You are in the room with the lanterns. Tell Claude: I read this puzzle live." }
        end
        -- car (child "Box" of gm81_512) up here: walk in. The entrance faces west at
        -- x 92.36 (outer doors gm80_564 at 107.2-107.7); inside flag (90.65,19.03,108.26).
        local carY
        pcall(function()
            local car = find_gimmick("gm81_512")
            local ch = car:call("get_Transform"):call("get_Child")
            while ch do
                if ch:call("get_GameObject"):call("get_Name") == "Box" then carY = ch:call("get_Position").y break end
                ch = ch:call("get_Next")
            end
        end)
        if pos and pos.y > 17.5 and carY and math.abs(carY - pos.y) < 0.8 then
            -- 11/14 10:14 log: the game showed "Elevator Button" (inner ButtonB 91.69,20.09,
            -- 109.42) at (91.3,19.0,108.8) for about a second; Ashley then raised the lantern at an
            -- armor knight 3 m away (aim turns her) and the prompt was gone; she died. One step,
            -- straight to the inner button, short words.
            local btn
            pcall(function()
                local car = find_gimmick("gm81_512")
                local ch = car:call("get_Transform"):call("get_Child")
                while ch do
                    if ch:call("get_GameObject"):call("get_Name") == "ButtonB" then btn = ch:call("get_Position") break end
                    ch = ch:call("get_Next")
                end
            end)
            local bp = btn and { x = btn.x, y = btn.y, z = btn.z } or { x = 91.69, y = 20.09, z = 109.42 }
            return { name = "the button inside the elevator", pos = { x = 91.25, y = 19.0, z = 108.85 }, face = bp, short = true,
                tip = "The elevator is here, to the west. Walk in to its button. If an armor knight is close, first hold L at it until it stops, then let go.",
                arrive = "Press F now." }
        end
        if pos and pos.y > 17.5 and sw then
            local spot = RE4Access.route.reach_spot(pos, sw.pos, 1.0, 1.6)
            local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or { x = 93.3, y = 19.0, z = 108.0 }
            return { name = "the elevator switch", pos = sp, face = sw.pos, go = sw.go,
                tip = "Through the passage behind the clock, down the stairs, to an elevator. If an armor knight comes, hold L to raise the lantern at it.",
                arrive = "The elevator switch is in front of you. Press F to call the elevator. Wait until it arrives, then walk in with W. If it does not go down by itself, press F inside. Then press N." }
        end
        return nil
    end
    -- (11/14 11:15: the "low gap under the bookshelf" and library-pedestal steps were wrong
    --  guesses - the library door stays shut for Ashley here; removed. The clock comes first.)
    local keys
    for _, it in ipairs(G.items(pos, 120) or {}) do
        if it.name == "Bunch of Keys" and not it.inside then keys = it break end
    end
    if keys then
        local spot = RE4Access.route.reach_spot(pos, keys.pos)
        local sp = spot and { x = spot.x, y = spot.y, z = spot.z } or keys.pos
        return { name = "the Bunch of Keys, upstairs", pos = sp, face = keys.pos,
            tip = "Up the stairs to the library's upper floor. An armor knight walks around down here: if it comes at you, hold L to raise the lantern at it, the light stops it. Then walk on.",
            arrive = "The Bunch of Keys is in front of you. Press F to pick it up. If no F comes, step a little closer with W, then press F. Then press N." }
    end
    -- 4. grandfather clock puzzle gm84_777 柱時計パズル(2) with its slide door (111.2,27.3,92.7):
    --    not read yet - the next session reads it live.
    local clock = find_gimmick("柱時計パズル(2)")
    if clock and not G.gimmick_done(clock) then
        return { name = "the grandfather clock", pos = { x = 111.2, y = 27.3, z = 91.7 }, face = { x = 111.2, y = 28.3, z = 92.7 },
            tip = "The clock is a puzzle that opens a door behind it.",
            arrive = "You are at the grandfather clock. Tell Claude: I read the puzzle and tell you the time to set." }
    end
    return nil
end
G.ashley_part = A
-- N: Ashley's step first (outermost wrap, like flee.lua)
if not G.next_step_ashley then
    G.next_step_ashley = true
    local orig = G.next_step
    G.next_step = function(...)
        local AP = G.ashley_part
        if AP and AP.active() then
            local pos = G.player_pos()
            local ok, t = pcall(AP.step, pos)
            if ok and t then
                t.dist = math.sqrt((t.pos.x - pos.x) ^ 2 + (t.pos.z - pos.z) ^ 2)
                if t.dist < 1.0 and t.face then
                    pcall(RE4Access.route.stop, true)
                    pcall(G.face_point, t.face, true)
                    AP.current, AP.told = t, true
                    say(t.arrive, true)
                    if t.look then AP.look = { pts = t.look, i = 0, next_at = os.clock() + 2.0 } end
                    return
                end
                AP.current, AP.told = t, false
                local ex = RE4Access.explore and RE4Access.explore.explore
                say("Next: " .. t.name .. ", " .. math.floor(t.dist + 0.5) .. " meters, " .. G.describe_position(t.pos, pos, G.facing()) .. ". " .. t.tip, true)
                G.select(t)
                if not ex then pcall(RE4Access.route.go, t) end
                return
            end
            if not ok then log.info("[RE4Access] ashley step error: " .. tostring(t)) end
            say("Ashley's part: I have not mapped this spot yet. Tell Claude where you are, and look around with Semicolon.", true)
            return
        end
        return orig(...)
    end
end
-- Ashley has no gun: the aim lock's "No enemy in sight" on every L (lantern raise) is noise.
-- 11/14 11:15 user: "a lot of misinformation" after reloading as Ashley: Leon's trail line
-- ("No more of the trail is known ... away from the gate"), "Got 7450 pesetas" (Leon's money
-- re-counted on load; Ashley carries none) and "the the" in F-search lines. While the player
-- body is Ashley (ch0a1z0_body) those Leon-only lines are dropped.
function RE4Access.is_ashley()
    local ok, n = pcall(function()
        return sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_BodyGameObject"):call("get_Name")
    end)
    return ok and n == "ch0a1z0_body"
end
local ASHLEY_DROP = { "^No enemy in sight", "^No more of the trail is known", "^Got [%d,]+ pesetas", "^Follow the trail", "^Next: the trail" }
local function ashley_filter(text)
    if type(text) ~= "string" then return text end
    text = text:gsub("the the ", "the ")
    -- 14:20 live: "Low passage ahead. Press E to crouch" was repeated while Ashley was already
    -- crouched; pressing E again stood her up (Crouching / Standing up / Crouching ...) and she
    -- stuck in the debris. Already crouched: just keep holding W.
    if text:find("^Low passage ahead") then
        local ok, c = pcall(function() return sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_IsCrouch") end)
        if ok and c then return "Low passage. You are crouched: keep holding W, do not press E." end
    end
    if RE4Access.is_ashley() then
        for _, pat in ipairs(ASHLEY_DROP) do if text:find(pat) then return nil end end
    end
    return text
end
RE4Access.ashley_filter_fn = ashley_filter
if not RE4Access.ashley_speak_filter2 then
    RE4Access.ashley_speak_filter2 = true
    local orig_speak = RE4Access.speak
    RE4Access.speak = function(text, ...)
        local f = RE4Access.ashley_filter_fn
        if f then text = f(text) end
        if text == nil then return end
        return orig_speak(text, ...)
    end
end
-- 11/14 user: "I need to know when I am crouched". Speak crouch changes (Leon and Ashley).
if not RE4Access.crouch_watch then
    RE4Access.crouch_watch = { at = 0, last = nil }
    re.on_frame(function()
        local cw = RE4Access.crouch_watch
        local now = os.clock()
        if now - cw.at < 0.2 then return end
        cw.at = now
        pcall(function()
            local c = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_IsCrouch")
            if cw.last ~= nil and c ~= cw.last then RE4Access.speak(c and "Crouching." or "Standing up.", true) end
            cw.last = c
        end)
    end)
end
-- on arrival: turn to face the thing and say what to do (once)
if not RE4Access.ashley_part_frame then
    RE4Access.ashley_part_frame = true
    re.on_frame(function()
        pcall(function()
            local AP = RE4Access.game.ashley_part
            -- camera look-around (eye level, 1.5 s per spot) - see the library door step
            local lk = AP and AP.look
            if lk and os.clock() >= lk.next_at then
                lk.i = lk.i + 1
                local q = lk.pts[lk.i]
                if q then
                    pcall(RE4Access.game.face_item, q)
                    lk.next_at = os.clock() + 1.5
                    log.info(string.format("[RE4Access] look-around %d at (%.1f,%.1f,%.1f)", lk.i, q.x, q.y, q.z))
                else AP.look = nil end
            end
            local t = AP and AP.current
            if not t or AP.told then return end
            if not AP.active() then AP.current = nil return end
            local pos = RE4Access.game.player_pos()
            if not pos then return end
            if math.sqrt((t.pos.x - pos.x) ^ 2 + (t.pos.z - pos.z) ^ 2) < 0.9 then
                AP.told = true
                pcall(RE4Access.route.stop, true)
                if t.face then pcall(RE4Access.game.face_point, t.face, true) end
                RE4Access.speak("Stop, let go of W. " .. t.arrive, true)
                log.info("[RE4Access] ashley part: arrived at " .. t.name)
                if t.look then AP.look = { pts = t.look, i = 0, next_at = os.clock() + 2.5 } end
            end
        end)
    end)
end
end

-- 11/14 user: "so tired of hearing" the F-angle search talk. The search still runs; it is
-- silent while looking, and a miss is one short line. "F ready" still speaks.
if not RE4Access.fangle_quiet then
    RE4Access.fangle_quiet = true
    local orig_speak = RE4Access.speak
    RE4Access.speak = function(text, ...)
        if type(text) == "string" then
            if text:find("^Finding the F angle") then return end
            if text:find("^No F angle found here") or (text:find("^No F on the ") and text:find("from here")) then
                text = "No F here."
            end
        end
        return orig_speak(text, ...)
    end
end

-- 11/14 Ashley part: grandfather clock puzzles (chainsaw.GmWallClock, gm84_777). Live fields
-- NowHour / NowMinute; get_CorrectTime() = the answer for this difficulty (11:04 here; the
-- candidates are 11:04 and 7:00 = Hardcore/Professional). While a hand moves, the mod speaks
-- the time the clock shows and how far it is from the right time. The clock-room clock is
-- also the speedrun shortcut past the library (only optional treasures are missed).
do
local W = { at = 0, last = nil, said_target = false }
RE4Access.wallclock = W
local function nearest_clock(pos)
    local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
    if not gm or not pos then return nil end
    local best, bd
    for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
        local core = e:get_field("value")
        if core then pcall(function()
            local go = core:call("get_GameObject")
            local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmWallClock"))
            if not c then return end
            local q = go:call("get_Transform"):call("get_Position")
            local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
            if d < 4 and math.abs(q.y - pos.y) < 3 and (not bd or d < bd) then best, bd = c, d end
        end) end
    end
    return best
end
function W.correct(c)
    local h, m = 11, 4
    pcall(function() local t = c:call("get_CorrectTime"); h, m = t:get_field("_Hour"), t:get_field("_Minute") end)
    return h, m
end
function W.text(h, m) return string.format("%d:%02d", h, m) end
re.on_frame(function()
    if RE4Access.wallclock ~= W then return end
    local now = os.clock()
    if now - W.at < 0.25 then return end
    W.at = now
    pcall(function()
        local G = RE4Access.game
        local c = nearest_clock(G.player_pos())
        if not c then W.last = nil W.said_target = false return end
        local h, m = c:get_field("NowHour"), c:get_field("NowMinute")
        local key = h * 60 + m
        if W.last == nil then W.last = key return end
        if key == W.last then return end
        W.last = key
        local ch, cm = W.correct(c)
        local s = W.text(h, m)
        if h == ch and m == cm then s = s .. ". That is the right time! Confirm it."
        else
            local d = (ch * 60 + cm) - key
            if d < -360 then d = d + 720 elseif d > 360 then d = d - 720 end
            s = s .. (d > 0 and (". " .. d .. " minutes too early") or (". " .. -d .. " minutes too late"))
        end
        if not W.said_target then W.said_target = true s = s .. ". Set it to " .. W.text(ch, cm) .. "." end
        RE4Access.speak(s, true)
        log.info("[RE4Access] wall clock " .. s)
    end)
end)
end

-- 11/14 user (Ashley died at the basement elevator button, armor knight behind her): "can I
-- get a warning when the elevator arrives". Any chainsaw.GmElevator within 15 m: its car
-- (the gimmick's transform) is followed; while it moves "Elevator coming", and when it stops
-- level with the player "Elevator is here. Walk in with W." (once per arrival).
do
local E = { at = 0, cars = {} }
RE4Access.elevwatch = E
re.on_frame(function()
    if RE4Access.elevwatch ~= E then return end
    local now = os.clock()
    if now - E.at < 0.3 then return end
    E.at = now
    pcall(function()
        local G = RE4Access.game
        local pos = G.player_pos(); if not pos then return end
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject")
                local el = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmElevator"))
                if not el then return end
                local q = go:call("get_Transform"):call("get_Position")
                if math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) > 15 then return end
                -- the car is the child "Box" (11/14 live: root stays at the bottom, y 13.14,
                -- while Box was at the top, y 19.02, and nothing was said)
                local ch = go:call("get_Transform"):call("get_Child")
                while ch do
                    if ch:call("get_GameObject"):call("get_Name") == "Box" then q = ch:call("get_Position") break end
                    ch = ch:call("get_Next")
                end
                local key = go:get_address()
                local c = E.cars[key]
                if not c then E.cars[key] = { y = q.y, moving = false, here = math.abs(q.y - pos.y) < 0.6 } return end
                local dy = q.y - c.y
                c.y = q.y
                if math.abs(dy) > 0.02 then
                    if not c.moving then
                        c.moving = true
                        c.here = false
                        local toward = (pos.y - q.y) * dy > 0
                        RE4Access.speak(toward and "Elevator coming." or "Elevator moving.", false)
                    end
                elseif c.moving then
                    c.moving = false
                    if math.abs(q.y - pos.y) < 0.8 and not c.here then
                        c.here = true
                        RE4Access.speak("Elevator is here. Press N.", true)
                        log.info(string.format("[RE4Access] elevator arrived at y %.1f", q.y))
                    else
                        log.info(string.format("[RE4Access] elevator stopped at y %.1f (player y %.1f)", q.y, pos.y))
                    end
                end
            end) end
        end
    end)
end)
end

-- 11/14 PM replay: Leon kept "Blocked" at (120.1,24.1,14.8), wedged between the centaur
-- statue gm84_676 (122.4,15.5) and the wall, the route's first point (121,15) being the
-- statue's corner. Open floor is to the south: walk there first, then on to the Lion Head.
do
local G = RE4Access.game
if not G.ch9_step_before_statueby then G.ch9_step_before_statueby = G.ch9_step end
G.ch9_step = function(pos)
    local t = G.ch9_step_before_statueby(pos)
    if t and pos and t.pos and math.abs(pos.y - 24.1) < 0.6 and pos.x > 118.5 and pos.x < 122.5 and pos.z > 13.6 and pos.z < 16.4
        and t.pos.z < 12 then
        return { name = "away from the statue, south", pos = { x = 119.3, y = 24.1, z = 11.2 }, dist = math.sqrt((119.3 - pos.x) ^ 2 + (11.2 - pos.z) ^ 2),
            tip = "You are wedged beside the big statue. First a few steps south, away from it.",
            after = "Now press N again.", fname = "Spot", spoken = "spot", no_f = true }
    end
    return t
end
end

-- 11/14 5:25PM: look-around spots (camera LookAt events, see library door). Each spot: stand
-- still 1.5 s within 1.3 m -> camera looks at its points at eye level, 1.5 s each, once per
-- visit. Spot 2: in front of the pottery shelf gm82_549 inside the library (129.4,78.6).
do
local L = { state = {}, cur = nil }
RE4Access.lookwatch = L   -- replaces the first watcher (it checks RE4Access.lookwatch ~= its own table)
local SPOTS = {
    { at = { x = 123.8, z = 79.2 }, pts = { { x = 126.6, y = 28.7, z = 79.0 }, { x = 126.0, y = 28.7, z = 81.5 }, { x = 126.0, y = 28.7, z = 76.5 }, { x = 128.5, y = 28.9, z = 79.0 }, { x = 126.6, y = 28.7, z = 79.0 } } },
    { at = { x = 129.4, z = 78.6 }, pts = { { x = 130.5, y = 28.6, z = 78.2 }, { x = 132.5, y = 28.7, z = 80.5 }, { x = 132.5, y = 28.7, z = 84.8 }, { x = 131.4, y = 28.7, z = 90.0 }, { x = 130.5, y = 28.6, z = 78.2 } } },
}
RE4Access.look_spots = SPOTS
re.on_frame(function()
    if RE4Access.lookwatch ~= L then return end
    pcall(function()
        local G = RE4Access.game
        local pos = G.player_pos(); if not pos then return end
        local now = os.clock()
        if L.cur then
            local c = L.cur
            if now >= c.next_at then
                c.i = c.i + 1
                local q = c.spot.pts[c.i]
                if not q then L.state[c.idx] = "done" L.cur = nil RE4Access.speak("Done looking.", true) log.info("[RE4Access] look-around done, spot " .. c.idx) return end
                G.face_item(q)
                c.next_at = now + 1.5
                log.info(string.format("[RE4Access] look-around spot %d point %d at (%.1f,%.1f,%.1f)", c.idx, c.i, q.x, q.y, q.z))
            end
            return
        end
        if G.state_text ~= "In control" then L.since = nil return end
        for idx, sp in ipairs(SPOTS) do
            local d = math.sqrt((pos.x - sp.at.x) ^ 2 + (pos.z - sp.at.z) ^ 2)
            if d > 4 then L.state[idx] = nil end
            if d < 1.3 and L.state[idx] ~= "done" then
                if L.last and math.abs(L.last.x - pos.x) + math.abs(L.last.z - pos.z) > 0.05 then L.since = nil end
                L.since = L.since or now
                L.last = pos
                if now - L.since > 1.5 then
                    L.cur = { idx = idx, spot = sp, i = 0, next_at = now }
                    L.since = nil
                    RE4Access.speak("Looking around.", true)
                end
                return
            end
        end
    end)
end)
end

-- 11/14 6PM: Bunch of Keys locks (chainsaw.GmKeyBundleAttachment): _CorrectKey (0-based),
-- _CurrentSelectKeyNum while choosing, _CurrentPhase. Live: lobby elevator "Keys" (130.8,65.5)
-- correct 2 = 3rd key; perfume chest ② (127.4,81.7) correct 1 = 2nd key; Sapphire chest ③
-- (123.6,34.4,53.8) correct 3 = 4th key. While Ashley uses one (phase not 0) the mod says the
-- key she is on and when it is the right one.
do
local K = { at = 0, last = {} }
RE4Access.keypick = K
re.on_frame(function()
    if RE4Access.keypick ~= K then return end
    local now = os.clock()
    if now - K.at < 0.2 then return end
    K.at = now
    pcall(function()
        local G = RE4Access.game
        local pos = G.player_pos(); if not pos then return end
        local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
        for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
            local core = e:get_field("value")
            if core then pcall(function()
                local go = core:call("get_GameObject")
                local c = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.GmKeyBundleAttachment"))
                if not c then return end
                local q = go:call("get_Transform"):call("get_Position")
                if math.abs(q.x - pos.x) > 4 or math.abs(q.z - pos.z) > 4 then return end
                local key = go:get_address()
                local phase, cur, cor = c:get_field("_CurrentPhase"), c:get_field("_CurrentSelectKeyNum"), c:get_field("_CorrectKey")
                local st = tostring(phase) .. ":" .. tostring(cur)
                if K.last[key] ~= st then
                    local was = K.last[key]
                    K.last[key] = st
                    if was == nil and phase == 0 then return end
                    if phase ~= 0 then
                        local s = "Key " .. (cur + 1) .. "."
                        if cur == cor then s = s .. " That is the right key. Press F." else s = s .. " The right one is key " .. (cor + 1) .. ". Turn with A or D." end
                        RE4Access.speak(s, true)
                        log.info("[RE4Access] key pick " .. s)
                    end
                end
            end) end
        end
    end)
end)
end

-- 11/14 6:40PM (Claude playing the return run): crouched in the low gap behind the crest
-- grate (x 51.5-59.9, z 105-112, y 11-13.5) the route has no walking way, so W went into the
-- wall. While Ashley is crouched there the mod keeps the camera pointed along the gap: east
-- (out, toward the gong hall) when she carries the insignia, west (in) before. Hold W.
do
local GS = { at = 0, said = false }
RE4Access.gapsteer = GS
re.on_frame(function()
    if RE4Access.gapsteer ~= GS then return end
    local now = os.clock()
    if now - GS.at < 0.4 then return end
    GS.at = now
    pcall(function()
        local G = RE4Access.game
        local pos = G.player_pos(); if not pos then return end
        -- (also: how long Ashley has stood at the basement elevator switch, for N)
        local AP = G.ashley_part
        if AP then
            local dsw = math.sqrt((pos.x - 87.6) ^ 2 + (pos.z - 108.6) ^ 2)
            if dsw < 1.2 then AP.sw_first = AP.sw_first or now elseif dsw > 3 and pos.x < 88.9 then AP.sw_first = nil end
        end
        local inside = pos.y > 11 and pos.y < 13.5 and pos.x > 51.0 and pos.x < 59.9 and pos.z > 105 and pos.z < 112
        local crouched = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_IsCrouch")
        if not (inside and crouched) then GS.said = false return end
        local out = G.ashley_part and G.ashley_part.reached and G.ashley_part.reached.insignia
        local tx = out and 62.5 or 49.5
        G.face_item({ x = tx, y = pos.y + 0.4, z = 108.4 })
        if not GS.said then
            GS.said = true
            RE4Access.speak("In the low gap. Hold W, I keep you pointed " .. (out and "east, out to the gong hall." or "west, to the mausoleum."), true)
        end
    end)
end)
end

-- 11/14 Can't die (Shift+U, owner builds only): while on, the player character (Leon, or
-- Ashley in her part) gets the game's own HitPoint flags Invincible / NoDeath / Immortal every
-- frame; off = the flags are cleared once.
do
local CD = { at = 0, was = false }
RE4Access.cantdie = CD
re.on_frame(function()
    if RE4Access.cantdie ~= CD then return end
    local now = os.clock()
    if now - CD.at < 0.2 then return end
    CD.at = now
    pcall(function()
        local G = RE4Access.game
        local on = G and G.cant_die and true or false
        if not on and not CD.was then return end
        local hp = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("getPlayerContextRef"):call("get_HitPoint")
        if not hp then return end
        hp:call("set_Invincible", on)
        hp:call("set_NoDeath", on)
        hp:call("set_Immortal", on)
        CD.was = on
    end)
end)
end

-- 11/14 7:20PM Chapter 10 read-ahead (TheGamer / Push Square / PowerPyx summaries, NOT checked
-- in the game yet; areas past the Grand Hall were not loaded). Spoken when N has no exact spot.
do
local G = RE4Access.game
local add = {
    { "throne room", "Chapter 10. The Merchant beside the Chimera door has a request, Merciless Knight, a gold armor knight in the mausoleum, optional. Ashley's treasures (Elegant Perfume Bottle, Emerald, Sapphire) lie just south of the cage, by the door. Way on: east, through the double doors past the Chimera statue. The folding ladder is only an optional shortcut from the floor above. Giant bugs attack, the shotgun works. The main door ahead is locked: hop the railing on the left, kill two more bugs, climb the stairs. In the big room, a First Aid Spray in the glass cabinet left of the entrance; leave by the door on the right. Down the stairs a swarm of bugs comes: fight them from under the stairs. Then the ballroom: the gate at the far east end needs two levers, one on the upper balcony at the end, one at the stairs on the south side. Next, a drawbridge: shoot two counterweights, the second one is hidden low, step left to reach it. Then the antechamber: two Garradors, they are blind and follow sound, plus zealots. Shoot a bell: a Garrador charges it and gets stuck, then hit the parasite on its back. Each Garrador drops a Unicorn Horn: put both horns in the statues on each side of the gate at the back. That gate is the throne room." },
    { "to the surface", "Chapter 10, the depths under the castle. Follow the water path, insect enemies hide in the water. A crack in a wall with light behind it: break through, an Elegant Crown lies on a body there. Climb the ladder, then the sewers: the Merchant and a typewriter. Then the laboratory: pull the lever in the first side room, then the power switch in the far right corner of the square room. Verdugo attacks: run to a green switch on the wall, it sprays liquid nitrogen and freezes him, then hit him. Turn the wheel on the exit door and head to the elevator. You can freeze him at the nitrogen showers on the way, or just survive until the elevator arrives and get in. That ends the chapter." },
}
for i = #add, 1, -1 do table.insert(G.OBJECTIVE_HINTS, 1, add[i]) end
end

-- 11/14 7:25PM Chapter 10 start (Leon, "Head for the throne room"): the first step is the
-- drop-down ladder gm84_850 大廊下のおろしハシゴ (128.2,27.3,34.3) back to the Grand Hall
-- (route known, 10 m from the cage). Past it the areas were not loaded yet: N falls back to the
-- normal objective guidance plus the spoken Chapter 10 read-ahead.
do
local G = RE4Access.game
if not G.next_step_ch10 then
    G.next_step_ch10 = true
    local orig = G.next_step
    G.next_step = function(...)
        local ok0, handled = pcall(function()
            local obj = tostring(G.objective_text() or ""):lower()
            if not obj:find("throne room", 1, true) then return false end
            local pos = G.player_pos(); if not pos then return false end
            local lad
            local gm = sdk.get_managed_singleton("chainsaw.GimmickManager")
            for _, e in ipairs(gm:get_field("_Core"):get_field("_entries"):get_elements()) do
                local core = e:get_field("value")
                if core and not lad then pcall(function()
                    local go = core:call("get_GameObject")
                    if go:call("get_Name"):find("gm84_850", 1, true) then lad = go end
                end) end
            end
            if not lad or G.gimmick_done(lad) then return false end
            -- 11/15: the ladder hangs from the upper corridor (TopPosObj y 31.75); it can only
            -- be kicked down from up there and is an optional shortcut. From the Grand Hall
            -- floor (y 27.25) "No F here". Only offer it when Leon is up top.
            if pos.y < 30 then return false end
            local q = lad:call("get_Transform"):call("get_Position")
            if math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2) > 40 then return false end
            local t = { name = "the ladder down to the Grand Hall", pos = { x = q.x, y = q.y, z = q.z }, go = lad,
                tip = "Chapter 10 starts here. Press F at the ladder to kick it down, then climb down." }
            local d = math.sqrt((q.x - pos.x) ^ 2 + (q.z - pos.z) ^ 2)
            if d < 1.3 then
                pcall(RE4Access.route.stop, true)
                RE4Access.speak("The ladder is here. Press F to kick it down, then F again to climb down. Then press N.", true)
                return true
            end
            RE4Access.speak("Next: " .. t.name .. ", " .. math.floor(d + 0.5) .. " meters. " .. t.tip, true)
            G.select(t)
            pcall(RE4Access.route.go, t)
            return true
        end)
        if ok0 and handled then return end
        return orig(...)
    end
end
end

-- 11/14 7:40PM user: in Ashley's part the armor knights came from the side and behind, the
-- lantern only freezes the one in front. LANTERN GUARD (Ashley only):
--  1. Warning: an awake enemy within 6 m that is coming closer and is NOT in front of Ashley
--     -> "Knight behind left, 4 meters. Hold L." (once per enemy per 4 s).
--  2. Hold L (raise the lantern): the mod turns Ashley's view to the nearest awake enemy within
--     8 m, every 0.25 s, so the light hits it. Says "Lantern on knight, left" when the target
--     changes. Let go of L and hold it again to switch to the next one.
do
local LG = { at = 0, last = {}, said_at = {}, target = nil }
RE4Access.lanternguard = LG
local function awake_enemies(pos)
    local out = {}
    local list = sdk.get_managed_singleton("chainsaw.CharacterManager"):call("get_EnemyContextList")
    if not list then return out end
    for i = 0, list:call("get_Count") - 1 do
        pcall(function()
            local ctx = list:call("get_Item", i)
            local live = true
            pcall(function() live = ctx:call("get_HitPoint"):call("get_IsLive") end)
            if live == false then return end
            local tn = ctx:get_type_definition():get_name()
            if tn:find("^Ch8g") then return end
            if tn:find("^Ch1d6") and (ctx:get_field("<TargetFindState>k__BackingField") or 0) == 0 then return end
            local p = ctx:call("get_Position")
            local d = math.sqrt((p.x - pos.x) ^ 2 + (p.z - pos.z) ^ 2)
            if d <= 9 and math.abs(p.y - pos.y) < 2.5 then out[#out + 1] = { key = ctx:get_address(), pos = { x = p.x, y = p.y, z = p.z }, dist = d, knight = tn:find("^Ch1d6") ~= nil } end
        end)
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end
re.on_frame(function()
    if RE4Access.lanternguard ~= LG then return end
    local now = os.clock()
    if now - LG.at < 0.25 then return end
    LG.at = now
    pcall(function()
        if not RE4Access.is_ashley() then LG.target = nil return end
        local G = RE4Access.game
        local pos = G.player_pos(); if not pos then return end
        local list = awake_enemies(pos)
        local held = G.aim_held()
        if held then
            local e = list[1]
            if e and e.dist <= 8 then
                G.face_item({ x = e.pos.x, y = e.pos.y + 1.3, z = e.pos.z })
                if LG.target ~= e.key then
                    LG.target = e.key
                    local where = (G.describe_position(e.pos, pos, G.facing()) or ""):gsub("^[%d%.]+ meters?, ", "")
                    RE4Access.speak("Lantern on " .. (e.knight and "knight" or "enemy") .. ", " .. where .. ", " .. math.floor(e.dist + 0.5) .. " meters.", true)
                    log.info("[RE4Access] lantern guard: turned to " .. tostring(e.key) .. " " .. where)
                end
            end
            return
        end
        LG.target = nil
        local facing = G.facing()
        for _, e in ipairs(list) do
            local prev = LG.last[e.key]
            LG.last[e.key] = e.dist
            if e.dist <= 6 and prev and e.dist < prev - 0.05 and facing then
                local dx, dz = e.pos.x - pos.x, e.pos.z - pos.z
                local where = (G.describe_position(e.pos, pos, facing) or ""):gsub("^[%d%.]+ meters?, ", "")
                local front = where:find("^ahead") and not where:find("left") and not where:find("right")
                if not front and now - (LG.said_at[e.key] or -99) > 4 then
                    LG.said_at[e.key] = now
                    RE4Access.speak((e.knight and "Knight " or "Enemy ") .. where .. ", " .. math.floor(e.dist + 0.5) .. " meters. Hold L.", true)
                end
            end
        end
    end)
end)
end

return G
