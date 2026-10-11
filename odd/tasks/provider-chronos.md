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

- [x] 1. The ROADMAP restructured: the decoupling phase active, the
      slices named (docs commit)
- [x] 2. chronos as a dependency + the wire contract: WireRequest/
      WireResponse/Transport (the injection point) + the FakeTransport
      (L1) — test-first (RED → GREEN)
- [x] 3. The SSE layer: adopt iceberg-work/sse (the incremental feed
      parser, pure Nim, zero deps, MIT — the search found it; writing the
      ~200-line state machine would duplicate it) + the OpenRouter wire
      fixtures (the capture script + the committed fixture) + our mapping
      SSE → StreamEvent — test-first
- [x] 4. The openai-compatible provider: the request builder (the dummy
      keys asserted) + the stream on chronos (the cancellation + the
      timeout) — test-first
- [x] 5. The scripted provider port (L2) without nimgent
- [x] 6. The Lua surface swap: expose.nim rewired to the new layer; the
      engine and the TUI untouched; the whole suite green keyless
- [ ] 7. nimgent out of neopi.nimble (and the libpcre build note); tp_real
      → opt-in; AGENTS.md refreshed
- [ ] 8. Work-unit commits on main; record evidence here

## Evidence

- The ROADMAP restructure (bbfd96d) + the pure-Nim search amendment
  (0d27e4d): chronos + iceberg-work/sse adopted, the OpenAI wire layer
  ours, the dependency rule (production-proven or trivially absorbable).
- The wire contract (2026-10-11): chronos in neopi.nimble (the local
  4.0.4 cache resolves) + the sse sibling checkout (~/proyectos/sse, the
  nimterm pattern — the fork seed) wired through nim.cfg; the wire
  contract in src/neopi/wire.nim: WireRequest (value) / WireResponse
  (status + the chunk iterator: next() yields "" at the EOF, close() is
  the cancel path) / Transport (the abstract fetch) / FakeTransport (the
  requests recorded for the assertions, the canned responses served in
  order) — the injection point the pi study fixed. The methods +
  chronos's {.async.} compose fine (the concern about the method+async
  combination did not materialize). Test-first: RED (cannot open file:
  neopi/wire) → GREEN. The compile lessons: seq.delete is single-arg in
  Nim 2.2; `waitFor resp.next() == ""` parses as waitFor the whole
  comparison — the checks parenthesize. One test bug caught (the second
  fetch without a canned response → the honest AssertionDefect). nimble
  test verbatim: "[Summary] 88 tests run (3.13s): 88 OK, 0 FAILED, 0
  SKIPPED" + busted "13 successes" — the wire tests joined the dispatcher
  (tp_all imports tp_wire).
