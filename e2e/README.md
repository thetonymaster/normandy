# Live e2e scenarios

Fourteen multi-turn scenarios, one per major Normandy 2.0 feature. Each is a narrated demo
and a gate: it prints what it does, checks hard invariants, and exits 2 on the first broken
invariant (1 if it crashes outright).

**Every run calls the live Anthropic API** (Haiku 4.5). Each scenario declares a live-call cap
(`S.start(id, cap: n)`) and halts if it exceeds it; the runner refuses a selection whose caps
sum past 140. A full run is roughly $0.15–0.50.

## Prerequisites

- `export ANTHROPIC_API_KEY=...` (or `API_KEY`)
- Scenario 12 only: Elixir ≥ 1.17 (the `ex_mcp` test dependency is skipped on older
  versions) and OTP ≥ 27 (the stdio MCP server uses the built-in `:json` module)
- Scenario 11 only: `docker compose -f docker-compose.verify.yml up -d` and
  `MIX_ENV=test mix ecto.setup`

## Running

```bash
mix e2e                        # all, in order; summary table at the end
mix e2e compaction tool_loop   # a subset, by name or id
MIX_ENV=test mix run e2e/02_compaction.exs   # one scenario, output straight to the terminal
MIX_ENV=test elixir --hidden --name e2e_primary@127.0.0.1 -S mix run e2e/11_distributed.exs
                               # scenario 11 alone: it needs a distributed (hidden) primary
```

A scenario that outruns its timeout (5 min; 10 for scenario 11) is killed and reported as
`FAIL` with a `timeout:` note.

Logs and `summary.md` land in `e2e/reports/<UTC timestamp>/` (gitignored).

## Reading a failure

`INVARIANT FAILED: <label> — <detail>` names the broken property. A recall check failing
is a finding to triage (model wording vs. lost memory), not something to retry.

| # | Scenario | Feature |
|---|---|---|
| 01 | long_conversation | memory, structured output, context providers, prompt caching |
| 02 | compaction | WindowManager `:summarize`, compaction telemetry |
| 03 | tool_loop | tools, hooks, batch completeness |
| 04 | durable_server | Turn.Session / Turn.Server kill + resume |
| 05 | approvals | policy approvals, approval expiry `:continue` / `:fail` |
| 06 | resilience | retry, circuit breaker open → half-open → closed |
| 07 | guardrails | input / output guardrails, `admit/2` |
| 08 | streaming | streamed turns, incremental output guardrail |
| 09 | dsl | `agent do` + `workflow do` (step, parallel, race) |
| 10 | coordination | AgentProcess, AgentPool, hierarchical + sequential |
| 11 | distributed | Postgres store, Horde, eager resume on node loss |
| 12 | mcp_a2a | stdio MCP server tools, A2A over HTTP |
| 13 | budget_policy | BudgetTracker denial, Ruleset deny |
| 14 | memory | `Tools.Memory` across sessions, namespace isolation (InMemory store) |
