## The TUI measurement harness: the numbers the interface work is judged
## against (odd/tasks/tui-own.md, task 1).
##
## It renders HEADLESS through nimterm's documented fake-backend pattern (a
## TerminalBackend subclass whose present is a counter instead of a terminal
## write) with the project's own widgets, so it never touches a terminal and
## runs anywhere. What it measures is what the streaming path actually pays
## per frame on a synthetic transcript of N entries:
##
##   idle     one `presentApp` on an unchanged transcript (the frame loop)
##   render   `App.render` — the app loop's own clear + full tree render +
##            present, the path the loop takes when it owns the process
##   delta    one streamed text delta posted as an agent event, the app's
##            dispatch of it, and a `presentApp` (what the stream sink runs)
##   key      one key dispatched through the app plus a `presentApp` (the
##            input path's latency)
##
## plus the in-process time to the first frame and the peak RSS. The sizes
## are swept because the cost's SCALING with the transcript length is the
## whole question this harness exists to answer.
##
## Usage: build/tui_bench [entries] [frames]
##   no arguments   the sweep 50 / 500 / 5000 entries
##   entries frames one size, `frames` samples at most (default 200)
##
## The process's own cold start and peak RSS are also measured from outside
## (`/usr/bin/time -v build/tui_bench`): only the caller sees the exec cost,
## and this harness only sees itself.
##
## Every measurement prints one stable line:
##   bench entries=<N> budget_ms=<b> idle_n=<k> idle_median_ms=... idle_p95_ms=...
##     render_n=<k> render_median_ms=... delta_n=<k> delta_median_ms=...
##     delta_p95_ms=... key_n=<k> key_median_ms=... presents=<count>
##     peak_rss_mb=...
## so two runs of different versions diff line against line. Each metric
## runs until its sample cap OR its 2s budget, whichever comes first: the
## count in the line says how much confidence the median has.
import std/[algorithm, monotimes, os, strutils, times]

import nimterm
import neopi/[session, tui]

# Same file-scope typedef as lua.nim and the bridge modules: no C headers
# exist to declare the opaque state type, and this module's generated C
# materializes TuiState, whose field holds it.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

const
  benchCols = 120
  benchRows = 40
  warmupFrames = 5
  deltaText = " and another streamed token"
  budgetMs = 2_000.0
    ## The per-metric time budget: these costs scale super-linearly with the
    ## transcript, so a fixed sample count would make the sweep unusable. A
    ## metric runs until `frames` samples or this budget, whichever first,
    ## and reports how many samples it took.

type
  BenchBackend = ref object of TerminalBackend
    ## The headless backend: a fixed size, never an event, and a counter
    ## where the terminal write would be.
    frameSize: Size
    presents: int

method size*(backend: BenchBackend): Size =
  backend.frameSize

method readEvent*(backend: BenchBackend, timeoutMs: int): UiEvent =
  discard timeoutMs
  UiEvent(kind: uiNone)

method present*(backend: BenchBackend, frame: Canvas) =
  inc backend.presents

let harnessStart = getMonoTime()
  ## The harness's own clock: the first-frame number is measured from here,
  ## so it covers the session build and the widget assembly but not the
  ## process exec or the module initialization.

proc msSince(t0: MonoTime): float =
  ## Milliseconds elapsed since `t0` (microsecond resolution: the per-frame
  ## times are well under a millisecond on the small transcripts).
  (getMonoTime() - t0).inMicroseconds.float / 1_000.0

proc fmt(value: float): string =
  ## Three decimals, stable across runs.
  formatFloat(value, ffDecimal, 3)

proc median(values: var seq[float]): float =
  ## The middle sample. `values` is sorted in place.
  values.sort()
  values[values.len div 2]

proc p95(values: var seq[float]): float =
  ## The 95th percentile sample. `values` is sorted in place.
  values.sort()
  values[min(values.high, values.len * 95 div 100)]

proc peakRssMb(): float =
  ## The peak resident set in MiB, from VmHWM. Linux-only, like the rest of
  ## the project.
  for line in readFile("/proc/self/status").splitLines():
    if line.startsWith("VmHWM:"):
      return line.splitWhitespace()[1].parseFloat / 1024

proc userText(i: int): string =
  "bench user turn " & $i & ": " & "lorem ipsum dolor sit amet ".repeat(3)

proc assistantText(i: int): string =
  "bench assistant turn " & $i & ": " & "the quick brown fox jumps over ".
    repeat(18)

proc toolText(i: int): string =
  "bench tool result " & $i & ": " & "0123456789 ".repeat(12)

