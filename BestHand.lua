-------------------------------------------------------------------------
-- BestHand.lua — Balatro mod that analyzes your hand and recommends
-- the highest-scoring play. Press F2 to evaluate; F3 to dump card data.
--
-- Scoring follows Balatro's evaluation order:
--   Phase 1: Each scoring card fires L→R (with retriggers):
--            base chips → enhancement → edition → per-card jokers
--   Phase 2: Flat joker effects fire L→R (with Blueprint/Brainstorm)
--   Phase 3: Held-in-hand effects (Steel Card, Baron, Shoot the Moon)
--            fire per held card, with Mime/Red Seal retriggers
-------------------------------------------------------------------------

-------------------------------------------------------------------------
-- Utility: generate all k-element subsets of a list
-------------------------------------------------------------------------
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

-------------------------------------------------------------------------
-- Hand-type containment tables
-- A Full House "contains" both a Pair and Three of a Kind, etc.
-- Used by conditional jokers like Jolly Joker ("if hand contains a Pair").
-------------------------------------------------------------------------
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

-- Fibonacci-rank IDs for the Fibonacci joker (Ace = id 14 counts)
local fib_ranks = { [2] = true, [3] = true, [5] = true, [8] = true, [14] = true }

-------------------------------------------------------------------------
-- Joker lookup tables (data-driven dispatch for jokers with uniform logic)
-------------------------------------------------------------------------

-- Per-card suit mult jokers: +3 mult per scoring card of the matching suit
local suit_mult_jokers = {
    ["Greedy Joker"]     = "Diamonds",
    ["Lusty Joker"]      = "Hearts",
    ["Wrathful Joker"]   = "Spades",
    ["Gluttonous Joker"] = "Clubs",
}

-- Flat jokers that are pure accumulator reads (value lives on ability.*)
local flat_add_mult = {
    ["Green Joker"] = true, ["Red Card"] = true, ["Popcorn"] = true,
    ["Ceremonial Dagger"] = true, ["Ride the Bus"] = true,
    ["Flash Card"] = true, ["Spare Trousers"] = true, ["Erosion"] = true,
    ["Fortune Teller"] = true, ["Swashbuckler"] = true,
}
local flat_x_mult = {
    ["Obelisk"] = true, ["Joker Stencil"] = true, ["Drivers License"] = true,
    ["Glass Joker"] = true, ["Madness"] = true, ["Vampire"] = true,
    ["Hologram"] = true, ["Steel Joker"] = true,
}
local flat_add_chips = {
    ["Ice Cream"] = true, ["Runner"] = true, ["Castle"] = true,
    ["Wee Joker"] = true, ["Square Joker"] = true,
}

-- Hand-type conditional jokers: fire when the played hand satisfies a
-- containment table. op is one of "chips", "mult", or "xmult".
local hand_conditional_jokers = {
    ["Jolly Joker"]   = { contains = contains_pair,     op = "mult",  amount = 8 },
    ["Zany Joker"]    = { contains = contains_three,    op = "mult",  amount = 12 },
    ["Mad Joker"]     = { contains = contains_two_pair, op = "mult",  amount = 10 },
    ["Crazy Joker"]   = { contains = contains_straight, op = "mult",  amount = 12 },
    ["Droll Joker"]   = { contains = contains_flush,    op = "mult",  amount = 10 },
    ["Sly Joker"]     = { contains = contains_pair,     op = "chips", amount = 50 },
    ["Wily Joker"]    = { contains = contains_three,    op = "chips", amount = 100 },
    ["Clever Joker"]  = { contains = contains_two_pair, op = "chips", amount = 80 },
    ["Devious Joker"] = { contains = contains_straight, op = "chips", amount = 100 },
    ["Crafty Joker"]  = { contains = contains_flush,    op = "chips", amount = 80 },
    ["The Duo"]       = { contains = contains_pair,     op = "xmult", amount = 2 },
    ["The Trio"]      = { contains = contains_three,    op = "xmult", amount = 3 },
    ["The Family"]    = { contains = contains_four,     op = "xmult", amount = 4 },
    ["The Order"]     = { contains = contains_straight, op = "xmult", amount = 3 },
    ["The Tribe"]     = { contains = contains_flush,    op = "xmult", amount = 2 },
}

-------------------------------------------------------------------------
-- suit_matches: does this card count as `target_suit`?
-- Wild Cards match every suit.
-------------------------------------------------------------------------
local function suit_matches(card, target_suit)
    if card.ability and card.ability.name == "Wild Card" then return true end
    return card.base.suit == target_suit
end

