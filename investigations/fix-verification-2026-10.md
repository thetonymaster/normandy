# Fix verification, 2026-10-02

A check of the fixes for the 2026-09 audit (`investigations/codebase-audit-2026-09/`,
taken at `1e3182b`) at `ef51378` on `feat/claudio-0.7-migration`.

Five read-only reviewers took one area each (AGENTS, LLM, OTP, SCHEMA, TESTS). For
every finding they read the fix commit and the current code, named the test that fails
if the fix is reverted, and looked for defects the fix introduced. They ran the area's
plain test files (about 1,800 tests, all passing) and probe scripts for suspected bugs.
The store suites were not run.

How far to trust each item:

- **verified**: confirmed by the controller reading the code, or by a probe script.
- **read**: found by reading the code; no probe ran.
- **suspected**: plausible, not confirmed.

## Summary

| Area | Fixed | Partial | Not fixed / regressed |
|---|---|---|---|
| AGENTS (16) | 15 | 1 (AGENTS-7) | 0 |
| LLM (15 + theme 1) | 12 | 3 (LLM-1, LLM-10, LLM-12) | 0 |
| OTP (15) + race A1 | 14 | 1 (OTP-1) + A1 | 0 |
| SCHEMA (15 + extras) | 17 | 3 (SCHEMA-10, SCHEMA-13, `__meta__`) | 0 |
| TESTS (15) | 14 | 0 | TESTS-14 (the audit asked for no fix) |

No finding regressed. Three fixes introduced high-severity bugs (FV-1 to FV-3).

## High

**FV-1. A failed stream logs the agent config, API key included.** verified.
`base_agent.ex:971` throws `{:stream_turn_error, error, config}` from inside
`with_llm_call_span`. The span's catch logs `format_exception_reason/1`, which falls back
to `inspect/1`, and the term also lands in the `[:normandy, :agent, :llm_call, :exception]`
telemetry metadata. The caller ignores the config (`_config_at_failure`, line 901).
Introduced by `ea68a54`.

**FV-2. `timeout: :infinity` on an exhausted pool kills the pool.** verified.
`agent_pool.ex:287` calls `Process.send_after(self(), msg, :infinity)`, which raises
`badarg`, so the pool and its agents die. Introduced by `1070a3f` (OTP-3); `:infinity`
worked before.

**FV-3. One crashing session during a store outage takes down every session.** verified.
`Turn.Server.init/1` returns `{:stop, reason}` when a store load fails (`server.ex:141`,
from `a273cbe`). The DynamicSupervisor restarts a crashed child at once, so it uses up the
supervisor's restart intensity (100 restarts in 5 s) in about a millisecond. Turn.Supervisor
then exits with every unrelated session. The probe saw `{:shutdown, 1}` with session b
killed too. This is the same mechanism as the theory for the Horde restart-limit flake.

## Medium

**FV-4. Busy agents drop out of `AgentSupervisor` listings.** verified.
`agent_supervisor.ex:143-147` (`5e60aad`) catches every exit from `AgentProcess.get_id/1`,
5 s call timeouts included. The default engine runs the LLM call inside `handle_call`, so an
agent busy for over 5 s is missing from `list_agents` and `find_agent` returns
`{:error, :not_found}`. Each busy agent also adds 5 s to the listing.

**FV-5. Redacted fields and `__meta__` reach the model from nested structs.** verified.
`schema.ex:384-385` drops them from the top-level struct only. In the probe,
`to_json(%Person{addr: %Addr{pin: "SECRET"}})` emitted `"pin":"SECRET"`. SCHEMA-10 and
`6ad6ef3` are therefore partial.

**FV-6. A summarized history can start with an orphan tool result.** verified.
`Summarizer` keeps a fixed number of recent messages (`summarizer.ex:273`), and the kept tail
can begin with a `tool` message whose tool call was summarized away. The API rejects that
with a 400 on every later call. WindowManager's `:summarize` strategy goes through the same
code, so LLM-10 is partial.

**FV-7. `prefix_key` ignores the model.** read.
`ToolCallResponse.prefix_key/2` hashes the system prompt and tools. The API also binds
thinking to the model (`model_binding_mismatch`, Claudio `response.ex:28-31`). After a model
change, stale thinking is replayed, and accounts created on or after 2026-08-31 reject it
with a 400.

**FV-8. A `RegexGuard` in a Tier-2 template breaks after loading in another VM.** verified.
A compiled `%Regex{}` carries a VM-specific reference. After a `term_to_binary` round trip
into another VM, `Regex.match?` raises `ArgumentError`. An input guard with the default
`on_error: :reraise` then crashes Turn.Server on every turn (`admit/2` does not rescue
`ArgumentError`). `ConfigTemplate.unstorable?/1` does not catch it.

