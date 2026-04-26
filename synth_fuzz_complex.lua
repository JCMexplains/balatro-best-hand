-- synth_fuzz_complex.lua — like synth_fuzz.lua but biased toward
-- "lots of interaction" setups: 5 played + held cards, 4-5 jokers,
-- high enhancement/edition/seal rate, retrigger-heavy joker pool,
-- straight-flush / four-of-a-kind / full-house biased hands.
--
-- The oracle is Balatro's real G.FUNCS.evaluate_play. The mod is
-- BestHand's score_combo. We avoid probabilistic effects entirely
-- so the two pipelines are deterministic and any disagreement is
-- a real mod bug.
--
-- Usage: lua synth_fuzz_complex.lua [N] [out_dir]
--   N        number of fixtures to try (default 10000)
--   out_dir  miss capture directory (default best_hand_captures)

local H = dofile('harness.lua')
H.load_besthand()
H.enable_oracle()

local N        = tonumber(arg[1]) or 10000
local OUT_DIR  = arg[2] or 'best_hand_captures'

if not OUT_DIR:match('^[%w%-._ :/\\]+$') then
  io.stderr:write('refusing suspicious out_dir: ' .. OUT_DIR .. '\n')
  os.exit(1)
end

local seed = tonumber(os.getenv('FUZZ_SEED')) or os.time()
math.randomseed(seed)
print(string.format('synth_fuzz_complex: seed=%d  N=%d  out=%s', seed, N, OUT_DIR))

-------------------------------------------------------------------------
-- Joker pool — same deterministic curated list as synth_fuzz.lua, but
-- partitioned so we can guarantee every fixture has at least one
-- "interaction" joker (retriggers, held-card readers, order-sensitive,
-- or per-card readers).
-------------------------------------------------------------------------
local INTERACTION_JOKERS = {
  -- Retriggers / per-card readers
  'Sock and Buskin', 'Hanging Chad', 'Mime', 'Hack', 'Dusk', 'Seltzer',
  'Photograph', 'Smiley Face', 'Scholar',
  'Fibonacci', 'Even Steven', 'Odd Todd',
  -- Held-card readers
  'Raised Fist', 'Baron', 'Shoot the Moon',
  -- Order-sensitive (first/last)
  'Triboulet',
  -- xMult on hand-type
  'The Duo', 'The Trio', 'The Family', 'The Order', 'The Tribe',
}

local FILLER_JOKERS = {
  'Joker', 'Greedy Joker', 'Lusty Joker', 'Wrathful Joker', 'Gluttonous Joker',
  'Jolly Joker', 'Zany Joker', 'Mad Joker', 'Crazy Joker', 'Droll Joker',
  'Sly Joker', 'Wily Joker', 'Clever Joker', 'Devious Joker', 'Crafty Joker',
  'Half Joker', 'Banner', 'Mystic Summit',
  'Pareidolia', 'Smeared Joker', 'Four Fingers', 'Splash',
  'Scary Face', 'Abstract Joker', 'Walkie Talkie',
  'Stone Joker', 'Steel Joker', 'Driver\'s License',
  'Bull', 'Onyx Agate', 'Arrowhead', 'Stuntman',
  'Flower Pot', 'Blackboard', 'Acrobat', 'Swashbuckler',
  'Cavendish', 'Gros Michel',
}

local SAFE_ENHANCEMENTS = { 'Bonus', 'Mult', 'Wild Card', 'Stone Card', 'Steel Card' }
local EDITIONS          = { 'foil', 'holo', 'polychrome' }
local SEALS             = { 'Red', 'Blue', 'Purple' }

local SUITS = { 'Diamonds', 'Clubs', 'Hearts', 'Spades' }
local RANKS = {
  { id = 2,  value = '2', nominal = 2 },
  { id = 3,  value = '3', nominal = 3 },
  { id = 4,  value = '4', nominal = 4 },
  { id = 5,  value = '5', nominal = 5 },
  { id = 6,  value = '6', nominal = 6 },
  { id = 7,  value = '7', nominal = 7 },
  { id = 8,  value = '8', nominal = 8 },
  { id = 9,  value = '9', nominal = 9 },
  { id = 10, value = '10', nominal = 10 },
  { id = 11, value = 'Jack',  nominal = 10 },
  { id = 12, value = 'Queen', nominal = 10 },
  { id = 13, value = 'King',  nominal = 10 },
  { id = 14, value = 'Ace',   nominal = 11 },
}

