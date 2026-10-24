## Principles audit: lib/normandy/agents/**/*.ex (18 modules, 9,260 lines, branch feat/claudio-0.7-migration @ 7561497)

Verdict: ship with follow-ups. Nothing blocks 2.0. The biggest issue is the concurrent tool-batch runner, copied four times; the copies have already drifted. The only finding that touches public API is the implicit supervisor contract, and fixing it only adds API, so it is cheapest to do before 2.0.

### Findings (ranked)

1. [Composition · under] lib/normandy/agents/base_agent.ex:833 — the step that runs a batch of tool calls concurrently is copied four times, and the copies have drifted.
   Evidence: these four places all contain the same `Task.async_stream(..., ordered: true, max_concurrency:, timeout: :infinity, on_timeout: :kill_task) |> Enum.map(&unwrap_tool_task_result!/1)` block with `OtelCtx.capture/restore`:
   - `dispatch_turn_tools/2` (base_agent.ex:833)
   - `dispatch_stream_tools/3` (base_agent.ex:1427, whose comment says "Mirror of dispatch_turn_tools")
   - `dispatch/2` (turn/server.ex:2178)
   - `execute_approved/2` (turn/server.ex:2218)

   `execute_one_tool_call/2` (base_agent.ex:1994) and `execute_one_streaming_tool_call/2` (base_agent.ex:2001) have the same body, `Dispatch.dispatch_one(config, tool_call, base_agent_pipeline(config))`.

   Two signs of drift:
   - The B2 fix (commit c0cf263, `tool_task_config/1` at server.ex:2170, "tool tasks run without the conversation's entries") was applied only to the two Server copies. investigations/performance-race-audit.md:261 names the BaseAgent copies as affected too, yet `dispatch_turn_tools` and `dispatch_stream_tools` still pass the full config, memory included, to every task.
   - `max(config.max_tool_concurrency || 1, 1)` appears 4 times (base_agent.ex:835, 1429; server.ex:2180, 2225). But `init/1` already normalizes the value to an integer >= 1 (`normalize_max_tool_concurrency/1`, base_agent.ex:243-249), and the field is typed `pos_integer()` (base_agent_config.ex:69). So the `|| 1` is a silent fallback for a value that cannot occur.

   Fix: one `@moduledoc false` function, e.g. `Dispatch.run_batch(config, items, per_item_fun)`. It would own concurrency, OTel propagation, the slim task config and unwrapping. The four call sites pass only their per-item function. Delete `execute_one_streaming_tool_call/2`.
   Public API: none (all private or `@doc false`).

2. [Composition · under] lib/normandy/agents/turn/session.ex:35 — `:supervisor_mod` is a public, pluggable contract with 2 lib implementations and 6 test implementations, but no behaviour.
   Evidence:
   - `grep -rn "@callback\|@behaviour" lib/normandy/agents/turn/supervisor*` returns nothing.
   - `def start_server(` is defined in turn/supervisor.ex:88, turn/supervisor/horde.ex:74 and 6 test files. `stop_server/2` is in supervisor.ex:111 and horde.ex:99.
   - Four modules consume the contract: Session, Turn.Start (start.ex:21), ResumeReaper and AgentProcess (agent_process.ex:159).
   - The option doc names only `start_server/2` (session.ex:39). `stop_server/2` is found at runtime: `stop_server_fun!/1` (session.ex:413-421) uses `function_exported?` and raises `ArgumentError` inside `delete/1`. A host's custom supervisor module is caught only when it first deletes a session, not at compile time or by dialyzer.

   Fix: add `Normandy.Behaviours.TurnSupervisor` with `@callback start_server/2` and `@callback stop_server/2`. Put `@behaviour` on both supervisors, point the `:supervisor_mod` doc at it, and keep the runtime check for non-conforming modules.
   Public API: additive (one new public module). It needs a `groups_for_modules` entry (test/docs/docs_groups_test.exs) and `@doc` on its callbacks.

