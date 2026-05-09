"""Simplified Balatro scorer that emits a list of TraceStep events.

The goal here is teaching, not faithfulness. The phase order mirrors the real
game (hand identify → base → scoring cards L->R → held-in-hand → flat jokers
L->R → boss end-of-hand → final), but we only model a curated subset of
jokers, enhancements, seals, editions, and boss blinds.

What this is NOT:
  - A drop-in replacement for BestHand's score_combo. See trace_viewer.py's
    "real trace" mode for that (V2).
  - Comprehensive. Many jokers are not here.

Conventions:
  - "Mult" stays additive until polychrome / xmult effects fire. We track it
    as a single float; xmult just multiplies it in place. This is how the
    game does it too (additive bonuses, then xmult).
  - Card scoring fires per-card jokers inside the per-card phase, mirroring
    Balatro's context.individual loop.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Optional


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

RANKS = ["2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A"]
SUITS = ["Spades", "Hearts", "Diamonds", "Clubs"]

RANK_CHIPS = {
    "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7,
    "8": 8, "9": 9, "T": 10, "J": 10, "Q": 10, "K": 10, "A": 11,
}

# rank index for straight detection (A is both 1 and 14)
RANK_INDEX = {r: i for i, r in enumerate(RANKS, start=2)}  # 2->2, ..., A->14
FACE = {"J", "Q", "K"}
EVEN = {"2", "4", "6", "8", "T"}
ODD = {"A", "3", "5", "7", "9"}

ENHANCEMENTS = ["none", "bonus", "mult", "glass", "stone", "steel", "gold", "lucky", "wild"]
SEALS = ["none", "red", "blue", "gold", "purple"]
CARD_EDITIONS = ["none", "foil", "holo", "polychrome"]
JOKER_EDITIONS = ["none", "foil", "holo", "polychrome", "negative"]

HAND_BASE = {
    "High Card":        (5, 1),
    "Pair":             (10, 2),
    "Two Pair":         (20, 2),
    "Three of a Kind":  (30, 3),
    "Straight":         (30, 4),
    "Flush":            (35, 4),
    "Full House":       (40, 4),
    "Four of a Kind":   (60, 7),
    "Straight Flush":   (100, 8),
    "Royal Flush":      (100, 8),
}

BLINDS = ["(none)", "The Eye", "The Mouth", "The Psychic", "The Arm", "The Flint"]


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

@dataclass
class Card:
    rank: str = "A"
    suit: str = "Spades"
    enhancement: str = "none"
    seal: str = "none"
    edition: str = "none"

    def __str__(self) -> str:
        suit_glyph = {"Spades": "S", "Hearts": "H", "Diamonds": "D", "Clubs": "C"}[self.suit]
        tag = []
        if self.enhancement != "none":
            tag.append(self.enhancement)
        if self.edition != "none":
            tag.append(self.edition)
        if self.seal != "none":
            tag.append(self.seal + "-seal")
        suffix = (" [" + ",".join(tag) + "]") if tag else ""
        return f"{self.rank}{suit_glyph}{suffix}"


@dataclass
class Joker:
    name: str
    edition: str = "none"


@dataclass
class TraceStep:
    phase: str           # broad bucket: "Identify" / "Base" / "Cards" / "Held" / "Jokers" / "Boss" / "Final"
    title: str           # short label
    narrative: str       # plain-English explanation
    math: str            # the arithmetic done
    chips: float         # running chips after this step
    mult: float          # running mult after this step


# ---------------------------------------------------------------------------
# Hand identification
# ---------------------------------------------------------------------------

def _effective_suit(card: Card) -> Optional[str]:
    """Stone cards have no suit. Wild cards are treated as flush-friendly."""
    if card.enhancement == "stone":
        return None
    return card.suit


def _has_rank(card: Card) -> bool:
    return card.enhancement != "stone"


def _is_flush(cards: list[Card]) -> bool:
    if len(cards) < 5:
        return False
    # Wild cards count as any suit. Stone cards don't count at all.
    suits = []
    wilds = 0
    for c in cards:
        if c.enhancement == "stone":
            return False  # any stone breaks flush
        if c.enhancement == "wild":
            wilds += 1
        else:
            suits.append(c.suit)
    if not suits:
        return False
    return all(s == suits[0] for s in suits) or (len(set(suits)) == 1)


def _is_straight(cards: list[Card]) -> bool:
    if len(cards) < 5:
        return False
    if any(c.enhancement == "stone" for c in cards):
        return False
    idxs = sorted({RANK_INDEX[c.rank] for c in cards})
    if len(idxs) < 5:
        return False
    # Standard run of 5
    for i in range(len(idxs) - 4):
        if idxs[i + 4] - idxs[i] == 4:
            return True
    # Wheel: A-2-3-4-5 (A counts as 1)
    if {2, 3, 4, 5, 14}.issubset(set(idxs)):
        return True
    return False


def _is_royal(cards: list[Card]) -> bool:
    ranks = {c.rank for c in cards if _has_rank(c)}
    return ranks == {"T", "J", "Q", "K", "A"}


def _rank_counts(cards: list[Card]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for c in cards:
        if _has_rank(c):
            counts[c.rank] = counts.get(c.rank, 0) + 1
    return counts


def identify_hand(played: list[Card]) -> tuple[str, list[int]]:
    """Return (hand_name, indices_of_scoring_cards).

    Scoring cards are the cards Balatro counts toward chips. For Pair, it's
    the two paired cards; for Flush/Straight, all five; etc. Stone cards
    always score (they're bonus chips regardless).
    """
    if not played:
        return "High Card", []

    counts = _rank_counts(played)
    flush = _is_flush(played)
    straight = _is_straight(played)
    royal = flush and _is_royal(played)

    # In Balatro, every scoring hand ALSO scores all stones in the played hand.
    stone_idxs = [i for i, c in enumerate(played) if c.enhancement == "stone"]

    def with_stones(idxs: list[int]) -> list[int]:
        return sorted(set(idxs) | set(stone_idxs))

    def idxs_of_rank(rank: str) -> list[int]:
        return [i for i, c in enumerate(played) if _has_rank(c) and c.rank == rank]

    if royal:
        return "Royal Flush", with_stones(list(range(len(played))))
    if straight and flush:
        return "Straight Flush", with_stones(list(range(len(played))))

    if 4 in counts.values():
        rank = next(r for r, n in counts.items() if n == 4)
        return "Four of a Kind", with_stones(idxs_of_rank(rank))

    triples = [r for r, n in counts.items() if n == 3]
    pairs = [r for r, n in counts.items() if n == 2]
    if triples and pairs:
        idxs = idxs_of_rank(triples[0]) + idxs_of_rank(pairs[0])
        return "Full House", with_stones(idxs)

    if flush:
        return "Flush", with_stones(list(range(len(played))))
    if straight:
        return "Straight", with_stones(list(range(len(played))))

    if triples:
        return "Three of a Kind", with_stones(idxs_of_rank(triples[0]))

    if len(pairs) >= 2:
        idxs = idxs_of_rank(pairs[0]) + idxs_of_rank(pairs[1])
        return "Two Pair", with_stones(idxs)

    if pairs:
        return "Pair", with_stones(idxs_of_rank(pairs[0]))

    # High Card: highest-rank scoring card scores.
    ranked = [(RANK_INDEX[c.rank], i) for i, c in enumerate(played) if _has_rank(c)]
    if ranked:
        ranked.sort(reverse=True)
        return "High Card", with_stones([ranked[0][1]])
    # Only stones
    return "High Card", stone_idxs


# ---------------------------------------------------------------------------
# Joker catalog (V1)
# ---------------------------------------------------------------------------
# Each joker has two optional hooks:
#   per_card(joker, card, ctx) -> (delta_chips, delta_mult, xmult, narrative)
#     fires once per scoring card (called inside the per-card loop)
#   main(joker, ctx) -> same shape
#     fires once per joker after all scoring cards (the joker_main phase)
#
# ctx provides: hand_name, played, scoring_cards, held, all_jokers.

JokerEffect = tuple[float, float, float, str]  # (dchips, dmult, xmult, narrative)


def _per_card_suit(suit: str, mult: float = 3) -> Callable[..., Optional[JokerEffect]]:
    def _fn(joker, card, ctx):
        if card.suit == suit or card.enhancement == "wild":
            why = f"{card.rank}{suit[0]} matches {suit}"
            if card.enhancement == "wild":
                why = f"{card.rank} (Wild) counts as {suit}"
            return (0, mult, 1, f"+{mult} mult: {why}")
        return None
    return _fn


def _hand_chips_main(hand_name: str, chips: float) -> Callable[..., Optional[JokerEffect]]:
    def _fn(joker, ctx):
        if ctx["hand_name"] == hand_name or _contains(ctx, hand_name):
            return (chips, 0, 1, f"+{chips} chips because hand contains {hand_name}")
        return None
    return _fn


def _hand_mult_main(hand_name: str, mult: float) -> Callable[..., Optional[JokerEffect]]:
    def _fn(joker, ctx):
        if ctx["hand_name"] == hand_name or _contains(ctx, hand_name):
            return (0, mult, 1, f"+{mult} mult because hand contains {hand_name}")
        return None
    return _fn


def _contains(ctx, sub_hand: str) -> bool:
    """Some hands contain others — Two Pair contains a Pair, Full House contains
    Three of a Kind, etc. This mirrors Balatro's context.poker_hands semantics
    in a coarse way."""
    h = ctx["hand_name"]
    contains = {
        "Pair": {"Pair", "Two Pair", "Three of a Kind", "Four of a Kind", "Full House"},
        "Two Pair": {"Two Pair"},
        "Three of a Kind": {"Three of a Kind", "Four of a Kind", "Full House"},
        "Straight": {"Straight", "Straight Flush", "Royal Flush"},
        "Flush": {"Flush", "Straight Flush", "Royal Flush"},
        "Four of a Kind": {"Four of a Kind"},
        "Full House": {"Full House"},
    }
    return h in contains.get(sub_hand, {h})


JOKERS: dict[str, dict] = {
    "Clever Joker": {
        "desc": "+150 chips if hand contains Two Pair.",
        "main": _hand_chips_main("Two Pair", 150),
    },
    "Crafty Joker": {
        "desc": "+80 chips if hand contains a Flush.",
        "main": _hand_chips_main("Flush", 80),
    },
    "Devious Joker": {
        "desc": "+100 chips if hand contains a Straight.",
        "main": _hand_chips_main("Straight", 100),
    },
    "Even Steven": {
        "desc": "+4 mult per scoring even-rank card (2,4,6,8,10).",
        "per_card": (lambda j, card, ctx:
            (0, 4, 1, f"+4 mult: {card.rank} is even") if card.rank in EVEN else None),
    },
    "Fibonacci": {
        "desc": "+8 mult per scoring A, 2, 3, 5, or 8.",
        "per_card": (lambda j, card, ctx:
            (0, 8, 1, f"+8 mult: {card.rank} is Fibonacci")
            if card.rank in {"A", "2", "3", "5", "8"} else None),
    },
    "Gluttonous Joker": {
        "desc": "+3 mult per scoring Club card.",
        "per_card": _per_card_suit("Clubs", 3),
    },
    "Greedy Joker": {
        "desc": "+3 mult per scoring Diamond card.",
        "per_card": _per_card_suit("Diamonds", 3),
    },
    "Joker": {
        "desc": "+4 mult.",
        "main": lambda j, ctx: (0, 4, 1, "+4 mult (flat)"),
    },
    "Jolly Joker": {
        "desc": "+8 mult if hand contains a Pair.",
        "main": _hand_mult_main("Pair", 8),
    },
    "Lusty Joker": {
        "desc": "+3 mult per scoring Heart card.",
        "per_card": _per_card_suit("Hearts", 3),
    },
    "Misprint": {
        "desc": "+0..23 mult (random). Shown as range, EV = +11.5.",
        "main": lambda j, ctx: (0, 11.5, 1, "+0..23 mult, EV = +11.5"),
    },
    "Odd Todd": {
        "desc": "+31 chips per scoring odd-rank card (A,3,5,7,9).",
        "per_card": (lambda j, card, ctx:
            (31, 0, 1, f"+31 chips: {card.rank} is odd") if card.rank in ODD else None),
    },
    "Photograph": {
        "desc": "First scoring face card gives X2 mult.",
        "per_card": None,  # filled in below (needs stateful closure)
    },
    "Sly Joker": {
        "desc": "+50 chips if hand contains a Pair.",
        "main": _hand_chips_main("Pair", 50),
    },
    "Stuntman": {
        "desc": "+250 chips, -2 hand size (we ignore the hand-size cost).",
        "main": lambda j, ctx: (250, 0, 1, "+250 chips"),
    },
    "Walkie Talkie": {
        "desc": "+10 chips, +4 mult per scoring 10 or 4.",
        "per_card": (lambda j, card, ctx:
            (10, 4, 1, f"+10 chips, +4 mult: {card.rank} is 10/4")
            if card.rank in {"T", "4"} else None),
    },
    "Wily Joker": {
        "desc": "+100 chips if hand contains Three of a Kind.",
        "main": _hand_chips_main("Three of a Kind", 100),
    },
    "Wrathful Joker": {
        "desc": "+3 mult per scoring Spade card.",
        "per_card": _per_card_suit("Spades", 3),
    },
}


# Photograph needs state: only the FIRST face card triggers. Build a stateful version.
def _photograph_per_card(joker, card, ctx):
    if card.rank in FACE and not ctx.get("_photo_used", False):
        ctx["_photo_used"] = True
        return (0, 0, 2, f"First face card ({card.rank}) → ×2 mult")
    return None


JOKERS["Photograph"]["per_card"] = _photograph_per_card


# ---------------------------------------------------------------------------
# Scoring engine
# ---------------------------------------------------------------------------

def score(played: list[Card], held: list[Card],
          jokers: list[Joker], blind: str = "(none)") -> tuple[list[TraceStep], int]:
    steps: list[TraceStep] = []
    chips: float = 0
    mult: float = 0

    def emit(phase, title, narrative, math):
        steps.append(TraceStep(phase, title, narrative, math, chips, mult))

    # 0. Inputs ---------------------------------------------------------------
    cards_repr = ", ".join(str(c) for c in played) if played else "(no played cards)"
    held_repr = ", ".join(str(c) for c in held) if held else "(no held cards)"
    jokers_repr = ", ".join(f"{j.name}" + (f" [{j.edition}]" if j.edition != "none" else "")
                             for j in jokers) if jokers else "(no jokers)"
    emit("Setup", "Inputs",
         f"Played: {cards_repr}\nHeld: {held_repr}\nJokers: {jokers_repr}\nBlind: {blind}",
         "chips = 0, mult = 0")

    # 1. Identify hand --------------------------------------------------------
    hand_name, scoring_idxs = identify_hand(played)
    scoring_cards = [played[i] for i in scoring_idxs]
    emit("Identify", f"Hand type: {hand_name}",
         f"Scanned the {len(played)} played cards and detected the highest-scoring "
         f"poker hand. Cards that count: {', '.join(str(c) for c in scoring_cards) or '(none)'}",
         f"hand_name = {hand_name!r}")

    # 2. Boss debuff: hand-name short circuit -------------------------------
    if blind == "The Eye":
        emit("Boss", "The Eye debuff (informational)",
             "The Eye disables hand types you've already played this round. "
             "We don't track round history here, so we just flag it.",
             "(no math change in V1)")
    if blind == "The Mouth":
        emit("Boss", "The Mouth debuff (informational)",
             "The Mouth allows only one hand type per round. Same caveat as The Eye.",
             "(no math change in V1)")
    if blind == "The Psychic" and len(played) < 5:
        emit("Boss", "The Psychic: <5 cards played",
             "The Psychic forces you to play exactly 5 cards. Score is zeroed.",
             f"len(played)={len(played)} < 5  →  score = 0")
        emit("Final", "Final score", "Boss zeroed the score.", "0", )
        return steps, 0

    # 3. Hand base ------------------------------------------------------------
    if hand_name not in HAND_BASE:
        emit("Final", "Unsupported hand", f"V1 doesn't model {hand_name}.", "score = 0")
        return steps, 0
    base_chips, base_mult = HAND_BASE[hand_name]
    chips, mult = float(base_chips), float(base_mult)
    emit("Base", f"Base for {hand_name}",
         f"Each hand type starts with a base chips × mult. {hand_name} = "
         f"{base_chips} chips × {base_mult} mult at level 1.",
         f"chips = {base_chips}, mult = {base_mult}")

    if blind == "The Arm":
        emit("Boss", "The Arm: hand level −1",
             "The Arm reduces the played hand's level by 1, capped at level 1. "
             "We assume level 1 throughout V1, so The Arm has no effect here.",
             "(no math change at level 1)")

    # 4. Per-scoring-card phase ---------------------------------------------
    ctx: dict = {
        "hand_name": hand_name,
        "played": played,
        "scoring_cards": scoring_cards,
        "held": held,
        "jokers": jokers,
    }

    if not scoring_cards:
        emit("Cards", "No scoring cards", "Nothing to score in this phase.", "(skipped)")
    for card in scoring_cards:
        triggers = 1 + (1 if card.seal == "red" else 0)
        for t in range(triggers):
            tag = "" if triggers == 1 else f"  [trigger {t + 1}/{triggers}]"

            # 4a. Rank chips
            if _has_rank(card):
                rc = RANK_CHIPS[card.rank]
                before = chips
                chips += rc
                emit("Cards", f"{card}{tag}: rank chips",
                     f"Each scoring card contributes its rank value as chips. {card.rank} = {rc}.",
                     f"chips: {before:g} + {rc} = {chips:g}")

            # 4b. Enhancement
            enh = card.enhancement
            if enh == "bonus":
                before = chips; chips += 30
                emit("Cards", f"{card}{tag}: Bonus enhancement",
                     "Bonus cards add 30 flat chips on score.",
                     f"chips: {before:g} + 30 = {chips:g}")
            elif enh == "mult":
                before = mult; mult += 4
                emit("Cards", f"{card}{tag}: Mult enhancement",
                     "Mult cards add 4 flat mult on score.",
                     f"mult: {before:g} + 4 = {mult:g}")
            elif enh == "glass":
                before = mult; mult *= 2
                emit("Cards", f"{card}{tag}: Glass enhancement",
                     "Glass cards give X2 mult (and have a chance to break — ignored here).",
                     f"mult: {before:g} × 2 = {mult:g}")
            elif enh == "stone":
                before = chips; chips += 50
                emit("Cards", f"{card}{tag}: Stone enhancement",
                     "Stone cards add 50 flat chips and have no rank or suit.",
                     f"chips: {before:g} + 50 = {chips:g}")
            elif enh == "lucky":
                # 1/5 chance +20 mult; 1/15 chance +20$ (no scoring effect for $)
                before = mult; mult += 4  # EV = 20 * 1/5 = 4
                emit("Cards", f"{card}{tag}: Lucky enhancement (EV)",
                     "Lucky has a 1-in-5 chance of +20 mult and 1-in-15 chance of +$20. "
                     "We use the expected value: 20 × 1/5 = 4 mult on average.",
                     f"mult: {before:g} + 4 (EV) = {mult:g}")

            # 4c. Edition (additive part)
            if card.edition == "foil":
                before = chips; chips += 50
                emit("Cards", f"{card}{tag}: Foil edition",
                     "Foil edition adds 50 chips.",
                     f"chips: {before:g} + 50 = {chips:g}")
            elif card.edition == "holo":
                before = mult; mult += 10
                emit("Cards", f"{card}{tag}: Holographic edition",
                     "Holo edition adds 10 mult.",
                     f"mult: {before:g} + 10 = {mult:g}")

            # 4d. Per-card jokers (L→R)
            for j in jokers:
                if j.name not in JOKERS:
                    continue
                hook = JOKERS[j.name].get("per_card")
                if not hook:
                    continue
                effect = hook(j, card, ctx)
                if effect is None:
                    continue
                dch, dmu, xmu, why = effect
                before_c, before_m = chips, mult
                chips += dch
                mult += dmu
                if xmu and xmu != 1:
                    mult *= xmu
                math_parts = []
                if dch: math_parts.append(f"chips: {before_c:g} + {dch:g} = {chips:g}")
                if dmu: math_parts.append(f"mult: {before_m:g} + {dmu:g} = {before_m + dmu:g}")
                if xmu and xmu != 1:
                    math_parts.append(f"mult: × {xmu:g} = {mult:g}")
                emit("Cards", f"{card}{tag}: {j.name} fires",
                     f"{j.name} ({JOKERS[j.name]['desc']}) — {why}",
                     "; ".join(math_parts))

            # 4e. Edition (xmult — fires after additive)
            if card.edition == "polychrome":
                before = mult; mult *= 1.5
                emit("Cards", f"{card}{tag}: Polychrome edition",
                     "Polychrome edition gives X1.5 mult, applied AFTER additive bonuses.",
                     f"mult: {before:g} × 1.5 = {mult:g}")

    # 5. Held-in-hand phase --------------------------------------------------
    for card in held:
        if card.enhancement == "steel":
            before = mult; mult *= 1.5
            emit("Held", f"{card} held: Steel",
                 "Steel cards give X1.5 mult while HELD in hand (not played).",
                 f"mult: {before:g} × 1.5 = {mult:g}")

    # 6. Flat-jokers phase ---------------------------------------------------
    for j in jokers:
        if j.name not in JOKERS:
            emit("Jokers", f"{j.name}: not modeled",
                 "This joker isn't in V1's catalog — pretend it does nothing.", "(skipped)")
            continue
        hook = JOKERS[j.name].get("main")
        if hook:
            effect = hook(j, ctx)
            if effect is not None:
                dch, dmu, xmu, why = effect
                before_c, before_m = chips, mult
                chips += dch
                mult += dmu
                if xmu and xmu != 1:
                    mult *= xmu
                parts = []
                if dch: parts.append(f"chips: {before_c:g} + {dch:g} = {chips:g}")
                if dmu: parts.append(f"mult: {before_m:g} + {dmu:g} = {before_m + dmu:g}")
                if xmu and xmu != 1: parts.append(f"mult: × {xmu:g} = {mult:g}")
                emit("Jokers", f"{j.name} fires (main)",
                     f"{JOKERS[j.name]['desc']} — {why}",
                     "; ".join(parts) or "(no change)")

        # Joker edition
        if j.edition == "foil":
            before = chips; chips += 50
            emit("Jokers", f"{j.name}: Foil edition",
                 "Foil joker adds 50 chips.",
                 f"chips: {before:g} + 50 = {chips:g}")
        elif j.edition == "holo":
            before = mult; mult += 10
            emit("Jokers", f"{j.name}: Holographic edition",
                 "Holo joker adds 10 mult.",
                 f"mult: {before:g} + 10 = {mult:g}")
        elif j.edition == "polychrome":
            before = mult; mult *= 1.5
            emit("Jokers", f"{j.name}: Polychrome edition",
                 "Polychrome joker gives X1.5 mult after the joker's main effect.",
                 f"mult: {before:g} × 1.5 = {mult:g}")
        # negative: extra slot, no scoring effect

    # 7. Boss end-of-hand ---------------------------------------------------
    if blind == "The Flint":
        before_c, before_m = chips, mult
        chips /= 2
        mult /= 2
        emit("Boss", "The Flint: chips and mult halved",
             "The Flint halves both base chips and base mult at the end of scoring.",
             f"chips: {before_c:g} / 2 = {chips:g}; mult: {before_m:g} / 2 = {mult:g}")

    # 8. Final --------------------------------------------------------------
    final = int(chips * mult)
    emit("Final", "Final score",
         "Multiply chips by mult. Balatro floors the result.",
         f"{chips:g} × {mult:g} = {chips * mult:g}  →  floor = {final:,}")
    return steps, final
