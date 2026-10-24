# 2.0 E2E Demo Suite — Design

Date: 2026-10-02 · Branch: `feat/claudio-0.7-migration` · Status: approved in chat, pending spec review

## Goal

Thirteen live, multi-turn scenarios that exercise every major Normandy 2.0 feature end to end.
Each scenario is both a **release gate** (hard invariants, non-zero exit on break) and a
**demo** (a readable, narrated transcript). They replace the 1.0.0 `verify/` one-shot smokes.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Audience | Both: gate and demo from the same script |
| Backend | Live Anthropic API every run (Haiku 4.5); features forced deterministically (pinned windows, injected faults, short timeouts) rather than waiting for them to occur |
| Scope | All 13 scenarios below, including distributed (11) and MCP + A2A (12) |
| Structure | Script per scenario + `mix e2e` runner, one OS process per scenario |
| `verify/` | Absorbed into `e2e/` and deleted |
| MCP | Real stdio MCP server via a test-only MCP client dep |
| Compaction observability | Add a `[:normandy, :agent, :compaction]` telemetry event to the library |

## Non-goals

- No stub/mock mode. A run costs money; caps bound it.
- No CI integration in this spec (live key + docker). Runs are manual, pre-merge/pre-release.
- No new library features beyond the compaction telemetry event.

## Layout

```
e2e/
  support.exs              # E2E.Support
  fault_client.ex          # E2E.FaultClient (loaded via Code.require_file)
  mcp_server.exs           # tiny stdio MCP server used by scenario 12
  01_long_conversation.exs
  02_compaction.exs
  03_tool_loop.exs
  04_durable_server.exs
  05_approvals.exs
  06_resilience.exs
  07_guardrails.exs
  08_streaming.exs
  09_dsl.exs
  10_coordination.exs
  11_distributed.exs
  12_mcp_a2a.exs
  13_budget_policy.exs
  reports/                 # gitignored; one dir per run
lib/mix/tasks/e2e.ex       # Mix.Tasks.E2e
```

Scripts run under `MIX_ENV=test` so `test/support` (e.g. `Normandy.ClusterCase` peer helpers)
and test-only deps (plug_cowboy, the MCP client) are available.

## Harness

### `E2E.Support` (`e2e/support.exs`)

Grown from `verify/support.exs`. State lives in an `Agent` started per script (no globals
shared across scenarios — each is its own OS process).

- `start(name, cap: n)` — starts the call counter and telemetry probes; prints the scenario header.
- `client(extra_options \\ %{})` — `%ClaudioAdapter{}` from `ANTHROPIC_API_KEY`/`API_KEY`;
  raises naming both variables if neither is set.
- `model/0` — `"claude-haiku-4-5-20251001"`.
- `narrate(text)`, `turn(n, user, reply)` — transcript output.
- `assert!(label, cond, msg)` — prints `ok: label` or `INVARIANT FAILED: label — msg` and halts 2.
- `recalls?(text, fact)` — case-insensitive substring check.
- Probes: attaches handlers to `[:normandy, :agent, :llm_call, :stop]` (counts calls,
  records `usage`), `[:claudio, :messages, :create, :stop]` (cache tokens),
  `[:normandy, :agent, :compaction]`, `[:normandy, :turn, :approval, :expired]`,
  `[:normandy, :agent, :guardrail, :violation]`. Accessors: `calls/0`, `usages/0`, `events(name)`.
- Call cap: every observed LLM call increments the counter; exceeding the scenario cap prints
  `INVARIANT FAILED: live-call cap` and halts 2.
- `finish/0` — prints `LIVE CALLS USED: n` and a machine-readable last line
  `E2E_RESULT {"scenario":..,"calls":..,"ms":..}` for the runner.

Counting is by telemetry, not by manual `record_call!`, so a scenario cannot forget to count.
Scenario 06's FaultClient faults never reach the API and are counted separately as
`faults_injected`.

### `E2E.FaultClient` (`e2e/fault_client.ex`)

