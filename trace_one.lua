-- trace_one.lua <capture_path>
-- Replay a single saved fixture through BestHand's score_combo with
-- the same shim that batch_verify uses — loads balatro_src/card.lua
-- and attaches the Card metatable so dispatch goes through the real
-- Card:calculate_joker. Use to investigate a specific miss.
--
-- Set BH_DEBUG=1 for a per-joker Phase-3 trace.

local capture_path = arg[1]
if not capture_path then
  print('usage: lua trace_one.lua <capture.lua>')
  os.exit(1)
end

local SRC_DIR = 'balatro_src'

-------------------------------------------------------------------------
-- Shim: same as batch_verify.lua. Extracted here so trace_one stays
-- usable when run standalone; if this drifts from batch_verify we risk
-- the two tools disagreeing about fixtures.
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

G = {
  GAME = {
    used_vouchers = {}, probabilities = { normal = 1 },
    consumeable_buffer = 0, round_resets = { ante = 1 },
    hands = {}, current_round = {},
    blind = { name = '', disabled = false },
    dollars = 0,
    cards_played = setmetatable({}, { __index = function()
      return { total = 0, suits = {} }
    end }),
  },
  P_CENTERS = {}, P_CENTER_POOLS = { Joker = {} },
  C = setmetatable({}, { __index = function() return {} end }),
  jokers = { cards = {}, config = { card_limit = 5 } },
  consumeables = { cards = {}, config = { card_limit = 2 } },
  hand = { cards = {} }, play = { cards = {} },
  deck = { cards = {} }, playing_cards = {},
  E_MANAGER = { add_event = function() end }, FUNCS = {},
  RESET_JIGGLES = false,
}
SMODS = {}
function SMODS.calculate_round_score() return 0 end
function SMODS.Keybind(_) end
function pseudorandom(_) return 0 end
function pseudoseed(_) return 'seed' end
function pseudorandom_element(t) return t and t[1] or nil, 1 end
function Event(e) return e end
function Tag(_) return {} end
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
function localize(_)
  return setmetatable({}, { __index = function() return '' end })
end
love = {
  filesystem = {
    getSaveDirectory = function() return '.' end,
    createDirectory = function() end,
  },
}

local function load_src(name)
  local ok, err = pcall(dofile, SRC_DIR .. '/' .. name)
  if not ok then
    io.stderr:write('[shim] ' .. name .. ': ' .. tostring(err) .. '\n')
    os.exit(1)
  end
end
load_src('card.lua')
load_src('functions/misc_functions.lua')
function localize(_)
  return setmetatable({}, { __index = function() return '' end })
end
assert(Card and Card.calculate_joker, 'Card:calculate_joker missing')
assert(evaluate_poker_hand, 'evaluate_poker_hand missing')

local SUIT_NOMINAL = { Diamonds = 0.01, Clubs = 0.02, Hearts = 0.03, Spades = 0.04 }
local SUIT_NOMINAL_ORIG = { Diamonds = 0.001, Clubs = 0.002, Hearts = 0.003, Spades = 0.004 }

