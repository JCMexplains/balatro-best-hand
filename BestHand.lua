-------------------------------------------------------------------------
-- BestHand.lua — Balatro mod that analyzes your hand and recommends
-- the highest-scoring play.
--
-- Keybinds:
--   F2  Evaluate the current hand: print the top 2 scoring plays,
--       card combos, estimated points, and (when order matters) the
--       optimal left-to-right card arrangement to drag into before
--       playing.
--   F4  Toggle fixture capture on/off. Default: ON in dev installs
--       (when .git/ is readable), OFF in released zips. See bottom of
--       this file for the regression harness.
--   F5  Toggle debug timing: log wall-clock for the F2 search and
--       the per-play prediction/enumeration to the game console.
--       Dev-only — registered only in dev installs (.git/ readable).
--
-- Scoring follows Balatro's evaluation order:
--   Phase 1: Each scoring card fires L→R (with retriggers):
--            base chips → enhancement → edition → per-card jokers
--   Phase 2: Held-in-hand effects (Steel Card, Baron, Shoot the Moon)
--            fire per held card, with Mime/Red Seal retriggers
--   Phase 3: Flat joker effects fire L→R (with Blueprint/Brainstorm)
-------------------------------------------------------------------------

-------------------------------------------------------------------------
-- Version tracking: read git commit hash at load time so captures
-- record which code version generated them. Falls back to "unknown"
-- if the .git directory isn't readable (e.g. installed from a zip).
-------------------------------------------------------------------------
local MOD_VERSION = 'unknown'
do
  -- Try to read the git HEAD ref from the mod directory.
  -- SMODS.current_mod.path gives us the mod's root directory.
  local mod_path = (SMODS.current_mod and SMODS.current_mod.path) or ''
  local head_f = io.open(mod_path .. '.git/HEAD', 'r')
  if head_f then
    local head = head_f:read('*l')
    head_f:close()
    if head then
      local ref = head:match('^ref: (.+)')
      if ref then
        local ref_f = io.open(mod_path .. '.git/' .. ref, 'r')
        if ref_f then
          MOD_VERSION = (ref_f:read('*l') or 'unknown'):sub(1, 7)
          ref_f:close()
        end
      else
        -- Detached HEAD: raw hash
        MOD_VERSION = head:sub(1, 7)
      end
    end
  end
end

-------------------------------------------------------------------------
-- Debug timing. When true, F2 and the per-play prediction hook log
-- wall-clock breakdowns to the game console so you can tell whether
-- lag is coming from F2's combinatorial search or from the per-play
-- probabilistic enumeration. Toggled at runtime by the F5 keybind,
-- which is registered only in dev installs (see bottom of file).
-- Declared up here so every handler below — including F2 — captures
-- it as an upvalue.
-------------------------------------------------------------------------
local debug_timing = false
local function now_ms()
  return (love and love.timer and love.timer.getTime() or os.clock()) * 1000
end

-------------------------------------------------------------------------
-- Respect face-down cards. When true (default), cards with
-- `facing == 'back'` are excluded from analyze_hand's combo enumeration
-- and from apply_held_effects, so the predictor doesn't peek at cards
-- the player can't see (The Wheel, The House, The Mark, The Fish).
-- Toggled at runtime by the F6 keybind, which is registered only in
-- dev installs (see bottom of file) — end users always run with this
-- on. The flag only gates analysis; per-play capture/scoring still
-- runs on the real hand because by the time evaluate_play fires,
-- every selected card is face-up anyway.
-------------------------------------------------------------------------
local respect_face_down = true
local function is_face_down(card)
  return card and card.facing == 'back'
end

