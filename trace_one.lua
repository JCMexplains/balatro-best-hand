-- trace_one.lua <capture_path>
-- Load a saved fixture and replay it through the real score_combo with
-- a full phase-by-phase trace. Use this to investigate a single miss.

local capture_path = arg[1]
if not capture_path then
    print("usage: lua trace_one.lua <capture.lua>")
    os.exit(1)
end

-------------------------------------------------------------------------
-- Same stubs as batch_verify.lua
-------------------------------------------------------------------------
SMODS = {}
function SMODS.Keybind(_) end
function SMODS.calculate_round_score() return 0 end
love = { filesystem = {
    getSaveDirectory = function() return "." end,
    createDirectory  = function() end,
} }
G = {
    FUNCS = {}, GAME = {}, jokers = { cards = {} },
    hand = { cards = {} }, play = { cards = {} },
    playing_cards = {}, deck = { cards = {} },
}

local function detect_hand(cards)
    if not cards or #cards == 0 then return "High Card", nil, {} end
    local plain_sc = { Hearts = 0, Diamonds = 0, Clubs = 0, Spades = 0 }
    local wild_count = 0
    local rank_cards = {}
    for _, c in ipairs(cards) do
        local en = c.ability and c.ability.name
        if en == "Stone Card" then
            -- excluded from all groupings
        elseif en == "Wild Card" then
            wild_count = wild_count + 1
            rank_cards[#rank_cards + 1] = c
        else
            if plain_sc[c.base.suit] then
                plain_sc[c.base.suit] = plain_sc[c.base.suit] + 1
            end
            rank_cards[#rank_cards + 1] = c
        end
    end
    local smeared, four_fingers = false, false
    if G.jokers and G.jokers.cards then
        for _, j in ipairs(G.jokers.cards) do
            local n = j.ability and j.ability.name
            if n == "Smeared Joker" then smeared = true end
            if n == "Four Fingers"  then four_fingers = true end
        end
    end
    local min_run = four_fingers and 4 or 5
    local is_flush = false
    if #rank_cards >= min_run then
        for _, n in pairs(plain_sc) do
            if n + wild_count >= min_run then is_flush = true; break end
        end
        if not is_flush and smeared then
            if plain_sc.Hearts + plain_sc.Diamonds + wild_count >= min_run
                or plain_sc.Clubs + plain_sc.Spades + wild_count >= min_run then
                is_flush = true
            end
        end
    end
    local ids, seen = {}, {}
    for _, c in ipairs(rank_cards) do
        local id = c.base.id
        if not seen[id] then seen[id] = true; ids[#ids+1] = id end
    end
    table.sort(ids)
    local is_straight = false
    if #ids >= min_run then
        local run = 1
        for i = 2, #ids do
            if ids[i] - ids[i-1] == 1 then
                run = run + 1
                if run >= min_run then is_straight = true; break end
            else run = 1 end
        end
        if not is_straight and seen[14] and seen[2] and seen[3]
            and seen[4] and (seen[5] or four_fingers) then
            is_straight = true
        end
    end
    local groups = {}
    for _, c in ipairs(rank_cards) do
        groups[c.base.id] = (groups[c.base.id] or 0) + 1
    end
    local counts = {}
    for _, n in pairs(groups) do counts[#counts+1] = n end
    table.sort(counts, function(a,b) return a > b end)
    local c1, c2 = counts[1] or 0, counts[2] or 0
    if is_flush and is_straight then
        if seen[10] and seen[11] and seen[12] and seen[13] and seen[14] then
            return "Royal Flush", nil, {}
        end
        return "Straight Flush", nil, {}
    end
    if c1 == 5 and is_flush then return "Flush Five", nil, {} end
    if c1 == 5 then return "Five of a Kind", nil, {} end
    if c1 == 3 and c2 == 2 and is_flush then return "Flush House", nil, {} end
    if c1 == 4 then return "Four of a Kind", nil, {} end
    if c1 == 3 and c2 == 2 then return "Full House", nil, {} end
    if is_flush then return "Flush", nil, {} end
    if is_straight then return "Straight", nil, {} end
    if c1 == 3 then return "Three of a Kind", nil, {} end
    if c1 == 2 and c2 == 2 then return "Two Pair", nil, {} end
    if c1 == 2 then return "Pair", nil, {} end
    return "High Card", nil, {}
end

function G.FUNCS.get_poker_hand_info(cards) return detect_hand(cards) end
function G.FUNCS.evaluate_play(e) end

-------------------------------------------------------------------------
-- Load BestHand.lua with exports
-------------------------------------------------------------------------
local f = assert(io.open("BestHand.lua", "r"))
local src = f:read("*a")
f:close()
src = src .. [[

_G._BH = {
    score_combo          = score_combo,
    resolve_jokers       = resolve_jokers,
    get_scoring_cards    = get_scoring_cards,
    get_triggers         = get_triggers,
    eval_per_card_jokers = eval_per_card_jokers,
    eval_flat_jokers     = eval_flat_jokers,
    apply_edition        = apply_edition,
    count_suits          = count_suits,
}
]]
local chunk = assert(loadstring(src, "BestHand"))
chunk()

-------------------------------------------------------------------------
-- Load fixture and install into G.
--
-- Sandboxed: captures are Lua source (`return { ... }`) and a bare
-- dofile() would execute anything the file contains with full
-- privileges (io, os.execute, require). That's fine for captures you
-- produced locally but risky for ones from bug reports or other
-- users. Parse the file in an empty env exposing only `math.huge`
-- (the one global the serializer is allowed to emit, for ±infinity).
-- Table/string/number/bool/nil literals don't touch the env, so a
-- well-formed capture loads unchanged; any attempt to reach for io,
-- os, require, etc. fails on a nil index.
-------------------------------------------------------------------------
local function load_fixture(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local src = f:read("*a")
    f:close()
    local chunk = assert(loadstring(src, path))
    setfenv(chunk, { math = { huge = math.huge } })
    return chunk()
end

local fx = assert(load_fixture(capture_path))

local function ensure_card(t)
    t.ability = t.ability or {}
    t.ability.perma_bonus = t.ability.perma_bonus or 0
    t.debuff = t.debuff or false
    return t
end
local function ensure_joker(t)
    t.ability = t.ability or {}
    t.ability.mult = t.ability.mult or 0
    t.ability.x_mult = t.ability.x_mult or 1
    t.ability.chips = t.ability.chips or 0
    t.ability.t_mult = t.ability.t_mult or 0
    t.ability.t_chips = t.ability.t_chips or 0
    t.ability.perma_bonus = t.ability.perma_bonus or 0
    t.debuff = t.debuff or false
    return t
end

local played, held = {}, {}
for i, c in ipairs(fx.played) do played[i] = ensure_card(c) end
for i, c in ipairs(fx.held)   do held[i]   = ensure_card(c) end

G.jokers.cards = {}
for i, j in ipairs(fx.jokers) do G.jokers.cards[i] = ensure_joker(j) end

G.GAME = {
    hands         = fx.game.hands or {},
    current_round = fx.game.current_round or {},
    blind         = fx.game.blind or { name = "", disabled = false },
    dollars       = fx.game.dollars or 0,
}

local all_cards = {}
for _, c in ipairs(played) do all_cards[#all_cards + 1] = c end
for _, c in ipairs(held)   do all_cards[#all_cards + 1] = c end

G.playing_cards = {}
for _, c in ipairs(all_cards) do G.playing_cards[#G.playing_cards+1] = c end

-- Pad G.playing_cards with dummy Steel Cards if the capture recorded
-- the full-deck Steel Card count (for Steel Joker).
local steel_target = fx.game and fx.game.steel_card_count
if steel_target then
    local steel_have = 0
    for _, c in ipairs(G.playing_cards) do
        if c.ability and c.ability.name == "Steel Card" then
            steel_have = steel_have + 1
        end
    end
    for _ = 1, steel_target - steel_have do
        G.playing_cards[#G.playing_cards + 1] = {
            ability = { name = "Steel Card" },
            base = { id = 0, suit = "Spades", nominal = 0 },
            debuff = false,
        }
    end
end

G.deck.cards = {}
for i = 1, (fx.game.deck_remaining or 0) do G.deck.cards[i] = {} end

-------------------------------------------------------------------------
-- Trace
-------------------------------------------------------------------------
local rank_name = {[2]="2",[3]="3",[4]="4",[5]="5",[6]="6",[7]="7",[8]="8",
                   [9]="9",[10]="T",[11]="J",[12]="Q",[13]="K",[14]="A"}
local suitch = { Hearts="h", Diamonds="d", Clubs="c", Spades="s" }
local function lbl(card)
    local rk = rank_name[card.base.id] or "?"
    local sc = suitch[card.base.suit] or "?"
    local enh = card.ability and card.ability.name or ""
    local tag = ""
    if enh and enh ~= "" and enh ~= "Default Base" then
        tag = "(" .. enh .. ")"
    end
    return rk .. sc .. tag
end

print(string.format("=== %s ===", capture_path:match("[^/\\]+$") or capture_path))
print(string.format("hand_name=%s  actual=%s  stored_predicted=%s",
    tostring(fx.hand_name), tostring(fx.actual_score), tostring(fx.predicted_score)))
print()
print("Played:")
for i, c in ipairs(played) do
    print(string.format("  [%d] %s", i, lbl(c)))
end
print("Held:")
for i, c in ipairs(held) do
    print(string.format("  [%d] %s", i, lbl(c)))
end
print("Jokers:")
for i, j in ipairs(G.jokers.cards) do
    local ed = ""
    if j.edition then
        for k, v in pairs(j.edition) do if v then ed = ed .. " " .. k end end
    end
    print(string.format("  [%d] %s%s", i, j.ability.name, ed))
end
print()

-- Full score_combo result
local hand_name, total, scoring_cards, used_ev, n_prob =
    _BH.score_combo(played, all_cards)
print(string.format("score_combo → hand=%s score=%s used_ev=%s n_prob=%s",
    tostring(hand_name), tostring(total), tostring(used_ev), tostring(n_prob)))
print()

-- Manual phase trace re-using the real helpers
print("============ TRACE ============")
local hinfo = G.GAME.hands[hand_name]
local chips, mult = hinfo.chips, hinfo.mult
print(string.format("base %s  chips=%d mult=%g  (level %d)",
    hand_name, chips, mult, hinfo.level or 1))

if (G.GAME.blind and G.GAME.blind.name) == "The Flint" then
    print("  Flint active: chips and mult each halved (ceil)")
end

local played_set = {}
for _, c in ipairs(played) do played_set[c] = true end

local resolved = _BH.resolve_jokers()
print(string.format("resolved jokers: %d", #resolved))

local pareidolia = false
for _, j in ipairs(resolved) do
    if j.name == "Pareidolia" then pareidolia = true; break end
end

local scoring = _BH.get_scoring_cards(played, hand_name)
print(string.format("scoring cards: %d", #scoring))
for i, c in ipairs(scoring) do
    print(string.format("  [%d] %s", i, lbl(c)))
end

local state = { photo_card = nil, used_ev = false,
                prob_idx = 0, prob_config = nil,
                range_idx = 0, range_config = nil }

print()
print("-- Phase 1: per-card --")
for idx, card in ipairs(scoring) do
    if not card.debuff then
        local triggers = _BH.get_triggers(card, idx, false, pareidolia)
        print(string.format("  card[%d] %s triggers=%d", idx, lbl(card), triggers))
        for t = 1, triggers do
            local a, b = chips, mult
            chips = chips + (card.base.nominal or 0)
            print(string.format("    t%d +%d nominal            → chips=%d mult=%g",
                t, card.base.nominal or 0, chips, mult))

            local ename = card.ability.name
            a, b = chips, mult
            if     ename == "Bonus"      then chips = chips + 30
            elseif ename == "Mult"       then mult  = mult + 4
            elseif ename == "Glass Card" then mult  = mult * 2
            elseif ename == "Stone Card" then chips = chips + 50
            elseif ename == "Lucky Card" then mult  = mult + 4; state.used_ev = true
            end
            if chips ~= a or mult ~= b then
                print(string.format("        enh %-12s      → chips=%d mult=%g", ename, chips, mult))
            end
            chips = chips + (card.ability.perma_bonus or 0)

            a, b = chips, mult
            chips, mult = _BH.apply_edition(card.edition, chips, mult)
            if chips ~= a or mult ~= b then
                print(string.format("        edition              → chips=%d mult=%g", chips, mult))
            end

            a, b = chips, mult
            chips, mult = _BH.eval_per_card_jokers(card, resolved, chips, mult, state, pareidolia)
            if chips ~= a or mult ~= b then
                print(string.format("        per-card Δ %+d/%+g → chips=%d mult=%g",
                    chips - a, mult - b, chips, mult))
            end
        end
    end
end
print(string.format("after Phase 1: chips=%d mult=%g", chips, mult))

print()
print("-- Phase 2: held-in-hand --")
local any = false
local has_baron, baron_count = false, 0
local has_moon, moon_count = false, 0
for _, j in ipairs(resolved) do
    if j.name == "Baron" then has_baron = true; baron_count = baron_count + 1 end
    if j.name == "Shoot the Moon" then has_moon = true; moon_count = moon_count + 1 end
end
for _, card in ipairs(all_cards) do
    if not played_set[card] and not card.debuff then
        local is_steel = card.ability and card.ability.name == "Steel Card"
        local is_king  = card.base.id == 13
        local is_queen = card.base.id == 12
        if is_steel or (has_baron and is_king) or (has_moon and is_queen) then
            any = true
            local triggers = _BH.get_triggers(card, 0, true, pareidolia)
            for _ = 1, triggers do
                if is_steel then
                    mult = mult * 1.5
                end
                if has_baron and is_king then
                    for _ = 1, baron_count do mult = mult * 1.5 end
                end
                if has_moon and is_queen then
                    mult = mult + 13 * moon_count
                end
            end
            print(string.format("  held %s → chips=%d mult=%g", lbl(card), chips, mult))
        end
    end
end
if not any then print("  (nothing fired)") end
print(string.format("after Phase 2: chips=%d mult=%g", chips, mult))

print()
print("-- Phase 3: flat jokers --")
for i, j in ipairs(resolved) do
    local a, b = chips, mult
    local ctx = {
        hand_name  = hand_name,
        all_cards  = all_cards,
        played     = played_set,
        num_played = #played,
        suits      = _BH.count_suits(scoring),
        full_hand  = played,
    }
    chips, mult = _BH.eval_flat_jokers({j}, chips, mult, ctx, state)
    if chips ~= a or mult ~= b then
        print(string.format("  [%d] %-20s Δchips %+d Δmult %+g  → chips=%d mult=%g",
            i, j.name, chips - a, mult - b, chips, mult))
    else
        print(string.format("  [%d] %-20s (no change)", i, j.name))
    end
end

print()
print(string.format("FINAL: %d × %g = %g (floor=%d)",
    chips, mult, chips * mult, math.floor(chips * mult)))
print(string.format("actual=%s  stored_predicted=%s",
    tostring(fx.actual_score), tostring(fx.predicted_score)))