3. [Composition · under] lib/normandy/agents/base_agent.ex:726 — `BaseAgent` is both the public facade and the internal handler library that `Turn.Server` builds on.
   Evidence:
   - base_agent.ex is 2,562 lines with 226 `def`/`defp`.
   - 16 public functions are `@doc false` and exist for other modules: lines 119, 140, 243, 262, 601, 610, 619, 631, 652, 713, 726, 1041, 1086, 1121, 1256, 1965.
   - turn/server.ex calls 9 distinct BaseAgent functions, 8 of them internal: `admit_input!`, `base_agent_pipeline`, `begin_turn`, `non_streaming_handlers`, `turn_response_model`, `unwrap_tool_task_result!`, `validate_marking_answer`, `with_default_output_schema`.
   - config_template.ex calls 3 more (`validate_client_options!`, `validate_compaction_config!`, `warn_deprecated_catalog`).

   The result: the durable shell depends on the facade's internals, and every reader of the public module wades through handler glue.

   Fix: move the turn handlers and admission into `Normandy.Agents.BaseAgent.TurnHandlers` (`@moduledoc false`), and the config checks into `BaseAgent.InitOptions` or `ConfigTemplate`. `BaseAgent` keeps `init`, `run`, `stream`, tools, context providers and batch.
   Public API: none (every moved function is `@doc false`). Effort: about 2-3 h, mostly moving code plus updating aliases in Server, ConfigTemplate, Hooks and Telemetry.RunUsage.

4. [False claim] lib/normandy/agents/dispatch.ex:7 — the public moduledoc and the `default_pipeline/0` doc say real implementations arrive "in later phases". They already exist.
   Evidence:
   - dispatch.ex:7-9 says "…injected in tests and replaced by real implementations in later phases. The default pipeline is allow-all / no-op / identity, preserving current behavior."
   - dispatch.ex:136-137 says "Reproduces current behavior… later phases override the behaviour functions."
   - The real pipelines are `Behaviours.Config.to_pipeline/1` (behaviours/config.ex:65) and `BaseAgent.base_agent_pipeline/1` (base_agent.ex:1965), which every production path uses (base_agent.ex:1995, 2002; server.ex:2179, 2224).

   The same stale wording is in the internal comments:
   - inline.ex:10-14: "does NOT (yet) replace `BaseAgent.run/2`… streaming, guardrails, validation, persistence and approval shells come in later phases". Those shells shipped in Driver and Server. Inline has no lib caller (it is used only by 5 test files), and nothing plans for it to replace `run/2`.
   - driver.ex:14 says Inline "serves the test/library path". It is test-only.

   Fix: change the wording to describe what exists now (default = no-op pipeline used when no `behaviours` are set; production = `Config.to_pipeline/1` + span-wrapped execute), and describe Inline as the test shell over the pure core.
   Public API: no (doc text only).

5. [Composition · over] lib/normandy/agents/validation_middleware.ex:252 — two helpers that nothing in lib calls.
   Evidence:
   - `format_validation_errors/2` (validation_middleware.ex:252) has 0 callers in lib/ or test/. The 2 grep hits are a different private function in llm/json/retry_feedback.ex:135.
   - `validation_enabled?/1` (validation_middleware.ex:270) is called only by test/agents/validation_middleware_test.exs:176-186.

   Fix: delete both and the test block. The module is `@moduledoc false`.
   Public API: no.

6. [Flat code · under] lib/normandy/agents/base_agent.ex:1647 — three functions reach nesting depth 4, and each needs credo disables to pass.
   Evidence: `nesting_depth.py --max 3` reports:
   - `stream_attempt` depth 4 (base_agent.ex:1661, two `Refactor.Nesting` disables at 1654 and 1660)
   - `consume_stream_with_incremental_guards` depth 4 (base_agent.ex:1737, plus a `CyclomaticComplexity` disable at 1715)
   - `Turn.Start.start_server` depth 4 (start.ex:32, Nesting disable at 31 and CyclomaticComplexity at 12)

   Each has an extraction that names a real concept:
   - The `else` branch of `stream_attempt` is `consume_stream/1`, the counterpart of `consume_stream_with_incremental_guards/3`.
   - The `reduce_while` body is `guard_chunk_step/4` and the tail block is `tail_check/3`.
   - The `via_race?` arm of `start_server` is `route_or_retry/…`.

   Fix: those extractions, which remove 4 of the 11 inline disables in scope.
   Public API: no. Priority: low. CLAUDE.md sanctions inline disables, so this is about readability, not a rule breach.

