-- synth_fuzz.lua — generate random fixtures and write any mod/oracle
-- disagreement to best_hand_captures/ in the same format F4 emits.
--
-- The oracle is Balatro's real G.FUNCS.evaluate_play. The mod is
-- BestHand's score_combo. We avoid probabilistic effects entirely
-- (no Lucky/Glass cards, no jokers that call pseudorandom in their
-- per-card / joker_main paths) so the two pipelines are deterministic
-- and any disagreement is a real mod bug.
--
-- Usage: lua synth_fuzz.lua [N] [out_dir]
--   N        number of fixtures to try (default 200)
--   out_dir  miss capture directory (default best_hand_captures)

local H = dofile('harness.lua')
H.load_besthand()
H.enable_oracle()

local N        = tonumber(arg[1]) or 200
local OUT_DIR  = arg[2] or 'best_hand_captures'

if not OUT_DIR:match('^[%w%-._ :/\\]+$') then
  io.stderr:write('refusing suspicious out_dir: ' .. OUT_DIR .. '\n')
  os.exit(1)
end

-- Reproducible per-run seed; override with FUZZ_SEED env var.
local seed = tonumber(os.getenv('FUZZ_SEED')) or os.time()
math.randomseed(seed)
print(string.format('synth_fuzz: seed=%d  N=%d  out=%s', seed, N, OUT_DIR))

-------------------------------------------------------------------------
-- Generation knobs.
-------------------------------------------------------------------------
-- Curated safe-joker list. Deterministic scoring jokers only —
-- nothing on BestHand's per_card_deny / before_deny / joker_main_deny.
local SAFE_JOKERS = {
  'Joker', 'Greedy Joker', 'Lusty Joker', 'Wrathful Joker', 'Gluttonous Joker',
  'Jolly Joker', 'Zany Joker', 'Mad Joker', 'Crazy Joker', 'Droll Joker',
  'Sly Joker', 'Wily Joker', 'Clever Joker', 'Devious Joker', 'Crafty Joker',
  'Half Joker', 'Banner', 'Mystic Summit',
  'Fibonacci', 'Even Steven', 'Odd Todd', 'Scholar',
  'Photograph', 'Hanging Chad', 'Sock and Buskin', 'Mime', 'Hack', 'Dusk', 'Seltzer',
  'Smiley Face', 'Pareidolia', 'Smeared Joker', 'Four Fingers', 'Splash',
  'Scary Face', 'Abstract Joker', 'Walkie Talkie', 'Triboulet',
  'Raised Fist', 'Baron', 'Shoot the Moon',
  'The Duo', 'The Trio', 'The Family', 'The Order', 'The Tribe',
  'Crazy Joker', 'Stone Joker', 'Steel Joker', 'Driver\'s License',
  'Bull', 'Onyx Agate', 'Arrowhead', 'Stuntman',
  'Flower Pot', 'Blackboard', 'Acrobat', 'Swashbuckler',
  'Cavendish', 'Gros Michel', 'Misprint',  -- Misprint generates a fixed range; mod handles via range_config
}

