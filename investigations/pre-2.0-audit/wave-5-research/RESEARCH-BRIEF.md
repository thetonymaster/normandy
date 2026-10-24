# Brief for Wave 5 research agents

You build ONE facts inventory for the Wave 5 implementation plan of the Normandy pre-2.0 audit
(/Users/antonio/personal/normandy, branch feat/claudio-0.7-migration, HEAD 0dccd48, Elixir library).
The plan writer works from your inventory, so it must be exact: every claim carries `file:line`
verified today against the current code. The audit reports are weeks old; line numbers and even
behaviour may have changed since (Waves 1-4 rewrote the Model protocol, error model, options,
tool contract and breaker). Re-verify every finding before inventorying it.

## Rules
- Write ONLY your output file under `investigations/pre-2.0-audit/wave-5-research/`. Edit no other file.
  No git commands that change state. You may run `mix compile`, `mix test <file>`, small `mix run -e`
  probes, and read anything.
- Read first: `CLAUDE.md`; `investigations/pre-2.0-audit/plan.md` § "Wave 5" (the spec for your tasks)
  and "Review Focus"; `investigations/pre-2.0-audit/decisions.md` (decisions 6, 7, 11, 12a, 12b, 15, 17, 20);
  the findings named in your dispatch in `agentx.md` / `security.md` / `perf.md`.
- Turn logic has THREE interpreters: `Turn.Driver`, `Turn.Inline`, `Turn.Server` (plus the BaseAgent
  sync path and the streaming path). A change to the tool loop, stop_reason handling or message
  construction must be inventoried for EVERY path that builds or consumes it. List them all.

## Output structure
1. `## 0. Surprises` — anything where the current code differs from the finding or from plan.md's
   Wave 5 text (already fixed, worse than reported, different location, an acceptance that cannot
   be tested as written). Most important section; put it first.
2. Per finding: current behaviour with `file:line` and short code excerpts; every call site / path
   affected (exact grep commands and counts); existing tests that pin current behaviour and will
   need changing (file:line); test helpers that exist (scripted clients, fake stores, telemetry
   capture helpers) with their exact API.
3. `## Proposed approach` — per finding, the smallest change that meets plan.md's acceptance,
   naming exact functions/modules, and the new public names/options/telemetry events.
4. `## Questions for Q` — design decisions the plan cannot settle from decisions.md, each with
   options, your recommendation, and what it costs if wrong.

Reply to your dispatcher with ONLY: the output path, and ≤8 lines of the most important surprises.
