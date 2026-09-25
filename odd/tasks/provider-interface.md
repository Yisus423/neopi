# Provider interface (anti-corruption layer over nimgent)

## Goal

Minimal, provider-neutral primitives for neopi's core: `generate`, `stream`,
`toolCall` plus their types, implemented over nimgent behind a thin interface
of our own. Swap-friendly: if nimgent stalls (solo dev, no releases), fork it
(MIT) or rewrite the wrapper without touching the core.

## Non-goals

- No agents, conversations, or structured-output helpers in the core (Lua
  layer or separate modules later).
- No OAuth provider flows (Codex /login etc.) — API-key providers only for MVP.
- No harness/UI or extensibility work (that design waits on the nvim/pi scout).

## Design

- `src/neopi/provider.nim`: Provider/Model/Message/Tool/StreamEvent types plus
  `generate`/`stream`/`toolCall` primitives.
- nimgent mapped strictly behind the interface; no nimgent types leak out.
- Errors: raise at the boundary with neopi-owned exceptions (nim-error-handling).
- Primitives only — the neovim-model boundary: the core exposes primitives,
  composition happens above (Lua later).

## Tasks

- [ ] 1. Project skeleton: `neopi.nimble`, `nim.cfg` (`-d:ssl`, `--mm:orc`, threads)
- [ ] 2. Types + `generate` primitive (sync text) mapped to nimgent
- [ ] 3. `stream` primitive: SSE `onEvent` + cancellation
- [ ] 4. `toolCall` primitive: JSON schema in, callback result back
- [ ] 5. Tests: scripted nimgent model + real streaming check (OpenRouter key from env)
- [ ] 6. Work-unit commit(s) on the feature branch; record evidence here

## Evidence

- `4abd12e` — feat: provider primitives with anti-corruption layer over nimgent
  (10 files, 432 insertions: src/neopi/provider.nim, scripted + real tests,
  skeleton, task doc)
- Tests: 10 run, 10 OK, 0 FAILED (scripted suite; the live OpenRouter check
  self-skips without OPENROUTER_API_KEY and awaits a keyed run in the user's
  shell)
- Subagent fallback: gentle-ai-worker failed twice at turn 0 (runtime error),
  so the parent implemented inline under the fallback rule
