local function combinations(list, k)
    local result = {}
    local function helper(start, combo)
        if #combo == k then
            result[#result + 1] = {unpack(combo)}
            return
        end
        for i = start, #list - (k - #combo) + 1 do
            combo[#combo + 1] = list[i]
            helper(i + 1, combo)
            combo[#combo] = nil
        end
    end
    helper(1, {})
    return result
end

local function score_combo(cards)
    local hand_name, _, _ = G.FUNCS.get_poker_hand_info(cards)
    if not hand_name then return nil, 0 end
    local hand_info = G.GAME.hands[hand_name]
    if not hand_info then return nil, 0 end

    local chips = hand_info.chips
    local mult = hand_info.mult

    for _, card in ipairs(cards) do
        -- skip debuffed cards entirely
        if not card.debuff then
            -- base chip value from rank
            chips = chips + (card.base.nominal or 0)

            -- enhancement bonuses
            local ability = card.ability
            if ability then
                local name = ability.name
                if name == "Bonus Card" then
                    chips = chips + 30
                elseif name == "Mult Card" then
                    mult = mult + 4
                elseif name == "Glass Card" then
                    mult = mult * 2
                elseif name == "Stone Card" then
                    chips = chips + 50
                elseif name == "Lucky Card" then
                    -- average expected value: 1 in 5 chance of +20 mult
                    mult = mult + 4
                elseif name == "Steel Card" then
                    mult = mult * 1.5
                end
                -- perma_bonus is confirmed in dump
                chips = chips + (ability.perma_bonus or 0)
            end

            -- edition bonuses
            local edition = card.edition
            if edition then
                if edition.foil then
                    chips = chips + 50
                elseif edition.holo then
                    mult = mult + 10
                elseif edition.polychrome then
                    mult = mult * 1.5
                end
            end
        end
    end

    return hand_name, chips * mult
end

local function analyze_hand()
    if not G or not G.hand or not G.hand.cards then return nil end
    local cards = G.hand.cards
    if #cards == 0 then return nil end
    local best = {}
    for size = 5, 1, -1 do
        if #cards >= size then
            for _, combo in ipairs(combinations(cards, size)) do
                local name, score = score_combo(combo)
                if name then
                    best[#best + 1] = { name = name, score = score }
                end
            end
        end
    end
    table.sort(best, function(a, b) return a.score > b.score end)
    local seen = {}
    local top = {}
    for _, entry in ipairs(best) do
        if not seen[entry.name] then
            seen[entry.name] = true
            top[#top + 1] = entry
        end
        if #top >= 3 then break end
    end
    return top
end

SMODS.Keybind({
    key_pressed = "f2",
    action = function(self)
        local results = analyze_hand()
        if not results or #results == 0 then return end
        local lines = {"", "-- Best Hands --"}
        for i, r in ipairs(results) do
            lines[#lines + 1] = i .. ". " .. r.name .. " (~" .. math.floor(r.score) .. ")"
        end
        for _, line in ipairs(lines) do print(line) end
    end
})

SMODS.Keybind({
    key_pressed = "f3",
    action = function(self)
        local out = {}
        local card = G.hand.cards[1]
        local function dump(t, prefix, depth)
            if depth > 4 then return end
            for k, v in pairs(t) do
                local key = prefix .. "." .. tostring(k)
                if type(v) == "table" then
                    dump(v, key, depth + 1)
                else
                    out[#out + 1] = key .. " = " .. tostring(v)
                end
            end
        end
        dump(card, "card", 0)
        table.sort(out)
        local path = love.filesystem.getSaveDirectory() .. "/card_dump.txt"
        local f = io.open(path, "w")
        for _, line in ipairs(out) do f:write(line .. "\n") end
        f:close()
        print("Written to " .. path)
    end
})