# Brief for Wave 6 research agents

You build ONE facts inventory for the Wave 6 implementation plan (performance and observability) of the
Normandy pre-2.0 audit (/Users/antonio/personal/normandy, branch feat/claudio-0.7-migration, HEAD d624fbf,
Elixir library). The plan writer works from your inventory, so it must be exact: every claim carries
`file:line` verified today against the current code. The audit reports are weeks old; Waves 1-5 rewrote the
Model protocol, error model, options, tool contract, breaker, tool loop, replay, compaction and memory store
limits. Re-verify every finding before inventorying it. A finding that is already fixed goes in Surprises.

## Rules
- Write ONLY your output file under `investigations/pre-2.0-audit/wave-6-research/`. Edit no other file.
  No git commands that change state. No `git stash`, no worktree removal you did not create, never drop a
  database, never start/stop Docker containers. You may run `mix compile`, `mix test <file>` (untagged), small
  `mix run -e` probes, and read anything. A scratch worktree, if you need one, goes under
  `/private/tmp/claude-501/-Users-antonio-personal-normandy/946e6225-f540-4a79-b3a0-2b246dd3a673/scratchpad/<your-group>`
  and you remove it (`git worktree remove --force <path>`) before replying.
- Never dispatch subagents.
- Read first: `CLAUDE.md`; `investigations/pre-2.0-audit/plan.md` § "Wave 6" (the spec for your tasks,
  including each task's Acceptance) and "Review Focus"; `investigations/pre-2.0-audit/decisions.md`
  (all decisions, especially 6 (error/logging model), 8a/8b, 21, 22, 23 and the Wave 4/5 progress bullets,
  which list items deferred to Wave 6); the findings named in your dispatch in `perf.md`, `telemetry.md`,
  `agentx.md`, `security.md`, and `investigations/performance-race-audit.md` (the July audit).
- Turn logic has THREE interpreters: `Turn.Driver`, `Turn.Inline`, `Turn.Server` (plus the BaseAgent sync
  `run/3` path and `stream/3`). A change to message encoding, the loop, telemetry spans or store IO must be
  inventoried for EVERY path that builds or consumes it. List them all.
- Telemetry: `test/telemetry/catalogue_test.exs` fails when an emitted event is missing from the
  `Normandy.Telemetry` moduledoc. Note every event your proposals add or change.

## Output structure
1. `## 0. Surprises` — where the current code differs from the finding or from plan.md's Wave 6 text
   (already fixed, worse than reported, moved, an acceptance that cannot be tested as written). First.
2. Per finding: current behaviour with `file:line` and short code excerpts; every call site / path affected
   (exact grep commands and counts); existing tests that pin current behaviour and will need changing
   (file:line); test helpers that exist (scripted clients, fake/slow stores, telemetry capture helpers) with
   their exact API. For performance items, a measured baseline from a probe where feasible (state how measured).
3. `## Proposed approach` — per finding, the smallest change that meets plan.md's acceptance, naming exact
   functions/modules and any new public names/options/telemetry events, and how the acceptance is tested
   without sleeps for ordering and without flaky timing (for timing acceptances, say how to make them robust).
4. `## Proposed task split` — sub-tasks (≤ ~400 diff lines each) in dependency order, with the files each touches.
5. `## Questions for Q` — design decisions the plan cannot settle from decisions.md, each with options, your
   recommendation, and what it costs if wrong. Breaking changes (public API, defaults, persisted formats) are
   always a question.

Reply to your dispatcher with ONLY: the output path, and ≤8 lines of the most important surprises.
