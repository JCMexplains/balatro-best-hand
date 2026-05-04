-- harness.lua — shared offline shim for BestHand tools.
--
-- Provides:
--   * Globals (Object, Moveable, G, SMODS, pseudorandom, love, ...) and
--     enough Lua-level stubs to dofile() balatro_src/* without crashing.
--   * Loaders for card.lua, misc_functions.lua, common_events.lua,
--     state_events.lua so the real Card:calculate_joker, eval_card and
--     evaluate_play paths run.
--   * Fixture rehydration (attach_card / attach_joker / install_fixture).
--   * `mod_score(fx)`  — runs BestHand's score_combo with the same
--     probabilistic enumeration batch_verify.lua uses.
--   * `oracle_score(fx)` — runs Balatro's real G.FUNCS.evaluate_play and
--     returns floor(hand_chips * mult). This is the ground-truth scorer.
--
-- Load with `local H = dofile('harness.lua')` then call `H.init{...}`.

local H = {}

local SRC_DIR = 'balatro_src'

-------------------------------------------------------------------------
-- Object / Moveable inheritance glue
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
-- G — minimal global game-state surface
-------------------------------------------------------------------------
G = {
  GAME = {
    used_vouchers   = {},
    probabilities   = { normal = 1 },
    consumeable_buffer = 0,
    round_resets    = { ante = 1 },
    hands           = {},
    current_round   = {
      current_hand = { handname = '', chips = 0, mult = 0, chip_total = 0 },
    },
    blind           = { name = '', disabled = false },
    chips           = 0,
    dollars         = 0,
    modifiers       = {},
    cards_played    = setmetatable({}, { __index = function()
      return { total = 0, suits = {} }
    end }),
    selected_back   = { trigger_effect = function() return nil, nil end },
  },
  P_CENTERS     = {},
  P_CENTER_POOLS = { Joker = {} },
  C             = setmetatable({}, { __index = function() return {} end }),
  jokers        = { cards = {}, config = { card_limit = 5 } },
  consumeables  = { cards = {}, config = { card_limit = 2 } },
  hand          = { cards = {}, emplace = function() end },
  play          = { cards = {} },
  deck          = { cards = {}, config = { card_limit = 52 } },
  playing_cards = {},
  E_MANAGER     = { add_event = function() end },
  FUNCS         = {},
  RESET_JIGGLES = false,
}

SMODS = {}
function SMODS.calculate_round_score() return 0 end
function SMODS.Keybind(_) end

-- Deterministic pseudorandom — BestHand's enumeration drives variance.
function pseudorandom(_) return 0 end
function pseudoseed(_) return 'seed' end
function pseudorandom_element(t) return t and t[1] or nil, 1 end

-- No-op constructors / placeholders used by source.
function Event(e) return e end
function Tag(_)   return {} end

-- No-op UI / sound / animation helpers.
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
function play_area_status_text() end
function ease_chips() end
function ease_background_colour() end
function set_screen_positions() end
function set_alerts() end
function lighten() return { 0, 0, 0, 1 } end
function mix_colours() return { 0, 0, 0, 1 } end
function draw_card() end

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
local function safe_localize(_)
  return setmetatable({}, { __index = function() return '' end })
end
function localize(_) return safe_localize(_) end

love = {
  filesystem = {
    getSaveDirectory = function() return '.' end,
    createDirectory  = function() end,
  },
}

-------------------------------------------------------------------------
-- Source loader. Whatever balatro_src files we dofile may redefine the
-- globals above with their real implementations; the caller can re-stub
-- after loading if a real impl reaches for state we don't have.
-------------------------------------------------------------------------
local function load_src(name)
  local path = SRC_DIR .. '/' .. name
  local ok, err = pcall(dofile, path)
  if not ok then
    io.stderr:write('[harness] failed to load ' .. path .. ': ' .. tostring(err) .. '\n')
    os.exit(1)
  end
end

-- Always-needed: card.lua (Card class, get_chip_bonus, calculate_joker)
-- and misc_functions.lua (evaluate_poker_hand, mod_chips, find_joker, ...).
load_src('card.lua')
load_src('functions/misc_functions.lua')

-- misc_functions.lua redefines localize, find_joker, set_hand_usage,
-- check_and_set_high_score against globals we don't have. Re-stub.
function localize(_) return safe_localize(_) end
function set_hand_usage() end
function check_and_set_high_score() end
function find_joker(name)
  local out = {}
  for _, j in ipairs(G.jokers.cards or {}) do
    if j.ability and j.ability.name == name then out[#out+1] = j end
  end
  return out
end

assert(Card and Card.calculate_joker, 'Card:calculate_joker missing')
assert(evaluate_poker_hand, 'evaluate_poker_hand missing')

-------------------------------------------------------------------------
-- P_CENTERS extraction from game.lua (lines 364..702 of that file form
-- a self-contained data table — no helper references).
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

-- Build display-name → key index for joker rehydration.
local name_to_key = {}
for key, center in pairs(G.P_CENTERS) do
  if type(center) == 'table' and center.name and center.set == 'Joker' then
    name_to_key[center.name] = key
  end
end
H.name_to_key = name_to_key
H.P_CENTERS = G.P_CENTERS

-- Suit nominals populated by Card:set_base; captures don't record them.
local SUIT_NOMINAL      = { Diamonds = 0.01,  Clubs = 0.02,  Hearts = 0.03,  Spades = 0.04  }
local SUIT_NOMINAL_ORIG = { Diamonds = 0.001, Clubs = 0.002, Hearts = 0.003, Spades = 0.004 }
H.SUITS = { 'Diamonds', 'Clubs', 'Hearts', 'Spades' }
H.RANKS = {
  { id = 2,  value = '2' },  { id = 3,  value = '3' },  { id = 4,  value = '4' },
  { id = 5,  value = '5' },  { id = 6,  value = '6' },  { id = 7,  value = '7' },
  { id = 8,  value = '8' },  { id = 9,  value = '9' },  { id = 10, value = '10' },
  { id = 11, value = 'Jack' }, { id = 12, value = 'Queen' },
  { id = 13, value = 'King' }, { id = 14, value = 'Ace' },
}

-------------------------------------------------------------------------
-- Card / Joker rehydration (Card metatable so :calculate_joker, :get_id,
-- :is_suit, :get_nominal etc. dispatch to balatro_src/card.lua).
-------------------------------------------------------------------------
local unique_id_seq = 0

-- Captures store edition as boolean flags (foil=true / polychrome=true).
-- The real Card:get_edition reads numeric fields self.edition.chips /
-- mult / x_mult that Card:set_ability populates from the e_foil /
-- e_holo / e_polychrome center configs. Rehydrate those numbers.
local EDITION_NUMERIC = { foil = 50, holo = 10, polychrome = 1.5 }
local function fill_edition(e)
  if not e or type(e) ~= 'table' then return end
  if e.foil       and e.chips  == nil then e.chips  = EDITION_NUMERIC.foil end
  if e.holo       and e.mult   == nil then e.mult   = EDITION_NUMERIC.holo end
  if e.polychrome and e.x_mult == nil then e.x_mult = EDITION_NUMERIC.polychrome end
end

-- Defaults that real Card:set_ability (card.lua:277) initializes for
-- every Card. Without these, Card:get_chip_x_mult / get_chip_h_mult /
-- get_chip_h_x_mult crash on nil arithmetic.
local function default_ability(a)
  a.perma_bonus = a.perma_bonus or 0
  a.bonus       = a.bonus       or 0
  a.mult        = a.mult        or 0
  a.x_mult      = a.x_mult      or 1
  a.h_mult      = a.h_mult      or 0
  a.h_x_mult    = a.h_x_mult    or 0
  a.h_dollars   = a.h_dollars   or 0
  a.p_dollars   = a.p_dollars   or 0
  a.t_mult      = a.t_mult      or 0
  a.t_chips     = a.t_chips     or 0
  a.h_size      = a.h_size      or 0
  a.d_size      = a.d_size      or 0
  a.extra_value = a.extra_value or 0
end

local function attach_card(t)
  t.ability = t.ability or {}
  default_ability(t.ability)
  fill_edition(t.edition)
  t.base    = t.base or {}
  t.base.nominal = t.base.nominal or 0
  t.base.suit_nominal = t.base.suit_nominal or SUIT_NOMINAL[t.base.suit] or 0
  t.base.suit_nominal_original = t.base.suit_nominal_original
    or SUIT_NOMINAL_ORIG[t.base.suit] or 0
  -- Card:set_base assigns face_nominal per value (J=0.1, Q=0.2, K=0.3,
  -- A=0.4). Captures don't record it; without this, get_nominal's
  -- ordering becomes suit-dominated and a 10 of Spades can outrank a
  -- King of Hearts in High Card selection.
  if t.base.face_nominal == nil then
    local v = t.base.value
    if     v == 'Jack'  then t.base.face_nominal = 0.1
    elseif v == 'Queen' then t.base.face_nominal = 0.2
    elseif v == 'King'  then t.base.face_nominal = 0.3
    elseif v == 'Ace'   then t.base.face_nominal = 0.4
    else                     t.base.face_nominal = 0
    end
  end
  unique_id_seq = unique_id_seq + 1
  t.unique_val = t.unique_val or unique_id_seq
  t.debuff  = t.debuff or false
  t.T       = t.T or { x = unique_id_seq, y = 0 }
  -- Enhancement defaults match m_* center configs in game.lua:648-654.
  -- Captures' copy_scalars drops zero/nil scalar fields, so without
  -- these, Mult cards score 0 mult, Stone cards 0 bonus, etc.
  if t.ability.name == 'Stone Card' then
    t.ability.effect = t.ability.effect or 'Stone Card'
    if t.ability.bonus == 0 then t.ability.bonus = 50 end
  elseif t.ability.name == 'Wild Card' then
    t.ability.effect = t.ability.effect or 'Wild Card'
  elseif t.ability.name == 'Glass Card' then
    t.ability.effect = t.ability.effect or 'Glass Card'
    if t.ability.x_mult == 1 then t.ability.x_mult = 2 end
  elseif t.ability.name == 'Steel Card' then
    t.ability.effect = t.ability.effect or 'Steel Card'
    if t.ability.h_x_mult == 0 then t.ability.h_x_mult = 1.5 end
  elseif t.ability.name == 'Mult' then
    t.ability.effect = t.ability.effect or 'Mult Card'
    if t.ability.mult == 0 then t.ability.mult = 4 end
  elseif t.ability.name == 'Lucky Card' then
    t.ability.effect = t.ability.effect or 'Lucky Card'
    if t.ability.mult == 0 then t.ability.mult = 20 end
    if t.ability.x_mult == 1 then t.ability.x_mult = 1 end
  elseif t.ability.name == 'Gold Card' then
    t.ability.effect = t.ability.effect or 'Gold Card'
    if t.ability.h_dollars == 0 then t.ability.h_dollars = 3 end
  elseif t.ability.name == 'Bonus' then
    t.ability.effect = t.ability.effect or 'Bonus'
    if t.ability.bonus == 0 then t.ability.bonus = 30 end
  end
  setmetatable(t, { __index = Card })
  return t
end

local function attach_joker(t)
  t.ability = t.ability or {}
  default_ability(t.ability)
  fill_edition(t.edition)
  t.ability.chips = t.ability.chips or 0
  t.ability.set   = t.ability.set   or 'Joker'
  t.debuff = t.debuff or false
  t.T      = t.T or { x = 0, y = 0 }
  -- Real jokers are Card instances and have a .base populated by
  -- Card:set_base. eval_card calls get_chip_bonus on every card it
  -- evaluates, including jokers from G.jokers, so .base must exist.
  t.base   = t.base or { nominal = 0, suit_nominal = 0,
                         suit_nominal_original = 0, face_nominal = 0,
                         id = 0, suit = '', value = '' }

  local key = name_to_key[t.ability.name]
  if key and G.P_CENTERS[key] then
    local cfg = G.P_CENTERS[key].config or {}
    if t.ability.extra == nil then
      if type(cfg.extra) == 'table' then
        local copy = {}
        for k, v in pairs(cfg.extra) do copy[k] = v end
        t.ability.extra = copy
      else
        t.ability.extra = cfg.extra
      end
    end
    if t.ability.mult    == 0 and cfg.mult    then t.ability.mult    = cfg.mult    end
    if t.ability.chips   == 0 and cfg.chips   then t.ability.chips   = cfg.chips   end
    if t.ability.t_mult  == 0 and cfg.t_mult  then t.ability.t_mult  = cfg.t_mult  end
    if t.ability.t_chips == 0 and cfg.t_chips then t.ability.t_chips = cfg.t_chips end
    if t.ability.x_mult  == 1 and cfg.Xmult   then t.ability.x_mult  = cfg.Xmult   end
    t.ability.type      = t.ability.type      or cfg.type      or ''
    t.ability.h_mult    = t.ability.h_mult    or cfg.h_mult    or 0
    t.ability.h_x_mult  = t.ability.h_x_mult  or cfg.h_x_mult  or 0
    t.ability.p_dollars = t.ability.p_dollars or cfg.p_dollars or 0
    t.ability.h_size    = t.ability.h_size    or cfg.h_size    or 0
    t.ability.d_size    = t.ability.d_size    or cfg.d_size    or 0
    t.ability.effect    = t.ability.effect    or G.P_CENTERS[key].effect
    t.config = t.config or {}
    t.config.center = G.P_CENTERS[key]
  end

  setmetatable(t, { __index = Card })
  return t
end

H.attach_card  = attach_card
H.attach_joker = attach_joker

-------------------------------------------------------------------------
-- install_fixture(fx) — populate G.* with a fresh copy of the fixture.
-- Returns played, held arrays.
-------------------------------------------------------------------------
local function deepcopy(t)
  if type(t) ~= 'table' then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepcopy(v) end
  return out
end

local function install_fixture(fx)
  local played, held = {}, {}
  for i, c in ipairs(fx.played) do played[i] = attach_card(deepcopy(c)) end
  for i, c in ipairs(fx.held)   do held[i]   = attach_card(deepcopy(c)) end

  G.jokers.cards = {}
  for i, j in ipairs(fx.jokers) do G.jokers.cards[i] = attach_joker(deepcopy(j)) end

  G.GAME.hands         = deepcopy(fx.game.hands) or {}
  G.GAME.current_round = deepcopy(fx.game.current_round) or {}
  G.GAME.current_round.current_hand = G.GAME.current_round.current_hand
    or { handname = '', chips = 0, mult = 0, chip_total = 0 }
  G.GAME.blind         = deepcopy(fx.game.blind) or { name = '', disabled = false }
  G.GAME.dollars       = fx.game.dollars or 0
  G.GAME.modifiers     = G.GAME.modifiers or {}

  -- Blind methods used by evaluate_play. Default: pass-through, no debuff.
  -- Honour the captured `debuffed_by_blind` flag if present.
  local debuffed = fx.debuffed_by_blind == true
  G.GAME.blind.debuff_hand = function(_self, _cards, _phs, _text) return debuffed end
  G.GAME.blind.modify_hand = function(_self, _cards, _phs, _text, m, c) return m, c, false end
  G.GAME.blind.juice_up    = function() end
  G.GAME.blind.stay_flipped = function() return false end

  G.GAME.selected_back = G.GAME.selected_back or {}
  G.GAME.selected_back.trigger_effect = function() return nil, nil end

  G.play.cards = played
  G.hand.cards = held

  G.playing_cards = {}
  for _, c in ipairs(played) do G.playing_cards[#G.playing_cards+1] = c end
  for _, c in ipairs(held)   do G.playing_cards[#G.playing_cards+1] = c end

  -- Reconstruct Steel Card total for held-Steel-counting jokers.
  local steel_target = fx.game and fx.game.steel_card_count
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

  -- Steel/Stone tallies for joker scaling reads.
  local steel, stone = 0, 0
  for _, c in ipairs(G.playing_cards) do
    local n = c.ability and c.ability.name
    if n == 'Steel Card' then steel = steel + 1 end
    if n == 'Stone Card' then stone = stone + 1 end
  end
  for _, j in ipairs(G.jokers.cards) do
    if j.ability.steel_tally == nil then j.ability.steel_tally = steel end
    if j.ability.stone_tally == nil then j.ability.stone_tally = stone end
  end

  G.deck.cards = {}
  for i = 1, (fx.game and fx.game.deck_remaining or 0) do G.deck.cards[i] = {} end

  return played, held
end

H.install_fixture = install_fixture

-------------------------------------------------------------------------
-- Capture loader (sandboxed math env so a malicious capture can't run
-- arbitrary code; matches batch_verify.lua's policy).
-------------------------------------------------------------------------
function H.load_fixture(path)
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
-- BestHand loader — returns score_combo via _BH global.
-------------------------------------------------------------------------
function H.load_besthand(path)
  path = path or 'BestHand.lua'
  local f = assert(io.open(path, 'r'))
  local src = f:read('*a')
  f:close()
  src = src .. '\n_G._BH = { score_combo = score_combo,'
            .. ' clear_smeared_cache = clear_smeared_cache }\n'
  local chunk = assert(loadstring(src, 'BestHand'))
  chunk()
  assert(_BH and _BH.score_combo, 'score_combo export failed')
  return _BH.score_combo
end

-------------------------------------------------------------------------
-- Mod scoring with probabilistic enumeration (verbatim from
-- batch_verify.lua's score_fixture).
-------------------------------------------------------------------------
function H.mod_score(fx, opts)
  opts = opts or {}
  local cap = opts.cap or 10000
  local played, held = install_fixture(fx)
  local all = {}
  for _, c in ipairs(played) do all[#all+1] = c end
  for _, c in ipairs(held)   do all[#all+1] = c end

  -- score_combo's caller in-game (analyze_hand) clears the Smeared
  -- Joker cache via with_no_resolve. We bypass that wrapper, so clear
  -- here — otherwise the cache leaks across fixtures and a fixture's
  -- Smeared logic depends on the prior fixture's joker set.
  if _BH.clear_smeared_cache then _BH.clear_smeared_cache() end

  local _, ev_score, _, _, prob_arities, range_events =
    _BH.score_combo(played, all, nil, nil)
  prob_arities = prob_arities or {}
  range_events = range_events or {}
  local n_prob = #prob_arities
  local n_range = #range_events

  local possible, seen = {}, {}
  local function add(s)
    if not seen[s] then seen[s] = true; possible[#possible+1] = s end
  end

  local range_total = 1
  for _, iv in ipairs(range_events) do
    range_total = range_total * (iv[2] - iv[1] + 1)
  end
  local prob_total = 1
  for _, a in ipairs(prob_arities) do prob_total = prob_total * a end
  local total_configs = prob_total * range_total

  if (n_prob + n_range) == 0 then
    add(ev_score)
  elseif total_configs <= cap then
    for pmask = 0, prob_total - 1 do
      local pcfg, tmp = {}, pmask
      for i, a in ipairs(prob_arities) do
        pcfg[i] = tmp % a
        tmp = math.floor(tmp / a)
      end
      for ridx = 0, range_total - 1 do
        local rcfg, rtmp = {}, ridx
        for i, iv in ipairs(range_events) do
          local span = iv[2] - iv[1] + 1
          rcfg[i] = iv[1] + (rtmp % span)
          rtmp = math.floor(rtmp / span)
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
-- Oracle: load common_events.lua + state_events.lua and run real
-- evaluate_play. Re-stub helpers that reach for state we don't have.
-------------------------------------------------------------------------
-- balatro_src/ is the un-patched vanilla extraction. The live game runs
-- under SMODS (smods/lovely/better_calc.toml), which replaces vanilla's
-- `mult = mod_mult(mult * Xmult_mod)` with the form
-- `Scoring_Parameters.mult:modify(mult * (amount - 1))` — i.e.
-- `mult + mult * (Xmult_mod - 1)`. Mathematically equal, but it
-- accumulates ULP drift differently. Without this rewrite the offline
-- oracle disagrees with both the in-game scorer and BestHand's own
-- `apply_xmult` at the ±1-chip level on hands involving Steel Joker
-- (the only joker whose xMult is a 0.2-step decimal that triggers the
-- subtractive-cancellation in `Xmult_mod - 1`).
local function load_state_events_smods_form()
  local path = SRC_DIR .. '/functions/state_events.lua'
  local f, err = io.open(path, 'r')
  if not f then
    io.stderr:write('[harness] failed to open ' .. path .. ': ' .. tostring(err) .. '\n')
    os.exit(1)
  end
  local src = f:read('*a'); f:close()
  src = src:gsub('mult%*([%w_%.]+)%.Xmult_mod',
                 '(mult + mult*(%1.Xmult_mod - 1))')
  src = src:gsub('mult%*([%w_%.]+)%.x_mult_mod',
                 '(mult + mult*(%1.x_mult_mod - 1))')
  local chunk, lerr = loadstring(src, '@' .. path)
  if not chunk then
    io.stderr:write('[harness] state_events.lua patch failed: ' .. tostring(lerr) .. '\n')
    os.exit(1)
  end
  chunk()
end

local oracle_loaded = false
function H.enable_oracle()
  if oracle_loaded then return end
  load_src('functions/common_events.lua')
  load_state_events_smods_form()

  -- common_events.lua redefines these against UI/state we don't model.
  -- Synchronous side effects in their bodies break things (e.g.
  -- update_hand_text reads G.hand_text_area, level_up_hand mutates
  -- G.GAME.hands then queues UI events). Replace with no-ops; the
  -- inside-event UI work was already discarded by our E_MANAGER stub.
  -- misc_functions.lua and common_events.lua redefined these against
  -- state we don't have (G.GAME.pseudorandom, G.CARD_W, G.P_CARDS).
  -- Re-stub so the score path doesn't crash.
  function pseudorandom(_) return 0 end
  function pseudoseed(_) return 'seed' end
  function pseudorandom_element(t) return t and t[1] or nil, 1 end
  -- copy_card is called by destructive jokers (DNA, Vampire). The
  -- copied card may have :add_to_deck / :start_materialize / etc.
  -- called on it, so return a sink whose every method is a no-op.
  -- These jokers don't affect THIS hand's score either way.
  local card_sink_mt = { __index = function() return function() end end }
  function copy_card()
    return setmetatable({ ability = {}, base = {}, config = { center = {}, card = {} },
                          states = {}, edition = false, seal = nil }, card_sink_mt)
  end
  function update_hand_text() end
  function highlight_card() end
  function ease_dollars() end
  function level_up_hand() end
  function check_for_unlock() end
  function play_area_status_text() end
  function ease_chips() end
  function ease_background_colour() end
  function set_screen_positions() end
  function set_alerts() end
  function draw_card() end
  function delay() end
  function card_eval_status_text() end
  function juice_card() end
  function play_sound() end
  function attention_text() end
  function add_tag() end
  function inc_career_stat() end
  function nominal_chip_inc() end
  function save_run() end
  function add_round_eval_row() end

  -- state_events.lua's get_poker_hand_info uses localize for disp_text;
  -- our localize stub is fine. Keep the real one — it returns
  -- (text, loc_disp_text, poker_hands, scoring_hand, disp_text).
  assert(G.FUNCS.evaluate_play, 'evaluate_play missing')
  assert(G.FUNCS.get_poker_hand_info, 'get_poker_hand_info missing')
  assert(eval_card, 'eval_card missing')

  oracle_loaded = true
end

-- oracle_score(fx) — install fixture, call evaluate_play, return
-- floor(hand_chips * mult). evaluate_play assigns to module-global
-- `mult` and `hand_chips` (no `local`) so we read them post-call.
function H.oracle_score(fx)
  if not oracle_loaded then H.enable_oracle() end
  install_fixture(fx)
  -- Reset module globals.
  _G.mult = 0
  _G.hand_chips = 0
  local ok, err = xpcall(function() G.FUNCS.evaluate_play(nil) end, debug.traceback)
  if not ok then return nil, err end
  local m  = tonumber(_G.mult) or 0
  local hc = tonumber(_G.hand_chips) or 0
  return math.floor(hc * m)
end

-------------------------------------------------------------------------
-- Capture writer — emit a fixture in the same format as F4 captures.
-------------------------------------------------------------------------
local function quote(s) return string.format('%q', s) end
local function is_valid_key(s)
  return type(s) == 'string' and s:match('^[%a_][%w_]*$') and not (
    s == 'and' or s == 'or' or s == 'not' or s == 'if' or s == 'then' or
    s == 'else' or s == 'elseif' or s == 'end' or s == 'for' or s == 'in' or
    s == 'do' or s == 'while' or s == 'repeat' or s == 'until' or s == 'local' or
    s == 'function' or s == 'return' or s == 'true' or s == 'false' or s == 'nil' or
    s == 'break'
  )
end

local function serialize(v, indent)
  indent = indent or '  '
  local depth = 0
  local function rec(val)
    local t = type(val)
    if t == 'nil' or t == 'boolean' or t == 'number' then return tostring(val) end
    if t == 'string' then return quote(val) end
    if t ~= 'table' then return 'nil' end
    depth = depth + 1
    local pad  = indent:rep(depth)
    local pad0 = indent:rep(depth - 1)
    -- Detect array vs map.
    local is_array, n = true, 0
    for k in pairs(val) do n = n + 1 end
    for i = 1, n do if val[i] == nil then is_array = false; break end end
    local parts = {}
    if is_array then
      for i = 1, n do parts[#parts+1] = pad .. rec(val[i]) end
    else
      local keys = {}
      for k in pairs(val) do keys[#keys+1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        local krep
        if is_valid_key(k) then krep = k
        else krep = '[' .. (type(k) == 'string' and quote(k) or tostring(k)) .. ']' end
        parts[#parts+1] = pad .. krep .. ' = ' .. rec(val[k])
      end
    end
    depth = depth - 1
    if #parts == 0 then return '{}' end
    return '{\n' .. table.concat(parts, ',\n') .. ',\n' .. pad0 .. '}'
  end
  return rec(v)
end

function H.serialize_capture(fx)
  return '-- BestHand capture fixture — auto-generated, safe to delete\n'
      .. 'return ' .. serialize(fx) .. '\n'
end

return H
