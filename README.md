# Best Hand Advisor

A Balatro mod that analyzes your current hand and recommends which play will score the most points, accounting for your jokers, card enhancements, editions, seals, boss blind, and most of the state the game uses to score.

## Install

Requires [lovely-injector](https://github.com/ethangreen-dev/lovely-injector) and [Steamodded](https://github.com/Steamodded/smods).

Copy this folder into your Balatro mods directory:

- Windows: `%APPDATA%\Balatro\Mods\balatro-best-hand\`

## Keybinds

- **F2** — Print the top 2 scoring hands to the console. Shows card combos, point totals, and — when an order-sensitive joker is active — the optimal left-to-right card arrangement to drag into before playing. Tied alternatives are grouped; probabilistic scores (Lucky Card, Bloodstone) are labeled `(expected value)`.
- **F4** — Toggle fixture capture on/off (on by default). See below.
- **F5** — Toggle debug timing. When on, each F2 press logs `analyze_hand: N ms  (C combos, B perm branches, P perms)` and each played hand logs `evaluate_play predict: S ms single + P ms prob (N configs)`. Use this to pinpoint lag.

## What it handles

Scoring dispatch goes through Balatro's own `Card:calculate_joker` on every joker, in every phase (`context.before`, `context.individual`, `context.joker_main`), so each joker scores with the same code the game runs. Explicit handling layers on top for:

- Every card enhancement (Bonus, Mult, Glass, Steel, Stone, Lucky, Gold, Wild)
- Foil / Holo / Polychrome editions on cards and jokers (with Balatro's exact composition order: additive before the joker's Xmult, polychrome after)
- Retrigger jokers: Red Seal, Mime, Hack, Sock and Buskin, Hanging Chad, Dusk, Seltzer
- Blueprint and Brainstorm copy resolution, including chained Blueprints
- Held-in-hand effects: Steel Card (with editions), Baron, Shoot the Moon
- Four Fingers, Smeared Joker, Pareidolia, Splash
- `context.before` pre-pass mirrors Balatro's own (state_events.lua:628): scaling jokers (Green Joker, Spare Trousers, Ride the Bus, Square Joker, Runner, Obelisk, Hologram, Madness, Glass Joker, etc.) get their `ability.*` bumped before `joker_main` reads. Destructive before-context side effects (DNA, Vampire, Midas Mask, To Do List, Space Joker) are skipped
- Per-round state jokers that read from `G.GAME.current_round` (Ancient Joker, The Idol)
- Boss blinds: The Eye and The Mouth (hand debuff → score zeroed), The Psychic (must play exactly 5 cards), The Arm (level penalty applied to base chips/mult), The Flint (base chips and mult halved)
- **Card ordering advice**: when order matters — Hanging Chad, Photograph, Ancient Joker, Bloodstone, Triboulet, The Idol, or a card with Polychrome edition or Glass Card enhancement — F2 tries every permutation of the scoring cards and marks the best arrangement with `← drag scoring cards into this order`

The scoring pipeline mirrors Balatro's own phase order: `before` pre-pass, then per-card effects (left to right, with retriggers), then held-in-hand effects, then flat joker effects with their edition bonuses.

## Known limitations

- **Probabilistic effects** (Lucky Card, Bloodstone) use expected value in the primary prediction. Bloodstone's real `calculate_joker` calls `pseudorandom()` directly, which can't resolve to an EV from inside the real dispatch — in EV mode it's computed separately (×1.25 per Heart, the expected value of a 50% ×1.5). F4 captures still enumerate all probabilistic outcomes to find the actual one. Hands where EV contributed are tagged `(expected value)` in the F2 output.
- **Most boss blinds are not modeled.** The five listed above are handled; others (Verdant Leaf, The Needle, The Wall, etc.) are not — the mod will recommend hands as if there were no blind in effect.

## Fixture capture (regression harness)

Fixture capture is **on by default**. Every hand you play is compared against the game's actual result; when the predicted and actual scores differ, the hand is written to `<mod>/best_hand_captures/capture_<timestamp>_<n>.lua` (inside this mod's own directory). On a miss, the console prints a `predicted X, actual Y` line with how far off the prediction was — silence means the prediction matched.

Each capture file is a Lua literal containing the played cards, held cards, jokers, relevant `G.GAME` state, the mod's predicted score, and the score Balatro actually computed. It is loadable with `dofile()` and replayable offline.

Press **F4** to disable capture (or to re-enable it after disabling).

### Offline tools

Both tools run from the mod directory with the Lua 5.1 interpreter and require `balatro_src/` to be present (a local extraction of Balatro's Lua source, gitignored and not shipped with this mod — drop it in if you want to run the tools).

**Only run these tools on capture files you produced yourself.** Captures are Lua source and are loaded with `dofile` / `loadstring`, so an untrusted capture can execute arbitrary code on your machine.

**`batch_verify.lua`** — replay every capture in a directory through `score_combo`, enumerate all probabilistic outcomes (Lucky Card / Bloodstone booleans × Misprint integer ranges), and report `ok` / `ok(var)` / `MISS` for each. Captured jokers are rehydrated with the `Card` metatable so scoring runs through the real `Card:calculate_joker` from `balatro_src/card.lua` — the same code the game uses in-engine.

```
lua batch_verify.lua [path/to/captures_dir]
```

**`trace_one.lua`** — load a single capture, print inputs (played / held / jokers with editions), replay through `score_combo`, and report whether the prediction matches the actual. Use this to investigate a specific miss.

```
lua trace_one.lua path/to/capture.lua
```

## License

MIT — see [LICENSE](LICENSE).