-- P_CENTERS extraction (lines 364..702 of game.lua are pure data)
local function extract_p_centers()
  local f = assert(io.open(SRC_DIR .. '/game.lua', 'r'))
  local in_block, depth, buf = false, 0, { 'return {' }
  for line in f:lines() do
    if not in_block then
      if line:match('self%.P_CENTERS%s*=%s*{') then
        in_block = true; depth = 1
      end
    else
      local opens = select(2, line:gsub('{', ''))
      local closes = select(2, line:gsub('}', ''))
      depth = depth + opens - closes
      if depth <= 0 then buf[#buf+1] = '}'; break end
      buf[#buf+1] = line
    end
  end
  f:close()
  local chunk, err = loadstring(table.concat(buf, '\n'), 'P_CENTERS')
  if not chunk then error('P_CENTERS parse: ' .. tostring(err)) end
  return chunk()
end
G.P_CENTERS = extract_p_centers()
local name_to_key = {}
for key, center in pairs(G.P_CENTERS) do
  if type(center) == 'table' and center.name and center.set == 'Joker' then
    name_to_key[center.name] = key
  end
end

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
      text = name; scoring_hand = poker_hands[name][1]; break
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

-- Load BestHand.lua with score_combo export
local f = assert(io.open('BestHand.lua', 'r'))
local src = f:read('*a')
f:close()
src = src .. '\n_G._BH = { score_combo = score_combo }\n'
local chunk = assert(loadstring(src, 'BestHand'))
chunk()
assert(_BH and _BH.score_combo, 'score_combo export failed')

-- Fixture loader (sandboxed, same as batch_verify)
local function load_fixture(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local src = f:read('*a')
  f:close()
  local chunk = assert(loadstring(src, path))
  setfenv(chunk, { math = { huge = math.huge } })
  return chunk()
end

-- Card / joker rehydration with Card metatable attached
local unique_id_seq = 0
local function attach_card(t)
  t.ability = t.ability or {}
  t.ability.perma_bonus = t.ability.perma_bonus or 0
  t.ability.bonus = t.ability.bonus or 0
  t.ability.mult = t.ability.mult or 0
  t.base = t.base or {}
  t.base.nominal = t.base.nominal or 0
  t.base.suit_nominal = t.base.suit_nominal or SUIT_NOMINAL[t.base.suit] or 0
  t.base.suit_nominal_original = t.base.suit_nominal_original
    or SUIT_NOMINAL_ORIG[t.base.suit] or 0
  t.base.face_nominal = t.base.face_nominal or 0
  unique_id_seq = unique_id_seq + 1
  t.unique_val = t.unique_val or unique_id_seq
  t.debuff = t.debuff or false
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
  t.ability.mult = t.ability.mult or 0
  t.ability.x_mult = t.ability.x_mult or 1
  t.ability.chips = t.ability.chips or 0
  t.ability.t_mult = t.ability.t_mult or 0
  t.ability.t_chips = t.ability.t_chips or 0
  t.ability.perma_bonus = t.ability.perma_bonus or 0
  t.ability.set = t.ability.set or 'Joker'
  t.debuff = t.debuff or false
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
    if t.ability.mult == 0 and cfg.mult then t.ability.mult = cfg.mult end
    if t.ability.chips == 0 and cfg.chips then t.ability.chips = cfg.chips end
    if t.ability.t_mult == 0 and cfg.t_mult then t.ability.t_mult = cfg.t_mult end
    if t.ability.t_chips == 0 and cfg.t_chips then t.ability.t_chips = cfg.t_chips end
    if t.ability.x_mult == 1 and cfg.Xmult then t.ability.x_mult = cfg.Xmult end
    t.ability.type = t.ability.type or cfg.type or ''
    t.ability.h_mult = t.ability.h_mult or cfg.h_mult or 0
    t.ability.h_x_mult = t.ability.h_x_mult or cfg.h_x_mult or 0
    t.ability.p_dollars = t.ability.p_dollars or cfg.p_dollars or 0
    t.ability.h_size = t.ability.h_size or cfg.h_size or 0
    t.ability.d_size = t.ability.d_size or cfg.d_size or 0
    t.ability.effect = t.ability.effect or G.P_CENTERS[key].effect
    t.config = t.config or {}
    t.config.center = G.P_CENTERS[key]
  end
  setmetatable(t, { __index = Card })
  return t
end

-------------------------------------------------------------------------
-- Install fixture, score, print
-------------------------------------------------------------------------
local fx = assert(load_fixture(capture_path))

local played, held = {}, {}
for i, c in ipairs(fx.played) do played[i] = attach_card(c) end
for i, c in ipairs(fx.held)   do held[i]   = attach_card(c) end
G.jokers.cards = {}
for i, j in ipairs(fx.jokers) do G.jokers.cards[i] = attach_joker(j) end
G.GAME.hands = fx.game.hands or {}
G.GAME.current_round = fx.game.current_round or {}
G.GAME.blind = fx.game.blind or { name = '', disabled = false }
G.GAME.dollars = fx.game.dollars or 0

local all_cards = {}
for _, c in ipairs(played) do all_cards[#all_cards+1] = c end
for _, c in ipairs(held)   do all_cards[#all_cards+1] = c end
G.playing_cards = {}
for _, c in ipairs(all_cards) do G.playing_cards[#G.playing_cards+1] = c end
local steel_target = fx.game and fx.game.steel_card_count
if steel_target then
  local have = 0
  for _, c in ipairs(G.playing_cards) do
    if c.ability and c.ability.name == 'Steel Card' then have = have + 1 end
  end
  for _ = 1, steel_target - have do
    G.playing_cards[#G.playing_cards+1] = attach_card({
      ability = { name = 'Steel Card' },
      base = { id = 0, suit = 'Spades', nominal = 0 },
      debuff = false,
    })
  end
end
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

local rank_name = { [2]='2',[3]='3',[4]='4',[5]='5',[6]='6',[7]='7',[8]='8',
  [9]='9',[10]='T',[11]='J',[12]='Q',[13]='K',[14]='A' }
local suitch = { Hearts='h', Diamonds='d', Clubs='c', Spades='s' }
local function lbl(card)
  local rk = rank_name[card.base.id] or '?'
  local sc = suitch[card.base.suit] or '?'
  local enh = card.ability and card.ability.name or ''
  local tag = (enh ~= '' and enh ~= 'Default Base') and ('(' .. enh .. ')') or ''
  return rk .. sc .. tag
end

print(string.format('=== %s ===', capture_path:match('[^/\\]+$') or capture_path))
print(string.format('hand_name=%s  actual=%s  stored_predicted=%s',
  tostring(fx.hand_name), tostring(fx.actual_score), tostring(fx.predicted_score)))
print()
print('Played:')
for i, c in ipairs(played) do print(string.format('  [%d] %s', i, lbl(c))) end
print('Held:')
for i, c in ipairs(held) do print(string.format('  [%d] %s', i, lbl(c))) end
print('Jokers:')
for i, j in ipairs(G.jokers.cards) do
  local ed = ''
  if j.edition then
    for k, v in pairs(j.edition) do if v then ed = ed .. ' ' .. k end end
  end
  print(string.format('  [%d] %s%s', i, j.ability.name, ed))
end
print()

local hand_name, total, scoring_cards, used_ev, n_prob =
  _BH.score_combo(played, all_cards)

print(string.format('hand=%s  predicted=%s  actual=%s  (used_ev=%s n_prob=%s)',
  tostring(hand_name), tostring(total), tostring(fx.actual_score),
  tostring(used_ev), tostring(n_prob)))
if total == fx.actual_score then
  print('MATCH')
else
  print(string.format('MISS (delta = %s)', tostring((fx.actual_score or 0) - total)))
  print('Re-run with BH_DEBUG=1 to see Phase-3 per-joker dispatch.')
end
