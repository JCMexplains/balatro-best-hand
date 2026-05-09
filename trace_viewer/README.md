# Trace Viewer

A side project that lets you specify a Balatro hand (cards, jokers, boss
blind) and walks you through scoring it one step at a time. Built for
re-grokking how the scoring pipeline works without having to read 4000
lines of `BestHand.lua`.

## Run

```
py trace_viewer.py
```

Loads with a demo fixture (Two Pair, three jokers) so there's something
to step through immediately.

## Modes

- **Pedagogy (V1, working)** — a simplified, pure-Python scorer in
  `pedagogy.py`. Mirrors the real game's phase order:
  1. Identify hand
  2. Apply hand-type base chips/mult
  3. Per scoring card (left → right, with red-seal retriggers): rank chips
     → enhancement → edition additive → per-card jokers → edition xmult
  4. Held-in-hand effects (steel ×1.5 mult)
  5. Per joker (left → right): main effect → edition additive → edition xmult
  6. Boss-blind end-of-hand (The Flint halves)
  7. Final = floor(chips × mult)

- **Real BestHand trace (V2, stub)** — will instrument
  `BestHand.lua`'s `score_combo` with a trace-event emitter and run it
  via `lua + harness.lua`, so you see exactly what the real mod does.
  Not implemented yet.

## What V1 models

| Category | Supported |
|---|---|
| Hand types | High Card, Pair, Two Pair, 3oaK, Straight, Flush, Full House, 4oaK, Straight Flush, Royal Flush |
| Card enhancements | bonus, mult, glass, stone, steel (held only), gold, lucky (EV), wild |
| Card seals | red (retrigger), gold/blue/purple (informational) |
| Card editions | foil, holo, polychrome |
| Joker editions | foil, holo, polychrome, negative |
| Boss blinds | The Eye, The Mouth (informational), The Psychic, The Arm, The Flint |
| Jokers | A small curated set — see `pedagogy.JOKERS`. Adding more is straightforward: define a `per_card` and/or `main` hook returning `(dchips, dmult, xmult, narrative)`. |

## What V1 does NOT model

- Five of a Kind, Flush House, Flush Five — multi-deck and wild-card edge cases.
- Probabilistic outcomes other than Lucky Card and Misprint (we use EV).
- Hand levels other than 1 — The Arm becomes a no-op for that reason.
- Most jokers, including blueprints/copying jokers, retrigger jokers
  (Hanging Chad, Mime, Dusk, Hack), tag-based jokers, deck composition
  jokers, etc. The catalog is intentionally small.
- The Eye / The Mouth round history (we just flag them as informational).

If a joker isn't in the catalog, it shows up in the trace as
"`<name>: not modeled`" and is skipped.

## Adding a joker

In `pedagogy.py`, append to `JOKERS`:

```python
"My Joker": {
    "desc": "What the joker does, shown in the help panel.",
    # Fires once per scoring card:
    "per_card": lambda j, card, ctx: (chips, mult, xmult, narrative) | None,
    # Fires once after the per-card phase:
    "main":     lambda j, ctx:       (chips, mult, xmult, narrative) | None,
},
```

Hooks return `None` for "no effect this fire," or a tuple
`(dchips, dmult, xmult, narrative_string)`.