-- Levels copied from synth_fuzz.lua (game.lua defaults).
local BASE_HANDS = {
  ['High Card']         = { chips =   5, mult =  1, l_chips = 10, l_mult = 1, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips =   5, s_mult =  1 },
  ['Pair']              = { chips =  10, mult =  2, l_chips = 15, l_mult = 1, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips =  10, s_mult =  2 },
  ['Two Pair']          = { chips =  20, mult =  2, l_chips = 20, l_mult = 1, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips =  20, s_mult =  2 },
  ['Three of a Kind']   = { chips =  30, mult =  3, l_chips = 20, l_mult = 2, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips =  30, s_mult =  3 },
  ['Straight']          = { chips =  30, mult =  4, l_chips = 30, l_mult = 3, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips =  30, s_mult =  4 },
  ['Flush']             = { chips =  35, mult =  4, l_chips = 15, l_mult = 2, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips =  35, s_mult =  4 },
  ['Full House']        = { chips =  40, mult =  4, l_chips = 25, l_mult = 2, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips =  40, s_mult =  4 },
  ['Four of a Kind']    = { chips =  60, mult =  7, l_chips = 30, l_mult = 3, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips =  60, s_mult =  7 },
  ['Straight Flush']    = { chips = 100, mult =  8, l_chips = 40, l_mult = 4, level = 1, played = 0, played_this_round = 0, visible = true,  s_chips = 100, s_mult =  8 },
  ['Five of a Kind']    = { chips = 120, mult = 12, l_chips = 35, l_mult = 3, level = 1, played = 0, played_this_round = 0, visible = false, s_chips = 120, s_mult = 12 },
  ['Flush House']       = { chips = 140, mult = 14, l_chips = 40, l_mult = 4, level = 1, played = 0, played_this_round = 0, visible = false, s_chips = 140, s_mult = 14 },
  ['Flush Five']        = { chips = 160, mult = 16, l_chips = 50, l_mult = 3, level = 1, played = 0, played_this_round = 0, visible = false, s_chips = 160, s_mult = 16 },
}

