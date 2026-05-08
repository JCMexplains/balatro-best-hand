-- test_score_combo_returns.lua
-- Pin score_combo's return-type contract: positions 5 (prob_arities)
-- and 6 (range_events) MUST be tables, even on the early-return paths.
--
-- Regression for the crash where The Psychic blind + <5 played cards
-- (and similarly The Eye / The Mouth debuff) returned `0` for
-- prob_arities; the evaluate_play wrapper then crashed at
-- `#prob_arities` ("attempt to get length of a number value").

local H = dofile('harness.lua')
local score_combo = H.load_besthand()

local function ace(suit)
  return {
    ability = { name = 'Default Base', perma_bonus = 0 },
    base    = { id = 14, nominal = 11, suit = suit, value = 'Ace' },
  }
end

local base_hands = {
  ['High Card'] = {
    chips = 5, mult = 1, level = 1,
    played = 0, played_this_round = 0,
    l_chips = 10, l_mult = 1, visible = true,
  },
  Pair = {
    chips = 10, mult = 2, level = 1,
    played = 0, played_this_round = 0,
    l_chips = 15, l_mult = 1, visible = true,
  },
  Flush = {
    chips = 35, mult = 4, level = 1,
    played = 0, played_this_round = 0,
    l_chips = 15, l_mult = 2, visible = true,
  },
}

local function clone_hands()
  local out = {}
  for name, h in pairs(base_hands) do
    local c = {}
    for k, v in pairs(h) do c[k] = v end
    out[name] = c
  end
  return out
end

-- Case 1: The Psychic with <5 played cards. Triggers the
-- `#cards < 5 then return ..., {}, {}` short-circuit.
local psychic_fixture = {
  played = { ace('Hearts'), ace('Clubs') },
  held   = {},
  jokers = {},
  game   = {
    hands = clone_hands(),
    current_round = { hands_left = 1, discards_left = 1, dollars = 0 },
    blind = { name = 'The Psychic', disabled = false },
    dollars = 0,
  },
}

-- Case 2: The Eye where the played hand_name has already been
-- played this round. Triggers the `is_hand_debuffed_by_blind`
-- short-circuit. Uses a Flush so we hit the path with >=5 cards
-- and the debuff branch is the only thing that can short-circuit.
local eye_hands = clone_hands()
eye_hands.Flush.played_this_round = 1
local eye_fixture = {
  played = {
    ace('Hearts'),
    { ability = { name = 'Default Base', perma_bonus = 0 },
      base = { id = 13, nominal = 10, suit = 'Hearts', value = 'King' } },
    { ability = { name = 'Default Base', perma_bonus = 0 },
      base = { id = 12, nominal = 10, suit = 'Hearts', value = 'Queen' } },
    { ability = { name = 'Default Base', perma_bonus = 0 },
      base = { id = 10, nominal = 10, suit = 'Hearts', value = '10' } },
    { ability = { name = 'Default Base', perma_bonus = 0 },
      base = { id = 7,  nominal = 7,   suit = 'Hearts', value = '7' } },
  },
  held   = {},
  jokers = {},
  game   = {
    hands = eye_hands,
    current_round = { hands_left = 1, discards_left = 1, dollars = 0 },
    blind = { name = 'The Eye', disabled = false },
    dollars = 0,
  },
}

local function run(label, fx)
  local played, held = H.install_fixture(fx)
  local all = {}
  for _, c in ipairs(played) do all[#all+1] = c end
  for _, c in ipairs(held)   do all[#all+1] = c end

  local hand_name, score, scoring, used_ev, prob_arities, range_events =
    score_combo(played, all)

  assert(hand_name, label .. ': hand_name nil')
  assert(score == 0, string.format(
    '%s: expected score=0 on short-circuit, got %s',
    label, tostring(score)))
  assert(type(prob_arities) == 'table', string.format(
    '%s: prob_arities must be a table, got %s (value=%s)',
    label, type(prob_arities), tostring(prob_arities)))
  assert(type(range_events) == 'table', string.format(
    '%s: range_events must be a table, got %s (value=%s)',
    label, type(range_events), tostring(range_events)))
  -- The bug: `#prob_arities` crashed when prob_arities was a number.
  -- Guard against regression by exercising it directly.
  local ok, err = pcall(function() return #prob_arities + #range_events end)
  assert(ok, label .. ': # operator on returned tables failed: ' .. tostring(err))

  print(string.format(
    '  ok %s  hand=%s score=%d #prob=%d #range=%d',
    label, hand_name, score, #prob_arities, #range_events))
end

print('test_score_combo_returns')
run('psychic_short_play',  psychic_fixture)
run('eye_repeat_hand_type', eye_fixture)
print('PASS')
