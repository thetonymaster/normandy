# Normandy 2.0 developer-ergonomics audit (2026-10-04)

Branch `feat/claudio-0.7-migration` @ `f7991a9`. Read-only: grep/read plus two throwaway Python scripts
in the scratchpad (`doccov.py`, which finds public `def`s with no `@doc`, and `refs.py`, which checks
that every documented `Module.fun(` exists). No `mix`, no live API.

Scope: the experience of an Elixir developer adopting 2.0. Findings already in
`investigations/codebase-audit-2026-09` are not repeated. Where one is still present and matters here,
it is cited by ID.

Marks: **VERIFIED** means I read the code path, or the script output, that proves it.
**PLAUSIBLE** means the code path is verified but the consequence depends on something I did not run
(the live API, the logger).
**BREAKING** means fixing it changes a public contract, so it happens in 2.0 or waits for 3.0.

Counts: 3 BLOCKER, 10 HIGH, 17 MEDIUM, 6 LOW.

---

## BLOCKER

### DX-1. README quickstart sends no `max_tokens`, which the Messages API requires
- Severity: BLOCKER (the first thing a new user runs) · not breaking
- Where: README.md:61-71; lib/normandy/llm/claudio_adapter.ex:27-32 (moduledoc example);
  lib/normandy/agents/base_agent.ex:154; lib/normandy/llm/claudio_adapter.ex:573
- Evidence:
  - README: `BaseAgent.init(%{client: client, model: "claude-sonnet-4-6"})`, with no `max_tokens`.
  - `init/1`: `max_tokens: Map.get(config, :max_tokens, nil)`.
  - Adapter: `defp add_max_tokens(request, nil), do: request`.
  - Claudio `Request` (../Claudio/lib/claudio/messages/request.ex:1936, :1993):
    `maybe_put("max_tokens", request.max_tokens)` with `defp maybe_put(map, _key, nil), do: map`. The
    key is left out of the body.
  - Every live test and e2e script sets it (`integration_helper.ex:134` defaults it to 1024; e2e
    01–07 all pass `max_tokens:`), so nothing exercises the README path.
  - The DSL defaults to 4096 (`dsl/agent.ex:469`), so the two entry points disagree.
- Consequence: the Anthropic Messages API requires `max_tokens`, so the quickstart's first `run/2`
  should fail with a 400 `invalid_request` `Normandy.LLMError`.
- Fix: default `max_tokens` in `BaseAgent.init/1` to the DSL's 4096 (one default for both entry
  points), or raise at `init/1` when a `ClaudioAdapter` client has no `max_tokens`. Add a test that runs
  the README snippet against `StubClient` and checks that the request carries `max_tokens`.
- Mark: PLAUSIBLE (code path VERIFIED; the API requirement is known but not called here)

### DX-2. `Model.completitions/6` is misspelled, never called, and every client must implement it
- Severity: BLOCKER (2.0 is the last chance to drop it cheaply) · **BREAKING**
- Where: lib/normandy/agents/model.ex:9-17; impls at claudio_adapter.ex:167,
  openai_compatible_adapter.ex:183, plus 8 test-support clients