`defstruct [:inner, :agent]` where `inner` is a `%ClaudioAdapter{}` and `agent` holds a script
of `%{call_index => fault}`. `defimpl Normandy.Agents.Model` delegates `converse/7` and
`completitions/6` to `inner` unless the current call index is scripted, in which case it
returns `{:error, %Normandy.LLMError{type: :overloaded, status: 529, retryable?: true}}`
(exact fields matched to `lib/normandy/llm/error.ex` at implementation time).
Known constraint: a non-ClaudioAdapter client needs a pinned compactor window — scenario 06
uses the default `NoOp` compactor, so this does not apply.

### `mix e2e` (`lib/mix/tasks/e2e.ex`)

- `mix e2e` runs all scenarios in numeric order; `mix e2e compaction tool_loop` runs a subset
  (match on the name part of the filename).
- Each scenario runs as `MIX_ENV=test mix run e2e/NN_name.exs` in its own OS process
  (`System.cmd` with output streamed to the terminal and tee'd to
  `e2e/reports/<UTC timestamp>/NN_name.log`). Scenario 11 additionally passes
  `elixir --sname` so `:peer` can start distributed nodes.
- Suite cap: 110 live calls total, summed from each scenario's `E2E_RESULT`. Exceeded → stop
  launching further scenarios, mark the run failed.
- Preflight: fail fast with a named message if no API key; for 11 and 12, check Postgres at
  the `config/test.exs` address and fail those scenarios (not skip) with
  `"Postgres unreachable at host:port — run docker compose -f docker-compose.verify.yml up -d"`.
- Summary table: scenario · PASS/FAIL · exit code · live calls · wall time; written to stdout
  and `e2e/reports/<ts>/summary.md`. Mix task exits non-zero if any scenario failed.
- `mix e2e` is not part of `mix precommit`.

## Library change: compaction telemetry

In `BaseAgent`, where compaction meta is produced (`lib/normandy/agents/base_agent.ex` ~746),
emit `:telemetry.execute([:normandy, :agent, :compaction], %{tokens_before:, tokens_after:,
tokens_removed:}, %{agent_name:, model:, strategy:, compacted:})`. Emitted on every compactor
run that returns meta, including `compacted: false`, so a non-firing compactor is observable.
Covered by a unit test in `test/agents/base_agent_compaction_config_test.exs`, documented in the
`BaseAgent` moduledoc telemetry list and CHANGELOG. Separate commit.

## Scenarios

All use Haiku 4.5, `max_tokens` ≤ 512, short prompts. "Recall" = seeded fact appears
(case-insensitive) in the reply, or in a structured field where one exists.

