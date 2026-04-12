-------------------------------------------------------------------------
-- BestHand.lua — Balatro mod that analyzes your hand and recommends
-- the highest-scoring play. Press F2 to evaluate; F3 to dump card data.
--
-- Scoring follows Balatro's evaluation order:
--   Phase 1: Each scoring card fires L→R (with retriggers):
--            base chips → enhancement → edition → per-card jokers
--   Phase 2: Held-in-hand effects (Steel Card, Baron, Shoot the Moon)
--            fire per held card, with Mime/Red Seal retriggers
--   Phase 3: Flat joker effects fire L→R (with Blueprint/Brainstorm)
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

-------------------------------------------------------------------------
-- Actual rank-group containment from played cards. Balatro's hand-type
-- conditional jokers (Jolly, The Duo, etc.) check the CARDS for sub-hand
-- presence, not just the primary hand type name. A Flush with Ks, Ks
-- contains a Pair even though "Flush" isn't in the contains_pair table.
-- For flush/straight containment the primary hand type is reliable (a
-- lower-priority hand can never contain a higher-priority pattern), so
-- only rank-based containment needs card-level analysis.
-------------------------------------------------------------------------
local function check_hand_contains(contains_table, hand_name, cards)
    -- For flush and straight, the primary hand type is sufficient
    if contains_table == contains_flush or contains_table == contains_straight then
        return contains_table[hand_name] or false
    end
    -- For rank-based containment, analyze actual card composition
    local groups = {}
    for _, c in ipairs(cards) do
        if not (c.ability and c.ability.name == "Stone Card") then
            local id = c.base.id
            groups[id] = (groups[id] or 0) + 1
        end
    end
    local counts = {}
    for _, n in pairs(groups) do counts[#counts + 1] = n end
    table.sort(counts, function(a, b) return a > b end)
    local c1, c2 = counts[1] or 0, counts[2] or 0
    if contains_table == contains_pair     then return c1 >= 2 end
    if contains_table == contains_three    then return c1 >= 3 end
    if contains_table == contains_four     then return c1 >= 4 end
    if contains_table == contains_two_pair then return c1 >= 2 and c2 >= 2 end
    -- Fallback: use the name-based table
    return contains_table[hand_name] or false
end

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
-- Steel Joker is NOT in this table: its x_mult isn't stored on ability,
-- it's computed live from the full playing deck at scoring time.
local flat_x_mult = {
    ["Obelisk"] = true, ["Joker Stencil"] = true, ["Driver's License"] = true,
    ["Glass Joker"] = true, ["Madness"] = true, ["Vampire"] = true,
    ["Hologram"] = true, ["Throwback"] = true, ["Constellation"] = true,
    ["Lucky Cat"] = true,
}
local flat_add_chips = {
    ["Ice Cream"] = true, ["Runner"] = true, ["Castle"] = true,
    ["Wee Joker"] = true, ["Square Joker"] = true,
}
-- Jokers whose +mult value lives on ability.extra.mult rather than ability.mult
local flat_add_mult_extra = {
    ["Gros Michel"] = true,
}

-------------------------------------------------------------------------
-- Snapshot / restore a joker's ability table. Used to guarantee that
-- calling calculate_joker during read-only analysis never corrupts
-- game state — even if a joker mutates self.ability.* as a side
-- effect of its calculate function, we roll it back immediately.
-- Handles one level of nesting (ability.extra is a sub-table).
-------------------------------------------------------------------------
local function snapshot_ability(ability)
    if not ability then return nil end
    local copy = {}
    for k, v in pairs(ability) do
        if type(v) == "table" then
            copy[k] = {}
            for k2, v2 in pairs(v) do copy[k][k2] = v2 end
        else
            copy[k] = v
        end
    end
    return copy
end

-------------------------------------------------------------------------
-- Hybrid scoring deny list: jokers whose real calculate_joker must NOT
-- be called during analysis because their joker_main calculate function
-- has side effects (advances RNG, mutates state, etc.). These jokers
-- fall back to the hardcoded reimplementation.
--
-- Misprint: calls pseudorandom() to roll a random mult, advancing the
--           RNG seed. We handle it via the range_config enumeration.
-- Blueprint / Brainstorm: delegate to their target's calculate_joker.
--           If the target is a deny-listed joker, the side effect leaks
--           through. Safer to resolve them manually via resolve_jokers()
--           and fall back to hardcoded for the resolved target.
-------------------------------------------------------------------------
local joker_main_deny = {
    ["Misprint"]    = true,
    ["Blueprint"]   = true,
    ["Brainstorm"]  = true,
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
-- Identify which cards participate in a flush pattern. Returns the
-- matching subset. Two wrinkles:
--   * Four Fingers: only 4 cards need to share a suit, so a 5-card
--     combo may contain a non-matching kicker.
--   * Smeared Joker: Hearts+Diamonds and Spades+Clubs each collapse
--     into a single virtual suit, so mixed-but-paired combos still
--     count all their cards as flush members.
-------------------------------------------------------------------------
-- Paired suits for Smeared Joker: Hearts<->Diamonds, Spades<->Clubs.
local smeared_pair = {
    Hearts = "Diamonds", Diamonds = "Hearts",
    Spades = "Clubs",    Clubs = "Spades",
}

local function has_smeared_joker()
    if not G.jokers or not G.jokers.cards then return false end
    for _, joker in ipairs(G.jokers.cards) do
        if not joker.debuff and joker.ability
            and joker.ability.name == "Smeared Joker" then
            return true
        end
    end
    return false
end

local function get_flush_members(cards)
    -- Smeared Joker merges Hearts+Diamonds and Spades+Clubs into single
    -- virtual suits. Without this check, a 3d+2h combo (5-card flush
    -- under Smeared) would only return 3 diamonds as members and the
    -- 2 hearts would silently drop out of scoring.
    local smeared = has_smeared_joker()
    local function is_member(card, target)
        if suit_matches(card, target) then return true end
        if smeared and suit_matches(card, smeared_pair[target]) then
            return true
        end
        return false
    end

    local suits = {"Hearts", "Diamonds", "Clubs", "Spades"}
    local best_suit, best_count = nil, 0
    for _, suit in ipairs(suits) do
        local count = 0
        for _, card in ipairs(cards) do
            if is_member(card, suit) then count = count + 1 end
        end
        if count > best_count then best_suit, best_count = suit, count end
    end
    if best_count >= #cards then return cards end
    local result = {}
    for _, card in ipairs(cards) do
        if is_member(card, best_suit) then result[#result + 1] = card end
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
    -- If the full combo is already a straight, every card participates.
    -- Without this check Four Fingers breaks 5-card straights: removing
    -- any single card leaves a 4-card subset that still registers as a
    -- straight, so the kicker-detection loop below would incorrectly
    -- drop a valid scoring card.
    local full_name = G.FUNCS.get_poker_hand_info(cards)
    if full_name and contains_straight[full_name] then return cards end
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
-- `resolved` is the Blueprint/Brainstorm-resolved joker list from
-- resolve_jokers(). When provided, retrigger detection uses resolved
-- names so Blueprint copies of retrigger jokers are counted.
-------------------------------------------------------------------------
local function get_triggers(card, card_index, is_held, pareidolia, resolved)
    local triggers = 1 -- base: every card fires at least once

    -- Red Seal doubles triggers (works on both played and held cards)
    if card.seal == "Red" then
        triggers = triggers * 2
    end

    -- Use the resolved joker list if available (handles Blueprint/Brainstorm
    -- copies of retrigger jokers). Fall back to raw G.jokers.cards for
    -- backward compatibility with standalone trace tools.
    local joker_names = nil
    if resolved then
        joker_names = {}
        for _, j in ipairs(resolved) do
            joker_names[#joker_names + 1] = j.name
        end
    else
        if not G.jokers or not G.jokers.cards then return triggers end
        joker_names = {}
        for _, joker in ipairs(G.jokers.cards) do
            if not joker.debuff then
                joker_names[#joker_names + 1] =
                    (joker.ability and joker.ability.name) or ""
            end
        end
    end

    if not is_held then
        -- Retrigger jokers for played/scoring cards
        for _, name in ipairs(joker_names) do
            if name == "Hack" then
                -- Retrigger cards ranked 2, 3, 4, or 5
                local id = card.base.id
                if id >= 2 and id <= 5 then triggers = triggers * 2 end
            elseif name == "Sock and Buskin" then
                -- Retrigger face cards (J=11, Q=12, K=13).
                -- Pareidolia makes every card count as face.
                local is_face = pareidolia
                    or (card.base.id >= 11 and card.base.id <= 13)
                if is_face then triggers = triggers * 2 end
            elseif name == "Hanging Chad" then
                -- The first scoring card fires 3 total times (+2 retriggers)
                if card_index == 1 then triggers = triggers * 3 end
            elseif name == "Dusk" then
                -- Retrigger all cards on the final hand of the round.
                -- The game decrements hands_left before scoring, so
                -- "last hand" is hands_left == 0 at evaluation time.
                local hands_left = (G.GAME.current_round
                    and G.GAME.current_round.hands_left) or 0
                if hands_left == 0 then triggers = triggers * 2 end
            elseif name == "Seltzer" then
                -- Retrigger all scored cards (temporary consumable effect)
                triggers = triggers * 2
            end
        end
    else
        -- Retrigger jokers for held-in-hand cards
        for _, name in ipairs(joker_names) do
            if name == "Mime" then
                triggers = triggers * 2
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
-- Used in three places: played-card editions in Phase 1, held Steel
-- card editions in Phase 2, and joker editions in Phase 3.
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
--   state.photo_card — identity of the first scored face card to fire
--                      Photograph. Every trigger of THAT card re-fires
--                      Photograph (Hanging Chad stacks stack x2s), but
--                      later face cards are blocked.
--   state.used_ev    — set true when a probabilistic effect (Lucky
--                      Card, Bloodstone) contributes; surfaces in F2
--                      as an "(expected value)" marker.
-- `pareidolia` makes every card count as a face card for Scary Face,
-- Smiley Face, and Photograph.
-------------------------------------------------------------------------
local function eval_per_card_jokers(card, resolved, chips, mult, state, pareidolia)
    local id = card.base.id
    -- Pareidolia makes every card count as a face card for joker effects
    local is_face = pareidolia or (id >= 11 and id <= 13)
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

        -- Photograph: x2 mult on the first scoring face card. Balatro's
        -- condition has no once-per-hand flag, so every trigger of that
        -- card re-fires Photograph — e.g. Hanging Chad retriggers of the
        -- leftmost face card stack into x2 × x2 × x2. Track the card
        -- identity, not a boolean, so later face cards are still blocked
        -- but retriggers of the original one continue to fire.
        elseif name == "Photograph" then
            if is_face and (state.photo_card == nil
                or state.photo_card == card) then
                state.photo_card = card
                mult = mult * 2
            end

        -- Triboulet: x2 mult per King or Queen scored
        elseif name == "Triboulet" then
            if id == 12 or id == 13 then mult = mult * 2 end

        -- Bloodstone: 1-in-2 chance of x1.5 mult per scored Heart.
        -- EV mode (prob_config nil): x1.25 per Heart (= 0.5*1.5 + 0.5*1.0).
        -- Exact mode: consume the next prob_config slot — true = hit (x1.5),
        -- false/nil = miss (x1.0). Always increment prob_idx so F4 can
        -- enumerate every outcome.
        elseif name == "Bloodstone" then
            if suit_matches(card, "Hearts") then
                state.prob_idx = state.prob_idx + 1
                if state.prob_config then
                    if state.prob_config[state.prob_idx] then
                        mult = mult * 1.5
                    end
                else
                    mult = mult * 1.25
                    state.used_ev = true
                end
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
-- Flat joker effects (fire once per hand, in slot order L→R). Called
-- from Phase 3 of score_combo AFTER held-in-hand effects have run.
-- These jokers depend on hand type, game state, or aggregate card
-- properties rather than individual scoring cards.
--
-- ctx fields: hand_name, all_cards, played, num_played, suits
-- state carries prob_idx / range_idx counters for Misprint etc.
-------------------------------------------------------------------------
local function eval_flat_jokers(resolved, chips, mult, ctx, state)
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

        elseif flat_add_mult_extra[name] then
            mult = mult + ((ability.extra and ability.extra.mult) or 0)

        -------------------------------------------
        -- Data-driven dispatch: hand-type conditional jokers
        -------------------------------------------
        elseif hand_conditional_jokers[name] then
            local hc = hand_conditional_jokers[name]
            if check_hand_contains(hc.contains, ctx.hand_name, ctx.full_hand) then
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
        elseif name == "Misprint" then
            -- +X mult where X is uniform random integer in [min, max]
            -- (defaults [0, 23]). EV mode: use midpoint. Exact mode:
            -- range_config[i] is the specific integer to use. state
            -- records {lo, hi} so F4 can enumerate every integer value.
            local lo = (ability.extra and ability.extra.min) or 0
            local hi = (ability.extra and ability.extra.max) or 23
            state.range_idx = state.range_idx + 1
            state.range_events[state.range_idx] = { lo, hi }
            local val = state.range_config
                and state.range_config[state.range_idx]
            if val then
                mult = mult + val
            else
                mult = mult + (lo + hi) / 2
                state.used_ev = true
            end

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
            -- +mult equal to the number of times this hand type was played.
            -- Balatro increments hands[name].played at the top of
            -- evaluate_play BEFORE Supernova reads it, so the game's value
            -- is one higher than what score_combo sees pre-play. Add 1
            -- so the prediction matches what will actually score.
            local times = (G.GAME.hands[ctx.hand_name]
                and G.GAME.hands[ctx.hand_name].played) or 0
            mult = mult + times + 1

        elseif name == "Acrobat" then
            -- x3 mult on the final hand of the round.
            -- The game decrements hands_left before scoring, so
            -- "last hand" is hands_left == 0 at evaluation time.
            local hands = (G.GAME.current_round
                and G.GAME.current_round.hands_left) or 0
            if hands == 0 then mult = mult * 3 end

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

        elseif name == "Steel Joker" then
            -- Steel Joker's x_mult is computed live at scoring time from
            -- the total number of Steel-enhanced cards across the full
            -- playing deck (deck + hand + play + discard). ability.x_mult
            -- on the joker is just the base (1) and never updates.
            local count = 0
            if G.playing_cards then
                for _, c in ipairs(G.playing_cards) do
                    if c.ability and c.ability.name == "Steel Card" then
                        count = count + 1
                    end
                end
            end
            local per_steel = (type(ability.extra) == "table" and ability.extra.x_mult_mod)
                or (type(ability.extra) == "number" and ability.extra)
                or 0.2
            mult = mult * (1 + per_steel * count)
        end

        -- Joker edition bonuses (applied after each joker's own effect)
        chips, mult = apply_edition(j.edition, chips, mult)
    end

    return chips, mult
end

-------------------------------------------------------------------------
-- Score a complete combo of played cards against the full hand.
-- Follows Balatro's three-phase evaluation order (scoring cards,
-- then held-in-hand, then flat jokers).
--
-- prob_config (optional) pins each boolean probabilistic roll to a specific
-- outcome — an array one-per-event of Lucky Card / Bloodstone fires, true =
-- hit, anything else = miss. Default: use EV and flip used_ev.
-- range_config (optional) pins each range-valued probabilistic event (e.g.
-- Misprint, which rolls a random integer mult in [min, max]) to a specific
-- integer. Default: use the midpoint. F4 enumerates every integer value to
-- get the exact discrete set of possible scores.
-- Returns: hand_name, score, scoring_cards, used_ev, prob_count, range_events.
-- range_events is an array of {lo, hi} bounds, one per range fire, so a
-- caller can iterate the cartesian product to enumerate all outcomes.
-------------------------------------------------------------------------
local function score_combo(cards, all_cards, prob_config, range_config)
    -- Identify the poker hand type and look up base chips/mult from level.
    -- Also capture poker_hands (the sub-hand containment table the game builds)
    -- because the hybrid joker path passes it to real calculate_joker calls
    -- for jokers that check "does this hand contain a Pair?" etc.
    -- get_poker_hand_info returns (hand_name, display_name, poker_hands_table);
    -- skip the display_name with _ to get the table in the 3rd slot.
    local hand_name, _, poker_hands = G.FUNCS.get_poker_hand_info(cards)
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

    -- Detect Pareidolia once up front. When present, every card counts
    -- as a face card for Scary Face, Smiley Face, Photograph, and the
    -- Sock and Buskin retrigger check.
    local pareidolia = false
    for _, j in ipairs(resolved) do
        if j.name == "Pareidolia" then pareidolia = true; break end
    end

    -- Cross-card state for per-card joker effects.
    -- used_ev gets flipped true whenever a probabilistic effect (Lucky Card,
    -- Bloodstone) contributes to the score in EV mode, so the F2 output can
    -- label the result as an expected value.
    -- prob_idx is the running count of probabilistic events consumed; F4
    -- reads the final value to size its enumeration loop. prob_config is
    -- the caller-supplied outcome pin (nil in F2 / EV mode).
    local state = {
        photo_card = nil, used_ev = false,
        prob_idx = 0, prob_config = prob_config,
        range_idx = 0, range_config = range_config,
        range_events = {},
    }

    -------------------------------------------------
    -- Phase 1: each scoring card fires L→R
    -- Each trigger applies in order:
    --   base chips → enhancement → edition → per-card jokers
    -- Retriggers repeat the entire sequence for that card.
    -------------------------------------------------
    for idx, card in ipairs(scoring) do
        if not card.debuff then
            local triggers = get_triggers(card, idx, false, pareidolia, resolved)
            for _ = 1, triggers do
                -- Base chip value from card rank (Stone Cards have nominal=0)
                chips = chips + (card.base.nominal or 0)

                -- Card enhancement bonuses
                local ability = card.ability
                if ability then
                    local ename = ability.name
                    -- Balatro stores these enhancement names WITHOUT the
                    -- "Card" suffix (confirmed from captured fixtures):
                    -- "Bonus", "Mult" — but "Glass Card", "Steel Card",
                    -- "Lucky Card" etc. DO carry the suffix. Inconsistent
                    -- naming in the game data.
                    if ename == "Bonus" then
                        chips = chips + 30
                    elseif ename == "Mult" then
                        mult = mult + 4
                    elseif ename == "Glass Card" then
                        mult = mult * 2
                    elseif ename == "Stone Card" then
                        chips = chips + 50
                    elseif ename == "Lucky Card" then
                        -- 1/5 chance of +20 mult. EV mode: +4 average.
                        -- Exact mode: consume the next prob_config slot.
                        state.prob_idx = state.prob_idx + 1
                        if state.prob_config then
                            if state.prob_config[state.prob_idx] then
                                mult = mult + 20
                            end
                        else
                            mult = mult + 4
                            state.used_ev = true
                        end
                    end
                    -- Permanent bonus chips (from hand-scored upgrades)
                    chips = chips + (ability.perma_bonus or 0)
                end

                -- Card edition bonuses (foil/holo/polychrome)
                chips, mult = apply_edition(card.edition, chips, mult)

                -- Per-card joker effects for this card
                chips, mult = eval_per_card_jokers(
                    card, resolved, chips, mult, state, pareidolia
                )
            end
        end
    end

    -------------------------------------------------
    -- Phase 2: held-in-hand effects (with retriggers)
    -- Steel Card, Baron, and Shoot the Moon fire per held card.
    -- Mime and Red Seal provide retriggers for held cards.
    --
    -- IMPORTANT: held-in-hand effects run BEFORE flat joker effects.
    -- Balatro's state_events.lua calls SMODS.calculate_main_scoring
    -- for the G.hand card-area (held cards) at line 673, and only
    -- fires joker_main in the loop starting at line 680. Running them
    -- in the opposite order mis-scales jokers like Mad Joker holo
    -- that add flat mult on top of Baron's x1.5 multiplier.
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
                local triggers = get_triggers(card, 0, true, pareidolia, resolved)
                for _ = 1, triggers do
                    -- Steel Card enhancement: x1.5 mult per trigger.
                    -- Card editions do NOT fire for held-in-hand effects;
                    -- they only fire in Phase 1 for scored cards.
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

    -------------------------------------------------
    -- Phase 3: flat joker effects fire L→R (after held-in-hand effects)
    --
    -- HYBRID APPROACH: for each joker, we first try calling the game's
    -- own Card:calculate_joker with a joker_main context. This returns
    -- a raw effect table like {mult_mod = 8} WITHOUT applying it to
    -- globals (SMODS.trigger_effects does that, and we skip it). The
    -- effect table tells us exactly what the joker would contribute —
    -- even for jokers the mod hasn't explicitly reimplemented.
    --
    -- If calculate_joker isn't available (offline harness, where
    -- "jokers" are plain tables without methods) or the joker is on the
    -- deny list (Misprint: advances RNG; Blueprint/Brainstorm: may
    -- delegate to a denied joker), we fall back to the hardcoded
    -- reimplementation in eval_flat_jokers.
    --
    -- This means:
    --   • In the live game, unknown jokers contribute their real value
    --     instead of silently scoring 0.
    --   • In the offline harness, known jokers still work via the
    --     reimplementation; unknown ones score 0 (same as before).
    --   • Deny-listed jokers always use the reimplementation, which
    --     handles Misprint's range enumeration, etc.
    -------------------------------------------------
    local suits = count_suits(scoring)
    local ctx = {
        hand_name   = hand_name,
        all_cards   = all_cards,
        played      = played,
        num_played  = #cards,
        suits       = suits,
        -- These extra fields are passed to real calculate_joker calls.
        -- poker_hands comes from get_poker_hand_info and maps each
        -- hand type ("Pair", "Flush", …) to the cards that form it.
        -- Jokers like Jolly Joker check poker_hands[self.ability.type]
        -- to decide whether to fire.
        poker_hands = poker_hands,
        full_hand   = cards,
        scoring_hand = scoring,
    }

    -- `resolved` (built in Phase 1 above) provides the fallback path's
    -- pre-resolved ability/name/edition for Blueprint/Brainstorm jokers.

    -- Iterate the real joker Card objects (not the resolved list) so
    -- calculate_joker is called on the actual Card — Blueprint's own
    -- calculate_joker handles delegation to its copy target internally.
    -- We keep a parallel index into `resolved` for the fallback path,
    -- which needs the pre-resolved ability/name/edition for Blueprint.
    local resolved_idx = 0
    for _, joker in ipairs(G.jokers and G.jokers.cards or {}) do
        if not joker.debuff then
            resolved_idx = resolved_idx + 1
            local name = (joker.ability and joker.ability.name) or ""
            local effect = nil

            ---------------------------------------------------------
            -- Hybrid path: call the game's real calculate_joker.
            -- Only available when running inside Balatro (joker is a
            -- real Card object with methods, not a plain fixture table).
            -- Skipped for deny-list jokers whose calculate has side
            -- effects we can't tolerate during read-only analysis.
            --
            -- SAFETY: snapshot the joker's ability table before the
            -- call and restore it unconditionally afterward. This
            -- guarantees that even if a joker's calculate mutates
            -- self.ability.* as a side effect, the game state is
            -- never corrupted by our read-only probing.
            ---------------------------------------------------------
            if joker.calculate_joker
                and not joker_main_deny[name]
                and poker_hands then
                local saved = snapshot_ability(joker.ability)
                effect = joker:calculate_joker({
                    joker_main   = true,
                    full_hand    = cards,
                    scoring_hand = scoring,
                    scoring_name = hand_name,
                    poker_hands  = poker_hands,
                    cardarea     = G.jokers,
                })
                -- Restore ability even if calculate_joker errored or
                -- mutated — the snapshot is our safety net.
                joker.ability = saved
            end

            if effect then
                -------------------------------------------------------
                -- Apply the returned effect table to our running
                -- chips/mult accumulators. The keys mirror what SMODS
                -- trigger_effects reads — we just do it manually
                -- without the animation/event side effects.
                --
                -- chip_mod  → additive chips  (e.g. Banner +30×discards)
                -- mult_mod  → additive mult   (e.g. Jolly Joker +8)
                -- Xmult_mod → multiplicative  (e.g. The Tribe ×2)
                -------------------------------------------------------
                chips = chips + (effect.chip_mod or 0)
                mult  = mult  + (effect.mult_mod or 0)
                if effect.Xmult_mod then mult = mult * effect.Xmult_mod end
                -- Joker edition (foil/holo/polychrome) is applied
                -- separately — the game does this after trigger_effects
                -- returns, so it's NOT included in the effect table.
                chips, mult = apply_edition(joker.edition, chips, mult)
            else
                -------------------------------------------------------
                -- Fallback: deny-listed, offline, or calculate returned
                -- nil (joker doesn't fire for this hand). Use the
                -- hardcoded reimplementation via eval_flat_jokers.
                -- Pass only the matching resolved entry (a 1-element
                -- list) so it handles Blueprint resolution + edition.
                -------------------------------------------------------
                local r = resolved[resolved_idx]
                if r then
                    chips, mult = eval_flat_jokers({r}, chips, mult, ctx, state)
                end
            end

            ---------------------------------------------------------
            -- Pre-increment corrections for accumulator jokers.
            --
            -- Some jokers update their own ability in context.before
            -- (which runs inside evaluate_play, BEFORE joker_main
            -- reads the accumulated value). Our analysis runs BEFORE
            -- evaluate_play, so we see the stale pre-increment value.
            -- Add the delta that context.before would apply for THIS
            -- hand. Same pattern as the existing Supernova +1 fix.
            --
            -- These corrections are pure arithmetic on the joker's
            -- stored ability fields — no game functions called.
            ---------------------------------------------------------
            local ability = joker.ability or {}
            local extra   = ability.extra or {}
            if name == "Wee Joker" then
                -- Gains +chip_mod chips per scored card in context.before.
                -- Default chip_mod = 8. Scored cards = #scoring.
                chips = chips + (extra.chip_mod or 8) * #scoring
            elseif name == "Runner" then
                -- Gains +chip_mod chips in context.before if the played
                -- hand contains a Straight. Default chip_mod = 15.
                if contains_straight[hand_name] then
                    chips = chips + (extra.chip_mod or 15)
                end
            elseif name == "Square Joker" then
                -- Gains +chip_mod chips in context.before if exactly 4
                -- cards are played. Default chip_mod = 4.
                if #cards == 4 then
                    chips = chips + (extra.chip_mod or 4)
                end
            elseif name == "Green Joker" then
                -- Gains +1 mult per hand played in context.before.
                mult = mult + (extra.hand_add or 1)
            elseif name == "Spare Trousers" then
                -- Gains +extra.mult mult in context.before if the hand
                -- contains a Two Pair.
                if contains_two_pair[hand_name] then
                    mult = mult + (extra.mult or 2)
                end
            end
        end
    end

    -- Balatro floors the final score to an integer; mirror that so
    -- polychrome/holo chains producing fractional intermediates match.
    return hand_name, math.floor(chips * mult), scoring,
        state.used_ev, state.prob_idx, state.range_events
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
-- For very large numbers, also append Balatro's exponent notation (e.g. "1.23e10").
local function format_number(n)
    local s = string.format("%.0f", n)
    local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    result = result:gsub("^,", "")
    if n >= 1e7 then
        local exp = math.floor(math.log10(n))
        local mantissa = n / (10 ^ exp)
        result = result .. string.format(" (%.2fe%d)", mantissa, exp)
    end
    return result
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

-------------------------------------------------------------------------
-- Fixture capture: hook G.FUNCS.evaluate_play to record every played
-- hand along with the score Balatro actually computed. These fixtures
-- are the oracle for offline regression tests — the game itself is the
-- ground truth, not hand-traced expected values.
--
-- Toggle with F4 (off by default). Captures go to
--   <save>/best_hand_captures/capture_<timestamp>_<n>.lua
-- Each file is a Lua literal loadable with dofile():
--   return { played=..., held=..., jokers=..., game=...,
--            hand_name=..., predicted_score=..., actual_score=... }
--
-- State is snapshotted BEFORE calling the real evaluate_play so it
-- matches what F2 sees when you're about to play — any mismatch with
-- actual_score is a real prediction bug. This naturally surfaces the
-- pre-increment gotcha on jokers that read hands[name].played /
-- played_this_round (Supernova, Card Sharp), since the game bumps those
-- counters at the top of evaluate_play before scoring with them.
-------------------------------------------------------------------------

local capture_enabled = false
local capture_dir = "best_hand_captures"

-- Serialize a plain Lua value as a Lua literal. Not general-purpose:
-- assumes scalars + nested tables of scalars, no cycles, no functions.
local function serialize(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v then return "(0/0)" end
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        return tostring(v)
    end
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return "nil" end

    local inner = indent .. "  "
    local n, max_i = 0, 0
    for k, _ in pairs(v) do
        n = n + 1
        if type(k) == "number" and k == math.floor(k) and k >= 1 then
            if k > max_i then max_i = k end
        end
    end
    if n == 0 then return "{}" end

    local parts = {"{"}
    if max_i == n then
        -- Array-style
        for i = 1, n do
            parts[#parts + 1] = inner .. serialize(v[i], inner) .. ","
        end
    else
        -- Hash-style, sorted by key for deterministic output
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local key_str
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                key_str = k
            else
                key_str = "[" .. serialize(k, inner) .. "]"
            end
            parts[#parts + 1] = inner .. key_str
                .. " = " .. serialize(v[k], inner) .. ","
        end
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
end

-- Copy only scalar fields from a table. Used for ability.extra where
-- different jokers store different fields (chips, Xmult, mult, etc.)
local function copy_scalars(t)
    if type(t) ~= "table" then return nil end
    local result, any = {}, false
    for k, val in pairs(t) do
        local vt = type(val)
        if vt == "number" or vt == "string" or vt == "boolean" then
            result[k] = val
            any = true
        end
    end
    if not any then return nil end
    return result
end

local function extract_edition(edition)
    if not edition then return nil end
    return {
        foil = edition.foil,
        holo = edition.holo,
        polychrome = edition.polychrome,
        negative = edition.negative,
    }
end

local function extract_card(card)
    local base = card.base or {}
    local ability = card.ability or {}
    return {
        base = {
            id      = base.id,
            suit    = base.suit,
            nominal = base.nominal,
            value   = base.value,
        },
        ability = {
            name        = ability.name,
            perma_bonus = ability.perma_bonus,
            extra       = copy_scalars(ability.extra),
        },
        edition = extract_edition(card.edition),
        seal    = card.seal,
        debuff  = card.debuff or nil,
    }
end

local function extract_joker(joker)
    local ability = joker.ability or {}
    return {
        ability = {
            name        = ability.name,
            mult        = ability.mult,
            x_mult      = ability.x_mult,
            chips       = ability.chips,
            t_mult      = ability.t_mult,
            t_chips     = ability.t_chips,
            remaining   = ability.remaining,
            perma_bonus = ability.perma_bonus,
            extra       = copy_scalars(ability.extra),
        },
        edition = extract_edition(joker.edition),
        debuff  = joker.debuff or nil,
    }
end

local function extract_card_list(list)
    local out = {}
    for i, c in ipairs(list) do out[i] = extract_card(c) end
    return out
end

local function extract_joker_list(list)
    local out = {}
    for i, j in ipairs(list) do out[i] = extract_joker(j) end
    return out
end

-- Snapshot the parts of G.GAME that score_combo consults.
local function extract_game_state()
    local game = {}

    if G.GAME and G.GAME.hands then
        game.hands = {}
        for name, info in pairs(G.GAME.hands) do
            game.hands[name] = {
                level             = info.level,
                chips             = info.chips,
                mult              = info.mult,
                played            = info.played,
                played_this_round = info.played_this_round,
                visible           = info.visible,
            }
        end
    end

    if G.GAME and G.GAME.current_round then
        local cr = G.GAME.current_round
        game.current_round = {
            hands_left    = cr.hands_left,
            discards_left = cr.discards_left,
            dollars       = cr.dollars,
        }
        if cr.ancient_card then
            game.current_round.ancient_card = { suit = cr.ancient_card.suit }
        end
        if cr.idol_card then
            game.current_round.idol_card = {
                id   = cr.idol_card.id,
                suit = cr.idol_card.suit,
                rank = cr.idol_card.rank,
            }
        end
    end

    game.dollars = G.GAME and G.GAME.dollars

    if G.GAME and G.GAME.blind then
        game.blind = {
            name     = G.GAME.blind.name,
            disabled = G.GAME.blind.disabled,
        }
    end

    if G.deck and G.deck.cards then
        game.deck_remaining = #G.deck.cards
    end

    -- Count Steel Cards across the full deck (G.playing_cards) so the
    -- offline harness can reconstruct the correct total for Steel Joker.
    if G.playing_cards then
        local steel_count = 0
        for _, c in ipairs(G.playing_cards) do
            if c.ability and c.ability.name == "Steel Card" then
                steel_count = steel_count + 1
            end
        end
        game.steel_card_count = steel_count
    end

    return game
end

-- Compute the mod's predicted score for the exact hand being played.
-- Called with real Card objects, BEFORE Balatro mutates state.
-- prob_config / range_config (optional): see score_combo for semantics.
local function compute_predicted_score(played, held, prob_config, range_config)
    local all = {}
    for _, c in ipairs(played) do all[#all + 1] = c end
    for _, c in ipairs(held)   do all[#all + 1] = c end
    return score_combo(played, all, prob_config, range_config)
end

local function write_capture(fixture)
    if love and love.filesystem and love.filesystem.createDirectory then
        love.filesystem.createDirectory(capture_dir)
    end
    local base = love.filesystem.getSaveDirectory() .. "/" .. capture_dir
    local stamp = os.date("%Y%m%d_%H%M%S")
    local path
    for i = 1, 1000 do
        local try = base .. "/capture_" .. stamp .. "_" .. i .. ".lua"
        local f = io.open(try, "r")
        if not f then path = try; break end
        f:close()
    end
    if not path then return end

    local f = io.open(path, "w")
    if not f then
        print("[BestHand] failed to open capture file: " .. path)
        return
    end
    f:write("-- BestHand capture fixture — auto-generated, safe to delete\n")
    f:write("return " .. serialize(fixture) .. "\n")
    f:close()
    print("[BestHand] captured: " .. path)
end

-- Wrap G.FUNCS.evaluate_play. Capture PRE-scoring so the fixture matches
-- what F2 would see just before playing; read the final score RIGHT AFTER
-- the original returns — the synchronous joker iteration has finished by
-- then, but the deferred chip-ease events haven't reset chip_total yet,
-- so SMODS.calculate_round_score() still has the true total.
if G.FUNCS and G.FUNCS.evaluate_play then
    local original_evaluate_play = G.FUNCS.evaluate_play
    G.FUNCS.evaluate_play = function(e)
        local fixture
        if capture_enabled then
            local ok, err = pcall(function()
                local played, held = {}, {}
                for i, c in ipairs(G.play.cards) do played[i] = c end
                for i, c in ipairs(G.hand.cards) do held[i]   = c end

                fixture = {
                    played = extract_card_list(played),
                    held   = extract_card_list(held),
                    jokers = extract_joker_list(G.jokers.cards),
                    game   = extract_game_state(),
                }

                local hn = G.FUNCS.get_poker_hand_info(G.play.cards)
                fixture.hand_name = hn

                local _, score, _, _, n_prob, range_events =
                    compute_predicted_score(played, held)
                fixture.predicted_score = score
                n_prob = n_prob or 0
                range_events = range_events or {}

                -- Enumerate every reachable score from the discrete
                -- product of (Lucky/Bloodstone booleans) × (each Misprint
                -- integer in its [min, max]). Bounded at 10k configs so
                -- 1-2 Misprints + ≤10 boolean fires stays fast.
                local range_total = 1
                for _, iv in ipairs(range_events) do
                    range_total = range_total * (iv[2] - iv[1] + 1)
                end
                local total_configs = (2 ^ n_prob) * range_total

                if (n_prob + #range_events) > 0 and n_prob <= 10
                    and total_configs <= 10000 then
                    local possible, seen = {}, {}
                    for pmask = 0, (2 ^ n_prob) - 1 do
                        local pcfg = {}
                        for i = 1, n_prob do
                            pcfg[i] = (math.floor(pmask / (2 ^ (i - 1))) % 2) == 1
                        end
                        for ridx = 0, range_total - 1 do
                            local rcfg, tmp = {}, ridx
                            for i, iv in ipairs(range_events) do
                                local span = iv[2] - iv[1] + 1
                                rcfg[i] = iv[1] + (tmp % span)
                                tmp = math.floor(tmp / span)
                            end
                            local _, s = compute_predicted_score(
                                played, held, pcfg, rcfg)
                            if not seen[s] then
                                seen[s] = true
                                possible[#possible + 1] = s
                            end
                        end
                    end
                    table.sort(possible)
                    fixture.possible_scores = possible
                end
            end)
            if not ok then
                print("[BestHand] capture pre-error: " .. tostring(err))
            end
        end

        original_evaluate_play(e)

        if fixture then
            local ok, err = pcall(function()
                fixture.actual_score = math.floor(SMODS.calculate_round_score())

                if fixture.predicted_score then
                    local actual = fixture.actual_score
                    local possible = fixture.possible_scores
                    local hn = tostring(fixture.hand_name or "?")

                    local matched = (actual == fixture.predicted_score)
                    if not matched and possible then
                        for _, s in ipairs(possible) do
                            if s == actual then matched = true; break end
                        end
                    end

                    local tag
                    if matched then
                        tag = possible
                            and ("MATCH (1 of " .. #possible .. " possible)")
                            or "MATCH"
                    elseif possible then
                        local closest = possible[1]
                        for _, s in ipairs(possible) do
                            if math.abs(s - actual) < math.abs(closest - actual) then
                                closest = s
                            end
                        end
                        tag = string.format(
                            "MISS (actual not in %d possible, closest %s off by %s)",
                            #possible,
                            format_number(closest),
                            format_number(actual - closest))
                    else
                        local delta = actual - fixture.predicted_score
                        tag = "(off by " .. format_number(delta) .. ")"
                    end
                    print(string.format("[BestHand] %s: predicted %s, actual %s  %s",
                        hn,
                        format_number(fixture.predicted_score),
                        format_number(actual),
                        tag))
                end

                write_capture(fixture)
            end)
            if not ok then
                print("[BestHand] capture post-error: " .. tostring(err))
            end
        end
    end
end

SMODS.Keybind({
    key_pressed = "f4",
    action = function(self)
        capture_enabled = not capture_enabled
        if capture_enabled then
            print("[BestHand] capture ENABLED — each played hand will be recorded")
        else
            print("[BestHand] capture disabled")
        end
    end
})
