-- RE4 Access: says money you pick up. Pesetas go straight to the wallet, not
-- the case, and the pick-up often happens while Leon is not "in control", so
-- the item watcher missed it (10/17: 1000 Pesetas in the Chief's closet taken
-- in silence; the user thought it was still there). Watches the wallet instead.

local last, check_at = nil, 0
re.on_frame(function()
    local now = os.clock()
    if now < check_at then return end
    check_at = now + 0.5
    pcall(function()
        local ptas = sdk.get_managed_singleton("chainsaw.InventoryManager"):call("get_CurrPTAS")
        -- 11/1: loading a save reads 0, then the real amount: that is not a gain
        local loading = last == 0 and RE4Access.game and RE4Access.game.state_text ~= "In control"
        if last and ptas > last and not loading and not (RE4Access.menu and RE4Access.menu.in_shop) then
            RE4Access.speak("Got " .. (ptas - last) .. " pesetas. You have " .. ptas .. ".", false)
        end
        last = ptas
    end)
end)
return {}
