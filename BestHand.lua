-------------------------------------------------------------------------
-- BestHand.lua — Balatro mod that analyzes your hand and recommends
-- the highest-scoring play.
--
-- Keybinds:
--   F2  Evaluate the current hand: print the top 3 scoring plays,
--       card combos, estimated points, and (when order matters) the
--       optimal left-to-right card arrangement to drag into before
--       playing.
--   F3  Dump the first hand card + all jokers + G.GAME.current_round
--       to card_dump.txt in the Balatro save directory.
--   F4  Toggle fixture capture on/off (on by default — see bottom of
--       this file for the regression harness).
--   F5  Toggle debug timing: log wall-clock for the F2 search and
--       the per-play prediction/enumeration to the game console.
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
-- probabilistic enumeration. Toggled at runtime by the F5 keybind
-- (registered near the bottom of this file). Declared up here so
-- every handler below — including F2 — captures it as an upvalue.
-------------------------------------------------------------------------
local debug_timing = false
local function now_ms()
  return (love and love.timer and love.timer.getTime() or os.clock()) * 1000
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
-- Hybrid scoring deny list: jokers whose real calculate_joker must NOT
-- be called during analysis. Misprint's calculate_joker calls
-- pseudorandom() which advances the RNG seed; we enumerate its range
-- via state.range_config instead (see eval_flat_jokers below).
-------------------------------------------------------------------------
local joker_main_deny = {
  ['Misprint'] = true,
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
-- Paired suits for Smeared Joker: Hearts<->Diamonds, Spades<->Clubs.
-- Defined early because suit_matches, count_suits, and get_flush_members
-- all need it.
-------------------------------------------------------------------------
local smeared_pair = {
  Hearts = 'Diamonds', Diamonds = 'Hearts',
  Spades = 'Clubs',    Clubs = 'Spades',
}

local function has_smeared_joker()
  if not G.jokers or not G.jokers.cards then return false end
  for _, joker in ipairs(G.jokers.cards) do
    if not joker.debuff and joker.ability
      and joker.ability.name == 'Smeared Joker' then
      return true
    end
  end
  return false
end

-------------------------------------------------------------------------
-- suit_matches: does this card count as `target_suit`?
-- Wild Cards match every suit. Smeared Joker merges Hearts+Diamonds
-- and Spades+Clubs into virtual suits, so a Diamond card counts as
-- Hearts (and vice versa), and a Club card counts as Spades.
-------------------------------------------------------------------------
local function suit_matches(card, target_suit)
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
  local suits = {'Hearts', 'Diamonds', 'Clubs', 'Spades'}
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
  -- If the full combo is already a straight, every card participates.
  -- Without this check Four Fingers breaks 5-card straights: removing
  -- any single card leaves a 4-card subset that still registers as a
  -- straight, so the kicker-detection loop below would incorrectly
  -- drop a valid scoring card.
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

  if not is_held then
    -- Retrigger jokers for played/scoring cards
    for _, name in ipairs(joker_names) do
      if name == 'Hack' then
        -- +1 retrigger for cards ranked 2, 3, 4, or 5
        local id = card.base.id
        if id >= 2 and id <= 5 then triggers = triggers + 1 end
      elseif name == 'Sock and Buskin' then
        -- +1 retrigger for face cards (J=11, Q=12, K=13).
        -- Pareidolia makes every card count as face.
        local is_face = pareidolia
          or (card.base.id >= 11 and card.base.id <= 13)
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
-- Determine which cards actually score for a given hand type.
-- Kicker cards (e.g. the 5th card in Two Pair) do NOT score,
-- UNLESS they have Stone Card enhancement (Stone Cards always score).
-- When the Splash joker is present, ALL played cards score.
-- Returns cards in their original hand order (left to right).
-------------------------------------------------------------------------
local function get_scoring_cards(cards, hand_name)
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
    else -- Straight Flush / Royal Flush: check flush first, then straight
      members = get_flush_members(cards)
      if #members >= #cards then
        members = get_straight_members(cards)
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

  -- Splash joker: all played cards score regardless of hand type
  if G.jokers and G.jokers.cards then
    for _, joker in ipairs(G.jokers.cards) do
      if not joker.debuff and joker.ability
        and joker.ability.name == 'Splash' then
        return cards
      end
    end
  end

  -- Group cards by rank id to identify the hand's core groups
  local by_rank = {}
  for _, card in ipairs(cards) do
    local id = card.base.id
    if not by_rank[id] then by_rank[id] = {} end
    by_rank[id][#by_rank[id] + 1] = card
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
    -- Only the highest-ranked card scores
    local best = nil
    for _, card in ipairs(cards) do
      if not best or card.base.id > best.base.id then best = card end
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
  local has_baseball_card = false
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
      has_baseball_card = true
    end
  end
  return {
    resolved          = resolved,
    pareidolia        = pareidolia,
    hiker_add         = hiker_count * 5,
    has_baron         = has_baron,
    baron_count       = baron_count,
    has_shoot_moon    = has_shoot_moon,
    shoot_moon_count  = shoot_moon_count,
    has_baseball_card = has_baseball_card,
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

local function edition_multiplicative(edition, chips, mult)
  if edition and edition.polychrome then
    mult = mult * 1.5
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
  cards, scoring, hand_name, poker_hands
)
  local jokers = G.jokers and G.jokers.cards or {}

  for idx, joker in ipairs(jokers) do
    if not joker.debuff and joker.ability then
      local name = joker.ability.name or ''
      local effect = nil

      if joker.calculate_joker
        and not per_card_deny[name]
        and not joker_main_deny[name]
        and poker_hands then
        local saved = snapshot_ability(joker.ability)
        effect = joker:calculate_joker({
          individual   = true,
          cardarea     = G.play,
          other_card   = card,
          full_hand    = cards,
          scoring_hand = scoring,
          scoring_name = hand_name,
          poker_hands  = poker_hands,
        })
        joker.ability = saved
      end

      if effect then
        chips = chips + (effect.chips or 0)
        mult  = mult  + (effect.mult or 0)
        if effect.x_mult then mult = mult * effect.x_mult end
      else
        -- Hardcoded fallback: only Bloodstone contributes here. Other
        -- deny-listed jokers (8 Ball, Business Card, Golden Ticket,
        -- Rough Gem, Hiker, Lucky Cat, Wee Joker) either have their
        -- contribution handled elsewhere or don't affect score in EV.
        local target = resolve_copy_target(jokers, idx, {}) or joker.ability
        if target.name == 'Bloodstone' then
          if suit_matches(card, 'Hearts') then
            state.prob_idx = state.prob_idx + 1
            if state.prob_config then
              if state.prob_config[state.prob_idx] then
                mult = mult * 1.5
              end
            else
              mult = mult * 1.25
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
  for _, joker in ipairs(G.jokers.cards) do
    local name = joker.ability and joker.ability.name or ''
    if not joker.debuff and joker.calculate_joker
      and not before_deny[name]
      and not joker_main_deny[name] then
      snapshots[joker] = snapshot_ability(joker.ability)
      pcall(joker.calculate_joker, joker, {
        before       = true,
        cardarea     = G.jokers,
        full_hand    = cards,
        scoring_hand = scoring,
        scoring_name = hand_name,
        poker_hands  = poker_hands,
      })
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
-- prob_config (optional) pins each boolean probabilistic roll to a specific
-- outcome — an array one-per-event of Lucky Card / Bloodstone fires, true =
-- hit, anything else = miss. Default: use EV and flip used_ev.
-- range_config (optional) pins each range-valued probabilistic event (e.g.
-- Misprint, which rolls a random integer mult in [min, max]) to a specific
-- integer. Default: use the midpoint. F4 enumerates every integer value to
-- get the exact discrete set of possible scores.
-- Returns: hand_name, score, scoring_cards, used_ev, prob_count, range_events.
-- range_events is an array of {lo, hi} bounds, one per range fire, so a
-- caller can iterate the cartesian product to enumerate all outcomes.
-------------------------------------------------------------------------
local function score_combo(cards, all_cards, prob_config, range_config, precomputed)
  -- Identify the poker hand type and look up base chips/mult from level.
  -- Also capture poker_hands (the sub-hand containment table the game builds)
  -- because the hybrid joker path passes it to real calculate_joker calls
  -- for jokers that check "does this hand contain a Pair?" etc.
  -- get_poker_hand_info returns (hand_name, display_name, poker_hands_table);
  -- skip the display_name with _ to get the table in the 3rd slot.
  local hand_name, _, poker_hands = G.FUNCS.get_poker_hand_info(cards)
  if not hand_name then return nil, 0 end

  -- With Four Fingers, Balatro may detect Straight Flush / Royal Flush
  -- when the flush subset and straight subset don't overlap (e.g. 4
  -- suited cards + 1 off-suit card that completes the straight).  Reject
  -- these so the individual Flush / Straight combos are recommended.
  if hand_name == 'Straight Flush' or hand_name == 'Royal Flush' then
    local flush_cards = get_flush_members(cards)
    if #flush_cards < #cards then
      local sub_name = G.FUNCS.get_poker_hand_info(flush_cards)
      if sub_name ~= 'Straight Flush' and sub_name ~= 'Royal Flush' then
        return nil, 0
      end
    end
  end

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

  -- context.before pre-pass: scaling jokers bump their ability.* here.
  -- Must be restored before return so the next combo iteration sees
  -- the same pre-hand state.
  local before_snapshots = run_before_pass(cards, scoring, hand_name, poker_hands)

  -- Unpack per-F2 invariants. analyze_hand's combo loop builds these
  -- once and passes them in; single-shot callers get a lazy build.
  -- Everything here (resolved list, Pareidolia, Hiker, Baron, Shoot
  -- the Moon, Baseball Card) depends only on the joker list, not on
  -- which scoring subset we're evaluating.
  precomputed = precomputed or build_combo_precomputed(resolve_jokers())
  local resolved          = precomputed.resolved
  local pareidolia        = precomputed.pareidolia
  local hiker_add         = precomputed.hiker_add
  local has_baron         = precomputed.has_baron
  local baron_count       = precomputed.baron_count
  local has_shoot_moon    = precomputed.has_shoot_moon
  local shoot_moon_count  = precomputed.shoot_moon_count
  local has_baseball_card = precomputed.has_baseball_card

  -- Cross-card state for per-card joker effects.
  -- used_ev gets flipped true whenever a probabilistic effect (Lucky Card,
  -- Bloodstone) contributes to the score in EV mode, so the F2 output can
  -- label the result as an expected value.
  -- prob_idx is the running count of probabilistic events consumed; F4
  -- reads the final value to size its enumeration loop. prob_config is
  -- the caller-supplied outcome pin (nil in F2 / EV mode).
  local state = {
    photo_card = nil, used_ev = false,
    prob_idx = 0, prob_config = prob_config,
    range_idx = 0, range_config = range_config,
    range_events = {},
  }

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
  local scoring_dollars = 0
  for idx, card in ipairs(scoring) do
    if not card.debuff then
      local triggers = get_triggers(card, idx, false, pareidolia, resolved)
      if card.seal == 'Gold' then
        scoring_dollars = scoring_dollars + 3 * triggers
      end
      local hiker_accum = 0  -- accumulated perma_bonus from Hiker for this card
      for trig = 1, triggers do
        -- Base chip value from card rank (Stone Cards have nominal=0)
        chips = chips + (card.base.nominal or 0)

        -- Card enhancement bonuses
        local ability = card.ability
        if ability then
          local ename = ability.name
          -- Balatro stores these enhancement names WITHOUT the
          -- "Card" suffix (confirmed from captured fixtures):
          -- "Bonus", "Mult" — but "Glass Card", "Steel Card",
          -- "Lucky Card" etc. DO carry the suffix. Inconsistent
          -- naming in the game data.
          if ename == 'Bonus' then
            chips = chips + 30
          elseif ename == 'Mult' then
            mult = mult + 4
          elseif ename == 'Glass Card' then
            mult = mult * 2
          elseif ename == 'Stone Card' then
            chips = chips + 50
          elseif ename == 'Lucky Card' then
            -- 1/5 chance of +20 mult. EV mode: +4 average.
            -- Exact mode: consume the next prob_config slot.
            state.prob_idx = state.prob_idx + 1
            if state.prob_config then
              if state.prob_config[state.prob_idx] then
                mult = mult + 20
              end
            else
              mult = mult + 4
              state.used_ev = true
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

        -- Per-card joker effects for this card
        chips, mult = eval_per_card_jokers(
          card, resolved, chips, mult, state, pareidolia,
          cards, scoring, hand_name, poker_hands
        )

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

  -- has_baron / baron_count / has_shoot_moon / shoot_moon_count are
  -- all read from `precomputed` — same reason Hiker is hoisted.
  local function apply_held_effects(card)
    if card.debuff then return end
    local is_steel = card.ability and card.ability.name == 'Steel Card'
    local is_king = card.base.id == 13
    local is_queen = card.base.id == 12
    if not (is_steel or (has_baron and is_king)
      or (has_shoot_moon and is_queen)) then return end
    local triggers = get_triggers(card, 0, true, pareidolia, resolved)
    for _ = 1, triggers do
      -- Steel Card enhancement: x1.5 mult per trigger.
      -- Card editions do NOT fire for held-in-hand effects;
      -- they only fire in Phase 1 for scored cards.
      if is_steel then
        mult = mult * 1.5
      end
      -- Baron: x1.5 mult per held King, per Baron instance
      if has_baron and is_king then
        for _ = 1, baron_count do
          mult = mult * 1.5
        end
      end
      -- Shoot the Moon: +13 mult per held Queen, per instance
      if has_shoot_moon and is_queen then
        mult = mult + 13 * shoot_moon_count
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
      if joker.calculate_joker
        and not joker_main_deny[name]
        and poker_hands then
        local saved = snapshot_ability(joker.ability)
        effect = joker:calculate_joker({
          joker_main   = true,
          full_hand    = cards,
          scoring_hand = scoring,
          scoring_name = hand_name,
          poker_hands  = poker_hands,
          cardarea     = G.jokers,
        })
        -- Restore ability even if calculate_joker errored or
        -- mutated — the snapshot is our safety net.
        joker.ability = saved

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
        if effect.Xmult_mod then mult = mult * effect.Xmult_mod end
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
      ---------------------------------------------------------
      local rarity = joker.rarity
        or (joker.config and joker.config.center
          and joker.config.center.rarity)
      if has_baseball_card and rarity == 2 then
        mult = mult * 1.5
      end

      ---------------------------------------------------------
      -- Context-specific pre-increment correction: Wee Joker
      -- updates self.ability.extra.chips in context.individual
      -- (per scored 2), not context.before. We don't mirror the
      -- individual-context loop, so add the delta here. Retriggers
      -- (Seltzer, Hack, Red Seal, etc.) on a 2 scale it per trigger.
      ---------------------------------------------------------
      if name == 'Wee Joker' then
        local ability = joker.ability or {}
        local extra = ability.extra
        if type(extra) ~= 'table' then extra = {} end
        local twos_triggers = 0
        for idx, c in ipairs(scoring) do
          if c.base.id == 2 then
            twos_triggers = twos_triggers
              + get_triggers(c, idx, false, pareidolia, resolved)
          end
        end
        chips = chips + (extra.chip_mod or 8) * twos_triggers
      end
    end
  end

  -- Roll back the before-pass mutations so the next combo (and any
  -- external reader of joker.ability.*) sees the original state.
  restore_before_pass(before_snapshots)

  -- Balatro floors the final score to an integer; mirror that so
  -- polychrome/holo chains producing fractional intermediates match.
  return hand_name, math.floor(chips * mult), scoring,
    state.used_ev, state.prob_idx, state.range_events
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
-- Analyze the current hand: try every possible combo (sizes 5→1),
-- score each one, and return the top 3 distinct hand types.
-------------------------------------------------------------------------
local function analyze_hand()
  if not G or not G.hand or not G.hand.cards then return nil end
  local cards = G.hand.cards
  if #cards == 0 then return nil end

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
          score_combo(combo, cards, nil, nil, precomputed)
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
                score_combo(reordered, cards, nil, nil, precomputed)
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
      if #top >= 3 then break end
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
-- F2 keybind: print the top 3 hands to the console
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
    if not results or #results == 0 then return end
    local lines = {'', '', '', '-- Best Hands --'}
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
-- F3 keybind: dump all card and joker properties to a file for debugging
-------------------------------------------------------------------------
SMODS.Keybind({
  key_pressed = 'f3',
  action = function(self)
    local out = {}
    local card = G.hand and G.hand.cards and G.hand.cards[1]
    local function dump(t, prefix, depth)
      if depth > 4 or type(t) ~= 'table' then return end
      for k, v in pairs(t) do
        local key = prefix .. '.' .. tostring(k)
        if type(v) == 'table' then
          dump(v, key, depth + 1)
        else
          out[#out + 1] = key .. ' = ' .. tostring(v)
        end
      end
    end
    if card then
      dump(card, 'card', 0)
    else
      print('F3: no hand to dump — press F3 during a round, while cards are in your hand')
      return
    end
    if G.jokers and G.jokers.cards then
      for i, joker in ipairs(G.jokers.cards) do
        dump(joker, 'joker[' .. i .. ']', 0)
      end
    end
    -- Dump G.GAME.current_round so we can find where Balatro stores
    -- per-round joker state (e.g. Ancient Joker's chosen suit lives
    -- on current_round.ancient_card, The Idol's target on idol_card)
    if G.GAME and G.GAME.current_round then
      dump(G.GAME.current_round, 'current_round', 0)
    end
    table.sort(out)
    local path = love.filesystem.getSaveDirectory() .. '/card_dump.txt'
    local f = io.open(path, 'w')
    for _, line in ipairs(out) do f:write(line .. '\n') end
    f:close()
    print('Written to ' .. path)
  end
})

-------------------------------------------------------------------------
-- Fixture capture: hook G.FUNCS.evaluate_play to record every played
-- hand along with the score Balatro actually computed. These fixtures
-- are the oracle for offline regression tests — the game itself is the
-- ground truth, not hand-traced expected values.
--
-- Toggle with F4 (on by default). Captures go to
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

local capture_enabled = true
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
  return score_combo(played, all, prob_config, range_config)
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
  if not path then return end

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

        local _, score, _, _, n_prob, range_events =
          compute_predicted_score(played, held)
        fixture.predicted_score = score
        if debug_timing then t_single_done = now_ms() end
        n_prob = n_prob or 0
        range_events = range_events or {}

        -- Enumerate every reachable score from the discrete
        -- product of (Lucky/Bloodstone booleans) × (each Misprint
        -- integer in its [min, max]). Bounded at 10k configs so
        -- 1-2 Misprints + ≤10 boolean fires stays fast.
        local range_total = 1
        for _, iv in ipairs(range_events) do
          range_total = range_total * (iv[2] - iv[1] + 1)
        end
        local total_configs = (2 ^ n_prob) * range_total
        prob_configs = total_configs

        if (n_prob + #range_events) > 0 and n_prob <= 10
          and total_configs <= 10000 then
          local possible, seen = {}, {}
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

          local tag
          if matched then
            tag = possible
              and ('MATCH (1 of ' .. #possible .. ' possible)')
              or 'MATCH'
          elseif possible then
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

SMODS.Keybind({
  key_pressed = 'f5',
  action = function(self)
    debug_timing = not debug_timing
    print('[BestHand] debug timing ' .. (debug_timing and 'ON' or 'off'))
  end
})
