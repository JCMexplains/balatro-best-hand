-- bench_profile.lua — short-circuit different phases to attribute cost.
-- Measures total time when each named region is patched out, so the
-- cost of that region = (full_time - patched_time).

local H = dofile('harness.lua')
local capture_path = arg[1] or 'best_hand_captures/capture_20260423_111931_1.lua'
local iters = tonumber(arg[2]) or 100

H.enable_oracle()
local fx = H.load_fixture(capture_path)
local _ = H.load_besthand('BestHand.lua')  -- loads _BH globals
local played, held = H.install_fixture(fx)
local all = {}
for _, c in ipairs(played) do all[#all + 1] = c end
for _, c in ipairs(held)   do all[#all + 1] = c end

local function combinations(list, k)
  local result = {}
  local function helper(start, combo)
    if #combo == k then result[#result + 1] = {unpack(combo)}; return end
    for i = start, #list - (k - #combo) + 1 do
      combo[#combo + 1] = list[i]; helper(i + 1, combo); combo[#combo] = nil
    end
  end
  helper(1, {})
  return result
end

local subsets = {}
for size = 5, 1, -1 do
  if #all >= size then
    for _, combo in ipairs(combinations(all, size)) do
      subsets[#subsets + 1] = combo
    end
  end
end

print(string.format('capture=%s  cards=%d  subsets=%d  iters=%d',
  capture_path:match('([^/\\]+)$'), #all, #subsets, iters))

local function bench(label, score_fn)
  -- warmup
  for _, combo in ipairs(subsets) do score_fn(combo, all, nil, nil) end
  local t0 = os.clock()
  for _ = 1, iters do
    for _, combo in ipairs(subsets) do score_fn(combo, all, nil, nil) end
  end
  local elapsed = os.clock() - t0
  print(string.format('%-32s %8.2f ms/iter  (per combo %5.1f us)',
    label, elapsed * 1000 / iters, elapsed * 1e6 / (iters * #subsets)))
  return elapsed
end

-- Baseline
bench('baseline', _BH.score_combo)

-- Phase 3 short-circuit: replace G.jokers.cards with empty table during loop
local saved_jokers = G.jokers and G.jokers.cards
do
  -- Stub get_poker_hand_info to a constant — bypass all the
  -- evaluate_poker_hand work.
  local saved_gphi = G.FUNCS.get_poker_hand_info
  G.FUNCS.get_poker_hand_info = function() return 'High Card', nil, {Pair={},Flush={},Straight={},["Two Pair"]={},["Three of a Kind"]={},["Four of a Kind"]={},["Five of a Kind"]={},["Full House"]={},["Straight Flush"]={},["Royal Flush"]={},["Flush Five"]={},["Flush House"]={},["High Card"]={{}}} end
  bench('w/o get_poker_hand_info', _BH.score_combo)
  G.FUNCS.get_poker_hand_info = saved_gphi
end

do
  G.jokers.cards = {}
  bench('w/o any jokers (phase 1+2+3)', _BH.score_combo)
  G.jokers.cards = saved_jokers
end