**FV-9. A stale second checkin releases the next holder's loan.** verified.
`AgentPool.checkin/2` knows only the agent pid (`agent_pool.ex:310-320, 390-399`). A second
checkin after the agent was lent again releases the new loan, so two callers hold one agent.

**FV-10. MCP and A2A discovery raise on remote names.** verified.
`mcp/registry.ex:65-72` and `a2a/registry.ex:88-95` call `Registry.register/3`, which now
raises on names outside `^[a-zA-Z0-9_-]{1,64}$` (`72b8490`). A remote tool called
`files.read`, or an A2A name over 64 characters, raises instead of returning `{:error, _}`.

**FV-11. The Postgres store still raises on a database failure** (OTP-1 partial). read.
`load_turn_state` and `load_config_template` (`postgres.ex:125, 171`) raise, against the
`{:error, reason}` contract in `session_store.ex:22-26`. `ResumeReaper.non_terminal?`
(`resume_reaper.ex:110`) has no rescue, so an outage crashes the reaper.

**FV-12. `ConverseResult.normalize/1` accepts any term** (AGENTS-7 and theme 1 partial).
verified. The catch-all at `converse_result.ex:34` treats `nil`, `{:ok, struct}` or a map
as the response. `nil` ends in a `BadMapError` in `call_turn_llm` (`base_agent.ex:640`).

**FV-13. Any `invalid_request_error` triggers a second full request** (LLM-1 part f).
verified. `__structured_error_action__` (`claudio_adapter.ex:1488`) retries without
structured outputs on any 400, including "prompt is too long". The error-contract spec left
this out of scope and nothing picked it up.

**FV-14. `:on_parse_failure` is not validated at init** (LLM-12 partial). verified.
`validate_options!/1` accepts `on_parse_failure: :raise`. The value raises `ArgumentError`
after three paid requests, and with `retry_options` set the raise is retried.

**FV-15. The default parse fallback adds `:chat_message` to any schema.** verified.
`claudio_adapter.ex:1009` and `openai_compatible_adapter.ex:202` put `:chat_message` on the
response model even when the schema has no such field. Required fields stay `nil`, and the
result is presented as success.

**FV-16. `compute:` raises out of `SchemaBinder.bind`.** verified.
Since `c1fc7d0`, compute functions run in every `apply_action` (`validate.ex:336-341`),
including when model output is parsed (`schema_binder.ex:27`). A compute that reads a `nil`
optional field raises `ArithmeticError` instead of giving a validation error. A tool-use
`"arguments"` envelope raises even with valid inner data, because the outer pass computes
on defaults.

**FV-17. `token_counter.ex:177-186` sends role `"tool"` to count_tokens.** read,
pre-existing. The endpoint accepts only `user` and `assistant`, so any agent that has used a
tool cannot be counted.

**FV-18. String formats are dropped from structured-output schemas.** verified.
`schema_translator.ex:50-57` removes `format`. Since `b02914e`, `:date`, `:time` and
`:duration` fields count as compatible with structured outputs, so the model gets a bare
`"string"`. A non-ISO date then fails the cast with no retry (`claudio_adapter.ex:1528`).
`validator.ex:428-438` does not check these formats either.

## Low

- **FV-19.** The streamed response returned to callers carries the internal `:prefix_key`
  (`base_agent.ex:957`). Only `:tool_calls` is stripped. verified.
- **FV-20.** `stream_response/3` and `stream_with_tools/3` document a `:thinking_delta`
  callback event that is never sent (`base_agent.ex:1044, 1093`; no clause in
  `invoke_stream_callback`). verified.
- **FV-21.** Error messages inspect single `client.options` values (`claudio_adapter.ex:1061,
  1323, 1371-1422`), against the project rule. None is a secret. read.
- **FV-22.** `:timeout` and `:recv_timeout` are checked only when the first call builds the
  client (`claudio_adapter.ex:1307`), not at init. read.
- **FV-23.** The OpenAI adapter ignores `on_parse_failure: :error` and falls back silently.
  read.
- **FV-24.** A replayed assistant message puts all thinking blocks first and merges the text
  blocks (`tool_call_response.ex:84`). If a signature covers earlier blocks of the same
  message, interleaved thinking breaks. suspected.
- **FV-25.** Sequential `:continue` returns `success: true, errors: []` after an agent
  failed (OTP-6 residual). read.
- **FV-26.** Every unnamed agent shares one budget scope (`config.ex:86`, OTP-8 residual).
  read.
