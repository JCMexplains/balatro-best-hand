-- replay.lua — load the real BestHand.lua and run score_combo on
-- capture_20260411_082018_1.lua, with the actual helpers (not a
-- Python re-implementation).

-------------------------------------------------------------------------
-- Stub the Balatro globals that BestHand.lua touches at load time.
-------------------------------------------------------------------------
SMODS = {}
function SMODS.Keybind(_) end
function SMODS.calculate_round_score() return 0 end

love = {
    filesystem = {
        getSaveDirectory = function() return "." end,
        createDirectory  = function() end,
    },
}

G = {
    FUNCS        = {},
    GAME         = {},
    jokers       = { cards = {} },
    hand         = { cards = {} },
    play         = { cards = {} },
    playing_cards = {},
    deck         = { cards = {} },
}

-- Minimal poker-hand detector — only has to handle this fixture (Flush).
-- Called from score_combo at the top and (for Straight/SF/RF) inside
-- get_straight_members. For this fixture it's only the top call.
function G.FUNCS.get_poker_hand_info(cards)
    if not cards or #cards == 0 then return "High Card", nil, {} end
    if #cards == 5 then
        -- Smeared is active → H+D merged, S+C merged
        local h, d, c, s = 0, 0, 0, 0
        for _, card in ipairs(cards) do
            local su = card.base.suit
            if su == "Hearts"   then h = h + 1
            elseif su == "Diamonds" then d = d + 1
            elseif su == "Clubs"    then c = c + 1
            elseif su == "Spades"   then s = s + 1
            end
        end
        if (h + d) == 5 or (c + s) == 5 or h == 5 or d == 5 or c == 5 or s == 5 then
            return "Flush", nil, {}
        end
    end
    return "High Card", nil, {}
end

-- Exists only so BestHand.lua's F4 hook can wrap it.
function G.FUNCS.evaluate_play(e) end

-------------------------------------------------------------------------
-- Load BestHand.lua source and append an export block so we can reach
-- the local functions from outside the chunk.
-------------------------------------------------------------------------
local path = "BestHand.lua"
local f = assert(io.open(path, "r"))
local src = f:read("*a")
f:close()

src = src .. [[

_G._BH = {
    score_combo          = score_combo,
    resolve_jokers       = resolve_jokers,
    get_scoring_cards    = get_scoring_cards,
    get_triggers         = get_triggers,
    get_flush_members    = get_flush_members,
    eval_per_card_jokers = eval_per_card_jokers,
    eval_flat_jokers     = eval_flat_jokers,
    apply_edition        = apply_edition,
    count_suits          = count_suits,
    has_smeared_joker    = has_smeared_joker,
    is_flint_active      = is_flint_active,
}
]]

local chunk = assert(loadstring(src, "BestHand"))
chunk()
assert(_BH and _BH.score_combo, "failed to export score_combo")

-------------------------------------------------------------------------
-- Rehydrate the fixture as live card/joker objects that look like
-- Balatro's own runtime tables.
-------------------------------------------------------------------------
local function make_card(t)
    return {
        base = {
            id      = t.id,
            suit    = t.suit,
            nominal = t.nominal,
            value   = t.value or tostring(t.id),
        },
        ability = {
            name        = t.ability or "Default Base",
            perma_bonus = 0,
            extra       = t.extra,
        },
        edition = t.edition,
        seal    = t.seal,
        debuff  = false,
    }
end

local function make_joker(t)
    return {
        ability = {
            name        = t.name,
            mult        = t.mult       or 0,
            x_mult      = t.x_mult     or 1,
            chips       = t.chips      or 0,
            t_mult      = t.t_mult     or 0,
            t_chips     = t.t_chips    or 0,
            extra       = t.extra,
            remaining   = t.remaining,
            perma_bonus = 0,
        },
        edition = t.edition,
        debuff  = false,
    }
end

local played = {
    make_card({ id = 5,  nominal = 5,  suit = "Hearts"   }),
    make_card({ id = 4,  nominal = 4,  suit = "Hearts"   }),
    make_card({ id = 13, nominal = 10, suit = "Diamonds", ability = "Mult"       }),
    make_card({ id = 12, nominal = 10, suit = "Diamonds", ability = "Lucky Card" }),
    make_card({ id = 11, nominal = 10, suit = "Diamonds", ability = "Lucky Card" }),
}

local held = {
    make_card({ id = 10, nominal = 10, suit = "Spades" }),
    make_card({ id =  8, nominal =  8, suit = "Spades" }),
    make_card({ id = 13, nominal = 10, suit = "Clubs", ability = "Mult" }),
}

