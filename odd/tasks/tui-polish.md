# TUI polish: the colors, the abort marker, the working indicator

## Goal

The TUI stops looking rough: the colors per entry kind (pi-like), the
abort marker on the partial turns, and the working indicator on the footer
while the stream runs.

## Decision (2026-09-30 — the user's call)

The order: async first (done — 950142f), then the polish. The polish is
this slice.

## Design

- **lineColor(line)** (pure, testable): the color per line prefix —
  "you: " → fgGreen, "assistant: " → fgNone, "-- compaction: " →
  fgMagenta, "tool " → fgRed when the line carries "(error)", fgCyan
  otherwise. drawScreen applies it per line (setForegroundColor + write);
  no signature changes in the pure layer.
- **The abort marker** (transcriptLines): the assistant entry with
  stopReason "aborted" renders " (aborted)" after the text.
- **The working indicator** (drawScreen): the footer gains " | working"
  while the streaming text is in flight.
- **The keys/flow**: unchanged.
- **The tests** (tp_tui): lineColor's prefixes; transcriptLines' abort
  marker.
- **Non-goals**: themes (a color config); the widget colors (plain text
  lines); the mouse; box drawing borders.

## Tasks

- [x] 1. lineColor + drawScreen's colors + the abort marker + the working
      indicator
- [x] 2. The tests: tp_tui (lineColor + the abort marker)
- [x] 3. Work-unit commit on main; record evidence here

## Evidence

- The parent implemented the slice inline (the writers stall systematically
  — the established lesson).
- nimble test verbatim: "[Summary] 110 tests run (1.88s): 110 OK, 0 FAILED,
  0 SKIPPED" + busted "10 successes" — lineColor's prefixes (the user's
  green, the assistant's default, the tools cyan, the errors red, the
  compaction magenta) and the abort marker (the partial turns render
  " (aborted)") pass.
- nimlangserver nimCheckFile: 0 diagnostics on tui.nim; the production
  binary builds clean (3.4M).
- The design: lineColor is PURE (the color per line PREFIX — no signature
  changes in the pure layer: the mixed line-to-entry mapping stays lost but
  the prefix carries the kind); drawScreen applies it per line with
  setForegroundColor + resets to fgNone before the composer/footer; the
  footer gains " | working" while the streaming text is in flight (pi's
  working indicator); no dirty tracking beyond illwill's displayDiff.
- Known limits: no themes (the colors are hardcoded); the widgets stay
  plain text; no box borders; the working indicator is a suffix (no
  spinner).
