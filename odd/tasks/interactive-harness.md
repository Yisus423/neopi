# Interactive harness: the TUI (slice 5a)

## Goal

neopi becomes usable daily: the interactive TUI. The design principle (the
user's): **separate the interface from the engine** — the engine (the loop in
Lua, runtime/agent.lua) does not change; the interface (Nim, the TUI) drives
it and renders the session.

## Verified basis (obs #1171)

- pi's TUI: the Component model (62 implementations) + requestRender (the
  invalidate pattern); the Terminal abstraction; extensions ADD components.
- nvim: the grid + dirty tracking + the flush.
- illwill 0.4.1 (johnnovak, 473 stars, PROVEN): the FullBuffer + keyboard
  input + raw mode + colors — the terminal mechanism, installed.
- pi's footer: the active provider, model, tokens, cost.

## Non-goals (slice 5b/5c)

- Steering/follow-up/abort queues (5b).
- neopi.ui.* (the Lua UI primitives for extensions — 5b).
- The mouse (illwill supports it; not needed for the MVP).
- Compaction UI (compaction works through the loop already; its rendering is
  the transcript's summary entry).

## Design

- The ENGINE stays: the loop (runtime/agent.lua) + the session tree + the
  tools. The interface drives it.
- The exposure gains `neopi.provider.stream(config, onEvent)` — the streaming
  variant (the deltas live). The onEvent is a Lua function; the TUI creates
  its sink as a Lua function via lua_pushcclosure (a Nim closure that calls
  the TUI's render callback — the makeLuaToolExecute pattern).
- The loop (runtime/agent.lua) uses stream when the config has onEvent (the
  text deltas render live; the tool calls and results render as they land).
- The TUI (Nim, src/neopi/tui.nim): illwill's FullBuffer + the key input +
  the raw mode; the component model (pi's pattern): components that render
  into the buffer + requestRender (invalidate + re-render + flush).
- The three components (the MVP set): the transcript (the session tree's
  entries: user/assistant/toolResult/compaction, scrollable), the composer
  (the editable input line), the footer (the provider, model, tokens — pi's
  footer). requestRender on: the input change, the stream deltas, the
  entries, the resize.
- The keys (the MVP): Enter sends; Esc clears the composer; Ctrl+C exits;
  the scroll (PgUp/PgDn or arrows) on the transcript.
- The flow: with a prompt arg, print mode (unchanged); with no args: the TUI
  opens → the user types → Enter → the loop runs with the live streaming →
  the session persists (the same JSONL tree).
- src/neopi.nim: the TUI mode wired (no prompt → tuiRun()).

## Tasks

- [x] 1. The exposure: neopi.provider.stream (the onEvent variant)
- [x] 2. The loop (runtime/agent.lua): stream when the config has onEvent
- [ ] 3. The TUI: illwill + the component model (requestRender)
- [ ] 4. The three components: transcript + composer + footer
- [ ] 5. The keys + the flow (no prompt → the TUI; the session persists)
- [ ] 6. Work-unit commit(s) on main; record evidence here

## Evidence

- `12ebb39` — feat: the streaming exposure - neopi.provider.stream with live
  deltas (4 files, 239 insertions: the parseProviderConfig refactor + the
  stream entry + the loop's stream + the tests)
- nimble test verbatim: "[Summary] 68 tests run (2.04s): 68 OK, 0 FAILED,
  0 SKIPPED" + busted "4 successes" — the streaming tests (the deltas land +
  the response returns + the no-onEvent path) pass.
- A real bug fixed: the Lua-callback bridges did not load the stored fn via
  lua_rawgeti before pcall — the tool bridge worked by the call stack's
  accident; the stream bridge exposed it ("attempt to call a table value").
  Both bridges load the fn now.
- Re-sliced: 5a-1 (the streaming, done) + 5a-2 (the TUI, remaining) — the
  writer stalled on the big reads; the parent implemented the small slice
  inline.