-------------------------------------------------------------------------
-- Count how many scoring cards match each suit (aggregate).
-- Wild Cards add +1 to every suit.
-- Used by flat jokers like Flower Pot that check aggregate suit presence.
-------------------------------------------------------------------------
local function count_suits(cards)
    local counts = { Hearts = 0, Diamonds = 0, Clubs = 0, Spades = 0 }
    for _, card in ipairs(cards) do
        if not card.debuff then
            if card.ability and card.ability.name == "Wild Card" then
                for s in pairs(counts) do counts[s] = counts[s] + 1 end
            else
                local suit = card.base.suit
                if counts[suit] then counts[suit] = counts[suit] + 1 end
            end
        end
    end
    return counts
end

-------------------------------------------------------------------------
-- Identify which cards participate in a flush pattern.
-- With Four Fingers only 4 cards need to share a suit, so a 5-card combo
-- may contain a kicker that doesn't match.  Returns the matching subset.
-------------------------------------------------------------------------
local function get_flush_members(cards)
    local suits = {"Hearts", "Diamonds", "Clubs", "Spades"}
    local best_suit, best_count = nil, 0
    for _, suit in ipairs(suits) do
        local count = 0
        for _, card in ipairs(cards) do
            if suit_matches(card, suit) then count = count + 1 end
        end
        if count > best_count then best_suit, best_count = suit, count end
    end
    if best_count >= #cards then return cards end
    local result = {}
    for _, card in ipairs(cards) do
        if suit_matches(card, best_suit) then result[#result + 1] = card end
    end
    return result
end

-------------------------------------------------------------------------
-- Identify which cards participate in a straight pattern.
-- Uses Balatro's hand detection so ace wrapping and Shortcut are handled.
-- Tries removing one card at a time; if the remainder is still a straight
-- the removed card is the kicker.
-------------------------------------------------------------------------
local function get_straight_members(cards)
    if #cards <= 1 then return cards end
    for i = 1, #cards do
        local subset = {}
        for j, c in ipairs(cards) do
            if j ~= i then subset[#subset + 1] = c end
        end
        local name = G.FUNCS.get_poker_hand_info(subset)
        if name and contains_straight[name] then
            return subset
        end
    end
    return cards
end

-------------------------------------------------------------------------
-- get_triggers: total number of times a card fires (always ≥ 1).
-- Retrigger sources stack MULTIPLICATIVELY in Balatro:
--   e.g. Red Seal (×2) + Hack (×2) on a 3 → 4 total triggers.
-- `card_index` is the 1-based position in the scoring card list.
-- `is_held` selects held-in-hand retrigger sources (Mime, Red Seal).
-------------------------------------------------------------------------
local function get_triggers(card, card_index, is_held)
    local triggers = 1 -- base: every card fires at least once

    -- Red Seal doubles triggers (works on both played and held cards)
    if card.seal == "Red" then
        triggers = triggers * 2
    end

    if not G.jokers or not G.jokers.cards then return triggers end

    if not is_held then
        -- Retrigger jokers for played/scoring cards
        for _, joker in ipairs(G.jokers.cards) do
            if not joker.debuff then
                local name = (joker.ability and joker.ability.name) or ""
                if name == "Hack" then
                    -- Retrigger cards ranked 2, 3, 4, or 5
                    local id = card.base.id
                    if id >= 2 and id <= 5 then triggers = triggers * 2 end
                elseif name == "Sock and Buskin" then
                    -- Retrigger face cards (J=11, Q=12, K=13)
                    if card.base.id >= 11 and card.base.id <= 13 then
                        triggers = triggers * 2
                    end
                elseif name == "Hanging Chad" then
                    -- The first scoring card fires 3 total times (+2 retriggers)
                    if card_index == 1 then triggers = triggers * 3 end
                elseif name == "Dusk" then
                    -- Retrigger all cards on the final hand of the round
                    local hands_left = (G.GAME.current_round
                        and G.GAME.current_round.hands_left) or 0
                    if hands_left == 1 then triggers = triggers * 2 end
                elseif name == "Seltzer" then
                    -- Retrigger all scored cards (temporary consumable effect)
                    triggers = triggers * 2
                end
            end
        end
    else
        -- Retrigger jokers for held-in-hand cards
        for _, joker in ipairs(G.jokers.cards) do
            if not joker.debuff then
                if (joker.ability and joker.ability.name) == "Mime" then
                    triggers = triggers * 2
                end
            end
        end
    end

    return triggers
end

-------------------------------------------------------------------------
-- Check if The Flint boss blind is active (halves base chips and mult).
-------------------------------------------------------------------------
local function is_flint_active()
    return G.GAME and G.GAME.blind and G.GAME.blind.name == "The Flint"
end

-------------------------------------------------------------------------
-- Determine which cards actually score for a given hand type.
-- Kicker cards (e.g. the 5th card in Two Pair) do NOT score,
-- UNLESS they have Stone Card enhancement (Stone Cards always score).
-- When the Splash joker is present, ALL played cards score.
-- Returns cards in their original hand order (left to right).
-------------------------------------------------------------------------
local function get_scoring_cards(cards, hand_name)
    -- Hands where every played card always participates
    if hand_name == "Full House" or hand_name == "Flush House"
        or hand_name == "Flush Five" or hand_name == "Five of a Kind" then
        return cards
    end

    -- Flush / Straight hands: with Four Fingers a combo may contain a
    -- kicker card that doesn't participate in the pattern.
    if hand_name == "Flush" or hand_name == "Straight"
        or hand_name == "Straight Flush" or hand_name == "Royal Flush" then
        local members
        if hand_name == "Flush" then
            members = get_flush_members(cards)
        elseif hand_name == "Straight" then
            members = get_straight_members(cards)
        else -- Straight Flush / Royal Flush: check flush first, then straight
            members = get_flush_members(cards)
            if #members >= #cards then
                members = get_straight_members(cards)
            end
        end
        if #members >= #cards then return cards end
        -- Build scoring set from participating cards + Stone Card kickers
        local scoring_set = {}
        for _, c in ipairs(members) do scoring_set[c] = true end
        for _, c in ipairs(cards) do
            if c.ability and c.ability.name == "Stone Card" then
                scoring_set[c] = true
            end
        end
        local result = {}
        for _, c in ipairs(cards) do
            if scoring_set[c] then result[#result + 1] = c end
        end
        return result
    end

    -- Splash joker: all played cards score regardless of hand type
    if G.jokers and G.jokers.cards then
        for _, joker in ipairs(G.jokers.cards) do
            if not joker.debuff and joker.ability
                and joker.ability.name == "Splash" then
                return cards
            end
        end
    end

    -- Group cards by rank id to identify the hand's core groups
    local by_rank = {}
    for _, card in ipairs(cards) do
        local id = card.base.id
        if not by_rank[id] then by_rank[id] = {} end
        by_rank[id][#by_rank[id] + 1] = card
    end

    -- Sort groups: largest first, highest rank breaks ties
    local groups = {}
    for id, group in pairs(by_rank) do
        groups[#groups + 1] = { id = id, cards = group, count = #group }
    end
    table.sort(groups, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.id > b.id
    end)

    -- Build a set of cards that form the hand's core pattern
    local scoring_set = {}

    if hand_name == "Four of a Kind" then
        for _, g in ipairs(groups) do
            if g.count >= 4 then
                for i = 1, 4 do scoring_set[g.cards[i]] = true end
                break
            end
        end
    elseif hand_name == "Three of a Kind" then
        for _, g in ipairs(groups) do
            if g.count >= 3 then
                for i = 1, 3 do scoring_set[g.cards[i]] = true end
                break
            end
        end
    elseif hand_name == "Two Pair" then
        local pairs_found = 0
        for _, g in ipairs(groups) do
            if g.count >= 2 and pairs_found < 2 then
                scoring_set[g.cards[1]] = true
                scoring_set[g.cards[2]] = true
                pairs_found = pairs_found + 1
            end
        end
    elseif hand_name == "Pair" then
        for _, g in ipairs(groups) do
            if g.count >= 2 then
                scoring_set[g.cards[1]] = true
                scoring_set[g.cards[2]] = true
                break
            end
        end
    elseif hand_name == "High Card" then
        -- Only the highest-ranked card scores
        local best = nil
        for _, card in ipairs(cards) do
            if not best or card.base.id > best.base.id then best = card end
        end
        if best then scoring_set[best] = true end
    else
        -- Unknown hand type: treat all as scoring
        for _, card in ipairs(cards) do scoring_set[card] = true end
    end

    -- Stone Cards always score, even as kickers — they contribute +50 chips
    for _, card in ipairs(cards) do
        if card.ability and card.ability.name == "Stone Card" then
            scoring_set[card] = true
        end
    end

    -- Return scoring cards in original hand order (left to right),
    -- which is important for Hanging Chad and Photograph
    local result = {}
    for _, card in ipairs(cards) do
        if scoring_set[card] then result[#result + 1] = card end
    end
    return result
end

-------------------------------------------------------------------------
-- Resolve Blueprint and Brainstorm into their effective joker targets.
-- Returns a list of {ability, name, edition} entries in slot order.
-- Blueprint copies the joker to its right (chained Blueprints walk
-- rightward until a real joker is found). Brainstorm copies the
-- leftmost joker.
-------------------------------------------------------------------------
local function resolve_jokers()
    if not G.jokers or not G.jokers.cards then return {} end
    local jokers = G.jokers.cards
    local resolved = {}

    for i, joker in ipairs(jokers) do
        if not joker.debuff then
            local ability = joker.ability or {}
            local name = ability.name or ""

            if name == "Blueprint" then
                -- Walk rightward past chained Blueprints to find the real target
                local target_ability = nil
                for k = i + 1, #jokers do
                    local t = jokers[k]
                    if not t.debuff and t.ability then
                        local tname = t.ability.name or ""
                        if tname == "Brainstorm" then
                            -- Brainstorm copies leftmost; resolve that instead
                            local left = jokers[1]
                            if left and left ~= t and not left.debuff
                                and left.ability
                                and left.ability.name ~= "Blueprint"
                                and left.ability.name ~= "Brainstorm" then
                                target_ability = left.ability
                            end
                            break
                        elseif tname ~= "Blueprint" then
                            target_ability = t.ability
                            break
                        end
                        -- Another Blueprint: keep walking right
                    end
                end
                if target_ability then
                    resolved[#resolved + 1] = {
                        ability = target_ability,
                        name = target_ability.name or "",
                        edition = joker.edition, -- Blueprint uses its OWN edition
                    }
                end

            elseif name == "Brainstorm" then
                -- Copy the leftmost joker (skip self if Brainstorm is first)
                local target = jokers[1]
                if target and target ~= joker and not target.debuff
                    and target.ability then
                    local tname = target.ability.name or ""
                    if tname ~= "Blueprint" and tname ~= "Brainstorm" then
                        resolved[#resolved + 1] = {
                            ability = target.ability,
                            name = tname,
                            edition = joker.edition,
                        }
                    end
                end

            else
                resolved[#resolved + 1] = {
                    ability = ability,
                    name = name,
                    edition = joker.edition,
                }
            end
        end
    end

    return resolved
end

-------------------------------------------------------------------------
-- Apply a foil/holo/polychrome edition bonus to (chips, mult).
-- Used for both card editions (Phase 1) and joker editions (Phase 2).
-------------------------------------------------------------------------
local function apply_edition(edition, chips, mult)
    if edition then
        if edition.foil then
            chips = chips + 50
        elseif edition.holo then
            mult = mult + 10
        elseif edition.polychrome then
            mult = mult * 1.5
        end
    end
    return chips, mult
end

-------------------------------------------------------------------------
-- Phase 1 helper: per-card joker effects for a single scoring card.
-- Called once per trigger (base + retriggers), in joker slot order.
-- These jokers give bonuses based on the individual card's rank/suit.
--
-- `state` carries cross-card flags:
--   state.photo_used — prevents Photograph from firing on subsequent
--                      face cards (only the first face card gets x2).
-------------------------------------------------------------------------
local function eval_per_card_jokers(card, resolved, chips, mult, state)
    local id = card.base.id
    local is_face = id >= 11 and id <= 13
    local is_ace = id == 14
    local is_fib = fib_ranks[id] or false
    local is_even = id >= 2 and id <= 10 and id % 2 == 0
    local is_odd = is_ace or (id >= 1 and id <= 10 and id % 2 == 1)

    for _, j in ipairs(resolved) do
        local name = j.name

        -- Suit mult jokers (Greedy/Lusty/Wrathful/Gluttonous):
        -- +3 mult per scoring card of the matching suit
        local suit_target = suit_mult_jokers[name]
        if suit_target then
            if suit_matches(card, suit_target) then mult = mult + 3 end

        -- Fibonacci: +8 mult for ranks 2, 3, 5, 8, Ace
        elseif name == "Fibonacci" then
            if is_fib then mult = mult + 8 end

        -- Scary Face: +30 chips per face card (J, Q, K)
        elseif name == "Scary Face" then
            if is_face then chips = chips + 30 end

        -- Scholar: +20 chips and +4 mult per Ace
        elseif name == "Scholar" then
            if is_ace then
                chips = chips + 20
                mult = mult + 4
            end

        -- Even Steven: +4 mult per even-ranked card (2, 4, 6, 8, 10)
        elseif name == "Even Steven" then
            if is_even then mult = mult + 4 end

        -- Odd Todd: +31 chips per odd-ranked card (A, 3, 5, 7, 9)
        elseif name == "Odd Todd" then
            if is_odd then chips = chips + 31 end

        -- Walkie Talkie: +10 chips and +4 mult per 10 or 4
        elseif name == "Walkie Talkie" then
            if id == 10 or id == 4 then
                chips = chips + 10
                mult = mult + 4
            end

        -- Smiley Face: +5 mult per face card
        elseif name == "Smiley Face" then
            if is_face then mult = mult + 5 end

        -- Photograph: x2 mult on the FIRST face card scored only
        elseif name == "Photograph" then
            if is_face and not state.photo_used then
                state.photo_used = true
                mult = mult * 2
            end

        -- Triboulet: x2 mult per King or Queen scored
        elseif name == "Triboulet" then
            if id == 12 or id == 13 then mult = mult * 2 end

        -- Bloodstone: 1-in-2 chance of x1.5 for Hearts
        -- Approximated as EV: x1.25 per Heart
        elseif name == "Bloodstone" then
            if suit_matches(card, "Hearts") then
                mult = mult * 1.25
                state.used_ev = true
            end

        -- Arrowhead: +50 chips per Spade scored
        elseif name == "Arrowhead" then
            if suit_matches(card, "Spades") then chips = chips + 50 end

        -- Onyx Agate: +7 mult per Club scored
        elseif name == "Onyx Agate" then
            if suit_matches(card, "Clubs") then mult = mult + 7 end

        -- Ancient Joker: x1.5 per card matching the joker's chosen suit.
        -- The chosen suit rotates each round and is stored on
        -- G.GAME.current_round.ancient_card.suit, not on the joker.
        elseif name == "Ancient Joker" then
            local ac = G.GAME.current_round and G.GAME.current_round.ancient_card
            local chosen = ac and ac.suit
            if chosen and suit_matches(card, chosen) then
                mult = mult * 1.5
            end

        -- Hiker: +5 chips per scoring card
        elseif name == "Hiker" then
            chips = chips + 5

        -- The Idol: x2 per card matching a specific rank AND suit.
        -- Target rotates each round and is stored on
        -- G.GAME.current_round.idol_card.{id, suit}.
        elseif name == "The Idol" then
            local ic = G.GAME.current_round and G.GAME.current_round.idol_card
            local tid = ic and ic.id
            local tsuit = ic and ic.suit
            if tid and tsuit and id == tid and suit_matches(card, tsuit) then
                mult = mult * 2
            end
        end
    end

    return chips, mult
end

-------------------------------------------------------------------------
-- Phase 2: flat joker effects (fire once per hand, in slot order L→R).
-- These depend on hand type, game state, or aggregate card properties
-- rather than individual scoring cards.
--
-- ctx fields: hand_name, all_cards, played, num_played, suits
-------------------------------------------------------------------------
local function eval_flat_jokers(resolved, chips, mult, ctx)
    for _, j in ipairs(resolved) do
        local ability = j.ability
        local name = j.name

        -------------------------------------------
        -- Data-driven dispatch: accumulator jokers whose value lives on
        -- ability.mult / ability.x_mult / ability.extra.chips
        -------------------------------------------
        if flat_add_mult[name] then
            mult = mult + (ability.mult or 0)

        elseif flat_x_mult[name] then
            mult = mult * (ability.x_mult or 1)

        elseif flat_add_chips[name] then
            chips = chips + (ability.extra and ability.extra.chips
                or ability.chips or 0)

        -------------------------------------------
        -- Data-driven dispatch: hand-type conditional jokers
        -------------------------------------------
        elseif hand_conditional_jokers[name] then
            local hc = hand_conditional_jokers[name]
            if hc.contains[ctx.hand_name] then
                if hc.op == "mult" then
                    mult = mult + hc.amount
                elseif hc.op == "chips" then
                    chips = chips + hc.amount
                else -- "xmult"
                    mult = mult * hc.amount
                end
            end

        -------------------------------------------
        -- Custom-logic jokers (unique conditions or game state)
        -------------------------------------------
        elseif name == "Joker" then
            -- The basic Joker: flat +4 mult
            mult = mult + 4

        elseif name == "Half Joker" then
            -- +20 mult when playing 3 or fewer cards
            if ctx.num_played <= 3 then mult = mult + 20 end

        elseif name == "Banner" then
            -- +30 chips per discard remaining this round
            local discards = (G.GAME.current_round
                and G.GAME.current_round.discards_left) or 0
            chips = chips + 30 * discards

        elseif name == "Mystic Summit" then
            -- +15 mult when 0 discards remain
            local discards = (G.GAME.current_round
                and G.GAME.current_round.discards_left) or 0
            if discards == 0 then mult = mult + 15 end

        elseif name == "Abstract Joker" then
            -- +3 mult per joker slot filled
            mult = mult + 3 * #G.jokers.cards

        elseif name == "Stuntman" then
            -- Flat +250 chips
            chips = chips + 250

        elseif name == "Supernova" then
            -- +mult equal to the number of times this hand type was played
            local times = (G.GAME.hands[ctx.hand_name]
                and G.GAME.hands[ctx.hand_name].played) or 0
            mult = mult + times

        elseif name == "Acrobat" then
            -- x3 mult on the final hand of the round
            local hands = (G.GAME.current_round
                and G.GAME.current_round.hands_left) or 0
            if hands == 1 then mult = mult * 3 end

        elseif name == "Bootstraps" then
            -- +2 mult per $5 currently held
            local dollars = G.GAME.dollars or 0
            mult = mult + 2 * math.floor(dollars / 5)

        elseif name == "Blackboard" then
            -- x3 mult if every held (non-played) card is a Spade or Club
            local all_dark = true
            for _, c in ipairs(ctx.all_cards) do
                if not ctx.played[c] and not c.debuff then
                    if c.base.suit ~= "Spades" and c.base.suit ~= "Clubs" then
                        all_dark = false
                        break
                    end
                end
            end
            if all_dark then mult = mult * 3 end

        elseif name == "Raised Fist" then
            -- +2× the rank of the lowest held-in-hand card
            local lowest = math.huge
            for _, c in ipairs(ctx.all_cards) do
                if not ctx.played[c] and not c.debuff then
                    if c.base.id < lowest then lowest = c.base.id end
                end
            end
            if lowest < math.huge then mult = mult + 2 * lowest end

        elseif name == "Blue Joker" then
            -- +2 chips per card remaining in the draw pile
            local remaining = (G.deck and G.deck.cards
                and #G.deck.cards) or 0
            chips = chips + 2 * remaining

        elseif name == "Flower Pot" then
            -- x3 mult if scoring cards include all 4 suits
            local s = ctx.suits
            if s.Hearts > 0 and s.Diamonds > 0
                and s.Clubs > 0 and s.Spades > 0 then
                mult = mult * (ability.x_mult or 3)
            end

        elseif name == "Loyalty Card" then
            -- x4 mult (or stored x_mult) on every 4th hand played
            if ability.remaining == 0 then
                mult = mult * (ability.x_mult or 4)
            end

        elseif name == "Card Sharp" then
            -- x3 mult if this hand type has already been played this round
            local h = G.GAME.hands[ctx.hand_name]
            if h and (h.played_this_round or 0) > 0 then
                mult = mult * (ability.extra and ability.extra.Xmult or 3)
            end
        end

        -- Joker edition bonuses (applied after each joker's own effect)
        chips, mult = apply_edition(j.edition, chips, mult)
    end

    return chips, mult
end

-------------------------------------------------------------------------
-- Score a complete combo of played cards against the full hand.
-- Follows Balatro's three-phase evaluation order.
-- Returns: hand_name, total_score, scoring_cards
-------------------------------------------------------------------------
local function score_combo(cards, all_cards)
    -- Identify the poker hand type and look up base chips/mult from level
    local hand_name, _, _ = G.FUNCS.get_poker_hand_info(cards)
    if not hand_name then return nil, 0 end

    -- With Four Fingers, Balatro may detect Straight Flush / Royal Flush
    -- when the flush subset and straight subset don't overlap (e.g. 4
    -- suited cards + 1 off-suit card that completes the straight).  Reject
    -- these so the individual Flush / Straight combos are recommended.
    if hand_name == "Straight Flush" or hand_name == "Royal Flush" then
        local flush_cards = get_flush_members(cards)
        if #flush_cards < #cards then
            local sub_name = G.FUNCS.get_poker_hand_info(flush_cards)
            if sub_name ~= "Straight Flush" and sub_name ~= "Royal Flush" then
                return nil, 0
            end
        end
    end

    local hand_info = G.GAME.hands[hand_name]
    if not hand_info then return nil, 0 end

    local chips = hand_info.chips
    local mult = hand_info.mult

    -- The Flint boss blind halves the hand's base chips and mult
    if is_flint_active() then
        chips = math.ceil(chips / 2)
        mult = math.ceil(mult / 2)
    end

    -- Set of played cards (for held-in-hand lookups later)
    local played = {}
    for _, card in ipairs(cards) do played[card] = true end

    -- Determine which cards score (excludes kickers, includes Stone Cards)
    local scoring = get_scoring_cards(cards, hand_name)

    -- Resolve Blueprint/Brainstorm into effective joker list once
    local resolved = resolve_jokers()

    -- Cross-card state for per-card joker effects.
    -- used_ev gets flipped true whenever a probabilistic effect
    -- (Lucky Card, Bloodstone) contributes to the score, so the F2
    -- output can label the result as an expected value.
    local state = { photo_used = false, used_ev = false }

    -------------------------------------------------
    -- Phase 1: each scoring card fires L→R
    -- Each trigger applies in order:
    --   base chips → enhancement → edition → per-card jokers
    -- Retriggers repeat the entire sequence for that card.
    -------------------------------------------------
    for idx, card in ipairs(scoring) do
        if not card.debuff then
            local triggers = get_triggers(card, idx, false)
            for _ = 1, triggers do
                -- Base chip value from card rank (Stone Cards have nominal=0)
                chips = chips + (card.base.nominal or 0)

                -- Card enhancement bonuses
                local ability = card.ability
                if ability then
                    local ename = ability.name
                    if ename == "Bonus Card" then
                        chips = chips + 30
                    elseif ename == "Mult Card" then
                        mult = mult + 4
                    elseif ename == "Glass Card" then
                        mult = mult * 2
                    elseif ename == "Stone Card" then
                        chips = chips + 50
                    elseif ename == "Lucky Card" then
                        -- EV: 1/5 chance of +20 mult ≈ +4 average
                        mult = mult + 4
                        state.used_ev = true
                    end
                    -- Permanent bonus chips (from hand-scored upgrades)
                    chips = chips + (ability.perma_bonus or 0)
                end

                -- Card edition bonuses (foil/holo/polychrome)
                chips, mult = apply_edition(card.edition, chips, mult)

                -- Per-card joker effects for this card
                chips, mult = eval_per_card_jokers(
                    card, resolved, chips, mult, state
                )
            end
        end
    end

    -------------------------------------------------
    -- Phase 2: flat joker effects fire L→R
    -------------------------------------------------
    local suits = count_suits(scoring)
    local ctx = {
        hand_name   = hand_name,
        all_cards   = all_cards,
        played      = played,
        num_played  = #cards,
        suits       = suits,
    }
    chips, mult = eval_flat_jokers(resolved, chips, mult, ctx)

    -------------------------------------------------
    -- Phase 3: held-in-hand effects (with retriggers)
    -- Steel Card, Baron, and Shoot the Moon fire per held card.
    -- Mime and Red Seal provide retriggers for held cards.
    -------------------------------------------------
    -- Pre-check which held-in-hand joker effects are active
    local has_baron = false
    local baron_count = 0       -- how many Baron instances (Blueprint can copy)
    local has_shoot_moon = false
    local shoot_moon_count = 0
    for _, j in ipairs(resolved) do
        if j.name == "Baron" then
            has_baron = true
            baron_count = baron_count + 1
        end
        if j.name == "Shoot the Moon" then
            has_shoot_moon = true
            shoot_moon_count = shoot_moon_count + 1
        end
    end

    for _, card in ipairs(all_cards) do
        if not played[card] and not card.debuff then
            local is_steel = card.ability and card.ability.name == "Steel Card"
            local is_king = card.base.id == 13
            local is_queen = card.base.id == 12

            -- Only process cards that have at least one held-in-hand effect
            if is_steel or (has_baron and is_king)
                or (has_shoot_moon and is_queen) then
                local triggers = get_triggers(card, 0, true)
                for _ = 1, triggers do
                    -- Steel Card enhancement: x1.5 mult per trigger
                    if is_steel then
                        mult = mult * 1.5
                    end
                    -- Baron: x1.5 mult per held King, per Baron instance
                    if has_baron and is_king then
                        for _ = 1, baron_count do
                            mult = mult * 1.5
                        end
                    end
                    -- Shoot the Moon: +13 mult per held Queen, per instance
                    if has_shoot_moon and is_queen then
                        mult = mult + 13 * shoot_moon_count
                    end
                end
            end
        end
    end

    return hand_name, chips * mult, scoring, state.used_ev
end

-------------------------------------------------------------------------
-- Display helpers: convert cards to compact readable labels
-------------------------------------------------------------------------
local rank_names = {
    [2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6",
    [7] = "7", [8] = "8", [9] = "9", [10] = "10",
    [11] = "J", [12] = "Q", [13] = "K", [14] = "A",
}
local suit_symbols = {
    ["Hearts"] = "h", ["Diamonds"] = "d",
    ["Clubs"] = "c", ["Spades"] = "s",
}

-- Format an integer with commas as thousands separators (e.g. 1234567 → "1,234,567")
local function format_number(n)
    local s = string.format("%.0f", n)
    local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (result:gsub("^,", ""))
end

local function card_label(card)
    local rank = rank_names[card.base.id] or "?"
    local suit = suit_symbols[card.base.suit] or "?"
    return rank .. suit
end

local function cards_label(cards)
    local labels = {}
    for _, card in ipairs(cards) do
        labels[#labels + 1] = card_label(card)
    end
    return table.concat(labels, ", ")
end

-- Label all cards EXCEPT those in the exclude list
local function cards_label_exclude(cards, exclude)
    local exc_set = {}
    for _, card in ipairs(exclude) do exc_set[card] = true end
    local labels = {}
    for _, card in ipairs(cards) do
        if not exc_set[card] then labels[#labels + 1] = card_label(card) end
    end
    return table.concat(labels, ", ")
end

-------------------------------------------------------------------------
-- Analyze the current hand: try every possible combo (sizes 5→1),
-- score each one, and return the top 3 distinct hand types.
-------------------------------------------------------------------------
local function analyze_hand()
    if not G or not G.hand or not G.hand.cards then return nil end
    local cards = G.hand.cards
    if #cards == 0 then return nil end

    -- Evaluate every possible combo of every size
    local best = {}
    for size = 5, 1, -1 do
        if #cards >= size then
            for _, combo in ipairs(combinations(cards, size)) do
                local name, score, scoring, used_ev = score_combo(combo, cards)
                if name then
                    best[#best + 1] = {
                        name = name, score = score,
                        cards = scoring, play = combo,
                        used_ev = used_ev,
                    }
                end
            end
        end
    end

    -- Sort by score descending; break ties by preferring fewer cards
    table.sort(best, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return #a.play < #b.play
    end)

    -- Deduplicate: keep only the best combo per hand type,
    -- but collect tied alternatives for display
    local seen = {}
    local top = {}
    for _, entry in ipairs(best) do
        if not seen[entry.name] then
            if #top >= 3 then break end
            seen[entry.name] = true
            entry.alts = {}
            top[#top + 1] = entry
        elseif top[#top].name == entry.name and entry.score == top[#top].score
            and #entry.play == #top[#top].play then
            -- Tied alternative for the same hand type and size
            local alts = top[#top].alts
            local label = cards_label(entry.cards)
            if not alts.seen_labels then alts.seen_labels = {} end
            if not alts.seen_labels[label] then
                alts.seen_labels[label] = true
                alts[#alts + 1] = entry
            end
        end
    end
    return top
end

-------------------------------------------------------------------------
-- F2 keybind: print the top 3 hands to the console
-------------------------------------------------------------------------
SMODS.Keybind({
    key_pressed = "f2",
    action = function(self)
        local results = analyze_hand()
        if not results or #results == 0 then return end
        local lines = {"", "-- Best Hands --"}
        -- Note when Splash makes all played cards score
        if G.jokers and G.jokers.cards then
            for _, joker in ipairs(G.jokers.cards) do
                if not joker.debuff and joker.ability
                    and joker.ability.name == "Splash" then
                    lines[#lines + 1] = "(All cards score with Splash joker)"
                    break
                end
            end
        end
        for i, r in ipairs(results) do
            -- Format: "1. Flush (Ah, Kh, Qh + 7h, 3h)  ~ 1234 points"
            local play_str = cards_label(r.play)
            if #r.play > #r.cards then
                play_str = cards_label(r.cards)
                    .. " + " .. cards_label_exclude(r.play, r.cards)
            end
            local line = i .. ". " .. r.name
                .. " (" .. play_str .. ")     ~ "
                .. format_number(r.score) .. " points"
            -- Mark scores that include expected-value approximations
            -- (Lucky Card enhancements, Bloodstone joker)
            if r.used_ev then line = line .. " (expected value)" end
            -- Show tied alternatives if any
            if r.alts and #r.alts > 0 then
                local alt_labels = {}
                for _, alt in ipairs(r.alts) do
                    alt_labels[#alt_labels + 1] = cards_label(alt.cards)
                end
                line = line .. "  (or "
                    .. table.concat(alt_labels, ", or ") .. ")"
            end
            lines[#lines + 1] = line
        end
        for _, line in ipairs(lines) do print(line) end
    end
})

-------------------------------------------------------------------------
-- F3 keybind: dump all card and joker properties to a file for debugging
-------------------------------------------------------------------------
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
        if G.jokers and G.jokers.cards then
            for i, joker in ipairs(G.jokers.cards) do
                dump(joker, "joker[" .. i .. "]", 0)
            end
        end
        -- Dump G.GAME.current_round so we can find where Balatro stores
        -- per-round joker state (e.g. Ancient Joker's chosen suit lives
        -- on current_round.ancient_card, The Idol's target on idol_card)
        if G.GAME and G.GAME.current_round then
            dump(G.GAME.current_round, "current_round", 0)
        end
        table.sort(out)
        local path = love.filesystem.getSaveDirectory() .. "/card_dump.txt"
        local f = io.open(path, "w")
        for _, line in ipairs(out) do f:write(line .. "\n") end
        f:close()
        print("Written to " .. path)
    end
})
