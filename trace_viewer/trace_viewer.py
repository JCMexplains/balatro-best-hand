#!/usr/bin/env python3
"""Trace Viewer — step through the scoring of a Balatro hand.

Usage (from the trace_viewer/ folder):  py trace_viewer.py

Specify a hand, jokers, and boss blind on the left; the right side walks you
through scoring one step at a time. V1 only implements the "pedagogy" mode
(a simplified Python scorer in pedagogy.py). The real-trace mode toggle is
present but stubbed — V2 will wire it to BestHand.lua's score_combo.
"""

from __future__ import annotations

import sys
import tkinter as tk
import tkinter.font as tkfont
from tkinter import ttk, messagebox
from typing import Optional

import pedagogy
from pedagogy import (
    Card, Joker, TraceStep,
    RANKS, SUITS, ENHANCEMENTS, SEALS, CARD_EDITIONS, JOKER_EDITIONS,
    BLINDS, JOKERS, score,
)


def _enable_dpi_awareness() -> None:
    if sys.platform != "win32":
        return
    try:
        import ctypes
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)  # per-monitor v2
        except (AttributeError, OSError):
            ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Phase colors — visual cue when scanning the step list
# ---------------------------------------------------------------------------
PHASE_COLORS = {
    "Setup":    "#9aa0a6",
    "Identify": "#1a73e8",
    "Base":     "#188038",
    "Boss":     "#c5221f",
    "Cards":    "#e8710a",
    "Held":     "#7b1fa2",
    "Jokers":   "#0f9d58",
    "Final":    "#202124",
}

# ---------------------------------------------------------------------------
# Joker list for dropdown — sorted, plus a "(empty)" option
# ---------------------------------------------------------------------------
JOKER_NAMES = ["(empty)"] + sorted(JOKERS.keys())


# ---------------------------------------------------------------------------
# Font manager — Ctrl+= / Ctrl+- / Ctrl+0 / Ctrl+wheel rescale the UI
# ---------------------------------------------------------------------------
APP_FONT_SPECS = {
    "AppFont9b":  ("Segoe UI", 9,  "bold"),
    "AppFont11":  ("Segoe UI", 11, "normal"),
    "AppFont11b": ("Segoe UI", 11, "bold"),
    "AppFont12b": ("Segoe UI", 12, "bold"),
    "AppFont14b": ("Segoe UI", 14, "bold"),
    "AppMono10":  ("Consolas", 10, "normal"),
}

# ttk-managed standard fonts that should grow with zoom too.
STD_FONT_NAMES = (
    "TkDefaultFont", "TkTextFont", "TkHeadingFont", "TkMenuFont",
    "TkFixedFont", "TkSmallCaptionFont", "TkCaptionFont",
    "TkIconFont", "TkTooltipFont",
)


class FontManager:
    DEFAULT_SCALE = 1.25

    def __init__(self, root: tk.Tk):
        self.root = root
        self.scale = self.DEFAULT_SCALE
        try:
            self.base_scaling = float(root.tk.call("tk", "scaling"))
        except tk.TclError:
            self.base_scaling = 1.0

        # (font_obj, base_size_in_points)
        self._fonts: list[tuple[tkfont.Font, int]] = []

        for name in STD_FONT_NAMES:
            try:
                f = tkfont.nametofont(name)
            except tk.TclError:
                continue
            size = abs(int(f.cget("size") or 9))
            self._fonts.append((f, size))

        for name, (family, size, weight) in APP_FONT_SPECS.items():
            f = tkfont.Font(name=name, family=family, size=size, weight=weight)
            self._fonts.append((f, size))

        self._style = ttk.Style(root)
        self.apply()

    def apply(self) -> None:
        for f, base in self._fonts:
            f.configure(size=max(6, int(round(base * self.scale))))
        self.root.tk.call("tk", "scaling", self.base_scaling * self.scale)
        # Treeview rowheight is set at creation; refresh it from the live font.
        line = tkfont.nametofont("TkDefaultFont").metrics("linespace")
        self._style.configure("Treeview", rowheight=int(line * 1.25))

    def zoom(self, delta: float) -> None:
        new = round(max(0.6, min(3.0, self.scale + delta)), 3)
        if new == self.scale:
            return
        self.scale = new
        self.apply()

    def reset(self) -> None:
        if self.scale == self.DEFAULT_SCALE:
            return
        self.scale = self.DEFAULT_SCALE
        self.apply()


