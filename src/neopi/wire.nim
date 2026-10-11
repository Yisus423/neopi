## The wire contract: the transport boundary the provider layer streams
## over. The transport is the injection point (the pi `client` option
## pattern): the production implementation rides chronos's HTTP client,
## and the FakeTransport feeds canned chunks in memory — the L1 tests run
## keyless, no network. chronos and the SSE library never leak past this
## file and provider.nim (the layer rule).
import chronos
import chronos/apps/http/httpclient

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
    cannedResponses: seq[WireResponse]
    calls*: seq[WireRequest]

  ChronosTransport* = ref object of Transport
    ## The production transport: chronos's HTTP client (the streaming body
    ## reader, TLS via bearssl — no OpenSSL). One session, pooled
    ## connections.
    session: HttpSessionRef

  ChronosWireResponse* = ref object of WireResponse
    ## The production response: the body reader is chronos's (the chunked
    ## transfer decoded underneath); close hands the connection back.
    resp: HttpClientResponseRef
    request: HttpClientRequestRef

proc newChronosTransport*(): ChronosTransport =
  ## A fresh production transport with its own connection pool.
  ChronosTransport(session: HttpSessionRef.new())

proc newFakeWireResponse*(status: int, chunks: seq[string],
    headers: seq[(string, string)] = @[]): FakeWireResponse =
  ## An in-memory response serving the chunks in order (the fake's
  ## constructor: the fields stay private to the module).
  FakeWireResponse(status: status, headers: headers, chunks: chunks,
    index: 0, closed: false)

proc newFakeTransport*(): FakeTransport =
  ## A fresh FakeTransport with no canned responses and no recorded calls.
  FakeTransport(cannedResponses: @[], calls: @[])

proc canned*(t: FakeTransport, status: int, chunks: seq[string],
    headers: seq[(string, string)] = @[]) =
  ## Queue one canned response: the next fetch serves it.
  t.cannedResponses.add newFakeWireResponse(status, chunks, headers)

proc cannedResponse*(t: FakeTransport, resp: WireResponse) =
  ## Queue a pre-built response (a custom fake, e.g. a slow one).
  t.cannedResponses.add resp

method next*(r: WireResponse): Future[string] {.base, async.} =
  ## The next body chunk, or "" at the EOF.
  doAssert false, "WireResponse.next is abstract"

method close*(r: WireResponse) {.base, gcsafe, raises: [].} =
  ## Abort the body: the default does nothing (the in-memory responses
  ## have nothing to abort; the transports override with the real cleanup).

method next*(r: FakeWireResponse): Future[string] {.async.} =
  ## The next canned chunk, or "" when closed or exhausted.
  if r.closed or r.index >= r.chunks.len:
    return ""
  let chunk = r.chunks[r.index]
  inc r.index
  return chunk

method close*(r: FakeWireResponse) {.gcsafe, raises: [].} =
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

method fetch*(t: ChronosTransport, req: WireRequest): Future[WireResponse] {.
    async.} =
  ## The production fetch: chronos's HTTP client. The response body arrives
  ## through the body reader (the chunked transfer decoded underneath).
  let request =
    if req.httpMethod == "GET":
      HttpClientRequestRef.get(t.session, req.url,
        headers = req.headers).get()
    else:
      HttpClientRequestRef.post(t.session, req.url,
        headers = req.headers,
        body = req.body.toOpenArrayByte(0, req.body.high)).get()
  let resp = await send(request)
  return ChronosWireResponse(status: resp.status, resp: resp,
    request: request)

method next*(r: ChronosWireResponse): Future[string] {.async.} =
  ## The next decoded body chunk, or "" at the EOF.
  let bytes = await r.resp.reader.read(8192)
  if bytes.len == 0:
    return ""
  var chunk = newString(bytes.len)
  if bytes.len > 0:
    copyMem(chunk[0].addr, bytes[0].unsafeAddr, bytes.len)
  return chunk

method close*(r: ChronosWireResponse) {.gcsafe, raises: [].} =
  ## Hand the connection back without blocking: the stream loop's cleanup
  ## awaits closeWait on the normal path, this covers the cancel path.
  asyncSpawn allFutures(closeWait(r.resp), closeWait(r.request))