### Survived scrutiny
- `Normandy.Agents.Model` protocol — 3 implementations: ClaudioAdapter (llm/claudio_adapter.ex:167), OpenAICompatibleAdapter (llm/openai_compatible_adapter.ex:242) and FakeClient (test/fake_client.ex:482). The claim that a non-streaming client's `stream/3` returns `:unsupported` is verified at openai_compatible_adapter.ex:305-308.
- The pure `Turn` core — grepping turn.ex for `Logger|:telemetry|send(|GenServer|Process.|System.|UUID|File.|Task.` returns 0 hits, so IO lives in the shells.
- Three interpreters (Driver, Inline, Server) — kept under the CLAUDE.md local rule. Driver is used by `BaseAgent.run/3` and `stream/3` (base_agent.ex:680, 1247), Server is the durable shell, and Inline is the test shell over the core (5 test files). The cost is real: each new effect is wired 3 times (11 clauses in Driver and in Inline). Driver's comment that the blocking or terminal effect always comes last in `step/2`'s effect list was checked against every effect list in turn.ex (lines 147-645). If that ever broke, Driver would silently drop the effects after it.
- `Dispatch.Pipeline` struct — 3 producers: `default_pipeline/0`, `Config.to_pipeline/1` and `base_agent_pipeline/1`, plus injected pipelines in 10 test files.
- `Driver.Handlers` injection — 2 lib handler sets (`non_streaming_handlers`, `streaming_handlers`), a wrapper (hooks/handlers.ex) and an injection point in Session, Server and ResumeReaper.
- `Turn.Server.interpret/2` (server.ex:1607) and `Driver.run/4` — flat dispatch over effect tags. The depth and complexity warnings come from the switch, not from conditions the reader must hold.
- `Session.run_on_server/3` (session.ex:250, depth 4, no disable needed by credo) — the extra level is a 2-line retry `if` inside `catch`. Extracting it would name nothing.
- `close_batch/2` (server.ex:1470) — the depth comes from an anonymous function inside a pipeline, not from branching.
- Incremental output guards rescan the whole accumulated text every 200 bytes (base_agent.ex:1727-1747), so the cost grows quadratically. Measured in MIX_ENV=test with `RegexGuard` (2 patterns), scratchpad/principles-audit/guard_bench.exs:
  - 64 KB stream: 3 ms in total for all checks
  - 256 KB stream: 54 / 52 / 50 ms over 3 runs (a single check takes 116 µs)

  That is negligible next to the stream itself. Caveat: a `SemanticScope` classifier guard would be called about 1,280 times on a 256 KB stream. That is the host's choice and was not measured.
- `tool_task_config/1` (server.ex:2170) — a performance change with no numbers in commit c0cf263 or in audit B2 (an estimate only). Kept because it costs 3 readable lines. Its partial application is part of finding 1.
- Global state and DI — the scope has no `Application.get_env`, no named singleton (Horde's `name` defaults to `__MODULE__` but can be overridden) and no hardwired HTTP client. test/agents has no `:meck` or `Application.put_env`. All 15 `async: false` files there give a reason (logger handlers, peer nodes, Postgres sandbox, VM-global unload).
- `Turn.Start` `Process.sleep(10)` × 20 retries — uses the real clock but is bounded at about 200 ms, `retries` can be injected, and the claim "up to ~200 ms" in resume_reaper.ex holds.

### Not checked
- `mix dialyzer` and `mix xref graph --label compile-connected` were not run, so compile-time coupling from `use` and dialyzer callback checks are unverified.
- No tests were run (read-only audit; Postgres, Redis and peer-node tests are excluded by the brief). `mix credo --strict` on the 18 files ran with exit 0 and reported "found no issues"; every complexity lead was found by `nesting_depth.py` (exit 1, 6 hits).
- The repo has no Benchee (`grep -rln Benchee bench test` finds nothing). The only benchmark is the throwaway guard benchmark above, with no base-vs-head comparison because the scope is whole modules, not a diff.
- The cost of copying memory into BaseAgent tool tasks (finding 1) was not measured.
- Reading depth varied:
  - Read at the leads only, not line by line: server.ex (2,242 lines) and base_agent.ex (2,562 lines).
  - Read in full: driver.ex, inline.ex, start.ex.
  - Skimmed for structure: config_template.ex, resume_reaper.ex, init_options.ex, base_agent_config.ex, tool_call_response.ex, model.ex, io_model.ex, supervisor.ex, supervisor/horde.ex, validation_middleware.ex.
