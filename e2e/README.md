# Live e2e scenarios

Sixteen multi-turn scenarios, one per major Normandy 2.0 feature. Each is a narrated demo
and a gate: it prints what it does, checks hard invariants, and exits 2 on the first broken
invariant (1 if it crashes outright).

**Every run calls the live Anthropic API**: Haiku 4.5, except scenario 15 (Opus 5.5). Each scenario
declares a live-call cap (`S.start(id, cap: n)`) and halts if it exceeds it; the runner refuses a
selection whose caps sum past 150. `mix e2e --estimate [names]` prints a cap-based estimate without
calling the API (about $1.92, at most $2.24, for the full suite with every scenario at its cap; a real run
uses fewer calls). Each scenario prints `usage: input=N output=N cache_read=N cache_write=N
est_cost=$X.XX`, and the summary adds them up (prices in `test/support/e2e/prices.ex`, list prices as of
2026-10).

## Prerequisites

- `export ANTHROPIC_API_KEY=...` (or `API_KEY`)
- Scenario 12 only: Elixir ≥ 1.17 (the `ex_mcp` test dependency is skipped on older
  versions) and OTP ≥ 27 (the stdio MCP server uses the built-in `:json` module)
- Scenario 11 only: a Postgres the test config reaches, with the test database migrated. Either
  `docker compose -f docker-compose.verify.yml up -d` and `MIX_ENV=test mix ecto.setup`, or an existing
  partition database: `MIX_TEST_PARTITION=_w54probe POSTGRES_PORT=55432 mix e2e distributed`
- Scenario 16 only: a public MCP server the API can reach (it tries DeepWiki, then the remote Fetch
  server, and falls back to a rebuilt paused turn; see the scenario's header)

## Running

```bash
mix e2e                        # all, in order; summary table at the end
mix e2e compaction tool_loop   # a subset, by name or id
MIX_ENV=test mix run e2e/02_compaction.exs   # one scenario, output straight to the terminal
MIX_ENV=test elixir --hidden --name e2e_primary@127.0.0.1 -S mix run e2e/11_distributed.exs
                               # scenario 11 alone: it needs a distributed (hidden) primary
```

A scenario that outruns its timeout (5 min; 10 for scenario 11, 20 for scenario 15, 15 for scenario 16) is killed and reported as
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
| 15 | preserved_thinking | AX-7: thinking replay on Opus 5.5 with `thinking_block_binding: :error`, final call after the iteration cap, run/3 and stream/3 |
| 16 | mcp_pause | MCP-connector `pause_turn`, `Turn.Server` killed while paused, new input; cited text replayed |

Scenario 16 prints `PAUSE_PATH live` when the API paused the turn and the kill happened on the paused
history, `PAUSE_PATH synthetic_mcp` or `synthetic_web_search` when it rebuilt the paused shape instead
(no pause came, or no MCP server answered), and `CITATIONS_REPLAY accepted (N cited block(s))`.
