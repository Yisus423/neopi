## Live streaming check against OpenRouter. Skips itself when no key is set.
import std/[os, syncio]
import neopi/provider
import unittest2

suite "real streaming (OpenRouter)":
  test "streams text deltas from a live model":
    let key = getEnv("OPENROUTER_API_KEY")
    if key.len == 0:
      skip()
      return
    let modelId = getEnv("OPENROUTER_MODEL",
      "meta-llama/llama-3.3-70b-instruct:free")
    let m = openRouter(key).model(modelId)
    var got = ""
    var finished = false
    let r = m.stream("Say 'neopi provider works' and nothing else.",
      proc (e: StreamEvent): bool =
        case e.kind
        of seTextDelta:
          got.add e.text
          stdout.write e.text
          flushFile(stdout)
        of seFinished:
          finished = true
        else:
          discard
        true)
    echo ""
    check finished
    check got.len > 0
    check r.text.len > 0
