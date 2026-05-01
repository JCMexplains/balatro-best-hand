-- batch_verify.lua — replay every capture through BestHand's
-- score_combo and report ok / ok(var) / MISS.
--
-- Each capture is enumerated over the cartesian product of boolean
-- probabilistic events (Lucky Card, Bloodstone) × integer range events
-- (Misprint), bounded at 10,000 configurations. A capture passes "ok"
-- when the game's actual score matches BestHand's EV prediction, or
-- "ok(var)" when the actual falls somewhere in the enumerated set.
--
-- Usage: lua batch_verify.lua [captures_dir]
-- Default captures_dir: ./best_hand_captures

local H = dofile('harness.lua')
H.enable_oracle()  -- pulls in real G.FUNCS.get_poker_hand_info
H.load_besthand()

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
  local fx, lerr = H.load_fixture(path)
  if not fx or type(fx) ~= 'table' then
    print(string.format('!! %s: failed to load (%s)',
      basename(path), tostring(lerr or fx)))
    miss = miss + 1
  else
    local ok2, ev_score, possible, n_prob, n_range =
      pcall(H.mod_score, fx)
    if not ok2 then
      print(string.format('!! %s: score error (%s)',
        basename(path), tostring(ev_score)))
      miss = miss + 1
    else
      local actual = fx.actual_score
      local hit_exact = (actual == ev_score)
        or (actual ~= 0
          and math.abs(actual - ev_score) / math.abs(actual) < 1e-9)
      local hit_any = false
      if not hit_exact and (n_prob + n_range) > 0 then
        for _, s in ipairs(possible) do
          if s == actual then hit_any = true; break end
        end
      end
      if hit_exact then
        strict = strict + 1
        print(string.format('  ok      %-45s %-16s  ev=%-10s actual=%s',
          basename(path), fx.hand_name,
          tostring(ev_score), tostring(actual)))
      elseif hit_any then
        via_variance = via_variance + 1
        print(string.format(
          '  ok(var) %-45s %-16s  ev=%-10s actual=%-10s (1 of %d, n_prob=%d n_range=%d)',
          basename(path), fx.hand_name,
          tostring(ev_score), tostring(actual),
          #possible, n_prob, n_range))
      else
        miss = miss + 1
        misses[#misses+1] = {
          file = basename(path), hand = fx.hand_name,
          ev = ev_score, actual = actual, possible = possible,
        }
        print(string.format(
          '  MISS    %-45s %-16s  ev=%-10s actual=%-10s n_prob=%d n_range=%d',
          basename(path), fx.hand_name,
          tostring(ev_score), tostring(actual), n_prob, n_range))
      end
    end
  end
end

print()
print(string.format(
  'Total: %d   strict match: %d   match via variance: %d   miss: %d',
  #files, strict, via_variance, miss))

if #misses > 0 then
  print()
  print('=== Misses ===')
  for _, m in ipairs(misses) do
    print(string.format('  %s (%s): ev=%s actual=%s',
      m.file, m.hand, tostring(m.ev), tostring(m.actual)))
  end
end
