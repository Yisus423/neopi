## The pump seam: the injected hook every blocking wait calls between polls.
## The contract under test is nil-safety — a null pump means "never abort", so
## the call sites (print mode, headless runs, tests) need no branch of their own.
import std/unittest
import neopi/pump

suite "the pump":

  test "a null pump never asks for an abort":
    var missing: Pump
    check missing.pumpAbort == false

  test "an injected pump is consulted and its verdict travels":
    var calls = 0
    let asked: Pump = proc (): bool =
      inc calls
      calls >= 2

    check asked.pumpAbort == false  # first poll: keep going
    check asked.pumpAbort == true   # second poll: the owner asked to abort
    check calls == 2

  test "the null check does not swallow the pump's own answer":
    let always: Pump = proc (): bool = true
    var missing: Pump

    check always.pumpAbort == true
    check missing.pumpAbort == false