- The SSE mapping (2026-10-11): the capture script
  (tests/capture_openrouter.sh — one curl run per fixture with the .env
  key; the fixtures committed: openrouter-text-stream.txt 128KB,
  openrouter-tool-stream.txt 118KB) caught the real wire shape: the
  reasoning arrives as delta.reasoning (OpenRouter's unified field, with
  reasoning_details), every chunk carries the empty content + the role,
  the usage rides the last chunk (with the reasoning_tokens breakdown),
  the tool calls stream the id+name in the first fragment and the
  argument JSON in fragments after (14 fragments → one call_.../write
  /{"path": "notas/x.txt", "content": "hola"}), finish_reason
  "tool_calls"/"stop", the [DONE] sentinel. The mapping
  (src/neopi/openai_compat.nim): mapOaiChunk(data, var OaiAccum) →
  seq[StreamEvent] — the contract preserved exactly (the reasoning
  deltas DROPPED, the same as nimgent's adapter today; the thinking
  kind is the TUI slice's contract extension), the fragments accumulate
  by tool_calls index, toToolCalls() parses the joined args (the
  unparsable args surface as JNull — the engine reports a tool failure
  instead of aborting), the finish reasons map stop→frStop,
  tool_calls→frToolUse, length→frMaxTokens. Test-first: RED (the module
  missing) → GREEN; the compile lesson: std/json's getOrDefault returns
  NIL on a missing key — field() wraps it (nil has no kind: the SIGSEGV
  was caught by the first test). nimble test verbatim: "[Summary] 98
  tests run (8.97s): 98 OK, 0 FAILED, 0 SKIPPED" + busted "13 successes"
  — the two L1 tests replay the real fixtures end-to-end keyless.
- The scripted L2 transport (2026-10-11): ScriptedTransport in
  openai_compat.nim — one ScriptStep per fetch, encoded as the real
  OpenAI wire (scriptChunks: the inverse of the mapping), so the L2
  tests exercise the FULL stack (the builder → the SSE parse → the
  mapping → the callback) with zero nimgent. Test-first caught the
  encoder bug: the JSON chunks went out without the `data: ` prefix (the
  parser treats the unknown fields per spec — silently ignored; only the
  [DONE] chunk, which had the prefix, ever mapped). The debug path that
  found it: the stderr (the async stdout interleaves), the stage-by-stage
  feed, and an isolated parser test (the parser was correct all along).
  wire.nim gained newFakeWireResponse (the canned fields stay private to
  the module) and the base close() is a no-op default (the abstract
  assert masked a timeout raise behind a defect). nimble test verbatim:
  "[Summary] 109 tests run (5.01s): 109 OK, 0 FAILED, 0 SKIPPED" + busted
  "13 successes".
- The swap (2026-10-11, task 6): nimgent leaves the code. The type block
  moved verbatim out of provider.nim into src/neopi/primitives.nim because
  openai_compat.nim needs the caller-facing types (StreamEvent, Response,
  Tool...) while provider.nim must call streamChat — importing back would
  be a cycle. provider.nim re-exports primitives, so `import neopi/provider`
  keeps the whole surface and expose.nim stays byte-identical (`git diff
  --name-only` lists only provider/openai_compat/wire/primitives and the two
  provider test files). ChatRole gained roleTool and Message gained
  toolCalls/toolCallId (the pi message model), so the tool round-trip rides
  ordinary Message values instead of a parallel wire type. provider.nim kept
  the policy — the Provider/Model objects, the ported loop (runTurn) and the
  hook gates (invokeTool) — and the independent verifier checked it line by
  line against nimgent.nim:675-745: stop/finished/frStepLimit, one
  seFinished per whole turn, the assistant message plus one tool message per
  call appended for the next step, a raising callback or a hook error
  becoming the tool-result text, and no `stream_text` hook in generate mode.
  openai_compat.nim gained the roleTool/tool_calls/tool_call_id wire shape,
  the transport-failure wrapping (a retryable ProviderError) and status/
  retryable on the non-200 path; ScriptedTransport records its requests, so
  the round trip is asserted on the wire. Invariant: `grep -rn nimgent src/
  tests/` finds no import and no dependency — only stale comments in the
  untouched expose.nim, cleaned in task 7.
  RED observed (the writer's own evidence was lost to a harness stall): in a
  scratch worktree at the pre-swap HEAD with the new tests copied in,
  `nim c -r --hints:off --threads:on --mm:orc -o:build/tp_all
  tests/tp_all.nim` fails with "tests/tp_provider.nim(51, 19) Error: type
  mismatch / Expression: openAI("dummy-key", baseUrl =
  "https://example.test/v1", transport = t)" — exit 1: the injection seam
  and roleTool do not exist before the swap. GREEN: "[Summary] 112 tests run
  (5.09s): 112 OK, 0 FAILED, 0 SKIPPED" + busted "13 successes / 0 failures
  / 0 errors / 0 pending", exit 0 — the 109 pre-existing tests pass
  unmodified (`git diff -U0 -- tests/` is pure additions, so the contract is
  pinned by tests that did not move), and the live check ran for real:
  "real streaming (OpenRouter) neopi provider works . (2.58s)". Two doc
  comments that contradicted the code (the close path's awaited closeWait
  and the nil-transport fallback) were corrected with the verification's
  findings.
- The live-path defect the swap surfaced (fixed in the same commit): the
  real transport had never run live — task 4 tested it only with the
  in-memory fake, and tp_real still rode nimgent. The first live run
  SIGSEGV'd inside wire.nim's next(): chronos's response carries no reader
  until getBodyReader() builds the chunked/sized chain, so `resp.reader.read`
  dereferenced nil. Worse, `read(n)` waits for exactly n bytes — a chunk
  boundary is not a buffer, so the SSE deltas would have been held back until
  8KB accumulated. The fix builds the reader in fetch via getBodyReader() and
  reads with readOnce (what has arrived; 0 at the EOF); closeWait(response)
  already closes that reader and releases the connection.

### Known limits (recorded from the task 6 verification — none is a regression)

- Mid-stream failures (`resp.next()` on a dropped connection, an SSE payload
  that is not JSON) escape the Nim boundary as chronos/JSON CatchableErrors,
  not as ProviderError: the fetch and the HTTP status are wrapped, the body
  stream is not. The Lua boundary still contains them (expose.nim's generic
  handler turns them into a Lua error).
- The argument JSON-Schema validation nimgent ran before each callback
  (execOne's toolInputFailure) is not ported. The hooks gate and the tools'
  own argument checks stand, and a bad call reaches the model as a tool
  failure, but the pre-execution schema check is gone — a validator is a
  follow-up of its own.
- The mapping allocates the accumulator up to the wire's tool_calls index
  (openai_compat.nim:79, `while acc.toolCalls.len <= idx`), so a hostile or
  buggy gateway can request a huge allocation. Pre-existing (identical at
  HEAD), found by the verification; worth bounding in the mapping's slice.
- A Provider built as an object literal (instead of through
  openAI/openRouter/scriptedProvider) leaves the private transport nil and
  fails at the first turn; the constructors are the only supported path and
  the type's doc says so.
