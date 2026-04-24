-- batch_verify.lua — replay every capture through BestHand's
-- score_combo and report ok / ok(var) / MISS.
--
-- Jokers run through the real Card:calculate_joker code from
-- balatro_src/ — the same code the game uses in-engine. We stub the
-- minimum global surface, load card.lua + misc_functions.lua, and
-- attach the Card metatable to captured jokers so BestHand's hybrid
-- dispatch picks the real path.
--
-- Each capture is enumerated over the cartesian product of boolean
-- probabilistic events (Lucky Card, Bloodstone) × integer range events
-- (Misprint), bounded at 10,000 configurations. A capture passes "ok"
-- when the game's actual score matches BestHand's EV prediction, or
-- "ok(var)" when the actual falls somewhere in the enumerated set.
--
-- Usage: lua batch_verify.lua [captures_dir]
-- Default captures_dir: ./best_hand_captures

local SRC_DIR = 'balatro_src'

-------------------------------------------------------------------------
-- Object / Moveable — enough inheritance glue for `Card = Moveable:extend()`
-------------------------------------------------------------------------
Object = {}
Object.__index = Object
function Object:init() end
function Object:extend()
  local cls = {}
  for k, v in pairs(self) do
    if type(k) == 'string' and k:find('__') == 1 then cls[k] = v end
  end
  cls.__index = cls
  cls.super = self
  setmetatable(cls, self)
  return cls
end
function Object:is(_) return false end
function Object:__call(...)
  local o = setmetatable({}, self)
  if o.init then o:init(...) end
  return o
end

Moveable = Object:extend()
function Moveable:init() end
function Moveable:move() end
function Moveable:align() end
function Moveable:hard_set_T() end
function Moveable:juice_up() end

-------------------------------------------------------------------------
-- Minimum global surface that card.lua + misc_functions.lua touch.
-- Most entries are no-ops; a few (pseudorandom, localize) must return
-- a non-nil value because caller code indexes the result.
-------------------------------------------------------------------------
G = {
  GAME = {
    used_vouchers   = {},
    probabilities   = { normal = 1 },
    consumeable_buffer = 0,
    round_resets    = { ante = 1 },
    hands           = {},
    current_round   = {},
    blind           = { name = '', disabled = false },
    dollars         = 0,
    cards_played    = setmetatable({}, { __index = function()
      return { total = 0, suits = {} }
    end }),
  },
  P_CENTERS     = {},          -- populated below from game.lua
  P_CENTER_POOLS = { Joker = {} },
  C             = setmetatable({}, { __index = function() return {} end }),
  jokers        = { cards = {}, config = { card_limit = 5 } },
  consumeables  = { cards = {}, config = { card_limit = 2 } },
  hand          = { cards = {} },
  play          = { cards = {} },
  deck          = { cards = {} },
  playing_cards = {},
  E_MANAGER     = { add_event = function() end },
  FUNCS         = {},
  RESET_JIGGLES = false,
}

SMODS = {}
function SMODS.calculate_round_score() return 0 end
function SMODS.Keybind(_) end

function pseudorandom(_) return 0 end   -- deterministic; BestHand's
function pseudoseed(_) return 'seed' end -- enumeration drives variance
function pseudorandom_element(t) return t and t[1] or nil, 1 end

function Event(e) return e end
function Tag(_)   return {} end
function play_sound() end
function card_eval_status_text() end
function juice_card_until() end
function juice_card() end
function update_hand_text() end
function attention_text() end
function ease_colour() end
function ease_dollars() end
function add_tag() end
function delay() end
function highlight_card() end
function copy_card(c) return c end
function create_card() return setmetatable({ ability = {}, base = {} }, nil) end
function check_for_unlock() end
function level_up_hand() end
function set_hand_usage() end
function inc_career_stat() end
function nominal_chip_inc() end
function save_run() end
function add_round_eval_row() end
function mod_chips(n) return n end
function mod_mult(n) return n end
function HEX() return { 0, 0, 0, 1 } end
function EMPTY(t) for k in pairs(t or {}) do t[k] = nil end return t end