local function pick(t) return t[math.random(#t)] end
local function maybe(p) return math.random() < p end

-- Higher enhancement/edition/seal rates than synth_fuzz.lua so cards
-- light up multiple per-card joker triggers per fixture.
local P_ENHANCE = 0.55
local P_EDITION = 0.40
local P_SEAL    = 0.40

local function gen_card(opts)
  opts = opts or {}
  local rank = opts.rank or pick(RANKS)
  local suit = opts.suit or pick(SUITS)
  local card = {
    ability = { name = 'Default Base', perma_bonus = 0 },
    base    = { id = rank.id, nominal = rank.nominal, suit = suit, value = rank.value },
  }
  if opts.allow_enhancements ~= false and maybe(P_ENHANCE) then
    card.ability.name = pick(SAFE_ENHANCEMENTS)
  end
  if maybe(P_EDITION) then
    local ed = pick(EDITIONS)
    card.edition = { [ed] = true, type = ed }
  end
  if maybe(P_SEAL) then
    card.seal = pick(SEALS)
  end
  return card
end

-- Always generate a 5-card played hand. Bias toward straight-flush /
-- four-of-a-kind / full-house / two-pair / flush + straight so most
-- fixtures hit a real poker-hand bonus and many jokers fire.
local function gen_played()
  local mode = math.random(7)
  local cards = {}
  if mode == 1 then  -- straight flush (5 consecutive same suit)
    local s = pick(SUITS)
    local lo = math.random(1, #RANKS - 4)
    for i = 1, 5 do cards[i] = gen_card{rank = RANKS[lo + i - 1], suit = s} end
  elseif mode == 2 then  -- four of a kind + kicker
    local r = pick(RANKS)
    for i = 1, 4 do cards[i] = gen_card{rank = r} end
    cards[5] = gen_card()
  elseif mode == 3 then  -- full house (3 + 2)
    local r1, r2 = pick(RANKS), pick(RANKS)
    while r2.id == r1.id do r2 = pick(RANKS) end
    for i = 1, 3 do cards[i] = gen_card{rank = r1} end
    for i = 4, 5 do cards[i] = gen_card{rank = r2} end
  elseif mode == 4 then  -- flush
    local s = pick(SUITS)
    for i = 1, 5 do cards[i] = gen_card{suit = s} end
  elseif mode == 5 then  -- straight (mixed suits)
    local lo = math.random(1, #RANKS - 4)
    for i = 1, 5 do cards[i] = gen_card{rank = RANKS[lo + i - 1]} end
  elseif mode == 6 then  -- two pair + kicker
    local r1, r2 = pick(RANKS), pick(RANKS)
    while r2.id == r1.id do r2 = pick(RANKS) end
    cards[1] = gen_card{rank = r1}; cards[2] = gen_card{rank = r1}
    cards[3] = gen_card{rank = r2}; cards[4] = gen_card{rank = r2}
    cards[5] = gen_card()
  else  -- random — exercises high card / unusual mixes
    for i = 1, 5 do cards[i] = gen_card() end
  end
  -- Shuffle so card order is non-trivial — exercises permutation logic
  -- and the F2 ordering search.
  for i = #cards, 2, -1 do
    local j = math.random(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
  return cards
end

local function gen_held()
  local n = math.random(2, 4)
  local cards = {}
  for i = 1, n do cards[i] = gen_card() end
  return cards
end

local function gen_jokers()
  local n = math.random(4, 5)
  local out = {}

  -- Sample from interaction pool (without replacement), then top up with
  -- filler. Guarantees at least 2 interaction jokers per fixture.
  local interaction_pool = {}
  for _, name in ipairs(INTERACTION_JOKERS) do interaction_pool[#interaction_pool+1] = name end
  local filler_pool = {}
  for _, name in ipairs(FILLER_JOKERS) do filler_pool[#filler_pool+1] = name end

  local n_inter = math.min(n, math.random(2, 4))
  for i = 1, n_inter do
    if #interaction_pool == 0 then break end
    local idx = math.random(#interaction_pool)
    out[#out+1] = {
      ability = { name = interaction_pool[idx], perma_bonus = 0,
                  mult = 0, t_chips = 0, t_mult = 0, x_mult = 1 },
      rarity  = 1,
    }
    table.remove(interaction_pool, idx)
  end
  for i = #out + 1, n do
    if #filler_pool == 0 then break end
    local idx = math.random(#filler_pool)
    out[#out+1] = {
      ability = { name = filler_pool[idx], perma_bonus = 0,
                  mult = 0, t_chips = 0, t_mult = 0, x_mult = 1 },
      rarity  = 1,
    }
    table.remove(filler_pool, idx)
  end

  -- High edition rate on jokers — exercises foil/holo/polychrome
  -- arithmetic during joker_main.
  for _, j in ipairs(out) do
    if maybe(0.30) then
      local ed = pick(EDITIONS)
      j.edition = { [ed] = true, type = ed }
    end
  end

  -- Shuffle so joker slot order varies (slot order matters for L→R
  -- per-card and joker_main passes).
  for i = #out, 2, -1 do
    local j = math.random(i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

local function copy_base_hands()
  local out = {}
  for k, v in pairs(BASE_HANDS) do
    out[k] = {}
    for kk, vv in pairs(v) do out[k][kk] = vv end
    out[k].s_chips = nil
    out[k].s_mult  = nil
  end
  return out
end

local function gen_fixture()
  return {
    played = gen_played(),
    held   = gen_held(),
    jokers = gen_jokers(),
    debuffed_by_blind = false,
    game = {
      blind = { name = '', disabled = false },
      hands = copy_base_hands(),
      current_round = {
        discards_left = 3,
        hands_left    = 3,
        hands_played  = 0,
        dollars       = 0,
      },
      deck_remaining   = 0,
      dollars          = 4,
      steel_card_count = 0,
    },
  }
end

local function detect_hand_name(fx)
  H.install_fixture(fx)
  local ok, text = pcall(G.FUNCS.get_poker_hand_info, G.play.cards)
  if not ok then return 'NULL' end
  return text or 'NULL'
end

local function read_mod_version()
  local f = io.open('BestHand.json', 'r')
  if not f then return 'synth_complex' end
  local s = f:read('*a'); f:close()
  local v = s:match('"version"%s*:%s*"([^"]+)"')
  return v and ('synth_complex+' .. v) or 'synth_complex'
end

-------------------------------------------------------------------------
-- Driver.
-------------------------------------------------------------------------
local mod_version = read_mod_version()
local n_ok, n_miss, n_err = 0, 0, 0
local first_err_msg
local out_index = 0
local timestamp_run = os.date('%Y%m%d_%H%M%S')

-- Track distinct (mod-oracle, hand_name, joker_set) signatures so we
-- don't drown in dupes if one bug triggers thousands of times.
local seen_sigs = {}

for i = 1, N do
  local fx = gen_fixture()

  local ok_m, mod_pred = pcall(function() return (H.mod_score(fx)) end)
  local oracle, oerr   = H.oracle_score(fx)

  if not ok_m or oerr then
    n_err = n_err + 1
    if not first_err_msg then
      first_err_msg = string.format('mod=%s  oracle=%s', tostring(mod_pred), tostring(oerr))
    end
  elseif mod_pred == oracle then
    n_ok = n_ok + 1
  else
    n_miss = n_miss + 1

    -- Build a signature: hand_name + sorted joker names + mod/oracle delta.
    fx.hand_name = detect_hand_name(fx)
    local jnames = {}
    for _, j in ipairs(fx.jokers) do jnames[#jnames+1] = j.ability.name end
    table.sort(jnames)
    local sig = fx.hand_name .. '|' .. table.concat(jnames, ',') ..
                '|' .. tostring(mod_pred - oracle)

    if not seen_sigs[sig] then
      seen_sigs[sig] = 1
      fx.predicted_score = mod_pred
      fx.actual_score    = oracle
      fx.mod_version     = mod_version
      out_index = out_index + 1
      local fname = string.format('synthc_%s_%04d.lua', timestamp_run, out_index)
      local path  = OUT_DIR .. '/' .. fname
      local f, oerr2 = io.open(path, 'w')
      if not f then
        io.stderr:write('write fail: ' .. tostring(oerr2) .. '\n')
      else
        f:write(H.serialize_capture(fx))
        f:close()
        print(string.format('  MISS  %s  hand=%-16s  mod=%-12s  oracle=%-12s  jokers=%s',
          fname, fx.hand_name, tostring(mod_pred), tostring(oracle), table.concat(jnames, ',')))
      end
    else
      seen_sigs[sig] = seen_sigs[sig] + 1
    end
  end

  if i % 500 == 0 then
    io.write(string.format('[%d/%d] ok=%d miss=%d uniq_miss=%d err=%d\n',
      i, N, n_ok, n_miss, out_index, n_err))
    io.flush()
  end
end

print()
print(string.format('synth_fuzz_complex done: tried=%d  ok=%d  miss=%d  uniq=%d  err=%d',
  N, n_ok, n_miss, out_index, n_err))
if first_err_msg then print('  first err: ' .. first_err_msg) end

-- Print top-N most frequent miss signatures, descending.
if n_miss > 0 then
  local sigs = {}
  for s, c in pairs(seen_sigs) do sigs[#sigs+1] = { s = s, c = c } end
  table.sort(sigs, function(a, b) return a.c > b.c end)
  print()
  print('Top miss signatures (count | hand | jokers | delta):')
  for i = 1, math.min(20, #sigs) do
    print(string.format('  %4d  %s', sigs[i].c, sigs[i].s))
  end
end

print(string.format('  misses written to %s/synthc_%s_*.lua', OUT_DIR, timestamp_run))
