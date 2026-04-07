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

-- Hand-type containment tables for joker conditions
local contains_pair = {
    ["Pair"] = true, ["Two Pair"] = true, ["Three of a Kind"] = true,
    ["Full House"] = true, ["Four of a Kind"] = true, ["Five of a Kind"] = true,
    ["Flush House"] = true, ["Flush Five"] = true,
}
local contains_three = {
    ["Three of a Kind"] = true, ["Full House"] = true,
    ["Four of a Kind"] = true, ["Five of a Kind"] = true,
    ["Flush House"] = true, ["Flush Five"] = true,
}
local contains_four = {
    ["Four of a Kind"] = true, ["Five of a Kind"] = true, ["Flush Five"] = true,
}
local contains_straight = {
    ["Straight"] = true, ["Straight Flush"] = true, ["Royal Flush"] = true,
}
local contains_flush = {
    ["Flush"] = true, ["Straight Flush"] = true, ["Royal Flush"] = true,
    ["Flush House"] = true, ["Flush Five"] = true,
}
local contains_two_pair = {
    ["Two Pair"] = true, ["Full House"] = true, ["Flush House"] = true,
}

local fib_ranks = { [2] = true, [3] = true, [5] = true, [8] = true, [14] = true }

local function count_suits(cards)
    local counts = { Hearts = 0, Diamonds = 0, Clubs = 0, Spades = 0 }
    for _, card in ipairs(cards) do
        if not card.debuff then
            if card.ability and card.ability.name == "Wild Card" then
                for s, _ in pairs(counts) do
                    counts[s] = counts[s] + 1
                end
            else
                local suit = card.base.suit
                if counts[suit] then
                    counts[suit] = counts[suit] + 1
                end
            end
        end
    end
    return counts
end

local function count_ranks(cards)
    local face, ace, fib, even, odd = 0, 0, 0, 0, 0
    for _, card in ipairs(cards) do
        if not card.debuff then
            local id = card.base.id
            if id >= 11 and id <= 13 then face = face + 1 end
            if id == 14 then ace = ace + 1 end
            if fib_ranks[id] then fib = fib + 1 end
            if id >= 2 and id <= 10 and id % 2 == 0 then even = even + 1 end
            if id == 14 or (id >= 1 and id <= 10 and id % 2 == 1) then odd = odd + 1 end
        end
    end
    return { face = face, ace = ace, fib = fib, even = even, odd = odd }
end