function find_joker(name)
  local out = {}
  for _, j in ipairs(G.jokers.cards or {}) do
    if j.ability and j.ability.name == name then out[#out+1] = j end
  end
  return out
end

-- localize must never return nil — many branches index its result.
function localize(_)
  return setmetatable({}, { __index = function() return '' end })
end

love = {
  filesystem = {
    getSaveDirectory = function() return '.' end,
    createDirectory  = function() end,
  },
}

-------------------------------------------------------------------------
-- Load Balatro source: card.lua (for Card class + methods) and
-- misc_functions.lua (for evaluate_poker_hand / get_X_same / get_flush
-- / get_straight / get_highest).
-------------------------------------------------------------------------
local function load_src(name)
  local path = SRC_DIR .. '/' .. name
  local ok, err = pcall(dofile, path)
  if not ok then
    io.stderr:write('[shim] failed to load ' .. path .. ': ' .. tostring(err) .. '\n')
    os.exit(1)
  end
end

load_src('card.lua')
load_src('functions/misc_functions.lua')

-- misc_functions.lua defines a real `localize` that reaches into
-- G.localization. Re-stub so our no-op wins.
function localize(_)
  return setmetatable({}, { __index = function() return '' end })
end

assert(Card and Card.calculate_joker, 'Card:calculate_joker missing')
assert(evaluate_poker_hand, 'evaluate_poker_hand missing')

-- Suit nominals populated by Card:set_base; captures don't record them.
local SUIT_NOMINAL = { Diamonds = 0.01, Clubs = 0.02, Hearts = 0.03, Spades = 0.04 }
local SUIT_NOMINAL_ORIG = { Diamonds = 0.001, Clubs = 0.002, Hearts = 0.003, Spades = 0.004 }

-------------------------------------------------------------------------
-- Extract the P_CENTERS block from game.lua (lines 364..702 of that
-- file form the data table; entries reference no helpers). We re-emit
-- it as `return { ... }` and loadstring it to recover the table.
-------------------------------------------------------------------------
local function extract_p_centers()
  local f = assert(io.open(SRC_DIR .. '/game.lua', 'r'))
  local in_block, depth, buf = false, 0, { 'return {' }
  for line in f:lines() do
    if not in_block then
      if line:match('self%.P_CENTERS%s*=%s*{') then
        in_block = true
        depth = 1
      end
    else
      -- naive brace accounting: count unescaped { and } on the line
      local opens = select(2, line:gsub('{', ''))
      local closes = select(2, line:gsub('}', ''))
      depth = depth + opens - closes
      if depth <= 0 then
        buf[#buf+1] = '}'
        break
      end
      buf[#buf+1] = line
    end
  end
  f:close()
  local src = table.concat(buf, '\n')
  local chunk, err = loadstring(src, 'P_CENTERS')
  if not chunk then error('P_CENTERS parse: ' .. tostring(err)) end
  return chunk()
end

G.P_CENTERS = extract_p_centers()

-- Build a display-name → center key index so we can look up config
-- data from a capture that only recorded `ability.name`.
local name_to_key = {}
for key, center in pairs(G.P_CENTERS) do
  if type(center) == 'table' and center.name and center.set == 'Joker' then
    name_to_key[center.name] = key
  end
end

-------------------------------------------------------------------------
-- Capture loading (sandboxed, same as batch_verify.lua)
-------------------------------------------------------------------------
local function load_fixture(path)
  local f, oerr = io.open(path, 'r')
  if not f then return nil, oerr end
  local src = f:read('*a')
  f:close()
  local chunk, lerr = loadstring(src, path)
  if not chunk then return nil, lerr end
  setfenv(chunk, { math = { huge = math.huge } })
  local ok, result = pcall(chunk)
  if not ok then return nil, result end
  return result
end

-------------------------------------------------------------------------
-- Load BestHand.lua with score_combo export (unchanged from v1)
-------------------------------------------------------------------------
do
  local f = assert(io.open('BestHand.lua', 'r'))
  local src = f:read('*a')
  f:close()
  src = src .. '\n_G._BH = { score_combo = score_combo }\n'
  local chunk = assert(loadstring(src, 'BestHand'))
  chunk()
  assert(_BH and _BH.score_combo, 'score_combo export failed')
end

-------------------------------------------------------------------------
-- Real G.FUNCS.get_poker_hand_info, built on evaluate_poker_hand.
-- Requires cards to have :get_id, :is_suit, :get_nominal — we attach
-- the Card metatable to played/held cards when rehydrating fixtures.
-------------------------------------------------------------------------
function G.FUNCS.get_poker_hand_info(cards)
  local poker_hands = evaluate_poker_hand(cards)
  local text, scoring_hand = 'NULL', {}
  local order = {
    'Flush Five', 'Flush House', 'Five of a Kind', 'Straight Flush',
    'Four of a Kind', 'Full House', 'Flush', 'Straight',
    'Three of a Kind', 'Two Pair', 'Pair', 'High Card',
  }
  for _, name in ipairs(order) do
    if next(poker_hands[name]) then
      text = name
      scoring_hand = poker_hands[name][1]
      break
    end
  end
  local disp_text = text
  if text == 'Straight Flush' then
    local min = 10
    for j = 1, #scoring_hand do
      if scoring_hand[j]:get_id() < min then min = scoring_hand[j]:get_id() end
    end
    if min >= 10 then disp_text = 'Royal Flush' end
  end
  return text, disp_text, poker_hands, scoring_hand, disp_text
end
function G.FUNCS.evaluate_play(_) end

-------------------------------------------------------------------------
-- Fixture rehydration with Card metatable so :calculate_joker,
-- :get_id, :is_suit, :get_nominal, :get_chip_bonus etc. dispatch to
-- balatro_src/card.lua methods.
-------------------------------------------------------------------------
local unique_id_seq = 0
local function attach_card(t)
  t.ability = t.ability or {}
  t.ability.perma_bonus = t.ability.perma_bonus or 0
  t.ability.bonus = t.ability.bonus or 0
  t.ability.mult  = t.ability.mult  or 0
  t.base    = t.base or {}
  t.base.nominal = t.base.nominal or 0
  t.base.suit_nominal = t.base.suit_nominal or SUIT_NOMINAL[t.base.suit] or 0
  t.base.suit_nominal_original = t.base.suit_nominal_original
    or SUIT_NOMINAL_ORIG[t.base.suit] or 0
  t.base.face_nominal = t.base.face_nominal or 0
  unique_id_seq = unique_id_seq + 1
  t.unique_val = t.unique_val or unique_id_seq
  t.debuff  = t.debuff or false
  -- Default ability.effect for enhancements Balatro uses in Card methods
  if t.ability.name == 'Stone Card' then
    t.ability.effect = t.ability.effect or 'Stone Card'
  elseif t.ability.name == 'Wild Card' then
    t.ability.effect = t.ability.effect or 'Wild Card'
  elseif t.ability.name == 'Glass Card' then
    t.ability.effect = t.ability.effect or 'Glass Card'
    t.ability.x_mult = t.ability.x_mult or 2
  elseif t.ability.name == 'Steel Card' then
    t.ability.effect = t.ability.effect or 'Steel Card'
    t.ability.h_x_mult = t.ability.h_x_mult or 1.5
  elseif t.ability.name == 'Mult' then
    t.ability.effect = t.ability.effect or 'Mult Card'
  elseif t.ability.name == 'Lucky Card' then
    t.ability.effect = t.ability.effect or 'Lucky Card'
    t.ability.mult = t.ability.mult ~= 0 and t.ability.mult or 20
  elseif t.ability.name == 'Gold Card' then
    t.ability.effect = t.ability.effect or 'Gold Card'
  elseif t.ability.name == 'Bonus' then
    t.ability.effect = t.ability.effect or 'Bonus'
    t.ability.bonus = t.ability.bonus ~= 0 and t.ability.bonus or 30
  end
  setmetatable(t, { __index = Card })
  return t
end

local function attach_joker(t)
  t.ability = t.ability or {}
  t.ability.mult        = t.ability.mult        or 0
  t.ability.x_mult      = t.ability.x_mult      or 1
  t.ability.chips       = t.ability.chips       or 0
  t.ability.t_mult      = t.ability.t_mult      or 0
  t.ability.t_chips     = t.ability.t_chips     or 0
  t.ability.perma_bonus = t.ability.perma_bonus or 0
  t.ability.set         = t.ability.set         or 'Joker'
  t.debuff = t.debuff or false

  -- Pull defaults from P_CENTERS if the capture didn't record them —
  -- mirrors Card:set_ability (card.lua:277) which copies fields from
  -- center.config into ability. copy_scalars in BestHand's capture
  -- code drops scalar values of ability.extra, so most captures lack
  -- these fields.
  local key = name_to_key[t.ability.name]
  if key and G.P_CENTERS[key] then
    local cfg = G.P_CENTERS[key].config or {}
    if t.ability.extra == nil then
      -- extra may be a scalar (e.g. 0.2) or a table (e.g. {s_mult=3, suit='Diamonds'})
      if type(cfg.extra) == 'table' then
        local copy = {}
        for k, v in pairs(cfg.extra) do copy[k] = v end
        t.ability.extra = copy
      else
        t.ability.extra = cfg.extra
      end
    end
    -- Scalar fields that the capture's copy_scalars() drops at 0 or nil.
    if t.ability.mult    == 0 and cfg.mult    then t.ability.mult    = cfg.mult    end
    if t.ability.chips   == 0 and cfg.chips   then t.ability.chips   = cfg.chips   end
    if t.ability.t_mult  == 0 and cfg.t_mult  then t.ability.t_mult  = cfg.t_mult  end
    if t.ability.t_chips == 0 and cfg.t_chips then t.ability.t_chips = cfg.t_chips end
    if t.ability.x_mult  == 1 and cfg.Xmult   then t.ability.x_mult  = cfg.Xmult   end
    -- Derived fields real calculate_joker reads directly.
    t.ability.type      = t.ability.type      or cfg.type      or ''
    t.ability.h_mult    = t.ability.h_mult    or cfg.h_mult    or 0
    t.ability.h_x_mult  = t.ability.h_x_mult  or cfg.h_x_mult  or 0
    t.ability.p_dollars = t.ability.p_dollars or cfg.p_dollars or 0
    t.ability.h_size    = t.ability.h_size    or cfg.h_size    or 0
    t.ability.d_size    = t.ability.d_size    or cfg.d_size    or 0
    t.ability.effect    = t.ability.effect    or G.P_CENTERS[key].effect
    -- Attach center so calculate_joker can reach rarity etc.
    t.config = t.config or {}
    t.config.center = G.P_CENTERS[key]
  end

  setmetatable(t, { __index = Card })
  return t
end

local function install_fixture(fx)
  local played, held = {}, {}
  for i, c in ipairs(fx.played) do played[i] = attach_card(c) end
  for i, c in ipairs(fx.held)   do held[i]   = attach_card(c) end

  G.jokers.cards = {}
  for i, j in ipairs(fx.jokers) do G.jokers.cards[i] = attach_joker(j) end

  G.GAME.hands         = fx.game.hands or {}
  G.GAME.current_round = fx.game.current_round or {}
  G.GAME.blind         = fx.game.blind or { name = '', disabled = false }
  G.GAME.dollars       = fx.game.dollars or 0

  G.playing_cards = {}
  for _, c in ipairs(played) do G.playing_cards[#G.playing_cards+1] = c end
  for _, c in ipairs(held)   do G.playing_cards[#G.playing_cards+1] = c end

  -- Reconstruct Steel Card total if the capture recorded it. Pad with
  -- dummy Steel Cards (attached to Card metatable so :get_id works).
  local steel_target = fx.game.steel_card_count
  if steel_target then
    local have = 0
    for _, c in ipairs(G.playing_cards) do
      if c.ability and c.ability.name == 'Steel Card' then have = have + 1 end
    end
    for _ = 1, steel_target - have do
      G.playing_cards[#G.playing_cards+1] = attach_card({
        ability = { name = 'Steel Card' },
        base    = { id = 0, suit = 'Spades', nominal = 0 },
        debuff  = false,
      })
    end
  end

  -- Maintain tallies that Balatro normally updates via add_to_deck
  -- hooks — used by Steel Joker / Stone Joker / Marble.
  local steel, stone = 0, 0
  for _, c in ipairs(G.playing_cards) do
    local name = c.ability and c.ability.name
    if name == 'Steel Card' then steel = steel + 1 end
    if name == 'Stone Card' then stone = stone + 1 end
  end
  for _, j in ipairs(G.jokers.cards) do
    if j.ability.steel_tally == nil then j.ability.steel_tally = steel end
    if j.ability.stone_tally == nil then j.ability.stone_tally = stone end
  end

  G.deck.cards = {}
  for i = 1, (fx.game.deck_remaining or 0) do G.deck.cards[i] = {} end

  return played, held
end

-------------------------------------------------------------------------
-- Scoring + probabilistic enumeration (copied from batch_verify.lua)
-------------------------------------------------------------------------
local function score_fixture(fx)
  local played, held = install_fixture(fx)
  local all = {}
  for _, c in ipairs(played) do all[#all+1] = c end
  for _, c in ipairs(held)   do all[#all+1] = c end

  local _, ev_score, _, _, n_prob, range_events =
    _BH.score_combo(played, all, nil, nil)
  n_prob = n_prob or 0
  range_events = range_events or {}
  local n_range = #range_events

  local possible, seen = {}, {}
  local function add(s)
    if not seen[s] then seen[s] = true; possible[#possible+1] = s end
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
    add(ev_score)
  end
  table.sort(possible)
  return ev_score, possible, n_prob, n_range, total_configs
end

-------------------------------------------------------------------------
-- Walk captures dir (reused from batch_verify.lua)
-------------------------------------------------------------------------
local captures_dir = arg[1] or 'best_hand_captures'

-- captures_dir is interpolated into a shell command below (dir /b on
-- Windows, ls on POSIX). Reject anything outside a conservative
-- path-character allowlist so a malicious argument can't inject
-- commands via ", $, `, ;, &, |, newline, etc.
if not captures_dir:match('^[%w%-._ :/\\]+$') then
  io.stderr:write('refusing suspicious captures_dir: ' .. captures_dir .. '\n')
  os.exit(1)
end

local function list_files(dir)
  local out = {}
  local win_dir = dir:gsub('/', '\\')
  local p = io.popen('dir /b "' .. win_dir .. '\\*.lua" 2>nul')
  if p then
    for line in p:lines() do out[#out+1] = dir .. '/' .. line end
    p:close()
  end
  if #out == 0 then
    p = io.popen('ls "' .. dir .. '"/*.lua 2>/dev/null')
    if p then
      for line in p:lines() do out[#out+1] = line end
      p:close()
    end
  end
  table.sort(out)
  return out
end

local files = list_files(captures_dir)
if #files == 0 then
  print('No captures found in ' .. captures_dir)
  os.exit(1)
end

print(string.format('Verifying %d captures from %s', #files, captures_dir))
print()

local function basename(p) return p:match('([^/\\]+)$') or p end

local strict, via_variance, miss = 0, 0, 0
local misses = {}

for _, path in ipairs(files) do
  local fx, lerr = load_fixture(path)
  if not fx or type(fx) ~= 'table' then
    print(string.format('!! %s: failed to load (%s)', basename(path), tostring(lerr or fx)))
    miss = miss + 1
  else
    local ok2, ev_score, possible, n_prob, n_range = pcall(score_fixture, fx)
    if not ok2 then
      print(string.format('!! %s: score error (%s)', basename(path), tostring(ev_score)))
      miss = miss + 1
    else
      local actual = fx.actual_score
      local hit_exact = (actual == ev_score)
        or (actual ~= 0 and math.abs(actual - ev_score) / math.abs(actual) < 1e-9)
      local hit_any = false
      if not hit_exact and (n_prob + n_range) > 0 then
        for _, s in ipairs(possible) do
          if s == actual then hit_any = true; break end
        end
      end
      if hit_exact then
        strict = strict + 1
        print(string.format('  ok      %-45s %-16s  ev=%-10s actual=%s',
          basename(path), fx.hand_name, tostring(ev_score), tostring(actual)))
      elseif hit_any then
        via_variance = via_variance + 1
        print(string.format('  ok(var) %-45s %-16s  ev=%-10s actual=%-10s (1 of %d, n_prob=%d n_range=%d)',
          basename(path), fx.hand_name, tostring(ev_score), tostring(actual), #possible, n_prob, n_range))
      else
        miss = miss + 1
        misses[#misses+1] = { file = basename(path), hand = fx.hand_name,
          ev = ev_score, actual = actual, possible = possible }
        print(string.format('  MISS    %-45s %-16s  ev=%-10s actual=%-10s n_prob=%d n_range=%d',
          basename(path), fx.hand_name, tostring(ev_score), tostring(actual), n_prob, n_range))
      end
    end
  end
end

print()
print(string.format('Total: %d   strict match: %d   match via variance: %d   miss: %d',
  #files, strict, via_variance, miss))

if #misses > 0 then
  print()
  print('=== Misses ===')
  for _, m in ipairs(misses) do
    print(string.format('  %s (%s): ev=%s actual=%s',
      m.file, m.hand, tostring(m.ev), tostring(m.actual)))
  end
end

os.exit(miss == 0 and 0 or 1)
