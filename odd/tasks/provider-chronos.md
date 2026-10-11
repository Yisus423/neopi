# Provider layer: our own, on chronos (replacing nimgent)

## Goal

neopi drops nimgent entirely: the provider layer is written in neopi, on
chronos, with the test injection built into the contract from day one. The
Lua surface (`neopi.provider.generate/stream/setScripted`) and the engine
stay unchanged — the swap is contained in `provider.nim` (the
anti-corruption layer absorbing its own replacement, the plan since the
design).

## The decided basis (2026-10-06 — the user's call after the study)

- **Order**: provider first, then the TUI replacement (the smaller swap
  first; the TUI wants to consume the new provider's typed events).
- **chronos, not asyncdispatch**: neopi touches asyncdispatch ZERO times
  (all of it is nimgent's internals) — zero migration; chronos brings
  first-class cancellation (cancelSoon/cancelAndWait — asyncdispatch's
  inverted Callback contract caused the one-char timer bug), timeouts
  (awaitWithTimeout — a hung stream hangs forever today), its own
  dispatcher (poll() for the future TUI loop), and production proof
  (status-im/nimbus).
- **The contract**: the stream as a typed event flow (pi's
  StreamFunction → AssistantMessageEventStream pattern) with the
  **transport injectable in the options** — the injection must exist in
  the design; it cannot be added cheaply later.
- **The pure-Nim search (2026-10-06, the user's call) settled the
  build-vs-reuse split**: chronos's httpclient IS the streaming transport
  (AsyncStreamReader + chunked, bearssl TLS — no OpenSSL); iceberg-work/sse
  IS the SSE parser (the incremental feed, the `:`-comment keepalives, the
  multiline data, the CRLF — spec-complete, 588 lines, zero deps); the
  OpenAI wire layer is ours — planetis-m/openai has no streaming and rides
  relay→libcurl, openai_leap has streaming but rides Curly→libcurl with
  live-only tests and no injection point (it fails the two criteria this
  feature just fixed: keyless testability and the minimal-deps profile).
  The dependency rule that came out of it: a dependency earns its place if
  it is production-proven (chronos) or so small and focused that absorbing
  it is trivial (sse, 588 lines — the fork-seed pattern applies trivially).
- **Three test levels** (the pi study): L1 wire (a fake transport + the
  real OpenRouter SSE fixtures → the real parser; the .env dependency
  leaves `nimble test`), L2 provider (the scripted provider — exists),
  L3 live (opt-in only; tp_real demotes).
- **The performance lesson** (for the TUI, noted here): nimterm's
  flushFrame does clear + full render per delta — O(screen) per delta;
  nvim's invalid-regions diff is the fix. The TUI slice designs for it.

## Non-goals (this feature)

- The TUI replacement (the next feature; nimterm stays until then).
- The other providers: OpenRouter (openai-compatible) + scripted only.
- The Lua surface changes: none (the engine and the tests keep their
  contract).
- The chronos TUI-loop integration: the future TUI's concern; this layer
  blocks with chronos's waitFor at the Lua boundary (the same shape as
  nimgent's internal waitFor today).

## Tasks

- [ ] 1. The ROADMAP restructured: the decoupling phase active, the
      slices named (docs commit)
- [ ] 2. chronos as a dependency + the wire contract: WireRequest/
      WireResponse/Transport (the injection point) + the FakeTransport
      (L1) — test-first (RED → GREEN)
- [ ] 3. The SSE layer: adopt iceberg-work/sse (the incremental feed
      parser, pure Nim, zero deps, MIT — the search found it; writing the
      ~200-line state machine would duplicate it) + the OpenRouter wire
      fixtures (the capture script + the committed fixture) + our mapping
      SSE → StreamEvent — test-first
- [ ] 4. The openai-compatible provider: the request builder (the dummy
      keys asserted) + the stream on chronos (the cancellation + the
      timeout) — test-first
- [ ] 5. The scripted provider port (L2) without nimgent
- [ ] 6. The Lua surface swap: expose.nim rewired to the new layer; the
      engine and the TUI untouched; the whole suite green keyless
- [ ] 7. nimgent out of neopi.nimble (and the libpcre build note); tp_real
      → opt-in; AGENTS.md refreshed
- [ ] 8. Work-unit commits on main; record evidence here

## Evidence

- (in progress)
