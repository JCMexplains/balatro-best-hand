# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Steamodded Balatro mod (Lua 5.1) that predicts the highest-scoring play from the current hand. Single mod file `BestHand.lua` at the repo root, loaded by Steamodded via `BestHand.json`. The flat layout is required by Steamodded — do not move files into `src/`.

## Lua style

Strict Olivine-Labs Lua style guide — see `STYLE.md` for the one-paragraph summary and the two project exceptions (filename/layout rules are skipped because Steamodded requires `BestHand.lua` and `BestHand.json` at the repo root). Every Lua file in this repo follows this style; match it when editing.

## Build / lint / test

There is no build step — Balatro loads `BestHand.lua` directly. The relevant commands:

- **Syntax check**: `luac -p BestHand.lua` (Lua 5.1, no execution). Run after every edit; the cheapest way to catch parse errors before launching the game.
- **Replay all captures through the mod**: `lua batch_verify.lua [captures_dir]` — defaults to `./best_hand_captures`. Reports `ok` / `ok(var)` / `MISS` per fixture.
- **Investigate a single miss**: `lua trace_one.lua path/to/capture.lua`.
- **Fuzz mod vs real game**: `lua synth_fuzz.lua [N] [out_dir]` generates `N` random deterministic fixtures biased toward dense interaction (5-card hands, 4-5 jokers with at least 2 from the retrigger / held-reader / order-sensitive pool, ~55% enhancement / 40% edition / 40% seal rate, hand types weighted toward straight-flush / four-of-a-kind / full-house). No probabilistic effects, so disagreements with Balatro's real `G.FUNCS.evaluate_play` are real mod bugs. Misses are deduped by `(hand_name, joker_set, delta)` signature and written to `out_dir/synth_<ts>_NNNN.lua` in the F4 capture format. `FUZZ_SEED=<int>` for reproducible runs. Defaults: `N=10000`, `out_dir=best_hand_captures`.

All offline tools require `balatro_src/` (a local extraction of Balatro's Lua source — gitignored, not shipped). Without it the harness can't load `card.lua` and the tools fail at startup.

**Security:** offline tools `dofile`/`loadstring` capture files. Only run them on captures you produced yourself.

## Architecture — scoring pipeline

The core insight: **scoring is dispatched through Balatro's own `Card:calculate_joker`** for every joker, in three phases that mirror the game's evaluation order (`state_events.lua` / `card.lua` in `balatro_src/`):

1. **`run_before_pass`** (BestHand.lua:974) — fires `context.before` on each joker. Scaling jokers (Green Joker, Spare Trousers, Ride the Bus, Square Joker, Runner, Obelisk, Hologram, Madness, Glass Joker) bump their `ability.*` here so `joker_main` reads the post-bump value. Snapshots are taken so analysis is non-destructive; `before_deny` lists jokers whose side effects can't be rolled back (DNA, Vampire, Midas Mask, Space Joker, To Do List) — these keep stale `ability.*` values.
2. **`eval_per_card_jokers`** (BestHand.lua:868) — for each scoring card L→R (with retriggers), fires `context.individual`. Card enhancements, editions, seals, and per-card jokers are resolved here.
3. **`eval_flat_jokers`** (BestHand.lua:941) — fires `context.joker_main` per joker L→R, applying their edition bonus (additive before Xmult, polychrome after). `joker_main_deny` lists jokers with unrollable side effects (Misprint, Vagabond, Superposition, Seance, Matador) — these fall through to hardcoded branches.

Phase gates `has_before_branch` and `has_individual_branch` (BestHand.lua:248, :264) skip the real dispatch entirely when no present joker hits that phase — saves N snapshots + N pcalls per combo (~218 combos per F2 press).

`score_combo` (BestHand.lua:1020) is the per-combo scorer. `analyze_hand` (BestHand.lua:1619) is the F2 entry point — it enumerates k-subsets of the hand, calls `score_combo` for each, and (when an order-sensitive joker is present per `build_ordering_flags` / `needs_ordering`) tries every permutation of the scoring cards to find the optimal arrangement.

`snapshot_ability` / `restore_before_pass` (BestHand.lua:188, :998) guarantee that calling `calculate_joker` during read-only analysis never corrupts game state — even if a joker mutates `self.ability.*`, it's rolled back. One level of nesting (`ability.extra`) is handled.

Probabilistic jokers (Lucky Card, Bloodstone) use **expected value** in the primary prediction. F4 captures enumerate the cartesian product of probabilistic outcomes (boolean events × Misprint integer ranges) up to 10,000 configurations.

## Architecture — fixture capture and offline replay

`G.FUNCS.evaluate_play` is wrapped (BestHand.lua:2140) to capture every played hand **pre-scoring**. When the predicted score doesn't match the actual, a Lua-literal capture file is written to `<save>/Mods/balatro-best-hand/best_hand_captures/capture_<timestamp>_<n>.lua` with the played cards, held cards, jokers, relevant `G.GAME` state, the predicted score, and the actual. F4 toggles capture on/off — default is ON in dev installs (auto-detected via readable `.git/HEAD`) and OFF in released zips. F5 toggles debug timing.

Captures are loadable with `dofile` and replayable through `batch_verify.lua` / `trace_one.lua` / the oracle harness.

`harness.lua` is the **shared offline shim** — globals (Object, Moveable, G, SMODS, pseudorandom, love), enough Lua-level stubs to `dofile` `balatro_src/*` without crashing, fixture rehydration (`attach_card`, `attach_joker`, `install_fixture`), and two scorers:

- `H.mod_score(fx)` — runs BestHand's `score_combo` with the same probabilistic enumeration `batch_verify.lua` uses.
- `H.oracle_score(fx)` — runs Balatro's real `G.FUNCS.evaluate_play` and returns `floor(hand_chips * mult)`. **Ground truth.**

`batch_verify.lua` and `trace_one.lua` predate `harness.lua` and have their own copies of the shim — if the shims drift, the tools may disagree about fixtures. Prefer extending `harness.lua` for new offline tooling and migrate the older two when convenient.

## Known limitations to keep in mind when editing

- Most boss blinds are not modeled. Only The Eye, The Mouth, The Psychic, The Arm, The Flint are handled — see the README. Don't claim a fix for "unmodeled blind X" unless you actually add it.
- Bloodstone in the real-dispatch path calls `pseudorandom()` directly, which can't resolve to an EV from inside `Card:calculate_joker`. EV mode computes it separately (×1.25 per Heart). See README "Known limitations".
