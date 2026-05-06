# bug_reports/

Curated divergences between BestHand's offline scorer + the offline oracle (vanilla `evaluate_play`) and the live SMODS-patched game. Candidates for upstream reports to **SMODS** (scoring `.toml` patches) or **Lovely** (the injector itself).

## Filing target

| Symptom | File against |
| --- | --- |
| Vanilla `state_events.lua` differs from the SMODS-patched form | [Steamodded/smods](https://github.com/Steamodded/smods) — `smods/lovely/*.toml` |
| `[[patches]]` block applies in the lovely dump but the running game executes the un-patched code | [ethangreen-dev/lovely-injector](https://github.com/ethangreen-dev/lovely-injector) |
| BestHand prediction wrong but oracle agrees with live game | **Not upstream** — this is a BestHand bug, fix here |

## Per-issue layout

One directory per candidate, named `<short-tag>-<one-line-symptom>/`:

```
bug_reports/
  000037-the-window-1.5x-divergence/
    capture.lua    -- the fixture (Lua-literal, runs through harness.lua)
    NOTES.md       -- what we know, what we've ruled out, what reducing this needs
```

`NOTES.md` should record:

- mod prediction, offline oracle prediction, live `actual_score`
- joker / card / blind state at a glance (don't repeat the capture verbatim)
- what's been ruled out (rerun the oracle, check editions, check tags, etc.)
- whether the capture predates `actual_chips`/`actual_mult` being recorded — if so, reproducing under HEAD is the first reduction step
- minimal repro plan (which jokers/cards can be removed without losing the divergence)

## Discipline before filing

A useful report reduces. The harness in this repo (`harness.lua` — `H.mod_score`, `H.oracle_score`) is exactly the right tool: load the fixture, edit it down, rerun until the divergence is the smallest joker+card combo that still breaks. File the reduction, not the original capture.

If reverting an SMODS lovely patch (commenting out its `payload` in the `.toml`) makes the divergence disappear, that's a smoking gun for the report.

## Status

- `000037-the-window-1.5x-divergence/` — **candidate, not yet reduced**. Do not file as-is.