- **FV-27.** Chunked Batch `on_progress` counts restart at each chunk (OTP-4 residual). read.
- **FV-28.** `mix.exs:150-155` has two near-duplicate comment paragraphs (OTP-9). read.
- **FV-29.** When an overflow agent dies, the freed slot is not given to queued waiters,
  which then time out (`agent_pool.ex:516-518`). verified.
- **FV-30.** A raising `:transform` or `:on_agent_complete` kills the caller of
  `ParallelOrchestrator.execute/2` (`parallel_orchestrator.ex:142-156, 273-276`).
  Sequential `execute_agent` (`sequential_orchestrator.ex:233-247`) and the Hierarchical
  manager rescue raises only, so an exit takes down their caller. verified.
- **FV-31.** A policy check that exits produces the denial rationale `inspect(value)`
  (`dispatch.ex:296`, same shape at `a2a/server.ex:150`). A GenServer-backed policy engine's
  exit can carry the ctx with config and client, which the model then sees. suspected.
- **FV-32.** The circuit breaker rescues raises only (`circuit_breaker.ex:319-341`), so an
  exit or throw leaves it stuck half-open (race audit A2). read.
- **FV-33.** `Redis` session registry `whereis` maps a transport error to `:none`
  (`session_registry/redis.ex:120-121`), so a Redis hiccup can start a second server for a
  live session. read.
- **FV-34.** Suspected, unconfirmed: Redis store `new/1` accepts `wait: {n, 0}` (Redis
  treats 0 as block forever on a shared connection); A2A does not catch a throw; a worker
  named `"w1#1"` can collide with a generated id.
- **FV-35.** SCHEMA-13 docs: the EnhancedCalculator moduledoc shows `{:ok, 28}` where the
  code returns `{:ok, 28.0}`; the `validator.ex:15` example uses `minLength: 1`, which no
  longer compiles; the SchemaBaseTool doc names a `:number` field type that does not exist.
  verified.
- **FV-36.** SCHEMA-8 residual: a plain map (not a struct) with a misspelled `:field` passes
  everything, and with `on_error: :open` the new `ArgumentError` is rescued into a pass.
  read.
- **FV-37.** `json_type/1` (`schema.ex:553-575`) has no clause for `{:try, _}` or
  `{:in, _}`, which `check_field_type!` accepts, so `field(:x, {:try, :string})` fails
  compilation with a `FunctionClauseError`. verified.
- **FV-38.** Poison is still hardcoded instead of the configured adapter at
  `base_agent.ex:513, 1188`, `dispatch.ex:366`, `summarizer.ex:163`,
  `window_manager.ex:178, 203`, `token_counter.ex:194, 256`. read.
- **FV-39.** `Type.load(SchemaModule, _)` raises `UndefinedFunctionError` (`type.ex:565`);
  `cast` and `dump` have schema clauses. Unused in lib. read.
- **FV-40.** `compute:` on a non-virtual field is accepted and never applied
  (`schema.ex:962-965`). verified.
- **FV-41.** AGENTS-14 leftover: `server.ex:216` raises a `MatchError` when the template
  provider's fetch fails, instead of `{:stop, reason}`. read.
- **FV-42.** AGENTS-6 leftover: bare `function_exported?/3` calls on registry modules at
  `server.ex:850`, `supervisor.ex:61`, `horde.ex:57`. read.
- **FV-43.** Turn.Server's tool-result reorder uses `Map.fetch!` on `tool_call_id`
  (`server.ex:916-917`). A before-hook result without the call's id raises `KeyError`, and
  the batch fails as a tool error. read.
- **FV-44.** Test hygiene:
  - `circuit_breaker_test.exs:222` orders events with `sleep(10)`.
  - `supervisor_horde_test.exs:84-103` removes the translator filter before registering
    `on_exit`.
  - `claudio_adapter_test.exs:180-207` attaches a global `:fallback` telemetry handler in an
    async module and asserts on the first event.
  - `session_registry_contract.ex:61` keeps a private `wait_until`.
  - About 15 serial test files give no reason for being serial.

## Notes, not defects

- `completitions/6` returns the response model unchanged in both adapters.
- `TokenCounter.count_message/3` defaults to a Haiku model id.
- The LLM-9 load allow-list ("any Normandy.Schema module") includes the adapter structs.
- Once memory reaches `max_messages`, every new message drops all thinking, including the
  current tool loop's. This follows from the strip-and-opt-in design.
- The streaming system prompt has no OUTPUT SCHEMA block (`base_agent.ex:1192` vs `:271`), so
  its `prefix_key` differs from the non-streaming one. Dropping thinking across the two is
  correct.

## Tests that fail if a fix is reverted

Each area reviewer named one per fixed finding. The exceptions are OTP-9 and SCHEMA-14
(a deletion), which have none, and TESTS-1 and TESTS-12, which are covered by CI only.