local function apply_jokers(chips, mult, cards, hand_name, all_cards, played)
    if not G.jokers or not G.jokers.cards then return chips, mult end

    local suits = count_suits(cards)
    local ranks = count_ranks(cards)
    local num_played = #cards

    for _, joker in ipairs(G.jokers.cards) do
        if not joker.debuff then
            local ability = joker.ability or {}
            local name = ability.name or ""

            -----------------------------------------------
            -- Tier 1: Always-apply and game-state jokers
            -----------------------------------------------
            if name == "Joker" then
                mult = mult + 4
            elseif name == "Greedy Joker" then
                mult = mult + 3 * suits.Diamonds
            elseif name == "Lusty Joker" then
                mult = mult + 3 * suits.Hearts
            elseif name == "Wrathful Joker" then
                mult = mult + 3 * suits.Spades
            elseif name == "Gluttonous Joker" then
                mult = mult + 3 * suits.Clubs
            elseif name == "Half Joker" then
                if num_played <= 3 then mult = mult + 20 end
            elseif name == "Banner" then
                local discards = (G.GAME.current_round and G.GAME.current_round.discards_left) or 0
                chips = chips + 30 * discards
            elseif name == "Mystic Summit" then
                local discards = (G.GAME.current_round and G.GAME.current_round.discards_left) or 0
                if discards == 0 then mult = mult + 15 end
            elseif name == "Abstract Joker" then
                mult = mult + 3 * #G.jokers.cards
            elseif name == "Stuntman" then
                chips = chips + 250
            elseif name == "Supernova" then
                local times = (G.GAME.hands[hand_name] and G.GAME.hands[hand_name].played) or 0
                mult = mult + times
            elseif name == "Acrobat" then
                local hands = (G.GAME.current_round and G.GAME.current_round.hands_left) or 0
                if hands == 1 then mult = mult * 3 end
            elseif name == "Bootstraps" then
                local dollars = G.GAME.dollars or 0
                mult = mult + 2 * math.floor(dollars / 5)
            elseif name == "Blackboard" then
                local all_dark = true
                for _, c in ipairs(all_cards) do
                    if not played[c] and not c.debuff then
                        local suit = c.base.suit
                        if suit ~= "Spades" and suit ~= "Clubs" then
                            all_dark = false
                            break
                        end
                    end
                end
                if all_dark then mult = mult * 3 end
            elseif name == "Raised Fist" then
                local lowest = math.huge
                for _, c in ipairs(all_cards) do
                    if not played[c] and not c.debuff then
                        local id = c.base.id
                        if id < lowest then lowest = id end
                    end
                end
                if lowest < math.huge then
                    mult = mult + 2 * lowest
                end

            -- Jokers with accumulated/dynamic values
            elseif name == "Green Joker" then
                mult = mult + (ability.mult or 0)
            elseif name == "Red Card" then
                mult = mult + (ability.mult or 0)
            elseif name == "Popcorn" then
                mult = mult + (ability.mult or 0)
            elseif name == "Ceremonial Dagger" then
                mult = mult + (ability.mult or 0)
            elseif name == "Ride the Bus" then
                mult = mult + (ability.mult or 0)
            elseif name == "Obelisk" then
                mult = mult * (ability.x_mult or 1)
            elseif name == "Ice Cream" then
                chips = chips + (ability.extra and ability.extra.chips or 0)
            elseif name == "Runner" then
                chips = chips + (ability.chips or 0)
            elseif name == "Loyalty Card" then
                -- x4 mult every 4 hands; read current state
                if ability.remaining == 0 then
                    mult = mult * (ability.x_mult or 4)
                end
            elseif name == "Flash Card" then
                mult = mult + (ability.mult or 0)
            elseif name == "Spare Trousers" then
                mult = mult + (ability.mult or 0)
            elseif name == "Castle" then
                chips = chips + (ability.extra and ability.extra.chips or ability.chips or 0)
            elseif name == "Wee Joker" then
                chips = chips + (ability.extra and ability.extra.chips or ability.chips or 0)
            elseif name == "Erosion" then
                mult = mult + (ability.mult or 0)

            -----------------------------------------------
            -- Tier 2: Hand-type conditional jokers
            -----------------------------------------------
            elseif name == "Jolly Joker" then
                if contains_pair[hand_name] then mult = mult + 8 end
            elseif name == "Zany Joker" then
                if contains_three[hand_name] then mult = mult + 12 end
            elseif name == "Mad Joker" then
                if contains_two_pair[hand_name] then mult = mult + 10 end
            elseif name == "Crazy Joker" then
                if contains_straight[hand_name] then mult = mult + 12 end
            elseif name == "Droll Joker" then
                if contains_flush[hand_name] then mult = mult + 10 end
            elseif name == "Sly Joker" then
                if contains_pair[hand_name] then chips = chips + 50 end
            elseif name == "Wily Joker" then
                if contains_three[hand_name] then chips = chips + 100 end
            elseif name == "Clever Joker" then
                if contains_two_pair[hand_name] then chips = chips + 80 end
            elseif name == "Devious Joker" then
                if contains_straight[hand_name] then chips = chips + 100 end
            elseif name == "Crafty Joker" then
                if contains_flush[hand_name] then chips = chips + 80 end
            elseif name == "The Duo" then
                if contains_pair[hand_name] then mult = mult * 2 end
            elseif name == "The Trio" then
                if contains_three[hand_name] then mult = mult * 2 end
            elseif name == "The Family" then
                if contains_four[hand_name] then mult = mult * 2 end
            elseif name == "The Order" then
                if contains_straight[hand_name] then mult = mult * 2 end
            elseif name == "The Tribe" then
                if contains_flush[hand_name] then mult = mult * 2 end

            -----------------------------------------------
            -- Tier 3: Card-specific conditional jokers
            -----------------------------------------------
            elseif name == "Fibonacci" then
                mult = mult + 8 * ranks.fib
            elseif name == "Scary Face" then
                chips = chips + 30 * ranks.face
            elseif name == "Scholar" then
                chips = chips + 20 * ranks.ace
                mult = mult + 4 * ranks.ace
            elseif name == "Even Steven" then
                mult = mult + 4 * ranks.even
            elseif name == "Odd Todd" then
                chips = chips + 31 * ranks.odd
            elseif name == "Photograph" then
                if ranks.face > 0 then mult = mult * 2 end
            elseif name == "Walkie Talkie" then
                -- +10 chips and +4 mult per 10 or 4 played
                for _, card in ipairs(cards) do
                    if not card.debuff then
                        local id = card.base.id
                        if id == 10 or id == 4 then
                            chips = chips + 10
                            mult = mult + 4
                        end
                    end
                end
            elseif name == "Smiley Face" then
                mult = mult + 5 * ranks.face
            elseif name == "Golden Joker" then
                -- $4 at end of round (money, not score) — skip
            end

            -- Joker edition bonuses
            local edition = joker.edition
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

    return chips, mult