class CardRow:
    """One row of dropdowns for a single card slot."""

    def __init__(self, parent: tk.Widget, row: int, label: str, *,
                 include_seal: bool = True, on_change=None):
        self.on_change = on_change
        self.label = label
        ttk.Label(parent, text=label, width=8).grid(row=row, column=0, sticky="w", padx=4, pady=2)
        self.rank = self._combo(parent, row, 1, ["(empty)"] + RANKS, width=6)
        self.suit = self._combo(parent, row, 2, SUITS, width=10)
        self.enh = self._combo(parent, row, 3, ENHANCEMENTS, width=8)
        self.seal = self._combo(parent, row, 4, SEALS if include_seal else ["none"], width=8)
        self.ed = self._combo(parent, row, 5, CARD_EDITIONS, width=10)
        # Defaults
        self.rank.set("(empty)")
        self.suit.set("Spades")
        self.enh.set("none")
        self.seal.set("none")
        self.ed.set("none")

    def _combo(self, parent, row, col, values, width):
        cb = ttk.Combobox(parent, values=values, width=width, state="readonly")
        cb.grid(row=row, column=col, sticky="w", padx=2, pady=2)
        if self.on_change:
            cb.bind("<<ComboboxSelected>>", lambda e: self.on_change())
        return cb

    def to_card(self) -> Optional[Card]:
        r = self.rank.get()
        if r == "(empty)" or r == "":
            return None
        return Card(rank=r, suit=self.suit.get(), enhancement=self.enh.get(),
                    seal=self.seal.get(), edition=self.ed.get())


class JokerRow:
    def __init__(self, parent, row, on_change=None):
        self.on_change = on_change
        ttk.Label(parent, text=f"Joker {row}", width=8).grid(row=row, column=0, sticky="w", padx=4, pady=2)
        self.name = ttk.Combobox(parent, values=JOKER_NAMES, width=22, state="readonly")
        self.name.grid(row=row, column=1, sticky="w", padx=2, pady=2, columnspan=2)
        self.name.set("(empty)")
        self.ed = ttk.Combobox(parent, values=JOKER_EDITIONS, width=10, state="readonly")
        self.ed.grid(row=row, column=3, sticky="w", padx=2, pady=2)
        self.ed.set("none")
        if on_change:
            self.name.bind("<<ComboboxSelected>>", lambda e: on_change())
            self.ed.bind("<<ComboboxSelected>>", lambda e: on_change())

    def to_joker(self) -> Optional[Joker]:
        n = self.name.get()
        if n in ("(empty)", ""):
            return None
        return Joker(name=n, edition=self.ed.get())


class TraceViewerApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Balatro Scoring Trace Viewer — V1")
        self.root.geometry("1400x900")

        self.steps: list[TraceStep] = []
        self.current_step = tk.IntVar(value=0)
        self.mode = tk.StringVar(value="pedagogy")

        # Named fonts must exist before any widget references them.
        self.fonts = FontManager(self.root)

        # Footer FIRST (DPI/layout requirement: pack footer before content)
        self._build_footer()
        self._build_header()
        self._build_main()
        self._bind_zoom()

        # Auto-score once with a sensible default fixture so the user sees output immediately.
        self._load_demo_fixture()
        self._rescore()

    # -----------------------------------------------------------------------
    # Zoom
    # -----------------------------------------------------------------------
    def _bind_zoom(self):
        # Ctrl+= and Ctrl+plus both grow; Ctrl+- shrinks; Ctrl+0 resets.
        for seq in ("<Control-equal>", "<Control-plus>",
                    "<Control-KP_Add>", "<Control-Shift-equal>"):
            self.root.bind_all(seq, lambda e: self._zoom(+0.1))
        for seq in ("<Control-minus>", "<Control-KP_Subtract>"):
            self.root.bind_all(seq, lambda e: self._zoom(-0.1))
        self.root.bind_all("<Control-0>", lambda e: self._zoom_reset())
        self.root.bind_all("<Control-MouseWheel>", self._on_ctrl_wheel)

    def _zoom(self, delta: float):
        self.fonts.zoom(delta)
        return "break"

    def _zoom_reset(self):
        self.fonts.reset()
        return "break"

    def _on_ctrl_wheel(self, event):
        self.fonts.zoom(+0.1 if event.delta > 0 else -0.1)
        return "break"

    # -----------------------------------------------------------------------
    # Layout
    # -----------------------------------------------------------------------
    def _build_footer(self):
        self.footer = ttk.Frame(self.root, padding=8)
        self.footer.pack(side="bottom", fill="x")

        self.score_var = tk.StringVar(value="Final score: —")
        self.score_label = ttk.Label(self.footer, textvariable=self.score_var,
                                     font="AppFont14b")
        self.score_label.pack(side="left")

        ttk.Label(self.footer, text="    Hand: ").pack(side="left")
        self.hand_var = tk.StringVar(value="—")
        ttk.Label(self.footer, textvariable=self.hand_var,
                  font="AppFont11").pack(side="left")

    def _build_header(self):
        bar = ttk.Frame(self.root, padding=(8, 4))
        bar.pack(side="top", fill="x")

        ttk.Label(bar, text="Mode:").pack(side="left")
        ttk.Radiobutton(bar, text="Pedagogy (simplified, in-process)",
                        variable=self.mode, value="pedagogy",
                        command=self._on_mode_change).pack(side="left", padx=4)
        ttk.Radiobutton(bar, text="Real BestHand trace (V2 — coming soon)",
                        variable=self.mode, value="real",
                        command=self._on_mode_change).pack(side="left", padx=4)

        ttk.Separator(bar, orient="vertical").pack(side="left", fill="y", padx=10)
        ttk.Button(bar, text="Score", command=self._rescore).pack(side="left", padx=4)
        ttk.Button(bar, text="Demo fixture", command=self._load_demo_fixture).pack(side="left", padx=4)
        ttk.Button(bar, text="Clear all", command=self._clear_all).pack(side="left", padx=4)

    def _build_main(self):
        paned = ttk.PanedWindow(self.root, orient="horizontal")
        paned.pack(fill="both", expand=True)

        left = ttk.Frame(paned, padding=8)
        right = ttk.Frame(paned, padding=8)
        paned.add(left, weight=1)
        paned.add(right, weight=2)

        self._build_input_pane(left)
        self._build_output_pane(right)

    def _build_input_pane(self, parent: ttk.Frame):
        # Played cards
        played_frame = ttk.LabelFrame(parent, text="Played cards (1–5)", padding=6)
        played_frame.pack(fill="x", pady=(0, 6))
        self._add_card_header(played_frame)
        self.played_rows = [CardRow(played_frame, i + 1, f"Card {i + 1}",
                                    on_change=self._rescore) for i in range(5)]

        # Held cards
        held_frame = ttk.LabelFrame(parent, text="Held cards (steel matters here)", padding=6)
        held_frame.pack(fill="x", pady=(0, 6))
        self._add_card_header(held_frame)
        self.held_rows = [CardRow(held_frame, i + 1, f"Held {i + 1}",
                                  on_change=self._rescore) for i in range(3)]

        # Jokers
        joker_frame = ttk.LabelFrame(parent, text="Jokers (left → right)", padding=6)
        joker_frame.pack(fill="x", pady=(0, 6))
        ttk.Label(joker_frame, text="Slot", width=8).grid(row=0, column=0, padx=4, pady=2, sticky="w")
        ttk.Label(joker_frame, text="Joker", width=22).grid(row=0, column=1, columnspan=2, padx=2, pady=2, sticky="w")
        ttk.Label(joker_frame, text="Edition", width=10).grid(row=0, column=3, padx=2, pady=2, sticky="w")
        self.joker_rows = [JokerRow(joker_frame, i + 1, on_change=self._rescore)
                           for i in range(5)]

        # Joker reference panel (shows description of selected joker)
        self.joker_help_var = tk.StringVar(value="Pick a joker to see its description here.")
        help_frame = ttk.LabelFrame(parent, text="Joker description", padding=6)
        help_frame.pack(fill="x", pady=(0, 6))
        ttk.Label(help_frame, textvariable=self.joker_help_var,
                  wraplength=420, justify="left").pack(anchor="w")
        # Update the help panel whenever a joker name changes
        for jr in self.joker_rows:
            jr.name.bind("<<ComboboxSelected>>",
                         lambda e, jr=jr: self._on_joker_change(jr), add="+")

        # Blind
        blind_frame = ttk.LabelFrame(parent, text="Boss blind", padding=6)
        blind_frame.pack(fill="x", pady=(0, 6))
        self.blind_var = tk.StringVar(value="(none)")
        cb = ttk.Combobox(blind_frame, values=BLINDS, textvariable=self.blind_var,
                          state="readonly", width=20)
        cb.pack(side="left", padx=4)
        cb.bind("<<ComboboxSelected>>", lambda e: self._rescore())
        self.blind_help_var = tk.StringVar(value="")
        ttk.Label(blind_frame, textvariable=self.blind_help_var,
                  foreground="#5f6368").pack(side="left", padx=8)
        cb.bind("<<ComboboxSelected>>", lambda e: self._on_blind_change(), add="+")

    def _add_card_header(self, frame: ttk.Frame):
        headers = ["Slot", "Rank", "Suit", "Enhancement", "Seal", "Edition"]
        for col, h in enumerate(headers):
            ttk.Label(frame, text=h, font="AppFont9b").grid(
                row=0, column=col, padx=4, pady=2, sticky="w")

    def _build_output_pane(self, parent: ttk.Frame):
        ttk.Label(parent, text="Step trace", font="AppFont11b").pack(anchor="w")

        # Listbox of steps
        list_frame = ttk.Frame(parent)
        list_frame.pack(fill="both", expand=True, pady=(4, 4))

        cols = ("idx", "phase", "title", "chips", "mult")
        self.tree = ttk.Treeview(list_frame, columns=cols, show="headings", height=20)
        self.tree.heading("idx", text="#")
        self.tree.heading("phase", text="Phase")
        self.tree.heading("title", text="Step")
        self.tree.heading("chips", text="Chips")
        self.tree.heading("mult", text="Mult")
        self.tree.column("idx", width=40, anchor="e")
        self.tree.column("phase", width=80)
        self.tree.column("title", width=380)
        self.tree.column("chips", width=80, anchor="e")
        self.tree.column("mult", width=80, anchor="e")
        sb = ttk.Scrollbar(list_frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.tree.bind("<<TreeviewSelect>>", self._on_tree_select)

        # Configure phase colors as tags
        for phase, color in PHASE_COLORS.items():
            self.tree.tag_configure(phase, foreground=color)

        # Detail panel
        detail = ttk.LabelFrame(parent, text="Step detail", padding=8)
        detail.pack(fill="x", pady=(0, 4))

        self.detail_title = tk.StringVar(value="—")
        self.detail_narrative = tk.StringVar(value="")
        self.detail_math = tk.StringVar(value="")
        self.detail_running = tk.StringVar(value="")

        ttk.Label(detail, textvariable=self.detail_title,
                  font="AppFont12b").pack(anchor="w")
        ttk.Label(detail, textvariable=self.detail_running,
                  font="AppMono10", foreground="#1a73e8").pack(anchor="w", pady=(2, 4))
        ttk.Label(detail, textvariable=self.detail_narrative,
                  wraplength=720, justify="left").pack(anchor="w", pady=(0, 4))
        ttk.Label(detail, textvariable=self.detail_math,
                  font="AppMono10", foreground="#188038").pack(anchor="w")

        # Nav buttons
        nav = ttk.Frame(parent)
        nav.pack(fill="x")
        ttk.Button(nav, text="⏮ Home", command=lambda: self._goto(0)).pack(side="left", padx=2)
        ttk.Button(nav, text="◀ Prev", command=self._prev).pack(side="left", padx=2)
        ttk.Button(nav, text="Next ▶", command=self._next).pack(side="left", padx=2)
        ttk.Button(nav, text="End ⏭", command=lambda: self._goto(max(0, len(self.steps) - 1))).pack(side="left", padx=2)

    # -----------------------------------------------------------------------
    # Event handlers
    # -----------------------------------------------------------------------
    def _on_mode_change(self):
        if self.mode.get() == "real":
            messagebox.showinfo(
                "Real-trace mode (V2)",
                "Real-trace mode will instrument BestHand.lua's score_combo with a "
                "trace emitter and run it via lua + harness.lua. Coming in V2.\n\n"
                "Falling back to Pedagogy mode for now.")
            self.mode.set("pedagogy")

    def _on_joker_change(self, jr: JokerRow):
        n = jr.name.get()
        if n in ("(empty)", "") or n not in JOKERS:
            self.joker_help_var.set(f"{n}: (no description)")
            return
        self.joker_help_var.set(f"{n}: {JOKERS[n]['desc']}")

    def _on_blind_change(self):
        b = self.blind_var.get()
        helps = {
            "(none)":      "No boss blind.",
            "The Eye":     "Disables hand types you've already played this round (informational only in V1).",
            "The Mouth":   "Only one hand type per round (informational only in V1).",
            "The Psychic": "Must play exactly 5 cards or score is 0.",
            "The Arm":     "Reduces played hand level by 1 (no effect at level 1, which V1 assumes).",
            "The Flint":   "Halves both base chips and base mult at end of scoring.",
        }
        self.blind_help_var.set(helps.get(b, ""))

    def _rescore(self):
        played = [r.to_card() for r in self.played_rows]
        played = [c for c in played if c is not None]
        held = [r.to_card() for r in self.held_rows]
        held = [c for c in held if c is not None]
        jokers = [r.to_joker() for r in self.joker_rows]
        jokers = [j for j in jokers if j is not None]
        blind = self.blind_var.get()

        try:
            steps, final = score(played, held, jokers, blind)
        except Exception as e:
            messagebox.showerror("Score error", f"{type(e).__name__}: {e}")
            return

        self.steps = steps
        self.score_var.set(f"Final score: {final:,}")
        # Find the hand-type step for the footer
        hand = next((s for s in steps if s.phase == "Identify"), None)
        if hand:
            self.hand_var.set(hand.title.replace("Hand type: ", ""))
        else:
            self.hand_var.set("—")

        # Repopulate tree
        for iid in self.tree.get_children():
            self.tree.delete(iid)
        for i, s in enumerate(steps):
            chips_str = f"{s.chips:,.4g}" if s.chips else "0"
            mult_str = f"{s.mult:,.4g}" if s.mult else "0"
            self.tree.insert("", "end", iid=str(i),
                             values=(i + 1, s.phase, s.title, chips_str, mult_str),
                             tags=(s.phase,))
        # Select first step
        if steps:
            self._goto(0)
        else:
            self._clear_detail()

    def _on_tree_select(self, _event):
        sel = self.tree.selection()
        if not sel:
            return
        idx = int(sel[0])
        self._show_step(idx)

    def _show_step(self, idx: int):
        if not (0 <= idx < len(self.steps)):
            return
        s = self.steps[idx]
        self.current_step.set(idx)
        self.detail_title.set(f"[{s.phase}] {s.title}")
        self.detail_running.set(f"chips = {s.chips:g}    mult = {s.mult:g}    running = {s.chips * s.mult:,.0f}")
        self.detail_narrative.set(s.narrative)
        self.detail_math.set("Math:  " + s.math if s.math else "")

    def _goto(self, idx: int):
        if not self.steps:
            return
        idx = max(0, min(idx, len(self.steps) - 1))
        self.tree.selection_set(str(idx))
        self.tree.see(str(idx))
        self._show_step(idx)

    def _prev(self):
        self._goto(self.current_step.get() - 1)

    def _next(self):
        self._goto(self.current_step.get() + 1)

    def _clear_detail(self):
        self.detail_title.set("—")
        self.detail_running.set("")
        self.detail_narrative.set("")
        self.detail_math.set("")

    # -----------------------------------------------------------------------
    # Fixtures
    # -----------------------------------------------------------------------
    def _load_demo_fixture(self):
        """A two-pair Aces-and-Kings hand with a couple of jokers, to give the
        user something interesting to step through immediately."""
        self._clear_all(_rescore=False)
        demo_played = [
            Card("A", "Hearts", "bonus", "none", "none"),
            Card("A", "Spades", "none", "red", "none"),
            Card("K", "Hearts", "none", "none", "polychrome"),
            Card("K", "Clubs", "mult", "none", "none"),
            Card("3", "Diamonds"),  # kicker, won't score in Two Pair
        ]
        demo_jokers = [
            Joker("Lusty Joker"),
            Joker("Clever Joker", "polychrome"),
            Joker("Photograph"),
        ]
        for r, c in zip(self.played_rows, demo_played):
            r.rank.set(c.rank); r.suit.set(c.suit)
            r.enh.set(c.enhancement); r.seal.set(c.seal); r.ed.set(c.edition)
        for r, j in zip(self.joker_rows, demo_jokers):
            r.name.set(j.name); r.ed.set(j.edition)
        self.blind_var.set("(none)")
        self._on_blind_change()
        self._rescore()

    def _clear_all(self, _rescore: bool = True):
        for r in self.played_rows + self.held_rows:
            r.rank.set("(empty)"); r.suit.set("Spades")
            r.enh.set("none"); r.seal.set("none"); r.ed.set("none")
        for r in self.joker_rows:
            r.name.set("(empty)"); r.ed.set("none")
        self.blind_var.set("(none)")
        self._on_blind_change()
        if _rescore:
            self._rescore()


def main():
    _enable_dpi_awareness()
    root = tk.Tk()
    try:
        style = ttk.Style(root)
        style.theme_use("vista" if "vista" in style.theme_names() else "default")
    except Exception:
        pass
    TraceViewerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
