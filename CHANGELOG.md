# Changelog

## 1.0.4 — 2026-05-04

(1.0.3 was tagged but never shipped — `BestHand.json` was not bumped, so `release.ps1` failed in CI. 1.0.4 contains the same fixes plus the version bump.)

- Fix Lucky Card's 1/15 dollars roll not bumping Lucky Cat — `prob_config` now enumerates that outcome (3 per Lucky card: none / mult / dollars-only) and the EV `lucky_trigger` rate is corrected from 1/5 to 19/75.
- Fix Wee Joker over-counting on debuffed 2s (e.g. The Pillar).
- Enumerate Space Joker's 1/4 hand-level upgrade as a probabilistic event instead of defaulting to no-upgrade.

## 1.0.2 — 2026-05-03

- Fix Blueprint (and Brainstorm) copying Baseball Card not contributing the second X1.5 mult per Uncommon joker — vanilla fires Baseball Card's `context.other_joker` reaction once for the real card and once for each copy.
- Fix Bootstraps (and Bull) reading stale `G.GAME.dollars` during analysis — vanilla `get_p_dollars` bumps `dollar_buffer` for Gold seals during the per-card phase, so the Phase-3 joker loop now mirrors that bump using the already-tracked `scoring_dollars`.

## 1.0.1 — 2026-05-01

- Removed dev-only debug keybinds (F5 timing, F6 face-down toggle) from the user README. They remain registered in dev installs only and are not part of the released mod.

## 1.0.0 — 2026-05-01

Initial release.

### Hand analysis
- **F2** — enumerates all k-subsets of the current hand and prints the top 2 scoring plays with point totals and card combos.
- Order-sensitive jokers (Hanging Chad, Photograph, Ancient Joker, Bloodstone, Triboulet, The Idol, Polychrome / Glass cards) trigger an exhaustive permutation search; the optimal left-to-right order is highlighted.
- Probabilistic jokers (Lucky Card, Bloodstone) contribute by expected value.
- **F6** — ignore face-down cards (on by default). Cards flipped by The Wheel, The House, The Mark, and The Fish are excluded from analysis and held-in-hand effects.

### Scoring fidelity
- Three-phase pipeline dispatched through Balatro's own `Card:calculate_joker` (`context.before` → per-card → `context.joker_main`), so each joker scores with the same code the game runs.
- Boss blinds modeled: The Eye, The Mouth, The Psychic, The Arm, The Flint.
- Held-in-hand effects: Steel Card, Baron, Shoot the Moon, with Mime / Red Seal retriggers.
- Blueprint and Brainstorm copy resolution including chained Blueprints.
- Four Fingers, Smeared Joker, Pareidolia, Splash, Shortcut.

### Diagnostics
- **F4** — fixture capture (off by default in released zips). Each played hand is compared against the game's actual score; mismatches are written to `best_hand_captures/` for offline regression.
- **F5** — debug timing for the F2 search and per-play prediction.
