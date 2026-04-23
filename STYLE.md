# Lua style

This project follows the **[Olivine-Labs Lua style guide](https://github.com/Olivine-Labs/lua-style-guide)** strictly. If something isn't covered here, defer to the upstream guide.

## The rules in one paragraph

Two-space soft tabs. Single-quoted strings (double only when the literal contains a `'`). No semicolons — one statement per line. 80-char line limit; split long strings with concatenation. `snake_case` for variables and functions, `PascalCase` for factory functions. Boolean-returning functions prefix with `is` / `has`. Use `local function name()` form. Always declare with `local`. Validate and return early. One space around operators and after commas; one space inside braces, none inside parens. Trailing newline at EOF, no trailing whitespace. No leading commas, no trailing comma on the last table item.

## Project-specific exceptions

Two of the upstream rules would break Steamodded mod loading, so we do **not** apply them:

- **Rule 40 (all-lowercase filenames):** `BestHand.json` declares `"main_file": "BestHand.lua"` and Steamodded loads from that exact path. We keep the PascalCase filenames.
- **Rules 41–43 (`src/` / `spec/` / `bin/` layout):** Steamodded expects the mod manifest and main file at the mod root. We keep the flat layout.

## Tooling

- `luac -p <file.lua>` parses without executing — use it as a cheap syntax check after edits (Lua 5.1 is what Balatro ships with).
- When in doubt about a rule, read the upstream guide directly: <https://github.com/Olivine-Labs/lua-style-guide>.