proc synthSession(entries: int, path: string): Session =
  ## A synthetic session of `entries` entries (user, assistant, tool result
  ## repeating), each text long enough to wrap into several rendered lines.
  ## It goes through `append`, so the id/parent/timestamp assignment and the
  ## JSONL write are the real ones.
  if fileExists(path):
    removeFile(path)
  result = newSession(path)
  var i = 0
  while i < entries:
    result.append SessionEntry(kind: ekUser, text: userText(i))
    inc i
    if i >= entries: break
    result.append SessionEntry(kind: ekAssistant, text: assistantText(i),
      model: "bench", provider: "bench", stopReason: "stop")
    inc i
    if i >= entries: break
    result.append SessionEntry(kind: ekToolResult, toolCallId: "call-" & $i,
      toolName: "read", output: toolText(i), isError: false)
    inc i

proc measure(entries, frames: int, path: string, reportFirstFrame: bool) =
  ## Build the synthetic session, render it headless, and print the numbers.
  let built = getMonoTime()
  let sess = synthSession(entries, path)
  var st = initTuiState("bench", "bench-model", sess, getTempDir())
  let screen = buildScreen(addr st)
  let backend = BenchBackend(frameSize: size(benchCols, benchRows))
  st.app = newApp(backend, screen)
  st.appReady = true
  for _ in 0 ..< warmupFrames:
    presentApp(addr st)
  if reportFirstFrame:
    echo "bench first_frame_ms=", fmt(msSince(harnessStart)),
      " session_build_ms=", fmt(msSince(built))

  var idle, render, delta, key: seq[float]
  # `phaseStart` is the budget's clock and `t0` the sample's: sharing one
  # variable makes the budget compare against the sample's own start and
  # never fire (the harness's first run did exactly that and burned 200
  # samples per metric).
  let idleStart = getMonoTime()
  while idle.len < frames and msSince(idleStart) < budgetMs:
    let t0 = getMonoTime()
    presentApp(addr st)
    idle.add msSince(t0)
  let renderStart = getMonoTime()
  while render.len < frames and msSince(renderStart) < budgetMs:
    let t0 = getMonoTime()
    st.app.render()
    render.add msSince(t0)
  # The delta path must mirror the sink (src/neopi/tui.nim's tuiOnEventCB
  # calls the WIDGET's apply) and it must still RENDER: a cheaper delta that
  # drops the text would be a wrong fix, so it is verified once here, outside
  # the timed region, against the presented canvas.
  st.transcriptW.apply(AgentUiEvent(kind: ueTextDelta, text: deltaText))
  presentApp(addr st)
  if not st.transcriptW.transcript.items[^1].text.endsWith(deltaText):
    quit("tui_bench: the delta did not reach the transcript")
  if not st.app.frame.plainText.contains("streamed"):
    quit("tui_bench: the delta did not render")

  # The delta metric must measure the SAME work every sample: `apply` on a
  # text delta appends to the last item, so left alone the transcript (and
  # the cost) grows sample after sample — the first version of this harness
  # measured a growing transcript and produced escalating numbers. Snapshot
  # the tail and restore it after each sample.
  let tailLen = st.transcriptW.transcript.items.len
  let tailText = if tailLen > 0: st.transcriptW.transcript.items[^1].text
    else: ""
  let deltaStart = getMonoTime()
  while delta.len < frames and msSince(deltaStart) < budgetMs:
    let t0 = getMonoTime()
    st.transcriptW.apply(AgentUiEvent(kind: ueTextDelta, text: deltaText))
    presentApp(addr st)
    delta.add msSince(t0)
    st.transcriptW.transcript.items.setLen(tailLen)
    if tailLen > 0:
      st.transcriptW.transcript.items[^1].text = tailText
  let keyStart = getMonoTime()
  while key.len < frames and msSince(keyStart) < budgetMs:
    let t0 = getMonoTime()
    st.app.dispatch(UiEvent(kind: uiKey, key: keyChar, text: "x"))
    presentApp(addr st)
    key.add msSince(t0)

  echo "bench entries=", entries, " budget_ms=", fmt(budgetMs),
    " idle_n=", idle.len,
    " idle_median_ms=", fmt(idle.median),
    " idle_p95_ms=", fmt(idle.p95),
    " render_n=", render.len,
    " render_median_ms=", fmt(render.median),
    " delta_n=", delta.len,
    " delta_median_ms=", fmt(delta.median),
    " delta_p95_ms=", fmt(delta.p95),
    " key_n=", key.len,
    " key_median_ms=", fmt(key.median),
    " presents=", backend.presents,
    " peak_rss_mb=", fmt(peakRssMb())

when isMainModule:
  let args = commandLineParams()
  let path = getTempDir() / "neopi-tui-bench.jsonl"
  if args.len >= 1:
    let entries = args[0].parseInt
    let frames = if args.len >= 2: args[1].parseInt else: 200
    measure(entries, frames, path, reportFirstFrame = true)
  else:
    for i, entries in [50, 500, 5000]:
      let frames = if entries >= 1000: 50 else: 200
      measure(entries, frames, path, reportFirstFrame = i == 0)
  if fileExists(path):
    removeFile(path)
