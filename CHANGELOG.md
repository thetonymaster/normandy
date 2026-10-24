# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- - -
## [v2.1.0](https://github.com/thetonymaster/normandy/compare/c15da39d93036430599f99243e790429995acdf2..v2.1.0) - 2026-10-24
#### Features
- send the memory tool as Anthropic's native memory_20250818 (AX-33) (#55) - ([4798893](https://github.com/thetonymaster/normandy/commit/4798893bfae0157adf5eb740ab51a31b8ae8cea2)) - Antonio Cabrera
- close the medium tier of 2.0 known limits (#52) - ([792fe79](https://github.com/thetonymaster/normandy/commit/792fe792afefec9a0635c3945ef4da06b5d9ba2c)) - Antonio Cabrera
- close five more 2.0 known limits (#51) - ([eaa26b8](https://github.com/thetonymaster/normandy/commit/eaa26b8dc60399b344fe35d0e59fbb140665a0d2)) - Antonio Cabrera
#### Bug Fixes
- JSON prose extraction no longer records every byte after a stray brace (#54) - ([372e08d](https://github.com/thetonymaster/normandy/commit/372e08d99047f33e8fb06a2a8d036f9aae99568e)) - Antonio Cabrera
- close four 2.0 known limits (#49) - ([c15da39](https://github.com/thetonymaster/normandy/commit/c15da39d93036430599f99243e790429995acdf2)) - Antonio Cabrera
#### Miscellaneous Chores
- cite the bench result for Type's @compile inline (#53) - ([200866b](https://github.com/thetonymaster/normandy/commit/200866be3bbb17889d278ef27fe08e8da112d955)) - Antonio Cabrera
- add Benchee benchmarks (mix bench) - ([a1426a7](https://github.com/thetonymaster/normandy/commit/a1426a79144b30138fc420e5bd538cee9286ffab)) - Antonio Cabrera

- - -

## [v2.0.0](https://github.com/thetonymaster/normandy/compare/cf8fd089cc4a393f852db77571de2a21ed07ada0..v2.0.0) - 2026-10-24
#### Features
- ![BREAKING](https://img.shields.io/badge/BREAKING-red) Normandy 2.0 - ([95bd480](https://github.com/thetonymaster/normandy/commit/95bd480f0d124c3df18e115a16d8db04c61a90d7)) - Antonio Cabrera
#### Documentation
- performance and race-condition audit report - ([12b3440](https://github.com/thetonymaster/normandy/commit/12b344077d1f90667fcbcb25c43de8dde689f704)) - Antonio Cabrera
- W2-A implementation plan (schema artifact + coordination one-liners) - ([ffbd389](https://github.com/thetonymaster/normandy/commit/ffbd389dcaf4eeca1aef570ada3c45ee512500f2)) - Antonio Cabrera
- coordination-layer reliability design spec (audit wave 2) - ([1b7336e](https://github.com/thetonymaster/normandy/commit/1b7336e476acffd2a5ec03f67d156616033db508)) - Antonio Cabrera
- implementation plans for critical-fixes 1-6 - ([922c35c](https://github.com/thetonymaster/normandy/commit/922c35c3b3a4e11850eb69a6eb2761c49a9b03dd)) - Antonio Cabrera
- framework workflow assessment and critical-fixes design spec - ([3a2d65b](https://github.com/thetonymaster/normandy/commit/3a2d65b7c9262cde69f2ff6cd5e10d05e33ab75c)) - Antonio Cabrera
#### Tests
- integration tool_use check accepts replayed content blocks (#48) - ([dd95de0](https://github.com/thetonymaster/normandy/commit/dd95de0566536a3e8fb277ac5929d3d639a94ad6)) - Antonio Cabrera
#### Continuous Integration
- re-enable Dialyzer type-checking gate (#45) - ([cf8fd08](https://github.com/thetonymaster/normandy/commit/cf8fd089cc4a393f852db77571de2a21ed07ada0)) - Antonio Cabrera

- - -

## Normandy 2.0 release notes

Normandy 2.0 moves to Claudio 0.7.1 and works with the current Claude models (Opus 4.7 and later reject
sampling parameters and budgeted thinking). It is a breaking release: **read `MIGRATING-2.0.md` before
upgrading**; its "Who is affected" table at the top sends you to the sections that concern you, and
"Known limits of 2.0" at the end lists what 2.0 does not do yet.

### Highlights

- **One model protocol.** `Normandy.Agents.Model` is `converse/3` and `stream/3` over
  `%Normandy.LLM.Request{}`; failures are `%Normandy.LLMError{}` and `run/3` returns
  `{:ok, config, output}` or `{:error, exception}` (`run!/3` raises). `stream/3` returns the output schema
  like `run/3`.
- **Durable sessions.** `Turn.Session` and `Turn.Server` persist every turn boundary to a
  `SessionStore` (InMemory, ETS, Mnesia, Postgres, Redis), resume after a crash or on another node
  (`SessionRegistry` Native, Horde or Redis; `ResumeReaper`), park tool calls for approval, and keep a
  turn whose final save failed until the store recovers.
- **Tools.** One `Normandy.Tool` behaviour (`use Normandy.Tool, name:, description:, input:`), a
  `Toolset`, validated tool input, per-tool timeouts and result caps; MCP and A2A tools are prefixed.
- **Lifecycle hooks** (`Normandy.Behaviours.Hooks`), **long-term memory** (`Normandy.Tools.Memory` over a
  `MemoryStore`), **policy, budget and guardrails** checked on every path.
- **Structured outputs on tool loops.** A non-chat output schema is sent as `output_config.format` beside
  the tools; a cut-off, refused or blank answer is an error on every path.
- **Prompt caching on by default**, the conversation built in linear time, assistant turns (thinking,
  citations, server and MCP tool blocks) replayed exactly as the API returned them.
- **Every option is validated** (NimbleOptions; an unknown option raises naming it).
- **Observability.** The `Normandy.Telemetry` catalogue documents every event; run, LLM-call, request,
  tool, approval and workflow spans carry OpenTelemetry GenAI attributes and run totals.
- **Testing support.** `Normandy.Test.FakeClient` and the store and registry contracts
  (`Normandy.Test.SessionStoreContract`, `MemoryStoreContract`, `SessionRegistryContract`) ship in the
  package; `docs/guides/testing.md` shows them.

### Added

- `Normandy.Agents.Turn.Driver.Handlers.default/0`: the handler set `Turn.Server` uses when `:handlers`
  is `nil`; build a custom set from it (`%{Handlers.default() | validate: f}`).
- **Telemetry catalogue.** `Normandy.Telemetry` documents every event with its measurements, metadata,
  the OpenTelemetry GenAI attribute mapping and the known limits. `test/telemetry/catalogue_test.exs`
  fails when an event is emitted but not listed there, or the reverse.
- `[:normandy, :llm, :request, :start | :stop | :exception]`: one span per provider request inside an
  llm_call (`attempt`, `request_kind`, `status`, `response_id`, `finish_reason`, token counts).
- `[:normandy, :agent, :llm_call, :stop]` adds `provider`, `stream`, `structured_output`, `max_tokens`,
  `temperature`, `effort`, `server_address` (start), `response_id`, `finish_reason` (a string, when the provider sent one),
  `served_by`, `attempts`, `json_retries`, `structured_fallback`, and for streaming
  `time_to_first_chunk` (metadata, native units). Normalized `input_tokens` (Anthropic: includes cache
  reads and writes), `output_tokens`, `cache_read_input_tokens`, `cache_write_input_tokens` sit beside the
  unchanged raw `usage`; streaming calls carry usage too, and OpenAI-shaped usage is normalized.
  Failed calls carry the billed usage on the error: `reason.usage` and `reason.usage_counts`.
- Run, llm_call and tool events carry `provider`, `turn_id`, `session_id` and `conversation_id` when
  known; tool spans add `tool_call_id`, `tool_description`, `tool_type` and, on failure, `error_type`.
- `[:normandy, :tool, :denied]` for every call answered without running its tool.
- `[:normandy, :turn, :approval, :start | :stop]` per approval park (`outcome`), and an `approval_wait`
  measurement on `Turn.Server`'s run `:stop`/`:exception`. The run stays one span.
- `Normandy.Components.ContentBlock.Protocol`, `Normandy.Agents.Turn.ServerSupervisor`,
  `Telemetry.Usage.sum/2`, `Telemetry.Span.span/4`, `A2A.AgentTool` `:poll_interval`, and optional
  `Compactor.validate_opts!/2`, `Compactor.needs_window?/1` and `ModelCatalog.needs_claudio_client?/1`
  callbacks (a host compactor or catalog no longer needs a `BaseAgent` edit).
- `[:normandy, :workflow, :run]` around `Workflow.execute/1` and the orchestrators' entry points.
- `[:normandy, :a2a, :request]` around `A2A.Server.handle_message/3`.
- Trace context: `Turn.Server`, `AgentProcess` and the coordinators carry the caller's OpenTelemetry
  context into the runs they start. `A2A.AgentTool` injects a W3C `traceparent` and
  `A2A.Server.handle_message/3` extracts it; this needs Claudio's A2A transport `:headers` option
  (Claudio 0.7.0). MCP calls carry no trace context (`call_tool/4` has no field for it).
- Resumed durable turns emit a run `:start` with `resumed: true`, parented under the persisted caller
  context.

### Changed

- Requires Elixir 1.17 or later (was 1.15); CI tests Elixir 1.17-1.19 on OTP 27 and 28.
- Breaking changes are listed, with what to do, in `MIGRATING-2.0.md` (sections 1–47). The bullets below
  are the telemetry and rolling-deploy changes; MIGRATING has the rest.
- `Turn.Server.run/2` now sends `{:turn, input, ctx}` and `approve/2` casts `{:approval, decisions, ctx}`.
  `AgentProcess.run/3` sends `{:run, input, ctx}` and `AgentProcess.cast/3` sends
  `{:run_async, input, reply_to, ctx}`. New servers still accept the old shapes, but an old-version
  server that receives a new shape crashes. **Rolling deploy: upgrade the nodes that host servers
  (`Turn.Server`, `AgentProcess`) before the nodes that call or approve them.**
- `Turn.State` gains `tokens_compacted` and `trace_carrier`. **On the Postgres and Redis stores a
  pre-2.0 node cannot load a session a 2.0 node has served** (its `[:safe]` decode raises on the
  new field names), finished turns included, and rolling back hits the same failure. Move every
  session-hosting node to 2.0 together; see MIGRATING-2.0.md §13.
- The `normandy llm call stop` log line's `input_tokens` is now the normalized count (Anthropic:
  input plus cache read and write), matching the span's normalized `input_tokens`. Log parsers that
  summed the old value on Anthropic will see larger numbers when prompt caching is on.
- Breaking, from the principles audit (what to do is in `MIGRATING-2.0.md`):
  - A `Turn.Session` with a `:template_provider` needs a credential provider in the config's
    `behaviours` (`credential` has no default; `CredentialProvider.FromClient` is removed) (§26).
  - `config :normandy, :adapter` is removed: Normandy encodes JSON with Jason. `JsonDeserializer` drops
    `:adapter`, `:recover_truncated_strings` and the `:recovery` event, and now refuses unknown options (§23).
  - The Redis store, memory store and registry constructors require `:url` and `:namespace` (`:prefix`);
    the two Postgres `new/0` are removed (§40).
  - `Coordination.Pattern`: `ok/1` and `error/1` removed, `ok!/2` and `error!/2` are `ok_value/2` and
    `error_reason/2`; `HierarchicalCoordinator` drops `:shared_context`; `Batch.Processor` errors are
    bare exceptions or `:task_down` `TurnError`s; a map input reaches the agent whole (§42).
  - `TokenCounter.count_message/2` removed (pass the model); `WindowManager` drops `:sliding_window`
    and `:summarize` without a client raises (§6).
  - `Normandy.Type` drops Ecto's `embed_as`, `embedded_dump/load`, `match?`, `primitive?`, `load`;
    `%Validate{}` drops `constraints`, `filters`, `prepare`; schema structs drop `__meta__` and
    `Normandy.Metadata` is removed (stored data still loads) (§47).
  - `Toolset` keeps one `Toolset.Entry` per tool; `Memory.new/1` and `Retry` validate through
    `Normandy.Options` (§25, §30).
  - OpenAI-compatible adapter: HTTP 529 is `:overloaded`, a status above 599 a retryable `:server` (§11).
  - `BaseAgent`'s `@doc false` functions moved to internal modules (§45); `run/3` and `stream/3` classify
    tool calls in the caller, as `Turn.Server` does (§16).

### Fixed

- `Turn.Server` no longer leaves a finished session in the in-flight index when the store fails at the
  turn's last save: it keeps the result, retries the save, refuses new turns with `:persist_failed`
  until it lands, and a resume whose answer is already stored makes no model call.
- A tool result is encoded once on every path (it was encoded up to five times).
- A new input after a stored paused turn continues that turn first, so the API no longer rejects
  every later request.
- A module using the `agent do` DSL compiles without warnings on Elixir 1.20.
- A `Schema.Validator` type error names a `Date`, `Time`, `NaiveDateTime` or `DateTime` value
  instead of calling it `object`.
- A request drops a server-tool use nothing answers, except in its last message, so the next
  input after a continued pause is accepted.
- A chat answer given beside a tool call survives a blank final reply instead of failing with
  `:invalid_output`. The run `:stop` metadata marks such an answer `answer_source: :tool_round`
  (`:final` otherwise). Memory stores the sentence in the tool-calling reply and as the answer
  (also when the model itself wrote it in both); later requests show it once: the tool-calling
  message is sent without its text, which rewrites the prompt cache from that message once. It
  is sent whole when it, or a later message of that turn before the answer, carries thinking
  the request sends, or when its text carries citations.
- JSON region extraction is linear on unclosed `{` and `[` (a 240 KB reply took 30 s) and bounded by a
  work budget; `JsonDeserializer` reports each retry's usage as it finishes.
- `StatefulContext` reads no longer wait behind a slow `update/4` (it commits by compare-and-set).
- A killed breaker `Registry` restarts instead of stopping the application, and a breaker crash no longer
  drops `AgentProcess` registrations.
- A host guard whose module sits under `Normandy.Guardrails.Builtins.` no longer gets built-in
  `:on_error` handling.
- `Normandy.Cluster.redis_child_specs/1` and `redis_handles/1` read `:redis_wait` and compute the store
  plan once per call.
- `Turn.Server` runs its worker through `Normandy.WatchedWorker`; a result from another worker is dropped.
- Coordinators (`Reactive`, `ParallelOrchestrator`, `Batch.Processor`) emit a synthetic
  `[:normandy, :agent, :run, :exception]` with `reason: :killed` for each agent task they kill. A handler
  can see it without a matching `:start`; the llm_call and tool spans inside a killed run stay open.
- `Reactive.all/3` keeps the results it collected when an agent exits or times out.
- `Turn.Server` closes the run span on `terminate/3` and ignores stray messages.
- `Context.Summarizer`'s summary request is an `[:normandy, :agent, :llm_call]` span (`purpose: :summary`,
  no `iteration`) with the agent's name and ids, and its provider requests carry them too. Before, its
  requests had no llm_call and no ids, so compaction tokens were missing from llm_call totals.

- - -
## [v1.3.0](https://github.com/thetonymaster/normandy/compare/6416cea35d8b120370c644dcd9a297dec67df829..v1.3.0) - 2026-06-23
#### Features
- (**llm**) JSON pipeline refactor, converse-contract fix, and native structured outputs (#44) - ([6416cea](https://github.com/thetonymaster/normandy/commit/6416cea35d8b120370c644dcd9a297dec67df829)) - Antonio Cabrera

- - -

## [v1.2.0](https://github.com/thetonymaster/normandy/compare/5dbc6ecf1c354015b8d49a2893de68d72f8231bc..v1.2.0) - 2026-06-20
#### Features
- (**agent_horde**) multi-agent multi-provider research pipeline + OpenAI-compatible adapter (#43) - ([5dbc6ec](https://github.com/thetonymaster/normandy/commit/5dbc6ecf1c354015b8d49a2893de68d72f8231bc)) - Antonio Cabrera

- - -

## [v1.1.1](https://github.com/thetonymaster/normandy/compare/c655a054b67a0931fcd8ab1434393fd648cb3d12..v1.1.1) - 2026-06-20
#### Bug Fixes
- (**telemetry**) emit agent.run span from run_with_tools/2 entry point (#42) - ([c655a05](https://github.com/thetonymaster/normandy/commit/c655a054b67a0931fcd8ab1434393fd648cb3d12)) - Antonio Cabrera

- - -

## [v1.1.0](https://github.com/thetonymaster/normandy/compare/931ce1418e0259cb66c563bce8ce019a16d6b77a..v1.1.0) - 2026-06-19
#### Features
- (**tools**) validate tool input at the Dispatch chokepoint before side effects (#40) - ([931ce14](https://github.com/thetonymaster/normandy/commit/931ce1418e0259cb66c563bce8ce019a16d6b77a)) - Antonio Cabrera
#### Continuous Integration
- add cocogitto autopublish pipeline (#41) - ([56b995c](https://github.com/thetonymaster/normandy/commit/56b995cf413c06731a030d8745ecce010a5c169c)) - Antonio Cabrera

- - -


## [1.0.0] - 2026-06-17

### Added

- **Phase 7 — distributed multi-node sessions (Tiers 0/1/2 + eager resume).**
  - `Normandy.Behaviours.SessionStore.Postgres` — durable session store over
    Ecto/Postgres (entries, opaque turn state, config template), with migrations
    and `resume_policy` / `config_template` columns. The Tier-1 durable store.
  - `Normandy.Behaviours.SessionRegistry.Horde` (`:via`, `members: :auto`) and
    `Normandy.Agents.Turn.Supervisor.Horde` — CRDT-backed distributed registry +
    dynamic supervisor that route to / own `Turn.Server`s across a cluster (Tier-2).
  - `Normandy.Agents.Turn.ResumeReaper` — selective **eager handoff** on
    `:nodedown`. Because `Horde.DynamicSupervisor` does not redistribute a dead
    node's children, the reaper restarts the eager, unregistered, non-terminal
    sessions whose server died with the lost node. Lazy rehydrate (route →
    `whereis` → rehydrate-on-demand) needs no reaper.
  - `Normandy.Behaviours.AgentTemplate` + a persisted **config template**
    (`Normandy.Agents.Turn.ConfigTemplate`): the non-secret config
    (model/temperature/behaviour refs/tools) needed to reconstruct an agent on
    rehydration; a `template_provider` resolves it. Credentials are never persisted.
  - `SessionStore` gained `save_config_template/3`, `load_config_template/2`, and
    `list_resumable/1` (eager session ids); `SessionRegistry` gained the optional
    `child_name/2` (`{:via, …}`) for atomic, supervisor-driven start that closes the
    start-time race. `InMemory` / `ETS` / `Native` impls were extended to match.
  - `Normandy.Cluster.child_specs/1` — one-call wiring of the Horde registry +
    supervisor + reaper (plus an optional `libcluster` `Cluster.Supervisor` when
    `:topologies` are supplied and `libcluster` is loaded).
  - Tier model: **Tier-0** in-memory/ETS single-node default (unchanged);
    **Tier-1** durable store + lazy rehydrate; **Tier-2** distributed
    registry/supervisor + eager reaper.
  - Drop-in backends behind the same `SessionStore` / `SessionRegistry` seam:
    `SessionStore.Mnesia` (OTP-native distributed store, transactional appends, no
    external DB), `SessionStore.Redis` (Redis Streams), `SessionRegistry.Redis`
    (`:via` registry using Redis as the name table), and the
    `Normandy.Cluster.setup_mnesia_store!/1` / `redis_child_specs/1` wiring helpers.

- **Guardrails — pre-charge admission, threaded context, fail-open, semantic scope.**
  - `Normandy.Agents.BaseAgent.admit/2,3` runs input guardrails as a **pre-charge
    filter** (no turn, memory, or circuit breaker), returning
    `:ok | {:block, violations}` instead of raising — reject disallowed input
    before paying for a turn.
  - `Normandy.Guardrails.run/3` threads a caller-supplied `context` map to guards
    implementing the optional `Guard.check/3` callback (`check/2`-only guards are
    unaffected) — host data a guard needs but the framework must not interpret
    (ids, locale, conversation history).
  - Per-guard `:on_error` policy: `:reraise` (default — a config bug stays a crash),
    `:open` (rescue the guard's raise and treat as a pass, for a guard fronting a
    flaky external service), `:closed` (rescue and turn it into a `:guard_error`
    violation). Only the `check` call is rescued; a malformed return always raises.
  - `Normandy.Guardrails.Builtins.SemanticScope` — a provider-agnostic hybrid scope
    guard: a cheap injected `fast_path` in front of an injected `classifier`
    (`(value, context) -> :allow | {:block, reason}`); the `:block` reason becomes
    the violation's machine-readable `:constraint`. (#31)

- **Phase 6 — AgentProcess durable turn engine (`:server` mode).**
  - `Normandy.Coordination.AgentProcess` opt-in `:server` mode (`turn_engine: :server`)
    routing turns through the durable `Turn.Session`/`Turn.Server` engine: approval
    parking, passivation, and persistence. `:inline` remains the default and is
    byte-for-byte unchanged.
  - `AgentProcess.approve/2` delivers human-approval decisions to a parked turn.
  - Non-blocking `:server` `run/3`/`cast/3`: the GenServer stays responsive while
    a turn is parked awaiting approval or passivated.
  - Store-authoritative `get_agent/1`: reconstructs agent (including conversation
    memory) from `SessionStore` in `:server` mode.
  - Template-only `update_agent/2` in `:server` mode: updates config template
    (model/temperature/behaviours/tools); memory mutations are ignored because
    `SessionStore` is authoritative.
  - Owned-or-supplied session infra: `:store`, `:registry`, `:supervisor` may be
    passed to `start_link`; if omitted, the process starts and owns in-memory
    defaults that terminate with it. `:subscriber`, `:handlers`,
    `:approval_timeout_ms`, and `:idle_timeout_ms` are forwarded to `Turn.Session`.

- **Phase 5 — compaction wiring (`:steering` boundary).**
  - `Normandy.Behaviours.Compactor` behaviour (+ `NoOp` default, opt-in
    `WindowManager` impl) invoked at the `:steering` turn boundary when the context
    window is exceeded; `compactor` slot on `Behaviours.Config`. (PR #32)

### Fixed

- Flaky `Turn.Supervisor.Horde` test: a `start_server` racing the `:via`
  registration could observe a transient `{:error, {:already_started, _}}`; the
  test now retries the start through the via race. (#36)
- `convert_turn_output/3` previously returned the empty output-schema struct for
  tool-using turns with non-`chat_message` output schemas, dropping the final-
  response content. Non-`chat_message`-schema agents using tools were affected.
- `Normandy.Context.TokenCounter` was unusable against the live API: every
  `count_message/2,3`, `count_conversation/2`, and `count_detailed/2` call sent
  `max_tokens` in the `/v1/messages/count_tokens` payload, which the endpoint
  rejects (`400 invalid_request_error: "max_tokens: Extra inputs are not
  permitted"`). The field is now omitted. The default model also moved off the
  retired `claude-3-5-sonnet-20241022` to `claude-haiku-4-5-20251001`. The
  previously-skipped token-counter tests are now enabled as `:integration` tests
  and pass against the live endpoint.

### Migration

- No action required: `:inline` is the default and is byte-for-byte unchanged.
- To adopt the durable engine:
  `AgentProcess.start_link(agent: config, turn_engine: :server)`, optionally
  passing shared `:store`/`:registry`/`:supervisor`.

## [0.9.0] - 2026-06-17

### Added

- **Phase 4a — approval core + chokepoint split (harness decomposition).**
  - `Normandy.Agents.Dispatch.classify/3` (registry → before-hooks → policy →
    verdict) and `Dispatch.execute/4` (budget → execute → record → after).
    `dispatch_one/3` is re-expressed as `classify ➞ execute`; its observable
    behavior is unchanged (the existing dispatch suite is the parity oracle).
  - `Normandy.Agents.Turn` core gains real human-approval parking: an
    `:awaiting_approval` state, `parked_calls`/`held_results` on `%Turn.State{}`,
    and the `{:needs_approval, held, parked}` → `{:approval, decisions}` →
    `{:approved_results, results}` event flow, with the batch-results logic
    factored into a shared `apply_tool_results/2` (one decrement per batch,
    API-order preserved). The synchronous inline path is unchanged — only the
    Phase 4b `:gen_statem` shell will exercise these transitions.

- **Phase 4b — `:gen_statem` Turn shell (harness decomposition).**
  - `Normandy.Agents.Turn.Server`: an opt-in asynchronous `:gen_statem` interpreter
    of the pure `Turn` FSM (the async analog of the inline `Driver`). Coarse
    lifecycle states (`:running`/`:awaiting_approval`/`:idle`) carry monitored
    Tasks for blocking effects, `state_timeout`s (approval expiry, passivation
    idle), persistence at suspend points, and mid-turn message postponement. Real
    human-approval parking: park on `:needs_approval`, resume via
    `Turn.Server.approve/2`, fail-closed on approval timeout.
  - `Normandy.Agents.Turn.Session` (router: whereis → route | rehydrate),
    `Normandy.Agents.Turn.Supervisor` (`DynamicSupervisor`, `restart: :transient`).
  - `Normandy.Behaviours.SessionRegistry` (`whereis/register/unregister`) + `Native`
    default over Elixir `Registry`; `session_registry` slot on `Behaviours.Config`.
  - `Normandy.Components.AgentMemory.from_entries/1` rebuilds memory from stored
    history for rehydration.
  - Four `BaseAgent` turn helpers exposed `@doc false` for shell reuse
    (`non_streaming_handlers/0`, `admit_turn_input/2`, `base_agent_pipeline/1`,
    `turn_response_model/1`) — visibility-only, no behavior change.
  - `BaseAgent.run/2`'s inline path is unchanged; `Turn.Server` is additive.

### Fixed

- Corrected the version stamp: the prior `1.0.0` (Phase 3) was never tagged and
  `1.0.0` is reserved for the final phase of the harness-decomposition milestone.
  Phase 3 is re-labeled `0.8.0` (a pre-1.0 breaking change from `0.7.0`).

## [0.8.0] - 2026-06-12

### Added

- **Branching session memory + SessionStore (Phase 3 of the harness
  decomposition).**
  - `Normandy.Components.AgentMemory` is now a struct of parent-linked
    `AgentMemory.Entry` records (`id` + `parent_id`) instead of a linear list.
    Branching is opt-in via `fork/2`; a linear conversation is a degenerate
    single-parent chain and `history/1` output is unchanged. New accessors:
    `fork/2`, `entries/1`, `get_entry/2`, `entry_chain/1`, `messages/1`,
    `latest_message/1`.
  - `Normandy.Behaviours.SessionStore` (`append_entry/3`, `history/2`, `fork/3`,
    `save_turn_state/3`, `load_turn_state/2`) with `InMemory` (default) and `ETS`
    impls sharing one contract suite. Both serialize per-session writes (the
    `InMemory` impl via its `Agent`, the `ETS` impl via a GenServer that owns a
    private table), so concurrent appends/forks to one session can't clobber each
    other — a guarantee the shared contract now exercises under concurrency. The
    turn-state half round-trips an opaque term; its consumer (suspendable turn /
    passivation) lands in Phase 4. Postgres is deferred.
  - `session_store` slot on `Normandy.Behaviours.Config` (default
    `{SessionStore.InMemory, []}`) — selectable per-agent, not on the dispatch
    pipeline, not yet consumed by the turn loop.

### Changed

- **BREAKING:** `AgentMemory`'s struct shape and `dump/1`/`load/1` JSON format
  changed (entry-based). The dump carries a `version` key (currently `1`) as a
  forward marker for future format detection — `load/1` does not yet branch on it.
  Code that read the old `%{history: [...]}` map shape must use the public API or
  the new accessors. The `dump/1`/`load/1` format is not backward-compatible with
  pre-1.0 dumps.
- `count_messages/1` now returns the total number of stored entries
  (`map_size(entries)`). For a linear conversation this is identical to the old
  active-chain length; after a `fork/2` with divergent appends it counts entries
  across all branches, not just the active one.

### Security

- `AgentMemory.load/1` no longer decodes dumps with `keys: :atoms`. A blanket
  atom decode interned every nested content key, so an untrusted/corrupt dump
  could exhaust the VM atom table. `load/1` now decodes with string keys and
  atomizes only known struct field names (via `to_existing_atom`, which never
  mints new atoms); raw content round-trips verbatim.

### Robustness

- `AgentMemory` graph walks are cycle-safe. Both the active-branch walk
  (`chain_newest_first/1`, behind `history/1`, `entry_chain/1`, `messages/1`) and
  the survivor-rewiring walk (`surviving_ancestor`, behind `delete_turn/2`) track
  visited ids, so a corrupt dump carrying a parent cycle terminates instead of
  looping forever.

### Notes

- Linear-conversation observable behavior is unchanged — the end-to-end suite is
  the parity oracle. Internal consumers (`base_agent` iteration counters,
  `window_manager`/`summarizer` memory rebuild) and white-box tests were migrated
  behavior-preservingly to the new accessors.

## [0.7.0] - 2026-06-01

### Added

- **Pluggable behaviours (Phase 2 of the harness decomposition).** The dispatch
  chokepoint's function slots are now backed by four Elixir `@behaviour`s, each
  with a default impl that preserves current behavior:
  - `Normandy.Behaviours.PolicyEngine` (`check/2`) — default `AllowAll`; plus a
    shipped `Ruleset` impl that evaluates ordered in-memory rules
    (`match` glob → `:allow | :deny | :require_approval`, first-match-wins,
    configurable `default_action`).
  - `Normandy.Behaviours.BudgetTracker` (`check/2`, `record/2`) — default `NoOp`.
  - `Normandy.Behaviours.CredentialProvider` (`get_token/2`) — default
    `FromClient` (extracts `api_key` from the client struct). Defined and
    defaulted; LLM-call consumption deferred.
  - `Normandy.Behaviours.ModelCatalog` (`get/1`, `supports?/2`,
    `context_window/1`) — default `Static`, now the single source of truth for
    `WindowManager`'s context-window limits.
- **`Normandy.Behaviours.Config`** bundle + `to_pipeline/1`, selectable per-agent
  via the new `BaseAgentConfig.behaviours` field. `before/after` hooks are now
  first-class, config-selectable function slots.

### Notes

- Additive and default-off: with the default bundle, observable behavior is
  unchanged. No migration required.

## [0.6.3] - 2026-05-12

### Added

- **`Normandy.LLM.JsonDeserializer` now supports opt-in recovery from a
  specific truncated-JSON failure mode**: when an LLM (notably
  Nemotron-Nano-12B-VL on DigitalOcean Inference) emits a response that
  ends inside an unclosed top-level string field — typically because the
  model entered a `\n`-escape runaway and ran out of output tokens —
  `parse_and_validate/3` and `deserialize_with_retry/8` now accept
  `recover_truncated_strings: true`. When the flag is on AND the strict
  decode fails AND the content looks like a single top-level object AND a
  byte scanner determines the unclosed string is at the outermost depth,
  Normandy truncates the string at the last position whose preceding
  bytes were not part of a `\n` escape, appends a closing `"`, and
  appends `}`/`]` closers derived from a tracked open-container stack.
  The recovered payload is re-decoded once through the adapter and run
  through the same cast pipeline as the happy path; a
  `[:normandy, :json_deserializer, :recovery]` telemetry event is
  emitted on success with `%{recovered: 1}` measurements and
  `%{strategy: :truncated_string, byte_size_before: _, byte_size_after: _}`
  metadata. Default is `false` — pre-existing callers see no behaviour
  change. Designed for vision-pipeline `page_text` transcription
  payloads where the alternative is an empty `%Output{}` and zero RAG
  indexing on customer-grade documents; not a general-purpose JSON
  repair. Nested-string truncation (e.g. `{"offerings":[{"name":"Paq`)
  explicitly does NOT recover, since manufacturing a closer there would
  produce a half-truthful inner record rather than empty top-level data.

## [0.6.2] - 2026-05-11

### Fixed

- **`Normandy.LLM.JsonDeserializer` now recovers from tool-use-style
  response envelopes**: some vision/instruction-following LLMs
  (Nemotron-Nano-12B-VL on DigitalOcean Inference, some Llama variants)
  wrap their JSON in `{"name": "...", "arguments": {...}}` even when
  given `response_format: {"type": "json_object"}` and a system prompt
  asking for the bare object shape. `parse_and_validate/3` previously
  cast such payloads to an all-defaults struct and returned `:ok`, so
  downstream consumers (notably `event_crew`'s vendor-doc vision
  extraction) silently dropped every populated field. `parse_and_populate/3`
  now retries the cast once against `parsed["arguments"]` when the outer
  attempt either succeeded with all-defaults OR returned a
  validation error, and the `"arguments"` value is itself a map. If the
  retry yields any populated field it wins; if it still yields
  all-defaults the original result is preserved so bare-shape responses
  see no behaviour change. One level only — `{"arguments": {"arguments":
  {...}}}` is not unwrapped. Inner cast errors are propagated when the
  inner map carries at least one permitted key (atom or string form), so
  e.g. `{"arguments":{"count":"not_a_number"}}` against `count: :integer`
  surfaces the validation error instead of returning an empty struct;
  inner errors are still suppressed when no permitted keys are present,
  so unrelated envelopes don't manufacture new failures. The
  `{:ok, struct}` / `{:error, reason}` contract is unchanged for every
  pre-existing shape (#22).
- **`get_required_fields/1` in `JsonDeserializer` now reads required
  fields from the correct source**: the helper was filtering
  `__specification__/0` entries as if each were a metadata map, but
  `Normandy.Schema` stores `{name, type}` tuples there — so the filter
  never matched and `validate_required/2` was being called with an empty
  list for every schema. It now reads `__schema__(:required)` (the
  source of truth) and falls back to the old scan for schemas that don't
  expose that callback. Required-field validation now actually fires for
  schemas declaring `field :foo, _, required: true` (#22).

## [0.6.1] - 2026-05-02

### Fixed

- **OpenTelemetry context propagation across `Normandy.Tools.Executor`
  spawn sites**: tool bodies run via `Task.async/1` in
  `execute_with_timeout/2` and `execute_parallel/3`. OTel context lives in
  the process dictionary, so spawned `Task`s started with an empty context
  — any span opened inside a tool's `run/1` became a root span in a fresh
  trace instead of nesting under `normandy.tool.execute`. Symptom in
  downstream apps: integration spans (e.g. external API calls, blob
  downloads) appeared as orphans in Tempo, and `normandy.tool.execute`
  was an opaque blob with no breakdown. The executor now captures the
  parent context before each spawn and re-attaches it inside the spawned
  function. Applied at both `Task.async` sites:
  `execute_with_timeout/2` (the primary fix) and `execute_parallel/3` (so
  the inner timeout call sees a non-empty context to propagate further).
  The capture/restore helpers (already present in `BaseAgent` for
  `Task.async_stream`) are extracted into a new internal
  `Normandy.Telemetry.OtelCtx` module and shared by both call sites; they
  no-op when `:opentelemetry` is not loaded, so consumers without OTel
  pay nothing (#20).

### Security

- **Secret redaction in `Inspect` output for `Normandy.LLM.ClaudioAdapter`
  and `Normandy.A2A.AgentTool`**: a live API key leaked through default
  error logging in a downstream project when a `Task` crashed and the
  BEAM error logger inspected closure args holding a `%ClaudioAdapter{}`.
  `Kernel.inspect/2` rendered the secret in plaintext. Both structs now
  carry `@derive {Inspect, except: [...]}` covering `:api_key`
  (`ClaudioAdapter`) and `:auth_token` (`AgentTool`).
  `Normandy.MCP.ServerConfig` already had this protection. Field access
  (dot syntax, `Map.get/2`, pattern matching) is unchanged; only the
  `Inspect` representation is affected. Locked in with regression tests
  asserting the secret value never appears in `inspect/1` output (#19).

### Changed

- **ExDoc warnings silenced**: `Normandy.Type.load/1` is now declared as
  an optional callback (the contract was already documented and
  exercised by custom-type implementations).
  `Normandy.ParameterizedType.embed_as/2` is also now declared as an
  optional callback (already in `defoverridable` with a default `:self`
  impl). No behavioural change; doc-build is now warning-clean (#18).

## [0.6.0] - 2026-05-01

### Added

- **Typed-struct cache control on multimodal content blocks**: each of
  `Normandy.Components.ContentBlock.{Text,Image,Document}` gains an optional
  `cache_control` field plus `with_cache/1` (ephemeral, the common case) and
  `with_cache/2` (caller-supplied map, e.g. `%{"type" => "ephemeral", "ttl"
  => "1h"}`). Atom keys are accepted and stringified at serialization time.
  `to_claudio/1` emits the `cache_control` key only when set, so existing
  callers see no wire-shape change. Closes the gap left in `0.5.1` where
  multimodal cache breakpoints required hand-built raw maps.
- **Conversation-breakpoint auto-cache strategy**: when
  `enable_caching: true`, `Normandy.LLM.ClaudioAdapter` now annotates the
  last block of the **last user message** with
  `cache_control: %{"type" => "ephemeral"}`, mirroring how Anthropic
  recommends placing prompt-cache breakpoints on chat conversations.
  Triggers only for list-form or single-`ContentBlock`-struct content —
  plain-string user messages keep their existing wire shape so chat-text
  callers see no behaviour change. Caller-set `cache_control` (via
  `with_cache/1-2` or hand-built atom/string-keyed `cache_control` on a raw
  map) is preserved; the adapter never overrides it. Earlier user messages
  in the history are not annotated.
- **List-form system prompt caching**: the system clause of
  `add_single_message/3` previously short-circuited
  `enable_caching: true` for list-form content because Claudio's
  `set_system_with_cache/2` only wraps strings. The adapter now annotates
  the last block of a list-form system prompt and routes it through
  `set_system/2` with pre-shaped wire blocks. Symmetric with the existing
  string-system caching path.
- **Normandy.Components.ContentBlock.CacheControl** (`@moduledoc false`):
  internal helper that string-normalizes top-level cache_control keys and
  raises `ArgumentError` when an atom and string version of the same key
  collide post-normalization, so caller intent is never silently lost.

### Changed

- **`dispatch_multimodal/3` named-helper patterns now require
  `cache_control: nil` on both blocks**. Claudio's
  `add_message_with_image`, `add_message_with_image_url`, and
  `add_message_with_document` take raw args and rebuild blocks internally —
  any `cache_control` on the source `ContentBlock` struct would have been
  silently dropped on the wire. With this change, cache-annotated blocks
  always go through the raw-list fallback path that preserves block fields.
- **Multimodal system prompt with `enable_caching: true`** now emits
  `cache_control` on the last system block. Previously this combination
  was a documented opt-out — the adapter ignored `enable_caching` for
  list-form system content and required callers to hand-build annotated
  block maps. Wire-shape change for callers that hit this exact combination
  in `0.5.x`.
- **Claudio dependency** bumped to `~> 0.5.0`.

## [0.5.1] - 2026-04-29

### Added

- **Multimodal user input via list-shaped content blocks**: agents can now
  receive a list of content blocks (e.g. `[%{"type" => "text", ...}, %{"type"
  => "image", ...}]`) through `MyAgent.run/2`, `MyAgent.run/3`, and
  `MyAgent.run_with_tools/2`. The list flows through `prepare_input/1`,
  `AgentMemory`, and the Claudio adapter unchanged, where
  `add_single_message/3` already dispatches it through the existing
  multimodal path. Two minimal upstream changes make this work:
  `Normandy.Components.BaseIOSchema` now has a `for: List` impl whose
  `to_json/1` returns the list verbatim (mirrors the four-callback shape of
  the existing `BitString`/`Map` impls), and Normandy.DSL.Agent.prepare_input/1
  passes lists through unchanged. Strings continue to wrap into
  `%{chat_message: ...}` and maps continue to pass through (unchanged).
  Callers that need prompt-cache breakpoints inside multimodal user content
  can hand-build raw block maps with a `"cache_control"` key — the adapter's
  raw-list path preserves them verbatim. Typed-struct caching support on
  `Normandy.Components.ContentBlock.{Text,Image,Document}` is deferred to a
  future release.

## [0.5.0] - 2026-04-29

### Added

- **Per-agent `max_tool_concurrency` (bounded parallel tool execution)**:
  `BaseAgentConfig` gains a `max_tool_concurrency` field (default `1`). The
  tool loop in `BaseAgent` now wraps each per-call worker through
  `Task.async_stream(ordered: true, max_concurrency: config.max_tool_concurrency,
   timeout: :infinity, on_timeout: :kill_task)` in both the non-streaming and
  streaming branches. Default `1` preserves pre-0.5.0 sequential behaviour
  (modulo the worker-process semantics noted under *Changed* below). Values
  `> 1` opt the agent into parallel tool execution — each tool call runs in
  its own `Task` worker, ordered by the LLM's call sequence, with up to N
  running at once. OTel parent context is propagated softly (via
  `Code.ensure_loaded?(OpenTelemetry.Ctx)` — Normandy does not add OTel as a
  hard dep) so consumer-side telemetry handlers continue to nest tool spans
  under the parent `agent.run` span.
- **DSL macro `max_tool_concurrency/1`**: sets the compile-time default
  inside `Normandy.DSL.Agent.agent do ... end`. Runtime overrides on
  `MyAgent.new/1` (top-level keyword, or via `:override`) take precedence as
  for any other agent setting.
- **Input validation for `:max_tool_concurrency`**: non-integer values
  (`"4"`, `4.0`, etc.) now raise `ArgumentError` rather than silently
  coercing to a default — a config bug should surface, not hide. Integers
  `< 1` are clamped to `1` to match the runtime tool-loop floor. Validation
  runs at both layers: at compile time inside the DSL `__before_compile__`
  (so `MyAgent.config().max_tool_concurrency` doesn't lie about the value
  the agent will actually use), and at runtime inside `BaseAgent.init/1`
  for `new/1` and `:override` callers. The shared
  `BaseAgent.normalize_max_tool_concurrency/1` helper drives both paths.
- **`BaseAgent.unwrap_tool_task_result!/1`** (`@doc false`, public for
  testability): translates a `Task.async_stream` element into the underlying
  tool result. The linked `Task.async_stream/3` propagates worker raises to
  the caller via process-link before yielding, so `{:exit, {exception,
  stacktrace}}` is unreachable for raises in the current configuration; the
  helper still handles it (re-raising with the original stacktrace) along
  with `{:exit, reason}` — most importantly `{:exit, :timeout}` from
  `on_timeout: :kill_task` and any deliberate `exit/1` from tool wrapper
  code — so those fail loudly instead of hitting `FunctionClauseError`
  against a `{:ok, _}`-only pattern.

### Changed

- **Streaming callback process semantics (`stream_with_tools/3`)**: the
  callback now executes in the `Task.async_stream` worker process, not the
  caller — including at `max_tool_concurrency: 1`, because `Task.async_stream`
  always spawns one worker per closure. Callbacks that referenced `self()`
  inside (e.g. `fn :tool_result, r -> send(self(), {:tool_result, r}) end`)
  will now target the worker PID. To send messages back to the owner, capture
  the PID outside the callback first: `parent = self(); fn :tool_result, r ->
  send(parent, ...) end`. This is the canonical Elixir pattern for any
  callback that may run in a worker process.
- **Streaming `:tool_result` callback ordering at concurrency > 1**:
  `stream_with_tools/3` invokes `callback.(:tool_result, result)` from inside
  each worker as soon as that tool finishes, so at `max_tool_concurrency > 1`
  callers observe `:tool_result` events in **completion order**, not
  LLM-call order. The final list of tool results sent back to the LLM stays
  in LLM-call order (`Task.async_stream` is invoked with `ordered: true`).
  Callers that need call-order callback delivery should keep
  `max_tool_concurrency: 1` or buffer + reorder client-side.
- **Tool loop refactor (`BaseAgent`)**: extracted the per-tool-call body of
  `execute_tool_loop/2` and `execute_streaming_tool_loop/3` into the private
  helpers `execute_one_tool_call/2` and `execute_one_streaming_tool_call/2`.
  Pure refactor — behaviour, ordering, and process semantics are identical to
  the previous inline `Enum.map` closures. Sets up a follow-up change to swap
  `Enum.map` for an opt-in bounded parallel runner (per-agent
  `max_tool_concurrency`) without churning the closure body again.

### Security

- **Atom-table hardening (`BaseAgent`)**: replaced `String.to_atom/1` over
  LLM-supplied tool input keys with `normalize_tool_field_key/2`, which only
  returns atoms that already exist as fields on the tool struct. LLM tool
  input is influenced by attacker-controllable prompt content (chat
  messages, webhooks); the previous code registered every unknown key in
  the global atom table on the way to `struct/2` discarding it, and BEAM
  never garbage-collects atoms — sustained crafted input could exhaust the
  table and crash the VM. Unknown keys are now silently dropped, preserving
  the existing user-visible behaviour of `struct/2`.

### Fixed

- **Streaming tool input normalisation (`BaseAgent`)**:
  `execute_one_streaming_tool_call/2` now routes `tool_call["input"]` through
  `normalize_tool_input/1` instead of an ad-hoc `case` that only accepted
  `nil`, maps, and binaries. Streaming tool input is raw LLM JSON, so a
  list/number/boolean previously raised `CaseClauseError` and aborted the
  whole streaming tool loop; unexpected shapes now degrade to `%{}`. The
  redundant `parse_json_input/1` private helper (functionally identical to
  the binary clause of `normalize_tool_input/1`) is removed.

## [0.4.0] - 2026-04-25

### Added

- **Multimodal Content Blocks**: Image and document support for agent messages
  - `Normandy.Components.ContentBlock.{Text, Image, Document}` framework-neutral
    block types with per-module `to_claudio/1` emitting Anthropic wire shapes
  - `ClaudioAdapter.add_single_message/3` opportunistically dispatches to
    Claudio's named helpers for the three wrapped shapes (base64 image+text,
    URL image+text, document+text); other shapes (multi-block, reversed,
    image-alone, pre-shaped maps with `cache_control`) fall through to a
    raw-list `add_message/3`
  - `Normandy.Components.Message.content` widened from `:struct` to `:any` with
    extended `@type t` covering `String.t() | struct() | [struct()]`
  - Token accounting in `WindowManager`, `TokenCounter`, and `Summarizer` now
    handles list content (image blocks ~1600 tokens, documents ~3000) instead
    of silently zero-counting them

- **Guardrails**: First-class content-level constraint layer for agent I/O,
  composable across input and output stages
  - `Normandy.Guardrails` runner with short-circuit semantics
  - `Normandy.Guardrails.Guard` behaviour for custom guards
  - `Normandy.Guardrails.ViolationError` raised on input violations
  - Built-in guards: `MaxLength`, `ForbiddenSubstrings`, `RegexGuard`
    (`:deny`/`:require` modes), `RequiredFields`
  - `BaseAgent` integration via new `:input_guardrails` / `:output_guardrails`
    config keys (input violations halt, output violations log and continue,
    mirroring `ValidationMiddleware`)
  - DSL macro `guardrails(:input | :output, [specs])` in `Normandy.DSL.Agent`
  - Telemetry event `[:normandy, :agent, :guardrail, :violation]` with
    `:stage`, `:agent_name`, `:guards`, and `:violations` metadata
  - Works on both non-streaming (`run/2`) and streaming paths — see the
    streaming output guardrails entry below for streaming specifics

- **Streaming Output Guardrails**: Output guardrails now run on streaming paths
  - `:accumulate` mode (default) — guards run on the final assistant text
    after the stream ends; log-and-continue on violation, matching
    non-streaming `run/2` posture
  - `:incremental` mode (opt-in) — guards run every
    `:output_guardrails_chunk_size` bytes of accumulated text plus a tail
    pass when the stream ends with unchecked bytes; on violation halts
    mid-stream, strips any in-flight `tool_use` content block, and returns
    with `:guardrail_violations` populated
  - Three signal channels on both modes: `:guardrail_violation` stream
    callback event, `:guardrail_violations` field on the returned response,
    and the existing telemetry event (metadata gains `streaming: true` and
    `mode: :accumulate | :incremental`)
  - New DSL macros inside `agent do … end`: `streaming_mode/1`,
    `streaming_chunk_size/1`
  - New `BaseAgentConfig` fields: `:output_guardrails_streaming_mode`,
    `:output_guardrails_chunk_size`

### Fixed

- **Streaming Cold-Start**: `BaseAgent.stream_response/3` and
  `stream_with_tools/3` no longer fail with `"Client does not support streaming"`
  when invoked as the first call through the `Normandy.Agents.Model` protocol.
  With protocol consolidation enabled (default in `:dev`/`:prod`), the
  consolidated impl module was not auto-loaded, so the `function_exported?/3`
  capability probe returned false. Now wraps the probe with `Code.ensure_loaded/1`
  (#9).

### Changed

- **Claudio dependency** bumped to `~> 0.4.0`. Required for streaming SSE
  events to decode with string-keyed data maps (matches the raw Anthropic
  JSON convention); earlier `keys: :atoms` decoding silently dropped
  callback dispatches in Normandy's adapter.

## [0.3.0] - 2026-04-18

### Added

- **MCP and A2A Protocol Support**: New protocols for interoperability
  - `Normandy.MCP.ToolWrapper` for wrapping Model Context Protocol (MCP) tools
  - `Normandy.MCP.Registry` for managing MCP tool collections
  - `Normandy.A2A.Server` for agent-to-agent communication
  - Support for cross-agent tool execution and discovery

- **Structured Agent Lifecycle Logging & Telemetry**: Enhanced observability
  - `Logger` calls for agent, LLM, and tool lifecycle events
  - Telemetry events for:
    - `[:normandy, :agent, :run, :start | :stop | :exception]`
    - `[:normandy, :agent, :llm_call, :start | :stop | :exception]` (the LLM call span; an `[:normandy, :llm, :call, *]` event never existed. `[:normandy, :llm, :request, *]`, added in the Unreleased section, is a different event)
    - `[:normandy, :tool, :execute, :start | :stop | :exception]`
  - Automatic duration tracking for all operations
  - Metadata enrichment with agent names, models, and tool names
  - OpenTelemetry-friendly logging with span context correlation

- **Telemetry Metadata & Robustness**:
  - Agent names included in all telemetry metadata
  - Improved error handling in LLM adapter calls
  - Support for `Finch` connection pool in `ClaudioAdapter`

- **DSL Enhancements**:
  - Exposed `run/3` in DSL for direct streaming support
  - Improved agent definition ergonomics

#### Schema Enhancements
- **Schema-Based Tool Definition**: New `SchemaBaseTool` mixin for streamlined tool creation
  - `tool_schema` macro providing single source of truth for tool definitions
  - Automatic JSON schema generation and validation
  - ~60% reduction in boilerplate code compared to manual approach

- **Tool Registry Metadata Methods**: Enhanced introspection capabilities
  - `get_metadata/2`, `list_metadata/1`, `filter_by_required_params/2`, etc.
  - Find tools by constraints, parameter types, or required fields

- **Validation Middleware**: Automatic validation for agent inputs and outputs
  - Type-safe agent execution with path-based error messages
  - Fail-fast on invalid inputs, warn on invalid LLM outputs

### Changed

- **Calculator Tool Migration**: Migrated to schema-based approach with improved type safety
- **HTTP Client**: Added support for custom `Finch` pools in `ClaudioAdapter`
- **JSON Schema Type Format**: Schema types now use atoms (`:object`) instead of strings (`"object"`)
- **CI/CD**: Adjusted test coverage threshold to 60% and updated matrix testing

### Fixed

- **Streaming Stability**: Restored tool loop, message conversion, and event shape in streaming responses
- **Tool Loop**: Fixed unwrap of double-nested JSON in `chat_message` after tool loop completion
- **JSON Deserialization**: Return structured content blocks from tool `to_json` instead of raw strings
- **Dependency Issues**: Added default `Poison` adapter to prevent encoding errors in consuming apps
- **Logging**: Preserved DSL-defined agent names in lifecycle logs
- **Dialyzer**: Resolved various type errors and added ignore patterns for clean analysis
- **CI**: Fixed compilation warnings and intermittent test failures

### Test Coverage
- Total tests: 900+ (doctests + property tests + unit tests)
- 0 failures, 100% passing rate

## [0.2.0] - 2025-10-28

### Added

#### CI/CD Infrastructure
- **GitHub Actions Workflow**: Comprehensive CI pipeline for automated testing
  - Matrix testing across Elixir 1.15, 1.16, 1.17 and OTP 26, 27
  - Separate jobs for unit tests, integration tests, Dialyzer, and dependency audits
  - Smart caching for dependencies and PLT files
  - Conditional integration test execution with API key support
  - Documentation in `.github/workflows/README.md`

#### Examples and Documentation
- **Comprehensive Examples**: Three runnable examples demonstrating key features
  - Customer support agent with custom tools and conversational memory
  - Multi-agent research workflow with parallel execution
  - Structured data extraction with validated output schemas
  - Complete examples README with setup instructions and key concepts

- **Customer Support Example Application**: Production-ready multi-agent system
  - Four specialized agents (Greeter, Technical, Billing, Order Support)
  - Custom tools for knowledge base, order lookup, refunds, and ticket creation
  - Interactive CLI interface with session management
  - Data stores for orders, tickets, and knowledge base
  - Full application architecture documentation

#### Context Management Improvements
- **TokenCounter Test Coverage**: Comprehensive unit tests for token counting
  - 15 tests covering all TokenCounter functionality
  - Mock-based testing for unit tests
  - Integration tests for real API calls
  - Error handling and edge case coverage

- **Date/Time Context Provider**: Dynamic timestamp injection for prompts
  - `Normandy.Components.DateTimeProvider` for temporal context
  - Configurable timezone support
  - Test coverage for provider functionality

#### Development Tools
- **JSON Deserializer**: Improved JSON parsing with error handling
  - `Normandy.LLM.JsonDeserializer` for robust JSON parsing
  - Fallback mechanisms for malformed JSON
  - Integration tests for retry scenarios

### Fixed
- **TokenCounter Implementation**: Critical bug fixes for production use
  - Fixed Claudio client initialization (map format instead of keyword list)
  - Fixed agent structure access patterns (direct field access)
  - Fixed system prompt extraction (pattern matching instead of get_in/2)
  - Added comprehensive error handling for malformed agents

- **Access Protocol Issues**: Resolved struct field access errors
  - Replaced get_in/2 with pattern matching for BaseAgentConfig
  - Improved error messages for malformed agent structures

### Documentation
- Enhanced ExDoc configuration with organized module groups
- Examples directory with comprehensive usage documentation
- CI/CD workflow documentation with local testing commands
- Customer support application architecture guide

### Test Coverage
- 443 unit tests (29 doctests + 21 properties + 393 tests)
- 62 integration tests (56 API + 6 comprehensive DSL tests)
- 15 new TokenCounter unit tests
- Total: 505+ tests, all passing

## [0.1.0] - 2025-10-26

### Added

#### Declarative DSLs (Phase 8.6)
- **Agent DSL**: Define agents with declarative syntax
  - `Normandy.DSL.Agent` - `agent do ...end` blocks for agent configuration
  - Macro-based configuration for model, temperature, prompts, tools
  - Automatic initialization with `new/1` and agent execution
  - Background, steps, and output_instructions directives

- **Workflow DSL**: Compose multi-agent workflows
  - `Normandy.DSL.Workflow` - `workflow do ... end` blocks
  - Sequential execution: `step :name do ... end`
  - Parallel execution: `parallel :name do ... end`
  - Race patterns: `race :name do ... end`
  - Data flow: `input(from: :step_name)` or static values
  - Result transformation: `transform fn ... end`
  - Conditional execution: `when_result do ... end`
  - Automatic step orchestration and error handling

- **Pattern Matching Helpers**: Utilities for result tuples
  - `Normandy.Coordination.Pattern` - Ergonomic {:ok, value} | {:error, reason} handling
  - Type checking: `ok?/1`, `error?/1`
  - Value extraction: `ok!/2`, `error!/2`, `unwrap!/1`
  - Filtering lists: `filter_ok/1`, `filter_errors/1`
  - Transformations: `map_ok/2`, `map_error/2`
  - Composition: `then/2`, `find_ok/1`, `collect_ok/1`, `all_ok/1`, `all_ok_map/1`
  - Wrapping utilities: `wrap/1`, `try_wrap/1`

- **Reactive Coordination Patterns**
  - `Normandy.Coordination.Reactive` - Concurrent agent execution primitives
  - `race/3` - Return first successful result from multiple agents
  - `all/3` - Wait for all agents with optional fail-fast mode
  - `some/4` - Quorum pattern (wait for N successful results)
  - `map/3` - Transform agent results
  - `when_result/3` - Conditional execution based on results

- **Agent Pool Management**
  - `Normandy.Coordination.AgentPool` - Connection pool pattern for agents
  - Transaction-based API with automatic checkout/checkin
  - Manual checkout/checkin for advanced use cases
  - Configurable pool size with overflow support
  - LIFO/FIFO checkout strategies
  - Automatic agent replacement on failure
  - Pool statistics and monitoring
  - Non-blocking checkout with timeout support

#### Core Foundation (Phases 1-7)
- **Schema System**: Macro-based DSL for defining agent I/O schemas with JSON Schema generation
  - `Normandy.Schema` module with `schema` and `io_schema` macros
  - Type system with casting, dumping, and loading via `Normandy.Type`
  - Changeset-like validation with `Normandy.Validate`
  - Support for parameterized and custom types

- **Agent System**: Core agent implementation with LLM integration
  - `Normandy.Agents.BaseAgent` with init, run, and get_response methods
  - `Normandy.Agents.BaseAgentConfig` for agent state management
  - Context provider system for dynamic prompt injection
  - Tool/function calling support via `Normandy.Agents.ToolCallResponse`

- **Memory Management**: Conversational history tracking
  - `Normandy.Components.AgentMemory` with turn-based organization
  - Message serialization and deserialization
  - Configurable message history limits

- **Prompt System**: Structured prompt generation
  - `Normandy.Components.SystemPromptGenerator` with section-based prompts
  - `Normandy.Components.PromptSpecification` for prompt structure
  - `Normandy.Components.ContextProvider` protocol for dynamic context

- **Streaming Responses**: Real-time LLM response streaming
  - Streaming support in `Normandy.Agents.BaseAgent`
  - Callback-based streaming with arity-2 callback support

- **Resilience Patterns**: Fault tolerance and reliability
  - `Normandy.Resilience.Retry` with exponential backoff
  - `Normandy.Resilience.CircuitBreaker` for preventing cascade failures
  - Integration with BaseAgent for automatic retry on failures

- **Context Window Management**: Intelligent conversation management
  - `Normandy.Context.WindowManager` for automatic context management
  - `Normandy.Context.TokenCounter` for accurate token counting
  - `Normandy.Context.Summarizer` for conversation summarization
  - Support for Claude's prompt caching (up to 90% cost reduction)

#### Multi-Agent Coordination (Phase 8)
- **Agent Communication**: Message-based agent-to-agent communication
  - `Normandy.Coordination.AgentMessage` for structured messaging
  - `Normandy.Coordination.SharedContext` for stateless context sharing
  - `Normandy.Coordination.StatefulContext` (GenServer + ETS) for stateful sharing

- **Orchestration Patterns**: Multiple coordination strategies
  - `Normandy.Coordination.SequentialOrchestrator` for pipeline execution
  - `Normandy.Coordination.ParallelOrchestrator` for concurrent execution
  - `Normandy.Coordination.HierarchicalCoordinator` for manager-worker patterns
  - Simple and advanced APIs for flexible usage

- **Agent Processes**: OTP-based agent supervision
  - `Normandy.Coordination.AgentProcess` (GenServer wrapper)
  - `Normandy.Coordination.AgentSupervisor` (DynamicSupervisor)
  - Fault tolerance with Elixir/OTP patterns

#### Batch Processing
- **Concurrent Processing**: Efficient batch agent execution
  - `Normandy.Batch.Processor` for concurrent batch processing
  - Configurable concurrency limits
  - Result aggregation and error handling

#### Integration & Testing (Phase 8.5)
- **Integration Tests**: Comprehensive real-world testing
  - 56 integration tests with real Anthropic API calls
  - Test helpers: `IntegrationHelper` and `NormandyIntegrationHelper`
  - Tag-based test exclusion (`@moduletag :api`, `@moduletag :integration`)
  - Coverage for multi-agent workflows, resilience, caching, and batch processing

- **LLM Client Integration**: Claudio HTTP client migration
  - Updated to Claudio v0.1.1 from hex.pm
  - Migrated from Tesla to Req HTTP client
  - Streaming error handling for `Req.Response.Async`

### Fixed
- Orchestrator APIs: Fixed `extract_result` to return full response maps instead of just chat_message strings
- Function clause matching: Improved pattern matching for simple vs advanced orchestrator APIs
- Streaming callbacks: Fixed arity-2 callback support for streaming responses

### Documentation
- Comprehensive README with usage examples
- Project roadmap (ROADMAP.md) tracking implementation phases
- MIT License
- Hex.pm package metadata and documentation configuration

### Dependencies
- `elixir_uuid` ~> 1.2 - UUID generation for conversation turns
- `poison` ~> 6.0 - JSON encoding/decoding
- `claudio` ~> 0.1.1 - Anthropic Claude API client
- `dialyxir` ~> 1.4 (dev/test) - Static analysis
- `stream_data` ~> 1.1 (dev/test) - Property-based testing
- `ex_doc` ~> 0.34 (dev) - Documentation generation

### Test Coverage
- 443 unit tests (29 doctests + 21 properties + 393 tests)
- 62 integration tests (56 API + 6 comprehensive DSL tests, excluded by default)
- Total: 505 tests, all passing
- New test files:
  - `test/coordination/pattern_test.exs` (13 tests)
  - `test/coordination/reactive_test.exs` (33 tests)
  - `test/coordination/agent_pool_test.exs` (30 tests)
  - `test/dsl/agent_test.exs` (8 tests)
  - `test/dsl/workflow_test.exs` (14 tests)
  - `test/dsl/workflow_transform_integration_test.exs` (4 tests)
  - `test/normandy_integration/dsl_comprehensive_test.exs` (6 comprehensive integration tests)

[1.0.0]: https://github.com/thetonymaster/normandy/releases/tag/v1.0.0
[0.9.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.9.0
[0.8.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.8.0
[0.7.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.7.0
[0.6.3]: https://github.com/thetonymaster/normandy/releases/tag/v0.6.3
[0.6.2]: https://github.com/thetonymaster/normandy/releases/tag/v0.6.2
[0.6.1]: https://github.com/thetonymaster/normandy/releases/tag/v0.6.1
[0.6.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.6.0
[0.5.1]: https://github.com/thetonymaster/normandy/releases/tag/v0.5.1
[0.5.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.5.0
[0.4.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.4.0
[0.3.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.3.0
[0.2.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.2.0
[0.1.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.1.0
