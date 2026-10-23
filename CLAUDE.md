# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Normandy is an Elixir library for building AI agents with structured schemas, validation, and LLM integration. It provides a type-safe approach to defining agent inputs/outputs using JSON schemas and supports conversational memory management.

## Common Commands

### Development
- `mix precommit` - Run before committing: `compile --warnings-as-errors`, `deps.unlock --check-unused`, `format`, `credo --strict`, `dialyzer`, `test --warnings-as-errors` (runs in MIX_ENV=test)
- `mix compile` - Compile the project
- `mix format` - Format code according to .formatter.exs
- `mix test` - Run all tests
  - Elixir 1.20 prints `Result: N passed (...)`, not "0 failures"; gate on the exit status (`${pipestatus[1]}` after `| tee`), not on a grep for failures
- `mix test test/path/to/test.exs` - Run a specific test file
- `mix test test/path/to/test.exs:42` - Run a specific test at line 42
- `mix credo --strict` - Lint; stock `.credo.exs`. Complexity/nesting findings get an inline `# credo:disable-for-next-line`, never a global threshold change
- `mix dialyzer` - Type analysis; PLTs live in `_build/plts`, accepted warnings in `.dialyzer_ignore.exs` (each with a reason)
- `tools/api_diff/run.sh main` - Public API removed or changed since `main` that MIGRATING-2.0.md does not name (exit 1 lists them); reviewed exceptions in `tools/api_diff/reviewed.txt`

### Dependencies
- `mix deps.get` - Fetch dependencies
- `mix deps.compile` - Compile dependencies

### Console
- `iex -S mix` - Start interactive Elixir shell with project loaded

## Architecture

### Schema System (Core Foundation)

The schema system is Normandy's foundation, heavily inspired by Ecto but adapted for AI agent I/O schemas:

- **`Normandy.Schema`** - Macro-based DSL for defining structs with JSON schema generation
  - `schema do ... end` - Basic schema definition
  - `io_schema "description" do ... end` - I/O schemas with BaseIOSchema protocol implementation
  - `field/3` - Define fields with types and options (`:description`, `:required`, `:default`)
  - Automatically generates JSON Schema specifications via `__specification__/0`