## Outcomes (2026-10-02)

Every item was fixed test-first unless noted. Each fix commit cites its FV id.

| Item | Outcome | Commit(s) |
|---|---|---|
| FV-1 | Fixed: the stream error is thrown without the config | d896114 |
| FV-2 | Fixed: an `:infinity` waiter has no timer; a bad `:timeout` raises in the caller | 967c55b, 6538b40 |
| FV-3 | Fixed (Q chose a degraded start): a store fault starts the server `:unavailable`; it retries on calls and on a backoff timer | ee5fb4c |
| FV-4 | Fixed: the agent id is read from the process dictionary, without a call | 2c23c1b |
| FV-5 | Fixed: `__meta__` and redacted fields are removed at every depth | 43e50e6 |
| FV-6 | Fixed: the summarizer's kept part starts at a user message | d185bf8 |
| FV-7 | **Premise false; open for Q.** Regular thinking blocks replay across models: the API drops a block the target cannot read and the request succeeds, and the guidance is to keep sending blocks when switching models. 404f24b strips them on a model change and should be reverted. | 404f24b |
| FV-8 | Fixed: RegexGuard compiles each pattern from its source and options | ce67fcc |
| FV-9 | Fixed (Q chose holder only): checkin is honored only from the holder | 963ce6e |
| FV-10 | Fixed: discovery returns `{:error, {:invalid_tool_name, name}}` | 393e477 |
| FV-11 | Fixed: every Postgres callback returns `{:error, reason}` | 7b72fcc |
| FV-12 | Fixed: an unknown `converse/7` shape raises, naming its type | 81282d0 |
| FV-13 | Fixed (Q chose schema errors only): the fallback runs only on 400s that name the output format or schema | 5e7bbe3 |
| FV-14, FV-21, FV-22 | Fixed: checked at agent init; option values are described, not printed | 3d48bf4 |
| FV-15, FV-23 | Fixed: shared `Normandy.LLM.ParseFailure`; no fake success | 9e74f3b |
| FV-16 | Fixed: a raising compute is a changeset error | d9526fc |
| FV-17 | Fixed: the count payload is built by the adapter's own message conversion | f8aa27f |
| FV-18 | Fixed: supported formats are kept; the validator checks date, time, duration and hostname | fd9217f |
| FV-19 | Fixed | 316ed5b |
| FV-20 | Fixed | 3af260b |
| FV-24 | **Not changed; open for Q.** Preserving each block's original position needs a stored block order (and server-tool blocks, which are not kept today). The docs do not settle whether order within one message is bound. | — |
| FV-25 | Fixed | 77fd837 |
| FV-26 | Documented: name the agents whose budgets are tracked | bf8cfa3 |
| FV-27 | Fixed | 8ceab61 |
| FV-28 | Fixed | b6e9254 |
| FV-29 | Fixed | 963ce6e |
| FV-30 | Fixed | c2a0909, ce44ce1 |
| FV-31 | Fixed (A2A also catches throws now) | a79b0a8 |
| FV-32 | Fixed | 2981593 |
| FV-33 | Fixed: `whereis` may return `{:error, reason}` | 6c012ba |
| FV-34 | All three confirmed and fixed: A2A throw, Redis `{n, 0}` wait, numbered id collision | a79b0a8, 448419f, b09db89 |
| FV-35 | Fixed; the examples were run | f2ef16e |
| FV-36 | Fixed: a built-in guard's config errors raise under any `:on_error`. A `:field` on a plain map is documented as uncheckable | 9ee9a10 |
| FV-37 | Fixed: rejected when the field is declared | 62e6185 |
| FV-38 | Fixed for wire-facing JSON. Size estimates keep Poison on purpose: Jason raises on content blocks | 07fd02a |
| FV-39 | Fixed | 4009026 |
| FV-40 | Fixed | 92c0683 |
| FV-41 | Fixed: rebuild failures are load errors (the server starts `:unavailable`) | 656e22e |
| FV-42 | Fixed | c117ed3 |
| FV-43 | Fixed: Dispatch keeps the original call id through every hook | c62031d |
| FV-44 | Fixed: sleeps, the filter restore, handler filters and the helper; eight serial files now run async, and every serial file says why | 15441e7, ea86d18 |

Found while fixing:

- **Flake root cause.** The eager-handoff test's cleanup was swallowed by a bare `rescue`, so 68 committed rows had built up. ResumeReaperIntegrationTest reaps every eager row, and timed out now and then. Fixed in 3213bf5; the leftover rows were deleted from the test database.
- **Flake.** The execute_stream timeout test gave the fast agent too little margin (2b1df90).
