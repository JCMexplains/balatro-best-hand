-- batch_verify.lua — replay every saved capture through the real
-- BestHand.lua score_combo with 2^N probabilistic enumeration, and
-- report MATCH / MATCH-via-variance / MISS.
--
-- Usage: lua batch_verify.lua [captures_dir]
-- Default captures_dir: ../../best_hand_captures (Balatro save dir
-- relative to the mod directory).

-------------------------------------------------------------------------
-- Stub the Balatro globals BestHand.lua touches at load time.
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

-------------------------------------------------------------------------
-- Minimal poker-hand detector. score_combo calls
-- G.FUNCS.get_poker_hand_info both with the full played set and (for
-- Straight / SF / RF hands) with subsets during get_straight_members.
-- Handles Smeared Joker suit merging and Four Fingers threshold.
-------------------------------------------------------------------------
-- Minimal stand-in for Balatro's G.FUNCS.get_poker_hand_info.
-- Must handle Wild Card (counts as any suit for flush detection),
-- Stone Card (excluded from flush/straight/pair groupings), Smeared
-- Joker (H+D and S+C merge), and Four Fingers (min_run drops to 4).
local function detect_hand(cards)
    if not cards or #cards == 0 then return "High Card", nil, {} end

    -- Split into plain / wild / stone, since each participates
    -- differently in hand detection.
    local plain_sc = { Hearts = 0, Diamonds = 0, Clubs = 0, Spades = 0 }
    local wild_count = 0
    local rank_cards = {}  -- cards that participate in rank groups
    for _, c in ipairs(cards) do
        local en = c.ability and c.ability.name
        if en == "Stone Card" then
            -- Stone Cards don't contribute to flush/straight/pair detection
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

    -- Flush: any suit (+ wild cards) reaches min_run
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

    -- Straight: unique consecutive IDs with wheel A-2-3-4-5
    local ids, seen = {}, {}
    for _, c in ipairs(rank_cards) do
        local id = c.base.id
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    table.sort(ids)

    local is_straight = false
    if #ids >= min_run then
        local run = 1
        for i = 2, #ids do
            if ids[i] - ids[i - 1] == 1 then
                run = run + 1
                if run >= min_run then is_straight = true; break end
            else
                run = 1
            end
        end
        if not is_straight and seen[14] and seen[2] and seen[3]
            and seen[4] and (seen[5] or four_fingers) then
            is_straight = true
        end
    end

    -- Rank multiplicities (Stone Cards excluded above)
    local groups = {}
    for _, c in ipairs(rank_cards) do
        groups[c.base.id] = (groups[c.base.id] or 0) + 1
    end
    local counts = {}
    for _, n in pairs(groups) do counts[#counts + 1] = n end
    table.sort(counts, function(a, b) return a > b end)
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
    if is_flush   then return "Flush", nil, {} end
    if is_straight then return "Straight", nil, {} end
    if c1 == 3 then return "Three of a Kind", nil, {} end
    if c1 == 2 and c2 == 2 then return "Two Pair", nil, {} end
    if c1 == 2 then return "Pair", nil, {} end
    return "High Card", nil, {}
end

function G.FUNCS.get_poker_hand_info(cards) return detect_hand(cards) end
function G.FUNCS.evaluate_play(e) end

-------------------------------------------------------------------------
-- Load BestHand.lua with export block
-------------------------------------------------------------------------
local f = assert(io.open("BestHand.lua", "r"))
local src = f:read("*a")
f:close()
src = src .. "\n_G._BH = { score_combo = score_combo }\n"
local chunk = assert(loadstring(src, "BestHand"))
chunk()
assert(_BH and _BH.score_combo, "score_combo export failed")

-------------------------------------------------------------------------
-- Rehydrate a saved fixture into live G state, then score it.
-------------------------------------------------------------------------
local function ensure_card(t)
    -- Captures already store the shape score_combo expects. Just
    -- guarantee the few fields that may be absent.
    t.ability = t.ability or {}
    t.ability.perma_bonus = t.ability.perma_bonus or 0
    t.base    = t.base or {}
    t.debuff  = t.debuff or false
    return t
end

local function ensure_joker(t)
    t.ability   = t.ability or {}
    t.ability.mult     = t.ability.mult     or 0
    t.ability.x_mult   = t.ability.x_mult   or 1
    t.ability.chips    = t.ability.chips    or 0
    t.ability.t_mult   = t.ability.t_mult   or 0
    t.ability.t_chips  = t.ability.t_chips  or 0
    t.ability.perma_bonus = t.ability.perma_bonus or 0
    t.debuff = t.debuff or false
    return t
end

local function install_fixture(fx)
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

    G.playing_cards = {}
    for _, c in ipairs(played) do G.playing_cards[#G.playing_cards + 1] = c end
    for _, c in ipairs(held)   do G.playing_cards[#G.playing_cards + 1] = c end

    -- If the capture recorded the total Steel Card count across the full
    -- deck (for Steel Joker), pad G.playing_cards with dummy Steel Cards
    -- so the offline count matches the live game.
    local steel_target = fx.game.steel_card_count
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

    return played, held
end

local function score_fixture(fx)
    local played, held = install_fixture(fx)
    local all = {}
    for _, c in ipairs(played) do all[#all + 1] = c end
    for _, c in ipairs(held)   do all[#all + 1] = c end

    local _, ev_score, _, _, n_prob, range_events =
        _BH.score_combo(played, all, nil, nil)
    n_prob = n_prob or 0
    range_events = range_events or {}
    local n_range = #range_events

    -- Discrete enumeration over the cartesian product of boolean probs
    -- (Lucky/Bloodstone) × each Misprint integer in [min, max].
    local possible, seen = {}, {}
    local function add(s)
        if not seen[s] then
            seen[s] = true
            possible[#possible + 1] = s
        end
    end

    local range_total = 1
    for _, iv in ipairs(range_events) do
        range_total = range_total * (iv[2] - iv[1] + 1)
    end
    local total_configs = (2 ^ n_prob) * range_total

    if (n_prob + n_range) == 0 then
        add(ev_score)
    elseif n_prob <= 10 and total_configs <= 10000 then
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
                local _, s = _BH.score_combo(played, all, pcfg, rcfg)
                add(s)
            end
        end
    else
        -- Too many configs to enumerate; fall back to EV only.
        add(ev_score)
    end
    table.sort(possible)
    return ev_score, possible, n_prob, n_range, total_configs
end

-------------------------------------------------------------------------
-- Walk captures dir
-------------------------------------------------------------------------
local captures_dir = arg[1] or "../../best_hand_captures"

local function list_files(dir)
    local out = {}
    -- Lua for Windows uses cmd.exe for io.popen, so try `dir /b` first.
    local win_dir = dir:gsub("/", "\\")
    local p = io.popen('dir /b "' .. win_dir .. '\\*.lua" 2>nul')
    if p then
        for line in p:lines() do
            out[#out + 1] = dir .. "/" .. line
        end
        p:close()
    end
    if #out == 0 then
        -- Unix fallback
        p = io.popen('ls "' .. dir .. '"/*.lua 2>/dev/null')
        if p then
            for line in p:lines() do out[#out + 1] = line end
            p:close()
        end
    end
    table.sort(out)
    return out
end

local files = list_files(captures_dir)
if #files == 0 then
    print("No captures found in " .. captures_dir)
    os.exit(1)
end

print(string.format("Verifying %d captures from %s", #files, captures_dir))
print()

local function basename(p) return p:match("([^/\\]+)$") or p end

local strict, via_variance, miss = 0, 0, 0
local misses = {}

for _, path in ipairs(files) do
    local ok, fx = pcall(dofile, path)
    if not ok or type(fx) ~= "table" then
        print(string.format("!! %s: failed to load (%s)", basename(path), tostring(fx)))
        miss = miss + 1
    else
        local ok2, ev_score, possible, n_prob, n_range, total_configs =
            pcall(score_fixture, fx)
        if not ok2 then
            print(string.format("!! %s: score error (%s)", basename(path), tostring(ev_score)))
            miss = miss + 1
        else
            local actual = fx.actual_score
            -- For very large scores, floating-point rounding in floor()
            -- can produce ULP differences. Use relative tolerance.
            local hit_exact = (actual == ev_score)
                or (actual ~= 0 and math.abs(actual - ev_score) / math.abs(actual) < 1e-9)
            local hit_any   = false
            local probabilistic = (n_prob + n_range) > 0
            if not hit_exact and probabilistic then
                for _, s in ipairs(possible) do
                    if s == actual then hit_any = true; break end
                end
            end

            local stored = fx.predicted_score
            local regressed = stored and ev_score ~= stored

            if hit_exact then
                strict = strict + 1
                local tag = regressed and
                    string.format(" [REGRESSED from stored %s]", tostring(stored)) or ""
                print(string.format("  ok      %-45s %-16s  ev=%-10s actual=%s%s",
                    basename(path), fx.hand_name, tostring(ev_score),
                    tostring(actual), tag))
            elseif hit_any then
                via_variance = via_variance + 1
                print(string.format("  ok(var) %-45s %-16s  ev=%-10s actual=%-10s (1 of %d possible, n_prob=%d n_range=%d)",
                    basename(path), fx.hand_name, tostring(ev_score),
                    tostring(actual), #possible, n_prob, n_range))
            else
                miss = miss + 1
                misses[#misses + 1] = {
                    file = basename(path), hand = fx.hand_name,
                    ev = ev_score, actual = actual, stored = stored,
                    possible = possible, n_prob = n_prob, n_range = n_range,
                    total_configs = total_configs,
                }
                local tag = regressed and
                    string.format(" [REGRESSED from stored %s]", tostring(stored)) or ""
                print(string.format("  MISS    %-45s %-16s  ev=%-10s actual=%-10s n_prob=%d n_range=%d%s",
                    basename(path), fx.hand_name, tostring(ev_score),
                    tostring(actual), n_prob, n_range, tag))
            end
        end
    end
end

print()
print(string.format("Total: %d   strict match: %d   match via variance: %d   miss: %d",
    #files, strict, via_variance, miss))

if #misses > 0 then
    print()
    print("=== Misses ===")
    for _, m in ipairs(misses) do
        print(string.format("  %s (%s): ev=%s actual=%s",
            m.file, m.hand, tostring(m.ev), tostring(m.actual)))
        if (m.n_prob + m.n_range) > 0 then
            local line = "    possible (" .. #m.possible .. "): "
            local shown = math.min(12, #m.possible)
            for i = 1, shown do
                line = line .. tostring(m.possible[i])
                if i < shown then line = line .. ", " end
            end
            if #m.possible > shown then
                line = line .. ", … (" .. (#m.possible - shown) .. " more)"
            end
            print(line)
        end
    end
end

os.exit(miss == 0 and 0 or 1)