local all_cards = {}
for _, c in ipairs(played) do all_cards[#all_cards + 1] = c end
for _, c in ipairs(held)   do all_cards[#all_cards + 1] = c end

G.jokers.cards = {
    make_joker({ name = "To Do List",       edition = { negative = true }, extra = { dollars = 4, poker_hand = "High Card" } }),
    make_joker({ name = "Cartomancer"       }),
    make_joker({ name = "Smeared Joker"     }),
    make_joker({ name = "Walkie Talkie",    extra = { chips = 10, mult = 4 } }),
    make_joker({ name = "Crafty Joker",     edition = { holo = true }, t_chips = 80 }),
    make_joker({ name = "Driver's License", x_mult = 1 }),
}

G.GAME = {
    dollars = 5,
    blind   = { name = "Small Blind", disabled = false },
    current_round = {
        hands_left    = 2,
        discards_left = 4,
        dollars       = 10,
        ancient_card  = { suit = "Diamonds" },
        idol_card     = { id = 2, suit = "Hearts", rank = "2" },
    },
    hands = {
        ["High Card"]       = { level = 1, chips =   5, mult =  1, played = 0, played_this_round = 0, visible = true  },
        Pair                = { level = 1, chips =  10, mult =  2, played = 0, played_this_round = 0, visible = true  },
        ["Two Pair"]        = { level = 1, chips =  20, mult =  2, played = 5, played_this_round = 1, visible = true  },
        ["Three of a Kind"] = { level = 1, chips =  30, mult =  3, played = 0, played_this_round = 0, visible = true  },
        Straight            = { level = 1, chips =  30, mult =  4, played = 0, played_this_round = 0, visible = true  },
        Flush               = { level = 1, chips =  35, mult =  4, played = 7, played_this_round = 0, visible = true  },
        ["Full House"]      = { level = 1, chips =  40, mult =  4, played = 1, played_this_round = 0, visible = true  },
        ["Four of a Kind"]  = { level = 1, chips =  60, mult =  7, played = 0, played_this_round = 0, visible = true  },
        ["Straight Flush"]  = { level = 1, chips = 100, mult =  8, played = 0, played_this_round = 0, visible = true  },
        ["Five of a Kind"]  = { level = 1, chips = 120, mult = 12, played = 0, played_this_round = 0, visible = false },
        ["Flush House"]     = { level = 1, chips = 140, mult = 14, played = 0, played_this_round = 0, visible = false },
        ["Flush Five"]      = { level = 1, chips = 160, mult = 16, played = 0, played_this_round = 0, visible = false },
    },
}

G.playing_cards = {}
for _, c in ipairs(all_cards) do G.playing_cards[#G.playing_cards + 1] = c end
G.deck.cards = {}
for i = 1, 38 do G.deck.cards[i] = {} end

-------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------
print("=== capture_20260411_082018_1.lua replay ===")
print("Played: 5h, 4h, Kd(Mult), Qd(Lucky), Jd(Lucky)")
print("Jokers: To Do List(neg), Cartomancer, Smeared, Walkie Talkie, Crafty(holo), Driver's License")
print()

local hand_name, total, scoring, used_ev = _BH.score_combo(played, all_cards)
print(string.format("[score_combo] hand_name=%s score=%s used_ev=%s",
    tostring(hand_name), tostring(total), tostring(used_ev)))
print(string.format("[fixture]     predicted=4920  actual=6888  (delta %+d)",
    6888 - (total or 0)))
print()

-------------------------------------------------------------------------
-- Phase-by-phase trace, calling the real helpers.
-------------------------------------------------------------------------
print("============ TRACE ============")
local rank_name = {[2]="2",[3]="3",[4]="4",[5]="5",[6]="6",[7]="7",[8]="8",[9]="9",
                   [10]="T",[11]="J",[12]="Q",[13]="K",[14]="A"}
local suitch = { Hearts="h", Diamonds="d", Clubs="c", Spades="s" }
local function lbl(card) return rank_name[card.base.id]..suitch[card.base.suit] end

local played_set = {}
for _, c in ipairs(played) do played_set[c] = true end

hand_name = "Flush"
local hinfo = G.GAME.hands[hand_name]
local chips, mult = hinfo.chips, hinfo.mult
print(string.format("base %-10s chips=%-4d mult=%-4g", hand_name, chips, mult))

local resolved = _BH.resolve_jokers()
print(string.format("resolved jokers: %d", #resolved))
for i, j in ipairs(resolved) do print(string.format("  [%d] %s", i, j.name)) end

local pareidolia = false
for _, j in ipairs(resolved) do if j.name == "Pareidolia" then pareidolia = true; break end end

local scoring_cards = _BH.get_scoring_cards(played, hand_name)
print(string.format("scoring cards: %d", #scoring_cards))

local state = {
    photo_card = nil, used_ev = false,
    prob_idx = 0, prob_config = nil,
    range_idx = 0, range_config = nil,
}

print()
print("-- Phase 1: per-card --")
for idx, card in ipairs(scoring_cards) do
    if not card.debuff then
        local triggers = _BH.get_triggers(card, idx, false, pareidolia)
        print(string.format("  card[%d] %s enh=%s triggers=%d",
            idx, lbl(card), card.ability.name, triggers))
        for _ = 1, triggers do
            local a, b = chips, mult
            chips = chips + (card.base.nominal or 0)
            print(string.format("    +%d nominal             → chips=%d mult=%g", card.base.nominal, chips, mult))

            local ename = card.ability.name
            a, b = chips, mult
            if     ename == "Bonus"      then chips = chips + 30
            elseif ename == "Mult"       then mult  = mult + 4
            elseif ename == "Glass Card" then mult  = mult * 2
            elseif ename == "Stone Card" then chips = chips + 50
            elseif ename == "Lucky Card" then mult  = mult + 4; state.used_ev = true
            end
            if chips ~= a or mult ~= b then
                print(string.format("    enh %-12s       → chips=%d mult=%g", ename, chips, mult))
            end
            chips = chips + (card.ability.perma_bonus or 0)

            a, b = chips, mult
            chips, mult = _BH.apply_edition(card.edition, chips, mult)
            if chips ~= a or mult ~= b then
                print(string.format("    edition                → chips=%d mult=%g", chips, mult))
            end

            a, b = chips, mult
            chips, mult = _BH.eval_per_card_jokers(card, resolved, chips, mult, state, pareidolia)
            if chips ~= a or mult ~= b then
                print(string.format("    per-card jokers Δ %+d/%+g → chips=%d mult=%g",
                    chips - a, mult - b, chips, mult))
            end
        end
    end
end
print(string.format("after Phase 1: chips=%d mult=%g", chips, mult))

print()
print("-- Phase 2: held-in-hand --")
local phase2_start_c, phase2_start_m = chips, mult
local has_baron, baron_count = false, 0
local has_shoot_moon, shoot_moon_count = false, 0
for _, j in ipairs(resolved) do
    if j.name == "Baron" then has_baron = true; baron_count = baron_count + 1 end
    if j.name == "Shoot the Moon" then has_shoot_moon = true; shoot_moon_count = shoot_moon_count + 1 end
end
local any_held_fired = false
for _, card in ipairs(all_cards) do
    if not played_set[card] and not card.debuff then
        local is_steel = card.ability and card.ability.name == "Steel Card"
        local is_king  = card.base.id == 13
        local is_queen = card.base.id == 12
        if is_steel or (has_baron and is_king) or (has_shoot_moon and is_queen) then
            any_held_fired = true
            print(string.format("  held %s steel=%s king=%s queen=%s", lbl(card),
                tostring(is_steel), tostring(is_king), tostring(is_queen)))
        end
    end
end
if not any_held_fired then print("  (nothing fired)") end
print(string.format("after Phase 2: chips=%d mult=%g  (Δ chips %+d mult %+g)",
    chips, mult, chips - phase2_start_c, mult - phase2_start_m))

print()
print("-- Phase 3: flat jokers (one at a time) --")
for i, j in ipairs(resolved) do
    local a, b = chips, mult
    local ctx = {
        hand_name  = hand_name,
        all_cards  = all_cards,
        played     = played_set,
        num_played = #played,
        suits      = _BH.count_suits(scoring_cards),
        full_hand  = played,
    }
    chips, mult = _BH.eval_flat_jokers({j}, chips, mult, ctx, state)
    print(string.format("  [%d] %-20s Δchips %+d Δmult %+g  → chips=%d mult=%g",
        i, j.name, chips - a, mult - b, chips, mult))
end

print()
print(string.format("FINAL: %d × %g = %g (floor=%d)",
    chips, mult, chips * mult, math.floor(chips * mult)))
print(string.format("predicted=4920 actual=6888 delta=%+d", 6888 - math.floor(chips * mult)))
