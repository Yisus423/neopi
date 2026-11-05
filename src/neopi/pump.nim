## The pump seam: the one hook that lets a blocking wait hand control back to
## whoever owns the frame — the TUI's app today, nobody in print mode.
##
## Three layers need the same question answered between polls ("does the owner
## want this work to stop?") without importing each other: the child-process
## runner and the wire's read loop ask it, and the TUI answers it. The hook
## travels as a plain closure, exactly like the stream sink and the transport
## injection, so the provider layer learns nothing about the TUI.
##
## Nil is a first-class value: no owner, no pump, and every call site works
## unchanged. The hook also owns no policy — it reports the request, while
## killing the child, keeping a partial result or ending the turn belongs to
## the call site.
##
## The effects are deliberately unconstrained (like the tool `execute` closure
## in primitives.nim): an owner that pumps by driving its own event loop does
## what its loop does, and forcing a `raises` contract here would make every
## future owner prove something it cannot, at the wrong layer.

type
  Pump* = proc (): bool {.closure.}
    ## Called between polls by a blocking wait. Returns true when the owner
    ## asks the running work to abort.

proc pumpAbort*(pump: Pump): bool =
  ## Ask the pump (when there is one) whether the running work must abort.
  ## A null pump means "never", so the call sites carry no branch of their own.
  not pump.isNil and pump()