- Evidence:
  - `grep -rn "completitions" lib`: the only hits are the protocol and its two `def`s. Nothing calls
    it.
  - The adapter's own comment: `# Claudio uses Messages API, not Completions / Return empty
    response_model`.
  - It has no `@doc`. Its `@spec` types `messages` as `binary()` and `temperature` as `float()`,
    which is wrong after the 2.0 temperature change.
  - Leaving it out of a `defimpl` gives a "required by protocol" warning. Under
    `--warnings-as-errors` that fails the build.
- Fix: delete it from the protocol and both adapters. Add a MIGRATING-2.0 line: "remove your
  `completitions/6` implementation".
- Mark: VERIFIED

### DX-3. The package cannot publish: Claudio is a path dependency and the version is 1.3.0
- Severity: BLOCKER (release mechanics; known, listed for completeness)
- Where: mix.exs:4 (`@version "1.3.0"`), mix.exs:166 (`{:claudio, path: "../Claudio"}`)
- Evidence: Hex rejects path dependencies, and README tells users to add `{:normandy, "~> 2.0"}`.
  `source_ref: "v#{@version}"` points HexDocs at a `v1.3.0` tag.
- Fix: publish Claudio 0.7.0 and switch to `~> 0.7.0`. Bump the version (or confirm cog bumps it), and
  move `CHANGELOG [Unreleased]` to `2.0.0`.
- Mark: VERIFIED

---

## HIGH

### DX-4. The `Model` protocol is positional, and streaming sits outside it
- Severity: HIGH · **BREAKING** (decide now or live with it until 3.0)
- Where: model.ex:62-68; base_agent.ex:1509-1560; claudio_adapter.ex:355-391
- Evidence:
  - `converse(config, model, temperature, max_tokens, messages, response_model, opts \\ [])` takes 7
    positional arguments. Telemetry trackers come in through `opts`.
  - Streaming is found by duck typing: `if impl && function_exported?(impl, :stream_converse, 7)`.
    It is not in the protocol, so a custom-client author cannot find it, and Dialyzer cannot check it.
  - The adapter's doc example calls `Model.stream_converse(client, ...)`, a function that does not
    exist. `refs.py` flagged it as the only dangling documented call in lib.
  - The return contract has 4 shapes: bare struct, `{r, usage}`, `{r, usage, meta}` and
    `{:error, LLMError}`.
  - The response model is passed in as an empty struct that the client fills. The contract does not
    say so; the test clients "return the response model unchanged".
- Fix (2.0): `converse(client, %Normandy.LLM.Request{model, messages, response_model, temperature,
  max_tokens, tools, ...}, opts) :: {:ok, %Normandy.LLM.Response{content, usage, meta}} | {:error,
  LLMError.t()}`. Add an optional `stream/3` callback, declared in the protocol or in a companion
  behaviour. `ConverseResult.normalize/1` disappears. If it stays as is, at least fix the doc example
  and document `stream_converse/7` in the protocol moduledoc.
- Mark: VERIFIED

### DX-5. Three error models, and an ordinary rate limit under `Turn.Server` arrives as a crash
- Severity: HIGH · **BREAKING**
- Where: base_agent.ex:432 (`run/2` raises); agents/turn/server.ex:128-132, :633-645, :1220-1258;
  agent_process.ex:116; dsl/workflow.ex:539-545; dsl/agent.ex `new/1`
- Evidence:
  - `BaseAgent.run/2` returns a bare `{config, response}` and raises `LLMError`,
    `ValidationError`, `ViolationError` or `HookHaltError`. There is no tuple-returning variant.
  - `Turn.Server.run/2`, `AgentProcess.run/3` and `Workflow.execute/1` return
    `{:ok, _} | {:error, _}`.
  - `DSL new/1` returns `{:ok, agent}` and never `{:error, _}` (prior AGENTS-15).
  - Under `Turn.Server` the LLM handler raises inside a plain `spawn` worker, and the `:DOWN` becomes
    `{:llm_error, {:task_down, reason}}`. A 429 therefore reaches the caller as
    `{:error, {:task_down, {%Normandy.LLMError{type: :rate_limit}, stacktrace}}}`.
  - The moduledoc lists that as "the worker task died". MIGRATING §5 shows the same wrapping for
    `ModelCatalogError`.
  - A crashed `spawn` also logs an error report, so every rate limit should log one (PLAUSIBLE).
- Fix:
  - Make `BaseAgent.run/2` return `{:ok, config, response} | {:error, exception}` and add `run!/2`
    with today's behaviour, following Elixir's `File.read`/`File.read!` pattern.
  - In `Turn.Server`, catch the handler's exception in the worker and reply
    `{:error, %LLMError{}}` (or `{:error, {:llm_error, e}}`). Keep `:task_down` for real crashes.
  - Make `DSL new/1` return the agent, or rename it `new!/1`.
- Mark: VERIFIED (reply shape); PLAUSIBLE (crash log)

### DX-6. `BaseAgent.init/1` silently drops unknown keys, takes only maps, and gives a `KeyError` for missing ones
- Severity: HIGH · **BREAKING** (becomes stricter)
- Where: base_agent.ex:46-176
- Evidence:
  - Every key is read with `Map.get(config, ...)`, and `config.client` / `config.model` use dot
    access.
  - Keys a DSL user would naturally try are dropped with no error: `system_prompt:` (the DSL's name),
    `tools:` (the DSL's `tool`), `temprature:`, `max_messages:` (which the DSL accepts).
  - `init/1` also reads `:session_id`, which the `config_input` type does not list.
  - A keyword list gives `BadMapError`. A missing `:model` gives
    `** (KeyError) key :model not found in: %{...}`.
  - The DSL's `new/1` (`validate_overrides!`), the ClaudioAdapter options and `Retry` all reject
    unknown keys with an "unknown option X; supported: ..." message, so the plain API is the only
    strict-free entry point.
- Fix: check `Map.keys(config) -- allowed`. Raise `ArgumentError`
  `"BaseAgent.init/1: unknown option :system_prompt; supported: ..."`, and add a hint for
  `system_prompt`/`tools` that points to `prompt_specification`/`tool_registry`. Also accept a keyword
  list. Raise `"BaseAgent.init/1 requires :model (a string), got none"` instead of the `KeyError`.
- Mark: VERIFIED

### DX-7. About 20 public entry points ignore unknown or misspelled options
- Severity: HIGH · **BREAKING** (becomes stricter)
- Where: these files use `Keyword.get(opts, …)` with no `Keyword.validate!` (count of `get`s in
  brackets):
  - agents/turn/server.ex (8), turn/session.ex (6)
  - coordination/agent_process.ex (13), agent_pool.ex (7), parallel_orchestrator.ex (8),
    sequential_orchestrator.ex (5), hierarchical_coordinator.ex (7), reactive.ex (8),
    agent_supervisor.ex (5)
  - batch/processor.ex (9), context/summarizer.ex (6), resilience/circuit_breaker.ex:245-248 (4),
    dsl/workflow.ex:417-420, cluster.ex (4)
- Evidence: only 5 modules validate options: `tools/memory.ex`, `validate.ex`, `retry.ex`,
  `agent_memory.ex`, `dsl/agent.ex`. Some examples of what slips through:
  - `Turn.Server.start_link(approval_timout_ms: 1000)` is ignored, so the default of 300 s applies.
    Only `:on_approval_timeout` is checked (server.ex:203-204).
  - A missing `:store` crashes `init/1` with `KeyError` instead of being caught in `start_link`.
  - `CircuitBreaker` with `failure_treshold:` keeps the default; prior OTP-15 noted this and it is
    still present.
  - `Retry` rejects the same kind of typo, so `retry_options` and `circuit_breaker_options` behave
    differently.
- Fix: `Keyword.validate!/2` (or NimbleOptions, which also documents the options) at each public
  entry point, with the same "unknown option :x for Mod.fun/n; supported: ..." wording that
  `retry.ex:149-151` uses.
- Mark: VERIFIED

### DX-8. Users get no test double and no guidance on testing their own agents offline
- Severity: HIGH · not breaking
- Where: lib/ has no fake client (no `Fake|Mock|Stub|Testing` module). test/support/stub_client.ex and
  scripted_tool_client.ex are good but do not ship. README, the guides and MIGRATING never mention
  testing.
- Evidence:
  - A user must write a `defimpl Normandy.Agents.Model`. That includes the dead `completitions/6`
    (DX-2) and the undocumented convention that `converse` returns a filled copy of the passed-in
    `response_model` (DX-4).
  - Custom `SessionStore` and `MemoryStore` authors get no contract suite:
    `test/support/session_store_contract.ex` and `memory_store_contract.ex` do not ship.
  - The protocol consolidation note (`consolidate_protocols: false` in test) is only in Normandy's own
    mix.exs.
- Fix: ship `Normandy.Testing.StubClient` (scripted replies, captured requests, optional
  `stream_converse`) and `Normandy.Testing.ScriptedToolClient`. Ship
  `Normandy.Testing.SessionStoreContract` and `MemoryStoreContract` as `ExUnit.CaseTemplate`s.
  Add a "Testing your agents" guide, linked from README.
- Mark: VERIFIED

### DX-9. `.formatter.exs` exports no `locals_without_parens`, so `mix format` adds parens to user DSL code
- Severity: HIGH (affects every DSL user) · not breaking
- Where: .formatter.exs:1-4 (only `inputs:`)
- Evidence: the docs' own DSL samples have already been rewritten by the formatter.
  - docs/guides/hooks.md:35: `model("claude-sonnet-4-5")` and `hooks([...])`.
  - README:80-81: `field(:name, :string, ...)`.
  - The DSL moduledoc writes `model "claude-opus-5-5"` without parens.
  - Ecto, Phoenix and Ash all export these, so users expect it.
- Fix: add `export: [locals_without_parens: [field: 2, field: 3, schema: 1, io_schema: 2, tool_schema:
  3, agent: 1, name: 1, description: 1, model: 1, temperature: 1, max_tokens: 1, max_tool_concurrency:
  1, system_prompt: 1, background: 1, steps: 1, output_instructions: 1, tool: 1, memory: 0..1,
  max_messages: 1, guardrails: 2..3, streaming_mode: 1, streaming_chunk_size: 1, hooks: 1, workflow: 1,
  step: 2, parallel: 2, race: 2, input: 1, transform: 1, when_result: 1]]`. Use the same list under
  `locals_without_parens` for Normandy's own code. Document
  `import_deps: [:normandy]`.
- Mark: VERIFIED

### DX-10. The core API is undocumented, and the root module is a `mix new` scaffold
- Severity: HIGH · not breaking (except `hello/0` removal, which is trivial)
- Where:
  - lib/normandy.ex:1-18
  - base_agent.ex:76 `init`, :178 `reset_memory`, :224 `get_response`, :433 `run/2`, :2051/2068/2082
    context-provider functions
  - turn/session.ex:55,60; turn/supervisor.ex:27,43; turn/server.ex:203 `start_link`
  - components/agent_memory.ex:29-140 (9 functions)
- Evidence:
  - lib/normandy.ex: `@moduledoc "Documentation for `Normandy`."` and
    `def hello, do: :world`, which test/normandy_test.exs doctests. This is the first module in the
    HexDocs sidebar.
  - `doccov.py` lists `init/1`, `run/2`, `reset_memory/1` and `get_response/2` as public functions
    with no `@doc`. These are the API README shows. `run/3` has a doc but no `@spec`.
  - `Turn.Session.run/2` and `approve/2`, the Tier-1/2 entry points, have no `@doc`.
- Fix: write `@doc`s for these, covering options, the return shape and what each raises. Replace
  `Normandy` with an overview moduledoc that has a decision table: `BaseAgent` vs `DSL.Agent` vs
  `AgentProcess` vs `Turn.Session`. Delete `hello/0` and its doctest.
- Mark: VERIFIED

### DX-11. Pairs of identical entry points, with contradictory docs and specs
- Severity: HIGH · **BREAKING** (removing the duplicates)
- Where: base_agent.ex:432-458 vs :530-537; :1264-1270 vs :1322-1330; :468-506; DSL
  `run_with_tools/2` (dsl/agent.ex:580-589)
- Evidence:
  - `run/2` already routes to the tool loop when tools are registered. `run_with_tools/2` runs the
    same `run_turn/2`.
  - `stream_response/3` and `stream_with_tools/3` have identical bodies: both call
    `run_stream_turn(config, user_input, callback)`. Their docs disagree. `stream_response` says
    "a stream is retried only until its first event reaches the callback"; `stream_with_tools` says
    "Streams are not retried."
  - Their specs disagree too: `{BaseAgentConfig.t(), map()}` vs `{BaseAgentConfig.t(), struct()}`.
  - `run/3` with `stream: true, on_chunk:` is a third way to stream.
- Fix: keep `run/2,3` (with `stream:` as an option) and one `stream/3`. Delete the others and fix the
  surviving doc. MIGRATING table: old name → new name.
- Mark: VERIFIED

### DX-12. A typo in the default input key sends a `nil` user message, with no error
- Severity: HIGH (the quickstart path) · not breaking
- Where: agents/validation_middleware.ex:80-83, :71-74
- Evidence:
  ```elixir
  # Skip validation for base schemas (backward compatibility)
  schema_module == Normandy.Agents.BaseAgentInputSchema ->
    {:ok, struct(schema_module, input_map)}
  ```
  `struct/2` drops unknown keys, so `run(agent, %{chat_mesage: "hi"})` builds
  `%BaseAgentInputSchema{chat_message: nil}` and sends that. A non-map input (a string, say) skips
  validation entirely through the catch-all at :72.
- Fix: validate the base schema like any other, with `chat_message` required (or `struct!/2`, which
  raises "unknown key :chat_mesage"). Accept a binary as `%{chat_message: s}` here, as the DSL's
  `prepare_input/1` does, so README can show `run(agent, "Explain ...")`.
- Mark: VERIFIED (code); not executed

### DX-13. HexDocs grouping omits most of the 2.0 surface, names a module that does not exist, and exposes internals
- Severity: HIGH (first impression of 2.0 on HexDocs) · not breaking
- Where: mix.exs:58-140
- Evidence:
  - `groups_for_modules` lists `Normandy.Agents.IOModel`, which no file defines; io_model.ex defines
    `BaseAgentInputSchema` and `BaseAgentOutputSchema`.
  - Not grouped, so they fall into an untitled bucket: `Turn`, `Turn.Server`, `Turn.Session`,
    `Turn.Supervisor`, `ResumeReaper`, `ConfigTemplate`, every `Behaviours.*` (Hooks, MemoryStore,
    SessionStore, SessionRegistry, Compactor, ModelCatalog, PolicyEngine, BudgetTracker,
    CredentialProvider, AgentTemplate, Config), `Tools.Memory`, `Tools.Context`,
    `Tools.ContextualTool`, `Tools.SchemaBaseTool`, `LLM.OpenAICompatibleAdapter`, `LLMError`, the
    exceptions, `Telemetry`, `Cluster`.
  - Internals without `@moduledoc false`, so they appear as public API: `Hooks.Runner`,
    `Turn.Driver`, `Turn.Inline`, `Telemetry.{Metadata, OtelCtx, Provider, KilledRun, WorkflowSpan,
    Request}`, `LLM.Json.*`, `Schema.Validator`, `ValidationMiddleware`.
  - The guides (hooks, agent-memory, distributed) are not grouped either: `groups_for_extras` is
    commented out.
- Fix: add groups for Durable sessions, Behaviours, Hooks, Memory, Errors and Telemetry. Decide for
  each internal whether it is public or gets `@moduledoc false`. Enable `groups_for_extras`. Fix or
  remove the `IOModel` entry.
- Mark: VERIFIED

---

## MEDIUM

### DX-14. `Turn.Session.run(opts, input)` puts the options first and needs 7 keys on every call
- **BREAKING** · turn/session.ex:54-60; docs/guides/agent-memory.md:65-76
- Every other `run` takes `(target, input)`. Each call repeats
  `session_id/registry/supervisor/store/template_provider/template_id/config`.
- Fix: `Session.new(opts) :: %Session{}` (validated once), then `Session.run(session, input)` and
  `Session.approve(session, decisions)`.
- VERIFIED

### DX-15. `ParallelOrchestrator.execute/2` overloads its second argument and can drop the input
- **BREAKING** · coordination/parallel_orchestrator.ex:57-118
- `execute(agents, input_or_opts)` is spec mode when given a keyword list and simple mode when given a
  map or binary, and each mode returns a different shape.
- A struct input (`%BaseAgentInputSchema{}`) falls to `true -> execute_with_specs(agents, [])`, so the
  input is dropped. `SequentialOrchestrator.execute(agents, input, opts)` takes 3 arguments.
- Fix: `execute(agents, input, opts \\ [])` everywhere, with one return shape.
- VERIFIED (code); not executed

### DX-16. Not-found and return conventions differ from function to function
- **BREAKING**
- Not found:
  - `get_tool` → `:error` (base_agent.ex:2130)
  - `get_context_provider` → raises `NonExistentContextProvider` (:2060)
  - `AgentMemory.get_entry` → `nil`
  - `AgentMemory.fork` → `{:error, :no_such_entry}`
  - `AgentMemory.delete_turn` → raises `NonExistentTurn`
- Returns:
  - `register_tool` → config; `register_mcp_tools` → `{:ok, config}`
  - `process_batch` always returns `{:ok, _}`, and the inner shape switches between a list and a
    stats map on `:ordered` (base_agent.ex:2236-2256)
- Keys: context providers use atoms, tools use strings.
- Fix: one rule. Use `fetch_*` → `{:ok, v} | :error` and `*!` → raise. Drop `{:ok, _}` wrappers that
  can never be `{:error, _}`. Make `process_batch` return one shape.
- VERIFIED

### DX-17. Exception names are inconsistent
- **BREAKING** · exceptions.ex:15-36
- `Normandy.NonExistentTurn` and `Normandy.NonExistentContextProvider` lack the `Error` suffix; the
  Credo check is disabled inline to allow it. They have no `@moduledoc`.
- The other exceptions sit in different namespaces: `Normandy.{LLMError, ModelCatalogError,
  HookHaltError, CastError, InvalidChangesetError}`, `Normandy.Schema.ValidationError`,
  `Normandy.Guardrails.ViolationError`.
- Fix: `TurnNotFoundError` and `ContextProviderNotFoundError`. Give each a moduledoc and an "Errors"
  docs group.
- VERIFIED

### DX-18. `BaseAgentConfig` is a flat bag of 28 fields with overloaded names
- **BREAKING** · base_agent_config.ex:14-74; base_agent.ex:46-72
- Five `output_guardrails_*` keys. Resilience is switched on two different ways: `retry_options`
  (`nil` = off) vs `enable_circuit_breaker` + `circuit_breaker_options`.
- `max_tokens` means the response cap on the config but the context window on the compactor and
  `WindowManager` (MIGRATING §5/§6: `compactor: {WindowManager, [max_tokens: 200_000]}`).
- The `memory: map()` spec should be `AgentMemory.t()`.
- Fix: `retry: keyword | nil`, `circuit_breaker: keyword | nil`,
  `guardrails: [input:, output:, streaming_mode:, chunk_size:, on_violation:]`. Rename the compactor
  option to `:context_window`.
- VERIFIED

### DX-19. `Behaviours.Config.session_store` and `session_registry` are never read, yet the guide says to set them
- **BREAKING** to remove (the template refs persist them)
- Where: behaviours/config.ex:15-19, :45-57; docs/guides/distributed_sessions.md:199
- The moduledoc says session_store is "wired here but not yet consumed by the turn loop (Phase 4
  reads it)". `grep` finds no consumer outside `config_template.ex`. `Turn.Server` reads
  `opts[:store]`, yet the guide's Redis section tells users to set
  `%Config{session_store: ..., session_registry: ...}`.
- Related: 19 moduledoc lines reference internal "Phase N" plan history (policy_engine.ex:13,
  session_store.ex:8, credential_provider.ex:5, ...), which means nothing to users.
- Fix: remove both slots, keeping the rebuild tolerant of old templates. Fix the guide. Strip the
  Phase jargon.
- VERIFIED

### DX-20. Postgres store setup: wrong config shape in the moduledoc, and three migrations
- Where: session_store/postgres.ex:11; docs/guides/distributed_sessions.md:28-35, :45
- The moduledoc says `{Normandy.Behaviours.SessionStore.Postgres, repo: MyApp.Repo}`, but the handle
  is the Repo module itself (`repo.transaction(...)`). The guide correctly uses
  `{..., MyApp.Repo}`.
- A fresh 2.0 install must call `Migration.up`, `MigrationAddTemplate.up` and
  `MigrationAddResumePolicy.up`, plus `MemoryStore.Postgres.Migration.up` for memory.
- `new/0` reads `Application.fetch_env!(:normandy, :ecto_repos)`, a host-app key.
- Fix: correct the moduledoc. Offer a versioned `Normandy.Migrations.up(version: n)` the way Oban
  does. Make `new/0` test-only or document it.
- VERIFIED

### DX-21. `BaseIOSchema` has Python leftovers, and there are four ways to get a schema
- **BREAKING** · components/base_io_schema.ex:11-25; schema.ex:400-428
- `__str__/1` and `__rich__/1` (`__rich__` is from Python's Rich library) are implemented by every
  `io_schema`, but nothing in lib calls them. Double-underscore names are conventionally reserved for
  compiler and metaprogramming hooks in Elixir.
- To get a schema there are `get_schema/1`, `get_json_schema/0`, `__schema__(:specification)` and
  `__specification__/0`. The `get_` prefix goes against Elixir naming conventions.
- Fix: protocol = `to_json/1` + `json_schema/1`; generated `json_schema/0`; drop the dunders.
- VERIFIED

### DX-22. Three tool contracts, and the tool registry is named `Registry`
- **BREAKING**
- `BaseTool.run/1` (protocol), `SchemaBaseTool`'s user-written `execute/1`, and `ContextualTool.run/2`.
  The last one requires a stub `BaseTool.run/1` that returns an error (agent-memory.md:278-280).
- `Normandy.Tools.Registry` shadows Elixir's `Registry` when aliased, and `BaseAgent` itself does
  `alias Normandy.Tools.Registry`. `MCP.Registry`, `A2A.Registry` and `SessionRegistry` add to the
  confusion.
- Fix: one `run(tool, %Context{})`, always called with a context. Rename the registry to
  `Normandy.Tools.Toolset` (or `ToolRegistry`).
- VERIFIED

### DX-23. `DSL.Agent` imports every macro into the whole module and resolves conflicts silently
- dsl/agent.ex:84-92, :530-555, :634, :660-688
- `import Normandy.DSL.Agent` brings in `name/1, description/1, model/1, steps/1, tool/1, memory/0..1,
  background/1, temperature/1` and more for the whole module, not just inside `agent do`. Only the
  `hooks/1` clash is documented (moduledoc "Name clashes").
- `system_prompt` silently wins over `background`, `steps` and `output_instructions` when both are
  given (the `cond` at :665).
- `description` is stored but only returned by `config/0`.
- A missing `model` raises a bare `RuntimeError "model is required in agent definition"` at `new/1`,
  not at compile time (prior AGENTS-15, still present).
- `tool Mod` is built with `struct(Mod)`, so a tool that needs field values cannot be configured.
- Fix: import the macros inside `agent do` only (`import ..., only: [...]` scoped in the block).
  Raise at compile time on a missing model and on `system_prompt` combined with the structured fields.
  Accept `tool %Mod{...}`.
- VERIFIED

### DX-24. `Workflow.execute/1`: `:context` is accepted and never used, and agents are keyed by module
- dsl/workflow.ex:405-460, :519-528, :550-563
- `:context` is documented ("Optional shared context map"), stored in state, and never read again.
- Agents come in as `agents: %{Module => instance}`, so one module cannot appear in two steps with
  different configs.
- Parallel results without `name:` are keyed `:agent_0` and so on.
- Unknown options are ignored (DX-7).
- Fix: remove `:context` or pass it to steps. Key agents by step or agent name.
- VERIFIED

### DX-25. Test fixtures ship in lib/, and `Examples.Weather` makes live HTTP calls
- **BREAKING** (module removal) · lib/normandy/tools/examples/*.ex
- `Weather`: "This tool is designed for integration testing", and it calls `Req.get` against
  Open-Meteo.
- All five `Normandy.Tools.Examples.*` modules compile into every consumer and appear on HexDocs.
  `BaseAgent.register_tool`'s doc uses `%Normandy.Tools.Examples.Calculator{}`.
- Fix: move them to test/support or examples/.
- VERIFIED

### DX-26. Two JSON libraries are hard deps, and Poison is the default
- **BREAKING** (default adapter) · mix.exs:164,168; io_model.ex `@derive {Poison.Encoder, ...}`;
  13 `Application.get_env(:normandy, :adapter, Poison)` call sites
- Most Elixir apps use Jason (or `JSON` in Elixir 1.18). CLAUDE.md still says `:adapter` is required;
  it is not, because it defaults to Poison.
- Fix: default to Jason. Make Poison optional or drop it. Read the adapter once, in one helper.
- VERIFIED

### DX-27. `BaseAgent.init/1` starts a linked process
- base_agent.ex:132-140
- With `enable_circuit_breaker: true`, init does `{:ok, cb} = CircuitBreaker.start_link(cb_opts)`.
  The constructor of a plain struct links a GenServer to whichever process built the config (a test, a
  Task, a LiveView mount), and the pid travels inside the config.
- Fix: callers pass a breaker name or pid they supervise (`circuit_breaker: MyApp.Breaker`), or Normandy
  starts it under its own supervisor.
- VERIFIED (code); PLAUSIBLE (impact)

### DX-28. Timeouts differ between the process APIs
- turn/server.ex:218-220 uses `:gen_statem.call(..., :infinity)` with no option.
  `AgentProcess.run/3` defaults `:timeout` to 60_000. `Reactive` uses 60_000. The orchestrators and
  `Batch` use 300_000.
- Fix: `Turn.Server.run/3` with `:timeout`, and document every default in one place.
- VERIFIED

### DX-29. examples/README.md is stale
- examples/README.md:45-46 `{:normandy, "~> 0.1.0"}, {:claudio, "~> 0.1.1"}`.
- :150 `ChatAgent.stream(...)` does not exist.
- "For streaming token-by-token (when implemented in Normandy)": streaming has shipped.
- Fix: rewrite against 2.0 (`MyAgent.run(agent, msg, stream: true, on_chunk: ...)`).
- VERIFIED

### DX-30. `run` and `stream` return different shapes
- **BREAKING** · base_agent.ex:1248-1251
- `run/2` returns the output-schema struct. Streaming returns "the accumulated message map; it is not
  converted to the output schema", and its callback payloads are string-keyed (`tool["name"]`).
- Fix: convert the final streamed message to the output schema (or a `%StreamResult{}`), and use
  atom-keyed or struct payloads (`%StreamEvent{}` already exists).
- VERIFIED

---

## LOW

### DX-31. Error messages that fall short of the CLAUDE.md bar
- schema.ex:879 `"invalid option #{inspect(k)} for #{fun_arity}"` names neither the field nor the
  valid options. Compare :934 (`"field/3: option :x for field :y must be ..., got: ..."`), which is
  good.
- dsl/agent.ex:634 `raise "model is required in agent definition"` is a bare `RuntimeError` that
  names no module.
- tools/registry.ex:117 `raise "Tool '#{tool_name}' not found in registry"` is a `RuntimeError` that
  lists no available tools (`list_names/1` exists).
- schema.ex:462 is a bare `raise`.
- `KeyError` for a missing `:model`, `:client` or `:store` (DX-6, DX-7).
- Good examples to copy: claudio_adapter.ex:1361-1390, retry.ex:149-170, dsl/agent.ex:404-407,
  agent_memory.ex add_message.
- VERIFIED

### DX-32. `iex>` examples that are not doctested and cannot run
- base_agent.ex: `run_with_tools` (`iex> {config, response} = BaseAgent.run_with_tools(agent,
  user_input)`), `register_tool`, `get_tool`, `list_tools`, `has_tools?`.
- tools/base_tool.ex: examples use `%MyTool{}` and `%CalculatorTool{}`, which do not exist.
- Only 6 modules are doctested.
- Fix: switch these to indented code without `iex>`, or make them real doctests.
- VERIFIED

### DX-33. `ModelCatalog.Static` is deprecated only in prose
- behaviours/model_catalog.ex:48 says "Deprecated ... Removed in 3.0", but there is no `@deprecated`
  on its functions, so users get no compile warning. Add `@deprecated`.
- VERIFIED

### DX-34. Small inconsistencies in the docs
- Model ids differ: README `claude-sonnet-4-6`; the guides `claude-sonnet-4-5`; moduledocs
  `claude-opus-5-5`.
- Memory roles are strings (`"user"`, `"assistant"`), where Elixir would use atoms.
- The README quickstart never reads `response.chat_message`, never shows rescuing `LLMError`, and does
  not link the hooks or agent-memory guides.
- VERIFIED

### DX-35. Package file list and repo hygiene
- mix.exs:274 `files:` leaves out MIGRATING-2.0.md (the extras still render it on HexDocs, but the
  tarball lacks it).
- `test_json_schema_export.exs` is tracked at the repo root.
- `Tools.Registry` exposes speculative introspection (`filter_by_param_type/2`,
  `tools_with_constraint/2`, `filter_by_required_params/2`) with no callers in lib, which adds public
  surface to maintain.
- VERIFIED (files list, tracked file); the callers claim comes from a grep of lib only

### DX-36. `Model` returns are loosely typed
- `converse` returns `struct()`, and the `run/2` spec returns `struct()`. Users get no Dialyzer help
  on response types. This folds into the DX-4 redesign (a `Response.t()` and typed output schemas).
- VERIFIED

---

## Breaking changes to decide for 2.0 (from the list above)
DX-2 (drop `completitions`), DX-4 (Model protocol), DX-5 (tuple `run` + `run!`; Turn.Server LLM error
reply), DX-6/DX-7 (strict options), DX-11 (remove duplicate entry points), DX-14 (Session handle),
DX-15 (orchestrator arity), DX-16/DX-17 (conventions, exception names), DX-18 (config shape),
DX-19 (dead slots), DX-21 (BaseIOSchema), DX-22 (tool contract, registry name), DX-25 (examples out of
lib), DX-26 (JSON default), DX-30 (stream result).

Not breaking and cheap: DX-1, DX-8, DX-9, DX-10, DX-12, DX-13, DX-20, DX-23 (partly), DX-24, DX-28,
DX-29, DX-31–36.