-- Drop Misprint until the batch_verify range_config plumb is verified;
-- it's the one prob-ish joker on the curated list. Keep things strict.
local function strip(t, name)
  local out = {}
  for _, v in ipairs(t) do if v ~= name then out[#out+1] = v end end
  return out
end
SAFE_JOKERS = strip(SAFE_JOKERS, 'Misprint')

-- Deterministic enhancements only. No Lucky (RNG mult), no Glass (RNG
-- shatter destroys cards mid-scoring), no Gold (end-of-round dollars).
local SAFE_ENHANCEMENTS = { nil, 'Bonus', 'Mult', 'Wild Card', 'Stone Card', 'Steel Card' }
local EDITIONS          = { nil, 'foil', 'holo', 'polychrome' }
local SEALS             = { nil, 'Red', 'Blue', 'Purple' }  -- Gold seal = end-of-round dollars; skip

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

-- Base poker-hand levels (from game.lua's defaults; chips/mult at L1).
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

-------------------------------------------------------------------------
-- Random helpers.
-------------------------------------------------------------------------
local function pick(t) return t[math.random(#t)] end
local function maybe(p) return math.random() < p end

local function gen_card(opts)
  opts = opts or {}
  local rank = opts.rank or pick(RANKS)
  local suit = opts.suit or pick(SUITS)
  local card = {
    ability = { name = 'Default Base', perma_bonus = 0 },
    base    = { id = rank.id, nominal = rank.nominal, suit = suit, value = rank.value },
  }
  -- Enhancement (overrides ability.name)
  if opts.allow_enhancements ~= false and maybe(0.20) then
    local enh = pick(SAFE_ENHANCEMENTS)
    if enh then card.ability.name = enh end
  end
  -- Edition
  if maybe(0.15) then
    local ed = pick(EDITIONS)
    if ed then card.edition = { [ed] = true, type = ed } end
  end
  -- Seal
  if maybe(0.15) then
    local s = pick(SEALS)
    if s then card.seal = s end
  end
  return card
end

-- Build a hand that's likely to make a recognized poker hand. Mix of:
--   * bare random (often High Card)
--   * forced pair/two-pair/three-of-a-kind (repeat ranks)
--   * forced flush (single suit)
--   * forced straight (consecutive ranks)
local function gen_played()
  local mode = math.random(6)
  local n = math.random(1, 5)
  local cards = {}
  if mode == 1 then  -- random
    for i = 1, n do cards[i] = gen_card() end
  elseif mode == 2 then  -- pair
    n = math.max(n, 2)
    local r = pick(RANKS)
    cards[1] = gen_card{rank = r}
    cards[2] = gen_card{rank = r}
    for i = 3, n do cards[i] = gen_card() end
  elseif mode == 3 then  -- three of a kind
    n = math.max(n, 3)
    local r = pick(RANKS)
    for i = 1, 3 do cards[i] = gen_card{rank = r} end
    for i = 4, n do cards[i] = gen_card() end
  elseif mode == 4 then  -- flush (5 cards same suit)
    n = 5
    local s = pick(SUITS)
    for i = 1, 5 do cards[i] = gen_card{suit = s} end
  elseif mode == 5 then  -- straight (5 consecutive)
    n = 5
    local lo = math.random(1, #RANKS - 4)
    for i = 1, 5 do cards[i] = gen_card{rank = RANKS[lo + i - 1]} end
  else  -- two pair
    n = math.max(n, 4)
    local r1, r2 = pick(RANKS), pick(RANKS)
    cards[1] = gen_card{rank = r1}; cards[2] = gen_card{rank = r1}
    cards[3] = gen_card{rank = r2}; cards[4] = gen_card{rank = r2}
    for i = 5, n do cards[i] = gen_card() end
  end
  return cards
end

local function gen_held()
  local n = math.random(0, 3)
  local cards = {}
  for i = 1, n do cards[i] = gen_card() end
  return cards
end

local function gen_jokers()
  local n = math.random(0, 3)
  local out = {}
  -- Sample without replacement so we don't get duplicates that can
  -- chain in surprising ways (Showman aside, but Showman isn't on the list).
  local pool = {}
  for _, name in ipairs(SAFE_JOKERS) do pool[#pool+1] = name end
  for i = 1, n do
    if #pool == 0 then break end
    local idx = math.random(#pool)
    out[i] = {
      ability = { name = pool[idx], perma_bonus = 0,
                  mult = 0, t_chips = 0, t_mult = 0, x_mult = 1 },
      rarity  = 1,
    }
    if maybe(0.10) then
      local ed = pick({ 'foil', 'holo', 'polychrome' })
      out[i].edition = { [ed] = true, type = ed }
    end
    table.remove(pool, idx)
  end
  return out
end

local function deepcopy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, vv in pairs(v) do out[k] = deepcopy(vv) end
  return out
end

local function copy_base_hands()
  local out = {}
  for k, v in pairs(BASE_HANDS) do
    out[k] = {}
    for kk, vv in pairs(v) do out[k][kk] = vv end
    -- Capture format omits s_chips / s_mult; not used by score paths.
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

-------------------------------------------------------------------------
-- Hand-name detection — we install the fixture (via mod_score path) so
-- the played cards have Card metatables, then call the real
-- get_poker_hand_info.
-------------------------------------------------------------------------
local function detect_hand_name(fx)
  H.install_fixture(fx)
  local ok, text = pcall(G.FUNCS.get_poker_hand_info, G.play.cards)
  if not ok then return 'NULL' end
  return text or 'NULL'
end

-------------------------------------------------------------------------
-- Mod version label (best-effort: read from BestHand.json).
-------------------------------------------------------------------------
local function read_mod_version()
  local f = io.open('BestHand.json', 'r')
  if not f then return 'synth' end
  local s = f:read('*a'); f:close()
  local v = s:match('"version"%s*:%s*"([^"]+)"')
  return v and ('synth+' .. v) or 'synth'
end

-------------------------------------------------------------------------
-- Driver.
-------------------------------------------------------------------------
local mod_version = read_mod_version()
local n_ok, n_miss, n_err = 0, 0, 0
local first_err_msg
local out_index = 0
local timestamp_run = os.date('%Y%m%d_%H%M%S')

for i = 1, N do
  local fx = gen_fixture()

  -- Score with mod first (deterministic only — no probabilistic enum).
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
    -- Detect the hand name on a fresh install (mod_score / oracle_score
    -- have already mutated state via deepcopy-attached cards, but the
    -- fixture itself is intact).
    fx.hand_name       = detect_hand_name(fx)
    fx.predicted_score = mod_pred
    fx.actual_score    = oracle
    fx.mod_version     = mod_version
    out_index = out_index + 1
    local fname = string.format('synth_%s_%03d.lua', timestamp_run, out_index)
    local path  = OUT_DIR .. '/' .. fname
    local f, oerr2 = io.open(path, 'w')
    if not f then
      io.stderr:write('write fail: ' .. tostring(oerr2) .. '\n')
    else
      f:write(H.serialize_capture(fx))
      f:close()
      print(string.format('  MISS  %s  hand=%-16s  mod=%-12s  oracle=%s',
        fname, fx.hand_name, tostring(mod_pred), tostring(oracle)))
    end
  end

  if i % 50 == 0 then
    io.write(string.format('[%d/%d] ok=%d miss=%d err=%d\n', i, N, n_ok, n_miss, n_err))
    io.flush()
  end
end

print()
print(string.format('synth_fuzz done: tried=%d  ok=%d  miss=%d  err=%d', N, n_ok, n_miss, n_err))
if first_err_msg then print('  first err: ' .. first_err_msg) end
print(string.format('  misses written to %s/synth_%s_*.lua', OUT_DIR, timestamp_run))
