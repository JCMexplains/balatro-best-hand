# Best Hand Advisor

A Balatro mod that analyzes your current hand and recommends which play will score the most points, accounting for your jokers, card enhancements, editions, seals, boss blind, and most of the state the game uses to score.

## Install

Requires [lovely-injector](https://github.com/ethangreen-dev/lovely-injector) and [Steamodded](https://github.com/Steamodded/smods).

Copy this folder into your Balatro mods directory:

- Windows: `%APPDATA%\Balatro\Mods\balatro-best-hand\`

## Keybinds

- **F2** — Print the top 3 scoring hands to the console. Shows card combos, point totals, and — when an order-sensitive joker is active — the optimal left-to-right card arrangement to drag into before playing. Tied alternatives are grouped; probabilistic scores (Lucky Card, Bloodstone) are labeled `(expected value)`.
- **F3** — Dump your first hand card, all your jokers, and `G.GAME.current_round` to `card_dump.txt` in your Balatro save directory. Useful for diagnosing unfamiliar ability fields when a prediction is off.
- **F4** — Toggle fixture capture on/off (on by default). See below.
- **F5** — Toggle debug timing. When on, each F2 press logs `analyze_hand: N ms  (C combos, B perm branches, P perms)` and each played hand logs `evaluate_play predict: S ms single + P ms prob (N configs)`. Use this to pinpoint lag.

## What it handles

Most common jokers and interactions, including:

- Every card enhancement (Bonus, Mult, Glass, Steel, Stone, Lucky, Gold, Wild)
- Foil / Holo / Polychrome editions on cards and jokers
- Retrigger jokers: Red Seal, Mime, Hack, Sock and Buskin, Hanging Chad, Dusk, Seltzer
- Blueprint and Brainstorm copy resolution, including chained Blueprints
- Held-in-hand effects: Steel Card (with editions), Baron, Shoot the Moon
- Four Fingers, Smeared Joker, Pareidolia, Splash
- Hand-type conditional jokers (Jolly / Zany / Mad / Crazy / Droll, Sly / Wily / Clever / Devious / Crafty, The Duo / Trio / Family / Order / Tribe)
- Per-round state jokers that read from `G.GAME.current_round` (Ancient Joker, The Idol)
- Boss blinds: The Eye and The Mouth (hand debuff → score zeroed), The Psychic (must play exactly 5 cards), The Arm (level penalty applied to base chips/mult), The Flint (base chips and mult halved)
- **Card ordering advice**: when order matters — Hanging Chad, Photograph, Ancient Joker, Bloodstone, Triboulet, The Idol, or a card with Polychrome edition or Glass Card enhancement — F2 tries every permutation of the scoring cards and marks the best arrangement with `← drag scoring cards into this order`

The scoring pipeline mirrors Balatro's own phase order: per-card effects first (left to right, with retriggers), then held-in-hand effects, then flat joker effects.

## Known limitations

- **Probabilistic effects** (Lucky Card, Bloodstone) use expected value — your actual score will vary by random number generation. Hands where these contributed are tagged `(expected value)` in the F2 output.
- **Most boss blinds are not modeled.** The five listed above are handled; others (Verdant Leaf, The Needle, The Wall, etc.) are not — the mod will recommend hands as if there were no blind in effect.
- **Not every joker is implemented.** Coverage skews toward commonly-encountered ones. Unknown jokers contribute zero to the prediction, so the mod will under-score in that case.

## Fixture capture (regression harness)

Fixture capture is **on by default**. Every hand you play is compared against the game's actual result; when the predicted and actual scores differ, the hand is written to `<mod>/best_hand_captures/capture_<timestamp>_<n>.lua` (inside this mod's own directory). The console always prints a live `predicted X, actual Y` line so you can spot drift as you play.

Each capture file is a Lua literal containing the played cards, held cards, jokers, relevant `G.GAME` state, the mod's predicted score, and the score Balatro actually computed. It is loadable with `dofile()` and replayable offline.

Press **F4** to disable capture (or to re-enable it after disabling).

### Offline tools

Both tools run from the mod directory with the Lua 5.1 interpreter.

**`batch_verify.lua`** — replay every capture in a directory through `score_combo`, enumerate all probabilistic outcomes (Lucky Card / Bloodstone booleans × Misprint integer ranges), and report `ok` / `ok(var)` / `MISS` for each.

```
lua batch_verify.lua [path/to/captures_dir]
```

**`trace_one.lua`** — load a single capture and replay it with a full phase-by-phase trace (per-card, held-in-hand, flat jokers). Use this to investigate a specific miss.

```
lua trace_one.lua path/to/capture.lua
```
