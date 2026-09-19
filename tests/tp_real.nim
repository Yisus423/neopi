## Live streaming check against OpenRouter. Skips itself when no key is set.
## Reads OPENROUTER_API_KEY from the environment or from a local .env file.
import std/[os, strutils, syncio]
import neopi/provider
import unittest2

proc loadDotEnv(path = ".env") =
  ## Populate the environment from a local KEY=VALUE file. Existing values
  ## win; the file never overwrites them.
  if not fileExists(path):
    return
  for line in lines(path):
    let trimmed = line.strip
    if trimmed.len > 0 and not trimmed.startsWith('#'):
      let sep = trimmed.find('=')
      if sep > 0:
        let key = trimmed[0 ..< sep].strip
        let value = trimmed[sep + 1 .. ^1].strip(chars = Whitespace + {'"'})
        if key.len > 0 and getEnv(key).len == 0:
          putEnv(key, value)

suite "real streaming (OpenRouter)":
  test "streams text deltas from a live model":
    loadDotEnv()
    let key = getEnv("OPENROUTER_API_KEY")
    if key.len == 0:
      skip()
      return
    let modelId = getEnv("OPENROUTER_MODEL",
      "inclusionai/ling-3.0-flash-vl:free")
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
