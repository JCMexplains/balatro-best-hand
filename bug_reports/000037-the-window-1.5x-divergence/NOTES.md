# 000037 — The Window blind, predicted 210 vs actual 315

**Status:** candidate. Not yet reduced. Do not file.

## Numbers

| | Score |
| --- | --- |
| BestHand `H.mod_score` (offline) | 210 |
| Vanilla `H.oracle_score` (offline `evaluate_play`) | 210 |
| Live game `actual_score` (in `capture.lua`) | 315 |

Ratio 315 / 210 = **1.5x**. Looks like a polychrome we can't see, but the fixture's joker editions and card editions don't include one.

## State at a glance

- **Played:** Ts (single card, High Card)
- **Held:** 2h, Kc, Qc, 9c, 5c, 8d, 5d, 4d (8d/5d/4d marked `debuff = true` from The Window)
- **Jokers:** Delayed Gratification, Riff-raff, Egg (holo edition), Green Joker (mult=2 pre-bump), Juggler
- **Blind:** The Window — `debuff = {suit = 'Diamonds'}`. The played card is Spades, so the blind shouldn't directly touch the score.
- **mod_version:** `476ea9b`

## Math we trust

- High Card base 5/1 + Ts (10 chips) = 15 chips, 1 mult
- Egg holo edition: +10 mult
- Green Joker post-bump (1 + 2 → 3): +3 mult
- Total: 15 × (1 + 10 + 3) = **15 × 14 = 210**, matching both mod and oracle

## Where the extra 105 could come from

- Polychrome anywhere = ×1.5 → 315. None recorded in the fixture.
- mult = 21 (= 14 + 7) with chips = 15 → 315. No source for +7 mult.
- chips = 21 (= 15 + 6) with mult = 15 (= 14 + 1) → 315. No source for either delta.

## Ruled out

- Editions extracted correctly (verified `extract_edition` reads `foil/holo/polychrome/negative`)
- No Steel cards in held (`steel_card_count = 0`)
- Riff-raff / Delayed Gratification / Juggler don't fire on play (vanilla `card.lua`)
- Egg's `context.individual` only bumps sell value, no chip/mult effect
- Card Sharp / Supernova fixes from `ae1d10a` don't apply (jokers not in the loadout)

## Capture predates the actual_chips/actual_mult diagnostic

`ae1d10a` adds `fixture.actual_chips` / `fixture.actual_mult` to the capture wrapper. **This fixture was captured before that landed**, so we can't tell whether `chips × mult ≠ actual_score` (= wrapper read stale) or `chips × mult = actual_score` (= unmodeled scoring source inflated chips/mult).

## Reduction plan

1. **Reproduce on HEAD** in a live game with the same loadout to get a fresh capture that includes `actual_chips`/`actual_mult`. That alone splits the diagnosis.
2. If reproduces: peel jokers one at a time and rerun. The minimal joker set that still hits 1.5x is the report.
3. Try without The Window (set the blind to Small/Big in a fresh capture). If divergence disappears, blame goes to The Window's interaction; if it persists, blame is elsewhere.
4. Check `G.GAME.tags` and any modifier state we don't extract — could be a Polychrome Tag we silently dropped.

## Capture (also in `capture.lua`)

Original path: `best_hand_captures/capture_20260505_000037_1.lua`.