-------------------------------------------------------------------------
-- Utility: generate all k-element subsets of a list
-------------------------------------------------------------------------
local function combinations(list, k)
  local result = {}
  local function helper(start, combo)
    if #combo == k then
      result[#result + 1] = {unpack(combo)}
      return
    end
    for i = start, #list - (k - #combo) + 1 do
      combo[#combo + 1] = list[i]
      helper(i + 1, combo)
      combo[#combo] = nil
    end
  end
  helper(1, {})
  return result
end

-------------------------------------------------------------------------
-- Utility: generate all permutations of a list (Heap's algorithm).
-- For scoring-card sets of size N ≤ 5 this produces at most 120 entries,
-- which is trivially fast even called dozens of times per F2 press.
-------------------------------------------------------------------------
local function permutations(t)
  local n = #t
  if n <= 1 then return {{unpack(t)}} end
  local result = {}
  local arr = {unpack(t)}
  local c   = {}
  for i = 1, n do c[i] = 1 end
  result[#result + 1] = {unpack(arr)}
  local i = 2
  while i <= n do
    if c[i] < i then
      if i % 2 == 1 then
        arr[1], arr[i] = arr[i], arr[1]
      else
        arr[c[i]], arr[i] = arr[i], arr[c[i]]
      end
      result[#result + 1] = {unpack(arr)}
      c[i] = c[i] + 1
      i = 2
    else
      c[i] = 1
      i = i + 1
    end
  end
  return result
end

-------------------------------------------------------------------------
-- Hand-type containment tables
-- A Full House "contains" both a Pair and Three of a Kind, etc.
-- Used by conditional jokers like Jolly Joker ("if hand contains a Pair").
-------------------------------------------------------------------------
local contains_pair = {
  ['Pair'] = true, ['Two Pair'] = true, ['Three of a Kind'] = true,
  ['Full House'] = true, ['Four of a Kind'] = true, ['Five of a Kind'] = true,
  ['Flush House'] = true, ['Flush Five'] = true,
}
local contains_three = {
  ['Three of a Kind'] = true, ['Full House'] = true,
  ['Four of a Kind'] = true, ['Five of a Kind'] = true,
  ['Flush House'] = true, ['Flush Five'] = true,
}
local contains_four = {
  ['Four of a Kind'] = true, ['Five of a Kind'] = true, ['Flush Five'] = true,
}
local contains_straight = {
  ['Straight'] = true, ['Straight Flush'] = true, ['Royal Flush'] = true,
}
local contains_flush = {
  ['Flush'] = true, ['Straight Flush'] = true, ['Royal Flush'] = true,
  ['Flush House'] = true, ['Flush Five'] = true,
}
local contains_two_pair = {
  ['Two Pair'] = true, ['Full House'] = true, ['Flush House'] = true,
}

-------------------------------------------------------------------------
-- Actual rank-group containment from played cards. Balatro's hand-type
-- conditional jokers (Jolly, The Duo, etc.) check the CARDS for sub-hand
-- presence, not just the primary hand type name. A Flush with Ks, Ks
-- contains a Pair even though "Flush" isn't in the contains_pair table.
-- For flush/straight containment the primary hand type is reliable (a
-- lower-priority hand can never contain a higher-priority pattern), so
-- only rank-based containment needs card-level analysis.
-------------------------------------------------------------------------
local function check_hand_contains(contains_table, hand_name, cards)
  -- For flush and straight, the primary hand type is sufficient
  if contains_table == contains_flush or contains_table == contains_straight then
    return contains_table[hand_name] or false
  end
  -- For rank-based containment, analyze actual card composition
  local groups = {}
  for _, c in ipairs(cards) do
    if not (c.ability and c.ability.name == 'Stone Card') then
      local id = c.base.id
      groups[id] = (groups[id] or 0) + 1
    end
  end
  local counts = {}
  for _, n in pairs(groups) do counts[#counts + 1] = n end
  table.sort(counts, function(a, b) return a > b end)
  local c1, c2 = counts[1] or 0, counts[2] or 0
  if contains_table == contains_pair     then return c1 >= 2 end
  if contains_table == contains_three    then return c1 >= 3 end
  if contains_table == contains_four     then return c1 >= 4 end
  if contains_table == contains_two_pair then return c1 >= 2 and c2 >= 2 end
  -- Fallback: use the name-based table
  return contains_table[hand_name] or false
end

-------------------------------------------------------------------------
-- Snapshot / restore a joker's ability table. Used to guarantee that
-- calling calculate_joker during read-only analysis never corrupts
-- game state — even if a joker mutates self.ability.* as a side
-- effect of its calculate function, we roll it back immediately.
-- Handles one level of nesting (ability.extra is a sub-table).
-------------------------------------------------------------------------
local function snapshot_ability(ability)
  if not ability then return nil end
  local copy = {}
  for k, v in pairs(ability) do
    if type(v) == 'table' then
      copy[k] = {}
      for k2, v2 in pairs(v) do copy[k][k2] = v2 end
    else
      copy[k] = v
    end
  end
  return copy
end

-------------------------------------------------------------------------
-- Hybrid scoring deny list for joker_main: jokers whose real
-- calculate_joker has side effects our snapshot_ability can't roll
-- back. Analysis runs every F2 press (~218 combos per hand), so even
-- a single leaked side effect compounds fast.
--
-- Misprint:      pseudorandom('misprint') advances the RNG seed; we
--                enumerate its [min, max] range via state.range_config.
-- Vagabond:      creates a Tarot card (G.consumeables / consumeable_buffer).
-- Superposition: creates a Tarot card.
-- Seance:        creates a Spectral card.
-- Matador:       calls ease_dollars (mutates G.GAME.dollars + dollar_buffer).
-------------------------------------------------------------------------
local joker_main_deny = {
  ['Misprint']      = true,
  ['Vagabond']      = true,
  ['Superposition'] = true,
  ['Seance']        = true,
  ['Matador']       = true,
}

-------------------------------------------------------------------------
-- context.before deny list: jokers whose before-context has side
-- effects we can't cleanly roll back during read-only analysis.
-- These keep their stale ability.* values; the fallback reads them.
--
-- Space Joker: pseudorandom roll for hand level-up.
-- Midas Mask:  converts face cards in scoring_hand to Gold Cards.
-- Vampire:     strips enhancements from scoring_hand cards.
-- To Do List:  calls ease_dollars (mutates G.GAME.dollars).
-- DNA:         copies a played card into G.playing_cards + G.deck.
-------------------------------------------------------------------------
local before_deny = {
  ['Space Joker'] = true,
  ['Midas Mask']  = true,
  ['Vampire']     = true,
  ['To Do List']  = true,
  ['DNA']         = true,
}

-------------------------------------------------------------------------
-- Jokers whose real calculate_joker has a context.before branch in
-- card.lua (3411-3569). analyze_hand skips run_before_pass entirely
-- when no present joker is in this set — saves N snapshots + N pcalls
-- per combo (~218 combos/F2).
-------------------------------------------------------------------------
local has_before_branch = {
  ['Spare Trousers'] = true, ['Space Joker']  = true,
  ['Square Joker']   = true, ['Runner']       = true,
  ['Midas Mask']     = true, ['Vampire']      = true,
  ['To Do List']     = true, ['DNA']          = true,
  ['Ride the Bus']   = true, ['Obelisk']      = true,
  ['Green Joker']    = true,
}

-------------------------------------------------------------------------
-- Jokers whose real calculate_joker has a context.individual branch
-- in cardarea=G.play (card.lua 3065-3270). Plus ability.effect=='Suit
-- Mult' (Greedy/Lusty/Wrathful/Gluttonous, which dispatch generically
-- on the suit in their ability.extra). eval_per_card_jokers skips the
-- real dispatch loop when no present joker is in this set.
-------------------------------------------------------------------------
local has_individual_branch = {
  ['Hiker']          = true, ['Lucky Cat']    = true,
  ['Wee Joker']      = true, ['Photograph']   = true,
  ['8 Ball']         = true, ['The Idol']     = true,
  ['Scary Face']     = true, ['Smiley Face']  = true,
  ['Golden Ticket']  = true, ['Scholar']      = true,
  ['Walkie Talkie']  = true, ['Business Card'] = true,
  ['Fibonacci']      = true, ['Even Steven']  = true,
  ['Odd Todd']       = true, ['Rough Gem']    = true,
  ['Onyx Agate']     = true, ['Arrowhead']    = true,
  ['Bloodstone']     = true, ['Ancient Joker'] = true,
  ['Triboulet']      = true,
  -- Suit Mult jokers dispatch via ability.effect, not name:
  ['Greedy Joker']   = true, ['Lusty Joker']    = true,
  ['Wrathful Joker'] = true, ['Gluttonous Joker'] = true,
}

-------------------------------------------------------------------------
-- context.individual deny list: jokers whose per-card dispatch either
-- calls pseudorandom (breaking EV estimation) or mutates state we
-- can't cleanly roll back (G.GAME.dollar_buffer, other_card ability).
-- These fall through to hardcoded branches in eval_per_card_jokers.
--
-- Bloodstone / Business Card / 8 Ball: pseudorandom; Bloodstone still
--   computes EV in the fallback, the other two are ignored.
-- Golden Ticket / Rough Gem: mutate G.GAME.dollar_buffer.
-- Hiker:     mutates other_card.ability.perma_bonus on each trigger;
--            Phase 1's hiker_accum already handles the chip delta.
-- Lucky Cat: fires only when other_card.lucky_trigger is set, which
--            requires firing the real Lucky Card enhancement path.
-- Wee Joker: self-mutation; handled via a Phase-3 correction.
-------------------------------------------------------------------------
local per_card_deny = {
  ['Bloodstone']    = true,
  ['Business Card'] = true,
  ['8 Ball']        = true,
  ['Golden Ticket'] = true,
  ['Rough Gem']     = true,
  ['Hiker']         = true,
  ['Lucky Cat']     = true,
  ['Wee Joker']     = true,
}

-------------------------------------------------------------------------
-- Jokers that NEVER return anything from context.joker_main:
-- passive (Pareidolia, Splash, Showman, Smeared, Four Fingers,
-- Shortcut), retrigger-only (Hack, Sock and Buskin, Hanging Chad,
-- Dusk, Seltzer, Mime), per-card individual-only (Photograph,
-- Triboulet, Idol, Ancient, Scary/Smiley Face, Walkie Talkie,
-- Fibonacci, Even Steven, Odd Todd, Scholar, Onyx Agate, Arrowhead,
-- Greedy/Lusty/Wrathful/Gluttonous, Hiker, Rough Gem,
-- Bloodstone, 8 Ball, Golden Ticket, Business Card), held-only
-- (Baron, Shoot the Moon, Reserved Parking, Raised Fist), and
-- before/discard-only (DNA, Vampire, Midas Mask, Space Joker,
-- To Do List, Burnt Joker).
--
-- Used in Phase 3 to skip pcall(calculate_joker, joker_main) entirely.
-- The Phase 3 inner loop checks this against the *resolved* joker name
-- so Blueprint copying e.g. Baron also gets skipped. Critical because
-- the lovely-patched joker_main has a catch-all `if x_mult > 1 then
-- return Xmult_mod` (and similar for t_mult/t_chips) — these jokers
-- have all of those at their default values, so the branch never
-- fires, but pcalling them still walks the entire if-elseif chain.
-- Skipping ~6 of 7 pcalls per combo on common loadouts × 218 combos
-- per F2 saves ~1,300 wasted pcalls.
--
-- NOTE: Lucky Cat is intentionally NOT in this set. Its `ability.x_mult`
-- starts at 1 but grows by extra=0.25 each time a Lucky card triggers,
-- and the catch-all `x_mult > 1` branch in joker_main returns the
-- accumulated value. Excluding it dropped a flat ×x_mult from every
-- prediction once Lucky Cat had triggered at least once.
-------------------------------------------------------------------------
local joker_main_no_fire = {
  -- Passive
  ['Pareidolia'] = true, ['Splash']         = true,
  ['Showman']    = true, ['Smeared Joker']  = true,
  ['Four Fingers'] = true, ['Shortcut']     = true,
  -- Retrigger-only
  ['Hack']       = true, ['Sock and Buskin'] = true,
  ['Hanging Chad'] = true, ['Dusk']         = true,
  ['Seltzer']    = true, ['Mime']           = true,
  -- Per-card (G.play individual)
  ['Photograph'] = true, ['Triboulet']      = true,
  ['The Idol']   = true, ['Ancient Joker']  = true,
  ['Scary Face'] = true, ['Smiley Face']    = true,
  ['Walkie Talkie'] = true, ['Fibonacci']   = true,
  ['Even Steven'] = true, ['Odd Todd']      = true,
  ['Scholar']    = true, ['Onyx Agate']     = true,
  ['Arrowhead']  = true, ['Greedy Joker']   = true,
  ['Lusty Joker'] = true, ['Wrathful Joker'] = true,
  ['Gluttonous Joker'] = true,
  ['Hiker']      = true,
  ['Rough Gem']  = true, ['Bloodstone']     = true,
  ['8 Ball']     = true, ['Golden Ticket']  = true,
  ['Business Card'] = true,
  -- Held individual
  ['Baron']        = true, ['Shoot the Moon']   = true,
  ['Reserved Parking'] = true, ['Raised Fist']  = true,
  -- Before / discard / first-hand only
  ['DNA']        = true, ['Vampire']        = true,
  ['Midas Mask'] = true, ['Space Joker']    = true,
  ['To Do List'] = true, ['Burnt Joker']    = true,
}

-------------------------------------------------------------------------
-- Paired suits for Smeared Joker: Hearts<->Diamonds, Spades<->Clubs.
-- Defined early because suit_matches, count_suits, and get_flush_members
-- all need it.
-------------------------------------------------------------------------
local smeared_pair = {
  Hearts = 'Diamonds', Diamonds = 'Hearts',
  Spades = 'Clubs',    Clubs = 'Spades',
}

-- Per-F2 cache for has_smeared_joker. suit_matches calls it inside
-- count_suits and get_flush_members — both of which are called O(combos)
-- times during analyze_hand. Without this, every combo re-scans
-- G.jokers.cards 4× per scoring card. Cleared by with_no_resolve at the
-- top and bottom of each F2 / per-play prediction so it never holds
-- stale data across game state changes.
local _smeared_cache = nil
local function clear_smeared_cache() _smeared_cache = nil end
local function has_smeared_joker()
  if _smeared_cache ~= nil then return _smeared_cache end
  if not G.jokers or not G.jokers.cards then
    _smeared_cache = false
    return false
  end
  for _, joker in ipairs(G.jokers.cards) do
    if not joker.debuff and joker.ability
      and joker.ability.name == 'Smeared Joker' then
      _smeared_cache = true
      return true
    end
  end
  _smeared_cache = false
  return false
end

-------------------------------------------------------------------------
-- suit_matches: does this card count as `target_suit`?
-- Wild Cards match every suit. Smeared Joker merges Hearts+Diamonds
-- and Spades+Clubs into virtual suits, so a Diamond card counts as
-- Hearts (and vice versa), and a Club card counts as Spades.
-------------------------------------------------------------------------
local function suit_matches(card, target_suit)
  -- Stone Cards have no suit — vanilla Card:is_suit returns false for
  -- them in both flush and non-flush branches. Without this check
  -- get_flush_members would treat a Stone Card's underlying base.suit
  -- as a flush member, picking the wrong suit and scoring set.
  if card.ability and card.ability.effect == 'Stone Card' then return false end
  if card.ability and card.ability.name == 'Wild Card' then return true end
  if card.base.suit == target_suit then return true end
  if has_smeared_joker() then
    local partner = smeared_pair[target_suit]
    if partner and card.base.suit == partner then return true end
  end
  return false
end

-------------------------------------------------------------------------
-- Count how many scoring cards match each suit (aggregate).
-- Wild Cards add +1 to every suit.
-- Used by flat jokers like Flower Pot that check aggregate suit presence.
-------------------------------------------------------------------------
local function count_suits(cards)
  local counts = { Hearts = 0, Diamonds = 0, Clubs = 0, Spades = 0 }
  for _, card in ipairs(cards) do
    if not card.debuff then
      -- suit_matches handles Wild Card (all suits) and Smeared
      -- Joker (H+D, S+C merge), so iterate all four suits.
      for s in pairs(counts) do
        if suit_matches(card, s) then
          counts[s] = counts[s] + 1
        end
      end
    end
  end
  return counts
end

-------------------------------------------------------------------------
-- Identify which cards participate in a flush pattern. Returns the
-- matching subset. Two wrinkles:
--   * Four Fingers: only 4 cards need to share a suit, so a 5-card
--     combo may contain a non-matching kicker.
--   * Smeared Joker: Hearts+Diamonds and Spades+Clubs each collapse
--     into a single virtual suit, so mixed-but-paired combos still
--     count all their cards as flush members.
-------------------------------------------------------------------------
local function get_flush_members(cards)
  -- suit_matches already handles Smeared Joker (H+D and S+C merge)
  -- and Wild Card (matches every suit), so we just call it directly.
  -- Iteration order and first-qualifying-wins tiebreak must match
  -- vanilla get_flush (misc_functions.lua:get_flush) — with Four
  -- Fingers + multiple Wilds, two suits can each hit count >= 4 and
  -- pick different scoring sets. Mismatching the order chooses the
  -- wrong members and chips.
  local suits = {'Spades', 'Hearts', 'Clubs', 'Diamonds'}
  local has_four_fingers = false
  for _, j in ipairs(G.jokers and G.jokers.cards or {}) do
    if not j.debuff and j.ability and j.ability.name == 'Four Fingers' then
      has_four_fingers = true; break
    end
  end
  local flush_min = has_four_fingers and 4 or 5
  for _, suit in ipairs(suits) do
    local matched = {}
    for _, card in ipairs(cards) do
      if suit_matches(card, suit) then matched[#matched + 1] = card end
    end
    if #matched >= flush_min then return matched end
  end
  -- No qualifying flush — caller is responsible for not asking, but
  -- return the most-populous suit's members as a safe fallback.
  local best_suit, best_count = nil, 0
  for _, suit in ipairs(suits) do
    local count = 0
    for _, card in ipairs(cards) do
      if suit_matches(card, suit) then count = count + 1 end
    end
    if count > best_count then best_suit, best_count = suit, count end
  end
  if best_count >= #cards then return cards end
  local result = {}
  for _, card in ipairs(cards) do
    if suit_matches(card, best_suit) then result[#result + 1] = card end
  end
  return result
end

-------------------------------------------------------------------------
-- Identify which cards participate in a straight pattern.
-- Uses Balatro's hand detection so ace wrapping and Shortcut are handled.
-- Tries removing one card at a time; if the remainder is still a straight
-- the removed card is the kicker.
-------------------------------------------------------------------------
local function get_straight_members(cards)
  if #cards <= 1 then return cards end
  -- get_straight (balatro_src/functions/misc_functions.lua:548) returns
  -- just the cards that participate in the straight pattern, honouring
  -- Four Fingers (4-card straight) and Shortcut (gap) jokers. Its
  -- output matches evaluate_poker_hand's scoring_hand for Straight
  -- exactly. If get_straight isn't loaded (standalone analyzer mode),
  -- fall back to the subset-detection below.
  -- SMODS replaces vanilla `get_straight(hand)` with a 4-arg version
  -- `get_straight(hand, min_length, skip, wrap)` whose min_length defaults
  -- to 5 — passing only `cards` would miss every Four Fingers straight
  -- and fall through to the get_poker_hand_info branch below, which
  -- returns ALL `cards` (including the gap kicker) for a Four Fingers
  -- 4-of-5 straight. Match the call shape SMODS uses internally so the
  -- min_length / Shortcut / wrap-around args are honoured live.
  -- The offline harness loads vanilla `get_straight(hand)`, which simply
  -- ignores the trailing args, so this works in both contexts.
  if get_straight then
    local s = get_straight(cards,
      SMODS.four_fingers and SMODS.four_fingers('straight'),
      SMODS.shortcut and SMODS.shortcut(),
      SMODS.wrap_around_straight and SMODS.wrap_around_straight())
    if s and s[1] then return s[1] end
  end
  local full_name = G.FUNCS.get_poker_hand_info(cards)
  if full_name and contains_straight[full_name] then return cards end
  for i = 1, #cards do
    local subset = {}
    for j, c in ipairs(cards) do
      if j ~= i then subset[#subset + 1] = c end
    end
    local name = G.FUNCS.get_poker_hand_info(subset)
    if name and contains_straight[name] then
      return subset
    end
  end
  return cards
end

-------------------------------------------------------------------------
-- get_triggers: total number of times a card fires (always ≥ 1).
-- Retrigger sources stack ADDITIVELY in Balatro: each source adds
-- extra repetitions. Red Seal +1, Hanging Chad +2 on the first card,
-- Hack / Sock and Buskin / Dusk / Seltzer +1 each.
-- e.g. Red Seal + Hack on a 3 → 1 base + 1 + 1 = 3 total triggers.
-- `card_index` is the 1-based position in the scoring card list.
-- `is_held` selects held-in-hand retrigger sources (Mime, Red Seal).
-- `resolved` is the Blueprint/Brainstorm-resolved joker list from
-- resolve_jokers(). When provided, retrigger detection uses resolved
-- names so Blueprint copies of retrigger jokers are counted.
-------------------------------------------------------------------------
local function get_triggers(card, card_index, is_held, pareidolia, resolved)
  local triggers = 1 -- base: every card fires at least once

  -- Red Seal: +1 retrigger (works on both played and held cards)
  if card.seal == 'Red' then
    triggers = triggers + 1
  end

  -- Use the resolved joker list if available (handles Blueprint/Brainstorm
  -- copies of retrigger jokers). Fall back to raw G.jokers.cards for
  -- backward compatibility with standalone trace tools.
  local joker_names = nil
  if resolved then
    joker_names = {}
    for _, j in ipairs(resolved) do
      joker_names[#joker_names + 1] = j.name
    end
  else
    if not G.jokers or not G.jokers.cards then return triggers end
    joker_names = {}
    for _, joker in ipairs(G.jokers.cards) do
      if not joker.debuff then
        joker_names[#joker_names + 1] =
          (joker.ability and joker.ability.name) or ''
      end
    end
  end

  -- Stone Cards override Card:get_id to return a random negative
  -- value, so Hack's 2-5 check and Sock and Buskin's face-card check
  -- never see them as a target. Skip rank-based retriggers here.
  local is_stone = card.ability and card.ability.name == 'Stone Card'

  if not is_held then
    -- Retrigger jokers for played/scoring cards
    for _, name in ipairs(joker_names) do
      if name == 'Hack' then
        -- +1 retrigger for cards ranked 2, 3, 4, or 5
        local id = card.base.id
        if not is_stone and id >= 2 and id <= 5 then triggers = triggers + 1 end
      elseif name == 'Sock and Buskin' then
        -- +1 retrigger for face cards (J=11, Q=12, K=13).
        -- Pareidolia makes every card count as face, including Stones
        -- (Card:is_face short-circuits on Pareidolia before any id
        -- check). Without Pareidolia, Stones never qualify — their
        -- get_id returns a negative random.
        local is_face = pareidolia
          or (not is_stone and card.base.id >= 11 and card.base.id <= 13)
        if is_face then triggers = triggers + 1 end
      elseif name == 'Hanging Chad' then
        -- +2 retriggers on the first scoring card
        if card_index == 1 then triggers = triggers + 2 end
      elseif name == 'Dusk' then
        -- +1 retrigger on the final hand of the round.
        -- The game decrements hands_left before scoring, so
        -- "last hand" is hands_left == 0 at evaluation time.
        local hands_left = (G.GAME.current_round
          and G.GAME.current_round.hands_left) or 0
        if hands_left == 0 then triggers = triggers + 1 end
      elseif name == 'Seltzer' then
        -- +1 retrigger for all scored cards
        triggers = triggers + 1
      end
    end
  else
    -- Retrigger jokers for held-in-hand cards
    for _, name in ipairs(joker_names) do
      if name == 'Mime' then
        triggers = triggers + 1
      end
    end
  end

  return triggers
end

-------------------------------------------------------------------------
-- Default per-level chip/mult increments for each hand type.
-- Used as a fallback when G.GAME.hands[name].l_chips / .l_mult
-- aren't available (e.g. old captures that predate the field).
-------------------------------------------------------------------------
local default_level_increments = {
  ['High Card']       = { l_chips = 10, l_mult = 1 },
  ['Pair']            = { l_chips = 15, l_mult = 1 },
  ['Two Pair']        = { l_chips = 20, l_mult = 1 },
  ['Three of a Kind'] = { l_chips = 20, l_mult = 2 },
  ['Straight']        = { l_chips = 30, l_mult = 3 },
  ['Flush']           = { l_chips = 15, l_mult = 2 },
  ['Full House']      = { l_chips = 25, l_mult = 2 },
  ['Four of a Kind']  = { l_chips = 30, l_mult = 3 },
  ['Straight Flush']  = { l_chips = 40, l_mult = 4 },
  ['Royal Flush']     = { l_chips = 40, l_mult = 4 },
  ['Five of a Kind']  = { l_chips = 35, l_mult = 3 },
  ['Flush House']     = { l_chips = 40, l_mult = 4 },
  ['Flush Five']      = { l_chips = 40, l_mult = 4 },
}

-------------------------------------------------------------------------
-- Fast custom evaluator that replaces G.FUNCS.get_poker_hand_info on
-- the score_combo hot path. The vanilla path was 39% of total F2 cost
-- because evaluate_poker_hand allocates 12 sub-result tables and runs
-- four separate O(n²) get_X_same passes (for 5/4/3/2 of a kind), plus
-- get_flush, get_straight, and get_highest, each of which allocates
-- more tables and walks the hand again.
--
-- Our evaluator does it all in a single O(n) pass over the cards and
-- a fixed-size O(14) walk for straight detection. The returned
-- poker_hands table is "lite": each value is one of two shared tables
-- (POKER_HANDS_CONTAINS / POKER_HANDS_EMPTY) — no per-call nested
-- allocations. Every joker that consults context.poker_hands does so
-- via `next(context.poker_hands[type])`, which is satisfied by the
-- shared tables (CONTAINS = {true} so next() returns truthy; EMPTY = {}
-- so next() returns nil). Verified via grep over the lovely-patched
-- card.lua: nothing reads the actual cards out of poker_hands[type].
--
-- Stone Cards: get_id returns a random negative, so they never pair
-- and never participate in straight detection. SMODS.has_no_suit
-- returns true, so they don't count toward flushes. We skip them in
-- both rank-grouping and suit-counting.
--
-- Wild Cards: have a normal base.id (so they can pair on rank), and
-- SMODS.has_any_suit returns true (so they count toward every suit).
-- We track them separately and add to all four suit counts.
--
-- Smeared Joker pairs Hearts↔Diamonds and Spades↔Clubs into virtual
-- suits — a Diamond card counts as Hearts too. When `has_smeared` is
-- true, each card's actual suit also adds to its smeared partner.
-------------------------------------------------------------------------
local POKER_HANDS_CONTAINS = {true}  -- next() returns key 1 → truthy
local POKER_HANDS_EMPTY    = {}      -- next() returns nil      → falsy

local function fast_evaluate_poker_hand(cards, has_smeared, four_fingers, has_shortcut)
  local n = #cards
  if n == 0 then
    -- Edge case: empty input. Return High Card as the safest fallback
    -- so callers that read hand_name don't get nil.
    return 'High Card', {
      ['High Card']       = POKER_HANDS_EMPTY,
      ['Pair']            = POKER_HANDS_EMPTY,
      ['Two Pair']        = POKER_HANDS_EMPTY,
      ['Three of a Kind'] = POKER_HANDS_EMPTY,
      ['Straight']        = POKER_HANDS_EMPTY,
      ['Flush']           = POKER_HANDS_EMPTY,
      ['Full House']      = POKER_HANDS_EMPTY,
      ['Four of a Kind']  = POKER_HANDS_EMPTY,
      ['Straight Flush']  = POKER_HANDS_EMPTY,
      ['Five of a Kind']  = POKER_HANDS_EMPTY,
      ['Flush House']     = POKER_HANDS_EMPTY,
      ['Flush Five']      = POKER_HANDS_EMPTY,
      ['Royal Flush']     = POKER_HANDS_EMPTY,
    }
  end

  -- Single pass: rank counts (Wild Cards keep their nominal rank),
  -- suit counts (Wilds add to all four), Stones excluded.
  local rank_count = {}
  local suit_count_h, suit_count_d = 0, 0
  local suit_count_s, suit_count_c = 0, 0
  local wild_count = 0

  for i = 1, n do
    local card = cards[i]
    local a = card.ability
    local aname = a and a.name
    if aname == 'Stone Card' then
      -- ignore for rank and suit
    else
      local id = card.base.id
      rank_count[id] = (rank_count[id] or 0) + 1
      if aname == 'Wild Card' then
        wild_count = wild_count + 1
      else
        local s = card.base.suit
        if s == 'Hearts' then suit_count_h = suit_count_h + 1
        elseif s == 'Diamonds' then suit_count_d = suit_count_d + 1
        elseif s == 'Spades' then suit_count_s = suit_count_s + 1
        elseif s == 'Clubs' then suit_count_c = suit_count_c + 1 end
      end
    end
  end

  -- Effective per-suit counts including Wilds and Smeared aliasing.
  local eff_h = suit_count_h + wild_count
  local eff_d = suit_count_d + wild_count
  local eff_s = suit_count_s + wild_count
  local eff_c = suit_count_c + wild_count
  if has_smeared then
    eff_h = eff_h + suit_count_d
    eff_d = eff_d + suit_count_h
    eff_s = eff_s + suit_count_c
    eff_c = eff_c + suit_count_s
  end

  -- Best X-of-a-kind. Iterate rank_count once.
  local has5, has4, has3 = false, false, false
  local triple_id = nil
  local pair_distinct = 0  -- distinct ranks with count >= 2
  for id, cnt in pairs(rank_count) do
    if cnt >= 5 then has5 = true end
    if cnt >= 4 then has4 = true end
    if cnt >= 3 then
      has3 = true
      if not triple_id or id > triple_id then triple_id = id end
    end
    if cnt >= 2 then pair_distinct = pair_distinct + 1 end
  end

  -- Full House: triple AND another pair (distinct rank).
  -- pair_distinct counts triples too (since count >= 2), so a triple
  -- alone gives pair_distinct == 1. We need a SECOND pair-or-better.
  local has_full_house = has3 and pair_distinct >= 2

  local has_two_pair = pair_distinct >= 2
  local has_pair     = pair_distinct >= 1

  -- Flush
  local flush_min = four_fingers and 4 or 5
  local has_flush = eff_h >= flush_min or eff_d >= flush_min
                 or eff_s >= flush_min or eff_c >= flush_min

  -- Straight: walk ranks 1..14, allow ace-low (id 14 → also id 1).
  -- Shortcut lets the walk skip an absent rank (the `skipped` flag
  -- resets on the next present rank, so multiple gaps are allowed
  -- as long as no two adjacent ranks are both absent). Mirrors
  -- get_straight in balatro_src/functions/misc_functions.lua:548 —
  -- crucially, only present ranks count toward `run`; a skipped
  -- rank does NOT bump the length, otherwise A,2,_,4,_ would be
  -- mistakenly accepted as a 5-card Shortcut straight.
  local straight_min = four_fingers and 4 or 5
  local has_straight = false
  do
    local present_1  = rank_count[14] and true or false  -- ace-low
    local present_2  = rank_count[2]  and true or false
    local present_3  = rank_count[3]  and true or false
    local present_4  = rank_count[4]  and true or false
    local present_5  = rank_count[5]  and true or false
    local present_6  = rank_count[6]  and true or false
    local present_7  = rank_count[7]  and true or false
    local present_8  = rank_count[8]  and true or false
    local present_9  = rank_count[9]  and true or false
    local present_10 = rank_count[10] and true or false
    local present_11 = rank_count[11] and true or false
    local present_12 = rank_count[12] and true or false
    local present_13 = rank_count[13] and true or false
    local present_14 = rank_count[14] and true or false
    local p = {present_1, present_2, present_3, present_4, present_5,
      present_6, present_7, present_8, present_9, present_10,
      present_11, present_12, present_13, present_14}
    local run = 0
    local skipped = false
    for j = 1, 14 do
      if p[j] then
        run = run + 1
        skipped = false
        if run >= straight_min then has_straight = true; break end
      elseif has_shortcut and not skipped and j ~= 14 then
        skipped = true
      else
        run = 0
        skipped = false
      end
    end
  end

  -- Composite types
  local has_flush_five     = has5 and has_flush
  local has_flush_house    = has_full_house and has_flush
  local has_straight_flush = has_straight and has_flush

  -- Pick the top hand_name in priority order. Mirrors
  -- state_events.lua:541 — note Royal Flush isn't a separate type
  -- in the table; it's a display variant of Straight Flush. Since
  -- score_combo only uses the text key for hand-info lookup, we
  -- always return 'Straight Flush' (G.GAME.hands keys this hand
  -- type as 'Straight Flush' in both cases).
  local hand_name
  if     has_flush_five     then hand_name = 'Flush Five'
  elseif has_flush_house    then hand_name = 'Flush House'
  elseif has5               then hand_name = 'Five of a Kind'
  elseif has_straight_flush then hand_name = 'Straight Flush'
  elseif has4               then hand_name = 'Four of a Kind'
  elseif has_full_house     then hand_name = 'Full House'
  elseif has_flush          then hand_name = 'Flush'
  elseif has_straight       then hand_name = 'Straight'
  elseif has3               then hand_name = 'Three of a Kind'
  elseif has_two_pair       then hand_name = 'Two Pair'
  elseif has_pair           then hand_name = 'Pair'
  else                            hand_name = 'High Card'
  end

  -- Lite poker_hands. Fresh shell table per call (one alloc) but
  -- the values are shared singletons (no nested allocs).
  local ph = {
    ['High Card']       = POKER_HANDS_CONTAINS,
    ['Pair']            = has_pair           and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Two Pair']        = has_two_pair       and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Three of a Kind'] = has3               and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Straight']        = has_straight       and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Flush']           = has_flush          and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Full House']      = has_full_house     and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Four of a Kind']  = has4               and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Straight Flush']  = has_straight_flush and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Five of a Kind']  = has5               and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Flush House']     = has_flush_house    and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Flush Five']      = has_flush_five     and POKER_HANDS_CONTAINS or POKER_HANDS_EMPTY,
    ['Royal Flush']     = POKER_HANDS_EMPTY,
  }
  return hand_name, ph
end

-------------------------------------------------------------------------
-- Check if The Flint boss blind is active (halves base chips and mult).
-------------------------------------------------------------------------
local function is_flint_active()
  return G.GAME and G.GAME.blind and G.GAME.blind.name == 'The Flint'
end

-------------------------------------------------------------------------
-- Boss-blind hand debuffs that zero the entire score:
--   The Eye   — each hand type can only score once per round.
--   The Mouth — only one hand type may score per round.
-- Balatro increments played_this_round at the top of evaluate_play, so
-- analysis runs against the pre-increment snapshot: if any matching
-- hand already has played_this_round > 0, playing it again zeroes out.
-------------------------------------------------------------------------
local function is_hand_debuffed_by_blind(hand_name)
  if not G.GAME or not G.GAME.blind or G.GAME.blind.disabled then
    return false
  end
  local bname = G.GAME.blind.name
  local hands = G.GAME.hands or {}
  if bname == 'The Eye' then
    local h = hands[hand_name]
    return h and (h.played_this_round or 0) > 0
  elseif bname == 'The Mouth' then
    for name, info in pairs(hands) do
      if name ~= hand_name and (info.played_this_round or 0) > 0 then
        return true
      end
    end
  end
  return false
end

-------------------------------------------------------------------------
-- Build a one-line description of any active hand-zeroing blind, so F2
-- can explain why some (or all) suggestions are missing. Returns nil
-- when no such blind is active. Mirrors is_hand_debuffed_by_blind and
-- the Psychic check in score_combo so the messaging stays in sync.
-------------------------------------------------------------------------
local function describe_blind_restriction(n_cards)
  if not G.GAME or not G.GAME.blind or G.GAME.blind.disabled then
    return nil
  end
  local bname = G.GAME.blind.name
  local hands = G.GAME.hands or {}
  if bname == 'The Mouth' then
    local allowed
    for name, info in pairs(hands) do
      if (info.played_this_round or 0) > 0 then
        allowed = name
        break
      end
    end
    if allowed then
      return string.format(
        'The Mouth: only %s scores this round (already played).', allowed)
    end
    return 'The Mouth: only the first hand type you play this round will score.'
  elseif bname == 'The Eye' then
    local played = {}
    for name, info in pairs(hands) do
      if (info.played_this_round or 0) > 0 then
        played[#played + 1] = name
      end
    end
    table.sort(played)
    if #played > 0 then
      return string.format(
        'The Eye: each hand type scores once per round. Already played: %s.',
        table.concat(played, ', '))
    end
    return 'The Eye: each hand type can only score once this round.'
  elseif bname == 'The Psychic' then
    if n_cards and n_cards < 5 then
      return string.format(
        'The Psychic: must play exactly 5 cards to score (only %d in hand).',
        n_cards)
    end
    return 'The Psychic: must play exactly 5 cards to score.'
  end
  return nil
end

-------------------------------------------------------------------------
-- Determine which cards actually score for a given hand type.
-- Kicker cards (e.g. the 5th card in Two Pair) do NOT score,
-- UNLESS they have Stone Card enhancement (Stone Cards always score).
-- When the Splash joker is present, ALL played cards score.
-- Returns cards in their original hand order (left to right).
-------------------------------------------------------------------------
local function get_scoring_cards(cards, hand_name)
  -- Splash joker: every played card scores regardless of hand type,
  -- including the off-suit kicker in a Four-Fingers flush. Must run
  -- before the Flush/Straight branch — that branch returns early and
  -- would otherwise drop the kicker from the scoring set.
  if G.jokers and G.jokers.cards then
    for _, joker in ipairs(G.jokers.cards) do
      if not joker.debuff and joker.ability
        and joker.ability.name == 'Splash' then
        return cards
      end
    end
  end

  -- Hands where every played card always participates
  if hand_name == 'Full House' or hand_name == 'Flush House'
    or hand_name == 'Flush Five' or hand_name == 'Five of a Kind' then
    return cards
  end

  -- Flush / Straight hands: with Four Fingers a combo may contain a
  -- kicker card that doesn't participate in the pattern.
  if hand_name == 'Flush' or hand_name == 'Straight'
    or hand_name == 'Straight Flush' or hand_name == 'Royal Flush' then
    local members
    if hand_name == 'Flush' then
      members = get_flush_members(cards)
    elseif hand_name == 'Straight' then
      members = get_straight_members(cards)
    else
      -- Straight Flush / Royal Flush: scoring_hand is the union of
      -- flush members and straight members. With Four Fingers the
      -- two sets may not overlap entirely (4-card flush + a 5th card
      -- that completes the straight), and Balatro scores both groups.
      -- evaluate_poker_hand builds the same union at line 428-443.
      local f = get_flush_members(cards)
      local s = get_straight_members(cards)
      local seen = {}
      members = {}
      for _, c in ipairs(f) do
        if not seen[c] then seen[c] = true; members[#members + 1] = c end
      end
      for _, c in ipairs(s) do
        if not seen[c] then seen[c] = true; members[#members + 1] = c end
      end
    end
    if #members >= #cards then return cards end
    -- Build scoring set from participating cards + Stone Card kickers
    local scoring_set = {}
    for _, c in ipairs(members) do scoring_set[c] = true end
    for _, c in ipairs(cards) do
      if c.ability and c.ability.name == 'Stone Card' then
        scoring_set[c] = true
      end
    end
    local result = {}
    for _, c in ipairs(cards) do
      if scoring_set[c] then result[#result + 1] = c end
    end
    return result
  end

  -- Group cards by rank id to identify the hand's core groups.
  -- Stone Cards are excluded from poker-hand evaluation in Balatro:
  -- they don't participate in pair / three-of-a-kind / etc. groups.
  -- Including them here would let a Stone Ace pair with a real Ace
  -- and steal the pair selection from a lower real pair. Stones get
  -- added back to scoring_set unconditionally below as kickers.
  local by_rank = {}
  for _, card in ipairs(cards) do
    if not (card.ability and card.ability.name == 'Stone Card') then
      local id = card.base.id
      if not by_rank[id] then by_rank[id] = {} end
      by_rank[id][#by_rank[id] + 1] = card
    end
  end

  -- Sort groups: largest first, highest rank breaks ties
  local groups = {}
  for id, group in pairs(by_rank) do
    groups[#groups + 1] = { id = id, cards = group, count = #group }
  end
  table.sort(groups, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.id > b.id
  end)

  -- Build a set of cards that form the hand's core pattern
  local scoring_set = {}

  if hand_name == 'Four of a Kind' then
    for _, g in ipairs(groups) do
      if g.count >= 4 then
        for i = 1, 4 do scoring_set[g.cards[i]] = true end
        break
      end
    end
  elseif hand_name == 'Three of a Kind' then
    for _, g in ipairs(groups) do
      if g.count >= 3 then
        for i = 1, 3 do scoring_set[g.cards[i]] = true end
        break
      end
    end
  elseif hand_name == 'Two Pair' then
    local pairs_found = 0
    for _, g in ipairs(groups) do
      if g.count >= 2 and pairs_found < 2 then
        scoring_set[g.cards[1]] = true
        scoring_set[g.cards[2]] = true
        pairs_found = pairs_found + 1
      end
    end
  elseif hand_name == 'Pair' then
    for _, g in ipairs(groups) do
      if g.count >= 2 then
        scoring_set[g.cards[1]] = true
        scoring_set[g.cards[2]] = true
        break
      end
    end
  elseif hand_name == 'High Card' then
    -- Only the highest-ranked non-Stone card scores. Stones don't
    -- participate in High Card selection (they'd get added below).
    local best = nil
    for _, card in ipairs(cards) do
      if not (card.ability and card.ability.name == 'Stone Card')
        and (not best or card.base.id > best.base.id) then
        best = card
      end
    end
    if best then scoring_set[best] = true end
  else
    -- Unknown hand type: treat all as scoring
    for _, card in ipairs(cards) do scoring_set[card] = true end
  end

  -- Stone Cards always score, even as kickers — they contribute +50 chips
  for _, card in ipairs(cards) do
    if card.ability and card.ability.name == 'Stone Card' then
      scoring_set[card] = true
    end
  end

  -- Return scoring cards in original hand order (left to right),
  -- which is important for Hanging Chad and Photograph
  local result = {}
  for _, card in ipairs(cards) do
    if scoring_set[card] then result[#result + 1] = card end
  end
  return result
end

-------------------------------------------------------------------------
-- Resolve Blueprint and Brainstorm into their effective joker targets.
-- Returns a list of {ability, name, edition} entries in slot order.
-- Blueprint copies the joker to its right; Brainstorm copies the
-- leftmost joker. Copies chain — Blueprint→Brainstorm→(leftmost)
-- and Brainstorm→Blueprint→(right) both walk through to the underlying
-- real joker. `visited` prevents infinite recursion when two copy
-- jokers reference each other.
-------------------------------------------------------------------------
local function resolve_copy_target(jokers, index, visited)
  if visited[index] then return nil end
  visited[index] = true
  local joker = jokers[index]
  if not joker or joker.debuff or not joker.ability then return nil end
  local name = joker.ability.name or ''
  if name == 'Blueprint' then
    for k = index + 1, #jokers do
      local t = jokers[k]
      if t and not t.debuff and t.ability then
        return resolve_copy_target(jokers, k, visited)
      end
    end
    return nil
  elseif name == 'Brainstorm' then
    if #jokers > 0 then
      return resolve_copy_target(jokers, 1, visited)
    end
    return nil
  else
    return joker.ability
  end
end

local function resolve_jokers()
  if not G.jokers or not G.jokers.cards then return {} end
  local jokers = G.jokers.cards
  local resolved = {}

  for i, joker in ipairs(jokers) do
    if not joker.debuff then
      local ability = joker.ability or {}
      local name = ability.name or ''

      if name == 'Blueprint' or name == 'Brainstorm' then
        -- Copy jokers chain through other copy jokers with cycle
        -- detection. The copy joker's OWN edition still applies.
        local target_ability = resolve_copy_target(jokers, i, {})
        if target_ability then
          resolved[#resolved + 1] = {
            ability = target_ability,
            name = target_ability.name or '',
            edition = joker.edition,
          }
        end

      else
        resolved[#resolved + 1] = {
          ability = ability,
          name = name,
          edition = joker.edition,
        }
      end
    end
  end

  return resolved
end

-------------------------------------------------------------------------
-- Per-F2 invariants derived from the resolved joker list. All five fields
-- were previously re-scanned inside score_combo on every combo (~218
-- times/F2) even though the joker list can't change between combos of a
-- single analyze_hand() call. One single-pass scan replaces five.
--
-- resolve_jokers() itself is also allocating; analyze_hand now builds
-- `resolved` once and reuses it here. Callers without a precomputed
-- bundle (compute_predicted_score → single-shot) fall back to a lazy
-- build inside score_combo so behavior is unchanged for them.
-------------------------------------------------------------------------
local function build_combo_precomputed(resolved)
  local pareidolia = false
  local hiker_count = 0
  local has_baron, baron_count = false, 0
  local has_shoot_moon, shoot_moon_count = false, 0
  local baseball_card_count = 0
  -- Phase gates: skip run_before_pass / per-card real dispatch when
  -- no joker in the (resolved) list has a branch for that context.
  -- Huge win on common joker loadouts (Blueprint + copy jokers +
  -- Steel Joker) where neither phase contributes anything.
  --
  -- run_individual = any individual-branch joker (used inside
  -- eval_per_card_jokers' inner real-dispatch gate).
  -- enter_per_card_loop = caller-side gate: only call
  -- eval_per_card_jokers at all when a non-deny individual joker
  -- exists OR Bloodstone is present (the only deny-listed joker
  -- with a score-affecting fallback). Without this, Hiker-only
  -- loadouts force the loop to run and pcall every other joker
  -- pointlessly — e.g. ~10,900 wasted pcalls per F2 on a 5-card
  -- played × 2 triggers × 6 non-deny jokers × 218 combos hand.
  local run_before, run_individual = false, false
  local has_pure_individual, has_bloodstone_pc = false, false
  -- Hand-evaluator inputs that don't change between combos.
  local has_smeared = false
  local has_four_fingers = false
  local has_shortcut = false
  -- Midas Mask is in before_deny because its context.before mutates
  -- scoring_hand cards' ability via set_ability — unrollable. We
  -- simulate the conversion in score_combo's enhancement read.
  local has_midas_mask = false
  for _, j in ipairs(resolved) do
    local n = j.name
    if n == 'Pareidolia' then
      pareidolia = true
    elseif n == 'Hiker' then
      hiker_count = hiker_count + 1
    elseif n == 'Baron' then
      has_baron = true
      baron_count = baron_count + 1
    elseif n == 'Shoot the Moon' then
      has_shoot_moon = true
      shoot_moon_count = shoot_moon_count + 1
    elseif n == 'Baseball Card' then
      baseball_card_count = baseball_card_count + 1
    elseif n == 'Bloodstone' then
      has_bloodstone_pc = true
    elseif n == 'Smeared Joker' then
      has_smeared = true
    elseif n == 'Four Fingers' then
      has_four_fingers = true
    elseif n == 'Shortcut' then
      has_shortcut = true
    elseif n == 'Midas Mask' then
      has_midas_mask = true
    end
    if has_before_branch[n] then run_before = true end
    if has_individual_branch[n] then
      run_individual = true
      if not per_card_deny[n] then has_pure_individual = true end
    end
  end
  return {
    resolved            = resolved,
    pareidolia          = pareidolia,
    hiker_add           = hiker_count * 5,
    has_baron           = has_baron,
    baron_count         = baron_count,
    has_shoot_moon      = has_shoot_moon,
    shoot_moon_count    = shoot_moon_count,
    baseball_card_count = baseball_card_count,
    run_before          = run_before,
    run_individual      = run_individual,
    enter_per_card_loop = has_pure_individual or has_bloodstone_pc,
    has_smeared         = has_smeared,
    has_four_fingers    = has_four_fingers,
    has_shortcut        = has_shortcut,
    has_midas_mask      = has_midas_mask,
  }
end

-------------------------------------------------------------------------
-- Apply a foil/holo/polychrome edition bonus to (chips, mult).
-- Used for played-card editions in Phase 1, held Steel card editions
-- in Phase 2, and as a convenience for jokers with no Xmult effect.
-- For jokers that include an Xmult effect, use edition_additive before
-- the Xmult and edition_multiplicative after — Balatro composes the
-- joker and edition events as if the edition's additive mult joins
-- the joker's additive before the joker's Xmult, so applying holo
-- AFTER ×mult (as this monolithic helper would) undershoots by
-- (holo bonus) × (Xmult − 1).
-------------------------------------------------------------------------
local function edition_additive(edition, chips, mult)
  if edition then
    if edition.foil then
      chips = chips + 50
    elseif edition.holo then
      mult = mult + 10
    end
  end
  return chips, mult
end

-- Apply an x_mult step the way SMODS does: mult + mult*(x-1) instead of
-- mult*x. Mathematically equivalent for exact reals, but float
-- arithmetic diverges when x has accumulated drift. Concrete case: Ramen
-- subtracts 0.01 from x_mult per discard, so after 20 discards x_mult is
-- 1.7999999999999998 (one ULP below 1.8). 175*1.7999999999999998 floors
-- to 56699 across 180 chips; 175 + 175*0.7999999999999998 lands on 315.0
-- exactly, matching the live game (56700). SMODS's
-- scoring_calculation.toml replaces vanilla scoring entirely, routing
-- every x_mult through Scoring_Parameters.mult:modify(mult*(amount-1))
-- (smods/src/game_object.lua:3881), so we mirror that form everywhere.
local function apply_xmult(mult, x)
  return mult + mult * (x - 1)
end

local function edition_multiplicative(edition, chips, mult)
  if edition and edition.polychrome then
    mult = apply_xmult(mult, 1.5)
  end
  return chips, mult
end

local function apply_edition(edition, chips, mult)
  chips, mult = edition_additive(edition, chips, mult)
  chips, mult = edition_multiplicative(edition, chips, mult)
  return chips, mult
end

-------------------------------------------------------------------------
-- Phase 1 helper: per-card joker effects for a single scoring card.
-- Called once per trigger (base + retriggers), in joker slot order.
--
-- Primary path: real Card:calculate_joker with context.individual and
-- context.other_card = card. Mirrors the loop at state_events.lua:693.
-- Handles deterministic jokers (suit-mult, rank-mult, face-detection,
-- Photograph, Triboulet, Ancient Joker, The Idol, Arrowhead, Onyx
-- Agate, etc.) and Blueprint/Brainstorm delegation natively.
--
-- Fallback: jokers in per_card_deny (probabilistic or side-effectful)
-- use hardcoded logic below. Bloodstone computes EV / consumes the
-- next prob_config slot; the others are ignored because their effect
-- is dollars, not score.
--
-- `state` carries:
--   state.used_ev    — set when a probabilistic effect contributes.
--   state.prob_idx / state.prob_config — see score_combo.
-------------------------------------------------------------------------
local function eval_per_card_jokers(
  card, resolved, chips, mult, state, pareidolia,
  cards, scoring, hand_name, poker_hands, run_individual, ctx_individual
)
  local jokers = G.jokers and G.jokers.cards or {}

  -- The context table is built once by the caller per Phase-1 pass
  -- and we just mutate `other_card` for each scoring card. The
  -- alternative — allocating a fresh table per (card × trigger ×
  -- joker) — was up to 50 allocations per combo × 218 combos.
  if ctx_individual then ctx_individual.other_card = card end

  for idx, joker in ipairs(jokers) do
    if not joker.debuff and joker.ability then
      local name = joker.ability.name or ''
      local effect = nil

      -- Skip the real-dispatch loop entirely when no joker in the
      -- current roster has a context.individual branch — avoids ~N
      -- calculate_joker pcalls per (card × trigger). run_individual
      -- is computed once per F2.
      --
      -- No snapshot here: every vanilla joker reachable in this path
      -- (Photograph, Idol, Triboulet, Ancient, Scary/Smiley Face,
      -- Walkie Talkie, Fibonacci, Even Steven, Odd Todd, Scholar,
      -- Suit Mult, Onyx Agate, Arrowhead, Bloodstone, …) only reads
      -- self.ability and returns an effect table. The mutators in
      -- this context (Lucky Cat, Wee Joker, Hiker, Business Card,
      -- 8 Ball, Golden Ticket, Rough Gem) are deny-listed above and
      -- never enter this branch, so the snapshot was pure overhead.
      -- pcall still guards against any modded joker erroring out.
      if run_individual
        and joker.calculate_joker
        and not per_card_deny[name]
        and not joker_main_deny[name]
        and poker_hands
        and ctx_individual then
        local ok, ret = pcall(joker.calculate_joker, joker, ctx_individual)
        -- Blueprint/Brainstorm mutate context.blueprint and
        -- context.blueprint_card before recursing into their copy
        -- target. Reset both after every call so subsequent jokers
        -- in the loop don't see leftover state from a Blueprint
        -- earlier in the slot order.
        ctx_individual.blueprint      = nil
        ctx_individual.blueprint_card = nil
        if ok and type(ret) == 'table' then effect = ret end
      end

      if effect then
        chips = chips + (effect.chips or 0)
        mult  = mult  + (effect.mult or 0)
        if effect.x_mult then mult = apply_xmult(mult, effect.x_mult) end
      else
        -- Hardcoded fallback: only Bloodstone contributes here. Other
        -- deny-listed jokers (8 Ball, Business Card, Golden Ticket,
        -- Rough Gem, Hiker, Lucky Cat, Wee Joker) either have their
        -- contribution handled elsewhere or don't affect score in EV.
        local target = resolve_copy_target(jokers, idx, {}) or joker.ability
        if target.name == 'Bloodstone' then
          if suit_matches(card, 'Hearts') then
            state.prob_idx = state.prob_idx + 1
            state.prob_arities[state.prob_idx] = 2
            if state.prob_config then
              -- 0 is truthy in Lua, so compare explicitly.
              if state.prob_config[state.prob_idx] == 1 then
                mult = apply_xmult(mult, 1.5)
              end
            else
              mult = apply_xmult(mult, 1.25)
              state.used_ev = true
            end
          end
        end
      end
    end
  end

  return chips, mult
end

-------------------------------------------------------------------------
-- Phase-3 fallback for Misprint. Every other joker runs through real
-- Card:calculate_joker in the hybrid path; Misprint is deny-listed
-- because its real calculate_joker calls pseudorandom() to roll a
-- random mult in [min, max], which we enumerate via state.range_config
-- instead (batch_verify iterates every integer in the range).
--
-- The caller wraps this in edition_additive/multiplicative so we only
-- contribute the joker's own mult_mod here.
-------------------------------------------------------------------------
local function eval_flat_jokers(resolved, chips, mult, ctx, state)
  for _, j in ipairs(resolved) do
    if j.name == 'Misprint' then
      local ability = j.ability
      local lo = (ability.extra and ability.extra.min) or 0
      local hi = (ability.extra and ability.extra.max) or 23
      state.range_idx = state.range_idx + 1
      state.range_events[state.range_idx] = { lo, hi }
      local val = state.range_config
        and state.range_config[state.range_idx]
      if val then
        mult = mult + val
      else
        mult = mult + (lo + hi) / 2
        state.used_ev = true
      end
    end
  end
  return chips, mult
end

-------------------------------------------------------------------------
-- context.before pre-pass. Mirrors the loop Balatro runs at
-- state_events.lua:628 — calls each joker's calculate_joker with
-- before=true so scaling jokers (Green Joker, Spare Trousers, Runner,
-- Square Joker, Ride the Bus, Obelisk, and any other joker whose
-- before-context updates self.ability.*) increment their stored
-- counters BEFORE joker_main reads them. Without this, joker_main sees
-- the pre-hand value and under-predicts by one increment.
--
-- Snapshots each mutated joker's ability so analyze_hand's enumeration
-- doesn't corrupt game state — after each combo we restore.
-------------------------------------------------------------------------
local function run_before_pass(cards, scoring, hand_name, poker_hands)
  local snapshots = {}
  if not G.jokers or not G.jokers.cards or not poker_hands then
    return snapshots
  end
  -- Build the context once and share across all jokers in the loop.
  local ctx = {
    before       = true,
    cardarea     = G.jokers,
    full_hand    = cards,
    scoring_hand = scoring,
    scoring_name = hand_name,
    poker_hands  = poker_hands,
  }
  for _, joker in ipairs(G.jokers.cards) do
    local name = joker.ability and joker.ability.name or ''
    -- Only the jokers in has_before_branch actually do anything in
    -- context.before; firing the rest is wasted snapshot+pcall.
    -- before_deny excludes the ones whose side effects we can't
    -- roll back (DNA, Vampire, Midas Mask, Space Joker, To Do List).
    if not joker.debuff and joker.calculate_joker
      and has_before_branch[name]
      and not before_deny[name]
      and not joker_main_deny[name] then
      snapshots[joker] = snapshot_ability(joker.ability)
      pcall(joker.calculate_joker, joker, ctx)
      -- Blueprint/Brainstorm reset (see eval_per_card_jokers).
      ctx.blueprint      = nil
      ctx.blueprint_card = nil
    end
  end
  return snapshots
end

local function restore_before_pass(snapshots)
  for joker, ability in pairs(snapshots) do
    joker.ability = ability
  end
end

-------------------------------------------------------------------------
-- Score a complete combo of played cards against the full hand.
-- Follows Balatro's three-phase evaluation order (scoring cards,
-- then held-in-hand, then flat jokers).
--
-- prob_config (optional) pins each probabilistic roll to a specific
-- outcome — an array indexed in emit order. Lucky Card emits ternary
-- outcomes (0 = neither path, 1 = mult-roll path, 2 = dollars-only path);
-- Bloodstone emits binary outcomes (0 = miss, 1 = hit). Default: use EV
-- and flip used_ev.
-- range_config (optional) pins each range-valued probabilistic event (e.g.
-- Misprint, which rolls a random integer mult in [min, max]) to a specific
-- integer. Default: use the midpoint. F4 enumerates every integer value to
-- get the exact discrete set of possible scores.
-- Returns: hand_name, score, scoring_cards, used_ev, prob_arities, range_events.
-- prob_arities is an array of per-event outcome counts (2 or 3) and
-- range_events is an array of {lo, hi} bounds — a caller can iterate the
-- cartesian product of both to enumerate all outcomes.
-------------------------------------------------------------------------
local function score_combo(cards, all_cards, prob_config, range_config, precomputed)
  -- Build the precomputed bundle here (rather than after the hand-info
  -- call) so we can pass smeared/four-fingers/shortcut flags into the
  -- fast hand evaluator on the very first call.
  precomputed = precomputed or build_combo_precomputed(resolve_jokers())

  -- Identify the poker hand type via our custom evaluator, which is
  -- ~5× faster than G.FUNCS.get_poker_hand_info because it does a
  -- single O(n) pass over the cards instead of running four
  -- get_X_same passes plus get_flush/straight/highest, each
  -- allocating their own result tables. The returned poker_hands
  -- table is "lite" — values are shared singletons so jokers'
  -- `next(context.poker_hands[type])` checks return the right
  -- truthiness without per-call nested allocations.
  local hand_name, poker_hands = fast_evaluate_poker_hand(
    cards, precomputed.has_smeared,
    precomputed.has_four_fingers, precomputed.has_shortcut)
  if not hand_name then return nil, 0 end

  -- With Four Fingers, Balatro may detect Straight Flush / Royal Flush
  -- when the flush subset and straight subset don't overlap (e.g. 4
  -- suited cards + 1 off-suit card that completes the straight). The
  -- in-game scorer still treats this as a Straight Flush, so we have
  -- to score it faithfully — analyze_hand decides separately whether
  -- to recommend the SF combo over Flush / Straight subsets.

  local hand_info = G.GAME.hands[hand_name]
  if not hand_info then return nil, 0 end

  -- Boss-blind hand debuff (The Eye / The Mouth): entire score is
  -- zeroed before Balatro runs Phase 1, so short-circuit here.
  if is_hand_debuffed_by_blind(hand_name) then
    return hand_name, 0, {}, false, 0, {}
  end

  -- The Psychic boss blind: must play exactly 5 cards or score is 0.
  if G.GAME and G.GAME.blind and G.GAME.blind.name == 'The Psychic'
    and not (G.GAME.blind.disabled)
    and #cards < 5 then
    return hand_name, 0, {}, false, 0, {}
  end

  local chips = hand_info.chips
  local mult = hand_info.mult

  -- The Arm boss blind lowers the played hand's level by 1.
  -- This happens in context.before during evaluate_play, so the
  -- snapshot sees the pre-Arm level. Subtract one level's worth
  -- of chips/mult (stored as l_chips/l_mult on the hand info,
  -- or fall back to the standard Balatro defaults).
  if G.GAME and G.GAME.blind and G.GAME.blind.name == 'The Arm'
    and not (G.GAME.blind.disabled)
    and (hand_info.level or 1) > 1 then
    local defaults = default_level_increments[hand_name] or {}
    local l_chips = hand_info.l_chips or defaults.l_chips or 0
    local l_mult  = hand_info.l_mult  or defaults.l_mult  or 0
    chips = chips - l_chips
    mult  = mult  - l_mult
  end

  -- The Flint boss blind halves the hand's base chips and mult
  if is_flint_active() then
    chips = math.ceil(chips / 2)
    mult = math.ceil(mult / 2)
  end

  -- Set of played cards (for held-in-hand lookups later)
  local played = {}
  for _, card in ipairs(cards) do played[card] = true end

  -- Determine which cards score (excludes kickers, includes Stone Cards)
  local scoring = get_scoring_cards(cards, hand_name)

  -- Unpack per-F2 invariants. analyze_hand's combo loop builds these
  -- once and passes them in; single-shot callers get a lazy build.
  -- Everything here (resolved list, Pareidolia, Hiker, Baron, Shoot
  -- the Moon, Baseball Card) depends only on the joker list, not on
  -- which scoring subset we're evaluating.
  -- Must precede the before-pass: run_before is read below.
  local resolved            = precomputed.resolved
  local pareidolia          = precomputed.pareidolia
  local hiker_add           = precomputed.hiker_add
  local has_baron           = precomputed.has_baron
  local baron_count         = precomputed.baron_count
  local has_shoot_moon      = precomputed.has_shoot_moon
  local shoot_moon_count    = precomputed.shoot_moon_count
  local baseball_card_count = precomputed.baseball_card_count
  local run_before          = precomputed.run_before
  local run_individual      = precomputed.run_individual
  local enter_per_card_loop = precomputed.enter_per_card_loop
  local has_midas_mask      = precomputed.has_midas_mask

  -- context.before pre-pass: scaling jokers bump their ability.* here.
  -- Must be restored before return so the next combo iteration sees
  -- the same pre-hand state.
  --
  -- Mirror evaluate_play's pre-scoring increment of played counters
  -- (state_events.lua:590-592) for the duration of the before pass.
  -- Obelisk reads G.GAME.hands[scoring_name].played in context.before
  -- to decide whether the played hand is uniquely the most-played; if
  -- another hand is tied, vanilla sees the post-bump value as
  -- uniquely highest and resets x_mult, but pre-bump leaves it tied
  -- and Obelisk fires when it shouldn't. Restore immediately so the
  -- pre-bump joker_main compensations (Supernova +1, Card Sharp)
  -- still see the values they were written against.
  local _played_pre_bump
  if run_before and hand_info then
    _played_pre_bump = {
      played            = hand_info.played,
      played_this_round = hand_info.played_this_round,
      played_this_ante  = hand_info.played_this_ante,
    }
    hand_info.played            = (hand_info.played or 0) + 1
    hand_info.played_this_round = (hand_info.played_this_round or 0) + 1
    hand_info.played_this_ante  = (hand_info.played_this_ante or 0) + 1
  end
  local before_snapshots = run_before and
    run_before_pass(cards, scoring, hand_name, poker_hands) or nil
  if _played_pre_bump then
    hand_info.played            = _played_pre_bump.played
    hand_info.played_this_round = _played_pre_bump.played_this_round
    hand_info.played_this_ante  = _played_pre_bump.played_this_ante
  end

  -- Cross-card state for per-card joker effects.
  -- used_ev gets flipped true whenever a probabilistic effect (Lucky Card,
  -- Bloodstone) contributes to the score in EV mode, so the F2 output can
  -- label the result as an expected value.
  -- prob_idx is the running count of probabilistic events consumed.
  -- prob_arities[i] is the number of distinct outcomes for event i —
  -- Lucky Card emits 3 (none / mult-roll / dollars-only-roll), Bloodstone
  -- emits 2 (miss / hit). F4 reads it to size its enumeration loop.
  -- prob_config is the caller-supplied outcome pin (nil in F2 / EV mode);
  -- when set, prob_config[i] is an integer in [0, prob_arities[i]).
  local state = {
    photo_card = nil, used_ev = false,
    prob_idx = 0, prob_arities = {}, prob_config = prob_config,
    range_idx = 0, range_config = range_config,
    range_events = {},
  }

  -- Lucky Cat snapshot: each Lucky-card trigger (vanilla card.lua:3076)
  -- mutates self.ability.x_mult on the actual Lucky Cat. The catch-all
  -- in joker_main (card.lua:3653) then returns Xmult_mod = x_mult, so
  -- the bump applied during Phase 1 must be visible to Phase 3. We
  -- mutate the live ability table for that visibility and restore it
  -- below before returning so the next combo (and the next F2 call)
  -- sees the original state. Ignores Blueprint/Brainstorm copies on
  -- purpose — vanilla guards the bump with `not context.blueprint`,
  -- and resolved entries share the underlying Lucky Cat ability table
  -- so a single bump propagates to every copy automatically.
  local lucky_cats = nil
  if G.jokers and G.jokers.cards then
    for _, j in ipairs(G.jokers.cards) do
      if j.ability and j.ability.name == 'Lucky Cat' and not j.debuff then
        lucky_cats = lucky_cats or {}
        local extra = j.ability.extra
        if type(extra) ~= 'number' then extra = 0.25 end
        lucky_cats[#lucky_cats + 1] = {
          joker = j,
          original_x_mult = j.ability.x_mult,
          extra = extra,
        }
      end
    end
  end

  -- Space Joker: in context.before, rolls pseudorandom('space') <
  -- 1/ability.extra (default 1/4) and on success bumps the played
  -- hand's level by 1 via level_up_hand (vanilla card.lua:3420).
  -- The level mutation can't be cleanly rolled back during read-only
  -- analysis, so Space Joker is on before_deny — run_before_pass
  -- skips it. Instead, enumerate the roll here as an arity-2 prob
  -- slot per Space Joker. Outcome 1 = upgrade fires, adding one
  -- level's worth of chips/mult to this combo's base. EV mode adds
  -- 1/4 of a level. (Blueprint/Brainstorm copies of Space Joker
  -- would each get an additional roll in vanilla, but this isn't
  -- enumerated — rare enough to ignore for now.)
  local space_count = 0
  if G.jokers and G.jokers.cards then
    for _, j in ipairs(G.jokers.cards) do
      if j.ability and j.ability.name == 'Space Joker' and not j.debuff then
        space_count = space_count + 1
      end
    end
  end
  if space_count > 0 then
    local defaults = default_level_increments[hand_name] or {}
    local l_chips = hand_info.l_chips or defaults.l_chips or 0
    local l_mult  = hand_info.l_mult  or defaults.l_mult  or 0
    for _ = 1, space_count do
      state.prob_idx = state.prob_idx + 1
      state.prob_arities[state.prob_idx] = 2
      if state.prob_config then
        if state.prob_config[state.prob_idx] == 1 then
          chips = chips + l_chips
          mult  = mult  + l_mult
        end
      else
        chips = chips + l_chips * 0.25
        mult  = mult  + l_mult  * 0.25
        state.used_ev = true
      end
    end
  end

  -- Wrap Phases 1-3 in pcall so an unexpected error (a misbehaving
  -- modded joker, a torn fixture, an arithmetic on nil) can't skip the
  -- ability-restore cleanup that follows. Without this, a leaked
  -- before-pass scaling bump or Lucky Cat x_mult bump would persist
  -- for the rest of the session. The closure captures all the locals
  -- declared above (chips, mult, scoring, state, …) by reference, so
  -- mutations propagate out as before.
  local saved_dollar_buffer
  local dollar_buffer_set = false
  local function _score_body()

  -------------------------------------------------
  -- Phase 1: each scoring card fires L→R
  -- Each trigger applies in order:
  --   base chips → enhancement → edition → per-card jokers
  -- Retriggers repeat the entire sequence for that card.
  -------------------------------------------------

  -- Hiker: permanent +5 perma_bonus per trigger per Hiker. hiker_add
  -- is precomputed once per F2 (= 5 × count); we just read it here.
  -- scoring_dollars tracks $ earned mid-hand from Gold-seal scoring
  -- triggers ($3 each), so Phase 3 jokers that read G.GAME.dollars
  -- (Bootstraps) see the real value the game presents to them.
  -- Reusable context table for Phase-1's real-dispatch loop. Built
  -- once and mutated per scoring card (see eval_per_card_jokers),
  -- replacing a per-(card × trigger × joker) allocation.
  local ctx_individual = run_individual and poker_hands and {
    individual   = true,
    cardarea     = G.play,
    other_card   = nil,  -- mutated per card by eval_per_card_jokers
    full_hand    = cards,
    scoring_hand = scoring,
    scoring_name = hand_name,
    poker_hands  = poker_hands,
  } or nil

  local scoring_dollars = 0
  for idx, card in ipairs(scoring) do
    if not card.debuff then
      local triggers = get_triggers(card, idx, false, pareidolia, resolved)
      if card.seal == 'Gold' then
        scoring_dollars = scoring_dollars + 3 * triggers
      end
      local hiker_accum = 0  -- accumulated perma_bonus from Hiker for this card
      -- Midas Mask (vanilla card.lua:3869) converts every face card in
      -- scoring_hand to Gold via set_ability(m_gold) during context.before.
      -- set_ability rebuilds ability with the Gold center's defaults
      -- (no chip/mult bonus) but PRESERVES perma_bonus, edition, and
      -- seal. We can't roll that mutation back during analyze_hand, so
      -- we simulate it here: skip the enhancement chip/mult branch for
      -- face cards when Midas Mask is present, and treat them as
      -- non-Stone (Gold restores nominal). is_face is Pareidolia-aware.
      local card_id = card.base and card.base.id
      local midas_gold = has_midas_mask and (pareidolia
        or card_id == 11 or card_id == 12 or card_id == 13)
      local is_stone = card.ability and card.ability.name == 'Stone Card'
        and not midas_gold
      for trig = 1, triggers do
        -- Base chip value from card rank. Real Card:get_chip_bonus
        -- (balatro_src/card.lua:976) returns ONLY bonus + perma_bonus
        -- for Stone Cards — nominal is suppressed.
        if not is_stone then
          chips = chips + (card.base.nominal or 0)
        end

        -- Card enhancement bonuses
        local ability = card.ability
        if ability then
          local ename = ability.name
          -- Balatro stores these enhancement names WITHOUT the
          -- "Card" suffix (confirmed from captured fixtures):
          -- "Bonus", "Mult" — but "Glass Card", "Steel Card",
          -- "Lucky Card" etc. DO carry the suffix. Inconsistent
          -- naming in the game data.
          if midas_gold then
            -- Enhancement gone (now Gold); no chip/mult contribution.
          elseif ename == 'Bonus' then
            chips = chips + 30
          elseif ename == 'Mult' then
            mult = mult + 4
          elseif ename == 'Glass Card' then
            mult = apply_xmult(mult, 2)
          elseif ename == 'Stone Card' then
            chips = chips + 50
          elseif ename == 'Lucky Card' then
            -- Two independent rolls per trigger (vanilla card.lua):
            --   1/5  mult roll  → +20 mult, sets lucky_trigger
            --   1/15 money roll → +$20,    sets lucky_trigger
            -- Both paths set lucky_trigger, which bumps Lucky Cat in
            -- the same individual context (card.lua:3076). Lucky Cat
            -- bumps once regardless of how many paths fired, so
            -- (mult+money) collapses with (mult-only) into one
            -- score-distinguishable outcome. Three outcomes total:
            --   0: neither rolls fire (4/5 × 14/15 = 56/75) — no mult, no bump
            --   1: mult roll fires    (1/5)                 — +20 mult, bump
            --   2: money roll alone   (4/5 × 1/15 = 4/75)   — no mult, bump
            -- EV mode averages: +4 mult (1/5 × 20), Lucky Cat bump
            -- weighted by Pr(lucky_trigger) = 19/75 ≈ 0.2533.
            state.prob_idx = state.prob_idx + 1
            state.prob_arities[state.prob_idx] = 3
            local outcome = nil  -- nil = EV partial, 0/1/2 = exact
            if state.prob_config then
              outcome = state.prob_config[state.prob_idx] or 0
              if outcome == 1 then mult = mult + 20 end
            else
              mult = mult + 4
              state.used_ev = true
            end
            -- Lucky Cat bump. Phase 3's joker_main catch-all
            -- (card.lua:3653) returns the bumped x_mult; restore
            -- happens at the bottom of score_combo.
            if lucky_cats then
              for _, lc in ipairs(lucky_cats) do
                if outcome == 1 or outcome == 2 then
                  lc.joker.ability.x_mult = lc.joker.ability.x_mult + lc.extra
                elseif outcome == nil then
                  lc.joker.ability.x_mult = lc.joker.ability.x_mult + lc.extra * (19/75)
                end
              end
            end
          end
          -- Permanent bonus chips (from hand-scored upgrades).
          -- Hiker accumulation: each Hiker adds +5 to perma_bonus
          -- per trigger, read on the NEXT trigger. hiker_accum
          -- tracks the total added by Hiker so far for this card.
          chips = chips + (ability.perma_bonus or 0) + hiker_accum
        end

        -- Card edition bonuses (foil/holo/polychrome)
        chips, mult = apply_edition(card.edition, chips, mult)

        -- Per-card joker effects for this card. Skip the call
        -- entirely when no joker would actually contribute — this
        -- cuts ~10,900 wasted pcalls per F2 on common loadouts
        -- where Hiker/Lucky Cat/Wee Joker (deny-listed) are the
        -- only jokers with an individual branch.
        if enter_per_card_loop then
          chips, mult = eval_per_card_jokers(
            card, resolved, chips, mult, state, pareidolia,
            cards, scoring, hand_name, poker_hands, run_individual,
            ctx_individual
          )
        end

        -- Hiker: permanently adds to this card's perma_bonus,
        -- read on the next trigger of this same card.
        hiker_accum = hiker_accum + hiker_add
      end
    end
  end

  -------------------------------------------------
  -- Phase 2: held-in-hand effects (with retriggers)
  -- Steel Card, Baron, and Shoot the Moon fire per held card.
  -- Mime and Red Seal provide retriggers for held cards.
  --
  -- IMPORTANT: held-in-hand effects run BEFORE flat joker effects.
  -- Balatro's state_events.lua calls SMODS.calculate_main_scoring
  -- for the G.hand card-area (held cards) at line 673, and only
  -- fires joker_main in the loop starting at line 680. Running them
  -- in the opposite order mis-scales jokers like Mad Joker holo
  -- that add flat mult on top of Baron's x1.5 multiplier.
  --
  -- NOTE on DNA: when DNA fires, it emplaces a copy of the played card
  -- into G.hand, but captures show the copy doesn't contribute to
  -- THIS hand's Phase 2 scoring — presumably because the emplace lands
  -- after Phase 2 has already snapshotted G.hand.cards. So treat DNA
  -- as score-neutral for the current hand and let the copy affect
  -- future hands only (via Steel Joker's full-deck count, Baron's
  -- held-King check next hand, etc.).
  -------------------------------------------------

  -- Jokers we don't dispatch in the held-individual real path:
  --   * Mime returns repetitions only (non-score); retriggers are
  --     applied by get_triggers.
  --   * Reserved Parking mutates G.GAME.dollar_buffer and queues an
  --     event — unrollable side effects.
  -- Baron and Shoot the Moon were here historically, paired with the
  -- hardcoded fast paths below. They were moved to real dispatch so
  -- they fire at their slot position, not before every other held
  -- joker — without that, Raised Fist (slot N) followed by Baron
  -- (slot N+M) was applying as mult * 1.5 + raised, instead of the
  -- correct (mult + raised) * 1.5.
  local held_individual_deny = {
    ['Mime']             = true,
    ['Reserved Parking'] = true,
  }

  -- Pre-scan for any joker that *might* fire in held-individual context
  -- so we don't enter the trigger loop on cards no joker cares about.
  --
  -- Also build a skip set for Blueprint/Brainstorm copies whose target
  -- is in held_individual_deny. Those copies' contribution is already
  -- counted by the hardcoded fast paths via baron_count / shoot_moon_count
  -- (resolve_jokers re-labels copies with the target's name). Letting
  -- their calculate_joker fire here forwards to Baron/Shoot the Moon
  -- and double-counts — manifests as ~25× over-prediction on Flush Five
  -- with Blueprint + Baron + Brainstorm and 4 held Kings (×1.5^2 per
  -- held King × 4 = ×1.5^8 ≈ 25.6).
  local jokers_for_held = G.jokers and G.jokers.cards or {}
  local has_held_individual_joker = false
  local held_skip_copies = {}
  for i, j in ipairs(jokers_for_held) do
    if not j.debuff and j.ability and j.calculate_joker then
      local nm = j.ability.name or ''
      if nm == 'Blueprint' or nm == 'Brainstorm' then
        local target = resolve_copy_target(jokers_for_held, i, {})
        if target and held_individual_deny[target.name or ''] then
          held_skip_copies[j] = true
        end
      end
      if not held_individual_deny[nm] and not held_skip_copies[j] then
        has_held_individual_joker = true
      end
    end
  end

  -- Reusable context table for the held-individual real-dispatch
  -- loop. `other_card` gets mutated per held card before each joker
  -- call. Built once per combo instead of once per (held card ×
  -- trigger × joker).
  local ctx_held = has_held_individual_joker and {
    individual   = true,
    cardarea     = G.hand,
    other_card   = nil,
    full_hand    = cards,
    scoring_hand = scoring,
    scoring_name = hand_name,
    poker_hands  = poker_hands,
  } or nil

  -- has_baron / baron_count / has_shoot_moon / shoot_moon_count are
  -- all read from `precomputed` — same reason Hiker is hoisted.
  local function apply_held_effects(card)
    if card.debuff then return end
    -- When respecting face-down cards, the player can't know whether a
    -- back-facing card is a King, Queen, Steel, etc., so it can't
    -- contribute to Baron / Shoot the Moon / Steel-held / Mime / Raised
    -- Fist. Skip entirely — matches the "treat unknown as nothing"
    -- model used by analyze_hand's combo filter.
    if respect_face_down and is_face_down(card) then return end
    local is_steel = card.ability and card.ability.name == 'Steel Card'
    -- Stone Cards override Card:get_id to return a random negative
    -- value, so Baron and Shoot the Moon (which test get_id == 13/12)
    -- never fire on them in-game. The fast paths below compare
    -- base.id, so exclude Stones explicitly.
    local is_stone = card.ability and card.ability.name == 'Stone Card'
    local is_king = not is_stone and card.base.id == 13
    local is_queen = not is_stone and card.base.id == 12
    if not (is_steel or (has_baron and is_king)
      or (has_shoot_moon and is_queen) or has_held_individual_joker) then
      return
    end
    local triggers = get_triggers(card, 0, true, pareidolia, resolved)
    for _ = 1, triggers do
      -- Steel Card enhancement: x1.5 mult per trigger. Steel fires
      -- from the card's own enhancement evaluation (before any joker
      -- in slot order), so it stays as a hardcoded prelude rather
      -- than going through real dispatch.
      -- Card editions do NOT fire for held-in-hand effects; they
      -- only fire in Phase 1 for scored cards.
      if is_steel then
        mult = apply_xmult(mult, 1.5)
      end
      -- Real-dispatch path for held-individual jokers in slot order:
      -- Baron (x1.5 per held King), Shoot the Moon (+13 mult per held
      -- Queen), Raised Fist (+2*nominal on its tracked card), plus
      -- any future additions. Mirrors the per-joker call in
      -- evaluate_play's held loop (state_events.lua:802) with
      -- cardarea = G.hand, individual = true.
      --
      -- No snapshot: every non-deny vanilla joker reachable here only
      -- reads self.ability and returns an effect table. Reserved
      -- Parking is in held_individual_deny because it mutates
      -- G.GAME.dollar_buffer and queues an event.
      if has_held_individual_joker then
        ctx_held.other_card = card
        for _, joker in ipairs(jokers_for_held) do
          local jname = joker.ability and joker.ability.name or ''
          if not joker.debuff and joker.ability and joker.calculate_joker
            and not held_individual_deny[jname]
            and not held_skip_copies[joker] then
            local ok, effect = pcall(joker.calculate_joker, joker, ctx_held)
            -- Blueprint/Brainstorm reset (see eval_per_card_jokers).
            ctx_held.blueprint      = nil
            ctx_held.blueprint_card = nil
            if ok and type(effect) == 'table' then
              if effect.h_mult then mult = mult + effect.h_mult end
              if effect.mult   then mult = mult + effect.mult   end
              if effect.x_mult then mult = apply_xmult(mult, effect.x_mult) end
            end
          end
        end
      end
    end
  end

  for _, card in ipairs(all_cards) do
    if not played[card] then apply_held_effects(card) end
  end

  -------------------------------------------------
  -- Phase 3: flat joker effects fire L→R (after held-in-hand effects)
  --
  -- HYBRID APPROACH: for each joker, first call the game's own
  -- Card:calculate_joker with a joker_main context. That returns a
  -- raw effect table like {mult_mod = 8} WITHOUT applying it to
  -- globals (SMODS.trigger_effects does that, and we skip it).
  --
  -- batch_verify attaches the Card metatable to captured fixture
  -- jokers, so both in-game and offline dispatch go through the same
  -- code path.
  --
  -- run_before_pass has already fired each joker's context.before so
  -- scaling state is bumped; joker_main returns the updated value.
  -- Jokers that return nil on joker_main (those firing only in
  -- context.individual/other_joker) — and Misprint, which is
  -- deny-listed to keep its pseudorandom() call out of our read-only
  -- analysis — fall through to eval_flat_jokers below, which reads
  -- ability.* accumulators directly.
  -------------------------------------------------
  local suits = count_suits(scoring)
  local ctx = {
    hand_name   = hand_name,
    all_cards   = all_cards,
    played      = played,
    num_played  = #cards,
    suits       = suits,
    -- These extra fields are passed to real calculate_joker calls.
    -- poker_hands comes from get_poker_hand_info and maps each
    -- hand type ("Pair", "Flush", …) to the cards that form it.
    -- Jokers like Jolly Joker check poker_hands[self.ability.type]
    -- to decide whether to fire.
    poker_hands = poker_hands,
    full_hand   = cards,
    scoring_hand = scoring,
    scoring_dollars = scoring_dollars,
  }

  -- `resolved` (built in Phase 1 above) provides the fallback path's
  -- pre-resolved ability/name/edition for Blueprint/Brainstorm jokers.

  -- Baseball Card: each uncommon joker (rarity == 2) gives x1.5 mult
  -- at the uncommon joker's slot position. Presence is read from the
  -- precomputed bundle (see build_combo_precomputed).

  -- Reusable joker_main context, allocated once per combo and shared
  -- across all jokers in the Phase-3 loop below. Replaces the
  -- per-joker table that was being allocated and discarded inside
  -- the loop on every combo.
  local ctx_joker_main = poker_hands and {
    joker_main   = true,
    full_hand    = cards,
    scoring_hand = scoring,
    scoring_name = hand_name,
    poker_hands  = poker_hands,
    cardarea     = G.jokers,
  } or nil

  -- Vanilla `get_p_dollars` (balatro_src/card.lua:1084) bumps
  -- G.GAME.dollar_buffer for every Gold seal (and Lucky/Gold-card
  -- p_dollars) during the per-card phase, BEFORE the Phase-3
  -- joker_main loop fires. Bootstraps (`dollars + dollar_buffer`)
  -- and Bull read this value, so analysis-time predictions miss any
  -- mid-hand dollars. Mirror the bump here using the scoring_dollars
  -- accumulated during Phase 1; restore unconditionally after pcall.
  if scoring_dollars > 0 and G.GAME then
    saved_dollar_buffer = G.GAME.dollar_buffer
    G.GAME.dollar_buffer = (saved_dollar_buffer or 0) + scoring_dollars
    dollar_buffer_set = true
  end

  -- Iterate the real joker Card objects (not the resolved list) so
  -- calculate_joker is called on the actual Card — Blueprint's own
  -- calculate_joker handles delegation to its copy target internally.
  -- We keep a parallel index into `resolved` for the fallback path,
  -- which needs the pre-resolved ability/name/edition for Blueprint.
  local resolved_idx = 0
  for _, joker in ipairs(G.jokers and G.jokers.cards or {}) do
    if not joker.debuff then
      resolved_idx = resolved_idx + 1
      local name = (joker.ability and joker.ability.name) or ''
      local effect = nil

      ---------------------------------------------------------
      -- Hybrid path: call the game's real calculate_joker.
      -- Only available when running inside Balatro (joker is a
      -- real Card object with methods, not a plain fixture table).
      -- Skipped for deny-list jokers whose calculate has side
      -- effects we can't tolerate during read-only analysis.
      --
      -- SAFETY: snapshot the joker's ability table before the
      -- call and restore it unconditionally afterward. This
      -- guarantees that even if a joker's calculate mutates
      -- self.ability.* as a side effect, the game state is
      -- never corrupted by our read-only probing.
      ---------------------------------------------------------
      -- Skip the pcall for jokers that never return anything from
      -- joker_main (passive, retrigger-only, per-card-only, held-only,
      -- before-only). Single name lookup against the *resolved* name
      -- so Blueprint/Brainstorm copying e.g. Baron also gets skipped.
      -- The lovely-patched joker_main has catch-all branches
      -- (x_mult > 1 / t_mult > 0 / t_chips > 0) but for every joker
      -- in this set the relevant ability fields stay at their default
      -- (1 or 0) — they're never mutated by these jokers' own code —
      -- so the catch-all never fires. Skipping ~6 of 7 pcalls per
      -- combo on common loadouts × 218 combos saves ~1.3k pcalls.
      local r_entry = resolved[resolved_idx]
      local r_name = r_entry and r_entry.name or name

      if joker.calculate_joker
        and not joker_main_deny[name]
        and ctx_joker_main
        and not joker_main_no_fire[r_name] then
        -- No snapshot here: the joker_main branch in lovely's
        -- patched card.lua is read-only for every vanilla joker
        -- except Loyalty Card, which writes ability.loyalty_remaining
        -- as a deterministic function of fields that don't change
        -- between F2 calls (G.GAME.hands_played - hands_played_at_create
        -- mod every+1) — same input, same output, so the "mutation"
        -- is idempotent and safe to leave in place.
        --
        -- pcall still catches modded jokers that error out;
        -- ctx_joker_main is reused across all jokers in this loop.
        local ok, ret = pcall(joker.calculate_joker, joker, ctx_joker_main)
        -- Blueprint/Brainstorm mutate these fields before recursing
        -- into their copy target — reset so the next joker sees
        -- a clean context (matches the per-call fresh-table behavior
        -- the old code relied on).
        ctx_joker_main.blueprint      = nil
        ctx_joker_main.blueprint_card = nil
        if ok and type(ret) == 'table' then effect = ret end

        -- Pre-increment correction: Supernova returns
        -- mult_mod = hands[name].played, but in the real play
        -- Balatro bumps that counter at the top of evaluate_play
        -- before calculate_joker reads it. Our analysis runs
        -- pre-increment, so the returned value is short by 1.
        -- Patch the effect before apply_edition so polychrome
        -- Supernova still composes correctly.
        if effect and name == 'Supernova' then
          effect.mult_mod = (effect.mult_mod or 0) + 1
        end
        -- Same pre-increment story for Card Sharp: vanilla checks
        -- played_this_round > 1, which is post-bump >= 2, i.e.
        -- pre-bump >= 1. joker_main returns nil pre-bump in that
        -- window, so synthesize the Xmult_mod.
        if not effect and name == 'Card Sharp' then
          local h = G.GAME and G.GAME.hands and G.GAME.hands[hand_name]
          if h and (h.played_this_round or 0) >= 1 then
            local xm = joker.ability.extra and joker.ability.extra.Xmult or 3
            effect = { Xmult_mod = xm }
          end
        end
      end

      -------------------------------------------------------
      -- Joker edition applies regardless of whether joker_main
      -- fires. Balatro evaluates edition and joker_main as
      -- independent eval_card calls (state_events.lua:880/905),
      -- so foil/holo still score even when the joker's
      -- joker_main returns nil (e.g. Baron, which fires only in
      -- the held-in-hand individual context).
      --
      -- Composition: holo (+10 mult) / foil (+50 chips) join the
      -- joker's additive pool BEFORE its Xmult step so e.g. Steel
      -- Joker ×11.4 with holo scores (m+10)×11.4, not m×11.4+10.
      -- Polychrome ×1.5 stacks AFTER the joker's Xmult.
      -------------------------------------------------------
      chips, mult = edition_additive(joker.edition, chips, mult)
      if effect then
        chips = chips + (effect.chip_mod or 0)
        mult  = mult  + (effect.mult_mod or 0)
        if effect.Xmult_mod then mult = apply_xmult(mult, effect.Xmult_mod) end
      else
        -- Fallback for deny-listed / joker_main-nil jokers.
        -- eval_flat_jokers handles Misprint's range enumeration;
        -- everything else falls through as a no-op (the joker
        -- either doesn't score this phase or contributed nil).
        local r = resolved[resolved_idx]
        if r then
          chips, mult = eval_flat_jokers({r}, chips, mult, ctx, state)
        end
      end
      chips, mult = edition_multiplicative(joker.edition, chips, mult)

      ---------------------------------------------------------
      -- Baseball Card: x1.5 mult for each uncommon joker.
      -- In Balatro, this fires at the uncommon joker's position
      -- (not at Baseball Card's own slot), even if the joker
      -- has no scoring effect. Rarity 2 = Uncommon.
      --
      -- Read rarity from both shapes: live Card objects store it
      -- at joker.config.center.rarity; fixture tables from
      -- extract_joker store the scalar at joker.rarity. Checking
      -- only the latter silently skipped the effect in-game.
      --
      -- Blueprint/Brainstorm copies of Baseball Card each add a
      -- second X1.5 per uncommon (each copy fires its own
      -- context.other_joker reaction in vanilla via
      -- SMODS.blueprint_effect), so apply once per resolved BC.
      ---------------------------------------------------------
      local rarity = joker.rarity
        or (joker.config and joker.config.center
          and joker.config.center.rarity)
      if baseball_card_count > 0 and rarity == 2 then
        for _ = 1, baseball_card_count do
          mult = apply_xmult(mult, 1.5)
        end
      end

      ---------------------------------------------------------
      -- Context-specific pre-increment correction: Wee Joker
      -- updates self.ability.extra.chips in context.individual
      -- (per scored 2), not context.before. We don't mirror the
      -- individual-context loop, so add the delta here. Retriggers
      -- (Seltzer, Hack, Red Seal, etc.) on a 2 scale it per trigger.
      -- Debuffed 2s (e.g. The Pillar boss debuff) don't fire
      -- context.individual at all, so they don't bump Wee.
      ---------------------------------------------------------
      if name == 'Wee Joker' then
        local ability = joker.ability or {}
        local extra = ability.extra
        if type(extra) ~= 'table' then extra = {} end
        local twos_triggers = 0
        for idx, c in ipairs(scoring) do
          if c.base.id == 2 and not c.debuff then
            twos_triggers = twos_triggers
              + get_triggers(c, idx, false, pareidolia, resolved)
          end
        end
        chips = chips + (extra.chip_mod or 8) * twos_triggers
      end
    end
  end

  end  -- _score_body

  local ok, err = pcall(_score_body)

  -- Roll back the before-pass mutations so the next combo (and any
  -- external reader of joker.ability.*) sees the original state.
  -- Runs whether _score_body succeeded or errored.
  if before_snapshots then restore_before_pass(before_snapshots) end

  -- Restore G.GAME.dollar_buffer if we bumped it for the Phase-3
  -- joker loop. Always runs, even if pcall errored mid-loop.
  if dollar_buffer_set then
    G.GAME.dollar_buffer = saved_dollar_buffer
  end

  -- Roll back Lucky Cat bumps applied during Phase 1's per-card loop.
  if lucky_cats then
    for _, lc in ipairs(lucky_cats) do
      lc.joker.ability.x_mult = lc.original_x_mult
    end
  end

  if not ok then error(err, 0) end

  -- Balatro floors the final score to an integer; mirror that so
  -- polychrome/holo chains producing fractional intermediates match.
  return hand_name, math.floor(chips * mult), scoring,
    state.used_ev, state.prob_arities, state.range_events
end

-------------------------------------------------------------------------
-- Display helpers: convert cards to compact readable labels
-------------------------------------------------------------------------
local rank_names = {
  [2] = '2', [3] = '3', [4] = '4', [5] = '5', [6] = '6',
  [7] = '7', [8] = '8', [9] = '9', [10] = '10',
  [11] = 'J', [12] = 'Q', [13] = 'K', [14] = 'A',
}
local suit_symbols = {
  ['Hearts'] = 'h', ['Diamonds'] = 'd',
  ['Clubs'] = 'c', ['Spades'] = 's',
}

-- Format an integer with commas as thousands separators (e.g. 1234567 → "1,234,567")
-- For very large numbers, also append Balatro's exponent notation (e.g. "1.23e10").
local function format_number(n)
  local s = string.format('%.0f', n)
  local result = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
  result = result:gsub('^,', '')
  if n >= 1e7 then
    local exp = math.floor(math.log10(n))
    local mantissa = n / (10 ^ exp)
    result = result .. string.format(' (%.2fe%d)', mantissa, exp)
  end
  return result
end

local function card_label(card)
  local rank = rank_names[card.base.id] or '?'
  local suit = suit_symbols[card.base.suit] or '?'
  return rank .. suit
end

local function cards_label(cards)
  local labels = {}
  for _, card in ipairs(cards) do
    labels[#labels + 1] = card_label(card)
  end
  return table.concat(labels, ', ')
end

-- Label all cards EXCEPT those in the exclude list
local function cards_label_exclude(cards, exclude)
  local exc_set = {}
  for _, card in ipairs(exclude) do exc_set[card] = true end
  local labels = {}
  for _, card in ipairs(cards) do
    if not exc_set[card] then labels[#labels + 1] = card_label(card) end
  end
  return table.concat(labels, ', ')
end

-- Map ability.name to short display tokens. Plain cards have
-- ability.name = "Default Base" and are reported as "plain".
local enhancement_display = {
  Bonus           = 'Bonus',
  Mult            = 'Mult',
  ['Lucky Card']  = 'Lucky',
  ['Glass Card']  = 'Glass',
  ['Steel Card']  = 'Steel',
  ['Stone Card']  = 'Stone',
  ['Gold Card']   = 'Gold',
  ['Wild Card']   = 'Wild',
}

-- Short description of what makes a card distinct beyond its rank/suit:
-- edition + enhancement + seal. Used to disambiguate duplicate labels
-- in the "drag into this order" hint, where two Kd's are otherwise
-- visually identical and the player can't tell which is which.
local function card_descriptor(card)
  local parts = {}
  local edition = card.edition
  if edition then
    if edition.polychrome then parts[#parts + 1] = 'Polychrome'
    elseif edition.holo then parts[#parts + 1] = 'Holographic'
    elseif edition.foil then parts[#parts + 1] = 'Foil'
    elseif edition.negative then parts[#parts + 1] = 'Negative'
    end
  end
  local enh = card.ability and enhancement_display[card.ability.name]
  if enh then parts[#parts + 1] = enh end
  local desc = #parts > 0 and table.concat(parts, ' ') or 'plain'
  if card.seal then
    desc = desc .. ' (' .. card.seal .. ' seal)'
  end
  return desc
end

-- When the optimal play order contains two or more cards that share a
-- rank/suit label (e.g. two Kd), the "drag into this order" hint is
-- ambiguous — the player has no way to know which physical card to
-- place where. For each colliding label, return a "Kd: Lucky, then
-- Bonus" fragment naming each copy by its distinguishing modifiers.
-- Returns nil when every label is unique, or when same-labeled cards
-- are themselves indistinguishable (the order between them is then
-- score-neutral and a hint would be misleading).
local function describe_duplicate_order(cards)
  local groups, order = {}, {}
  for _, card in ipairs(cards) do
    local label = card_label(card)
    if not groups[label] then
      groups[label] = {}
      order[#order + 1] = label
    end
    local g = groups[label]
    g[#g + 1] = card_descriptor(card)
  end
  local hints = {}
  for _, label in ipairs(order) do
    local g = groups[label]
    if #g > 1 then
      local all_same = true
      for i = 2, #g do
        if g[i] ~= g[1] then all_same = false; break end
      end
      if not all_same then
        hints[#hints + 1] = label .. ': '
          .. table.concat(g, ', then ')
      end
    end
  end
  if #hints == 0 then return nil end
  return table.concat(hints, '; ')
end

-- Balatro's get_straight walks each rank in the run and adds EVERY card
-- of that rank to scoring_hand, so a Straight (or Straight Flush / Royal
-- Flush) played with two cards sharing a rank — A-K-Q-J-J or 3-4-4-5-6 —
-- counts both copies. Without a hint this looks wrong: the duplicate
-- reads as a non-scoring kicker that the mod is incorrectly listing.
-- Annotate so the player recognizes both copies score.
local function describe_rank_duplicates(name, cards)
  if name ~= 'Straight' and name ~= 'Straight Flush'
    and name ~= 'Royal Flush' then return nil end
  local counts, order = {}, {}
  for _, c in ipairs(cards) do
    -- Stone Cards score as unconditional kickers, not as straight-pattern
    -- members; their base.id can collide with a real scoring card and
    -- would falsely look like a same-rank duplicate.
    if not (c.ability and c.ability.name == 'Stone Card') then
      local id = c.base.id
      if not counts[id] then
        counts[id] = 0
        order[#order + 1] = id
      end
      counts[id] = counts[id] + 1
    end
  end
  local labels = {}
  for _, id in ipairs(order) do
    if counts[id] > 1 then
      labels[#labels + 1] = (rank_names[id] or '?') .. 's'
    end
  end
  if #labels == 0 then return nil end
  return 'both ' .. table.concat(labels, ' and ') .. ' score'
end

-------------------------------------------------------------------------
-- Detect whether the joker + card configuration makes scoring ORDER
-- matter. Returns true when at least one of these conditions holds:
--
--   Joker / card        Why position matters
--   ─────────────────── ──────────────────────────────────────────────────
--   Hanging Chad        Gives +2 retriggers to the LEFTMOST scoring card
--                       only. Put the highest-value card first so it fires
--                       three times instead of once.
--
--   Photograph          ×2 mult fires when the FIRST face card is scored.
--                       Put non-face cards to the left so more +mult has
--                       accumulated before the ×2 fires. With Hanging Chad
--                       on the same face card, each of its 3 triggers
--                       re-fires Photograph → ×2 × ×2 × ×2 = ×8 total.
--
--   Ancient Joker       ×1.5 fires each time a card of the active suit is
--   Bloodstone          scored (×1.25 EV for Bloodstone Hearts). Because
--   Triboulet           ×mult compounds — mult × 1.5 × 1.5 is bigger when
--   The Idol            the base it starts from is already high — you want
--                       these cards rightmost so preceding +mult additions
--                       are inside the multiplication, not outside it.
--                       (Triboulet: ×2 per K/Q. The Idol: ×2 per the
--                       active rank+suit card.)
--
--   Polychrome edition  ×1.5 fires mid-hand when that specific card is
--   (on a scored card)  scored. Same logic: put it rightmost so earlier
--                       +mult contributions are captured by the ×1.5.
--
--   Glass Card          ×2 mult fires on every trigger of that card
--                       (base trigger + retriggers). Same rightmost rule.
--
-- The general principle: Balatro's final score is chips × mult, and mult
-- is built up additively (+mult) and multiplicatively (×mult) as cards
-- are scored left to right. A ×mult applied to a mult of 20 is worth
-- twice as much as one applied to a mult of 10. So ×mult effects benefit
-- from firing LATE (after +mult has accumulated), while Hanging Chad's
-- retrigger benefit scales with the value of the card it targets.
-------------------------------------------------------------------------
-- Precompute which order-sensitive conditions could possibly fire this
-- F2, given the current jokers and the FULL hand. Done once per F2,
-- then needs_ordering() only has to check the specific per-combo
-- conditions that remain in play. Without this, every combo (218 per
-- F2 worst case) re-scans the entire resolved joker list inside
-- needs_ordering — pure constant overhead.
local function build_ordering_flags(resolved, hand_cards)
  local flags = {
    pareidolia    = false,
    hanging_chad  = false,
    photograph    = false,
    ancient_joker = false,
    bloodstone    = false,
    triboulet     = false,
    idol          = false,
    -- A hand-level "maybe" for card-edition/enhancement effects:
    -- if no card in the whole hand has polychrome or Glass, no
    -- scoring subset ever will either.
    maybe_poly_or_glass = false,
  }
  for _, j in ipairs(resolved) do
    local n = j.name
    if     n == 'Pareidolia'    then flags.pareidolia    = true
    elseif n == 'Hanging Chad'  then flags.hanging_chad  = true
    elseif n == 'Photograph'    then flags.photograph    = true
    elseif n == 'Ancient Joker' then flags.ancient_joker = true
    elseif n == 'Bloodstone'    then flags.bloodstone    = true
    elseif n == 'Triboulet'     then flags.triboulet     = true
    elseif n == 'The Idol'      then flags.idol          = true
    end
  end
  if flags.idol then
    local ic = G.GAME and G.GAME.current_round
      and G.GAME.current_round.idol_card
    if ic then
      flags.idol_id   = ic.id
      flags.idol_suit = ic.suit
    else
      flags.idol = false
    end
  end
  for _, c in ipairs(hand_cards) do
    if (c.edition and c.edition.polychrome)
      or (c.ability and c.ability.name == 'Glass Card') then
      flags.maybe_poly_or_glass = true
      break
    end
  end
  -- Cheap top-level gate: when none of these hold, no combo will
  -- ever need ordering and needs_ordering() can short-circuit without
  -- even walking the scoring set.
  flags.maybe = flags.hanging_chad or flags.ancient_joker
    or flags.photograph or flags.bloodstone or flags.triboulet
    or flags.idol or flags.maybe_poly_or_glass
  return flags
end

local function needs_ordering(flags, scoring)
  if not flags.maybe then return false end
  if not scoring or #scoring <= 1 then return false end

  -- Unconditional jokers: their presence alone justifies exploring
  -- permutations. Hanging Chad always retriggers SOME card; Ancient
  -- Joker's x_mult applies to whichever card ends up at a particular
  -- suit position.
  if flags.hanging_chad or flags.ancient_joker then return true end

  for _, c in ipairs(scoring) do
    local id = c.base.id
    if flags.photograph and
      (flags.pareidolia or (id >= 11 and id <= 13)) then
      return true
    end
    if flags.bloodstone and c.base.suit == 'Hearts' then return true end
    if flags.triboulet and (id == 12 or id == 13) then return true end
    if flags.idol and id == flags.idol_id
      and c.base.suit == flags.idol_suit then return true end
    if c.edition and c.edition.polychrome then return true end
    if c.ability and c.ability.name == 'Glass Card' then return true end
  end

  return false
end

-------------------------------------------------------------------------
-- Suppress floating UI messages and event-queue side effects while
-- score_combo dispatches through real Card:calculate_joker.
-- Steamodded's scaling.toml lovely patch replaces direct ability
-- mutations in scaling jokers (Green Joker, Square Joker, Spare
-- Trousers, Hologram, Runner, Obelisk, Ride the Bus, Vampire, ...)
-- with SMODS.scale_card, which displays a floating "Upgrade!"
-- message. Without suppression, F2's ~218 combos × ~5 jokers flood
-- the UI with Upgrade messages even though snapshot_ability rolls
-- back the numeric mutation.
--
-- Defense in depth — every gate is independently sufficient, but
-- together they make it almost impossible for analysis to leak a
-- visible side effect:
--   1. SMODS.no_resolve gates messages (smods utils.lua:1334) and
--      juice (:1515) inside SMODS.calculate_effect.
--   2. card_eval_status_text is stubbed because some game code paths
--      call it without going through SMODS.calculate_effect.
--   3. G.E_MANAGER:add_event is stubbed because a joker we haven't
--      audited (or a future modded joker) might queue events
--      directly. Across ~218 combos × ~50 dispatches, even a small
--      leak compounds into observable lag and stale events firing
--      after analysis returns.
--   4. juice_card / juice_card_until / play_sound are stubbed for
--      the same reason — they bypass SMODS gating.
-- The synchronous ability mutations from scaling jokers still apply
-- in-place; run_before_pass's snapshot rolls them back. Score is
-- unaffected because nothing here changes the math.
local function with_no_resolve(fn, ...)
  -- Clear at entry so stale joker-list state from a prior call can't
  -- bleed in (e.g. after a Blueprint copy is rerouted).
  clear_smeared_cache()
  local prev_resolve = SMODS and SMODS.no_resolve
  if SMODS then SMODS.no_resolve = true end

  local stubbed_globals = {
    'card_eval_status_text', 'juice_card', 'juice_card_until',
    'play_sound', 'update_hand_text',
  }
  local saved = {}
  for _, k in ipairs(stubbed_globals) do
    if _G[k] ~= nil then
      saved[k] = _G[k]
      _G[k] = function() end
    end
  end

  local saved_add_event
  if G and G.E_MANAGER and G.E_MANAGER.add_event then
    saved_add_event = G.E_MANAGER.add_event
    G.E_MANAGER.add_event = function() end
  end

  local results = { pcall(fn, ...) }

  if saved_add_event then G.E_MANAGER.add_event = saved_add_event end
  for k, v in pairs(saved) do _G[k] = v end
  if SMODS then SMODS.no_resolve = prev_resolve end
  -- Clear at exit too: don't hold a flag while game state is free
  -- to change between calls (joker bought/sold, Smeared given a
  -- new edition, etc.).
  clear_smeared_cache()

  if not results[1] then error(results[2], 0) end
  return unpack(results, 2)
end

-------------------------------------------------------------------------
-- Analyze the current hand: try every possible combo (sizes 5→1),
-- score each one, and return the top 2 distinct hand types.
-------------------------------------------------------------------------
local function analyze_hand_inner()
  if not G or not G.hand or not G.hand.cards then return nil end
  local hand_cards = G.hand.cards
  if #hand_cards == 0 then return nil end

  -- Visible-only view of the hand. When respect_face_down is on, F2
  -- treats face-down cards (Wheel/House/Mark/Fish) as if the player
  -- can't see them: they're never proposed for play, and held-in-hand
  -- effects (Baron/Shoot the Moon/Steel/Mime/Raised Fist) skip them.
  -- score_combo still receives the FULL G.hand.cards as `all_cards` so
  -- the held-iteration walks them — apply_held_effects early-returns
  -- on face-down inside score_combo.
  local cards = hand_cards
  if respect_face_down then
    local visible = {}
    for _, c in ipairs(hand_cards) do
      if not is_face_down(c) then visible[#visible + 1] = c end
    end
    cards = visible
    if #cards == 0 then return nil end
  end

  -- Resolve Blueprint/Brainstorm once and precompute the per-F2
  -- invariants (Pareidolia, Hiker, Baron, Shoot the Moon, Baseball
  -- Card) in one pass. Both `ord_flags` and `precomputed` are then
  -- reused across every score_combo call (~218 combos × up to 120
  -- perms), replacing work that used to repeat per combo.
  local resolved    = resolve_jokers()
  local ord_flags   = build_ordering_flags(resolved, cards)
  local precomputed = build_combo_precomputed(resolved)

  -- Evaluate every possible combo of every size
  local best = {}
  -- Counters for F5 debug timing (free when flag is off; print only
  -- reads them at the end of F2).
  local combo_n, perm_branches, perm_n = 0, 0, 0
  for size = 5, 1, -1 do
    if #cards >= size then
      for _, combo in ipairs(combinations(cards, size)) do
        combo_n = combo_n + 1
        local name, score, scoring, used_ev =
          score_combo(combo, hand_cards, nil, nil, precomputed)
        -- Skip zero-score combos (boss-blind debuffs like The Eye /
        -- The Mouth zero the whole hand; The Psychic zeros any combo
        -- with fewer than 5 cards). These are never worth showing.
        if name and score > 0 then
          -- When order-sensitive jokers are active, try every
          -- permutation of the scoring cards to find the best
          -- play order.  Non-scoring kicker cards go to the
          -- held-in-hand phase regardless of slot, so only
          -- scoring card order needs to be explored.
          --
          -- Keep the default-order score (before permuting) so
          -- F2 can report it alongside the optimal when a drag
          -- hint is shown — otherwise the F2 number looks like
          -- a bug when the user doesn't reorder and the live
          -- prediction comes in much lower.
          local optimal_order = nil
          local default_score = score
          if needs_ordering(ord_flags, scoring) then
            perm_branches = perm_branches + 1
            local scoring_set = {}
            for _, c in ipairs(scoring) do
              scoring_set[c] = true
            end
            local non_scoring = {}
            for _, c in ipairs(combo) do
              if not scoring_set[c] then
                non_scoring[#non_scoring + 1] = c
              end
            end
            for _, perm in ipairs(permutations(scoring)) do
              perm_n = perm_n + 1
              -- Scoring cards first (in permuted order),
              -- then kickers — get_scoring_cards preserves
              -- left-to-right order from the combo we pass.
              local reordered = {unpack(perm)}
              for _, c in ipairs(non_scoring) do
                reordered[#reordered + 1] = c
              end
              local _, ps, psc, pev =
                score_combo(reordered, hand_cards, nil, nil, precomputed)
              if ps > score then
                score         = ps
                scoring       = psc
                used_ev       = pev
                optimal_order = perm
              end
            end
          end
          best[#best + 1] = {
            name          = name,
            score         = score,
            cards         = scoring,
            play          = combo,
            used_ev       = used_ev,
            optimal_order = optimal_order,
            default_score = default_score,
          }
        end
      end
    end
  end

  -- Sort by score descending; break ties by preferring fewer cards
  table.sort(best, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return #a.play < #b.play
  end)

  -- Deduplicate: keep only the best combo per hand type,
  -- but collect tied alternatives for display
  local seen = {}
  local top = {}
  for _, entry in ipairs(best) do
    if not seen[entry.name] then
      if #top >= 2 then break end
      seen[entry.name] = true
      entry.alts = {}
      top[#top + 1] = entry
    elseif top[#top].name == entry.name and entry.score == top[#top].score
      and #entry.play == #top[#top].play then
      -- Tied alternative for the same hand type and size
      local alts = top[#top].alts
      local label = cards_label(entry.cards)
      if not alts.seen_labels then alts.seen_labels = {} end
      if not alts.seen_labels[label] then
        alts.seen_labels[label] = true
        alts[#alts + 1] = entry
      end
    end
  end
  return top, { combos = combo_n, perm_branches = perm_branches, perms = perm_n }
end

local function analyze_hand(...)
  return with_no_resolve(analyze_hand_inner, ...)
end

-------------------------------------------------------------------------
-- JIT warmup.
--
-- The first F2 press of a session takes ~5x longer than subsequent
-- presses because LuaJIT hasn't yet compiled the combinatorial search
-- paths (combinations(), the per-size loop, the sort+dedup at the
-- end). Evaluate_play doesn't exercise those paths — it only scores
-- one combo — so playing a hand doesn't warm them up on its own.
--
-- schedule_warmup() queues a non-blocking deferred event that runs
-- analyze_hand() once, silently, so LuaJIT compiles the hot path
-- BEFORE the user actually presses F2. It's called from the
-- evaluate_play hook (on every play, but idempotent via warmed_up):
-- by the time the user presses F2 after their first play of the
-- session, the JIT is warm.
--
-- Guarded on G.E_MANAGER and Event existing — both are Balatro
-- globals that aren't defined at mod load time, so this function
-- no-ops until gameplay state is up. Also gated on G.hand.cards
-- being populated so the warmup runs against realistic data rather
-- than an empty hand.
-------------------------------------------------------------------------
local warmed_up = false
local function schedule_warmup()
  if warmed_up then return end
  if not (G and G.E_MANAGER and Event) then return end
  if not (G.hand and G.hand.cards and #G.hand.cards > 0) then return end
  G.E_MANAGER:add_event(Event({
    trigger   = 'after',
    delay     = 0.1,
    blockable = false,
    blocking  = false,
    func = function()
      if not warmed_up then
        pcall(analyze_hand)
        warmed_up = true
      end
      return true
    end,
  }))
end

-------------------------------------------------------------------------
-- F2 keybind: print the top 2 hands to the console
-------------------------------------------------------------------------
SMODS.Keybind({
  key_pressed = 'f2',
  action = function(self)
    local t0 = debug_timing and now_ms()
    local results, stats = analyze_hand()
    if debug_timing and t0 then
      print(string.format(
        '[BestHand][TIMING] F2 analyze_hand: %.2f ms  (%d combos, %d perm branches, %d perms)',
        now_ms() - t0,
        stats and stats.combos or 0,
        stats and stats.perm_branches or 0,
        stats and stats.perms or 0))
    end
    local n_in_hand = (G and G.hand and G.hand.cards) and #G.hand.cards or 0
    local blind_msg = describe_blind_restriction(n_in_hand)
    if not results or #results == 0 then
      -- Empty results usually means the active blind zeroes every combo
      -- (The Mouth locking out a hand type the user can't form, The Eye
      -- after every reachable type has been played, The Psychic with
      -- fewer than 5 cards). Stay silent only when there's no such
      -- restriction — otherwise explain why no play is recommended.
      if blind_msg then
        print('')
        print('')
        print('-- Best Hands --')
        print('No scoring play available. ' .. blind_msg)
      end
      return
    end
    local lines = {'', '', '-- Best Hands --'}
    if blind_msg then
      lines[#lines + 1] = '(' .. blind_msg .. ')'
    end
    -- Note when Splash makes all played cards score
    if G.jokers and G.jokers.cards then
      for _, joker in ipairs(G.jokers.cards) do
        if not joker.debuff and joker.ability
          and joker.ability.name == 'Splash' then
          lines[#lines + 1] = '(All cards score with Splash joker)'
          break
        end
      end
    end
    for i, r in ipairs(results) do
      -- Format: "1. Flush (Ah, Kh, Qh + 7h, 3h)  ~ 1234 points"
      -- r.cards holds the scoring cards in optimal play order.
      -- Fall back to r.play when r.cards is empty (shouldn't
      -- happen after the score>0 filter, but defensive either way).
      local play_str
      if #r.cards > 0 then
        play_str = cards_label(r.cards)
        if #r.play > #r.cards then
          play_str = play_str
            .. ' + ' .. cards_label_exclude(r.play, r.cards)
        end
      else
        play_str = cards_label(r.play)
      end
      local line = i .. '. ' .. r.name
        .. ' (' .. play_str .. ')     ~ '
        .. format_number(r.score) .. ' points'
      -- Mark scores that include expected-value approximations
      -- (Lucky Card enhancements, Bloodstone joker)
      if r.used_ev then line = line .. ' (expected value)' end
      -- Note when a non-default scoring order boosts the score.
      -- Also show what the default-order score would be so the
      -- user can compare. Without this, if the user plays the
      -- hand WITHOUT reordering, the live prediction comes in
      -- well below the F2 number and looks like a prediction bug.
      if r.optimal_order then
        line = line .. '  ← drag scoring cards into this order'
        if r.default_score and r.default_score < r.score then
          line = line .. ' (default order: ~'
            .. format_number(r.default_score) .. ')'
        end
        -- Two cards with identical rank/suit (e.g. two Kd) look the
        -- same in the play area, so "drag into this order" alone
        -- doesn't tell the player which one goes first. Spell out
        -- the order by enhancement / edition / seal.
        local dup_hint = describe_duplicate_order(r.cards)
        if dup_hint then
          line = line .. '\n     (' .. dup_hint .. ')'
        end
      end
      local rank_dup_hint = describe_rank_duplicates(r.name, r.cards)
      if rank_dup_hint then
        line = line .. '\n     (' .. rank_dup_hint .. ')'
      end
      -- Show tied alternatives if any
      if r.alts and #r.alts > 0 then
        local alt_labels = {}
        for _, alt in ipairs(r.alts) do
          alt_labels[#alt_labels + 1] = cards_label(alt.cards)
        end
        line = line .. '  (or '
          .. table.concat(alt_labels, ', or ') .. ')'
      end
      lines[#lines + 1] = line
    end
    for _, line in ipairs(lines) do print(line) end
  end
})

-------------------------------------------------------------------------
-- Fixture capture: hook G.FUNCS.evaluate_play to record every played
-- hand along with the score Balatro actually computed. These fixtures
-- are the oracle for offline regression tests — the game itself is the
-- ground truth, not hand-traced expected values.
--
-- Toggle with F4. Default: ON when .git/ is present (dev install),
-- OFF otherwise (released zip — end users opt in by pressing F4).
-- Captures go to
--   <save>/Mods/balatro-best-hand/best_hand_captures/capture_<timestamp>_<n>.lua
-- Each file is a Lua literal loadable with dofile():
--   return { played=..., held=..., jokers=..., game=...,
--            hand_name=..., predicted_score=..., actual_score=... }
--
-- State is snapshotted BEFORE calling the real evaluate_play so it
-- matches what F2 sees when you're about to play — any mismatch with
-- actual_score is a real prediction bug. This naturally surfaces the
-- pre-increment gotcha on jokers that read hands[name].played /
-- played_this_round (Supernova, Card Sharp), since the game bumps those
-- counters at the top of evaluate_play before scoring with them.
-------------------------------------------------------------------------

-- MOD_VERSION resolves to the git commit hash in dev installs (where
-- .git/HEAD is readable) and stays 'unknown' in released zips. We use
-- that as the dev-vs-release signal so end users don't accumulate
-- capture files they'll never look at.
local capture_enabled = (MOD_VERSION ~= 'unknown')
local capture_dir = 'Mods/balatro-best-hand/best_hand_captures'

-- Serialize a plain Lua value as a Lua literal. Not general-purpose:
-- assumes scalars + nested tables of scalars, no cycles, no functions.
local function serialize(v, indent)
  indent = indent or ''
  local t = type(v)
  if t == 'nil' then return 'nil' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then
    if v ~= v then return '(0/0)' end
    if v == math.huge then return 'math.huge' end
    if v == -math.huge then return '-math.huge' end
    -- Emit fractional values at full double precision (%.17g) so
    -- round-trip through the capture file preserves the exact bit
    -- pattern. Jokers like Constellation accumulate x_mult via
    -- repeated += 0.1, which drifts below the clean decimal value;
    -- the default tostring (%.14g) rounds that drift away and the
    -- offline replay then over-predicts by 1 at the final floor.
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return tostring(v)
    end
    return string.format('%.17g', v)
  end
  if t == 'string' then return string.format('%q', v) end
  if t ~= 'table' then return 'nil' end

  local inner = indent .. '  '
  local n, max_i = 0, 0
  for k, _ in pairs(v) do
    n = n + 1
    if type(k) == 'number' and k == math.floor(k) and k >= 1 then
      if k > max_i then max_i = k end
    end
  end
  if n == 0 then return '{}' end

  local parts = {'{'}
  if max_i == n then
    -- Array-style
    for i = 1, n do
      parts[#parts + 1] = inner .. serialize(v[i], inner) .. ','
    end
  else
    -- Hash-style, sorted by key for deterministic output
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local key_str
      if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
        key_str = k
      else
        key_str = '[' .. serialize(k, inner) .. ']'
      end
      parts[#parts + 1] = inner .. key_str
        .. ' = ' .. serialize(v[k], inner) .. ','
    end
  end
  parts[#parts + 1] = indent .. '}'
  return table.concat(parts, '\n')
end

-- Copy only scalar fields from a table. Used for ability.extra where
-- different jokers store different fields (chips, Xmult, mult, etc.)
local function copy_scalars(t)
  if type(t) ~= 'table' then return nil end
  local result, any = {}, false
  for k, val in pairs(t) do
    local vt = type(val)
    if vt == 'number' or vt == 'string' or vt == 'boolean' then
      result[k] = val
      any = true
    end
  end
  if not any then return nil end
  return result
end

local function extract_edition(edition)
  if not edition then return nil end
  return {
    foil = edition.foil,
    holo = edition.holo,
    polychrome = edition.polychrome,
    negative = edition.negative,
  }
end

local function extract_card(card)
  local base = card.base or {}
  local ability = card.ability or {}
  return {
    base = {
      id      = base.id,
      suit    = base.suit,
      nominal = base.nominal,
      value   = base.value,
    },
    ability = {
      name        = ability.name,
      perma_bonus = ability.perma_bonus,
      extra       = copy_scalars(ability.extra),
    },
    edition = extract_edition(card.edition),
    seal    = card.seal,
    debuff  = card.debuff or nil,
  }
end

local function extract_joker(joker)
  local ability = joker.ability or {}
  -- Capture rarity for Baseball Card (uncommon = 2 in Balatro).
  -- The rarity lives on the joker's center config, not ability.
  local rarity = nil
  if joker.config and joker.config.center and joker.config.center.rarity then
    rarity = joker.config.center.rarity
  end
  return {
    ability = {
      name        = ability.name,
      mult        = ability.mult,
      x_mult      = ability.x_mult,
      chips       = ability.chips,
      t_mult      = ability.t_mult,
      t_chips     = ability.t_chips,
      remaining   = ability.remaining,
      perma_bonus = ability.perma_bonus,
      extra       = copy_scalars(ability.extra),
      -- Per-joker accumulated state that joker_main / context.before
      -- read directly off self.ability. Nil for jokers that don't use
      -- the field, so the serializer drops them cleanly.
      driver_tally           = ability.driver_tally,
      caino_xmult            = ability.caino_xmult,
      yorick_discards        = ability.yorick_discards,
      invis_rounds           = ability.invis_rounds,
      to_do_poker_hand       = ability.to_do_poker_hand,
      hands_played_at_create = ability.hands_played_at_create,
    },
    edition = extract_edition(joker.edition),
    rarity  = rarity,
    debuff  = joker.debuff or nil,
  }
end

local function extract_card_list(list)
  local out = {}
  for i, c in ipairs(list) do out[i] = extract_card(c) end
  return out
end

local function extract_joker_list(list)
  local out = {}
  for i, j in ipairs(list) do out[i] = extract_joker(j) end
  return out
end

-- Snapshot the parts of G.GAME that score_combo consults.
local function extract_game_state()
  local game = {}

  if G.GAME and G.GAME.hands then
    game.hands = {}
    for name, info in pairs(G.GAME.hands) do
      game.hands[name] = {
        level             = info.level,
        chips             = info.chips,
        mult              = info.mult,
        l_chips           = info.l_chips,
        l_mult            = info.l_mult,
        played            = info.played,
        played_this_round = info.played_this_round,
        visible           = info.visible,
      }
    end
  end

  if G.GAME and G.GAME.current_round then
    local cr = G.GAME.current_round
    game.current_round = {
      hands_left    = cr.hands_left,
      hands_played  = cr.hands_played,
      discards_left = cr.discards_left,
      dollars       = cr.dollars,
    }
    if cr.ancient_card then
      game.current_round.ancient_card = { suit = cr.ancient_card.suit }
    end
    if cr.idol_card then
      game.current_round.idol_card = {
        id   = cr.idol_card.id,
        suit = cr.idol_card.suit,
        rank = cr.idol_card.rank,
      }
    end
  end

  game.dollars = G.GAME and G.GAME.dollars

  if G.GAME and G.GAME.blind then
    game.blind = {
      name     = G.GAME.blind.name,
      disabled = G.GAME.blind.disabled,
    }
  end

  if G.deck and G.deck.cards then
    game.deck_remaining = #G.deck.cards
  end

  -- Count Steel Cards across the full deck (G.playing_cards) so the
  -- offline harness can reconstruct the correct total for Steel Joker.
  if G.playing_cards then
    local steel_count = 0
    for _, c in ipairs(G.playing_cards) do
      if c.ability and c.ability.name == 'Steel Card' then
        steel_count = steel_count + 1
      end
    end
    game.steel_card_count = steel_count
  end

  return game
end

-- Compute the mod's predicted score for the exact hand being played.
-- Called with real Card objects, BEFORE Balatro mutates state.
-- prob_config / range_config (optional): see score_combo for semantics.
local function compute_predicted_score(played, held, prob_config, range_config)
  local all = {}
  for _, c in ipairs(played) do all[#all + 1] = c end
  for _, c in ipairs(held)   do all[#all + 1] = c end
  return with_no_resolve(
    score_combo, played, all, prob_config, range_config)
end

local function write_capture(fixture)
  if love and love.filesystem and love.filesystem.createDirectory then
    love.filesystem.createDirectory(capture_dir)
  end
  local base = love.filesystem.getSaveDirectory() .. '/' .. capture_dir
  local stamp = os.date('%Y%m%d_%H%M%S')
  local path
  for i = 1, 1000 do
    local try = base .. '/capture_' .. stamp .. '_' .. i .. '.lua'
    local f = io.open(try, 'r')
    if not f then
      path = try
      break
    end
    f:close()
  end
  if not path then
    print('[BestHand] capture write skipped: 1000 collisions at ' .. stamp)
    return
  end

  local f = io.open(path, 'w')
  if not f then
    print('[BestHand] failed to open capture file: ' .. path)
    return
  end
  f:write('-- BestHand capture fixture — auto-generated, safe to delete\n')
  f:write('return ' .. serialize(fixture) .. '\n')
  f:close()
  print('[BestHand] captured: ' .. path)
end

-- Wrap G.FUNCS.evaluate_play. Capture PRE-scoring so the fixture matches
-- what F2 would see just before playing; read the final score RIGHT AFTER
-- the original returns — the synchronous joker iteration has finished by
-- then, but the deferred chip-ease events haven't reset chip_total yet,
-- so SMODS.calculate_round_score() still has the true total.
if G.FUNCS and G.FUNCS.evaluate_play then
  local original_evaluate_play = G.FUNCS.evaluate_play
  G.FUNCS.evaluate_play = function(e)
    local fixture
    local t_start, t_single_done, prob_configs
    if capture_enabled then
      t_start = debug_timing and now_ms()
      local ok, err = pcall(function()
        local played, held = {}, {}
        for i, c in ipairs(G.play.cards) do played[i] = c end
        for i, c in ipairs(G.hand.cards) do held[i]   = c end

        fixture = {
          mod_version = MOD_VERSION,
          played = extract_card_list(played),
          held   = extract_card_list(held),
          jokers = extract_joker_list(G.jokers.cards),
          game   = extract_game_state(),
        }

        local hn = G.FUNCS.get_poker_hand_info(G.play.cards)
        fixture.hand_name = hn
        -- Must snapshot pre-evaluate_play: The Eye's check reads
        -- played_this_round, which Balatro increments during
        -- evaluate_play — a post-hook read would false-positive
        -- on every Eye play.
        fixture.debuffed_by_blind = is_hand_debuffed_by_blind(hn)

        local _, score, _, _, prob_arities, range_events =
          compute_predicted_score(played, held)
        fixture.predicted_score = score
        if debug_timing then t_single_done = now_ms() end
        prob_arities = prob_arities or {}
        range_events = range_events or {}
        local n_prob = #prob_arities

        -- Enumerate every reachable score from the discrete product of
        -- per-event outcomes (Lucky=3, Bloodstone=2) × each Misprint
        -- integer in [min, max]. Bounded at 10k configs.
        local range_total = 1
        for _, iv in ipairs(range_events) do
          range_total = range_total * (iv[2] - iv[1] + 1)
        end
        local prob_total = 1
        for _, a in ipairs(prob_arities) do prob_total = prob_total * a end
        local total_configs = prob_total * range_total
        prob_configs = total_configs

        if (n_prob + #range_events) > 0 and total_configs <= 10000 then
          local possible, seen = {}, {}
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
              local _, s = compute_predicted_score(
                played, held, pcfg, rcfg)
              if not seen[s] then
                seen[s] = true
                possible[#possible + 1] = s
              end
            end
          end
          table.sort(possible)
          fixture.possible_scores = possible
        end
      end)
      if not ok then
        print('[BestHand] capture pre-error: ' .. tostring(err))
      end
      if debug_timing and t_start then
        local t_end = now_ms()
        local t_single = (t_single_done or t_end) - t_start
        local t_prob = t_end - (t_single_done or t_end)
        print(string.format(
          '[BestHand][TIMING] evaluate_play predict: %.2f ms single + %.2f ms prob (%d configs)',
          t_single, t_prob, prob_configs or 0))
      end
    end

    original_evaluate_play(e)

    if fixture then
      local ok, err = pcall(function()
        fixture.actual_score = math.floor(SMODS.calculate_round_score())

        -- When the blind zeroes the hand (The Eye / The Mouth),
        -- Balatro's evaluate_play early-exits without touching
        -- chip_total, so SMODS.calculate_round_score() returns a
        -- stale prior value rather than 0. Skip the compare here —
        -- our predicted 0 is already correct.
        if fixture.debuffed_by_blind then
          print(string.format(
            '[BestHand] %s: debuffed by %s — skipping compare (actual_score unreliable)',
            tostring(fixture.hand_name or '?'),
            (G.GAME and G.GAME.blind and G.GAME.blind.name) or 'boss'))
          return
        end

        local matched = false
        if fixture.predicted_score then
          local actual = fixture.actual_score
          local possible = fixture.possible_scores
          local hn = tostring(fixture.hand_name or '?')

          matched = (actual == fixture.predicted_score)
          if not matched and possible then
            for _, s in ipairs(possible) do
              if s == actual then
                matched = true
                break
              end
            end
          end

          if not matched then
            local tag
            if possible then
              local closest = possible[1]
              for _, s in ipairs(possible) do
                if math.abs(s - actual) < math.abs(closest - actual) then
                  closest = s
                end
              end
              tag = string.format(
                'MISS (actual not in %d possible, closest %s off by %s)',
                #possible,
                format_number(closest),
                format_number(actual - closest))
            else
              local delta = actual - fixture.predicted_score
              tag = '(off by ' .. format_number(delta) .. ')'
            end
            print(string.format('[BestHand] %s: predicted %s, actual %s  %s',
              hn,
              format_number(fixture.predicted_score),
              format_number(actual),
              tag))
          end
        end

        if fixture.predicted_score and not matched then
          write_capture(fixture)
        end
      end)
      if not ok then
        print('[BestHand] capture post-error: ' .. tostring(err))
      end
    end

    -- Kick off the (one-time) JIT warmup. Idempotent; does nothing
    -- after the first successful run.
    schedule_warmup()
  end
end

SMODS.Keybind({
  key_pressed = 'f4',
  action = function(self)
    capture_enabled = not capture_enabled
    if capture_enabled then
      print('[BestHand] capture ENABLED — each played hand will be recorded')
    else
      print('[BestHand] capture disabled')
    end
  end
})

-- F5 is a dev diagnostic — only registered when running from a git
-- checkout. Released zips have MOD_VERSION == 'unknown'.
if MOD_VERSION ~= 'unknown' then
  SMODS.Keybind({
    key_pressed = 'f5',
    action = function(self)
      debug_timing = not debug_timing
      print('[BestHand] debug timing ' .. (debug_timing and 'ON' or 'off'))
    end
  })
end

-- F6 is a dev-only toggle for poking at the face-down behavior. End
-- users always run with respect_face_down=true (the default).
if MOD_VERSION ~= 'unknown' then
  SMODS.Keybind({
    key_pressed = 'f6',
    action = function(self)
      respect_face_down = not respect_face_down
      if respect_face_down then
        print('[BestHand] respecting face-down cards (default) — predictor will not peek at face-down cards')
      else
        print('[BestHand] face-down peeking ENABLED — predictor will read face-down cards')
      end
    end
  })
end
