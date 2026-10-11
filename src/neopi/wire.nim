## The wire contract: the transport boundary the provider layer streams
## over. The transport is the injection point (the pi `client` option
## pattern): the production implementation rides chronos's HTTP client,
## and the FakeTransport feeds canned chunks in memory — the L1 tests run
## keyless, no network. chronos and the SSE library never leak past this
## file and provider.nim (the layer rule).
import chronos

type
  WireRequest* = object
    ## One HTTP request: the URL, the verb, the headers, the body.
    url*: string
    httpMethod*: string
    headers*: seq[(string, string)]
    body*: string

  WireResponse* = ref object of RootObj
    ## The response head plus a chunk iterator over the body. `next`
    ## returns "" at the EOF; `close` aborts the body (the cancel path).
    status*: int
    headers*: seq[(string, string)]

  Transport* = ref object of RootObj
    ## The injectable transport: one fetch per request. Implementations:
    ## the chronos HTTP client (production) and the FakeTransport (L1).

  FakeWireResponse* = ref object of WireResponse
    ## The in-memory response: the canned chunks served in order.
    chunks: seq[string]
    index: int
    closed*: bool

  FakeTransport* = ref object of Transport
    ## The test transport: records every request for the assertions and
    ## serves the canned responses in order.
    cannedResponses: seq[FakeWireResponse]
    calls*: seq[WireRequest]

proc newFakeTransport*(): FakeTransport =
  ## A fresh FakeTransport with no canned responses and no recorded calls.
  FakeTransport(cannedResponses: @[], calls: @[])

proc canned*(t: FakeTransport, status: int, chunks: seq[string],
    headers: seq[(string, string)] = @[]) =
  ## Queue one canned response: the next fetch serves it.
  t.cannedResponses.add FakeWireResponse(status: status, headers: headers,
    chunks: chunks, index: 0, closed: false)

method next*(r: WireResponse): Future[string] {.base, async.} =
  ## The next body chunk, or "" at the EOF.
  doAssert false, "WireResponse.next is abstract"

method close*(r: WireResponse) {.base.} =
  ## Abort the body: the cancel path.
  doAssert false, "WireResponse.close is abstract"

method next*(r: FakeWireResponse): Future[string] {.async.} =
  ## The next canned chunk, or "" when closed or exhausted.
  if r.closed or r.index >= r.chunks.len:
    return ""
  let chunk = r.chunks[r.index]
  inc r.index
  return chunk

method close*(r: FakeWireResponse) =
  ## Mark the response closed: the reads yield "" from here on.
  r.closed = true

method fetch*(t: Transport, req: WireRequest): Future[WireResponse] {.base,
    async.} =
  ## Perform the request and return the response head with the body
  ## iterator. Failures raise (the transport errors surface as exceptions).
  doAssert false, "Transport.fetch is abstract"

method fetch*(t: FakeTransport, req: WireRequest): Future[WireResponse] {.
    async.} =
  ## Record the request and serve the next canned response.
  t.calls.add req
  doAssert t.cannedResponses.len > 0,
    "the FakeTransport has no canned response for this fetch"
  let canned = t.cannedResponses[0]
  t.cannedResponses.delete(0)
  return canned
