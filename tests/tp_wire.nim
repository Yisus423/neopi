## Tests for the wire contract: the transport boundary the provider layer
## streams over, with the FakeTransport as the L1 injection point — the
## tests run keyless, no network (the pi FakeTerminal pattern applied to
## the provider's HTTP boundary).
import chronos
import neopi/wire
import unittest2

suite "the wire contract":
  test "the fake transport returns the canned status and the chunks in order":
    let fake = newFakeTransport()
    fake.canned(200, @["data: {\"id\":1}\n\n", "data: [DONE]\n\n"])
    let resp = waitFor fake.fetch(WireRequest(
      url: "https://openrouter.ai/api/v1/chat/completions",
      httpMethod: "POST",
      headers: @[("authorization", "Bearer dummy-key")],
      body: "{}"))
    check resp.status == 200
    var got: seq[string] = @[]
    while true:
      let chunk = waitFor resp.next()
      if chunk.len == 0:
        break
      got.add chunk
    check got == @["data: {\"id\":1}\n\n", "data: [DONE]\n\n"]

  test "the fake transport records every request for the assertions":
    let fake = newFakeTransport()
    fake.canned(200, @["data: x\n\n"])
    let resp = waitFor fake.fetch(WireRequest(url: "u1", httpMethod: "POST",
      headers: @[("authorization", "Bearer dummy")], body: "b1"))
    discard waitFor resp.next()
    fake.canned(200, @[])
    discard waitFor fake.fetch(WireRequest(url: "u2", httpMethod: "GET"))
    check fake.calls.len == 2
    check fake.calls[0].url == "u1"
    check fake.calls[0].headers[0][1] == "Bearer dummy"
    check fake.calls[0].body == "b1"
    check fake.calls[1].url == "u2"
    check fake.calls[1].httpMethod == "GET"

  test "close marks the response closed (the cancel path)":
    let fake = newFakeTransport()
    fake.canned(200, @["a", "b", "c"])
    let resp = waitFor fake.fetch(WireRequest(url: "u", httpMethod: "GET"))
    discard waitFor resp.next()
    resp.close()
    check FakeWireResponse(resp).closed
    # The next read after the close yields the EOF.
    check (waitFor resp.next()) == ""

  test "an error status flows through (the provider layer decides)":
    let fake = newFakeTransport()
    fake.canned(429, @["{\"error\": \"rate limited\"}"])
    let resp = waitFor fake.fetch(WireRequest(url: "u", httpMethod: "POST"))
    check resp.status == 429
    check (waitFor resp.next()) == "{\"error\": \"rate limited\"}"

  test "multiple canned responses are served in order":
    let fake = newFakeTransport()
    fake.canned(200, @["first"])
    fake.canned(200, @["second"])
    let r1 = waitFor fake.fetch(WireRequest(url: "u", httpMethod: "GET"))
    let r2 = waitFor fake.fetch(WireRequest(url: "u", httpMethod: "GET"))
    check (waitFor r1.next()) == "first"
    check (waitFor r2.next()) == "second"
