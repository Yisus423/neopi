# The TUI, ours (replacing nimterm)

## Goal

neopi's interface stops depending on nimterm — and with it the last niminal
component. The motivation is the SAME as the provider layer's, and it is
trust, not a measured defect: the creator of the niminal stack (nimterm,
nimlet, nimwire, nimgent — author "martin") deleted three of those repos
once already. The ROADMAP's performance note ("the per-delta full render is
the performance defect") is a HYPOTHESIS read off the code, not a
measurement, and this feature's first task exists to settle it with numbers
before anything is rewritten.

This is a work in progress: the first source write happens after the
measurement harness, and the slices below task 2 are provisional until the
harness and the scope decision land.

## What the reconnaissance found (2026-10-11, read-only)

The basis, so the plan is not built on the ROADMAP note's assumptions
(paths are in ~/proyectos/nimterm unless said otherwise):

- **The backend is already an interface.** `TerminalBackend` (backend.nim)
  declares `init`/`shutdown`/`size`/`readEvent`/`wake`/`present`/
  `resetPresentation` with no-op base bodies; a fake is a subclass (the docs
  document it: `present` stores `frame.copy()`). `newApp` does NOT initialize
  the backend — raw terminal mode starts only at `init`/`run`. Headless
  rendering and headless measurement are free today.
- **The canvas is headless.** `newCanvas(size, fill)` (canvas.nim:23) and
  `Widget.render(canvas, area)` (widget.nim:66); the assertion surface is
  `canvas.plainText` and `getCell(x, y)`. neopi's own test file drives the
  TUI with a nil app today (tests/tp_tui.nim:229), so the render path is not
  exercised by the suite at all.
- **The terminal write is ALREADY differential.** `frameOutput(frame,
  previous, force)` (frame.nim:17) compares cells row by row, emits only the
  damaged rows, keeps a wide glyph together with its continuation cell, and
  reuses the active SGR run. Every backend presents through it.
- **The transcript widget caches its lines** (`invalidateLines`,
  widgets/transcript.nim:85), so its per-delta re-render is not obviously
  O(all lines).