- **`Normandy.Schema.Wire`** - `encodable/1` is what the model sees of a spec: properties in declaration order (the spec's `:property_order`, sent as `Jason.OrderedObject`), no `$schema`/`title`; used for tool `input_schema`, the `# OUTPUT SCHEMA` block and retry feedback. `SchemaTranslator` keeps the same order and states the constraints structured outputs drop in the property description. Declaration order is generation order

- **`Normandy.Type`** - Type system with casting, dumping, and loading
  - Base types: `:integer`, `:float`, `:boolean`, `:string`, `:map`, `:date`, `:time`, `:binary`, `:any`, `:struct`
  - Composite types: `{:array, type}`, `{:map, type}`
  - Custom types via `Normandy.Type` behaviour (requires `type/0`, `cast/1`, `dump/1`, `load/1` callbacks)
  - Parameterized types via `Normandy.ParameterizedType`

- **`Normandy.Validate`** - Changeset-like validation for schemas
  - `cast/4` - Cast params into schema types
  - `validate_required/2`, `validate_format/3`, `validate_inclusion/3`, `validate_length/3`, `validate_number/3`, etc.
  - Returns `%Validate{}` struct with errors, changes, and validation state

### Agent System

- **`Normandy.Agents.BaseAgent`** - Core agent implementation
  - `init/1` - Build a `BaseAgentConfig` from a keyword list or map (requires `:client` and `:model`; `:temperature` is optional and omitted from the request when `nil`, since Opus 4.7+ reject sampling parameters). `:max_tool_iterations` defaults to 20; after the last round the turn stores a notice and makes one more call with `Request.tool_choice: :none`. `max_tool_result_chars` (default 100_000 graphemes, `nil` = off): `Dispatch.finish/3` cuts longer tool results (error results too) after every hook and appends `\n[truncated: N of M chars shown]`; emits `[:normandy, :tool, :result_truncated]`. The schema is `BaseAgent.InitOptions` (NimbleOptions, docs generated into `init/1`); every option is checked through `Normandy.Options.validate!/3` before any process starts, and an unknown one raises `ArgumentError` naming it
  - `run/3` - Execute agent turn; returns `{:ok, config, response}` or `{:error, exception}` (Normandy errors only; bugs raise); `run!/3` returns `{config, response}` and raises; neither takes options yet (any raises `ArgumentError`); an answer cut off at `max_tokens` (or the context window) or refused is `{:error, %LLMError{type: :max_tokens | :refusal}}` on every path (`Normandy.LLM.Call.check_stop_reason/1`), and no tool from it runs; a final call still paused after 3 continuations is `:pause_turn`; a blank final answer is `{:error, %LLMError{type: :invalid_output}}` on every path, except for a `:chat_message` agent whose last tool-calling response in the turn carried text: that text is the answer (`chat_answer/2`)
  - `stream/3` - like `run/3`, streaming `%Normandy.Components.StreamEvent{}` to a 1-arity callback; returns the output schema like `run/3`
  - `get_response/2` - One LLM request with the agent's prompt, tools and memory, outside a run (an `[:normandy, :agent, :llm_call]` span with no `iteration`)
  - `reset_memory/1` - Reset conversation to initial state
  - Context provider management: `register_context_provider/3`, `fetch_context_provider/2` and `fetch_context_provider!/2`, `delete_context_provider/2`

- **`Normandy.Agents.BaseAgentConfig`** - Agent state container
  - Stores: input/output schemas, memory, prompt specification, LLM client/model, optional temperature, max_tokens, resolved context window, and the option groups `retry` (Retry options or nil), `circuit_breaker` (breaker options or nil; calls go through the breaker shared per client module, endpoint, model and options, `BaseAgentConfig.circuit_breaker_key/1`) and `guardrails` (`[input:, output:, streaming_mode:, chunk_size:, on_violation:]`, read with `BaseAgentConfig.guardrail/2`)

- **`Normandy.Options`** - `validate!(opts, schema, {mod, fun, arity})` for every public entry point: NimbleOptions schema, map or keyword input, `ArgumentError` prefixed `Mod.fun/arity:`; values of `sensitive_keys/0` (`:client`, `:api_key`, ...) never appear in a message

- **`Normandy.Agents.Model`** - Protocol for LLM client implementations
  - Requires: `converse/3` and `stream/3` over `%Normandy.LLM.Request{}` (`request.output_format`: the non-chat output schema on a tool-loop call or stream; `%ToolCallResponse{}` carries `content_blocks`, replayed verbatim, and `stop_reason`, `:pause_turn` continues the turn); `converse/3` returns `{:ok, %Normandy.LLM.Response{}}` or `{:error, %Normandy.LLMError{}}`; a non-streaming client's `stream/3` returns `{:error, %LLMError{type: :unsupported}}`
  - Clients must implement this protocol (see Claudio integration in dependencies)

- **`Normandy.Agents.Turn.Server`** - Durable `:gen_statem` turn shell
  - `run/2` replies `{:error, exception}` instead of crashing: Normandy's own exceptions bare (`LLMError`, `ValidationError`, `ViolationError`, `HookHaltError`, `ModelCatalogError`), anything else a `Normandy.TurnError` (`:handler_crashed`, `:task_down`, `:persist_failed`, `:approval_timeout`, `:session_unavailable`, ...); never a tagged tuple or a stacktrace. `TurnError.from_reason/1` is the one mapping
  - `on_approval_timeout: :continue | :fail` (default `:continue`) decides what an approval expiry does; expired calls get `expired: true` results
  - A history ending in a paused turn (`Turn.paused_last?/1`) is continued first, as a resumed run, before the next input is admitted. A failed continuation fails that `run/2` (nothing appended) and the next `run/2` retries it (`Data.paused_continued_for`)
  - A terminal turn-state save (`:stopped`/`:failed`) the store refuses is logged by tag (no event), kept in `Data.unsaved_terminal` and saved again on a `{:timeout, :retry_terminal_save}` timer (1 s doubling to 30 s), before the next turn and before passivating; meanwhile `run/2` replies `:persist_failed` `{:terminal_unsaved, reason}` and passivation waits. An eager resume of a `:steering` turn whose answer is the last stored message (`Turn.answered?/1`) saves it `:stopped` with no model call. Tests: `Normandy.Test.TerminalSaveCases` on every store backend
  - Loads its session in its first event after `init/1` (`:loading`), so a start never waits on the store; a duplicate self-registering start stops with `{:already_started, pid}`. A store call that exits is `{:store_exit, reason}` (`:persist_failed` mid-turn, `:session_unavailable` in a load); anything a load raises, exits or throws leaves the server `:unavailable`; a store's load reason is replied reduced by `Describe.reason_term/1`. Each compaction is stored as a `"compaction"` history entry (`%{version: 1, entries: [...]}`) that `AgentMemory.from_entries/1` applies. `format_status` shows ids and state names only. Under Horde it is named through `SessionRegistry.Horde.Via` (OTP's `gen_statem` checks the via name before `init/1`; `Horde.Registry` alone answers before its table has the key)
  - A stored template is checked before use (`ConfigTemplate.check_loaded!/1`: plain data, behaviour modules declare their behaviour) and against the supplement's `:pinned` (`[policy:, guardrails:, credential:, ...]`); a refusal is `{:invalid_template, message}` in a `:session_unavailable` `TurnError`