end

-- Determine which cards actually score for a given hand type.
-- Kicker cards (e.g. 5th card in Two Pair) do NOT contribute chips.
local function get_scoring_cards(cards, hand_name)
    -- Hands where all cards score
    if hand_name == "Flush" or hand_name == "Straight" or hand_name == "Straight Flush"
        or hand_name == "Royal Flush" or hand_name == "Full House"
        or hand_name == "Flush House" or hand_name == "Flush Five"
        or hand_name == "Five of a Kind" then
        return cards
    end

    -- Group cards by rank id
    local by_rank = {}
    for _, card in ipairs(cards) do
        local id = card.base.id
        if not by_rank[id] then by_rank[id] = {} end
        by_rank[id][#by_rank[id] + 1] = card
    end

    -- Sort groups by size descending, then by rank descending for ties
    local groups = {}
    for id, group in pairs(by_rank) do
        groups[#groups + 1] = { id = id, cards = group, count = #group }
    end
    table.sort(groups, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.id > b.id
    end)

    local scoring = {}

    if hand_name == "Four of a Kind" then
        for _, g in ipairs(groups) do
            if g.count >= 4 then
                for i = 1, 4 do scoring[#scoring + 1] = g.cards[i] end
                break
            end
        end
    elseif hand_name == "Three of a Kind" then
        for _, g in ipairs(groups) do
            if g.count >= 3 then
                for i = 1, 3 do scoring[#scoring + 1] = g.cards[i] end
                break
            end
        end
    elseif hand_name == "Two Pair" then
        local pairs_found = 0
        for _, g in ipairs(groups) do
            if g.count >= 2 and pairs_found < 2 then
                scoring[#scoring + 1] = g.cards[1]
                scoring[#scoring + 1] = g.cards[2]
                pairs_found = pairs_found + 1
            end
        end
    elseif hand_name == "Pair" then
        for _, g in ipairs(groups) do
            if g.count >= 2 then
                scoring[#scoring + 1] = g.cards[1]
                scoring[#scoring + 1] = g.cards[2]
                break
            end
        end
    elseif hand_name == "High Card" then
        -- highest single card scores
        local best = nil
        for _, card in ipairs(cards) do
            if not best or card.base.id > best.base.id then
                best = card
            end
        end
        if best then scoring[#scoring + 1] = best end
    else
        -- unknown hand type: treat all as scoring
        return cards
    end

    return scoring
end

local function score_combo(cards, all_cards)
    local hand_name, _, _ = G.FUNCS.get_poker_hand_info(cards)
    if not hand_name then return nil, 0 end
    local hand_info = G.GAME.hands[hand_name]
    if not hand_info then return nil, 0 end

    local chips = hand_info.chips
    local mult = hand_info.mult

    -- build set of played cards for held-in-hand lookup
    local played = {}
    for _, card in ipairs(cards) do
        played[card] = true
    end

    -- identify which cards actually form the hand (not kickers)
    local scoring = get_scoring_cards(cards, hand_name)
    local scoring_set = {}
    for _, card in ipairs(scoring) do
        scoring_set[card] = true
    end

    for _, card in ipairs(cards) do
        -- skip debuffed and non-scoring (kicker) cards
        if not card.debuff and scoring_set[card] then
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

    -- held-in-hand effects (cards NOT played)
    for _, card in ipairs(all_cards) do
        if not played[card] and not card.debuff then
            local ability = card.ability
            if ability and ability.name == "Steel Card" then
                mult = mult * 1.5
            end
        end
    end

    -- apply joker bonuses
    chips, mult = apply_jokers(chips, mult, cards, hand_name, all_cards, played)

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
                local name, score = score_combo(combo, cards)
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