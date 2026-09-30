# Agent commands: neopi.registerCommand + the composer's / dispatch

## Goal

Extensions register commands the user runs with /name in the composer (pi's
model). This unlocks the deferred session resume later (/resume + the
session choice need in-agent commands first — the user's call). The
mechanism only in this slice; /resume is the next one.

## Verified basis (2026-09-30)

- pi's prompt(): the text starting with "/" → the extension command
  executes IMMEDIATELY ("Extension command executed, no prompt to send");
  "Extension commands manage their own LLM interaction via pi.sendMessage()".
- pi's RegisteredCommand: {name, sourceInfo, description?,
  getArgumentCompletions?, handler: (args, ctx) => Promise<void>} — the ctx
  (ExtensionCommandContextActions: newSession/fork/navigateTree/
  switchSession) is where /resume's machinery lives.
- neopi's extensions reach everything through the globals (neopi.* — the
  nvim model), so no ctx is needed for the MVP.
- The tools' registry pattern (runtime/init.lua): the runtime owns the
  registry; the extensions register via neopi.registerTool; the core reads
  via neopi.registeredTools(). The commands follow the same shape.
- The composer's send path (tui.nim sendTurn): the text → the user entry →
  the loop chunk. The "/" interception goes BEFORE the user entry: a
  command's input never enters the session.

## Design

- **runtime/init.lua** (the runtime owns the registry and the dispatch — the
  nvim model):
  - `neopi.registerCommand(name, description, execute)`: the validation
    (name and description strings, an execute function) + the registry
    append {name, description, execute}. A clear Lua error otherwise.
  - `neopi.registeredCommands()`: the registry, in registration order.
  - `neopi.runCommand(input)`: the dispatcher — parse the /-prefixed input
    (the name and the rest via ^/(%S+) and ^/%S+%s*(.*)$), find the command
    in the registry, call its execute with the arguments string, return its
    output (or nil). Errors: "commands start with /name", "unknown command
    /name".
- **tui.nim** (the composer's interception):
  - sendTurn: the text starts with "/" → the command path (NOT the user
    entry — the command's input never enters the session).
  - The private runCommand: the input travels on the neopi table
    (`neopi._tuiCommandInput` — the _tuiModel pattern, no escaping needed);
    the chunk `return neopi.runCommand(neopi._tuiCommandInput)`; the output
    (a non-empty string) renders as the STATUS line; a LuaError renders as
    the status line too — a command failure is FEEDBACK, not a fatal loop
    error (the TUI survives a typo /unknown).
- **The keys**: Enter runs the command when the composer starts with "/",
  sends otherwise. Esc/Ctrl+C unchanged.
- **Non-goals**: /resume and the session selection (the next slice); the
  argument completions / autocomplete (post-MVP); the command ctx (the
  globals are the MVP's context).

## Tasks

- [x] 1. runtime/init.lua: neopi.registerCommand + registeredCommands +
      runCommand
- [x] 2. tui.nim: the "/" interception in sendTurn + the private runCommand
- [x] 3. The tests: the busted spec (commands_spec.lua: the registry, the
      dispatch, the unknown error) + tp_tui (the "/" interception: the
      command runs, the status renders, no user entry)
- [x] 4. Work-unit commit on main; record evidence here

## Evidence

- The parent implemented the slice inline (the writer lesson: 3 stalls in
  two slices — the writers of this runtime stall systematically; the parent
  writes the slices inline from the task file's contracts).
- nimble test verbatim: "[Summary] 103 tests run (2.27s): 103 OK, 0 FAILED,
  0 SKIPPED" + busted "10 successes" — the commands_spec (the registry, the
  dispatch with the args, the empty args, the invalid registrations, the
  bad inputs, the unknown command) and the tp_tui dispatch tests (a
  /-prefixed input runs the command and renders the status, an unknown
  command renders the error as the status without quitting, the command's
  input never enters the session) pass.
- nimlangserver nimCheckFile: 0 diagnostics on tui.nim; the production
  binary builds clean (3.4M).
- The test pattern: the tp_tui dispatch tests load the runtime entry
  (init.lua) with the tp_register pattern (the package.path + agent =
  require('agent') + require('init')) — the command registry lives on the
  neopi table, so the extensibility-only tests must load init.lua
  explicitly.
- Known limits: no /help (the mechanism has no builtin commands); the
  command's feedback is the status line only (a /-input with a long output
  would clip); no argument completions / autocomplete (post-MVP); the
  commands run synchronously (they cannot steer or queue).