- **`Normandy.Agents.Turn.Session`** - Session handle, options validated once
  - `new/1` builds the handle (`:session_id`, `:store`, `:registry`, `:supervisor`, and `:config` or `:template_provider`)
  - `run/2` → `{:ok, output} | {:error, exception}`; a call that reaches a passivated server is routed again (three servers, then `:session_unavailable` `:passivated`); `approve/2` (`%{tool_call_id => :approve | :reject}`); `put_config/2` replaces the config; `delete/1` stops the live server (`supervisor_mod.stop_server/2`) then `SessionStore.delete_session/2`

- **`Normandy.Behaviours.SessionStore`** - `save_turn_state/4` takes `inflight?` (eager and unfinished, computed by `Turn.Server.persist_turn_state/2`) written with the state; `list_resumable/1` returns only in-flight sessions; `delete_session/2` is idempotent and keeps fork-shared entries (Postgres, Mnesia share ancestors; InMemory, ETS, Redis copy). Postgres needs `MigrationAddInflight`. Contract: `Normandy.Test.SessionStoreContract` (`lib/normandy/test/`, shipped; `use` with `impl:`, optional `new: {m, f, a}` and `stored_entry_ids: {m, f, a}`)

- **`Normandy.Behaviours.SessionRegistry.Redis`** - Handle `%SessionRegistry.Redis.Handle{owner:, conn:, namespace:}` (`handle/1`, `fetch_handle/1`; the combo's from `Normandy.Cluster.redis_handles/1`); `whereis` runs in the caller (a remote pid's liveness checked on its node); the refresh stops a process whose key another holds (`{:shutdown, :registration_lost}`, `[:normandy, :session_registry, :ownership_lost]`). `SessionStore.Redis` runs a session's waited writes and their `WAIT` on one of the handle's `wait_conns` (`new/1` `:wait_connections`; the combo's pool, or `:store_redix`)

- **Orchestrators** (`SequentialOrchestrator`, `ParallelOrchestrator`) - `execute(agents, input, opts \\ [])` → `{:ok, %{agent_id => output}}` | `{:error, %Normandy.OrchestrationError{results:, errors:}}`; each agent runs unlinked under a per-call `Task.Supervisor`, so a raise, exit or throw fails only that agent (`:task_down` `TurnError`)

- **`Normandy.Coordination.AgentProcess`** - Agent as a process; `:inline` (default) runs turns one at a time from a FIFO queue (runs, casts, `update_agent/3`, whose `:timeout` defaults to `:infinity`) in a `Normandy.WatchedWorker` that dies with the process and carries `$callers` (Mox/`Req.Test` allowances on the agent pid reach the LLM call), so reads answer during a turn; `run/3` waits `:infinity`; `:max_pending_runs` (default 100) bounds runs and casts in both engines, refused with a `:queue_full` `TurnError`; `:server` without `:registry` uses a scope in the app-level `AgentProcess.ScopedRegistry`; `format_status` shows no config, memory or queued input

### Memory & Messages

- **`Normandy.Components.AgentMemory`** - Conversation history management
  - `new_memory/1` - Create memory with optional max_messages limit
  - `add_message/4` - Add user/assistant message to history (`opts`: `:turn_id`, `:id`)
  - `initialize_turn/1` - Start new conversation turn (generates UUID)
  - `history/1` - Get formatted message history for LLM
  - Each `AgentMemory.Entry` carries derived `wire` (the model-facing encoding) and `tokens` (its estimate), set only by AgentMemory when content is set (`add_message/4`, thinking drops, `from_entries/1`, `load/1`) and never persisted; request builders use `request_messages_for/2` (`@doc false`, one walk) and compaction `keep_entries/3`. Content that cannot be encoded raises at append
  - `request_messages/1` - History to request messages; each run of tool results becomes one message (one user turn on the wire), with a following user text as its last block. An assistant message other than the last loses each `server_tool_use`/`mcp_tool_use` block nothing answers (the API accepts one only in the last message), and goes if that leaves it empty or holding only thinking. Memory keeps one entry per result and the stored history is unchanged
  - `dump/1` and `load/1` - Serialize/deserialize memory state
  - `from_entries/1` - Rebuild from store history; applies the last `"compaction"` snapshot entry; a stored entry it cannot rebuild raises `ArgumentError` naming the entry
  - `delete_turn/2` - Remove specific conversation turn

- **`Normandy.Components.Message`** - Message struct with `:turn_id`, `:role`, `:content`

### Long-term Memory & Tool Context

- **`Normandy.Behaviours.MemoryStore`** - Namespaced, path-addressed document store with
  compare-and-set versions; `put/6` takes `limits` (`[max_bytes:, max_documents:]`) checked
  atomically with the write (`check_limits/3`, `{:error, {:namespace_full, :bytes | :documents, n}}`);
  backends InMemory, ETS and Mnesia (one row per document plus a `{ns, 0}` totals row;
  rules in `MemoryStore.Rows`), Postgres (counter table `normandy_memory_namespaces`),
  Redis (`:bytes` key); shared contract `Normandy.Test.MemoryStoreContract` (`lib/normandy/test/`, shipped)
- **`Normandy.Tools.Memory`** - The `memory` tool (Anthropic memory-tool commands); namespace
  from `tool_context[:memory_namespace]`, never from the struct; `Commands`/`Paths`/`Render`
  hold command logic, path rules and model-facing text; limits `max_document_bytes`,
  `max_namespace_bytes` (default 1_000_000) and `max_namespace_documents` (default 1000), each
  namespace cap `nil` = off and enforced by the store, `max_view_chars`, `max_cas_retries`;
  a session namespace equal to a mount's raises; mounts sharing a namespace must share its access
- **`Normandy.Tool`** - The one tool contract: `name/1`, `description/1`, `input_schema/1`,
  `run(tool, %Normandy.Tools.Context{})`; `use Normandy.Tool, name:, description:, input: Schema`
  generates the first three. The struct holds configuration only; the model's input is
  validated (`Normandy.Tools.Input`: unknown keys refused, except under a hand-written schema with no `properties`) and arrives as `context.input`
- **`Normandy.Tools.Toolset`** - Tools by name (`BaseAgentConfig.toolset`); `register/3`
  options `:timeout` (the call's timeout; a struct field is never read), `:max_result_chars`
  (this tool's result cap; `nil` = none) and `:replace`;
  `fetch/2`, `fetch!/2`. A struct whose module is not a `Normandy.Tool` raises at
  registration and in `ConfigTemplate.rebuild/3` (1.x tools)
- **`Normandy.Tools.Context`** - Per-call context: `input`, plus `values` from
  `BaseAgentConfig.tool_context` (plain data, persisted in the config template), built by
  every pipeline through `Dispatch.executor_opts/3`

### Lifecycle Hooks

- **`Normandy.Behaviours.Hooks`** - Ordered `{module, opts}` entries on `Behaviours.Config.hooks`
  (persisted in the config template; opts plain data, checked at `BaseAgent.init/1`); optional
  callbacks `on_session_start`, `on_passivate`, `on_prompt`, `before_llm`, `before_tool`,
  `after_tool`, `after_compact`, `on_turn_end`; `use` checks callback names and arities
- **`Normandy.Hooks.Runner`** - The only caller of hook modules: order, rewrites, halts,
  `:on_error`, return contracts, the `[:normandy, :hook, *]` span; call sites in
  `Normandy.Hooks.BaseAgentGlue`, `Normandy.Hooks.ServerGlue`, `Normandy.Hooks.Handlers`
  (wraps any handler set with `before_llm`/`after_compact`) and `Config.to_pipeline/1`
  (tool hooks; `after_tool` sees every tool result once). No hook outcome terminates
  `Turn.Server`; no hook timeouts
- **`Normandy.Guardrails`** - `:on_error` (`:reraise | :open | :closed`) covers raises, exits and throws; host code a builtin calls fails as `Normandy.Guardrails.GuardError`; `on_violation: :warn` logs the guards, paths and count only (the messages are in the `ViolationError`)

### Prompt System

- **`Normandy.Components.SystemPromptGenerator`** - Generates system prompts
  - Takes `PromptSpecification` and builds structured prompt with sections:
    - "Role" (background; an empty one is "You are a helpful assistant.")
    - "How to work" (steps)
    - "Output" (output_instructions; BaseAgent appends the output schema)
    - "Context" (from context providers)

- **`Normandy.Components.PromptSpecification`** - Defines prompt structure
  - Fields: `:background`, `:steps`, `:output_instructions`, `:context_providers`

- **`Normandy.Components.ContextProvider`** - Protocol for providing dynamic context
  - Used to inject runtime information into prompts (e.g., current time, user data)

### I/O Schema Protocol

- **`Normandy.Components.BaseIOSchema`** - Protocol for agent I/O serialization
  - Auto-implemented for `io_schema` definitions
  - Methods: `to_json/1`, `get_schema/1`
  - Encodes through `Normandy.JSON` (adapter from `config :normandy, :adapter`, default Jason)

### Resilience & Error Handling

- **`Normandy.Resilience.Retry`** - Exponential backoff retry with jitter
  - Integrated into `BaseAgent` for automatic retries on LLM call failures
  - Configured per agent with `init/1`'s `retry:` (max attempts, backoff factor, delay)

- **`Normandy.Resilience.CircuitBreaker`** - Three-state circuit breaker (Closed, Open, Half-Open)
  - Prevents cascading failures by failing fast when thresholds are reached
  - Configured per agent with `init/1`'s `circuit_breaker:` (thresholds, timeout)

### Declarative DSLs

- **`Normandy.DSL.Agent`** - `agent do ... end` macro for defining agents declaratively
  - Configure background, steps, output_instructions, model, tools, etc.
  - Generates `new/1` (returns the `BaseAgentConfig`; takes `BaseAgent.init/1`'s options without defaults, checked under `MyAgent.new/1`) and `run/1-3`
  - `system_prompt` beside `background`/`steps`/`output_instructions` raises `ArgumentError` at compile time; the generated code calls `Normandy.DSL.Agent.__prompt_specification__/1` (no injected helpers), which builds the `PromptSpecification` from the block's config (`system_prompt` alone becomes its background)

- **`Normandy.DSL.Workflow`** - `workflow do ... end` macro for multi-agent workflows
  - Sequential (`step`), parallel (`parallel`), and race (`race`) execution patterns
  - Built-in data flow, transformations, and conditional branching

### Observability & Telemetry

- **`Normandy.Agents.BaseAgent`** - Integrated Telemetry and structured logging
  - Events: `[:normandy, :agent, :run, :start | :stop | :exception]`, etc.
  - Automatic duration tracking and metadata enrichment (agent name, model, tools)
  - OpenTelemetry-compatible span context correlation
- **`Normandy.Telemetry`** - The catalogue of every emitted event (measurements, metadata, OTel GenAI mapping, known limits). `test/telemetry/catalogue_test.exs` fails when an emitted event is missing from its moduledoc, so document any new event there. Run `:stop` carries the run's totals (`llm_calls`, token sums, `iterations`, `stop_reason`, `finish_reason`), summed by `Normandy.Telemetry.RunUsage`, a `:counters` ref every shell puts on its call requests as `request[:run_usage]` (`with_llm_call_span` adds each finished call; summary calls are not counted). `Turn.Server` keeps the caller's OTel context current from admission to `on_turn_end` (`turn_ctx_token`, released by `release_turn_ctx/1` on every turn exit)

### Protocol Support

- **`Normandy.MCP.ToolWrapper`** - Interoperate with Model Context Protocol servers. `:prefix` is required on `ToolWrapper.new/4`, `MCP.Registry.discover_and_register/4`/`wrap_tools/4` and `BaseAgent.register_mcp_tools/4` (and on `A2A.AgentTool.new/3` and `A2A.Registry`): letters, digits, `-` and single `_`, at most 61 bytes, or `false`; tools are named `prefix__name`. Policy globs must match remote tools on the prefix
- **`Normandy.A2A.Server`** - Expose agents for agent-to-agent collaboration; `handle_message/4` takes `:max_text_bytes` (default 100_000, `nil` off; over → `{:error, :too_large}`; a text part whose text is not a string → `{:error, :invalid_message}`) and `:tool_context` (replaces the config's for one call). Authentication and body limits are the host's

## Key Patterns

### Defining Agent I/O Schemas

```elixir
defmodule MyInputSchema do
  use Normandy.Schema

  io_schema "Input for my agent" do
    field :query, :string, description: "User query", required: true
    field :max_results, :integer, description: "Max results", default: 10
  end
end
```

### Agent Workflow

1. Define input/output schemas using `io_schema`
2. Build the `BaseAgentConfig` with `BaseAgent.init/1` (client, model, schemas, prompt specification)
3. Run conversation turns with `BaseAgent.run/3` (`{:ok, config, output}` | `{:error, exception}`)
4. Agent manages memory automatically, serializing I/O schemas to JSON

### Validation Flow

1. Cast params with `Validate.cast/4` specifying permitted fields
2. Chain validations: `validate_required/2`, `validate_format/3`, etc.
3. Check `changeset.valid?` or use `apply_action/2` for error handling
4. Apply changes with `apply_changes/1` or `apply_action!/2`

## Configuration

- `config/config.exs` - Imports environment-specific config
- `config/dev.exs` and `config/test.exs` - Environment configs
- `:adapter` (optional, default `Jason`) - the JSON library `Normandy.JSON` calls; any module with `encode!/2` and `decode/1` (see the `Normandy.JSON` moduledoc)
- `:structured_outputs` (default `true`) toggles Anthropic native structured outputs; set to `false` globally or via `client.options[:structured_outputs]` to force the legacy parse-retry path — a tool-loop call or stream sends a non-chat output schema as `output_config.format` beside its tools (`Normandy.LLM.Request.output_format`); automatic fallback also applies for incompatible schemas and a 400 that names the output format or schema (on `stream/3` too; other 400s are returned without a second request); a response that stops at `max_tokens`, `model_context_window_exceeded` or `refusal` is never parsed or re-asked
- `client.options` request settings (`:thinking`, `:effort`, `:speed`, `:inference_geo`, `:fallbacks`, `:task_budget`, `:thinking_budget`, `:thinking_block_binding`, `:enable_caching`, `:req_options`) are documented on `Normandy.LLM.ClaudioAdapter`; nothing is sent unless set, except prompt caching, on by default (`enable_caching: false` opts out)
- `consolidate_protocols: false` in test environment for faster compilation

## Dependencies

- **Claudio** - LLM client library (Hex package `~> 0.7.1`; requests are built with `Request.add_messages/2`)
- **Jason** - JSON encoding/decoding (the default `:adapter`)
- **NimbleOptions** - option schemas for every public entry point (through `Normandy.Options`)
- **elixir_uuid** - UUID generation for conversation turns

## Releases

- Releases are automatic: on a push to `main` after CI, `.github/scripts/release-version.sh` asks `cog bump --auto --dry-run` (`cog.toml`) for the next version; `feat:` = minor, `fix:` = patch, `!`/`BREAKING CHANGE` = major, `docs:`/`ci:`/`chore:`/`test:` alone release nothing. `pr-title.yml` lints the PR title as a conventional commit; squash-merge with the title as the commit and a hand-written body (the repo default body would copy every commit message, trailers included)

## Notes

- Protocol consolidation disabled in test env (`consolidate_protocols: Mix.env() != :test`)
- Test support files in `test/support/` (included via `elixirc_paths/1` in mix.exs)
- `Normandy.Test.OwnLog.capture/2` - `capture_log/2` that keeps only the caller's own log events; use it for an async test's log refute when the code under test logs in the caller's process. A test that starts a supervisor or Horde member uses `start_supervised!` (never `on_exit` + `Process.exit(..., :kill)`), so its shutdown logs cannot reach a later test
- `Normandy.Test.FakeClient` (shipped in `lib/normandy/test/`) is the scripted model client for tests: `new([{:text, t | [chunks]} | {:structured, map} | {:tool_calls, [{name, input} | %ToolCall{}]} | {:error, %LLMError{}} | fun], options: %{})`, item options `:stop_reason`, `:usage`, `:stream_error_after`; `requests/1`, `remaining/1`; a request past the script raises `ScriptExhaustedError`. Use it instead of a new inline `defimpl Normandy.Agents.Model`. The store/registry contracts ship beside it (`SessionStoreContract`, `MemoryStoreContract`, `SessionRegistryContract`). `test/support` never defines a module name `lib/` ships (`test/normandy/test/shipped_names_test.exs`); a new contract test updates the counts (16 session store, 33 memory store) in `test/normandy/test/contracts_test.exs`
- `Normandy.Test.opaque/1` (`test/support/opaque.ex`) hides a deliberately wrong argument from the compiler's type checker; wrap it so `mix test --warnings-as-errors` (Elixir 1.20) stays clean
- Docs tests in `test/docs/`: `docs_groups_test.exs` (every `lib/` module with docs is in exactly one `mix.exs` `groups_for_modules` group; internals are `@moduledoc false`), `doc_coverage_test.exs` (every function, macro and callback of a visible module has `@doc`), `devex_docs_test.exs` (`iex>` only in doctested files; one model id, `claude-opus-5-5`, in README and guides). A new public module needs a group; a new internal one needs `@moduledoc false`. `docs/guides/testing.md` and `docs/guides/hooks.md` are guide-tested (`test/docs/testing_guide_test.exs`, `test/hooks/guide_examples_test.exs`): changing an example module means updating that test's counts
- Metadata tracking via `Normandy.Metadata` struct in schemas
- Before running tests run `mix format`
- If tests fail, they must be fixed, even if were items we were not working on.