- **The loop is documented both ways**: `app.run()` (nimterm owns the loop)
  and `init`/`step`/`flush`/`shutdown` for a HOST-OWNED loop ("use them when
  another event loop owns the process"). neopi uses `app.run()`
  (src/neopi/tui.nim:598) while the stream deltas flush from the sink inside
  chronos's `waitFor` — the nesting the replacement is meant to invert.
- **`App.render()`** (app.nim:193) is `frame.clear()` + a full widget-tree
  render + `backend.present(frame)`; neopi's `flushFrame` (tui.nim:235) then
  renders its three widgets into `app.frame` a second time. That double pass
  is the concrete cost to measure.
- **The dependencies**: nimterm requires `unicodedb` (author: Esteban Castro
  Borsani / @nitely — the illwill author, an INDEPENDENT community package,
  MIT, pure Unicode data, NOT the niminal "martin" stack) and Nim >= 2.0.
- **neopi has NO pty harness**: `grep -rn "openpty\|TIOCSCTTY"` over the repo
  is empty, so AGENTS.md's pty bullet is stale (a docs item for this slice).

## Tasks

- [x] 1. The measurement harness and the baseline: `bench/tui_bench.nim` (a
      standalone binary, `-o:build/tui_bench`, plus a `nimble bench` task)
      that builds a synthetic transcript of N entries, renders frames
      headless through a fake backend, and reports — per-frame ms for N in
      {50, 500, 5000} with the scaling, the key-dispatch-to-frame latency,
      the in-process time to the first frame, and the peak RSS
      (`/proc/self/status` VmHWM; Linux-only like the rest of the project).
      It must print one stable, greppable line per measurement so future
      runs diff against each other. The numbers are recorded HERE.
- [ ] 2. The scope decision (design only, no code): from the measurements
      plus a capability inventory, fix what our core must provide to not
      regress (the cell + style model, the damaged-row diff, the transcript
      line cache, unicode widths, markdown, the widget set we actually use,
      the backend contract, the loop ownership) and what is dropped (themes,
      menus, questions, mouse, the kitty/modifyOtherKeys protocols,
      multipart, clipboard — decide each explicitly). Recorded here with the
      numbers that justify it.
- [ ] 3. Our own terminal core + the fake backend + chronos owning the loop
      (provisional until task 2): the cell/canvas/style model, the damaged
      row diff, a backend contract with a POSIX implementation and a fake,
      and the loop inverted so chronos drives and the TUI is a component.
      Test-first on the diff (only damaged rows emitted, wide glyphs travel
      with their continuation) and on the fake backend contract.
- [ ] 4. Our own transcript/composer/footer on that core, with the stream
      sink attached (the deltas render live) — and the provider's event
      contract extended for the thinking delta, which is the window where
      the ROADMAP #18 provider follow-ups fold in.
- [ ] 5. The width and markdown primitives (the last nimterm/unicodedb tie):
      decide with evidence between keeping `unicodedb` (independent, MIT,
      data-only) and absorbing a minimal East-Asian-width table plus the
      combining marks we actually render.
- [ ] 6. nimterm out: the nim.cfg path, the docs (AGENTS.md/README/
      ARCHITECTURE, including the stale pty claim), the ROADMAP.

## Evidence

- Task 1, the harness and the baseline (2026-10-11): `bench/tui_bench.nim`
  plus the `nimble bench` task. It renders headless through a fake
  `TerminalBackend` (a counter where the terminal write would be) with the
  project's real widgets, so it needs no terminal, and it prints one
  greppable line per size. Each metric runs until its sample cap or its 2s
  budget — the costs are super-linear, so a fixed sample count made the
  sweep unusable (the first attempt had to be killed by a timeout); the
  `_n=` count in each line says how much confidence the median has.

  Baseline, this machine, 120x40 canvas, synthetic entries long enough to
  wrap (`build/tui_bench`, the full sweep in ~35s; medians over the sample
  counts shown, each phase capped at its 2s budget):

  | entries | idle ms (n) | render ms (n) | delta ms (n) | key ms (n) | peak RSS |
  | --- | --- | --- | --- | --- | --- |
  | 50 | 7.55 (200) | 7.23 (200) | 74.6 (26) | 7.49 (200) | 3.7 MB |
  | 500 | 11.14 (169) | 7.25 (200) | 680.4 (3) | 11.02 (171) | 5.8 MB |
  | 5000 | 46.73 (43) | 7.24 (50) | 6588.5 (1) | 47.22 (43) | 28.2 MB |

  The 5000-entry delta rests on ONE sample (a single delta there costs more
  than the 2s budget) and it varies ~6.6-7.3 s between runs; the smaller
  sizes have 3 and 26 samples. Everything else above 50 samples is stable
  within a few percent.

  (`idle` = one `flushFrame`; `render` = `App.render`, the app loop's clear
  + full tree render + present; `delta` = one streamed token applied to the
  transcript + `invalidateLines` + `flushFrame`, the sink's exact sequence,
  from a restored starting state; `key` = one key dispatched + `flushFrame`.)

  The harness caught two bugs in ITSELF while settling in, both recorded
  because they are the failure mode of this kind of instrument: (1) the
  delta samples were measured on a GROWING transcript (`apply` appends to
  the last item), so the numbers escalated sample after sample and 200
  samples of a "90 ms" metric ran for minutes — the fix restores the tail
  before each sample; (2) the per-sample clock and the phase budget shared
  one variable, so the budget compared against the sample's own start and
  never fired, silently running every metric to its sample cap. Both were
  visible as implausible numbers rather than as errors.

  **The measurement refutes the ROADMAP note that justified the slice.** The
  full widget-tree render is FLAT — ~7.2 ms at 50, 500 and 5000 entries —
  because nimterm's per-item line caches work. What is O(transcript) is the
  DELTA path: 74.6 ms at 50 entries, 680 ms at 500, 6.6 SECONDS at 5000
  (12x the transcript for ~9x the cost at 50→500, and no sign of leveling).
  The cause is all-or-nothing invalidation: `invalidateLines()`
  (nimterm/widgets/transcript.nim:85) resets EVERY item's cache — "Rebuild
  every cached item line" — and it is the only invalidation the widget
  offers, so one streamed token re-wraps and re-renders the whole
  transcript. neopi's sink has to call it per delta (src/neopi/tui.nim:338)
  because `apply` mutates the last item in place.

  Two further costs, both O(transcript) with small constants and both in
  OUR code rather than nimterm's: `refreshFooter` (src/neopi/tui.nim:152)
  walks `sess.history()` on every frame, which is the growth of the `idle`
  and `key` columns (7.6 → 46.7 ms; `key` is indistinguishable from `idle`,
  so the keystroke itself costs nothing measurable — the frame does) and the
  footer sums tokens per frame instead of caching them. Side measurement,
  not a TUI cost: the session write path costs ~1.7 ms per `append` (a
  5000-entry synthetic session takes ~8.6 s to build, which dominates the
  harness's `first_frame_ms`).

  Not yet measured, and named here so it is not confused with measured
  data: the real process's cold start (the <100 ms target) needs the real
  binary under a pty — neopi has NO pty harness (`grep -rn
  "openpty\|TIOCSCTTY"` is empty; AGENTS.md's claim about one is stale), so
  it is a task-2/3 item. The peak RSS (28.2 MB at 5000 entries) is already
  inside the <50 MB target.

  **The fix (same day, one line of OURS).** The second finding is that the
  sledgehammer is in our code. nimterm's transcript MODEL bumps the mutated
  item's `revision` on every event (transcript.nim:73, 85, 104, ...) and
  `ensureLayout` re-renders only the items whose revision changed
  (widgets/transcript.nim:233) — but neopi's sink called the MODEL's apply
  and then `invalidateLines()`, which resets EVERY cache revision
  (widgets/transcript.nim:88). Calling the WIDGET's apply instead
  (widgets/transcript.nim:212 — it clears `linesValid` and leaves the
  per-item caches to the revision check) is the entire fix: one line in
  `tuiOnEventCB` (src/neopi/tui.nim). Re-measured with the same harness,
  whose delta now runs the sink's own path and carries a correctness guard
  (the delta must reach the transcript AND appear on the presented canvas —
  a cheaper delta that stops rendering would be a wrong fix):

  | entries | delta before | delta after | speedup |
  | --- | --- | --- | --- |
  | 50 | 74.6 ms | 7.96 ms | 9x |
  | 500 | 680.4 ms | 12.05 ms | 56x |
  | 5000 | 6588.5 ms | 54.87 ms | 120x |

  The delta is now bounded by the frame, not by the transcript. What still
  grows with the transcript is the FRAME itself (`idle` 7.6 → 47.7 ms), and
  that is ours as well: `refreshFooter` walks `sess.history()` per frame.
  It is the next work unit, and the harness already carries its baseline.

  **The frame fix (same day, ours, ~15 lines).** `refreshFooter` walked
  `sess.history()` on every frame — that was the entire growth of the
  `idle`/`key` columns. The totals are now memoized in the `TuiState` behind
  an explicit validity key: the session's identity (a `/resume` swap rebinds
  it), the active branch's tip and the entry count. Every way usage arrives
  here changes one of the three (`append` grows the count, `navigateTo` moves
  the tip, entries are never edited in place). The pure `footerText` keeps
  the honest walk as the reference, and tests/tp_tui.nim ("the footer")
  compares the memoized line against it after appends AND after a navigate
  that leaves the entry count unchanged — the case a count-only key would get
  wrong.

  | entries | idle before | idle after | delta before | delta after |
  | --- | --- | --- | --- | --- |
  | 50 | 7.55 | 7.20 | 74.6 | 7.54 |
  | 500 | 11.14 | 7.23 | 680.4 | 8.11 |
  | 5000 | 46.73 | 7.21 | 6588.5 | 13.40 |

  The frame is now FLAT at ~7.2 ms from 50 to 5000 entries, and the peak RSS
  fell from 28.2 to 23.5 MB at 5000 (the per-frame `history()` seq is gone).
  Counting from the first measurement, at 5000 entries the streamed token
  went 6588 → 54.9 → 13.4 ms and the frame 46.7 → 7.2 ms. **Nothing in the
  interface grows with the transcript any more**, and the suite pins the new
  totals test: 113 tests green.

  What this means for task 2: the performance argument for replacing the
  interface is now GONE — the canvas, the damaged-row present and the flat
  full render were already good, and the one real defect was our own
  invalidation call. The replacement stands on the trust reason alone
  (leaving the last niminal component), which is the honest reason it had
  from the start. The footer's per-frame history scan is a small, separable
  fix in our file.