| # | Turns / time | Forcing | Invariants | Cap |
|---|---|---|---|---|
| 01 Long conversation | 8 turns, structured `io_schema` output, `enable_caching: true`, DateTimeProvider | seed 3 facts in turns 1–3 | every output casts to schema; turn 8 recalls all 3 facts; `cache_read_input_tokens > 0` on some call from turn 2 on; memory holds 16 messages | 10 |
| 02 Compaction | 10 turns | WindowManager `:summarize`, `max_tokens: 2_000` pinned | ≥1 `:compaction` event with `compacted: true` and `tokens_after < tokens_before`; turn-1 fact recalled at turn 10 | 14 |
| 03 Tool loop | 3 turns, 2–3 tool calls each (calculator + kv-store) | a tool hook rewrites one result | every batch answers every `tool_call_id`; final answers reflect tool output (incl. rewritten one); kv value written turn 1 read back turn 3 | 12 |
| 04 Durable server | 5 turns via `Turn.Session` (in-memory store + registry) | `Process.exit(pid, :kill)` after turn 2 | new pid after kill; memory reconstructed from store; turns 3–5 recall turn 1; no duplicated messages | 6 |
| 05 Approvals | 2 turns + second server | Ruleset `:require_approval` on `delete_record`; `approval_timeout_ms: 1_000` | turn 1: `:awaiting_approval` → `approve/2` → tool runs; turn 2: no decision → `[:turn, :approval, :expired]` + result `expired: true` (`:continue`); `:fail` server returns `{:error, {:approval_timeout, ids}}` | 5 |
| 06 Resilience | ~20 s wall | FaultClient: calls 1–3 → 529; breaker `failure_threshold: 3, timeout: 5_000` | retries observed; breaker opens; next run raises `LLMError type: :circuit_open` with zero new live calls; after 5 s a real call succeeds and breaker is closed | 3 |
| 07 Guardrails | 4 turns | input `ForbiddenSubstrings`; output `MaxLength` + `RegexGuard`; `admit/2` | turn-2 bad input rejected with no LLM call (counter unchanged); turns 3–4 continue normally; violation telemetry fired | 4 |
| 08 Streaming | 3 streamed turns | `run(…, stream: true, on_chunk:)` + incremental output guardrail | deltas concatenate to final text; memory entry equals final text; turn 3 recalls turn 1 | 4 |
| 09 DSL | `agent do` ×2 + `workflow do` (step → parallel → race), run twice | — | both `execute/1` calls return `{:ok, _}`; both parallel branches present; race yields exactly one | 10 |
| 10 Coordination | 3 rounds | HierarchicalCoordinator over AgentPool of 2 AgentProcesses; SequentialOrchestrator pipeline | each round's subtask results reach coordinator; pool worker pids stable across rounds; AgentProcess memory grows per round | 12 |
| 11 Distributed | 4 turns, 2 `:peer` nodes, Postgres store, Horde registry, `resume_policy: :eager` | stop owning peer after turn 2 | ResumeReaper restarts session on survivor; turns 3–4 recall turn 1; exactly one live pid cluster-wide | 6 |
| 12 MCP + A2A | 3 turns | real stdio MCP server exposing `lookup_city`; agent B behind `A2A.Server` mounted in Plug/cowboy on a random port | MCP tools discovered with prefix and called; A→B over HTTP ≥2 times; B's answers reflected in A's reply | 8 |
| 13 Budget/policy | 3 turns | BudgetTracker allowing 2 tool calls; Ruleset denying `drop_table` | 3rd tool call gets `denied: true` result and model's reply acknowledges it; `drop_table` denied; turn 3 still completes | 6 |

Cap total: 100 (suite cap 110 leaves headroom for retries inside caps).
Estimated cost per full run: ~$0.15–0.40.

### Migration of `verify/`

- `verify/guardrails_live.exs` invariants → folded into 07.
- `verify/durable_server_live.exs` → superseded by 04.
- `verify/json_smoke_live.exs` invariants → folded into 01 (structured output) where they
  test the JSON path; any not covered get their own step in 01.
- `docs/release/1.0.0-e2e-runbook.md` stays as history; a short `e2e/README.md` replaces it as
  the how-to-run doc.

## Error handling

- Any unexpected exception in a scenario propagates: the script crashes, exits non-zero, the
  runner records FAIL with the log path. No rescue-and-continue inside scenarios except where
  the raise *is* the invariant (06 `:circuit_open`, 05 `:fail`).
- Model nondeterminism: recall invariants use seeded, distinctive tokens (e.g. "the code word
  is PERIWINKLE-42") and prompts that ask for them directly. A flaky recall is a real finding,
  logged, not retried.
- Timing-dependent steps (05 timeout, 06 half-open) wait with explicit deadlines
  (`assert_receive`-style loops on telemetry messages), never bare `Process.sleep` guessing.

## Verification of the harness itself

- `mix compile --warnings-as-errors` and `mix credo --strict` cover `lib/mix/tasks/e2e.ex`.
- A unit test for `Mix.Tasks.E2e` result parsing / cap summing / name matching (pure functions,
  no subprocess).
- Each scenario is developed one at a time and run live until green before the next starts.

## Open items for implementation

- Choose between `hermes_mcp` and `ex_mcp` for the test-only MCP dep by checking which one
  Claudio's adapter supports with the least setup and which compiles cleanly on this OTP.
- Exact `LLMError` field names for FaultClient — read from `lib/normandy/llm/error.ex`.
