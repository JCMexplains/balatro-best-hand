-- bench_f2.lua — benchmark analyze_hand-style F2 cost.
-- Loads a capture, then runs score_combo over many subsets to mimic
-- analyze_hand's combinatorial search. Reports total + per-combo time.
--
-- Usage: lua bench_f2.lua [capture.lua] [iterations]
--   default capture: most recent in best_hand_captures
--   default iterations: 50 (each iteration scores all 5/4/3/2/1-card subsets)

local H = dofile('harness.lua')

local capture_path = arg[1]
if not capture_path then
  -- Pick a recent capture
  local p = io.popen('ls -t best_hand_captures/*.lua 2>/dev/null')
  if p then capture_path = p:read('*l'); p:close() end
end
assert(capture_path, 'no capture path provided')
local iters = tonumber(arg[2]) or 50

H.enable_oracle()  -- needed for G.FUNCS.get_poker_hand_info
local score_combo = H.load_besthand('BestHand.lua')
local fx = H.load_fixture(capture_path)
local played, held = H.install_fixture(fx)

-- Build the full hand list (played + held) — analyze_hand operates on
-- G.hand.cards, not just played, so we union them. install_fixture
-- returns the rehydrated cards (with metatables), not the plain
-- fixture tables.
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

-- Pre-build all subsets up front so the timing measures score_combo only
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

-- Warmup
for _, combo in ipairs(subsets) do score_combo(combo, all, nil, nil) end

local t0 = os.clock()
for _ = 1, iters do
  for _, combo in ipairs(subsets) do score_combo(combo, all, nil, nil) end
end
local elapsed = os.clock() - t0
local total_combos = iters * #subsets
print(string.format('elapsed=%.3fs  total_combos=%d  per_combo=%.1f us  per_iter=%.2f ms',
  elapsed, total_combos,
  elapsed * 1e6 / total_combos,
  elapsed * 1000 / iters))
