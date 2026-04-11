# Best Hand Advisor

A Balatro mod that looks at your current hand and tells you which play will score the most points, accounting for your jokers, card enhancements, editions, seals, boss blind, and most of the state the game uses to score.

## Install

Requires [lovely-injector](https://github.com/ethangreen-dev/lovely-injector) and [Steamodded](https://github.com/Steamodded/smods).

Copy this folder into your Balatro mods directory:

- Windows: `%APPDATA%\Balatro\Mods\balatro-best-hand\`

## Keybinds

- **F2** — Print the top 3 scoring hands for your current hand to the console, with card combos and point totals. Tied alternatives are grouped; probabilistic scores (Lucky Card, Bloodstone) are labeled `(expected value)`.
- **F3** — Dump your first hand card, all your jokers, and `G.GAME.current_round` to `card_dump.txt` in your Balatro save directory. Useful for diagnosing unfamiliar ability fields when a prediction is off.
- **F4** — Toggle fixture capture (off by default). See below.

## What it handles

Most common jokers and interactions, including:

- Every card enhancement (Bonus, Mult, Glass, Steel, Stone, Lucky, Gold, Wild)
- Foil / Holo / Polychrome editions on cards and jokers
- Red Seal retriggers (and Mime / Hack / Sock and Buskin / Hanging Chad / Dusk / Seltzer)
- Blueprint and Brainstorm copy resolution, including chained Blueprints
- Held-in-hand effects: Steel Card (with editions), Baron, Shoot the Moon
- Four Fingers, Smeared Joker, Pareidolia, Splash
- Hand-type conditional jokers (Jolly / Zany / Mad / Crazy / Droll, Sly / Wily / Clever / Devious / Crafty, The Duo / Trio / Family / Order / Tribe)
- Per-round state jokers that stash data on `G.GAME.current_round` (Ancient Joker, The Idol)
- The Flint boss blind's base-score halving

The scoring pipeline mirrors Balatro's own phase order: per-card effects first, then held-in-hand, then flat joker effects.

## Known limitations

- **Probabilistic effects** (Lucky Card, Bloodstone) use expected value — your actual score will vary by RNG. Hands where these contributed are tagged `(expected value)` in the F2 output.
- **Boss blinds with hand restrictions** (The Mouth, The Eye, Verdant Leaf, etc.) are not detected — the mod will happily recommend a hand the boss will debuff to zero.
- Not every joker is implemented. Coverage skews toward the commonly-encountered ones. Unknown jokers contribute zero to the prediction, so the mod will under-score in that case.

## Fixture capture (regression harness)

Press **F4** in-game to start recording every hand you play. Each play writes a Lua literal to `<save>/best_hand_captures/capture_<timestamp>_<n>.lua` containing the played cards, held cards, jokers, relevant `G.GAME` state, the mod's predicted score, and the score Balatro actually computed. The console also prints a live diff (`predicted X, actual Y`) so you can spot drift as you play.

These captures are the oracle for verifying the mod against the real game — the game itself is the ground truth, not hand-traced expected values. When a capture shows a non-zero `predicted - actual` delta, that's a bug worth investigating.

Press F4 again to stop capturing.
