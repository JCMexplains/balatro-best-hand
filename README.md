# Best Hand Advisor

A Balatro mod that analyzes your current hand and recommends which play will score the most points, accounting for your jokers, card enhancements, editions, seals, boss blind, and most of the state the game uses to score.

## Install

Requires [lovely-injector](https://github.com/ethangreen-dev/lovely-injector) and [Steamodded](https://github.com/Steamodded/smods).

Copy this folder into your Balatro mods directory:

- Windows: `%APPDATA%\Balatro\Mods\balatro-best-hand\`

## Keybinds

- **F2** — Print the top 2 scoring hands to the console. Shows card combos, point totals, and — when an order-sensitive joker is active — the optimal left-to-right card arrangement to drag into before playing. Tied alternatives are grouped; probabilistic scores (Lucky Card, Bloodstone) are labeled `(expected value)`.
- **F4** — Toggle capture of mispredicted hands (off by default). When on, any hand where the predicted score differs from the actual is written to `<mod>/best_hand_captures/capture_<timestamp>_<n>.lua` — useful as a bug-report attachment.

## What it handles

Scoring runs through Balatro's own per-joker scoring code in every phase, so each joker is evaluated with the same logic the game uses. Explicit handling layers on top for:

- Every card enhancement (Bonus, Mult, Glass, Steel, Stone, Lucky, Gold, Wild)
- Foil / Holo / Polychrome editions on cards and jokers (with Balatro's exact composition order: additive before the joker's Xmult, polychrome after)
- Retrigger jokers: Red Seal, Mime, Hack, Sock and Buskin, Hanging Chad, Dusk, Seltzer
- Blueprint and Brainstorm copy resolution, including chained Blueprints
- Held-in-hand effects: Steel Card (with editions), Baron, Shoot the Moon
- Four Fingers, Smeared Joker, Pareidolia, Splash, Shortcut
- Scaling jokers (Green Joker, Spare Trousers, Ride the Bus, Square Joker, Runner, Obelisk, Hologram, Madness, Glass Joker, etc.) — their pre-pass bumps are applied before the rest of scoring reads them
- Per-round state jokers (Ancient Joker, The Idol)
- Face-down cards (flipped by The Wheel, The House, The Mark, The Fish) are never proposed for play, and held-in-hand effects (Baron, Shoot the Moon, Steel-held, Mime, Raised Fist) skip them — the predictor doesn't peek at cards you can't see
- Boss blinds: The Eye and The Mouth (hand debuff → score zeroed), The Psychic (must play exactly 5 cards), The Arm (level penalty applied to base chips/mult), The Flint (base chips and mult halved)
- **Card ordering advice**: when order matters — Hanging Chad, Photograph, Ancient Joker, Bloodstone, Triboulet, The Idol, or a card with Polychrome edition or Glass Card enhancement — F2 tries every permutation of the scoring cards and marks the best arrangement with `← drag scoring cards into this order`

The scoring pipeline mirrors Balatro's own phase order: pre-pass scaling, then per-card effects (left to right, with retriggers), then held-in-hand effects, then flat joker effects with their edition bonuses.

## Known limitations

- **Probabilistic effects** (Lucky Card, Bloodstone) use expected value in the prediction. Hands where EV contributed are tagged `(expected value)` in the F2 output.
- **Most boss blinds are not modeled.** The five listed above are handled; others (Verdant Leaf, The Needle, The Wall, etc.) are not — the mod will recommend hands as if there were no blind in effect.

## License

MIT — see [LICENSE](LICENSE).

## Credits

Developed with assistance from Claude (Anthropic).
