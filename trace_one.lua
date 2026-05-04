-- trace_one.lua <capture_path>
-- Replay a single saved fixture through BestHand's score_combo with
-- the same shim batch_verify uses. Use to investigate a specific miss.
--
-- Single-shot EV scoring only (no probabilistic enumeration). For hands
-- with Lucky Card / Bloodstone / Misprint, the reported MISS may be a
-- legitimate match against one of the discrete outcomes — use
-- batch_verify.lua to confirm.

local capture_path = arg[1]
if not capture_path then
  print('usage: lua trace_one.lua <capture.lua>')
  os.exit(1)
end

local H = dofile('harness.lua')
H.enable_oracle()  -- pulls in real G.FUNCS.get_poker_hand_info
local score_combo = H.load_besthand()

local fx = assert(H.load_fixture(capture_path))
local played, held = H.install_fixture(fx)

local all_cards = {}
for _, c in ipairs(played) do all_cards[#all_cards+1] = c end
for _, c in ipairs(held)   do all_cards[#all_cards+1] = c end

local rank_name = {
  [2]='2', [3]='3', [4]='4', [5]='5', [6]='6', [7]='7', [8]='8',
  [9]='9', [10]='T', [11]='J', [12]='Q', [13]='K', [14]='A',
}
local suitch = { Hearts='h', Diamonds='d', Clubs='c', Spades='s' }
local function lbl(card)
  local rk = rank_name[card.base.id] or '?'
  local sc = suitch[card.base.suit] or '?'
  local enh = card.ability and card.ability.name or ''
  local tag = (enh ~= '' and enh ~= 'Default Base')
    and ('(' .. enh .. ')') or ''
  return rk .. sc .. tag
end

print(string.format('=== %s ===',
  capture_path:match('[^/\\]+$') or capture_path))
print(string.format('hand_name=%s  actual=%s  stored_predicted=%s',
  tostring(fx.hand_name),
  tostring(fx.actual_score),
  tostring(fx.predicted_score)))
print()
print('Played:')
for i, c in ipairs(played) do
  print(string.format('  [%d] %s', i, lbl(c)))
end
print('Held:')
for i, c in ipairs(held) do
  print(string.format('  [%d] %s', i, lbl(c)))
end
print('Jokers:')
for i, j in ipairs(G.jokers.cards) do
  local ed = ''
  if j.edition then
    for k, v in pairs(j.edition) do
      if v then ed = ed .. ' ' .. k end
    end
  end
  print(string.format('  [%d] %s%s', i, j.ability.name, ed))
end
print()

local hand_name, total, _, used_ev, prob_arities =
  score_combo(played, all_cards)
local n_prob = prob_arities and #prob_arities or 0

print(string.format(
  'hand=%s  predicted=%s  actual=%s  (used_ev=%s n_prob=%s)',
  tostring(hand_name), tostring(total), tostring(fx.actual_score),
  tostring(used_ev), tostring(n_prob)))
if total == fx.actual_score then
  print('MATCH')
else
  print(string.format('MISS (delta = %s)',
    tostring((fx.actual_score or 0) - total)))
end
