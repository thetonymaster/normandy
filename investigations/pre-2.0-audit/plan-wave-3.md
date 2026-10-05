# Normandy 2.0 — Wave 3 Implementation Plan (Config, options, tool contract)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every public entry point reject unknown options with a message naming the function and the key, reshape `BaseAgentConfig` into named option groups that 1.x templates translate into, replace the three tool contracts with one `Normandy.Tool` behaviour that never merges model input into the tool struct, and settle the naming, return-shape and JSON conventions 2.0 ships with.

**Architecture:** One helper, `Normandy.Options`, wraps NimbleOptions and turns its errors into `ArgumentError`s that name `Module.function/arity`. `BaseAgent.init/1` adopts it first (Task 3.1), then the config reshape and template translation land on top of it (Task 3.2). The JSON helper (Task 3.3) lands before the tool rewrite because tool results are encoded through it. The tool contract (Tasks 3.4a–3.4d) is the largest change: a mechanical rename, then the behaviour and input validator, then the dispatcher rewrite together with every implementation's migration (they cannot land apart without breaking every tool), then the 1.x guard and docs. Session and orchestrator shapes (Task 3.5) and lookup naming (Task 3.6) follow. Option validation for every other entry point (Tasks 3.7a–3.7d) goes last so its schemas describe the final signatures. Every task ends green on the full suite.

**Tech Stack:** Elixir ~> 1.15, ExUnit + StreamData, NimbleOptions ~> 1.1 (new direct dependency), Jason (replaces Poison), Claudio (path dep `../Claudio`), telemetry.

**Spec:** `investigations/pre-2.0-audit/decisions.md`: decisions 1, 7, 9 and **decision 17** (Wave 3 details Q settled on 2026-10-05). Roadmap: `plan.md` §"Wave 3". Findings: `devex.md` (DX-6, DX-7, DX-14–DX-19, DX-21, DX-22, DX-25, DX-26, DX-28, DX-31), `security.md` (SEC-1). Current-code inventories written for this plan: `wave-3-research/3.1-3.2-config.md`, `3.3-opts.md`, `3.4-tools.md`, `3.5-3.6-session-naming.md`, `3.7-json-examples.md`.

**Task numbering vs. the roadmap:** roadmap 3.1→3.1, 3.2→3.2, 3.7 (JSON, examples)→**3.3**, 3.4→**3.4a–3.4d**, 3.5→3.5, 3.6→3.6, 3.3 (options everywhere)→**3.7a–3.7d** (3.7c split in two for size), gate→3.8. Options everywhere moved last so each schema describes the signature the earlier tasks settle.

**Findings closed:** DX-5 rest (DSL `new/1`), DX-6, DX-7, DX-14, DX-15, DX-16, DX-17, DX-18, DX-19, DX-21 (the `__str__`/`__rich__` part), DX-22, DX-25, DX-26, DX-28 (option names only), DX-31 (the `KeyError` bullets), SEC-1. Deferred minors closed: `config_template.ex` `||` lets a stored 0/negative/false `max_tokens` through (Wave 1 Task 1.3 → Task 3.2); `Compactor.WindowManager.checked_manager/2` misleading message for `max_tokens: nil` and bare `KeyError` (Wave 2 Task 2.0 → Task 3.2); `check_run_opts!/1` message does not name `run/3` (Wave 2 Task 2.8 → Task 3.1).

**Out of scope (owner):** what `circuit_breaker:` options mean at runtime and the breaker's key (Wave 4; this wave only renames and validates them), tool-result caps (Task 5.4), consolidating the four schema accessors `get_schema`/`get_json_schema`/`__schema__(:specification)`/`__specification__` (Wave 7 docs task; this wave removes only `__str__`/`__rich__`), the `examples/` apps' own configs beyond the Poison lines (Wave 7), unreleased dev-branch templates (decision 17c: only v1.0.0 templates translate).

## Global Constraints

- Elixir `~> 1.15`; CI matrix Elixir 1.15–1.19 on OTP 26–28. Anything newer than 1.15 needs a guard.
- Each task ends with `mix format` then `mix test` showing ` 0 failures`; the wave ends with `mix precommit` exit 0. Gate on the literal ` 0 failures`, never on `| tail` output alone.
- Credo: stock `.credo.exs`. Complexity or nesting findings get an inline `# credo:disable-for-next-line`, never a threshold change.
- Dialyzer: a new `.dialyzer_ignore.exs` entry needs a reason comment.
- Every emitted telemetry event is documented in the `Normandy.Telemetry` moduledoc (`test/telemetry/catalogue_test.exs` enforces it). This wave adds none.
- A new Turn core effect must be wired into all three interpreters (`Turn.Driver`, `Turn.Inline`, `Turn.Server`). This wave adds none.
- No silent fallbacks (`|| default`, `rescue _ ->`) that turn a hard failure into wrong data. Error messages say what was expected and what was received.
- Never log or put into telemetry a stacktrace's arguments or a config value. Option errors may name the key and the expected type; they never echo a value that could be a secret (an `:api_key`, a client struct) — NimbleOptions messages include the value, so `Normandy.Options` redacts it for keys listed as sensitive.
- Commits: conventional messages; add files individually (`git add .` is forbidden); no AI attribution lines (no `Co-Authored-By`, no "Generated with"). Do not push or merge.
- `MIGRATING-2.0.md` is updated in the task that makes the change; new sections start at §21 and are numbered in execution order: §21 option checking (3.1a–c), §22 config groups and templates (3.2a–c), §23 JSON (3.3a), §24 example tools (3.3b), §25 Tools: one `Normandy.Tool` behaviour (3.4a; 3.4c/3.4d append), §26 `Turn.Session` handle (3.5a), §27 orchestrators (3.5b; 3.5c/3.5d append), §28 `fetch_*` lookups (3.6a; 3.6b appends), §29 `BaseIOSchema` dunders (3.6c), §30 every option is checked (3.7a; 3.7b–d append). Error messages that point at a section name it as `MIGRATING-2.0.md §NN`.
- Acceptance greps are scoped to `lib/ test/ config/` (`.claude/worktrees/` holds stale copies).
- If any test fails, fix it, even outside the task's scope.

## Shared interfaces (every task uses these exact names)

```elixir
# Task 3.1a — lib/normandy/options.ex
Normandy.Options.validate!(opts :: keyword() | map(), schema :: NimbleOptions.t(),
                           mfa :: {module(), atom(), arity()}) :: keyword()
# raises ArgumentError: "#{inspect(mod)}.#{fun}/#{arity}: <reason>". A map is converted to a
# keyword list first; string keys and duplicated keys raise with their own messages.
# Unknown keys (house style, NimbleOptions' own wording is replaced):
#   "M.f/1: unknown option :x; supported: :a, :b"   (several: "unknown options [:x, :y]; ...";
#   nested: "unknown option :x in :parent; supported: ...")
# Any other error: NimbleOptions' message after the prefix, except for a sensitive key.
Normandy.Options.docs(schema :: NimbleOptions.t()) :: String.t()
Normandy.Options.sensitive_keys() :: [atom()]
# :api_key, :authorization, :client, :credential, :headers, :mcp_servers, :password,
# :req_options, :secret, :token (Tasks 3.7a–d add :config, :agent, :agent_config, :agents,
# :auth_token, :transport_opts, :context, :url, :redix, :templates). An error on such a key,
# or nested under one, shows the key and its :type_doc, never the value:
#   "M.f/1: invalid value for :client option: expected <type_doc>; the value is not shown
#    because :client can hold a secret"
# The one NimbleOptions custom type for a plain map (Task 3.1a; decision 18):
Normandy.Options.plain_map(term()) :: {:ok, map()} | {:error, String.t()}
#   used as {:custom, Normandy.Options, :plain_map, []} (InitOptions' :tool_context in 3.1b and
#   every 3.7a–d schema): NimbleOptions' :map / {:map, k, v} raise Protocol.UndefinedError on a
#   struct. Error (exact): "expected a plain map (not a struct), got: <Describe.type_of/1>",
#   e.g. "...got: a %URI{}", "...got: a list", "...got: a string (4 bytes)".
# Task 3.7a — test/support/options_assertions.ex (used by 3.7b–3.7d)
Normandy.Test.OptionsAssertions.assert_rejects(key, mod, fun, args)
Normandy.Test.OptionsAssertions.assert_documents_options(mod, fun, arity)

# Task 3.1b — BaseAgent.init/1
BaseAgent.init(keyword() | map()) :: BaseAgentConfig.t()    # schema: BaseAgent.InitOptions
# Missing :model carries the Mod.fun/n prefix like every other init/1 message (decision 18):
#   "Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"   (absent key or model: nil)
# Task 3.1c — DSL: MyAgent.new(keyword() | map()) :: BaseAgentConfig.t() (was {:ok, config});
#   raises ArgumentError prefixed "MyAgent.new/1: " (init/1's schema without defaults);
#   no declared model: "MyAgent.new/1: requires :model (a string), got none" (decision 18).

# Task 3.2 — BaseAgentConfig fields that replace the 1.x ones
retry: keyword() | nil                 # was retry_options
circuit_breaker: keyword() | nil       # was enable_circuit_breaker + circuit_breaker_options (options only)
circuit_breaker_pid: pid() | nil       # was circuit_breaker (the pid); node-local; Wave 4 replaces it with a key
guardrails: keyword()                  # [input:, output:, streaming_mode:, chunk_size:, on_violation:]
# compactor option :max_tokens → :context_window

# Task 3.3a — lib/normandy/json.ex
Normandy.JSON.encode!(term(), keyword() \\ []) :: String.t()
Normandy.JSON.encode(term(), keyword() \\ []) :: {:ok, String.t()} | {:error, Exception.t()}
Normandy.JSON.decode(String.t()) :: {:ok, term()} | {:error, Exception.t()}
Normandy.JSON.decode!(String.t()) :: term()
# Structs: a struct with its own encoder impl (derived) is encoded by it; any other struct
# is encoded as its map without :__struct__ and :__meta__. Adapter: :normandy, :adapter (default Jason).
# Dispatch (Task 3.3a; kept by Task 3.4c): a tool output JSON cannot express becomes an
# is_error: true result before it reaches memory (wrap_output/2); an error reason JSON cannot
# express is sent as its inspect/1 text (wrap_error/2).

# Task 3.3b — the four example tools move to test/support/tools/ KEEPING their module names
# Normandy.Tools.Examples.{Calculator, EnhancedCalculator, ListProcessor, StringManipulator};
# Weather becomes MyApp.Tools.Weather in examples/tools/weather.ex (not compiled by mix).

# Task 3.4b — lib/normandy/tool.ex (decision 17a)
@callback name(tool :: struct()) :: String.t()
@callback description(tool :: struct()) :: String.t()
@callback input_schema(tool :: struct()) :: map()          # JSON Schema object
@callback run(tool :: struct(), Normandy.Tools.Context.t()) :: {:ok, term()} | {:error, term()}
use Normandy.Tool, name: "x", description: "y", input: MyInputSchema   # generates the first three
# Normandy.Tools.Context gains :input (the validated model input: a struct when the tool
# declared input:, else a string-keyed map checked against input_schema/1).
Normandy.Tool.name/1, description/1, input_schema/1, run/2   # dispatch on tool.__struct__
Normandy.Tool.implemented_by?(module()) :: boolean()
Normandy.Tools.Input.validate(tool :: struct(), input :: term()) ::
  {:ok, struct() | map()} | {:error, [%{path: _, message: String.t(), constraint: atom()}]}
Normandy.Tools.Input.message([error]) :: String.t()   # one line naming the keys
# A hand-written input_schema/1 map (decision 18): no `properties` key ⇒ open (any keys; still
# an object; `required` still checked); `properties` without `additionalProperties`, or with
# `false` ⇒ strict (unknown keys rejected, named); `additionalProperties: true` ⇒ open.

# Task 3.4a/b/c — lib/normandy/tools/toolset.ex (was Tools.Registry)
Normandy.Tools.Toolset.new([tool | {tool, keyword()}]) :: Toolset.t()
Normandy.Tools.Toolset.register(Toolset.t(), tool, keyword()) :: Toolset.t()   # opts: :timeout (3.4c), :replace
Normandy.Tools.Toolset.fetch(Toolset.t(), String.t()) :: {:ok, tool} | :error
Normandy.Tools.Toolset.fetch!(Toolset.t(), String.t()) :: tool                # raises Normandy.ToolNotFoundError
Normandy.Tools.Toolset.fetch_metadata(Toolset.t(), String.t()) :: {:ok, map()} | :error   # was get_metadata/2 (3.4a)
Normandy.Tools.Toolset.timeout(Toolset.t(), String.t()) :: pos_integer() | nil           # 3.4c
# BaseAgentConfig.tool_registry, init/1's :tool_registry, the DSL override and the
# AgentTemplate supplement key all become :toolset (3.4a).
BaseAgent.register_tool(BaseAgentConfig.t(), tool, keyword() \\ []) :: BaseAgentConfig.t()  # opts → Toolset.register/3
Normandy.Agents.Dispatch.Invocation   # %{tool, input, timeout}: what classify/3's :execute and
                                      # :needs_approval verdicts, execute/4, policy_fn and
                                      # execute_fn carry instead of the input-merged struct (3.4c)
Normandy.Tools.Executor.execute_tool/2, execute_tool_classified/2   # opts :context (required), :timeout
Normandy.Tools.Executor.default_timeout() :: 30_000                 # execute/3, execute_parallel/3,
                                                                    # execute_sequential/3 removed (3.4c)

# Task 3.5
Normandy.Agents.Turn.Session.new(keyword()) :: Session.t()
Normandy.Agents.Turn.Session.run(Session.t(), input) :: {:ok, output} | {:error, Exception.t()}
#   (Turn.Server keeps the config; a returned config would be a stale copy)
Normandy.Agents.Turn.Session.approve(Session.t(), decisions) ::
  :ok | {:error, %Normandy.TurnError{type: :session_unavailable}}
#   (Turn.Server.approve/2 is a cast; the turn's result goes to the parked run/2 caller)
Normandy.Agents.Turn.Session.put_config(Session.t(), BaseAgentConfig.t()) :: Session.t()
SequentialOrchestrator.execute(agents, input, keyword() \\ []) ::
  {:ok, %{id => output}} | {:error, %Normandy.OrchestrationError{}}
ParallelOrchestrator.execute(agents, input, keyword() \\ []) ::
  {:ok, %{id => output}} | {:error, %Normandy.OrchestrationError{}}
Normandy.OrchestrationError   # defexception results: %{id => output}, errors: %{id => Exception.t()}

# Task 3.6 (decision 17b)
BaseAgent.fetch_tool/2, fetch_tool!/2        # delegate to Toolset.fetch/2, fetch!/2 (3.4a)
BaseAgent.fetch_context_provider/2, fetch_context_provider!/2
AgentMemory.fetch_entry/2, fetch_entry!/2
Normandy.TurnNotFoundError, Normandy.ContextProviderNotFoundError (replace NonExistentTurn, NonExistentContextProvider)
SharedContext.fetch/2, StatefulContext.fetch/2, AgentSupervisor.fetch_agent/2   # 3.6b
```

## Rulings made while writing this plan (Q may override)

1. **`circuit_breaker` name collision.** Today `BaseAgentConfig.circuit_breaker` is the breaker pid. The 2.0 option `circuit_breaker:` is a keyword list, so the pid field becomes `circuit_breaker_pid` (node-local, supplied on rebuild, never persisted) until Wave 4 replaces it with a registry key. Cost if wrong: one more field rename in Wave 4.
2. **NimbleOptions errors become `ArgumentError`.** NimbleOptions raises `NimbleOptions.ValidationError` without the function name; `Normandy.Options.validate!/3` re-raises `ArgumentError` with the `Mod.fun/n:` prefix. Cost if wrong: callers rescuing `NimbleOptions.ValidationError` (none in lib or test).
3. **A derived encoder still decides a schema's fields.** `Normandy.JSON` encodes a struct with its own `Jason.Encoder` impl through that impl, so `@derive {Jason.Encoder, only: ...}` keeps working and the `io_schema_json_test.exs` "a derived encoder still decides the fields" test keeps its meaning (switched from Poison to Jason). `tool_result.ex`'s `rescue _ -> inspect` fallback is removed. Cost if wrong: none for users who don't derive.
4. **Example tools.** `Calculator`, `StringManipulator`, `EnhancedCalculator` and `ListProcessor` move to `test/support/tools/` (tests use them) and keep their `Normandy.Tools.Examples.*` module names (Task 3.4 names them throughout); `Weather` (live HTTP) moves to `examples/tools/weather.ex` and its tests move out of the default suite. The `base_agent.ex` doc example stops naming them.
5. **The 1.x tool guard lives at registration.** Templates persist no tool data (`rebuild/3` takes the toolset from the node-local supplement), so the "1.x template referencing a removed tool module" check is in `Toolset.register/3` and in `rebuild/3`'s supplement check: a struct whose module does not implement `Normandy.Tool` raises `ArgumentError` naming the module and pointing at `MIGRATING-2.0.md §25`. `rebuild/3` also refuses a supplement still keyed `:tool_registry`.
6. **The `Keyword.get(opts` acceptance grep is an allowlist test.** `test/options_coverage_test.exs` lists the files whose remaining `Keyword.get(opts` reads are internal (with a reason each) and fails when a new file appears.
7. **Turn.Server start options.** `Turn.Server` validates its options in `start_link/1` in the caller's process (so an `ArgumentError` raises in the caller) and still accepts `:name`, which the supervisors inject. `Turn.Supervisor.start_server/2` and `Turn.Supervisor.Horde.start_server/2` also validate `server_opts` against `Turn.Server`'s schema in the caller, naming themselves, before `start_child` (otherwise the raise happens inside the supervisor and comes back as `{:error, {%ArgumentError{}, stacktrace}}`) (Task 3.7a).

## Review Focus

1. **A v1.0.0 session template rebuilt under 2.0** (with `max_tokens: nil`, `session_store`/`session_registry` in `behaviours_refs`, a compactor `{mod, [max_tokens: n]}`). Expect a working config with 2.0 defaults; any field the translation cannot handle raises `ArgumentError` naming it — never a crash deep in a turn. Test: Task 3.2.
2. **Model input that names a tool's config field** (`{"query": "x", "endpoint": "evil", "timeout": "x"}` to a tool `defstruct [:endpoint, timeout: 5_000]` with input `{query}`). Expect the struct unchanged, an `is_error: true` tool_result naming the unknown keys, the turn continues, the registration timeout applies — under `run/2`, `stream/3` and `Turn.Server`. Test: Task 3.4c.
3. **A misspelled option to a process entry point** (`Turn.Server.start_link(approval_timout_ms: 1)`, `AgentPool.start_link(sise: 3)`). Expect an `ArgumentError` in the caller naming `Module.function/arity` and the key, never a supervisor `{:error, ...}` or a crash in `init/1`. Test: Tasks 3.7a/3.7b.
4. **A struct that Jason has no encoder for** inside a tool result, memory dump or context-window estimate. Expect it encoded as its map (minus `__meta__`), never `Protocol.UndefinedError` and never `inspect/1` output sent to the model. Test: Task 3.3.
5. **A secret passed under a misspelled key** (`init(%{model: "m", client: c, api_kye: "sk-..."})`). Expect the error to name `:api_kye` and not to contain `"sk-"`. Test: Task 3.1.

---

### Task 3.1a: `Normandy.Options` and the NimbleOptions dependency (decision 9)

**Files:**
- Modify: `mix.exs:170-176` (`deps/0`)
- Create: `lib/normandy/options.ex`
- Test: `test/options_test.exs` (new)

**Interfaces:**
- Consumes: `NimbleOptions` 1.1.1 (already in `mix.lock:42` as a transitive dep of finch and
  redix), `Normandy.Components.ContentBlock.Describe.type_of/1`.
- Produces (header names):
  - `Normandy.Options.validate!(opts :: keyword() | map(), schema :: NimbleOptions.t(),
    mfa :: {module(), atom(), arity()}) :: keyword()`: defaults filled; raises `ArgumentError`
    prefixed `"Mod.fun/arity: "`.
  - `Normandy.Options.docs(schema :: NimbleOptions.t()) :: String.t()`.
  - `Normandy.Options.sensitive_keys() :: [atom()]` (see Header conflict 2).
  - `Normandy.Options.plain_map(term()) :: {:ok, map()} | {:error, String.t()}` (`@doc false`):
    the one NimbleOptions custom type for a plain map, `{:custom, Normandy.Options, :plain_map,
    []}` (decision 18), used by Task 3.1b's `:tool_context` and Tasks 3.7a–d. Error (exact):
    `"expected a plain map (not a struct), got: <Describe.type_of/1>"`, e.g. `"... got: a
    %URI{}"`, `"... got: a list"`, `"... got: a string (4 bytes)"`. (Of the two messages earlier
    drafts of this plan had, this one says what was expected, that a struct does not count, and what was
    received; "a map of plain data" promised a check of the contents that nothing makes.)
  - Message shapes later tasks may assert:
    - unknown: `"M.f/1: unknown option :x; supported: :a, :b"` (several:
      `"unknown options [:x, :y]; supported: ..."`; nested:
      `"unknown option :x in :parent; supported: ..."`)
    - sensitive: `"M.f/1: invalid value for :client option: expected <type_doc>; the value is
      not shown because :client can hold a secret"`
    - everything else: NimbleOptions' own message after the prefix, e.g.
      `"M.f/1: invalid value for :n option: expected positive integer, got: 0"`
    - shape: `"M.f/1: expected options as a keyword list or a map, got ..."`,
      `"M.f/1: option names must be atoms, got: [\"model\"]"`,
      `"M.f/1: option :model given more than once"`.

- [ ] **Step 1: Add the dependency**

In `mix.exs` `deps/0`, after `{:jason, "~> 1.4"},` add:

```elixir
      # Option schemas for every public entry point (Normandy.Options).
      {:nimble_options, "~> 1.1"},
```

Run: `mix deps.get && mix deps.unlock --check-unused`
Expected: exit 0 and `mix.lock` unchanged (it already locks 1.1.1; verified on a scratch copy).

- [ ] **Step 2: Write the failing tests**

Create `test/options_test.exs`:

```elixir
defmodule Normandy.OptionsTest do
  use ExUnit.Case, async: true

  alias Normandy.Options

  @mfa {Normandy.Agents.BaseAgent, :init, 1}

  @schema NimbleOptions.new!(
            model: [type: :string, required: true, doc: "The model."],
            count: [type: :pos_integer, default: 3, doc: "A count."],
            client: [type: {:struct, URI}, type_doc: "a `URI` struct", doc: "A client."],
            transport: [
              type: :keyword_list,
              default: [],
              keys: [
                headers: [type: :keyword_list, type_doc: "a keyword list", doc: "Headers."],
                pool: [type: :pos_integer, default: 1, doc: "Pool size."]
              ],
              doc: "Transport."
            ]
          )

  describe "validate!/3" do
    test "returns a keyword list with the defaults filled in" do
      assert Options.validate!([model: "m"], @schema, @mfa) |> Enum.sort() ==
               [count: 3, model: "m", transport: [pool: 1]]
    end

    test "accepts a map with atom keys and returns a keyword list" do
      validated = Options.validate!(%{model: "m", count: 5}, @schema, @mfa)

      assert Keyword.keyword?(validated)
      assert Keyword.fetch!(validated, :count) == 5
    end

    test "an unknown option is named, with the supported ones" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown option :modle; supported: " <>
                     ":model, :count, :client, :transport",
                   fn -> Options.validate!([model: "m", modle: "x"], @schema, @mfa) end
    end

    test "several unknown options are named together" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown options [:a, :b]; supported: " <>
                     ":model, :count, :client, :transport",
                   fn -> Options.validate!([model: "m", a: 1, b: 2], @schema, @mfa) end
    end

    test "an unknown nested option names its parent and the parent's options" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown option :poool in :transport; " <>
                     "supported: :headers, :pool",
                   fn -> Options.validate!([model: "m", transport: [poool: 2]], @schema, @mfa) end
    end

    test "an unknown option's value is never shown" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!([model: "m", api_kye: "sk-ant-canary"], @schema, @mfa)
        end

      assert error.message =~ ":api_kye"
      refute error.message =~ "sk-ant-canary"
    end

    test "a bad value of an ordinary option keeps NimbleOptions' message" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: invalid value for :count option: " <>
                     "expected positive integer, got: 0",
                   fn -> Options.validate!([model: "m", count: 0], @schema, @mfa) end
    end

    test "a missing required option is named" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: required :model option not found, " <>
                     "received options: [:count]",
                   fn -> Options.validate!([count: 1], @schema, @mfa) end
    end

    test "a sensitive option's bad value is not shown; its type_doc is" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!([model: "m", client: "sk-ant-canary"], @schema, @mfa)
        end

      assert error.message ==
               "Normandy.Agents.BaseAgent.init/1: invalid value for :client option: expected " <>
                 "a `URI` struct; the value is not shown because :client can hold a secret"
    end

    test "a sensitive option nested under another is not shown either" do
      error =
        assert_raise ArgumentError, fn ->
          Options.validate!(
            [model: "m", transport: [headers: "Bearer sk-ant-canary"]],
            @schema,
            @mfa
          )
        end

      assert error.message =~ ":headers option in :transport"
      refute error.message =~ "sk-ant-canary"
    end

    test "a list that is not a keyword list is rejected by position" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: expected options as a keyword list or a " <>
                     "map, got a list whose element 1 is an integer",
                   fn -> Options.validate!([{:model, "m"}, 2], @schema, @mfa) end
    end

    test "a struct is not an options map" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: expected options as a keyword list or a " <>
                     "map, got a %URI{} struct",
                   fn -> Options.validate!(%URI{}, @schema, @mfa) end
    end

    test "string keys are rejected, naming them" do
      assert_raise ArgumentError,
                   ~s(Normandy.Agents.BaseAgent.init/1: option names must be atoms, got: ["model"]),
                   fn -> Options.validate!(%{"model" => "m"}, @schema, @mfa) end
    end

    test "a value that is neither a list nor a map is rejected" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: expected options as a keyword list or a " <>
                     "map, got a string (2 bytes)",
                   fn -> Options.validate!("hi", @schema, @mfa) end
    end

    test "a duplicated option is rejected" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: option :model given more than once",
                   fn -> Options.validate!([model: "a", model: "b"], @schema, @mfa) end
    end

    test "the prefix names any module, function and arity" do
      assert_raise ArgumentError, ~r/^Normandy.Agents.Turn.Server.start_link\/1: /, fn ->
        Options.validate!([x: 1], @schema, {Normandy.Agents.Turn.Server, :start_link, 1})
      end
    end
  end

  test "docs/1 is NimbleOptions' option list" do
    assert Options.docs(@schema) == NimbleOptions.docs(@schema)
    assert Options.docs(@schema) =~ "* `:model` (`t:String.t/0`) - Required. The model."
  end

  test "sensitive_keys/0 names the credential-carrying options" do
    assert :client in Options.sensitive_keys()
    assert :api_key in Options.sensitive_keys()
    assert :mcp_servers in Options.sensitive_keys()
  end

  test "plain_map/1 accepts a plain map and names the type of anything else" do
    assert {:ok, %{a: 1}} = Options.plain_map(%{a: 1})

    assert {:error, "expected a plain map (not a struct), got: a %URI{}"} =
             Options.plain_map(%URI{})

    assert {:error, "expected a plain map (not a struct), got: a list"} = Options.plain_map(a: 1)

    assert {:error, "expected a plain map (not a struct), got: a string (4 bytes)"} =
             Options.plain_map("acme")
  end
end
```

- [ ] **Step 3: Run to verify they fail**

Run: `mix test test/options_test.exs`
Expected: FAIL to compile, `Normandy.Options.validate!/3 is undefined (module Normandy.Options
is not available)`.

- [ ] **Step 4: Implement**

Create `lib/normandy/options.ex`:

```elixir
defmodule Normandy.Options do
  @moduledoc """
  Option validation for Normandy's public entry points.

  An entry point keeps a `NimbleOptions` schema and calls `validate!/3` with its own
  `{module, function, arity}`. Options may be a keyword list or a map with atom keys. Any
  problem raises `ArgumentError` whose message starts with `Module.function/arity:` and
  names the option:

      Normandy.Agents.BaseAgent.init/1: unknown option :api_kye; supported: :client, :model, ...

  The value of an option named in `sensitive_keys/0`, or nested under one, never appears in
  a message: the message names the option and shows its `:type_doc` instead. Give every such
  option a `:type_doc` in its schema.
  """

  alias NimbleOptions.ValidationError
  alias Normandy.Components.ContentBlock.Describe

  @sensitive_keys [
    :api_key,
    :authorization,
    :client,
    :credential,
    :headers,
    :mcp_servers,
    :password,
    :req_options,
    :secret,
    :token
  ]

  @doc "Option names whose values are never shown in an error message."
  @spec sensitive_keys() :: [atom()]
  def sensitive_keys, do: @sensitive_keys

  @doc """
  Validates `opts` against `schema` and returns them as a keyword list with the schema's
  defaults filled in.

  Raises `ArgumentError` prefixed with `Module.function/arity:` (from `mfa`) for an unknown
  or duplicated option, a missing required one, a bad value, or `opts` that are neither a
  keyword list nor a map with atom keys.
  """
  @spec validate!(keyword() | map(), NimbleOptions.t(), {module(), atom(), arity()}) ::
          keyword()
  def validate!(opts, %NimbleOptions{} = schema, {mod, fun, arity})
      when is_atom(mod) and is_atom(fun) and is_integer(arity) and arity >= 0 do
    prefix = "#{inspect(mod)}.#{fun}/#{arity}"
    opts = to_keyword!(opts, prefix)
    :ok = check_duplicates!(opts, prefix)

    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} ->
        validated

      {:error, %ValidationError{} = error} ->
        raise ArgumentError, "#{prefix}: #{describe(error, schema)}"
    end
  end

  @doc "The Markdown option list for `schema`, to embed in an `@doc`."
  @spec docs(NimbleOptions.t()) :: String.t()
  def docs(%NimbleOptions{} = schema), do: NimbleOptions.docs(schema)

  @doc false
  # A NimbleOptions custom type: `{:custom, Normandy.Options, :plain_map, []}`. NimbleOptions'
  # own :map and {:map, k, v} raise Protocol.UndefinedError when given a struct. It names the
  # type, never the value.
  @spec plain_map(term()) :: {:ok, map()} | {:error, String.t()}
  def plain_map(value) when is_map(value) and not is_struct(value), do: {:ok, value}

  def plain_map(value),
    do: {:error, "expected a plain map (not a struct), got: #{Describe.type_of(value)}"}

  defp to_keyword!(opts, prefix) when is_list(opts) do
    case Enum.find_index(opts, &(not keyword_entry?(&1))) do
      nil ->
        opts

      index ->
        raise ArgumentError,
              "#{prefix}: expected options as a keyword list or a map, got a list whose " <>
                "element #{index} is #{Describe.type_of(Enum.at(opts, index))}"
    end
  end

  defp to_keyword!(%mod{}, prefix) do
    raise ArgumentError,
          "#{prefix}: expected options as a keyword list or a map, got a " <>
            "%#{inspect(mod)}{} struct"
  end

  defp to_keyword!(opts, prefix) when is_map(opts) do
    case Enum.reject(Map.keys(opts), &is_atom/1) do
      [] -> Map.to_list(opts)
      keys -> raise ArgumentError, "#{prefix}: option names must be atoms, got: #{inspect(keys)}"
    end
  end

  defp to_keyword!(other, prefix) do
    raise ArgumentError,
          "#{prefix}: expected options as a keyword list or a map, got " <>
            Describe.type_of(other)
  end

  defp keyword_entry?({key, _value}) when is_atom(key), do: true
  defp keyword_entry?(_entry), do: false

  defp check_duplicates!(opts, prefix) do
    keys = Keyword.keys(opts)

    case Enum.uniq(keys -- Enum.uniq(keys)) do
      [] -> :ok
      dups -> raise ArgumentError, "#{prefix}: #{option_names(dups)} given more than once"
    end
  end

  # NimbleOptions reports unknown options with the list of them in :key.
  defp describe(%ValidationError{key: keys, keys_path: path}, schema) when is_list(keys) do
    supported = schema.schema |> definition_at(path) |> Keyword.keys()

    "unknown #{option_names(keys)}#{under(path)}; supported: " <>
      Enum.map_join(supported, ", ", &inspect/1)
  end

  defp describe(%ValidationError{key: key, keys_path: path, value: value} = error, schema) do
    if value != nil and Enum.any?([key | path], &(&1 in @sensitive_keys)) do
      spec = schema.schema |> definition_at(path) |> Keyword.get(key, [])
      expected = Keyword.get(spec, :type_doc) || inspect(Keyword.get(spec, :type))

      "invalid value for #{inspect(key)} option#{under(path)}: expected #{expected}; " <>
        "the value is not shown because #{inspect(key)} can hold a secret"
    else
      Exception.message(error)
    end
  end

  defp definition_at(definition, []), do: definition

  defp definition_at(definition, [key | rest]),
    do: definition |> Keyword.fetch!(key) |> Keyword.fetch!(:keys) |> definition_at(rest)

  defp option_names([key]), do: "option #{inspect(key)}"
  defp option_names(keys), do: "options #{inspect(keys)}"

  defp under([]), do: ""
  defp under(path), do: " in #{Enum.map_join(path, ".", &inspect/1)}"
end
```

(Verified against NimbleOptions 1.1.1 with a scratch copy of this module: the unknown-key,
nested-unknown, sensitive and duplicate messages above are what it produces.)

- [ ] **Step 5: Run to verify they pass**

Run: `mix test test/options_test.exs`
Expected: PASS, 19 tests, 0 failures.

- [ ] **Step 6: Format, full suite**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures` (2710 tests on the scratch copy, rehearsed before `plain_map/1`'s test
moved here from Task 3.7a; expect 2711. Later rehearsed totals predate decision 18 too: add
one from here on, two from Task 3.1c (`NoModelAgent`), and Task 3.4b's tests as it lists them).

Run: `mix dialyzer`. Expected: one new warning, `lib/normandy/options.ex:<line>:guard_fail ...
is_list(_keys :: atom()) can never succeed`. It is a false positive: `NimbleOptions.ValidationError`
types `:key` as `atom()` (`deps/nimble_options/lib/nimble_options/validation_error.ex:12`), but
`validate_unknown_options/2` (`nimble_options.ex:516-529`) puts the list of unknown keys there,
and the tests above exercise that clause. Add to `.dialyzer_ignore.exs` under
`# --- Tooling false positives ---`:

```elixir
  # options.ex describe/2: NimbleOptions.ValidationError types :key as atom(), but an
  # unknown-option error puts the list of unknown keys there (nimble_options 1.1.1,
  # validate_unknown_options/2), so the is_list/1 guard Dialyzer calls impossible is the
  # clause that formats "unknown option :x; supported: ...". Covered by test/options_test.exs.
  {"lib/normandy/options.ex", :guard_fail},
```

Run `mix dialyzer` again: "done (passed successfully)", 0 unnecessary skips (verified).

No MIGRATING text: nothing user-visible yet (§21 is written by Task 3.1b).

- [ ] **Step 7: Commit**

```bash
git add mix.exs lib/normandy/options.ex test/options_test.exs .dialyzer_ignore.exs
git commit -m "feat(options): Normandy.Options validates entry-point options with NimbleOptions"
```

---
### Task 3.1b: A strict `BaseAgent.init/1` (DX-6) and `run/3`'s option check

**Files:**
- Create: `lib/normandy/agents/base_agent/init_options.ex` (the schema, shared with Task 3.1c)
- Modify: `lib/normandy/agents/base_agent.ex`: aliases (`:15-52`), `@type config_input` and
  `init/1` (`:55-184`), `max_tokens!/1` (`:252-266`), `normalize_max_tool_iterations/1`
  (`:268-279`), `run/3` (`:461-466`), `run!/3` (`:473-481`), `check_run_opts!/1` (`:483-496`)
- Modify: `MIGRATING-2.0.md` (new §21 before `## New, non-breaking`), `CLAUDE.md:54`
- Test: `test/agents/base_agent_init_options_test.exs` (new), `test/agents/base_agent_stream_test.exs`,
  and the message rewrites in Step 6

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`, `docs/1`, `plain_map/1` (Task 3.1a; the
  `:tool_context` type); `Retry.validate_options!/1`.
- Produces:
  - `BaseAgent.init(opts :: keyword() | map()) :: BaseAgentConfig.t()`; option list in its docs.
  - `Normandy.Agents.BaseAgent.InitOptions` (`@moduledoc false`, used by Tasks 3.1c, 3.2b,
    3.2c): `definition/0 :: keyword()` (the NimbleOptions definition, plain data),
    `schema/0 :: NimbleOptions.t()`, `validate!/1` (init's whole check),
    `check_misnamed!(opts, schema, mfa) :: :ok` (hint keys the given schema does not accept),
    `without_defaults(definition) :: keyword()` (recursive; drops `:default`, sets
    `required: false`).
  - Messages (exact): `"Normandy.Agents.BaseAgent.init/1: requires :model (a string), got
    none"` (decision 18: the same prefix as every other init/1 message); `"Normandy.Agents.BaseAgent.init/1: unknown option :system_prompt; the system
    prompt goes in :prompt_specification (a %Normandy.Components.PromptSpecification{});
    supported: :client, :model, ..."`; same shape for `:tools` and `:max_messages`;
    `"Normandy.Agents.BaseAgent.run/3: unknown option :max_turns; run/3 takes no options"`
    (`run!/3` names itself).
  - Behaviour kept: `max_tool_concurrency` below 1 still counts as 1; `nil` input/output schema,
    memory and prompt specification still mean the defaults; `enable_json_retry` defaults to
    `true`.
  - Behaviour changed: every check runs before `CircuitBreaker.start_link/1` (today
    `max_tokens!`/`normalize_max_tool_iterations` run after it and leak a linked breaker,
    base_agent.ex:143-171); `circuit_breaker_options` accepts only `:failure_threshold`,
    `:success_threshold`, `:timeout`, `:half_open_max_calls` (`:name` is gone: a registered
    name made a second `init/1` crash with a `MatchError` on `{:error, {:already_started, _}}`).

- [ ] **Step 1: Write the failing tests**

Create `test/agents/base_agent_init_options_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentInitOptionsTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.InitOptions
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Test.StubClient

  @supported Enum.map_join(Keyword.keys(InitOptions.definition()), ", ", &inspect/1)

  defp client, do: %StubClient{}

  test "a keyword list works like a map" do
    from_keyword = BaseAgent.init(model: "m", client: client())
    from_map = BaseAgent.init(%{model: "m", client: client()})

    assert %BaseAgentConfig{model: "m", max_tokens: 16_000} = from_keyword
    assert from_keyword == from_map
  end

  test "the supported list starts with the required options" do
    assert String.starts_with?(@supported, ":client, :model, ")
  end

  test "an unknown option raises, naming it and the supported ones" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :temprature; supported: " <>
                   @supported,
                 fn -> BaseAgent.init(model: "m", client: client(), temprature: 0.2) end
  end

  test ":system_prompt points at :prompt_specification" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :system_prompt; the system " <>
                   "prompt goes in :prompt_specification (a " <>
                   "%Normandy.Components.PromptSpecification{}); supported: " <> @supported,
                 fn ->
                   BaseAgent.init(model: "m", client: client(), system_prompt: "Be brief.")
                 end
  end

  test ":tools points at the tool registry" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :tools; tools go in " <>
                   ":tool_registry (Normandy.Tools.Registry.new([tool, ...])) or are added " <>
                   "after init with BaseAgent.register_tool/2; supported: " <> @supported,
                 fn -> BaseAgent.init(model: "m", client: client(), tools: []) end
  end

  test ":max_messages points at the memory" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :max_messages; cap the " <>
                   "memory with memory: Normandy.Components.AgentMemory.new_memory(max_messages); " <>
                   "supported: " <> @supported,
                 fn -> BaseAgent.init(model: "m", client: client(), max_messages: 10) end
  end

  test "a missing or nil :model raises, naming init/1" do
    for opts <- [[client: client()], [client: client(), model: nil], %{client: client()}] do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none",
                   fn -> BaseAgent.init(opts) end
    end
  end

  test "a missing :client is named" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: required :client option not found, " <>
                   "received options: [:model]",
                 fn -> BaseAgent.init(model: "m") end
  end

  # Review Focus #5.
  test "a secret under a misspelled key is named, never shown" do
    error =
      assert_raise ArgumentError, fn ->
        BaseAgent.init(%{model: "m", client: client(), api_kye: "sk-ant-api03-canary"})
      end

    assert error.message =~ "unknown option :api_kye"
    refute error.message =~ "sk-"
  end

  test "a secret passed as the client is never shown" do
    error =
      assert_raise ArgumentError, fn ->
        BaseAgent.init(model: "m", client: "sk-ant-api03-canary")
      end

    assert error.message ==
             "Normandy.Agents.BaseAgent.init/1: invalid value for :client option: expected a " <>
               "struct implementing `Normandy.Agents.Model`; the value is not shown because " <>
               ":client can hold a secret"
  end

  test ":session_id is an option" do
    assert BaseAgent.init(model: "m", client: client(), session_id: "s-1").session_id == "s-1"
  end

  test "a list that is not a keyword list is rejected" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: expected options as a keyword list or a " <>
                   "map, got a list whose element 0 is an integer",
                 fn -> BaseAgent.init([1, 2]) end
  end

  test "every option is checked before the circuit breaker starts" do
    {:links, before} = Process.info(self(), :links)

    assert_raise ArgumentError, ~r/:max_tool_iterations option/, fn ->
      BaseAgent.init(
        model: "m",
        client: client(),
        enable_circuit_breaker: true,
        max_tool_iterations: 0
      )
    end

    assert Process.info(self(), :links) == {:links, before}
  end

  test "an unknown circuit breaker option is named" do
    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.init/1: unknown option :error_threshold in " <>
                   ":circuit_breaker_options; supported: :failure_threshold, " <>
                   ":success_threshold, :timeout, :half_open_max_calls",
                 fn ->
                   BaseAgent.init(
                     model: "m",
                     client: client(),
                     circuit_breaker_options: [error_threshold: 3]
                   )
                 end
  end

  test "init/1's docs list its options" do
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(BaseAgent)

    assert [%{"en" => doc}] =
             for({{:function, :init, 1}, _, _, doc, _} <- docs, do: doc)

    assert doc =~ "* `:model` (`t:String.t/0`) - Required."
    assert doc =~ "* `:session_id`"
    assert doc =~ "The default value is `16000`."
  end
end
```

In `test/agents/base_agent_stream_test.exs`, replace line 268

```elixir
    assert error.message =~ "unknown options [:max_turns]"
```

with

```elixir
    assert error.message ==
             "Normandy.Agents.BaseAgent.run!/3: unknown option :max_turns; run!/3 takes no options"
```

and add after the test `"run/3 rejects the old streaming options with a stream/3 hint"`
(ends at `:278`):

```elixir

  test "run/3 and run!/3 name themselves and reject options that are not a keyword list" do
    agent = agent(%ScriptedTextClient{text: "x"})

    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.run/3: unknown option :max_turns; run/3 takes no options",
                 fn -> BaseAgent.run(agent, "hi", max_turns: 2) end

    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.run/3: expected options as a keyword list, got a " <>
                   "list that is not one; run/3 takes no options",
                 fn -> BaseAgent.run(agent, "hi", [1, 2]) end

    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.run!/3: expected options as a keyword list, got " <>
                   ":fast; run!/3 takes no options",
                 fn -> BaseAgent.run!(agent, "hi", :fast) end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/base_agent_init_options_test.exs test/agents/base_agent_stream_test.exs`
Expected: FAIL to compile (`Normandy.Agents.BaseAgent.InitOptions.definition/0 is undefined`).
After Step 3 alone (before Step 4) the init tests fail on the messages; that is the point of
running them again in Step 5.

- [ ] **Step 3: Create the schema module**

Create `lib/normandy/agents/base_agent/init_options.ex`:

```elixir
defmodule Normandy.Agents.BaseAgent.InitOptions do
  @moduledoc false
  # The `BaseAgent.init/1` option schema, its custom checks, and hints for option names a
  # caller might reasonably try. `Normandy.DSL.Agent`'s generated `new/1` uses the same
  # definition (without defaults), so both entry points accept the same options.

  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Options
  alias Normandy.Resilience.Retry

  @guard_spec {:or, [:atom, {:tuple, [:atom, :keyword_list]}]}

  @definition [
    client: [
      type: {:custom, __MODULE__, :client, []},
      required: true,
      type_doc: "a struct implementing `Normandy.Agents.Model`",
      doc: "The LLM client, for example a `Normandy.LLM.ClaudioAdapter`."
    ],
    model: [type: :string, required: true, doc: "The model id sent with every request."],
    temperature: [
      type: {:or, [:float, :integer, nil]},
      default: nil,
      type_doc: "`t:number/0` or `nil`",
      doc: "Sampling temperature. `nil` leaves it out of the request (Opus 4.7+ reject it)."
    ],
    max_tokens: [
      type: {:custom, __MODULE__, :max_tokens, []},
      default: BaseAgentConfig.default_max_tokens(),
      type_doc: "`t:pos_integer/0`",
      doc: "The answer's token limit; the Messages API requires one."
    ],
    input_schema: [
      type: {:custom, __MODULE__, :struct_or_nil, []},
      default: nil,
      type_doc: "an `io_schema` struct or `nil`",
      doc: "The input schema; `nil` is `Normandy.Agents.BaseAgentInputSchema`."
    ],
    output_schema: [
      type: {:custom, __MODULE__, :struct_or_nil, []},
      default: nil,
      type_doc: "an `io_schema` struct or `nil`",
      doc: "The output schema; `nil` is `Normandy.Agents.BaseAgentOutputSchema`."
    ],
    memory: [
      type: {:or, [{:struct, Normandy.Components.AgentMemory}, nil]},
      default: nil,
      type_doc: "a `Normandy.Components.AgentMemory` or `nil`",
      doc: "The starting memory, also what `reset_memory/1` restores; `nil` is empty."
    ],
    prompt_specification: [
      type: {:or, [{:struct, Normandy.Components.PromptSpecification}, nil]},
      default: nil,
      type_doc: "a `Normandy.Components.PromptSpecification` or `nil`",
      doc: "The system prompt's sections; `nil` is an empty specification."
    ],
    tool_registry: [
      type: {:or, [{:struct, Normandy.Tools.Registry}, nil]},
      default: nil,
      type_doc: "a `Normandy.Tools.Registry` or `nil`",
      doc: "The agent's tools."
    ],
    max_tool_iterations: [type: :pos_integer, default: 5, doc: "Tool rounds per turn."],
    max_tool_concurrency: [
      type: {:custom, __MODULE__, :max_tool_concurrency, []},
      default: 1,
      type_doc: "`t:integer/0`",
      doc: "Tool calls run at once; a value below 1 counts as 1."
    ],
    retry_options: [
      type: {:custom, __MODULE__, :retry, []},
      default: nil,
      type_doc: "`t:keyword/0` or `nil`",
      doc: "`Normandy.Resilience.Retry` options for LLM calls; `nil` makes one attempt."
    ],
    enable_circuit_breaker: [
      type: :boolean,
      default: false,
      doc: "Starts a `Normandy.Resilience.CircuitBreaker` linked to the caller."
    ],
    circuit_breaker_options: [
      type: :keyword_list,
      default: [],
      keys: [
        failure_threshold: [type: :pos_integer, doc: "Failures before it opens."],
        success_threshold: [type: :pos_integer, doc: "Successes that close it from half-open."],
        timeout: [type: :pos_integer, doc: "Milliseconds open before half-open."],
        half_open_max_calls: [type: :pos_integer, doc: "Calls let through when half-open."]
      ],
      doc: "The circuit breaker's options."
    ],
    enable_json_retry: [
      type: :boolean,
      default: true,
      doc: "Asks the model again when its JSON does not parse."
    ],
    json_retry_max_attempts: [type: :pos_integer, default: 2, doc: "JSON re-asks per call."],
    input_guardrails: [
      type: {:list, @guard_spec},
      default: [],
      doc: "Guards for the input (`Normandy.Guardrails`)."
    ],
    output_guardrails: [
      type: {:list, @guard_spec},
      default: [],
      doc: "Guards for the answer (`Normandy.Guardrails`)."
    ],
    output_guardrails_streaming_mode: [
      type: {:in, [:accumulate, :incremental]},
      default: :accumulate,
      doc: "When `stream/3` checks the output guards."
    ],
    output_guardrails_chunk_size: [
      type: :pos_integer,
      default: 200,
      doc: "Bytes of streamed text between incremental checks."
    ],
    output_guardrails_on_violation: [
      type: {:in, [:block, :warn]},
      default: :block,
      doc: "What an output violation does."
    ],
    name: [type: {:or, [:string, nil]}, default: nil, doc: "The agent's name."],
    session_id: [
      type: {:or, [:string, nil]},
      default: nil,
      doc: "The session id put on telemetry and tool contexts."
    ],
    behaviours: [
      type: {:or, [{:struct, Normandy.Behaviours.Config}, nil]},
      default: nil,
      type_doc: "a `Normandy.Behaviours.Config` or `nil`",
      doc: "Pluggable behaviours and hooks; `nil` is the default bundle."
    ],
    mcp_servers: [
      type: {:or, [{:list, :any}, nil]},
      default: nil,
      type_doc: "a list of MCP server configs or `nil`",
      doc: "MCP servers whose tools the agent may call."
    ],
    tool_context: [
      type: {:custom, Normandy.Options, :plain_map, []},
      default: %{},
      type_doc: "`t:map/0`",
      doc: "Plain data handed to tools; persisted in session templates, so no secrets."
    ]
  ]

  @schema NimbleOptions.new!(@definition)

  # Option names callers try that are not init/1 options, with where the setting lives.
  @hints [
    system_prompt:
      "the system prompt goes in :prompt_specification (a %Normandy.Components.PromptSpecification{})",
    tools:
      "tools go in :tool_registry (Normandy.Tools.Registry.new([tool, ...])) or are added " <>
        "after init with BaseAgent.register_tool/2",
    max_messages:
      "cap the memory with memory: Normandy.Components.AgentMemory.new_memory(max_messages)"
  ]

  @init {Normandy.Agents.BaseAgent, :init, 1}

  @doc false
  @spec definition() :: keyword()
  def definition, do: @definition

  @doc false
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc false
  # Checks `BaseAgent.init/1`'s options: misnamed keys, then :model, then the schema.
  @spec validate!(keyword() | map()) :: keyword()
  def validate!(opts) do
    :ok = check_misnamed!(opts, @schema, @init)

    if model_missing?(opts) do
      raise ArgumentError,
            "Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"
    end

    Options.validate!(opts, @schema, @init)
  end

  @doc false
  # Raises for a key in @hints that `schema` does not itself accept, naming the key, where
  # the setting lives, and `schema`'s options.
  @spec check_misnamed!(term(), NimbleOptions.t(), {module(), atom(), arity()}) :: :ok
  def check_misnamed!(opts, %NimbleOptions{} = schema, {mod, fun, arity}) do
    keys = option_keys(opts)
    supported = Keyword.keys(schema.schema)

    case Enum.find(@hints, fn {key, _hint} -> key in keys and key not in supported end) do
      nil ->
        :ok

      {key, hint} ->
        raise ArgumentError,
              "#{inspect(mod)}.#{fun}/#{arity}: unknown option #{inspect(key)}; #{hint}; " <>
                "supported: #{Enum.map_join(supported, ", ", &inspect/1)}"
    end
  end

  @doc false
  # The definition with no defaults and nothing required, at every level: for an entry
  # point (DSL new/1) where an option left out keeps a value declared elsewhere.
  @spec without_defaults(keyword()) :: keyword()
  def without_defaults(definition) do
    Enum.map(definition, fn {key, spec} ->
      spec =
        spec
        |> Keyword.delete(:default)
        |> Keyword.put(:required, false)

      spec =
        if Keyword.has_key?(spec, :keys),
          do: Keyword.update!(spec, :keys, &without_defaults/1),
          else: spec

      {key, spec}
    end)
  end

  # Malformed options are Options.validate!/3's to report; here they just have no keys.
  defp option_keys(%_{}), do: []
  defp option_keys(opts) when is_map(opts), do: Map.keys(opts)
  defp option_keys(opts) when is_list(opts), do: for({key, _value} <- opts, do: key)
  defp option_keys(_opts), do: []

  defp model_missing?(%_{}), do: false

  defp model_missing?(opts) when is_map(opts),
    do: Enum.all?(Map.keys(opts), &is_atom/1) and Map.get(opts, :model) == nil

  defp model_missing?(opts) when is_list(opts),
    do: Keyword.keyword?(opts) and Keyword.get(opts, :model) == nil

  defp model_missing?(_opts), do: false

  @doc false
  def client(%_{} = client), do: {:ok, client}
  def client(other), do: {:error, "expected a client struct, got #{Describe.type_of(other)}"}

  @doc false
  def max_tokens(n) when is_integer(n) and n > 0, do: {:ok, n}

  def max_tokens(other) do
    {:error,
     "expected a positive integer (the Messages API requires it), got: #{inspect(other)}. " <>
       "Omit it to use the default of #{BaseAgentConfig.default_max_tokens()}."}
  end

  @doc false
  def struct_or_nil(nil), do: {:ok, nil}
  def struct_or_nil(%_{} = schema), do: {:ok, schema}

  def struct_or_nil(other),
    do: {:error, "expected a schema struct or nil, got #{Describe.type_of(other)}"}

  @doc false
  def max_tool_concurrency(n) when is_integer(n), do: {:ok, max(n, 1)}
  def max_tool_concurrency(other), do: {:error, "expected an integer, got: #{inspect(other)}"}

  @doc false
  # Retry checks its own options (Retry.validate_options!/1); its ArgumentError becomes
  # this option's error so the message carries init/1's prefix.
  def retry(nil), do: {:ok, nil}

  def retry(opts) when is_list(opts) do
    :ok = Retry.validate_options!(opts)
    {:ok, opts}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def retry(other),
    do: {:error, "expected a keyword list or nil, got #{Describe.type_of(other)}"}
end
```

`tool_context` uses a custom check rather than `{:map, :any, :any}` because NimbleOptions
enumerates a map type's entries and raises `Protocol.UndefinedError` on a struct (verified).
`retry/1` rescues only `ArgumentError`, the one exception `Retry.validate_options!/1` raises
(including `Keyword.keys/1`'s on a non-keyword list), and turns it into this option's error;
nothing is swallowed.

- [ ] **Step 4: Rewrite `init/1`, drop its helpers, name `run/3` in the option check**

In `lib/normandy/agents/base_agent.ex`:

1. Add `alias Normandy.Agents.BaseAgent.InitOptions` above `alias Normandy.Agents.BaseAgentConfig`
   (`:15`).
2. Replace everything from `  @type config_input :: %{` (`:55`) through the `end` of `init/1`
   (`:184`) with:

```elixir
  @doc """
  Builds an agent config from `opts`, a keyword list or a map.

  Every option is checked before anything starts: an unknown option, a missing `:client`
  or `:model`, or a bad value raises `ArgumentError` naming the option (and, for an
  unknown one, the supported options). Values of credential-carrying options such as
  `:client` are never shown in the message.

      agent = BaseAgent.init(client: client, model: "claude-opus-5-5")

  ## Options

  #{Normandy.Options.docs(InitOptions.schema())}
  """
  @spec init(keyword() | map()) :: BaseAgentConfig.t()
  def init(opts) do
    opts = InitOptions.validate!(opts)
    client = Keyword.fetch!(opts, :client)
    behaviours = Keyword.fetch!(opts, :behaviours)

    _ = validate_compaction_config!(%BaseAgentConfig{client: client, behaviours: behaviours})
    _ = validate_client_options!(client)
    :ok = validate_policy_opts!(behaviours)
    :ok = validate_hooks!(behaviours)

    # Every check is above: the breaker starts last, so a bad option never leaves a
    # linked process behind.
    circuit_breaker = start_circuit_breaker(opts)
    memory = Keyword.fetch!(opts, :memory) || AgentMemory.new_memory()

    %BaseAgentConfig{
      input_schema: Keyword.fetch!(opts, :input_schema) || %BaseAgentInputSchema{},
      output_schema: Keyword.fetch!(opts, :output_schema) || %BaseAgentOutputSchema{},
      memory: memory,
      initial_memory: memory,
      prompt_specification: Keyword.fetch!(opts, :prompt_specification) || %PromptSpecification{},
      client: client,
      model: Keyword.fetch!(opts, :model),
      current_user_input: nil,
      temperature: Keyword.fetch!(opts, :temperature),
      max_tokens: Keyword.fetch!(opts, :max_tokens),
      tool_registry: Keyword.fetch!(opts, :tool_registry),
      max_tool_iterations: Keyword.fetch!(opts, :max_tool_iterations),
      max_tool_concurrency: Keyword.fetch!(opts, :max_tool_concurrency),
      retry_options: Keyword.fetch!(opts, :retry_options),
      circuit_breaker: circuit_breaker,
      enable_json_retry: Keyword.fetch!(opts, :enable_json_retry),
      json_retry_max_attempts: Keyword.fetch!(opts, :json_retry_max_attempts),
      mcp_servers: Keyword.fetch!(opts, :mcp_servers),
      name: Keyword.fetch!(opts, :name),
      session_id: Keyword.fetch!(opts, :session_id),
      tool_context: Keyword.fetch!(opts, :tool_context),
      input_guardrails: Keyword.fetch!(opts, :input_guardrails),
      output_guardrails: Keyword.fetch!(opts, :output_guardrails),
      output_guardrails_streaming_mode: Keyword.fetch!(opts, :output_guardrails_streaming_mode),
      output_guardrails_chunk_size: Keyword.fetch!(opts, :output_guardrails_chunk_size),
      output_guardrails_on_violation: Keyword.fetch!(opts, :output_guardrails_on_violation),
      behaviours: behaviours
    }
  end

  defp start_circuit_breaker(opts) do
    if Keyword.fetch!(opts, :enable_circuit_breaker) do
      {:ok, pid} = CircuitBreaker.start_link(Keyword.fetch!(opts, :circuit_breaker_options))
      pid
    end
  end
```

3. Delete `defp max_tokens!/1` (`:252-266`) and `normalize_max_tool_iterations/1` with its
   comment block (`:268-279`); `init/1` was their only caller (grep: `grep -rn
   "normalize_max_tool_iterations\|max_tokens!(" lib test` → no hits after the edit).
   `normalize_max_tool_concurrency/1` stays: `dsl/agent.ex:480` uses it at compile time.
4. In `run/3` (`:461`), make the first line of the body
   `:ok = check_run_opts!(opts, :run)`. In `run!/3` (`:473`), drop the `when is_list(opts)`
   guard and change `check_run_opts!(opts)` to `:ok = check_run_opts!(opts, :run!)`. (`run/3`
   checks first so its error names `run/3`; the `ArgumentError` passes through `run/3`'s
   `rescue`, because `domain_error/2` re-raises anything that is not a Normandy error.)
5. Replace `check_run_opts!/1` and its comment (`:483-496`) with:

```elixir
  # run/3 and run!/3 take no options yet; if one gains options it gets a
  # Normandy.Options schema instead of this check.
  defp check_run_opts!([], _fun), do: :ok

  defp check_run_opts!(opts, fun) when is_list(opts) do
    prefix = "Normandy.Agents.BaseAgent.#{fun}/3"

    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{prefix}: expected options as a keyword list, got a list that is not one; " <>
              "#{fun}/3 takes no options"
    end

    keys = Keyword.keys(opts)

    hint =
      if Enum.any?(keys, &(&1 in [:stream, :on_chunk])),
        do: ". Streaming moved to BaseAgent.stream/3",
        else: ""

    names =
      case keys do
        [key] -> "option #{inspect(key)}"
        keys -> "options #{inspect(keys)}"
      end

    raise ArgumentError, "#{prefix}: unknown #{names}; #{fun}/3 takes no options#{hint}"
  end

  defp check_run_opts!(other, fun) do
    raise ArgumentError,
          "Normandy.Agents.BaseAgent.#{fun}/3: expected options as a keyword list, got " <>
            "#{Describe.type_of(other)}; #{fun}/3 takes no options"
  end
```

(`Describe` is already aliased at `:24`.) Also edit `run/3`'s doc line "`run/3` takes no
options yet: any option raises `ArgumentError`." to "`run/3` takes no options yet: any option,
or options that are not a keyword list, raise `ArgumentError` naming `run/3`."

- [ ] **Step 5: Run the new tests**

Run: `mix test test/agents/base_agent_init_options_test.exs test/agents/base_agent_stream_test.exs`
Expected: PASS (35 tests, 0 failures, verified on a scratch copy of the branch).

- [ ] **Step 6: Update the 13 assertions whose message changed**

`mix test` now fails exactly these 13 tests (verified): the messages come from NimbleOptions
instead of hand-written `raise`s. Rewrite only the regex (then `mix format` re-wraps):

| File:line | Old | New |
|---|---|---|
| `test/agents/base_agent_tool_loop_test.exs:154` | `~r/max_tool_iterations must be an integer >= 1/` | `~r/invalid value for :max_tool_iterations option: expected positive integer, got: 0/` |
| `…tool_loop_test.exs:167` | same | `… got: -1/` |
| `…tool_loop_test.exs:180` | same | `… got: 1.5/` |
| `…tool_loop_test.exs:193` | same | `… got: "5"/` |
| `test/agents/base_agent_max_tokens_test.exs:51` | `~r/:max_tokens must be a positive integer.*got: #{Regex.escape(inspect(bad))}/` | `~r/:max_tokens option: expected a positive integer \(the Messages API requires it\), got: #{Regex.escape(inspect(bad))}/` |
| `test/agents/tool_context_test.exs:22` | `~r/tool_context must be a map/` | `~r/:tool_context option: expected a plain map \(not a struct\), got: a list/` |
| `test/dsl/agent_memory_test.exs:112` | `~r/tool_context must be a map of plain data, got: "acme"/` | `~r/:tool_context option: expected a plain map \(not a struct\), got: a string \(4 bytes\)/` |
| `test/dsl/agent_test.exs:374` | `~r/:max_tool_concurrency must be an integer >= 1/` (the `4.0` call) | `~r/:max_tool_concurrency option: expected an integer, got: 4.0/` |
| `test/dsl/agent_test.exs:378` | same (the `"4"` call) | `~r/:max_tool_concurrency option: expected an integer, got: "4"/` |
| `test/agents/base_agent_streaming_guardrails_test.exs:434` | `~r/:accumulate or :incremental/` | `~r/expected one of \[:accumulate, :incremental\], got: :bogus/` |
| `test/agents/base_agent_guardrails_test.exs:159` | `~r/output_guardrails_on_violation must be :block or :warn, got: :log/` | `~r/:output_guardrails_on_violation option: expected one of \[:block, :warn\], got: :log/` |
| `…guardrails_test.exs:242` | `~r/input_guardrails must be a list/` | `~r/:input_guardrails option: expected list, got: :not_a_list/` |
| `…guardrails_test.exs:248` | `~r/output_guardrails must be a list/` | `~r/:output_guardrails option: expected list, got: %\{not: "a list"\}/` |

`test/dsl/agent_test.exs:388` (the compile-time `max_tool_concurrency("4")` check) keeps its
regex: it still goes through `normalize_max_tool_concurrency/1`.
`test/resilience/retry_test.exs:333` keeps `~r/unknown option :max_attemps/`: the message is now
`"Normandy.Agents.BaseAgent.init/1: invalid value for :retry_options option: Retry.with_retry/2:
unknown option :max_attemps; supported: ..."`.

Also fix `test/integration/agent_resilience_integration_test.exs:64`
(`@tag :integration`, not in the default run): `error_threshold: 3` is not a breaker option
(1.x ignored it); make it `failure_threshold: 3`.

- [ ] **Step 7: MIGRATING**

Insert before `## New, non-breaking` (`MIGRATING-2.0.md:485`):

```markdown
## 21. `BaseAgent.init/1` and DSL `new/1` check their options

`BaseAgent.init/1` takes a keyword list or a map, and checks every option before it starts
anything. In 1.x it took only a map and ignored any key it did not know.

- An unknown option raises `ArgumentError` naming it and listing the supported ones:
  `temprature:`, `system_prompt:` (use `prompt_specification:`), `tools:` (use
  `tool_registry:` or `register_tool/2`) and `max_messages:` (use
  `memory: AgentMemory.new_memory(n)`) used to be dropped silently.
- A missing `:model` raises `"Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"` (1.x:
  `KeyError`); a missing `:client` raises `ArgumentError` (1.x: `KeyError`).
- Values are checked: `:client` must be a struct, `:input_schema`/`:output_schema` a struct or
  `nil`, `:memory` an `AgentMemory` or `nil`, `:prompt_specification`, `:tool_registry` and
  `:behaviours` their structs or `nil`, `:tool_context` a map, `:name`/`:session_id` strings or
  `nil`, `:json_retry_max_attempts` a positive integer, guard lists `module | {module, opts}`.
- `:circuit_breaker_options` accepts `:failure_threshold`, `:success_threshold`, `:timeout` and
  `:half_open_max_calls` only. `:name` is gone: a registered breaker name made a second
  `init/1` with the same options crash.
- A bad option raises before the circuit breaker starts, so it no longer leaves a linked
  breaker process behind.
- The value of a credential-carrying option (`:client`, `:mcp_servers`) never appears in the
  message.
- `run/3` and `run!/3` name themselves in their option error, and options that are not a
  keyword list raise `ArgumentError` instead of `FunctionClauseError`.
```

- [ ] **Step 8: CLAUDE.md**

Replace `CLAUDE.md:54`

```markdown
  - `init/1` - Initialize agent with `BaseAgentConfig` (requires `:client` and `:model`; `:temperature` is optional and omitted from the request when `nil`, since Opus 4.7+ reject sampling parameters)
```

with

```markdown
  - `init/1` - Build a `BaseAgentConfig` from a keyword list or map (requires `:client` and `:model`; `:temperature` is optional and omitted from the request when `nil`, since Opus 4.7+ reject sampling parameters). The schema is `BaseAgent.InitOptions` (NimbleOptions, docs generated into `init/1`); every option is checked through `Normandy.Options.validate!/3` before any process starts, and an unknown one raises `ArgumentError` naming it
```

and add under `### Agent System`, after the `BaseAgentConfig` bullet:

```markdown
- **`Normandy.Options`** - `validate!(opts, schema, {mod, fun, arity})` for every public entry point: NimbleOptions schema, map or keyword input, `ArgumentError` prefixed `Mod.fun/arity:`; values of `sensitive_keys/0` (`:client`, `:api_key`, ...) never appear in a message
```

- [ ] **Step 9: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -3 && mix credo --strict`
Expected: ` 0 failures` (2726 tests on the scratch copy) and no credo issues.

```bash
git add lib/normandy/agents/base_agent/init_options.ex lib/normandy/agents/base_agent.ex \
  test/agents/base_agent_init_options_test.exs test/agents/base_agent_stream_test.exs \
  test/agents/base_agent_tool_loop_test.exs test/agents/base_agent_max_tokens_test.exs \
  test/agents/tool_context_test.exs test/dsl/agent_memory_test.exs test/dsl/agent_test.exs \
  test/agents/base_agent_streaming_guardrails_test.exs test/agents/base_agent_guardrails_test.exs \
  test/integration/agent_resilience_integration_test.exs MIGRATING-2.0.md CLAUDE.md
git commit -m "feat(agent)!: init/1 checks every option with NimbleOptions and takes keyword lists"
```

---
### Task 3.1c: DSL `new/1` checks options with the init schema and returns the agent (DX-5 rest, DX-6)

`plan-wave-2.md:15` left "DSL `new/1` return shape" to this task. DX-5's fix offers "return the
agent, or rename it `new!/1`". This task makes `new/1` return the `%BaseAgentConfig{}` and raise
`ArgumentError`, like `BaseAgent.init/1` (it never returned `{:error, _}`). Open question for Q in
the notes.

**Files:**
- Modify: `lib/normandy/dsl/agent.ex`: aliases (`:80-84`), `@override_keys` +
  `validate_overrides!/2` (`:390-431`), generated `new/1` doc and body (`:505-569`),
  `build_config/2` (`:630-668`), moduledoc example (`:32`)
- Modify (mechanical, 59 sites): the `{:ok, agent} = SomeDslAgent.new(` call sites listed in
  Step 5, `docs/guides/agent-memory.md:100`, `e2e/09_dsl.exs:52`
- Modify: `MIGRATING-2.0.md` §21 (Task 3.1b), `CLAUDE.md:146`
- Test: `test/dsl/agent_test.exs` (`describe "new/1"`, the `"raises when client is missing"`
  test at `:190-194`)

**Interfaces:**
- Consumes: `InitOptions.definition/0`, `without_defaults/1`, `check_misnamed!/3`
  (Task 3.1b); `Normandy.Options.validate!/3`, `docs/1` (Task 3.1a).
- Produces:
  - Generated `MyAgent.new(opts :: keyword() | map()) :: BaseAgentConfig.t()` (was
    `{:ok, BaseAgentConfig.t()}`); raises `ArgumentError` prefixed `"MyAgent.new/1: "`.
    An agent that declares no model raises `"MyAgent.new/1: requires :model (a string), got
    none"` (decision 18: init/1's message under new/1's prefix; 1.x raised a `RuntimeError`
    `"model is required in agent definition"`).
  - Options: every `BaseAgent.init/1` option without its default (one left out keeps the
    declared value), `:client` required, plus `:override` (keyword list, wins over top-level),
    `:memory_store`, `:max_messages`.
  - `Normandy.DSL.Agent.new_schema/0` and `init_config!/4` (`@doc false`, called from the
    generated code). `validate_overrides!/2` and `@override_keys` are gone.

- [ ] **Step 1: Write the failing tests**

In `test/dsl/agent_test.exs`, after `LimitedMemoryAgent` (`:32-40`) add

```elixir
  # Declares no model: new/1 raises before it builds anything.
  defmodule NoModelAgent do
    use Normandy.DSL.Agent

    agent do
      name("No Model Agent")
    end
  end
```

then replace the test `"raises when client is missing"` (`:190-194` before the insertion,
which asserts `KeyError`) with:

```elixir
    test "an agent that declares no model raises, naming new/1" do
      assert_raise ArgumentError,
                   "Normandy.DSL.AgentTest.NoModelAgent.new/1: requires :model (a string), " <>
                     "got none",
                   fn -> NoModelAgent.new(client: %NormandyTest.Support.ModelMockup{}) end
    end

    test "a missing client raises ArgumentError naming new/1" do
      assert_raise ArgumentError,
                   "Normandy.DSL.AgentTest.TestAgent.new/1: required :client option not found, " <>
                     "received options: []",
                   fn -> TestAgent.new([]) end
    end

    test "new/1 returns the agent config itself" do
      assert %Normandy.Agents.BaseAgentConfig{} =
               TestAgent.new(client: %NormandyTest.Support.ModelMockup{})
    end

    test "an unknown option names new/1, the option and the supported ones" do
      error =
        assert_raise ArgumentError, fn ->
          TestAgent.new(client: %NormandyTest.Support.ModelMockup{}, temprature: 0.2)
        end

      assert error.message =~
               ~r/^Normandy.DSL.AgentTest.TestAgent.new\/1: unknown option :temprature; supported: :client, :model, /

      assert error.message =~ ":override, :memory_store"
    end

    test "an unknown option under :override names new/1 too" do
      assert_raise ArgumentError,
                   ~r/^Normandy.DSL.AgentTest.TestAgent.new\/1: unknown option :maxtokens; supported: /,
                   fn ->
                     TestAgent.new(
                       client: %NormandyTest.Support.ModelMockup{},
                       override: [maxtokens: 1]
                     )
                   end
    end

    test ":override must be a keyword list" do
      assert_raise ArgumentError,
                   "Normandy.DSL.AgentTest.TestAgent.new/1: invalid value for :override option: " <>
                     "expected keyword list, got: :fast",
                   fn ->
                     TestAgent.new(client: %NormandyTest.Support.ModelMockup{}, override: :fast)
                   end
    end

    test ":system_prompt gets the same hint as BaseAgent.init/1" do
      assert_raise ArgumentError,
                   ~r/^Normandy.DSL.AgentTest.TestAgent.new\/1: unknown option :system_prompt; the system prompt goes in :prompt_specification/,
                   fn ->
                     TestAgent.new(
                       client: %NormandyTest.Support.ModelMockup{},
                       system_prompt: "Be brief."
                     )
                   end
    end

    test "a secret under a misspelled key is never shown" do
      error =
        assert_raise ArgumentError, fn ->
          TestAgent.new(client: %NormandyTest.Support.ModelMockup{}, api_kye: "sk-ant-canary")
        end

      assert error.message =~ "unknown option :api_kye"
      refute error.message =~ "sk-"
    end

    test "an option left out keeps the declared value" do
      agent = TestAgent.new(client: %NormandyTest.Support.ModelMockup{}, name: "renamed")

      assert agent.name == "renamed"
      assert agent.model == TestAgent.config().model
      assert agent.max_tokens == TestAgent.config().max_tokens
    end

    test "new/1's option docs come from its schema" do
      docs = Normandy.Options.docs(Normandy.DSL.Agent.new_schema())

      assert docs =~ "* `:client` (a struct implementing `Normandy.Agents.Model`) - Required."
      assert docs =~ "* `:override`"
      assert docs =~ "* `:memory_store`"
    end
```

(The docs test reads the schema, not `Code.fetch_docs/1`: a module defined in a test file has
no `.beam`, so `Code.fetch_docs/1` returns an error for it; verified.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/dsl/agent_test.exs`
Expected: FAIL: `KeyError` instead of `ArgumentError` for the missing client, a `RuntimeError`
`"model is required in agent definition"` for `NoModelAgent`, `{:ok, %BaseAgentConfig{}}`
instead of the struct, the old `"...new/1: unknown option :temprature; allowed: ..."` text, and
`Normandy.DSL.Agent.new_schema/0` undefined.

- [ ] **Step 3: Implement in `Normandy.DSL.Agent`**

1. Aliases (`:80-84`): add `alias Normandy.Agents.BaseAgent.InitOptions` after
   `alias Normandy.Agents.BaseAgent`, and `alias Normandy.Options` after
   `alias Normandy.Components.PromptSpecification`.
2. Replace the `@override_keys` comment and list and `validate_overrides!/2` (`:390-431`) with:

```elixir
  # new/1 takes BaseAgent.init/1's options without their defaults (an option left out
  # keeps the agent's declared value; :client is required), plus three of its own.
  @own_options [
    override: [
      type: :keyword_list,
      default: [],
      doc: "`BaseAgent.init/1` options (and `:max_messages`) that win over the top-level ones."
    ],
    memory_store: [
      type: {:tuple, [:atom, :any]},
      doc:
        "`{module, handle}`: the store for a declared `memory`; required when the agent " <>
          "declares memory, rejected when it does not."
    ],
    max_messages: [
      type: {:or, [:pos_integer, nil]},
      doc: "Caps the memory at this many messages; ignored when `:memory` is given."
    ]
  ]

  @override_definition InitOptions.without_defaults(InitOptions.definition()) ++
                         Keyword.take(@own_options, [:max_messages])

  @new_definition Keyword.update!(
                    @override_definition,
                    :client,
                    &Keyword.put(&1, :required, true)
                  ) ++ Keyword.take(@own_options, [:override, :memory_store])

  @new_schema NimbleOptions.new!(@new_definition)
  @override_schema NimbleOptions.new!(@override_definition)

  @doc false
  # The schema of a DSL agent's new/1, for its generated docs.
  @spec new_schema() :: NimbleOptions.t()
  def new_schema, do: @new_schema

  @doc false
  # new/1's options -> {the BaseAgent.init/1 config, the memory store}. Every option is
  # checked here, under new/1's name, before anything is built.
  @spec init_config!(module(), keyword() | map(), map(), map()) :: {map(), term()}
  def init_config!(agent_module, opts, base_config, compile_config) do
    mfa = {agent_module, :new, 1}
    :ok = InitOptions.check_misnamed!(opts, @new_schema, mfa)
    opts = Options.validate!(opts, @new_schema, mfa)
    {explicit, opts} = Keyword.pop!(opts, :override)
    :ok = InitOptions.check_misnamed!(explicit, @override_schema, mfa)
    explicit = Options.validate!(explicit, @override_schema, mfa)
    {memory_store, implicit} = Keyword.pop(opts, :memory_store)

    {max_messages, overrides} =
      implicit
      |> Keyword.merge(explicit)
      |> Keyword.pop(:max_messages, compile_config.max_messages)

    config =
      base_config
      |> Map.merge(Map.new(overrides))
      |> put_declared_hooks(compile_config.hooks)
      |> put_memory_cap(max_messages)

    {config, memory_store}
  end

  # BaseAgent.init/1 takes the cap through the memory; a given :memory wins.
  defp put_memory_cap(config, nil), do: config
  defp put_memory_cap(%{memory: _} = config, _cap), do: config
  defp put_memory_cap(config, cap), do: Map.put(config, :memory, AgentMemory.new_memory(cap))
```

3. In `__before_compile__`, replace the generated `new/1` `@doc` and body (from
   `      @doc """\n      Creates a new agent instance.` through `        {:ok, agent}\n      end`,
   `:505-569`) with:

```elixir
      @doc """
      Builds the agent: a `%Normandy.Agents.BaseAgentConfig{}` with the declared
      prompt, tools and memory.

      Takes `BaseAgent.init/1`'s options, which override what the agent declares,
      either at the top level or under `:override` (which wins when both give one).
      Every option is checked first: an unknown option or a bad value raises
      `ArgumentError` naming `#{inspect(__MODULE__)}.new/1` and the option.

          agent = #{inspect(__MODULE__)}.new(client: my_client)
          agent = #{inspect(__MODULE__)}.new(client: my_client, override: [max_tokens: 2048])

      ## Options

      #{Normandy.Options.docs(Normandy.DSL.Agent.new_schema())}
      """
      def new(opts) do
        {config, memory_store} =
          Normandy.DSL.Agent.init_config!(__MODULE__, opts, base_config(), @agent_compile_config)

        # Built before init/1 so a missing store raises before any process starts.
        memory_tool =
          Normandy.DSL.Agent.memory_tool!(__MODULE__, @agent_compile_config.memory, memory_store)

        agent =
          config
          |> BaseAgent.init()
          |> apply_system_prompt()
          |> register_tools()

        if memory_tool, do: BaseAgent.register_tool(agent, memory_tool), else: agent
      end
```

4. Replace `defp build_config(client, overrides)` (`:630-668`) with `defp base_config`: keep its
   `unless @agent_compile_config.model do raise ... end` check (its `raise` becomes the
   `ArgumentError` below, decision 18) and its `%{...}` map minus the
   `client: client,` line; delete everything after the map (the `validate_overrides!` call, the
   merge, `put_declared_hooks`, the `max_messages` case; `init_config!/4` does those now). It
   becomes:

```elixir
      defp base_config do
        unless @agent_compile_config.model do
          raise ArgumentError,
                "#{inspect(__MODULE__)}.new/1: requires :model (a string), got none"
        end

        %{
          model: @agent_compile_config.model,
          temperature: @agent_compile_config.temperature,
          max_tokens: @agent_compile_config.max_tokens,
          max_tool_concurrency: @agent_compile_config.max_tool_concurrency,
          name: @agent_name,
          input_guardrails: @agent_compile_config.input_guardrails,
          output_guardrails: @agent_compile_config.output_guardrails,
          output_guardrails_streaming_mode:
            @agent_compile_config.output_guardrails_streaming_mode,
          output_guardrails_chunk_size: @agent_compile_config.output_guardrails_chunk_size,
          output_guardrails_on_violation: @agent_compile_config.output_guardrails_on_violation
        }
      end
```

5. Moduledoc `:32`: `{:ok, agent} = MyResearchAgent.new(client: my_client)` →
   `agent = MyResearchAgent.new(client: my_client)`.

`Keyword.pop!/2` needs Elixir 1.10+ (fine on 1.15). `without_defaults/1` matters for the nested
guardrail keys Task 3.2b adds: with defaults, `new(guardrails: [input: x])` would reset the
declared output guardrails.

- [ ] **Step 4: Run the DSL tests**

Run: `mix test test/dsl/agent_test.exs`
Expected: the new tests pass; the rest of the file fails on `{:ok, agent} = TestAgent.new(...)`
(`MatchError`) until Step 5.

- [ ] **Step 5: Rewrite the call sites (mechanical)**

Rewrite rule: `{:ok, VAR} = DslAgent.new(` (optionally prefixed by `assert `, and with the
`=` possibly followed by a newline) becomes `VAR = DslAgent.new(`. Every such site in these
files is a DSL agent (checked: no `Registry.new`/`Memory.new` matches the pattern there).
Apply with:

```bash
perl -0pi -e 's/(?:assert\s+)?\{:ok,\s*(\w+)\}(\s*=\s*)((?:[A-Z][\w.]*|mod)\.new\()/$1$2$3/g' \
  test/dsl/agent_test.exs test/dsl/agent_guardrails_test.exs test/dsl/agent_hooks_test.exs \
  test/dsl/agent_memory_test.exs test/dsl/agent_streaming_guardrails_test.exs \
  test/dsl/workflow_test.exs test/normandy_integration/dsl_comprehensive_test.exs \
  test/agents/base_agent_logging_test.exs test/agents/base_agent_max_tokens_test.exs \
  e2e/09_dsl.exs docs/guides/agent-memory.md
```

Expected count: **59** replacements (agent_test 24, dsl_comprehensive_test 11, agent_guardrails 7,
workflow 5, agent_hooks 3, agent_memory 3, agent_streaming_guardrails 2, logging 1, max_tokens 1,
e2e/09_dsl 1, agent-memory.md 1). Count before and after with
`perl -0ne '$c += () = /(?:assert\s+)?\{:ok,\s*\w+\}\s*=\s*(?:[A-Z][\w.]*|mod)\.new\(/g; END { print "$c\n" }' <the files>`
(59 → 0).

- [ ] **Step 6: Run the suite**

Run: `mix format && mix test 2>&1 | tail -3`
Expected: ` 0 failures` (2734 tests on the scratch copy). The existing
`"an unknown option raises, naming it"` test (`agent_test.exs:172-180`) keeps passing unchanged:
the messages still contain `unknown option :temprature` / `unknown option :maxtokens`.

- [ ] **Step 7: MIGRATING and CLAUDE.md**

Append to §21 (Task 3.1b):

```markdown
- A DSL agent's `new/1` returns the agent (`agent = MyAgent.new(client: c)`); it returned
  `{:ok, agent}` and never `{:error, _}`. It takes the same options as `BaseAgent.init/1`
  (top level or under `:override`) plus `:memory_store` and `:max_messages`, checks them the
  same way, and its errors name `MyAgent.new/1`. A missing `:client` raises `ArgumentError`
  (1.x: `KeyError`); an agent that declares no model raises `ArgumentError`
  `"MyAgent.new/1: requires :model (a string), got none"` (1.x: `RuntimeError`
  `"model is required in agent definition"`).
```

`CLAUDE.md:146`: replace

```markdown
  - Generates `new/1` and `run/1-3` functions automatically
```

with

```markdown
  - Generates `new/1` (returns the `BaseAgentConfig`; takes `BaseAgent.init/1`'s options without defaults, checked under `MyAgent.new/1`) and `run/1-3`
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/dsl/agent.ex test/dsl/agent_test.exs test/dsl/agent_guardrails_test.exs \
  test/dsl/agent_hooks_test.exs test/dsl/agent_memory_test.exs \
  test/dsl/agent_streaming_guardrails_test.exs test/dsl/workflow_test.exs \
  test/normandy_integration/dsl_comprehensive_test.exs test/agents/base_agent_logging_test.exs \
  test/agents/base_agent_max_tokens_test.exs e2e/09_dsl.exs docs/guides/agent-memory.md \
  MIGRATING-2.0.md CLAUDE.md
git commit -m "feat(dsl)!: new/1 returns the agent and checks options with the init schema"
```

---
### Task 3.2a: The compactor's window pin is `:context_window` (DX-18 part); `checked_manager/2` messages (Wave 2 minor)

**Files:**
- Modify: `lib/normandy/behaviours/compactor/window_manager.ex` (moduledoc `:6-17`,
  `build_manager/3` + `checked_manager/2` `:35-61`)
- Modify: `lib/normandy/agents/base_agent.ex` (`compact_turn_memory/3` comment,
  `validate_compaction_config!/1`, `resolve_context_window/3`; around `:887-1020` before 3.1b,
  shifted by 3.1b; the diff below has the post-3.1b positions)
- Modify: `lib/normandy/behaviours/compactor.ex:14`, `lib/normandy/exceptions.ex:127,136`
  (`ModelCatalogError`)
- Modify: `e2e/02_compaction.exs:16`, `MIGRATING-2.0.md` §5 (`:109-128`) and §17 (`:394`)
- Test: `test/behaviours/compactor_test.exs`, `test/agents/base_agent_compaction_config_test.exs`,
  and the 14 renamed opts in Step 5

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - Compactor option `:context_window` (header: "compactor option :max_tokens → :context_window").
    `BaseAgent` reads it as the pin for **any** compactor (it did so with `:max_tokens`);
    `Compactor.WindowManager` turns it into `Context.WindowManager.new(max_tokens: window)`.
    `Normandy.Context.WindowManager.new/1` keeps `:max_tokens` (a standalone API; out of scope).
  - `Compactor.WindowManager` with `:max_tokens` in its opts raises
    (`validate_compaction_config!/1` at `init/1`/`rebuild/3`, and `maybe_compact/3` for a
    hand-built config). A custom compactor's own `:max_tokens` is not touched.
  - Exact messages: see the tests. The deferred minor is closed: `context_window: nil` (or 0, or a
    string) and an acc whose `max_tokens` is missing or `nil` raise `ArgumentError` naming the
    field, where today they gave `"...must be smaller than the context window ()"` (Erlang term
    order makes `16_000 >= nil` true) or a bare `KeyError` from `Map.fetch!/2`.

- [ ] **Step 1: Write the failing tests**

In `test/behaviours/compactor_test.exs`, inside `describe "WindowManager impl"`, after the test
`"a reserve that leaves no room for history raises naming both numbers"`:

```elixir

    test "a pinned :context_window wins over the window in ctx" do
      {_acc, meta} =
        WMCompactor.maybe_compact(history_acc(16_000), %{window: 8_000}, context_window: 20_000)

      # 20_000 pinned - 16_000 reserved = 4_000 tokens of history at most
      assert meta.compacted
      assert meta.tokens_after <= 4_000
    end

    test "the 1.x :max_tokens pin raises, naming :context_window" do
      assert_raise ArgumentError,
                   "Compactor.WindowManager: the :max_tokens option was renamed to " <>
                     ":context_window in 2.0 (the model's context window in tokens); see " <>
                     "MIGRATING-2.0.md §22",
                   fn ->
                     WMCompactor.maybe_compact(history_acc(16_000), %{window: 20_000},
                       max_tokens: 20_000
                     )
                   end
    end

    test "a pinned :context_window that is not a positive integer raises, naming it" do
      for bad <- [nil, 0, "200000"] do
        assert_raise ArgumentError,
                     "Compactor.WindowManager: :context_window must be a positive integer " <>
                       "(the model's context window in tokens), got: #{inspect(bad)}",
                     fn ->
                       WMCompactor.maybe_compact(history_acc(16_000), %{window: 20_000},
                         context_window: bad
                       )
                     end
      end
    end

    test "an acc without :max_tokens and no :reserved_tokens raises, not KeyError" do
      acc = %{memory: mem_with([{"user", "hi"}])}

      assert_raise ArgumentError,
                   "Compactor.WindowManager: the agent config has no :max_tokens to reserve " <>
                     "for the answer; pass :reserved_tokens in the compactor opts",
                   fn -> WMCompactor.maybe_compact(acc, %{window: 20_000}, []) end
    end

    test "an acc whose max_tokens is nil raises, naming it" do
      assert_raise ArgumentError,
                   "Compactor.WindowManager: the agent's max_tokens is the default " <>
                     ":reserved_tokens and must be a positive integer, got: nil; set it, or " <>
                     "pass :reserved_tokens in the compactor opts",
                   fn -> WMCompactor.maybe_compact(history_acc(nil), %{window: 20_000}, []) end
    end

    test "a :reserved_tokens that is not a non-negative integer raises, naming it" do
      assert_raise ArgumentError,
                   "Compactor.WindowManager: :reserved_tokens must be a non-negative " <>
                     "integer, got: nil",
                   fn ->
                     WMCompactor.maybe_compact(history_acc(16_000), %{window: 20_000},
                       reserved_tokens: nil
                     )
                   end
    end
```

In `test/agents/base_agent_compaction_config_test.exs`, after the test
`"passes when :max_tokens is pinned"` (renamed in Step 5):

```elixir

  test "the 1.x :max_tokens pin on Compactor.WindowManager raises at init, naming :context_window" do
    behaviours = %Config{compactor: {Compactor.WindowManager, [max_tokens: 50_000]}}

    assert_raise ArgumentError,
                 "Normandy.Agents.BaseAgent.validate_compaction_config!/1: the :max_tokens " <>
                   "option of Normandy.Behaviours.Compactor.WindowManager was renamed to " <>
                   ":context_window in 2.0; see MIGRATING-2.0.md §22",
                 fn -> init(%Normandy.LLM.ClaudioAdapter{api_key: "k"}, behaviours) end
  end

  test "a custom compactor's own :max_tokens option is left alone" do
    behaviours = %Config{compactor: {Normandy.Test.KeepLastCompactor, [keep: 2, max_tokens: 9]}}

    assert %Normandy.Agents.BaseAgentConfig{} =
             init(%Normandy.LLM.ClaudioAdapter{api_key: "k"}, behaviours)
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/behaviours/compactor_test.exs test/agents/base_agent_compaction_config_test.exs`
Expected: 7 new tests FAIL (verified): the 1.x pin is accepted, `context_window:` is ignored,
`nil` gives the misleading reserve message, the missing `:max_tokens` gives `KeyError`.
(`"a custom compactor's own :max_tokens option is left alone"` already passes; it guards Step 3.)

- [ ] **Step 3: Implement the compactor**

In `lib/normandy/behaviours/compactor/window_manager.ex`, replace the moduledoc paragraphs from
`Triggered at the turn's` through `(see \`Normandy.Behaviours.Compactor\`).` with:

```elixir
  Triggered at the turn's `:steering` boundary: builds a `WindowManager` sized to the
  model's context window (`ctx.window`, unless `opts` pins `:context_window`), then
  delegates to `WindowManager.ensure_within_limit/2` — a no-op when already under budget.

  Options: `:context_window` pins the window (and skips the model catalog lookup);
  `:reserved_tokens` is the answer's room, by default the agent's `max_tokens`; a reserve
  at or above the window raises `ArgumentError`; `:strategy` goes to
  `WindowManager.new/1`. The 1.x name `:max_tokens` for the pin raises `ArgumentError`.
  The `:summarize` strategy needs `acc.client`; if summarization fails it returns the
  original `acc` with `%{compacted: false, error: reason}` rather than crashing the turn.
  Its meta carries `:dropped`, the removed entries (see `Normandy.Behaviours.Compactor`).
```

and replace `build_manager/3` and `checked_manager/2` (from the comment
`# Honour an explicit opts :max_tokens;` through `WM.new(opts)\n  end`) with:

```elixir
  # A pinned :context_window wins; otherwise the model's window from ctx; with neither
  # there is nothing to size against, so the compactor skips. The answer's room is the
  # agent's max_tokens unless opts pins :reserved_tokens; it is read only when a manager
  # is actually built.
  defp build_manager(window, opts, acc) do
    :ok = reject_max_tokens!(opts)

    case Keyword.fetch(opts, :context_window) do
      {:ok, pinned} -> checked_manager(pinned, Keyword.delete(opts, :context_window), acc)
      :error when is_integer(window) -> checked_manager(window, opts, acc)
      :error -> nil
    end
  end

  # 1.x and the 2.0 betas pinned the window with :max_tokens, the name the agent uses
  # for the answer's limit. Read silently, it would now be ignored.
  defp reject_max_tokens!(opts) do
    if Keyword.has_key?(opts, :max_tokens) do
      raise ArgumentError,
            "Compactor.WindowManager: the :max_tokens option was renamed to :context_window " <>
              "in 2.0 (the model's context window in tokens); see MIGRATING-2.0.md §22"
    end

    :ok
  end

  defp checked_manager(window, opts, acc) do
    unless is_integer(window) and window > 0 do
      raise ArgumentError,
            "Compactor.WindowManager: :context_window must be a positive integer (the " <>
              "model's context window in tokens), got: #{inspect(window)}"
    end

    reserved = Keyword.get_lazy(opts, :reserved_tokens, fn -> agent_max_tokens!(acc) end)

    unless is_integer(reserved) and reserved >= 0 do
      raise ArgumentError,
            "Compactor.WindowManager: :reserved_tokens must be a non-negative integer, " <>
              "got: #{inspect(reserved)}"
    end

    if reserved >= window do
      raise ArgumentError,
            "Compactor.WindowManager: reserved_tokens (#{reserved}) must be smaller than " <>
              "the context window (#{window}); lower the agent's max_tokens or pass " <>
              ":reserved_tokens in the compactor opts"
    end

    WM.new([max_tokens: window, reserved_tokens: reserved] ++ Keyword.drop(opts, [:reserved_tokens]))
  end

  # The default reserve: the agent's max_tokens. A real agent config always has a
  # positive one (init/1 and ConfigTemplate.rebuild/3 check it).
  defp agent_max_tokens!(%{max_tokens: n}) when is_integer(n) and n > 0, do: n

  defp agent_max_tokens!(%{max_tokens: other}) do
    raise ArgumentError,
          "Compactor.WindowManager: the agent's max_tokens is the default :reserved_tokens " <>
            "and must be a positive integer, got: #{inspect(other)}; set it, or pass " <>
            ":reserved_tokens in the compactor opts"
  end

  defp agent_max_tokens!(_acc) do
    raise ArgumentError,
          "Compactor.WindowManager: the agent config has no :max_tokens to reserve for the " <>
            "answer; pass :reserved_tokens in the compactor opts"
  end
```

(`mix format` re-wraps the `WM.new([...] ++ ...)` line.)

- [ ] **Step 4: Implement the agent side and the messages**

Apply this diff (positions are after Task 3.1b):

```diff
diff --git a/lib/normandy/agents/base_agent.ex b/lib/normandy/agents/base_agent.ex
index 4e3ea53..90c32bf 100644
--- a/lib/normandy/agents/base_agent.ex
+++ b/lib/normandy/agents/base_agent.ex
@@ -817,7 +817,7 @@ defmodule Normandy.Agents.BaseAgent do
   defp emit_turn_event(_config, _name, _meta), do: :ok
 
   # Compaction at the :steering boundary. Resolves the configured Compactor and
-  # the model's context window (pinned `:max_tokens`, else the configured
+  # the model's context window (pinned `:context_window`, else the configured
   # ModelCatalog, memoised on the config), compacts the running config.memory,
   # and logs when it actually shrinks the conversation. Every run emits
   # [:normandy, :agent, :compaction] (measurements: whichever of :tokens_before,
@@ -895,7 +895,7 @@ defmodule Normandy.Agents.BaseAgent do
 
   @doc false
   # A real compactor sizes against the model's context window. With no pinned
-  # :max_tokens and the default catalog (the Anthropic Models API), that lookup
+  # :context_window and the default catalog (the Anthropic Models API), that lookup
   # needs a ClaudioAdapter client; any other client makes every compaction raise
   # mid-turn, after tools ran. Called from init/1 and ConfigTemplate.rebuild/3 so
   # the mistake surfaces where the config is made. Never inspects the client value
@@ -912,9 +912,17 @@ defmodule Normandy.Agents.BaseAgent do
               "#{inspect(compactor)} must be a keyword list, got #{inspect(compactor_opts)}"
     end
 
+    if compactor == Normandy.Behaviours.Compactor.WindowManager and
+         Keyword.has_key?(compactor_opts, :max_tokens) do
+      raise ArgumentError,
+            "Normandy.Agents.BaseAgent.validate_compaction_config!/1: the :max_tokens option " <>
+              "of Normandy.Behaviours.Compactor.WindowManager was renamed to :context_window " <>
+              "in 2.0; see MIGRATING-2.0.md §22"
+    end
+
     needs_api_lookup? =
       compactor != Normandy.Behaviours.Compactor.NoOp and
-        not Keyword.has_key?(compactor_opts, :max_tokens) and
+        not Keyword.has_key?(compactor_opts, :context_window) and
         catalog in [
           Normandy.Behaviours.ModelCatalog.ModelsAPI,
           Normandy.Behaviours.ModelCatalog.Static
@@ -925,7 +933,7 @@ defmodule Normandy.Agents.BaseAgent do
             "Normandy.Agents.BaseAgent: compactor #{inspect(compactor)} needs the model's " <>
               "context window, and the model catalog #{inspect(catalog)} reads it from the " <>
               "Anthropic Models API, which needs a Normandy.LLM.ClaudioAdapter client; got " <>
-              "#{client_kind(config.client)}. Pin the window with the compactor's :max_tokens " <>
+              "#{client_kind(config.client)}. Pin the window with the compactor's :context_window " <>
               "option, or configure a model_catalog that works with this client."
     end
 
@@ -938,14 +946,14 @@ defmodule Normandy.Agents.BaseAgent do
   defp client_kind(_other), do: "a non-struct value"
 
   # The window the compactor sizes against. NoOp needs none; a pinned
-  # :max_tokens wins without a lookup (offline use, non-Claude clients);
+  # :context_window wins without a lookup (offline use, non-Claude clients);
   # otherwise the catalog, memoised per model on the config. A failed lookup
   # fails the turn: the agent asked for compaction and can't size it.
   defp resolve_context_window(config, Normandy.Behaviours.Compactor.NoOp, _opts),
     do: {config, nil}
 
   defp resolve_context_window(config, _compactor, opts) do
-    case Keyword.fetch(opts, :max_tokens) do
+    case Keyword.fetch(opts, :context_window) do
       {:ok, pinned} -> {config, pinned}
       :error -> lookup_context_window(config)
     end
diff --git a/lib/normandy/behaviours/compactor.ex b/lib/normandy/behaviours/compactor.ex
index ffe4204..442f988 100644
--- a/lib/normandy/behaviours/compactor.ex
+++ b/lib/normandy/behaviours/compactor.ex
@@ -11,7 +11,7 @@ defmodule Normandy.Behaviours.Compactor do
   `ctx` carries the decision inputs the core cannot compute (it is pure):
 
     * `:model`  — the model id for this turn
-    * `:window` — the model's context window: the compactor opts' `:max_tokens`
+    * `:window` — the model's context window: the compactor opts' `:context_window`
       when pinned, otherwise resolved through the configured `ModelCatalog`
       (memoised on the agent). `nil` only for the `NoOp` compactor
 
diff --git a/lib/normandy/exceptions.ex b/lib/normandy/exceptions.ex
index 65dd19d..ef93d8f 100644
--- a/lib/normandy/exceptions.ex
+++ b/lib/normandy/exceptions.ex
@@ -124,7 +124,7 @@ end
 defmodule Normandy.ModelCatalogError do
   @moduledoc """
   Raised when the model catalog can't produce a context window for a turn that
-  needs one (an agent with a real compactor and no pinned `:max_tokens`). The
+  needs one (an agent with a real compactor and no pinned `:context_window`). The
   turn fails; nothing is memoised, so the next turn retries the lookup.
   """
   defexception [:model, :reason]
@@ -133,7 +133,7 @@ defmodule Normandy.ModelCatalogError do
   def message(%__MODULE__{model: model, reason: reason}) do
     "model catalog lookup failed for #{inspect(model)}: #{inspect(reason)}. " <>
       "Compaction needs the model's context window; pin it with the compactor's " <>
-      ":max_tokens option to skip the lookup (required for non-Claude clients)."
+      ":context_window option to skip the lookup (required for non-Claude clients)."
   end
 end
 
```

- [ ] **Step 5: Rename the pin in existing tests and the e2e scenario**

Find: `grep -rnE "compactor: \{[^}]*max_tokens|WindowManager, \[?max_tokens|Compactor, \[max_tokens|KeepLastCompactor, keep: [0-9]+, max_tokens" test e2e`
Rule: on each of these lines, `max_tokens:` → `context_window:` (all are compactor opts that pin
the window; the custom `KeepLastCompactor`/`StubCompactor` ones too, since `BaseAgent` reads the
pin for every compactor). Expected **14 lines**:

| File | Lines |
|---|---|
| `test/integration/compaction_turn_test.exs` | 36, 77 |
| `test/hooks/llm_compaction_hooks_test.exs` | 45, 148, 166 |
| `test/hooks/server_hooks_test.exs` | 440, 466, 492, 512 |
| `test/agents/config_template_test.exs` | 384 |
| `test/agents/base_agent_compaction_telemetry_test.exs` | 50 |
| `test/agents/base_agent_compaction_config_test.exs` | 21, 52 |
| `e2e/02_compaction.exs` | 16 |

And the texts that name the option:

| File:line | Old | New |
|---|---|---|
| `compaction_turn_test.exs:72` | `test "a pinned :max_tokens never consults the catalog"` | `test "a pinned :context_window never consults the catalog"` |
| `compaction_turn_test.exs:164` | `~r/:no_client.*:max_tokens/s` | `~r/:no_client.*:context_window/s` |
| `config_template_test.exs:382` | `~r/:max_tokens/` (the unpinned rebuild) | `~r/:context_window/` |
| `base_agent_compaction_config_test.exs:28` | `assert error.message =~ ":max_tokens"` | `assert error.message =~ ":context_window"` |
| `base_agent_compaction_config_test.exs:51` | `test "passes when :max_tokens is pinned"` | `test "passes when :context_window is pinned"` |

Without Step 5, `mix test` fails exactly 19 tests (verified).

- [ ] **Step 6: MIGRATING**

In §5 (`MIGRATING-2.0.md:109-128`): replace "no pinned `:max_tokens`" with "no pinned
`:context_window`", "Pin `:max_tokens` (see below)." with "Pin `:context_window` (see below).",
`[max_tokens: 200_000]` with `[context_window: 200_000]`, and "Pinning `:max_tokens` also skips
the lookup entirely (offline use)." with "Pinning `:context_window` also skips the lookup entirely
(offline use). It was `:max_tokens` in 1.x (see §22)."

In §17 (`:394`), the `Compactor.WindowManager` bullet stays; it says nothing about the pin.

Then start §22 after §21 (Tasks 3.2b and 3.2c append to it):

```markdown
## 22. Config groups, the compactor's window pin, and 1.0 session templates

- The window pin of a compactor is `:context_window`; 1.x called it `:max_tokens`, the name
  the agent also uses for the answer's limit. `Compactor.WindowManager` with `:max_tokens`
  raises `ArgumentError` at `init/1` (and when it runs). `BaseAgent` reads `:context_window`
  as the pin for any compactor, so a custom compactor that was pinned with `:max_tokens` must
  rename it too; a custom compactor's own `:max_tokens` option is left alone.
- `Compactor.WindowManager` raises `ArgumentError` naming the field for a pin that is not a
  positive integer, and for an agent config without a positive `max_tokens` when no
  `:reserved_tokens` is given (it gave a misleading reserve error or a `KeyError`).
```

- [ ] **Step 7: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -3 && mix credo --strict`
Expected: ` 0 failures` (2742 tests on the scratch copy), no credo issues.

```bash
git add lib/normandy/behaviours/compactor/window_manager.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/behaviours/compactor.ex lib/normandy/exceptions.ex e2e/02_compaction.exs \
  test/behaviours/compactor_test.exs test/agents/base_agent_compaction_config_test.exs \
  test/integration/compaction_turn_test.exs test/hooks/llm_compaction_hooks_test.exs \
  test/hooks/server_hooks_test.exs test/agents/config_template_test.exs \
  test/agents/base_agent_compaction_telemetry_test.exs MIGRATING-2.0.md
git commit -m "feat(compaction)!: the compactor pins the window with :context_window"
```

---
### Task 3.2b: Option groups `retry`, `circuit_breaker`, `circuit_breaker_pid`, `guardrails` (DX-18, Ruling 1)

This task cannot be split further without a red suite: renaming a struct field breaks every
test that sets it. Its diff is large (~550 test lines) but the test part is mechanical: a
reviewer checks the rewrite script and its per-file counts, then the hand edits.

**Files:**
- Modify: `lib/normandy/agents/base_agent_config.ex` (fields, types, `default_guardrails/0`,
  `guardrail/2`)
- Modify: `lib/normandy/agents/base_agent/init_options.ex` (the 1.x keys become `retry`,
  `circuit_breaker`, `guardrails`; `@renamed`; `circuit_breaker/1`)
- Modify: `lib/normandy/agents/base_agent.ex` (`init/1` struct, `admit/3`, `with_resilience/3`,
  `stream/3` doc, the streaming dispatch, the three output-guardrail runners)
- Modify: `lib/normandy/agents/config_template.ex` (`@data_fields`, `@node_local_fields`, moduledoc),
  `lib/normandy/behaviours/agent_template.ex` (supplement key `:circuit_breaker_pid`)
- Modify: `lib/normandy/dsl/agent.ex` (compile config, `config/0`, `base_config/0`, guardrails
  override merge)
- Modify (docs): `lib/normandy/guardrails.ex:23-25,77,108`, `lib/normandy/llm/claudio_adapter.ex:93`,
  `lib/normandy/resilience/retry.ex:136`
- Modify: 21 test files + `test/support/integration_helper.ex` + `e2e/06_resilience.exs`,
  `e2e/07_guardrails.exs`, `e2e/08_streaming.exs` (Steps 5-6)
- Modify: `MIGRATING-2.0.md` (§22, §11 line 200), `CLAUDE.md:61-62,134-140`
- Test: `test/agents/base_agent_config_groups_test.exs` (new), `test/dsl/agent_guardrails_test.exs`

**Interfaces:**
- Consumes: `InitOptions` (3.1b), DSL `init_config!/4` (3.1c), `:context_window` (3.2a).
- Produces (header names, Ruling 1):
  - `BaseAgentConfig` fields `retry: keyword() | nil`, `circuit_breaker: keyword() | nil` (the
    validated options), `circuit_breaker_pid: pid() | nil` (node-local), `guardrails: keyword()`
    (default `BaseAgentConfig.default_guardrails()` =
    `[input: [], output: [], streaming_mode: :accumulate, chunk_size: 200, on_violation: :block]`).
    Removed: `retry_options`, `circuit_breaker` (as a pid), `input_guardrails`,
    `output_guardrails`, `output_guardrails_streaming_mode`, `output_guardrails_chunk_size`,
    `output_guardrails_on_violation`.
  - `BaseAgentConfig.guardrail(config, key)`: every reader goes through it; a key a hand-built
    `guardrails` list leaves out reads as its default (documented; `init/1` always fills all five).
  - `init/1` options `retry:`, `circuit_breaker:` (`nil` = none, a keyword list starts a linked
    breaker; keys `:failure_threshold`, `:success_threshold`, `:timeout`, `:half_open_max_calls`),
    `guardrails:` (nested NimbleOptions keys with defaults).
  - 1.x keys raise (exact): `"Normandy.Agents.BaseAgent.init/1: :retry_options was renamed to
    :retry in 2.0; see MIGRATING-2.0.md §22"`, likewise `:circuit_breaker_options` (→
    `:circuit_breaker`), `:enable_circuit_breaker` ("was removed: circuit_breaker: [] (or the
    breaker's options) starts a breaker"), and the five guardrail keys ("moved to guardrails:
    [input: ...]" etc.). DSL `new/1` raises the same under its own name.
  - Templates: `@data_fields` = `[:initial_memory, :retry, :circuit_breaker, :enable_json_retry,
    :json_retry_max_attempts, :guardrails, :tool_context]`; `@node_local_fields` =
    `[:circuit_breaker_pid, :mcp_servers]`; supplement key `:circuit_breaker_pid`.
  - DSL `config/0` returns `guardrails: [...]` instead of the five keys; a `guardrails:` given to
    `new/1` is merged into the declared one (`Keyword.merge/2`), not substituted.

- [ ] **Step 1: Write the failing tests**

Create `test/agents/base_agent_config_groups_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentConfigGroupsTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Guardrails.Builtins.MaxLength
  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Test.StubClient

  defp init(opts), do: BaseAgent.init([model: "m", client: %StubClient{}] ++ opts)

  describe "1.x option names" do
    @renamed [
      retry_options: {[max_attempts: 2], "was renamed to :retry"},
      enable_circuit_breaker:
        {true, "was removed: circuit_breaker: [] (or the breaker's options) starts a breaker"},
      circuit_breaker_options: {[timeout: 10], "was renamed to :circuit_breaker"},
      input_guardrails: {[MaxLength], "moved to guardrails: [input: ...]"},
      output_guardrails: {[MaxLength], "moved to guardrails: [output: ...]"},
      output_guardrails_streaming_mode:
        {:incremental, "moved to guardrails: [streaming_mode: ...]"},
      output_guardrails_chunk_size: {10, "moved to guardrails: [chunk_size: ...]"},
      output_guardrails_on_violation: {:warn, "moved to guardrails: [on_violation: ...]"}
    ]

    for {key, {value, change}} <- @renamed do
      test "#{key} raises, naming its 2.0 home" do
        assert_raise ArgumentError,
                     "Normandy.Agents.BaseAgent.init/1: #{inspect(unquote(key))} " <>
                       "#{unquote(change)} in 2.0; see MIGRATING-2.0.md §22",
                     fn -> init([{unquote(key), unquote(Macro.escape(value))}]) end
      end
    end
  end

  describe "retry" do
    test "is kept on the config, nil by default" do
      assert init([]).retry == nil
      assert init(retry: [max_attempts: 2]).retry == [max_attempts: 2]
    end

    test "a bad retry option raises naming :retry" do
      assert_raise ArgumentError, ~r/invalid value for :retry option: .*:max_attemps/, fn ->
        init(retry: [max_attemps: 2])
      end
    end
  end

  describe "circuit_breaker" do
    test "nil (the default) starts no breaker" do
      config = init([])

      assert config.circuit_breaker == nil
      assert config.circuit_breaker_pid == nil
    end

    test "a keyword list starts a breaker with those options" do
      config = init(circuit_breaker: [failure_threshold: 1, timeout: 60_000])

      assert config.circuit_breaker == [failure_threshold: 1, timeout: 60_000]
      assert is_pid(config.circuit_breaker_pid)
      assert CircuitBreaker.state(config.circuit_breaker_pid) == :closed
      GenServer.stop(config.circuit_breaker_pid)
    end

    test "[] starts a breaker with its defaults" do
      config = init(circuit_breaker: [])

      assert is_pid(config.circuit_breaker_pid)
      GenServer.stop(config.circuit_breaker_pid)
    end

    test "true is not a breaker option list" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: invalid value for :circuit_breaker " <>
                     "option: expected a keyword list or nil, got true",
                   fn -> init(circuit_breaker: true) end
    end
  end

  describe "guardrails" do
    test "every key has its default" do
      assert Enum.sort(init([]).guardrails) == Enum.sort(BaseAgentConfig.default_guardrails())
    end

    test "a partial list is completed with the defaults" do
      guardrails = init(guardrails: [input: [MaxLength], on_violation: :warn]).guardrails

      assert guardrails[:input] == [MaxLength]
      assert guardrails[:on_violation] == :warn
      assert guardrails[:output] == []
      assert guardrails[:streaming_mode] == :accumulate
      assert guardrails[:chunk_size] == 200
    end

    test "an unknown guardrails key is named with the supported ones" do
      assert_raise ArgumentError,
                   "Normandy.Agents.BaseAgent.init/1: unknown option :inptu in :guardrails; " <>
                     "supported: :input, :output, :streaming_mode, :chunk_size, :on_violation",
                   fn -> init(guardrails: [inptu: []]) end
    end

    test "guardrail/2 reads a key a hand-built list left out as its default" do
      config = %BaseAgentConfig{guardrails: [output: [MaxLength]]}

      assert BaseAgentConfig.guardrail(config, :output) == [MaxLength]
      assert BaseAgentConfig.guardrail(config, :input) == []
      assert BaseAgentConfig.guardrail(config, :chunk_size) == 200
    end
  end
end
```

Append to `test/dsl/agent_guardrails_test.exs`, before the final `end`:

```elixir

  describe "guardrails passed to new/1" do
    test "change only the keys they give; the rest stay as declared" do
      agent =
        GuardedAgent.new(
          client: %NormandyTest.Support.ModelMockup{},
          guardrails: [on_violation: :warn]
        )

      assert agent.guardrails[:on_violation] == :warn
      assert agent.guardrails[:input] == GuardedAgent.config().guardrails[:input]
      assert agent.guardrails[:output] == GuardedAgent.config().guardrails[:output]
    end

    test "a 1.x guardrail option names new/1 and its 2.0 home" do
      assert_raise ArgumentError,
                   "Normandy.DSL.AgentGuardrailsTest.GuardedAgent.new/1: :input_guardrails " <>
                     "moved to guardrails: [input: ...] in 2.0; see MIGRATING-2.0.md §22",
                   fn ->
                     GuardedAgent.new([
                       {:input_guardrails, []},
                       {:client, %NormandyTest.Support.ModelMockup{}}
                     ])
                   end
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/base_agent_config_groups_test.exs test/dsl/agent_guardrails_test.exs`
Expected: FAIL (`unknown option :retry`, `KeyError` on `config.retry`,
`BaseAgentConfig.default_guardrails/0 is undefined`, the 1.x keys still accepted).

- [ ] **Step 3: Implement the config and the schema**

Apply to `lib/normandy/agents/base_agent_config.ex`:

```diff
diff --git a/lib/normandy/agents/base_agent_config.ex b/lib/normandy/agents/base_agent_config.ex
index 1102576..6b5b562 100644
--- a/lib/normandy/agents/base_agent_config.ex
+++ b/lib/normandy/agents/base_agent_config.ex
@@ -4,6 +4,12 @@ defmodule Normandy.Agents.BaseAgentConfig do
 
   Stores all stateful information for an agent including schemas,
   memory, model configuration, and prompt specifications.
+
+  Option groups: `retry` (`Normandy.Resilience.Retry` options or `nil`), `circuit_breaker`
+  (`Normandy.Resilience.CircuitBreaker` options or `nil`; `circuit_breaker_pid` is the
+  breaker `BaseAgent.init/1` started, node-local) and `guardrails`
+  (`[input:, output:, streaming_mode:, chunk_size:, on_violation:]`). A `guardrails` list
+  built by hand may leave keys out: `guardrail/2` reads a missing key as its default.
   """
 
   use Normandy.Schema
@@ -19,6 +25,23 @@ defmodule Normandy.Agents.BaseAgentConfig do
   @spec default_max_tokens() :: pos_integer()
   def default_max_tokens, do: @default_max_tokens
 
+  @default_guardrails [
+    input: [],
+    output: [],
+    streaming_mode: :accumulate,
+    chunk_size: 200,
+    on_violation: :block
+  ]
+
+  @typedoc "The `guardrails` group; see `Normandy.Guardrails`."
+  @type guardrails :: [
+          input: [Normandy.Guardrails.spec()],
+          output: [Normandy.Guardrails.spec()],
+          streaming_mode: :accumulate | :incremental,
+          chunk_size: pos_integer(),
+          on_violation: :block | :warn
+        ]
+
   @type t :: %__MODULE__{
           input_schema: struct(),
           output_schema: struct(),
@@ -33,17 +56,14 @@ defmodule Normandy.Agents.BaseAgentConfig do
           tool_registry: Registry.t() | nil,
           max_tool_iterations: pos_integer(),
           max_tool_concurrency: pos_integer(),
-          retry_options: keyword() | nil,
-          circuit_breaker: pid() | nil,
+          retry: keyword() | nil,
+          circuit_breaker: keyword() | nil,
+          circuit_breaker_pid: pid() | nil,
           enable_json_retry: boolean(),
           json_retry_max_attempts: pos_integer(),
           name: String.t() | nil,
           mcp_servers: list() | nil,
-          input_guardrails: [Normandy.Guardrails.spec()],
-          output_guardrails: [Normandy.Guardrails.spec()],
-          output_guardrails_streaming_mode: :accumulate | :incremental,
-          output_guardrails_chunk_size: pos_integer(),
-          output_guardrails_on_violation: :block | :warn,
+          guardrails: guardrails(),
           behaviours: Normandy.Behaviours.Config.t() | nil,
           resolved_context_window: {String.t(), pos_integer()} | nil,
           session_id: String.t() | nil,
@@ -68,19 +88,29 @@ defmodule Normandy.Agents.BaseAgentConfig do
     field(:tool_registry, :struct, default: nil)
     field(:max_tool_iterations, :integer, default: 5)
     field(:max_tool_concurrency, :integer, default: 1)
-    field(:retry_options, :map, default: nil)
+    field(:retry, :any, default: nil)
     field(:circuit_breaker, :any, default: nil)
+    field(:circuit_breaker_pid, :any, default: nil)
     field(:enable_json_retry, :boolean, default: true)
     field(:json_retry_max_attempts, :integer, default: 2)
     field(:mcp_servers, :any, default: nil)
-    field(:input_guardrails, :any, default: [])
-    field(:output_guardrails, :any, default: [])
-    field(:output_guardrails_streaming_mode, :any, default: :accumulate)
-    field(:output_guardrails_chunk_size, :integer, default: 200)
-    field(:output_guardrails_on_violation, :any, default: :block)
+    field(:guardrails, :any, default: @default_guardrails)
     field(:behaviours, :any, default: nil)
     field(:resolved_context_window, :any, default: nil)
     field(:session_id, :string, default: nil)
     field(:tool_context, :map, default: %{})
   end
+
+  @doc "The `guardrails` a config has when it sets none."
+  @spec default_guardrails() :: guardrails()
+  def default_guardrails, do: @default_guardrails
+
+  @doc """
+  One `guardrails` setting of `config`; a key left out of a hand-built `guardrails` list
+  reads as its default (`default_guardrails/0`).
+  """
+  @spec guardrail(t(), :input | :output | :streaming_mode | :chunk_size | :on_violation) ::
+          term()
+  def guardrail(%__MODULE__{guardrails: guardrails}, key) when is_list(guardrails),
+    do: Keyword.get_lazy(guardrails, key, fn -> Keyword.fetch!(@default_guardrails, key) end)
 end
```

(`default_guardrails/0` and `guardrail/2` go after the `schema do ... end` block: a
`%__MODULE__{}` pattern before the struct is defined does not compile.)

Apply to `lib/normandy/agents/base_agent/init_options.ex`:

```diff
diff --git a/lib/normandy/agents/base_agent/init_options.ex b/lib/normandy/agents/base_agent/init_options.ex
index b33b51f..fa1f3f2 100644
--- a/lib/normandy/agents/base_agent/init_options.ex
+++ b/lib/normandy/agents/base_agent/init_options.ex
@@ -68,27 +68,22 @@ defmodule Normandy.Agents.BaseAgent.InitOptions do
       type_doc: "`t:integer/0`",
       doc: "Tool calls run at once; a value below 1 counts as 1."
     ],
-    retry_options: [
+    retry: [
       type: {:custom, __MODULE__, :retry, []},
       default: nil,
       type_doc: "`t:keyword/0` or `nil`",
       doc: "`Normandy.Resilience.Retry` options for LLM calls; `nil` makes one attempt."
     ],
-    enable_circuit_breaker: [
-      type: :boolean,
-      default: false,
-      doc: "Starts a `Normandy.Resilience.CircuitBreaker` linked to the caller."
-    ],
-    circuit_breaker_options: [
-      type: :keyword_list,
-      default: [],
-      keys: [
-        failure_threshold: [type: :pos_integer, doc: "Failures before it opens."],
-        success_threshold: [type: :pos_integer, doc: "Successes that close it from half-open."],
-        timeout: [type: :pos_integer, doc: "Milliseconds open before half-open."],
-        half_open_max_calls: [type: :pos_integer, doc: "Calls let through when half-open."]
-      ],
-      doc: "The circuit breaker's options."
+    circuit_breaker: [
+      type: {:custom, __MODULE__, :circuit_breaker, []},
+      default: nil,
+      type_doc: "`t:keyword/0` or `nil`",
+      doc:
+        "Starts a `Normandy.Resilience.CircuitBreaker`, linked to the caller, with these " <>
+          "options: `:failure_threshold` (failures before it opens), `:success_threshold` " <>
+          "(successes that close it from half-open), `:timeout` (milliseconds open before " <>
+          "half-open), `:half_open_max_calls` (calls let through when half-open). `[]` uses " <>
+          "the breaker's defaults; `nil` starts none."
     ],
     enable_json_retry: [
       type: :boolean,
@@ -96,30 +91,29 @@ defmodule Normandy.Agents.BaseAgent.InitOptions do
       doc: "Asks the model again when its JSON does not parse."
     ],
     json_retry_max_attempts: [type: :pos_integer, default: 2, doc: "JSON re-asks per call."],
-    input_guardrails: [
-      type: {:list, @guard_spec},
-      default: [],
-      doc: "Guards for the input (`Normandy.Guardrails`)."
-    ],
-    output_guardrails: [
-      type: {:list, @guard_spec},
+    guardrails: [
+      type: :keyword_list,
       default: [],
-      doc: "Guards for the answer (`Normandy.Guardrails`)."
-    ],
-    output_guardrails_streaming_mode: [
-      type: {:in, [:accumulate, :incremental]},
-      default: :accumulate,
-      doc: "When `stream/3` checks the output guards."
-    ],
-    output_guardrails_chunk_size: [
-      type: :pos_integer,
-      default: 200,
-      doc: "Bytes of streamed text between incremental checks."
-    ],
-    output_guardrails_on_violation: [
-      type: {:in, [:block, :warn]},
-      default: :block,
-      doc: "What an output violation does."
+      keys: [
+        input: [type: {:list, @guard_spec}, default: [], doc: "Guards for the input."],
+        output: [type: {:list, @guard_spec}, default: [], doc: "Guards for the answer."],
+        streaming_mode: [
+          type: {:in, [:accumulate, :incremental]},
+          default: :accumulate,
+          doc: "When `stream/3` checks the output guards."
+        ],
+        chunk_size: [
+          type: :pos_integer,
+          default: 200,
+          doc: "Bytes of streamed text between incremental checks."
+        ],
+        on_violation: [
+          type: {:in, [:block, :warn]},
+          default: :block,
+          doc: "What an output violation does."
+        ]
+      ],
+      doc: "`Normandy.Guardrails` guards and how they apply."
     ],
     name: [type: {:or, [:string, nil]}, default: nil, doc: "The agent's name."],
     session_id: [
@@ -160,6 +154,26 @@ defmodule Normandy.Agents.BaseAgent.InitOptions do
       "cap the memory with memory: Normandy.Components.AgentMemory.new_memory(max_messages)"
   ]
 
+  # 1.x init/1 options that 2.0 renamed or regrouped.
+  @renamed [
+    retry_options: "was renamed to :retry",
+    enable_circuit_breaker:
+      "was removed: circuit_breaker: [] (or the breaker's options) starts a breaker",
+    circuit_breaker_options: "was renamed to :circuit_breaker",
+    input_guardrails: "moved to guardrails: [input: ...]",
+    output_guardrails: "moved to guardrails: [output: ...]",
+    output_guardrails_streaming_mode: "moved to guardrails: [streaming_mode: ...]",
+    output_guardrails_chunk_size: "moved to guardrails: [chunk_size: ...]",
+    output_guardrails_on_violation: "moved to guardrails: [on_violation: ...]"
+  ]
+
+  @breaker_schema NimbleOptions.new!(
+                    failure_threshold: [type: :pos_integer],
+                    success_threshold: [type: :pos_integer],
+                    timeout: [type: :pos_integer],
+                    half_open_max_calls: [type: :pos_integer]
+                  )
+
   @init {Normandy.Agents.BaseAgent, :init, 1}
 
   @doc false
@@ -184,12 +198,22 @@ defmodule Normandy.Agents.BaseAgent.InitOptions do
   end
 
   @doc false
-  # Raises for a key in @hints that `schema` does not itself accept, naming the key, where
-  # the setting lives, and `schema`'s options.
+  # Raises for a 1.x key in @renamed, naming its 2.0 home, and for a key in @hints that
+  # `schema` does not itself accept, naming where the setting lives and `schema`'s options.
   @spec check_misnamed!(term(), NimbleOptions.t(), {module(), atom(), arity()}) :: :ok
   def check_misnamed!(opts, %NimbleOptions{} = schema, {mod, fun, arity}) do
     keys = option_keys(opts)
     supported = Keyword.keys(schema.schema)
+    prefix = "#{inspect(mod)}.#{fun}/#{arity}"
+
+    case Enum.find(@renamed, fn {key, _change} -> key in keys end) do
+      {key, change} ->
+        raise ArgumentError,
+              "#{prefix}: #{inspect(key)} #{change} in 2.0; see MIGRATING-2.0.md §22"
+
+      nil ->
+        :ok
+    end
 
     case Enum.find(@hints, fn {key, _hint} -> key in keys and key not in supported end) do
       nil ->
@@ -197,7 +221,7 @@ defmodule Normandy.Agents.BaseAgent.InitOptions do
 
       {key, hint} ->
         raise ArgumentError,
-              "#{inspect(mod)}.#{fun}/#{arity}: unknown option #{inspect(key)}; #{hint}; " <>
+              "#{prefix}: unknown option #{inspect(key)}; #{hint}; " <>
                 "supported: #{Enum.map_join(supported, ", ", &inspect/1)}"
     end
   end
@@ -285,4 +309,21 @@ defmodule Normandy.Agents.BaseAgent.InitOptions do
 
   def retry(other),
     do: {:error, "expected a keyword list or nil, got #{Describe.type_of(other)}"}
+
+  @doc false
+  def circuit_breaker(nil), do: {:ok, nil}
+
+  def circuit_breaker(opts) when is_list(opts) do
+    if Keyword.keyword?(opts) do
+      case NimbleOptions.validate(opts, @breaker_schema) do
+        {:ok, validated} -> {:ok, validated}
+        {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
+      end
+    else
+      {:error, "expected a keyword list or nil, got a list that is not one"}
+    end
+  end
+
+  def circuit_breaker(other),
+    do: {:error, "expected a keyword list or nil, got #{Describe.type_of(other)}"}
 end
```

`circuit_breaker/1` validates the nested options itself instead of a `keys:` schema under
`{:or, [nil, :keyword_list]}`: NimbleOptions 1.1.1 crashes with `FunctionClauseError` validating a
`nil` default against nested `keys:` (verified), and an `{:or, ...}` error lists every branch's
failure.

- [ ] **Step 4: Implement the readers, templates, DSL and docs**

Apply to `lib/normandy/agents/base_agent.ex`:

```diff
diff --git a/lib/normandy/agents/base_agent.ex b/lib/normandy/agents/base_agent.ex
index 90c32bf..a649763 100644
--- a/lib/normandy/agents/base_agent.ex
+++ b/lib/normandy/agents/base_agent.ex
@@ -80,7 +80,7 @@ defmodule Normandy.Agents.BaseAgent do
 
     # Every check is above: the breaker starts last, so a bad option never leaves a
     # linked process behind.
-    circuit_breaker = start_circuit_breaker(opts)
+    circuit_breaker_pid = start_circuit_breaker(opts)
     memory = Keyword.fetch!(opts, :memory) || AgentMemory.new_memory()
 
     %BaseAgentConfig{
@@ -97,27 +97,28 @@ defmodule Normandy.Agents.BaseAgent do
       tool_registry: Keyword.fetch!(opts, :tool_registry),
       max_tool_iterations: Keyword.fetch!(opts, :max_tool_iterations),
       max_tool_concurrency: Keyword.fetch!(opts, :max_tool_concurrency),
-      retry_options: Keyword.fetch!(opts, :retry_options),
-      circuit_breaker: circuit_breaker,
+      retry: Keyword.fetch!(opts, :retry),
+      circuit_breaker: Keyword.fetch!(opts, :circuit_breaker),
+      circuit_breaker_pid: circuit_breaker_pid,
       enable_json_retry: Keyword.fetch!(opts, :enable_json_retry),
       json_retry_max_attempts: Keyword.fetch!(opts, :json_retry_max_attempts),
       mcp_servers: Keyword.fetch!(opts, :mcp_servers),
       name: Keyword.fetch!(opts, :name),
       session_id: Keyword.fetch!(opts, :session_id),
       tool_context: Keyword.fetch!(opts, :tool_context),
-      input_guardrails: Keyword.fetch!(opts, :input_guardrails),
-      output_guardrails: Keyword.fetch!(opts, :output_guardrails),
-      output_guardrails_streaming_mode: Keyword.fetch!(opts, :output_guardrails_streaming_mode),
-      output_guardrails_chunk_size: Keyword.fetch!(opts, :output_guardrails_chunk_size),
-      output_guardrails_on_violation: Keyword.fetch!(opts, :output_guardrails_on_violation),
+      guardrails: Keyword.fetch!(opts, :guardrails),
       behaviours: behaviours
     }
   end
 
   defp start_circuit_breaker(opts) do
-    if Keyword.fetch!(opts, :enable_circuit_breaker) do
-      {:ok, pid} = CircuitBreaker.start_link(Keyword.fetch!(opts, :circuit_breaker_options))
-      pid
+    case Keyword.fetch!(opts, :circuit_breaker) do
+      nil ->
+        nil
+
+      breaker_opts ->
+        {:ok, pid} = CircuitBreaker.start_link(breaker_opts)
+        pid
     end
   end
 
@@ -152,9 +153,14 @@ defmodule Normandy.Agents.BaseAgent do
           :ok | {:block, [Normandy.Guardrails.Guard.violation()]}
   def admit(config, value, context \\ %{})
 
-  def admit(%BaseAgentConfig{input_guardrails: []}, _value, _context), do: :ok
+  def admit(%BaseAgentConfig{} = config, value, context) do
+    case BaseAgentConfig.guardrail(config, :input) do
+      [] -> :ok
+      guards -> admit_with(config, guards, value, context)
+    end
+  end
 
-  def admit(%BaseAgentConfig{input_guardrails: guards} = config, value, context) do
+  defp admit_with(config, guards, value, context) do
     case Normandy.Guardrails.run(guards, value, context) do
       {:ok, _value} ->
         emit_guardrail_decision(:admit, config, guards, [])
@@ -308,20 +314,20 @@ defmodule Normandy.Agents.BaseAgent do
     end
   end
 
-  # Retry (retry_options) inside the circuit breaker (circuit_breaker), each only
+  # Retry (config.retry) inside the circuit breaker (circuit_breaker_pid), each only
   # when configured. `may_retry?` is checked before each retry on top of the
   # retry_if policy; streaming uses it to stop once output reached the caller.
   defp with_resilience(config, call, may_retry? \\ fn -> true end) do
     retryable_call =
-      if config.retry_options do
-        retry_opts = retry_options(config.retry_options, may_retry?)
+      if config.retry do
+        retry_opts = retry_options(config.retry, may_retry?)
         fn -> Retry.with_retry(call, retry_opts) end
       else
         call
       end
 
-    if config.circuit_breaker do
-      CircuitBreaker.call(config.circuit_breaker, retryable_call)
+    if config.circuit_breaker_pid do
+      CircuitBreaker.call(config.circuit_breaker_pid, retryable_call)
     else
       retryable_call.()
     end
@@ -440,10 +446,10 @@ defmodule Normandy.Agents.BaseAgent do
   parse is not re-asked. The same holds for `run/3`'s final answer after a tool loop; a
   `run/3` without tools re-asks through the adapter.
 
-  `retry_options` and the circuit breaker apply, but a stream is retried only until its
+  `retry` and the circuit breaker apply, but a stream is retried only until its
   first event reaches the callback, so no output is shown twice. Output guardrails
   report (`:guardrail_violation` event, telemetry) and don't block: the text was already
-  delivered; with `output_guardrails_streaming_mode: :incremental` a violation stops
+  delivered; with `guardrails: [streaming_mode: :incremental]` a violation stops
   the stream at the next chunk boundary.
 
   ## Example
@@ -1419,21 +1425,16 @@ defmodule Normandy.Agents.BaseAgent do
         stream = Stream.each(stream, &deliver_stream_event(&1, callback))
 
         # credo:disable-for-next-line Credo.Check.Refactor.Nesting
-        case config do
-          %BaseAgentConfig{
-            output_guardrails: [_ | _],
-            output_guardrails_streaming_mode: :incremental
-          } ->
-            consume_stream_with_incremental_guards(stream, config, callback)
-
-          _ ->
-            events = Enum.to_list(stream)
-
-            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
-            case StreamProcessor.stream_error(events) do
-              nil -> {:ok, StreamProcessor.build_final_message(events)}
-              %LLMError{} = error -> {:error, stream_error_with_usage(error, events)}
-            end
+        if incremental_output_guards?(config) do
+          consume_stream_with_incremental_guards(stream, config, callback)
+        else
+          events = Enum.to_list(stream)
+
+          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
+          case StreamProcessor.stream_error(events) do
+            nil -> {:ok, StreamProcessor.build_final_message(events)}
+            %LLMError{} = error -> {:error, stream_error_with_usage(error, events)}
+          end
         end
 
       {:error, %LLMError{}} = error ->
@@ -1478,7 +1479,7 @@ defmodule Normandy.Agents.BaseAgent do
   defp deliver_stream_event(_event, _callback), do: :ok
 
   # Consumes a stream event-by-event, running output guards every
-  # `output_guardrails_chunk_size` bytes of accumulated text. On violation,
+  # `guardrails[:chunk_size]` bytes of accumulated text. On violation,
   # halts consumption, emits telemetry + the :guardrail_violation callback
   # event, strips any partial tool-use block from the response, and returns
   # `{:ok, final_message}`. A stream that failed (error event,
@@ -1486,8 +1487,8 @@ defmodule Normandy.Agents.BaseAgent do
   # `{:error, %LLMError{}}`; a guardrail halt is a deliberate stop, not a failure.
   # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
   defp consume_stream_with_incremental_guards(stream, config, callback) do
-    guards = config.output_guardrails
-    chunk_size = config.output_guardrails_chunk_size
+    guards = BaseAgentConfig.guardrail(config, :output)
+    chunk_size = BaseAgentConfig.guardrail(config, :chunk_size)
 
     initial = %{events: [], accumulated: "", since_last_check: 0, violations: [], halted?: false}
 
@@ -2148,19 +2149,24 @@ defmodule Normandy.Agents.BaseAgent do
   end
 
   # Runs output guardrails before the answer is appended to memory. A violation
-  # raises (output_guardrails_on_violation: :block, the default), so the answer
+  # raises (guardrails[:on_violation] == :block, the default), so the answer
   # is neither returned nor saved; with :warn it is logged and the turn goes on.
   # Telemetry is emitted either way.
-  defp run_output_guardrails(%BaseAgentConfig{output_guardrails: []}, _value), do: :ok
+  defp run_output_guardrails(%BaseAgentConfig{} = config, value) do
+    case BaseAgentConfig.guardrail(config, :output) do
+      [] -> :ok
+      guards -> check_output(config, guards, value)
+    end
+  end
 
-  defp run_output_guardrails(%BaseAgentConfig{output_guardrails: guards} = config, value) do
+  defp check_output(config, guards, value) do
     case Normandy.Guardrails.run(guards, value) do
       {:ok, _value} ->
         :ok
 
       {:error, violations} ->
         emit_guardrail_violation(:output, config, guards, violations)
-        output_violation(config.output_guardrails_on_violation, violations)
+        output_violation(BaseAgentConfig.guardrail(config, :on_violation), violations)
     end
   end
 
@@ -2231,21 +2237,15 @@ defmodule Normandy.Agents.BaseAgent do
   # (logged and reported, not blocked: the text already reached the caller); :incremental is a
   # no-op here because guards already ran at chunk boundaries inside
   # `consume_stream_with_incremental_guards/3`. Returns :ok.
-  defp run_streaming_output_guardrails(%BaseAgentConfig{output_guardrails: []}, _message, _cb),
-    do: :ok
+  defp run_streaming_output_guardrails(%BaseAgentConfig{} = config, message, callback) do
+    guards = BaseAgentConfig.guardrail(config, :output)
 
-  defp run_streaming_output_guardrails(
-         %BaseAgentConfig{output_guardrails_streaming_mode: :incremental},
-         _message,
-         _callback
-       ),
-       do: :ok
+    if guards == [] or BaseAgentConfig.guardrail(config, :streaming_mode) == :incremental,
+      do: :ok,
+      else: check_streamed_text(config, guards, message, callback)
+  end
 
-  defp run_streaming_output_guardrails(
-         %BaseAgentConfig{output_guardrails: guards} = config,
-         message,
-         callback
-       ) do
+  defp check_streamed_text(config, guards, message, callback) do
     case Normandy.Guardrails.run(guards, extract_streaming_text(message)) do
       {:ok, _} ->
         :ok
@@ -2283,4 +2283,9 @@ defmodule Normandy.Agents.BaseAgent do
   end
 
   defp extract_streaming_text(_), do: ""
+
+  defp incremental_output_guards?(config) do
+    BaseAgentConfig.guardrail(config, :output) != [] and
+      BaseAgentConfig.guardrail(config, :streaming_mode) == :incremental
+  end
 end
```

Apply to `lib/normandy/agents/config_template.ex`, `lib/normandy/behaviours/agent_template.ex`,
`lib/normandy/dsl/agent.ex`, `lib/normandy/guardrails.ex`, `lib/normandy/llm/claudio_adapter.ex`,
`lib/normandy/resilience/retry.ex`:

```diff
diff --git a/lib/normandy/agents/config_template.ex b/lib/normandy/agents/config_template.ex
index 36e67c6..4f65ac7 100644
--- a/lib/normandy/agents/config_template.ex
+++ b/lib/normandy/agents/config_template.ex
@@ -6,13 +6,13 @@ defmodule Normandy.Agents.ConfigTemplate do
 
   Excluded from the template (resolved node-locally instead): `client` (built from
   the token), `tool_registry` and `before/after_hooks` (from the supplement), and
-  `circuit_breaker` and `mcp_servers` (from the supplement; the template records
+  `circuit_breaker_pid` and `mcp_servers` (from the supplement; the template records
   only that they were set, and `rebuild/3` raises if the supplement lacks one).
   `current_user_input` and `resolved_context_window` are transient and not kept.
 
   Everything else travels in the template: model and sampling settings, tool
-  limits, prompt, schemas, memory cap, `initial_memory`, `retry_options`, JSON
-  retry settings, guardrails, `tool_context`, behaviour module refs and hook entries
+  limits, prompt, schemas, memory cap, `initial_memory`, the `retry` and
+  `circuit_breaker` options, JSON retry settings, `guardrails`, `tool_context`, behaviour module refs and hook entries
   (`Normandy.Behaviours.Hooks`; their opts must be plain data and hold no secrets).
   These must be plain data: `from_config/2` raises on a function or pid (e.g. a `:retry_if` fun).
   `tool_context` must hold no secrets: the template is stored in plaintext.
@@ -28,21 +28,18 @@ defmodule Normandy.Agents.ConfigTemplate do
   # them, so `rebuild/3` leaves the struct defaults in place for missing keys.
   @data_fields [
     :initial_memory,
-    :retry_options,
+    :retry,
+    :circuit_breaker,
     :enable_json_retry,
     :json_retry_max_attempts,
-    :input_guardrails,
-    :output_guardrails,
-    :output_guardrails_streaming_mode,
-    :output_guardrails_chunk_size,
-    :output_guardrails_on_violation,
+    :guardrails,
     :tool_context
   ]
 
   # Fields a template cannot hold (a linked pid; MCP settings that may carry an
   # authorization token). The template records which were set, and `rebuild/3`
   # takes them from the supplement.
-  @node_local_fields [:circuit_breaker, :mcp_servers]
+  @node_local_fields [:circuit_breaker_pid, :mcp_servers]
 
   @spec from_config(BaseAgentConfig.t(), String.t()) :: map()
   def from_config(%BaseAgentConfig{} = c, template_id) do
diff --git a/lib/normandy/behaviours/agent_template.ex b/lib/normandy/behaviours/agent_template.ex
index b783065..606468a 100644
--- a/lib/normandy/behaviours/agent_template.ex
+++ b/lib/normandy/behaviours/agent_template.ex
@@ -3,7 +3,7 @@ defmodule Normandy.Behaviours.AgentTemplate do
   Resolves the **node-local, non-serializable** half of an agent's config from a
   stable `template_id`: the tool registry, before/after hooks, and a
   `client_builder` that turns a credential token into an LLM client struct.
-  Optionally `:circuit_breaker` (a node-local breaker) and `:mcp_servers` (which may
+  Optionally `:circuit_breaker_pid` (a node-local breaker) and `:mcp_servers` (which may
   carry authorization tokens); `ConfigTemplate.rebuild/3` requires each one the
   original config had set.
 
@@ -19,7 +19,7 @@ defmodule Normandy.Behaviours.AgentTemplate do
           required(:before_hooks) => [term()],
           required(:after_hooks) => [term()],
           required(:client_builder) => (String.t() -> struct()),
-          optional(:circuit_breaker) => GenServer.server(),
+          optional(:circuit_breaker_pid) => GenServer.server(),
           optional(:mcp_servers) => [term()]
         }
 
diff --git a/lib/normandy/dsl/agent.ex b/lib/normandy/dsl/agent.ex
index c9f7ad8..8d4d703 100644
--- a/lib/normandy/dsl/agent.ex
+++ b/lib/normandy/dsl/agent.ex
@@ -446,13 +446,17 @@ defmodule Normandy.DSL.Agent do
 
     config =
       base_config
-      |> Map.merge(Map.new(overrides))
+      |> Map.merge(Map.new(overrides), &merge_override/3)
       |> put_declared_hooks(compile_config.hooks)
       |> put_memory_cap(max_messages)
 
     {config, memory_store}
   end
 
+  # A :guardrails override changes only the keys it gives; the rest stay as declared.
+  defp merge_override(:guardrails, declared, given), do: Keyword.merge(declared, given)
+  defp merge_override(_key, _declared, given), do: given
+
   # BaseAgent.init/1 takes the cap through the memory; a given :memory wins.
   defp put_memory_cap(config, nil), do: config
   defp put_memory_cap(%{memory: _} = config, _cap), do: config
@@ -516,14 +520,15 @@ defmodule Normandy.DSL.Agent do
         tools: Module.get_attribute(__MODULE__, :agent_tools, []) |> Enum.reverse(),
         memory: Module.get_attribute(__MODULE__, :agent_memory),
         hooks: Module.get_attribute(__MODULE__, :agent_hooks) || [],
-        input_guardrails: Module.get_attribute(__MODULE__, :agent_input_guardrails, []),
-        output_guardrails: Module.get_attribute(__MODULE__, :agent_output_guardrails, []),
-        output_guardrails_streaming_mode:
-          Module.get_attribute(__MODULE__, :agent_output_guardrails_streaming_mode, :accumulate),
-        output_guardrails_chunk_size:
-          Module.get_attribute(__MODULE__, :agent_output_guardrails_chunk_size, 200),
-        output_guardrails_on_violation:
-          Module.get_attribute(__MODULE__, :agent_output_guardrails_on_violation, :block)
+        guardrails: [
+          input: Module.get_attribute(__MODULE__, :agent_input_guardrails, []),
+          output: Module.get_attribute(__MODULE__, :agent_output_guardrails, []),
+          streaming_mode:
+            Module.get_attribute(__MODULE__, :agent_output_guardrails_streaming_mode, :accumulate),
+          chunk_size: Module.get_attribute(__MODULE__, :agent_output_guardrails_chunk_size, 200),
+          on_violation:
+            Module.get_attribute(__MODULE__, :agent_output_guardrails_on_violation, :block)
+        ]
       }
 
       # Store additional config at compile time
@@ -611,12 +616,7 @@ defmodule Normandy.DSL.Agent do
           tools: @agent_compile_config.tools,
           hooks: @agent_compile_config.hooks,
           max_messages: @agent_compile_config.max_messages,
-          input_guardrails: @agent_compile_config.input_guardrails,
-          output_guardrails: @agent_compile_config.output_guardrails,
-          output_guardrails_streaming_mode:
-            @agent_compile_config.output_guardrails_streaming_mode,
-          output_guardrails_chunk_size: @agent_compile_config.output_guardrails_chunk_size,
-          output_guardrails_on_violation: @agent_compile_config.output_guardrails_on_violation
+          guardrails: @agent_compile_config.guardrails
         }
       end
 
@@ -633,12 +633,7 @@ defmodule Normandy.DSL.Agent do
           max_tokens: @agent_compile_config.max_tokens,
           max_tool_concurrency: @agent_compile_config.max_tool_concurrency,
           name: @agent_name,
-          input_guardrails: @agent_compile_config.input_guardrails,
-          output_guardrails: @agent_compile_config.output_guardrails,
-          output_guardrails_streaming_mode:
-            @agent_compile_config.output_guardrails_streaming_mode,
-          output_guardrails_chunk_size: @agent_compile_config.output_guardrails_chunk_size,
-          output_guardrails_on_violation: @agent_compile_config.output_guardrails_on_violation
+          guardrails: @agent_compile_config.guardrails
         }
       end
 
diff --git a/lib/normandy/guardrails.ex b/lib/normandy/guardrails.ex
index f9a9575..3e20038 100644
--- a/lib/normandy/guardrails.ex
+++ b/lib/normandy/guardrails.ex
@@ -20,9 +20,9 @@ defmodule Normandy.Guardrails do
       iex> Guardrails.run([{MaxLength, limit: 100}], "ok")
       {:ok, "ok"}
 
-  Attach a guard list to an agent by setting `:input_guardrails` or
-  `:output_guardrails` on `Normandy.Agents.BaseAgentConfig`, or via the
-  `guardrails/2` macro in `Normandy.DSL.Agent`.
+  Attach a guard list to an agent with `guardrails: [input: ..., output: ...]` in
+  `Normandy.Agents.BaseAgent.init/1`, or with the `guardrails/2` macro in
+  `Normandy.DSL.Agent`.
 
   ## Pre-charge admission
 
@@ -74,7 +74,7 @@ defmodule Normandy.Guardrails do
   `constraint: :off_topic` lets the caller render scope-specific messaging
   without parsing strings. Extra keys on the violation map are allowed.
 
-  ## Output violations (`:output_guardrails_on_violation`)
+  ## Output violations (`guardrails: [on_violation: ...]`)
 
   On the non-streaming path (`BaseAgent.run/3`, `Turn.Server`), output guards
   run on the validated answer before it is saved to memory:
@@ -105,7 +105,7 @@ defmodule Normandy.Guardrails do
     `{ForbiddenSubstrings, field: :summary}`) do not apply in streaming mode. Use
     bare string guards (no `:field`) for streaming output.
 
-  - `:incremental` — guards run every `:output_guardrails_chunk_size` bytes of
+  - `:incremental` — guards run every `guardrails[:chunk_size]` bytes of
     accumulated assistant text. On violation, the stream is halted, a
     `:guardrail_violation` event is emitted to the caller callback and telemetry,
     and any partial tool-use block is dropped; the text streamed so far is
diff --git a/lib/normandy/llm/claudio_adapter.ex b/lib/normandy/llm/claudio_adapter.ex
index 89c58be..2d3b63f 100644
--- a/lib/normandy/llm/claudio_adapter.ex
+++ b/lib/normandy/llm/claudio_adapter.ex
@@ -90,7 +90,7 @@ defmodule Normandy.LLM.ClaudioAdapter do
     when the schema has no `:chat_message` field to put the raw text in
 
   Claudio's client-level `retry:` (in `req_options` or the client config) retries HTTP
-  failures before Normandy sees them; enabling it together with `retry_options`
+  failures before Normandy sees them; enabling it together with the agent's `retry`
   multiplies the attempts.
 
   `validate_options!/1` checks the option combinations and values above once, up front;
diff --git a/lib/normandy/resilience/retry.ex b/lib/normandy/resilience/retry.ex
index 2acc31b..43b896e 100644
--- a/lib/normandy/resilience/retry.ex
+++ b/lib/normandy/resilience/retry.ex
@@ -133,7 +133,7 @@ defmodule Normandy.Resilience.Retry do
   @doc """
   Checks retry options without running anything, raising `ArgumentError` on an
   unknown option or a bad value. `BaseAgent.init/1` calls it for
-  `:retry_options`, so a mistake surfaces when the agent is built.
+  `:retry`, so a mistake surfaces when the agent is built.
   """
   @spec validate_options!(retry_options()) :: :ok
   def validate_options!(opts) do
```

Run: `mix compile --warnings-as-errors` → exit 0. Then
`mix test test/agents/base_agent_config_groups_test.exs test/dsl/agent_guardrails_test.exs`:
the config-groups tests pass; `agent_guardrails_test.exs` still fails on its old field reads until
Step 5.

- [ ] **Step 5: Rewrite the 1.x keys in tests and e2e (mechanical)**

Find the files:

```bash
grep -rlE "input_guardrails|output_guardrails|retry_options|enable_circuit_breaker|circuit_breaker_options|\.circuit_breaker\b" \
  test e2e/06_resilience.exs e2e/07_guardrails.exs e2e/08_streaming.exs \
  \
  | grep -v -e "^test/support/integration_helper.ex" -e "^test/agents/base_agent_config_groups_test.exs"
```

Expected: the 24 files in the table below (the integration helper is a hand edit in Step 6).
Save this script as `/tmp/regroup_32b.pl` (it is not committed) and run it on them:

```perl
#!/usr/bin/perl
# Task 3.2b mechanical rewrite of 1.x config keys in test and e2e sources.
#
#   1. A run of 1.x guardrail options in a map, keyword list or struct literal/update
#      (`input_guardrails: A, output_guardrails: B, output_guardrails_streaming_mode: C,
#      output_guardrails_chunk_size: D, output_guardrails_on_violation: E`, any subset, in any
#      order, separated only by commas and whitespace) becomes one
#      `guardrails: [input: A, output: B, streaming_mode: C, chunk_size: D, on_violation: E]`.
#   2. A read of one of those fields (`x.input_guardrails`, `x.output_guardrails_chunk_size`,
#      `Mod.config().output_guardrails_on_violation`, ...) becomes `x.guardrails[:input]`, ...
#   3. `enable_circuit_breaker: true, circuit_breaker_options: X` becomes `circuit_breaker: X`;
#      a lone `enable_circuit_breaker: true` becomes `circuit_breaker: []`.
#   4. `retry_options:` (an option key) becomes `retry:`.
#   5. A read `x.circuit_breaker` becomes `x.circuit_breaker_pid`.
#
# Keys preceded by `:` (atoms such as `:output_guardrails` in `Map.put/3` or regexes) and text
# inside strings that is not followed by `: ` are left alone; Step 6 of Task 3.2b lists the
# few sites that need a hand edit. Prints "<file>: <n> rewrites" per file.
use strict;

my %group = (
  input_guardrails => 'input',
  output_guardrails => 'output',
  output_guardrails_streaming_mode => 'streaming_mode',
  output_guardrails_chunk_size => 'chunk_size',
  output_guardrails_on_violation => 'on_violation',
);
my $keys = join('|', sort { length($b) <=> length($a) } keys %group);

# Returns the index just past a value starting at $i: stops at a depth-0 `,` or closing bracket.
sub value_end {
  my ($s, $i) = @_;
  my $depth = 0;
  my $n = length($s);
  while ($i < $n) {
    my $c = substr($s, $i, 1);
    if ($c eq '"') {
      $i++;
      while ($i < $n && substr($s, $i, 1) ne '"') { $i += (substr($s, $i, 1) eq '\\') ? 2 : 1 }
      $i++;
      next;
    }
    if ($c eq '~' && substr($s, $i + 1, 1) =~ /[a-zA-Z]/) {
      my $open = substr($s, $i + 2, 1);
      my %close = ('/' => '/', '(' => ')', '[' => ']', '{' => '}', '|' => '|', '"' => '"');
      my $cl = $close{$open} // die "unknown sigil delimiter $open";
      $i += 3;
      while ($i < $n && substr($s, $i, 1) ne $cl) { $i += (substr($s, $i, 1) eq '\\') ? 2 : 1 }
      $i++;
      $i++ while $i < $n && substr($s, $i, 1) =~ /[a-z]/;
      next;
    }
    if ($c =~ /[\[\{\(]/) { $depth++ }
    elsif ($c =~ /[\]\}\)]/) { return $i if $depth == 0; $depth-- }
    elsif ($c eq ',' && $depth == 0) { return $i }
    elsif ($c eq "\n" && $depth == 0) {
      # a value ends at a depth-0 newline unless the next line continues an expression
      my $rest = substr($s, $i + 1);
      return $i unless $rest =~ /^\s*(\||<>|\+\+|and\b|or\b)/;
    }
    $i++;
  }
  return $i;
}

for my $file (@ARGV) {
  local $/;
  open(my $fh, '<', $file) or die "$file: $!";
  my $s = <$fh>;
  close $fh;
  my $count = 0;

  # 1. guardrail option runs
  my $out = '';
  my $pos = 0;
  while ($s =~ /(?<![\w.:])($keys):[ \t]*/g) {
    my $start = $-[0];
    next if $start < $pos;
    my @pairs;
    my $i = $+[0];
    my $key = $1;
    while (1) {
      my $vend = value_end($s, $i);
      my $value = substr($s, $i, $vend - $i);
      $value =~ s/\s+\z//;
      push @pairs, "$group{$key}: $value";
      # another guardrail key after `,` and whitespace?
      my $tail = substr($s, $vend);
      if ($tail =~ /\A(,\s*)($keys):[ \t]*/) {
        $key = $2;
        $i = $vend + $+[0];
        next;
      }
      # end of run: keep a trailing comma/whitespace as it was
      my $end = $vend;
      my $after = substr($s, $vend);
      my ($ws) = ($after =~ /\A(\s*)/);
      # do not swallow the newline layout: value stripped of trailing ws above
      my $raw = substr($s, $start, $end - $start);
      my ($trail) = ($raw =~ /(\s*)\z/);
      $out .= substr($s, $pos, $start - $pos) . "guardrails: [" . join(', ', @pairs) . "]" . $trail;
      $pos = $end;
      $count++;
      last;
    }
    pos($s) = $pos;
  }
  $out .= substr($s, $pos);
  $s = $out;

  # 2. field reads
  $count += ($s =~ s/([\w\)\]])\.($keys)\b/"$1.guardrails[:$group{$2}]"/ge);

  # 3. circuit breaker options
  $count += ($s =~ s/(?<![\w.:])enable_circuit_breaker: true,(\s*)circuit_breaker_options:/circuit_breaker:/g);
  $count += ($s =~ s/(?<![\w.:])enable_circuit_breaker: true\b/circuit_breaker: []/g);

  # 4. retry
  $count += ($s =~ s/(?<![\w.:])retry_options:/retry:/g);

  # 5. breaker pid reads
  $count += ($s =~ s/([\w\)])\.circuit_breaker\b(?!_)/$1.circuit_breaker_pid/g);

  open(my $o, '>', $file) or die;
  print $o $s;
  close $o;
  print "$file: $count rewrites\n";
}
```

```bash
perl /tmp/regroup_32b.pl $(grep -rlE "input_guardrails|output_guardrails|retry_options|enable_circuit_breaker|circuit_breaker_options|\.circuit_breaker\b" \
  test e2e/06_resilience.exs e2e/07_guardrails.exs e2e/08_streaming.exs \
  \
  | grep -v -e "^test/support/integration_helper.ex" -e "^test/agents/base_agent_config_groups_test.exs")
```

Expected output (rewrites per file; verified on a scratch copy at the end of Task 3.2a):

| File | Rewrites |
|---|---|
| `test/integration/agent_resilience_integration_test.exs` | 4 |
| `test/agents/config_template_test.exs` | 4 |
| `test/agents/base_agent_admit_test.exs` | 8 |
| `test/agents/base_agent_run_result_test.exs` | 1 |
| `test/agents/base_agent_resilience_test.exs` | 22 |
| `test/agents/base_agent_streaming_guardrails_test.exs` | 14 |
| `test/agents/base_agent_stream_test.exs` | 1 |
| `test/agents/base_agent_init_options_test.exs` | 1 |
| `test/agents/base_agent_guardrails_test.exs` | 16 |
| `test/agents/base_agent_llm_error_test.exs` | 6 |
| `test/agents/base_agent_stream_resilience_test.exs` | 2 |
| `test/agents/base_agent_stream_errors_test.exs` | 1 |
| `test/agents/turn/server_test.exs` | 2 |
| `test/resilience/retry_test.exs` | 1 |
| `test/telemetry/span_hierarchy_test.exs` | 1 |
| `test/telemetry/llm_request_span_test.exs` | 3 |
| `test/hooks/base_agent_hooks_test.exs` | 0 (comment only; Step 6) |
| `test/telemetry/metadata_test.exs` | 2 |
| `test/telemetry/llm_call_request_metadata_test.exs` | 1 |
| `test/dsl/agent_streaming_guardrails_test.exs` | 8 |
| `test/dsl/agent_guardrails_test.exs` | 12 |
| `e2e/06_resilience.exs` | 3 |
| `e2e/07_guardrails.exs` | 2 |
| `e2e/08_streaming.exs` | 1 |

The tests added in Step 1 are safe: the new test file is excluded above, and the DSL test passes
the 1.x key as `{:input_guardrails, []}`, which the script does not match.

- [ ] **Step 6: Hand edits the script leaves**

| File | Old | New |
|---|---|---|
| `test/support/integration_helper.ex:116-117` (doc) | `` - `:retry_options` - Retry configuration`` / `` - `:enable_circuit_breaker` - Enable circuit breaker (default: false)`` | `` - `:retry` - Retry configuration`` / `` - `:circuit_breaker` - Circuit breaker options; starts one (default: nil, none)`` |
| `test/support/integration_helper.ex:135-137` | `retry_options: Keyword.get(opts, :retry_options),` / `enable_circuit_breaker: Keyword.get(opts, :enable_circuit_breaker, false),` / `circuit_breaker_options: Keyword.get(opts, :circuit_breaker_options, [])` | `retry: Keyword.get(opts, :retry),` / `circuit_breaker: Keyword.get(opts, :circuit_breaker)` |
| `test/agents/config_template_test.exs` (round trip, `:278-293`) | `%{circuit_breaker: cb, mcp_servers: servers}` (supplement), `\| circuit_breaker: cb,`, `\| circuit_breaker: self()`, `~r/:circuit_breaker/` | `circuit_breaker_pid:` in all three, `~r/:circuit_breaker_pid/` |
| `config_template_test.exs` | `test "rebuild raises when the template had a circuit breaker and the supplement has none"` | `... had a circuit breaker pid and ...` |
| `config_template_test.exs` | `test "from_config refuses a function in retry_options"`, `~r/from_config\/2.*:retry_options.*function/` | `test "from_config refuses a function in the retry options"`, `~r/from_config\/2.*:retry .*function/` |
| `config_template_test.exs` | `~r/:input_guardrails/` (guardrail-fun refusal) | `~r/from_config\/2: :guardrails contains a function/` |
| `config_template_test.exs` `full_config/1` | (none) | add `circuit_breaker: [failure_threshold: 3],` before `guardrails:`, so the round trip covers the breaker options |
| `test/agents/base_agent_stream_errors_test.exs` (`"a tail-check violation does not mask a stream error"`) | `config = Map.put(@incremental, :output_guardrails, [{ForbiddenSubstrings, terms: ["badwd"]}])` / `config = Map.put(config, :output_guardrails_chunk_size, 100)` | `config = %{@incremental \| guardrails: [output: [{ForbiddenSubstrings, terms: ["badwd"]}], streaming_mode: :incremental, chunk_size: 100]}` |
| `test/agents/base_agent_guardrails_test.exs` | `~r/:output_guardrails_on_violation option: expected one of \[:block, :warn\], got: :log/` | `~r/:on_violation option: expected one of \[:block, :warn\], got: :log \(in options \[:guardrails\]\)/` |
| same | `~r/:input_guardrails option: expected list, got: :not_a_list/` | `~r/:input option: expected list, got: :not_a_list \(in options \[:guardrails\]\)/` |
| same | `~r/:output_guardrails option: expected list, got: %\{not: "a list"\}/` | `~r/:output option: expected list, got: %\{not: "a list"\} \(in options \[:guardrails\]\)/` |
| same, test names | `"an invalid :output_guardrails_on_violation is rejected at init"`, `"raises ArgumentError when :input_guardrails is not a list"`, `"... :output_guardrails is not a list"` | `"an invalid guardrails :on_violation is rejected at init"`, `"raises ArgumentError when guardrails :input is not a list"`, `"... guardrails :output is not a list"` |
| `test/agents/base_agent_init_options_test.exs` (`"an unknown circuit breaker option is named"`) | `circuit_breaker_options: [error_threshold: 3]` and the expected `"...unknown option :error_threshold in :circuit_breaker_options; supported: ..."` | `circuit_breaker: [error_threshold: 3]` and `"Normandy.Agents.BaseAgent.init/1: invalid value for :circuit_breaker option: unknown options [:error_threshold], valid options are: [:failure_threshold, :success_threshold, :timeout, :half_open_max_calls]"` |
| test names: `base_agent_stream_resilience_test.exs` `"...retried under retry_options"`, `base_agent_llm_error_test.exs` `"without retry_options an LLM error..."`, `retry_test.exs` `"BaseAgent.init checks :retry_options when..."`; comment `base_agent_hooks_test.exs:21` `retry_options defaults to nil` | | `retry` in each |

Then `mix format`. Acceptance grep (expected: only `init_options.ex`'s `@renamed` list, the DSL
`:agent_*_guardrails` module attributes, `Retry`'s and `CircuitBreaker`'s own
`retry_options`/`circuit_breaker_options` types, `base_agent.ex`'s private
`retry_options/2` helper and the `run_*_guardrails` function names):

```bash
grep -rnE "retry_options|enable_circuit_breaker|circuit_breaker_options|input_guardrails|output_guardrails" lib test config e2e/0*.exs
```

- [ ] **Step 7: Run the suite**

Run: `mix test 2>&1 | tail -3 && mix credo --strict && mix compile --force --warnings-as-errors`
Expected: ` 0 failures` (2762 tests on the scratch copy), no credo issues, no warnings.

- [ ] **Step 8: MIGRATING**

`MIGRATING-2.0.md:200` (§11): replace "`retry_options` multiplies attempts" with "the agent's
`retry` options multiplies attempts".

In §21 (Task 3.1b), replace "- `:circuit_breaker_options` accepts `:failure_threshold`," with
"- `circuit_breaker:` (1.x `:circuit_breaker_options`, see §22) accepts `:failure_threshold`,",
so §21 does not name an option this task removes.

Append to §22 (started in Task 3.2a), before its compactor bullets:

```markdown
`BaseAgent.init/1` (and DSL `new/1`) group the resilience and guardrail options. Passing a
1.x name raises `ArgumentError` naming its 2.0 home.

| 1.x option / `BaseAgentConfig` field | 2.0 |
|---|---|
| `retry_options: opts` | `retry: opts` |
| `enable_circuit_breaker: true, circuit_breaker_options: opts` | `circuit_breaker: opts` (`[]` for the defaults; `nil`, the default, starts none) |
| `config.circuit_breaker` (the pid) | `config.circuit_breaker_pid`; `config.circuit_breaker` is now the options |
| `input_guardrails: specs` | `guardrails: [input: specs]` |
| `output_guardrails: specs` | `guardrails: [output: specs]` |
| `output_guardrails_streaming_mode: m` | `guardrails: [streaming_mode: m]` |
| `output_guardrails_chunk_size: n` | `guardrails: [chunk_size: n]` |
| `output_guardrails_on_violation: v` | `guardrails: [on_violation: v]` |

- Keys left out of `guardrails:` keep their defaults; read one setting with
  `BaseAgentConfig.guardrail(config, :output)`. A `guardrails:` given to a DSL agent's `new/1`
  changes only the keys it gives.
- The DSL's `config/0` returns `guardrails: [...]` in place of the five `*_guardrails*` keys.
- `circuit_breaker:` accepts `:failure_threshold`, `:success_threshold`, `:timeout` and
  `:half_open_max_calls`. What the breaker does at runtime is unchanged here.
- An `AgentTemplate` supplement names the node-local breaker `:circuit_breaker_pid` (was
  `:circuit_breaker`). Templates now store the `retry`, `circuit_breaker` and `guardrails`
  options.
```

- [ ] **Step 9: CLAUDE.md**

Replace `CLAUDE.md:61-62`

```markdown
- **`Normandy.Agents.BaseAgentConfig`** - Agent state container
  - Stores: input/output schemas, memory, prompt specification, LLM client/model, optional temperature, max_tokens, resolved context window
```

with

```markdown
- **`Normandy.Agents.BaseAgentConfig`** - Agent state container
  - Stores: input/output schemas, memory, prompt specification, LLM client/model, optional temperature, max_tokens, resolved context window, and the option groups `retry` (Retry options or nil), `circuit_breaker` (breaker options or nil; `circuit_breaker_pid` is the node-local breaker init/1 started) and `guardrails` (`[input:, output:, streaming_mode:, chunk_size:, on_violation:]`, read with `BaseAgentConfig.guardrail/2`)
```

and in `### Resilience & Error Handling` (`:134-140`) change "Configurable max attempts, backoff
factor, and delay" to "Configured per agent with `init/1`'s `retry:` (max attempts, backoff
factor, delay)" and "Thresholds and timeouts are configurable per agent" to "Configured per agent
with `init/1`'s `circuit_breaker:` (thresholds, timeout)".

- [ ] **Step 10: Commit**

```bash
git add lib/normandy/agents/base_agent_config.ex lib/normandy/agents/base_agent/init_options.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/agents/config_template.ex \
  lib/normandy/behaviours/agent_template.ex lib/normandy/dsl/agent.ex lib/normandy/guardrails.ex \
  lib/normandy/llm/claudio_adapter.ex lib/normandy/resilience/retry.ex \
  test/agents/base_agent_config_groups_test.exs test/support/integration_helper.ex \
  test/integration/agent_resilience_integration_test.exs test/agents/config_template_test.exs \
  test/agents/base_agent_admit_test.exs test/agents/base_agent_run_result_test.exs \
  test/agents/base_agent_resilience_test.exs test/agents/base_agent_streaming_guardrails_test.exs \
  test/agents/base_agent_stream_test.exs test/agents/base_agent_init_options_test.exs \
  test/agents/base_agent_guardrails_test.exs test/agents/base_agent_llm_error_test.exs \
  test/agents/base_agent_stream_resilience_test.exs test/agents/base_agent_stream_errors_test.exs \
  test/agents/turn/server_test.exs test/resilience/retry_test.exs \
  test/telemetry/span_hierarchy_test.exs test/telemetry/llm_request_span_test.exs \
  test/hooks/base_agent_hooks_test.exs test/telemetry/metadata_test.exs \
  test/telemetry/llm_call_request_metadata_test.exs test/dsl/agent_streaming_guardrails_test.exs \
  test/dsl/agent_guardrails_test.exs e2e/06_resilience.exs e2e/07_guardrails.exs \
  e2e/08_streaming.exs MIGRATING-2.0.md CLAUDE.md
git commit -m "feat(agent)!: retry, circuit_breaker and guardrails option groups"
```

---
### Task 3.2c: `Behaviours.Config` loses the session slots; `rebuild/3` translates v1.0.0 templates (DX-19, decision 17c, Review Focus #1)

**Files:**
- Modify: `lib/normandy/behaviours/config.ex` (moduledoc `:13-19`, aliases `:27-28`, type `:45-46`,
  defaults `:57-58`)
- Modify: `lib/normandy/agents/config_template.ex` (moduledoc, field lists, `from_config/2`
  `behaviours_refs`, `rebuild/3`, new `translate!/1` and helpers)
- Create: `test/fixtures/templates/v1_0_0_session_template.etf` (binary, 1568 bytes),
  `test/fixtures/templates/generate_v1_0_0.exs` (provenance; not run by the suite)
- Modify: `docs/guides/distributed_sessions.md:196-202`, `MIGRATING-2.0.md` §22
- Test: `test/agents/config_template_v1_test.exs` (new), `test/behaviours/config_test.exs:27-43`

**Why a checked-in `.etf` and not a test-support helper.** The fixture is the exact bytes v1.0.0's
own `BaseAgent.init/1` + `ConfigTemplate.from_config/3` produced, encoded the way 1.0's
Postgres and Redis stores kept a template (`:erlang.term_to_binary/1`; v1.0.0
`postgres.ex:225`). A helper that builds the map in 2.0 code would be built from 2.0's structs
and atoms and would silently follow any later change to them; frozen bytes keep testing what a
1.0 store really returns, including the `[:safe]` decode of its atoms. The generator script is
committed next to it so anyone can re-create it from the tag (verified: re-running it on a
`git archive v1.0.0` export gives byte-identical output, sha256 below).

**Interfaces:**
- Consumes: `:context_window` (3.2a), the 3.2b field names.
- Produces:
  - `%Normandy.Behaviours.Config{}` without `session_store`/`session_registry`; templates' `behaviours_refs`
    no longer carry them.
  - `ConfigTemplate.rebuild/3` accepts the v1.0.0 shape and the 2.0 shape only. Translation: 1.0
    `max_tokens: nil` → `BaseAgentConfig.default_max_tokens()`; `session_store`/`session_registry`
    refs dropped; `{Compactor.WindowManager, opts}` with `:max_tokens` → `:context_window`
    (custom compactors untouched). Raises `ArgumentError` (exact texts in the tests) for: a
    top-level field outside `@required_fields ++ @optional_fields`; a missing required field; a
    `node_local_fields` entry outside `[:circuit_breaker_pid, :mcp_servers]` (a pre-release
    `:circuit_breaker` lands here); an unknown or missing `behaviours_refs` slot; a `max_tokens`
    that is neither `nil` nor a positive integer (closes the Wave 1 `||` minor: `0`, `-1`, `false`
    used to pass or silently default); both `:max_tokens` and `:context_window` on
    `Compactor.WindowManager`.
  - `@optional_fields` includes `:server_options`, which `Turn.Session.save_template/2`
    (`session.ex:159`) adds and `Turn.Server` reads (`server.ex:510`). The research inventory
    missed it; without it every Tier-2 session test fails (verified: 5 tests).

- [ ] **Step 1: Add the fixture**

```bash
mkdir -p test/fixtures/templates
elixir -e 'File.write!(hd(System.argv()), Base.decode64!(IO.read(:stdio, :eof) |> String.replace(~r/\s/, "")))' \
  test/fixtures/templates/v1_0_0_session_template.etf <<'EOF'
g3QAAAANdwRuYW1lbQAAAAdzdXBwb3J0dwVtb2RlbG0AAAARY2xhdWRlLXNvbm5ldC00LTZ3C3Rl
bXBlcmF0dXJlRj/szMzMzMzNdxRwcm9tcHRfc3BlY2lmaWNhdGlvbnQAAAAGdwpfX3N0cnVjdF9f
dy5FbGl4aXIuTm9ybWFuZHkuQ29tcG9uZW50cy5Qcm9tcHRTcGVjaWZpY2F0aW9udwpiYWNrZ3Jv
dW5kbAAAAAFtAAAAHVlvdSBhbnN3ZXIgYmlsbGluZyBxdWVzdGlvbnMuancIX19tZXRhX190AAAA
BXcFc3RhdGV3BWJ1aWx0dwdjb250ZXh0dwNuaWx3BnNvdXJjZXcDbmlsdwpfX3N0cnVjdF9fdxhF
bGl4aXIuTm9ybWFuZHkuTWV0YWRhdGF3BnNjaGVtYXcuRWxpeGlyLk5vcm1hbmR5LkNvbXBvbmVu
dHMuUHJvbXB0U3BlY2lmaWNhdGlvbncRY29udGV4dF9wcm92aWRlcnN0AAAAAHcTb3V0cHV0X2lu
c3RydWN0aW9uc2p3BXN0ZXBzancKbWF4X3Rva2Vuc3cDbmlsdxNtYXhfdG9vbF9pdGVyYXRpb25z
YQV3FG1heF90b29sX2NvbmN1cnJlbmN5YQF3DW91dHB1dF9zY2hlbWF0AAAAA3cKX19zdHJ1Y3Rf
X3csRWxpeGlyLk5vcm1hbmR5LkFnZW50cy5CYXNlQWdlbnRPdXRwdXRTY2hlbWF3CF9fbWV0YV9f
dAAAAAV3BXN0YXRldwVidWlsdHcHY29udGV4dHcDbmlsdwZzb3VyY2V3A25pbHcKX19zdHJ1Y3Rf
X3cYRWxpeGlyLk5vcm1hbmR5Lk1ldGFkYXRhdwZzY2hlbWF3LEVsaXhpci5Ob3JtYW5keS5BZ2Vu
dHMuQmFzZUFnZW50T3V0cHV0U2NoZW1hdwxjaGF0X21lc3NhZ2V3A25pbHcMaW5wdXRfc2NoZW1h
dAAAAAN3Cl9fc3RydWN0X193K0VsaXhpci5Ob3JtYW5keS5BZ2VudHMuQmFzZUFnZW50SW5wdXRT
Y2hlbWF3CF9fbWV0YV9fdAAAAAV3BXN0YXRldwVidWlsdHcHY29udGV4dHcDbmlsdwZzb3VyY2V3
A25pbHcKX19zdHJ1Y3RfX3cYRWxpeGlyLk5vcm1hbmR5Lk1ldGFkYXRhdwZzY2hlbWF3K0VsaXhp
ci5Ob3JtYW5keS5BZ2VudHMuQmFzZUFnZW50SW5wdXRTY2hlbWF3DGNoYXRfbWVzc2FnZXcDbmls
dwxtYXhfbWVzc2FnZXNhMncPYmVoYXZpb3Vyc19yZWZzdAAAAAd3BnBvbGljeWgCdzBFbGl4aXIu
Tm9ybWFuZHkuQmVoYXZpb3Vycy5Qb2xpY3lFbmdpbmUuQWxsb3dBbGxqdwljb21wYWN0b3JoAncy
RWxpeGlyLk5vcm1hbmR5LkJlaGF2aW91cnMuQ29tcGFjdG9yLldpbmRvd01hbmFnZXJsAAAAAmgC
dwptYXhfdG9rZW5zYgADDUBoAncIc3RyYXRlZ3l3DG9sZGVzdF9maXJzdGp3DW1vZGVsX2NhdGFs
b2doAncuRWxpeGlyLk5vcm1hbmR5LkJlaGF2aW91cnMuTW9kZWxDYXRhbG9nLlN0YXRpY2p3BmJ1
ZGdldGgCdy1FbGl4aXIuTm9ybWFuZHkuQmVoYXZpb3Vycy5CdWRnZXRUcmFja2VyLk5vT3Bqdwpj
cmVkZW50aWFsaAJ3OEVsaXhpci5Ob3JtYW5keS5CZWhhdmlvdXJzLkNyZWRlbnRpYWxQcm92aWRl
ci5Gcm9tQ2xpZW50ancNc2Vzc2lvbl9zdG9yZWgCdzBFbGl4aXIuTm9ybWFuZHkuQmVoYXZpb3Vy
cy5TZXNzaW9uU3RvcmUuSW5NZW1vcnlqdxBzZXNzaW9uX3JlZ2lzdHJ5aAJ3MUVsaXhpci5Ob3Jt
YW5keS5CZWhhdmlvdXJzLlNlc3Npb25SZWdpc3RyeS5OYXRpdmVqdw1yZXN1bWVfcG9saWN5dwVl
YWdlcncLdGVtcGxhdGVfaWRtAAAAB3RtcGwtdjE=
EOF
shasum -a 256 test/fixtures/templates/v1_0_0_session_template.etf
```

Expected: `ae2eebb697715c800a015ad2b46bf5a8fbef9a6b82a6905a658016051bbede08`. Decoded, it is
(v1.0.0's `from_config/3`, `:eager`):

```elixir
%{
  template_id: "tmpl-v1", resume_policy: :eager, name: "support",
  model: "claude-sonnet-4-6", temperature: 0.9, max_tokens: nil,
  max_tool_iterations: 5, max_tool_concurrency: 1, max_messages: 50,
  prompt_specification: %PromptSpecification{background: ["You answer billing questions."], ...},
  input_schema: %BaseAgentInputSchema{}, output_schema: %BaseAgentOutputSchema{},
  behaviours_refs: %{
    policy: {PolicyEngine.AllowAll, []}, budget: {BudgetTracker.NoOp, []},
    credential: {CredentialProvider.FromClient, []},
    compactor: {Compactor.WindowManager, [max_tokens: 200000, strategy: :oldest_first]},
    model_catalog: {ModelCatalog.Static, []},
    session_store: {SessionStore.InMemory, []}, session_registry: {SessionRegistry.Native, []}
  }
}
```

Create `test/fixtures/templates/generate_v1_0_0.exs`:

```elixir
# Generates v1_0_0_session_template.etf with Normandy v1.0.0's own BaseAgent.init/1 and
# ConfigTemplate.from_config/3, the way a 1.0 Postgres or Redis store persisted it
# (:erlang.term_to_binary/1). Not part of the suite. Run it in an export of the v1.0.0 tag,
# never in this tree:
#
#     mkdir -p /tmp/normandy-1.0.0 && git archive v1.0.0 | tar -x -C /tmp/normandy-1.0.0
#     cd /tmp/normandy-1.0.0 && mix deps.get && mix compile
#     mix run --no-start /path/to/this/file.exs /path/to/v1_0_0_session_template.etf
alias Normandy.Agents.{BaseAgent, ConfigTemplate}
alias Normandy.Behaviours.{Compactor, Config}
alias Normandy.Components.{AgentMemory, PromptSpecification}

config =
  BaseAgent.init(%{
    client: %URI{host: "fixture.invalid"},
    model: "claude-sonnet-4-6",
    temperature: 0.9,
    name: "support",
    memory: AgentMemory.new_memory(50),
    prompt_specification: %PromptSpecification{background: ["You answer billing questions."]},
    behaviours: %Config{
      compactor: {Compactor.WindowManager, [max_tokens: 200_000, strategy: :oldest_first]}
    }
  })

template = ConfigTemplate.from_config(config, "tmpl-v1", :eager)
[out] = System.argv()
File.write!(out, :erlang.term_to_binary(template))
IO.puts("v1.0.0 template: " <> inspect(template, limit: :infinity, pretty: true))
```

- [ ] **Step 2: Write the failing tests**

Create `test/agents/config_template_v1_test.exs`:

```elixir
defmodule Normandy.Agents.ConfigTemplateV1Test do
  # Review Focus #1: a session template saved by Normandy 1.0.0, rebuilt under 2.0.
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.BaseAgentOutputSchema
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.SessionStore.Codec
  alias Normandy.Test.StubClient

  # Written by v1.0.0's own ConfigTemplate.from_config/3 (generate_v1_0_0.exs, same
  # directory) and stored as a 1.0 Postgres/Redis store kept it: term_to_binary/1.
  @fixture Path.expand("../fixtures/templates/v1_0_0_session_template.etf", __DIR__)

  defp v1_template, do: @fixture |> File.read!() |> Codec.decode()

  defp supplement do
    %{
      tool_registry: nil,
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _token ->
        %StubClient{notify: self(), reply: fn model -> %{model | chat_message: "hello"} end}
      end
    }
  end

  defp rebuild(tmpl), do: ConfigTemplate.rebuild(tmpl, supplement(), "token")

  test "the fixture has the 1.0 shape the translation is for" do
    tmpl = v1_template()

    assert tmpl.max_tokens == nil
    assert Map.has_key?(tmpl.behaviours_refs, :session_store)
    assert Map.has_key?(tmpl.behaviours_refs, :session_registry)
    refute Map.has_key?(tmpl, :node_local_fields)

    assert tmpl.behaviours_refs.compactor ==
             {Compactor.WindowManager, [max_tokens: 200_000, strategy: :oldest_first]}
  end

  test "it rebuilds into a working config with 2.0 defaults" do
    config = rebuild(v1_template())

    assert %BaseAgentConfig{model: "claude-sonnet-4-6", temperature: 0.9, name: "support"} =
             config

    assert config.max_tokens == BaseAgentConfig.default_max_tokens()
    assert config.memory.max_messages == 50
    assert config.prompt_specification.background == ["You answer billing questions."]
    assert config.retry == nil
    assert config.circuit_breaker == nil
    assert config.circuit_breaker_pid == nil
    assert config.guardrails == BaseAgentConfig.default_guardrails()
    assert config.tool_context == %{}
    assert config.behaviours.hooks == []
    refute Map.has_key?(config.behaviours, :session_store)
    refute Map.has_key?(config.behaviours, :session_registry)

    {mod, opts} = config.behaviours.compactor
    assert mod == Compactor.WindowManager
    assert Keyword.fetch!(opts, :context_window) == 200_000
    assert Keyword.fetch!(opts, :strategy) == :oldest_first
    refute Keyword.has_key?(opts, :max_tokens)

    assert {:ok, _config, %BaseAgentOutputSchema{chat_message: "hello"}} =
             BaseAgent.run(config, "hi")

    assert_receive {:converse, %Normandy.LLM.Request{max_tokens: 16_000}, _opts}
  end

  # Pinned with :context_window, so the rebuild needs no catalog lookup for StubClient.
  test "a custom compactor's :max_tokens is not rewritten" do
    tmpl =
      put_in(
        v1_template().behaviours_refs.compactor,
        {Normandy.Test.KeepLastCompactor, [keep: 2, max_tokens: 9, context_window: 100_000]}
      )

    assert rebuild(tmpl).behaviours.compactor ==
             {Normandy.Test.KeepLastCompactor, [keep: 2, max_tokens: 9, context_window: 100_000]}
  end

  test "a field neither 1.0 nor 2.0 writes raises, naming it" do
    tmpl = Map.put(v1_template(), :retry_options, max_attempts: 2)

    assert_raise ArgumentError,
                 ~s(ConfigTemplate.rebuild/3: template "tmpl-v1" has the field :retry_options, ) <>
                   "which neither a Normandy 1.0 nor a 2.0 template has; it cannot be rebuilt " <>
                   "(MIGRATING-2.0.md §22)",
                 fn -> rebuild(tmpl) end
  end

  test "an unknown behaviours_refs slot raises, naming it" do
    tmpl = put_in(v1_template().behaviours_refs[:sandbox], {SomeSandbox, []})

    assert_raise ArgumentError,
                 ~s(ConfigTemplate.rebuild/3: template "tmpl-v1" has the behaviours_refs slot ) <>
                   ":sandbox, which neither a Normandy 1.0 nor a 2.0 template has; it cannot " <>
                   "be rebuilt (MIGRATING-2.0.md §22)",
                 fn -> rebuild(tmpl) end
  end

  test "a missing required field raises, naming it" do
    assert_raise ArgumentError,
                 ~s(ConfigTemplate.rebuild/3: template "tmpl-v1" lacks the field :model, ) <>
                   "which every Normandy 1.0 and 2.0 template has; it cannot be rebuilt " <>
                   "(MIGRATING-2.0.md §22)",
                 fn -> v1_template() |> Map.delete(:model) |> rebuild() end
  end

  test "a missing required behaviours_refs slot raises, naming it" do
    tmpl = update_in(v1_template().behaviours_refs, &Map.delete(&1, :credential))

    assert_raise ArgumentError, ~r/lacks the behaviours_refs slot :credential/, fn ->
      rebuild(tmpl)
    end
  end

  test "an unreleased node_local_fields entry raises, naming it" do
    tmpl = Map.put(v1_template(), :node_local_fields, [:circuit_breaker])

    assert_raise ArgumentError, ~r/lists :circuit_breaker in :node_local_fields/, fn ->
      rebuild(tmpl)
    end
  end

  test "a max_tokens that is neither nil nor a positive integer raises, naming it" do
    for bad <- [0, -1, false, "16000"] do
      assert_raise ArgumentError,
                   ~s(ConfigTemplate.rebuild/3: template "tmpl-v1" has max_tokens ) <>
                     "#{inspect(bad)}; expected a positive integer, or nil (a 1.0 template " <>
                     "that set none)",
                   fn -> v1_template() |> Map.put(:max_tokens, bad) |> rebuild() end
    end
  end

  test "both window pins on Compactor.WindowManager raise" do
    tmpl =
      put_in(
        v1_template().behaviours_refs.compactor,
        {Compactor.WindowManager, [max_tokens: 1_000, context_window: 2_000]}
      )

    assert_raise ArgumentError, ~r/both :max_tokens \(1.0\) and :context_window \(2.0\)/, fn ->
      rebuild(tmpl)
    end
  end

  test "a 2.0 template round-trips through the same checks" do
    config = rebuild(v1_template())
    tmpl = ConfigTemplate.from_config(config, "tmpl-v2", :eager)

    refute Map.has_key?(tmpl.behaviours_refs, :session_store)
    assert rebuild(tmpl).behaviours.compactor == config.behaviours.compactor
  end
end
```

In `test/behaviours/config_test.exs` (the slots go away):

```diff
diff --git a/test/behaviours/config_test.exs b/test/behaviours/config_test.exs
index 0244e18..c1d9d06 100644
--- a/test/behaviours/config_test.exs
+++ b/test/behaviours/config_test.exs
@@ -24,23 +24,17 @@ defmodule Normandy.Behaviours.ConfigTest do
       assert b.after_hooks == []
       assert b.credential == {Normandy.Behaviours.CredentialProvider.FromClient, []}
       assert b.model_catalog == {Normandy.Behaviours.ModelCatalog.ModelsAPI, []}
-      assert b.session_store == {Normandy.Behaviours.SessionStore.InMemory, []}
     end
 
-    test "default bundle carries the Native session_registry slot" do
-      assert %Normandy.Behaviours.Config{}.session_registry ==
-               {Normandy.Behaviours.SessionRegistry.Native, []}
+    test "has no session_store or session_registry slot (Turn.Server takes :store and :registry)" do
+      refute Map.has_key?(%Config{}, :session_store)
+      refute Map.has_key?(%Config{}, :session_registry)
     end
 
     test "default bundle carries the NoOp compactor slot" do
       b = %Config{}
       assert b.compactor == {Normandy.Behaviours.Compactor.NoOp, []}
     end
-
-    test "to_pipeline/1 ignores session_registry (not a dispatch-path concern)" do
-      pipeline = Config.to_pipeline(%Normandy.Behaviours.Config{})
-      refute Map.has_key?(Map.from_struct(pipeline), :session_registry)
-    end
   end
 
   # Reports what the pipeline hands it, including the ref's opts.
```

The four 1.x-shaped hand-built templates in `test/agents/config_template_test.exs` (`:57-91`,
`:93-132`, `:349-388`, `:390-430`; they carry `session_store`/`session_registry` and lack
`resume_policy`/`node_local_fields`) stay as they are: after this task they exercise the
translation too.

- [ ] **Step 3: Run to verify they fail**

Run: `mix test test/agents/config_template_v1_test.exs test/behaviours/config_test.exs`
Expected: FAIL: the fixture's `{WindowManager, [max_tokens: ...]}` hits Task 3.2a's
"renamed to :context_window" error; the unknown-field and bad-`max_tokens` cases rebuild instead
of raising (`0` passes through `||`); `%Config{}` still has the slots.

- [ ] **Step 4: Implement**

Apply:

```diff
diff --git a/lib/normandy/agents/config_template.ex b/lib/normandy/agents/config_template.ex
index 4f65ac7..6e4becc 100644
--- a/lib/normandy/agents/config_template.ex
+++ b/lib/normandy/agents/config_template.ex
@@ -12,20 +12,39 @@ defmodule Normandy.Agents.ConfigTemplate do
 
   Everything else travels in the template: model and sampling settings, tool
   limits, prompt, schemas, memory cap, `initial_memory`, the `retry` and
-  `circuit_breaker` options, JSON retry settings, `guardrails`, `tool_context`, behaviour module refs and hook entries
-  (`Normandy.Behaviours.Hooks`; their opts must be plain data and hold no secrets).
-  These must be plain data: `from_config/2` raises on a function or pid (e.g. a `:retry_if` fun).
-  `tool_context` must hold no secrets: the template is stored in plaintext.
-  A template saved before these fields existed rebuilds with their defaults.
+  `circuit_breaker` options, JSON retry settings, `guardrails`, `tool_context`,
+  behaviour module refs and hook entries (`Normandy.Behaviours.Hooks`; their opts must
+  be plain data and hold no secrets). These must be plain data: `from_config/2` raises
+  on a function or pid (e.g. a `:retry_if` fun). `tool_context` must hold no secrets:
+  the template is stored in plaintext.
+
+  ## Templates saved by Normandy 1.0
+
+  `rebuild/3` reads templates written by Normandy 1.0.0 and by 2.0. A 1.0 template lacks
+  the fields 2.0 added (they rebuild with their defaults) and differs in three ways, which
+  `rebuild/3` translates:
+
+    * `max_tokens: nil` (the agent set none) rebuilds with
+      `BaseAgentConfig.default_max_tokens/0`;
+    * `behaviours_refs` carries `session_store` and `session_registry`, slots 1.0 never
+      read; they are dropped;
+    * a `Normandy.Behaviours.Compactor.WindowManager` ref pins the window with
+      `:max_tokens`, which 2.0 calls `:context_window`. A custom compactor's opts are
+      left as they are.
+
+  Any other field, a `behaviours_refs` slot or a `node_local_fields` entry that neither
+  version writes, and a missing required field, raise `ArgumentError` naming it. Templates
+  written by unreleased 2.0 builds are not translated.
   """
   alias Normandy.Agents.BaseAgent
   alias Normandy.Agents.BaseAgentConfig
+  alias Normandy.Behaviours.Compactor
   alias Normandy.Behaviours.Config
   alias Normandy.Behaviours.Hooks
   alias Normandy.Components.AgentMemory
 
-  # Plain-data config fields carried as-is. A template saved before 2.0 lacks
-  # them, so `rebuild/3` leaves the struct defaults in place for missing keys.
+  # Plain-data config fields carried as-is. A 1.0 template lacks them, so
+  # `rebuild/3` leaves the struct defaults in place for missing keys.
   @data_fields [
     :initial_memory,
     :retry,
@@ -41,6 +60,36 @@ defmodule Normandy.Agents.ConfigTemplate do
   # takes them from the supplement.
   @node_local_fields [:circuit_breaker_pid, :mcp_servers]
 
+  # Top-level fields rebuild/3 reads with no default: both 1.0 and 2.0 templates have them.
+  @required_fields [
+    :template_id,
+    :model,
+    :temperature,
+    :max_tokens,
+    :max_tool_iterations,
+    :max_tool_concurrency,
+    :name,
+    :prompt_specification,
+    :input_schema,
+    :output_schema,
+    :behaviours_refs
+  ]
+
+  # Fields read when present: 1.0 wrote resume_policy and max_messages too;
+  # Turn.Session adds server_options (the Turn.Server options it was started with).
+  @optional_fields [
+    :resume_policy,
+    :max_messages,
+    :node_local_fields,
+    :server_options | @data_fields
+  ]
+
+  @required_refs [:policy, :budget, :credential, :compactor, :model_catalog]
+  @optional_refs [:hooks]
+
+  # 1.0's session slots: never read by 1.0's turn loop, so dropping them loses nothing.
+  @dropped_v1_refs [:session_store, :session_registry]
+
   @spec from_config(BaseAgentConfig.t(), String.t()) :: map()
   def from_config(%BaseAgentConfig{} = c, template_id) do
     b = c.behaviours || %Config{}
@@ -64,8 +113,6 @@ defmodule Normandy.Agents.ConfigTemplate do
         credential: b.credential,
         compactor: b.compactor,
         model_catalog: b.model_catalog,
-        session_store: b.session_store,
-        session_registry: b.session_registry,
         hooks: storable_hooks!(b.hooks)
       }
     }
@@ -116,14 +163,17 @@ defmodule Normandy.Agents.ConfigTemplate do
   @doc """
   Rebuilds a `BaseAgentConfig` from a template and a supplement.
 
-  Raises `ArgumentError` for a compaction setup that can't size its window (see
-  `BaseAgent.validate_compaction_config!/1`), and for a malformed hook entry in the
-  template (shape, `:on_error` and plain-data opts; whether the hook module exists on
+  Translates a template saved by Normandy 1.0 (see the moduledoc). Raises
+  `ArgumentError` naming the field for one it cannot translate, for a `max_tokens` that is
+  neither `nil` (1.0) nor a positive integer, for a compaction setup that can't size its
+  window (see `BaseAgent.validate_compaction_config!/1`), and for a malformed hook entry in
+  the template (shape, `:on_error` and plain-data opts; whether the hook module exists on
   this node is checked later, by `Turn.Server`).
   """
   @spec rebuild(map(), Normandy.Behaviours.AgentTemplate.supplement(), String.t()) ::
           BaseAgentConfig.t()
-  def rebuild(tmpl, supplement, token) do
+  def rebuild(tmpl, supplement, token) when is_map(tmpl) do
+    tmpl = translate!(tmpl)
     refs = tmpl.behaviours_refs
     :ok = Hooks.validate_entries!(Map.get(refs, :hooks, []), load: false)
 
@@ -133,8 +183,6 @@ defmodule Normandy.Agents.ConfigTemplate do
       credential: refs.credential,
       compactor: refs.compactor,
       model_catalog: refs.model_catalog,
-      session_store: refs.session_store,
-      session_registry: refs.session_registry,
       hooks: Map.get(refs, :hooks, []),
       before_hooks: supplement.before_hooks,
       after_hooks: supplement.after_hooks
@@ -143,8 +191,7 @@ defmodule Normandy.Agents.ConfigTemplate do
     %BaseAgentConfig{
       model: tmpl.model,
       temperature: tmpl.temperature,
-      # Templates saved by 1.x store nil for an unset max_tokens; 2.0 sends the default.
-      max_tokens: tmpl.max_tokens || BaseAgentConfig.default_max_tokens(),
+      max_tokens: tmpl.max_tokens,
       max_tool_iterations: tmpl.max_tool_iterations,
       max_tool_concurrency: tmpl.max_tool_concurrency,
       name: tmpl.name,
@@ -162,6 +209,98 @@ defmodule Normandy.Agents.ConfigTemplate do
     |> validate_client_options!()
   end
 
+  # A 1.0 or 2.0 template → the 2.0 shape; anything else raises naming the field.
+  defp translate!(tmpl) do
+    id = Map.get(tmpl, :template_id)
+    :ok = check_fields!(tmpl, id)
+
+    tmpl
+    |> Map.update!(:max_tokens, &max_tokens!(&1, id))
+    |> Map.update!(:behaviours_refs, &translate_refs!(&1, id))
+  end
+
+  defp check_fields!(tmpl, id) do
+    case Map.keys(tmpl) -- (@required_fields ++ @optional_fields) do
+      [] -> :ok
+      [field | _] -> untranslatable!(id, "has the field #{inspect(field)}")
+    end
+
+    case @required_fields -- Map.keys(tmpl) do
+      [] -> :ok
+      [field | _] -> missing!(id, "the field #{inspect(field)}")
+    end
+
+    case Map.get(tmpl, :node_local_fields, []) -- @node_local_fields do
+      [] -> :ok
+      [field | _] -> untranslatable!(id, "lists #{inspect(field)} in :node_local_fields")
+    end
+  end
+
+  # 1.0 stored nil for an unset max_tokens; 2.0 always stores a positive integer.
+  defp max_tokens!(nil, _id), do: BaseAgentConfig.default_max_tokens()
+  defp max_tokens!(n, _id) when is_integer(n) and n > 0, do: n
+
+  defp max_tokens!(other, id) do
+    raise ArgumentError,
+          "ConfigTemplate.rebuild/3: template #{inspect(id)} has max_tokens " <>
+            "#{inspect(other)}; expected a positive integer, or nil (a 1.0 template that " <>
+            "set none)"
+  end
+
+  defp translate_refs!(refs, id) when is_map(refs) do
+    refs = Map.drop(refs, @dropped_v1_refs)
+
+    case Map.keys(refs) -- (@required_refs ++ @optional_refs) do
+      [] -> :ok
+      [slot | _] -> untranslatable!(id, "has the behaviours_refs slot #{inspect(slot)}")
+    end
+
+    case @required_refs -- Map.keys(refs) do
+      [] -> :ok
+      [slot | _] -> missing!(id, "the behaviours_refs slot #{inspect(slot)}")
+    end
+
+    Map.update!(refs, :compactor, &compactor_ref!(&1, id))
+  end
+
+  defp translate_refs!(_refs, id),
+    do: untranslatable!(id, "has a behaviours_refs that is not a map")
+
+  # 1.0's WindowManager pinned the window with :max_tokens; 2.0 calls it :context_window.
+  # Only Normandy's own compactor: a custom compactor's :max_tokens is its own option.
+  defp compactor_ref!({Compactor.WindowManager, opts}, id) when is_list(opts) do
+    case {Keyword.fetch(opts, :max_tokens), Keyword.has_key?(opts, :context_window)} do
+      {:error, _pinned?} ->
+        {Compactor.WindowManager, opts}
+
+      {{:ok, _window}, true} ->
+        untranslatable!(
+          id,
+          "has Compactor.WindowManager opts with both :max_tokens (1.0) and :context_window (2.0)"
+        )
+
+      {{:ok, window}, false} ->
+        {Compactor.WindowManager,
+         opts |> Keyword.delete(:max_tokens) |> Keyword.put(:context_window, window)}
+    end
+  end
+
+  defp compactor_ref!(ref, _id), do: ref
+
+  @spec untranslatable!(term(), String.t()) :: no_return()
+  defp untranslatable!(id, what) do
+    raise ArgumentError,
+          "ConfigTemplate.rebuild/3: template #{inspect(id)} #{what}, which neither a " <>
+            "Normandy 1.0 nor a 2.0 template has; it cannot be rebuilt (MIGRATING-2.0.md §22)"
+  end
+
+  @spec missing!(term(), String.t()) :: no_return()
+  defp missing!(id, what) do
+    raise ArgumentError,
+          "ConfigTemplate.rebuild/3: template #{inspect(id)} lacks #{what}, which every " <>
+            "Normandy 1.0 and 2.0 template has; it cannot be rebuilt (MIGRATING-2.0.md §22)"
+  end
+
   defp node_local_fields!(tmpl, supplement) do
     tmpl
     |> Map.get(:node_local_fields, [])
diff --git a/lib/normandy/behaviours/config.ex b/lib/normandy/behaviours/config.ex
index 69f4fe7..a9f8d9e 100644
--- a/lib/normandy/behaviours/config.ex
+++ b/lib/normandy/behaviours/config.ex
@@ -11,12 +11,12 @@ defmodule Normandy.Behaviours.Config do
   `before_hooks`, `after_hooks`, and the `before_tool`/`after_tool` callbacks of `hooks`)
   into a `%Normandy.Agents.Dispatch.Pipeline{}`.
   Building it here (not on `Dispatch`) keeps the Phase 1 chokepoint untouched —
-  the dependency points Phase 2 → Phase 1. The `credential`, `compactor`,
-  `model_catalog`, `session_store`, and `session_registry` slots are not
-  dispatch-path concerns and are not placed on the pipeline. `compactor` selects
-  the `:steering`-boundary compaction strategy (Phase 5); `session_store`
-  selects where session entries / turn state persist; it is wired here but not
-  yet consumed by the turn loop (Phase 4 reads it).
+  the dependency points Phase 2 → Phase 1. The `credential`, `compactor` and
+  `model_catalog` slots are not dispatch-path concerns and are not placed on the
+  pipeline. `compactor` selects the `:steering`-boundary compaction strategy. Where
+  sessions persist is not chosen here: `Normandy.Agents.Turn.Server` takes `:store` and
+  `:registry` (the 1.x `session_store`/`session_registry` slots were never read and are
+  gone).
   """
 
   alias Normandy.Agents.Dispatch.Pipeline
@@ -25,8 +25,6 @@ defmodule Normandy.Behaviours.Config do
   alias Normandy.Behaviours.CredentialProvider
   alias Normandy.Behaviours.ModelCatalog
   alias Normandy.Behaviours.PolicyEngine
-  alias Normandy.Behaviours.SessionRegistry
-  alias Normandy.Behaviours.SessionStore
   alias Normandy.Hooks.Runner
   alias Normandy.Tools.Context
   alias Normandy.Tools.Executor
@@ -41,9 +39,7 @@ defmodule Normandy.Behaviours.Config do
           hooks: [Normandy.Behaviours.Hooks.entry()],
           credential: ref(),
           compactor: ref(),
-          model_catalog: ref(),
-          session_store: ref(),
-          session_registry: ref()
+          model_catalog: ref()
         }
 
   defstruct policy: {PolicyEngine.AllowAll, []},
@@ -53,9 +49,7 @@ defmodule Normandy.Behaviours.Config do
             hooks: [],
             credential: {CredentialProvider.FromClient, []},
             compactor: {Compactor.NoOp, []},
-            model_catalog: {ModelCatalog.ModelsAPI, []},
-            session_store: {SessionStore.InMemory, []},
-            session_registry: {SessionRegistry.Native, []}
+            model_catalog: {ModelCatalog.ModelsAPI, []}
 
   @doc """
   Builds a `%Dispatch.Pipeline{}` from the dispatch-path slots of the bundle.
```

Notes on the diff: `translate!/1` runs first in `rebuild/3`, so every later read sees the 2.0
shape; the dot accesses (`tmpl.model`, ...) are safe because `check_fields!/2` guarantees the
required keys. The atoms `:session_store` and `:session_registry` stay alive through
`@dropped_v1_refs`, which `[:safe]` decoding of a 1.0 blob needs. `@spec ... :: no_return()` on
the two raising helpers keeps Dialyzer's `no_return` warning off (verified).

- [ ] **Step 5: Docs**

`docs/guides/distributed_sessions.md`:

```diff
diff --git a/docs/guides/distributed_sessions.md b/docs/guides/distributed_sessions.md
index 4ca3797..6a6e938 100644
--- a/docs/guides/distributed_sessions.md
+++ b/docs/guides/distributed_sessions.md
@@ -193,13 +193,8 @@ children =
   )
 ```
 
-```elixir
-# then in Config:
-%Normandy.Behaviours.Config{
-  session_store: {Normandy.Behaviours.SessionStore.Redis, {MyApp.SessionRedix, "normandy"}},
-  session_registry: {Normandy.Behaviours.SessionRegistry.Redis, MyApp.SessionRegistry}
-}
-```
+The store and registry are chosen here, in the child specs; `Normandy.Behaviours.Config` has
+no session slots (the two 1.x slots were never read and are gone in 2.0).
 
 > Note: `redis_child_specs/1` shares a single Redix connection across the store, registry, and reaper. Under high throughput, give the registry its own connection (pass a separate `:conn`) to avoid a single-mailbox bottleneck.
```

Acceptance: `grep -c "session_store\|session_registry" docs/guides/distributed_sessions.md` → `0`.

- [ ] **Step 6: Run the suite and the gate**

Run: `mix format && mix test 2>&1 | tail -3`
Expected: ` 0 failures` (2772 tests on the scratch copy). Then `mix precommit` → exit 0
(verified on the scratch copy at the end of this task: credo clean, Dialyzer "passed
successfully" with the 3.1a ignore entry, 2772 tests, 0 failures) and
`mix docs --warnings-as-errors` → exit 0 (verified).

The tagged suites (`postgres`, `redis`, `distributed`, Horde) were not run; they build their
templates with `from_config/2`, so they follow the new shape. Run
`mix test.postgres`/`mix test.redis` if the services are up.

- [ ] **Step 7: MIGRATING**

Append to §22:

```markdown
- `Normandy.Behaviours.Config` no longer has `session_store` or `session_registry`. Nothing read
  them; `Turn.Server` takes `:store` and `:registry` (and `Normandy.Cluster`'s child specs pass
  them). Drop the two keys from any `%Config{}` you build.
- **Session templates saved by Normandy 1.0.0 rebuild under 2.0.** `ConfigTemplate.rebuild/3`
  gives `max_tokens: nil` the 2.0 default (16_000), drops the two session slots, and renames a
  `Compactor.WindowManager` window pin from `:max_tokens` to `:context_window` (a custom
  compactor's opts are left alone). Fields 2.0 added (`retry`, `circuit_breaker`, `guardrails`,
  `tool_context`, hooks, ...) get their defaults, as a 1.0 agent behaved.
- `rebuild/3` raises `ArgumentError` naming the field for anything else it cannot read: a field
  neither 1.0 nor 2.0 writes (templates saved by unreleased 2.0 builds, which have
  `retry_options` or `input_guardrails`, are not translated: recreate those sessions), a missing
  required field, an unknown `behaviours_refs` slot, or a `max_tokens` that is neither `nil` nor
  a positive integer (a stored `0` or `false` used to pass through).
```

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/behaviours/config.ex lib/normandy/agents/config_template.ex \
  test/fixtures/templates/v1_0_0_session_template.etf test/fixtures/templates/generate_v1_0_0.exs \
  test/agents/config_template_v1_test.exs test/behaviours/config_test.exs \
  docs/guides/distributed_sessions.md MIGRATING-2.0.md
git commit -m "feat(templates)!: rebuild/3 translates Normandy 1.0 templates; drop the session slots"
```

---

### Task 3.3a: `Normandy.JSON`; Jason is the default and Poison is gone (roadmap 3.7; DX-26)

**Files:**
- Create: `lib/normandy/json.ex`
- Modify: `lib/normandy/schema.ex:274-294` (`__serializable__/1`) and `:408-417` (the generated `BaseIOSchema` impl)
- Modify: `lib/normandy/agents/io_model.ex:9,24` (delete both Poison derives)
- Modify: `lib/normandy/agents/dispatch.ex:346-354` (`execute_and_wrap/4`) and `:468` (`normalize_tool_input/1`)
- Modify: `lib/normandy/agents/base_agent.ex:551` (`unwrap_llm_content/1`) and `:1362-1363` (`with_output_schema/2`)
- Modify: `lib/normandy/components/stream_processor.ex:196`, `lib/normandy/components/agent_memory.ex:270-296` (`dump/1`, `load/1`), `lib/normandy/components/base_io_schema.ex:38-43` (Map impl), `lib/normandy/components/tool_result.ex:45-58`
- Modify: `lib/normandy/context/window_manager.ex:176-179,202-204`, `lib/normandy/context/token_counter.ex:199-201,261-264`, `lib/normandy/context/summarizer.ex:185-188`
- Modify: `lib/normandy/llm/json_deserializer.ex:63,127,161,193,394-398`, `lib/normandy/llm/claudio_adapter.ex:337-339,1432-1435`
- Modify: `mix.exs` (deps, the `hex: [ignore_advisories:]` comment, docs `groups_for_modules`), `mix.lock` (via `mix deps.unlock poison`), `config/dev.exs`, `config/test.exs`
- Modify: `CLAUDE.md:130,199,207`, `examples/README.md:52-57,181`, `examples/agent_horde/config/config.exs:3`, `examples/customer_support_app/config/{config,dev,prod,test}.exs`
- Modify: `MIGRATING-2.0.md` (new section)
- Test (create): `test/json_test.exs`, `test/json_struct_encoding_test.exs`
- Test (modify): `test/app_env_config_test.exs`, `test/components/tool_result_test.exs`, `test/schema/redact_test.exs`, plus the 51 lines that name Poison under `test/` (Step 7)

**Interfaces:**
- Consumes: `Jason` (already a direct, non-optional dependency in `mix.exs`), `Normandy.Components.ContentBlock.Describe.type_of/1`.
- Produces (header names, exact):
  `Normandy.JSON.encode!(term(), keyword()) :: String.t()`,
  `Normandy.JSON.encode(term(), keyword()) :: {:ok, String.t()} | {:error, Exception.t()}`,
  `Normandy.JSON.decode(String.t()) :: {:ok, term()} | {:error, Exception.t()}`,
  `Normandy.JSON.decode!(String.t()) :: term()`.
  Plus the internal `@doc false Normandy.JSON.own_encoder?(struct()) :: boolean()`.
- Adapter contract (documented in the moduledoc): `config :normandy, :adapter` names a module, default `Jason`. Normandy calls only `encode!/2` (with opts `[]` or `[pretty: true]`) and `decode/1`, which must return `{:ok, term}` or `{:error, exception}`. `decode!/1` is built on the adapter's `decode/1`, so an adapter needs no `decode!/1` and no `encode!/1`.
- Removed: `Normandy.LLM.JsonDeserializer.get_json_adapter/0`. The `:adapter` option of `JsonDeserializer.parse_and_validate/3` and `deserialize_with_retry/5` stays and defaults to `Normandy.JSON`. `Json.Decoder.decode/3` and `Json.RetryFeedback.build/4` keep their adapter-module parameter, and every caller passes `Normandy.JSON`.
- Task 3.4c rewrites `Dispatch`. It must keep `wrap_output/2` and `wrap_error/2` from Step 5d, or an equivalent check that runs before a result reaches memory.

- [ ] **Step 1: Write the failing tests**

Create `test/json_test.exs`:

```elixir
defmodule Normandy.JSONTest do
  # The default adapter (Jason): config/test.exs sets no :adapter.
  use ExUnit.Case, async: true

  defmodule Plain do
    @moduledoc false
    defstruct [:a, :nested]
  end

  defmodule Derived do
    @moduledoc false
    @derive {Jason.Encoder, only: [:shown]}
    defstruct [:shown, :hidden]
  end

  defmodule WithMeta do
    @moduledoc false
    use Normandy.Schema

    schema do
      field(:name, :string)
    end
  end

  describe "encode!/2" do
    test "a struct without an encoder is encoded as its map, at any depth" do
      json = Normandy.JSON.encode!(%{list: [%Plain{a: 1, nested: %Plain{a: 2}}]})

      assert Jason.decode!(json) == %{
               "list" => [%{"a" => 1, "nested" => %{"a" => 2, "nested" => nil}}]
             }
    end

    test "a struct's :__meta__ is left out" do
      assert Jason.decode!(Normandy.JSON.encode!(%WithMeta{name: "x"})) == %{"name" => "x"}
    end

    test "a struct with its own encoder is encoded by it" do
      assert Normandy.JSON.encode!(%Derived{shown: "a", hidden: "b"}) == ~s({"shown":"a"})
      assert Normandy.JSON.encode!(%{on: ~D[2026-10-05]}) == ~s({"on":"2026-10-05"})
    end

    test "pretty: true reaches the adapter" do
      assert Normandy.JSON.encode!(%{a: 1}, pretty: true) == "{\n  \"a\": 1\n}"
    end

    test "a term JSON cannot express raises the adapter's exception" do
      assert_raise Protocol.UndefinedError, fn -> Normandy.JSON.encode!(%{a: {1, 2}}) end
    end
  end

  describe "encode/2" do
    test "returns the JSON" do
      assert {:ok, ~s({"a":{"a":1,"nested":null}})} = Normandy.JSON.encode(%{a: %Plain{a: 1}})
    end

    test "returns the adapter's exception for a term JSON cannot express" do
      assert {:error, %Protocol.UndefinedError{value: {1, 2}}} =
               Normandy.JSON.encode(%{a: {1, 2}})
    end
  end

  describe "decode/1 and decode!/1" do
    test "an object decodes to a string-keyed map" do
      assert {:ok, %{"a" => [1, %{"b" => nil}]}} = Normandy.JSON.decode(~s({"a":[1,{"b":null}]}))
      assert Normandy.JSON.decode!(~s({"a":1})) == %{"a" => 1}
    end

    test "text that is not JSON is the adapter's exception" do
      assert {:error, %Jason.DecodeError{}} = Normandy.JSON.decode("not json")
      assert_raise Jason.DecodeError, fn -> Normandy.JSON.decode!("not json") end
    end
  end
end
```

Create `test/json_struct_encoding_test.exs` (Review Focus 4):

```elixir
defmodule Normandy.JSONStructEncodingTest do
  @moduledoc """
  Review Focus 4: a struct Jason has no encoder for, inside a tool result, a memory
  dump or a context-window estimate, is encoded as its map without __meta__ â
  never a Protocol.UndefinedError and never inspect/1 output sent to the model.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch}
  alias Normandy.Components.{AgentMemory, BaseIOSchema, Message, ToolCall, ToolResult}
  alias Normandy.Context.{Summarizer, WindowManager}
  alias Normandy.Test.FakeTool

  defmodule Reading do
    @moduledoc false
    defstruct [:station, :celsius]
  end

  # Sends the summary request's messages to `notify`.
  defmodule RecordingClient do
    @moduledoc false
    defstruct [:notify]

    defimpl Normandy.Agents.Model do
      def converse(client, request, _opts) do
        send(client.notify, {:summarize_request, request.messages})

        {:ok,
         %Normandy.LLM.Response{content: %{request.response_model | chat_message: "summary"}}}
      end

      def stream(_client, _request, _opts),
        do: {:error, Normandy.LLMError.new(type: :unsupported, retryable?: false)}
    end
  end

  # A function, not a module attribute: the struct is not defined until the
  # module body around it compiles.
  defp reading, do: %Reading{station: "SFO", celsius: 15.5}
  @reading_json %{"station" => "SFO", "celsius" => 15.5}

  defp execute(output) do
    pipeline = %{Dispatch.default_pipeline() | execute_fn: fn _, _, _, _ -> output end}
    call = %ToolCall{id: "t1", name: "weather", input: %{}}
    Dispatch.execute(%{name: "agent"}, %FakeTool{}, call, pipeline)
  end

  defp model_content(%ToolResult{} = result) do
    [%{content: content}] = BaseIOSchema.to_json(result)
    content
  end

  test "a tool result is sent to the model as JSON with the struct as its map" do
    result = execute({:ok, %{readings: [reading()]}})

    assert %ToolResult{is_error: false} = result
    assert Jason.decode!(model_content(result)) == %{"readings" => [@reading_json]}
  end

  test "a tool output JSON cannot express becomes an error result naming its type" do
    assert %ToolResult{
             is_error: true,
             output: %{
               error: "the tool ran, but its output cannot be sent as JSON: it contains a tuple"
             }
           } = execute({:ok, %{at: {2026, 10, 5}}})
  end

  test "an error reason JSON cannot express is sent as its text" do
    result = execute({:error, {:http, 503}})

    assert %ToolResult{is_error: true, output: %{error: "{:http, 503}"}} = result
    assert Jason.decode!(model_content(result)) == %{"error" => "{:http, 503}"}
  end

  test "a memory dump encodes the struct as its map and loads it back as one" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.add_message("tool", %ToolResult{tool_call_id: "t1", output: reading()})

    assert [%ToolResult{output: @reading_json}] =
             memory
             |> AgentMemory.dump()
             |> AgentMemory.load()
             |> AgentMemory.messages()
             |> Enum.map(fn %Message{content: content} -> content end)
  end

  test "a context-window estimate counts the struct's JSON" do
    expected = WindowManager.estimate_tokens(Jason.encode!(@reading_json))

    assert WindowManager.estimate_message_content_tokens(reading()) == expected
    assert WindowManager.estimate_message_content_tokens([reading()]) == expected
  end

  test "the summary prompt shows the struct as JSON, not inspect output" do
    agent = BaseAgent.init(%{client: %RecordingClient{}, model: "m"})
    messages = [%{role: "user", content: reading()}]

    {:ok, "summary"} =
      Summarizer.summarize_messages(%RecordingClient{notify: self()}, agent, messages)

    assert_received {:summarize_request, [%Message{content: prompt}]}
    assert prompt =~ ~s("station":"SFO")
    refute prompt =~ "%Normandy.JSONStructEncodingTest.Reading{"
  end
end
```

In `test/components/tool_result_test.exs`, add before `test "text and numbers are sent as text"`:

```elixir
  test "an atom, a boolean and nil are sent as JSON, not inspect/1 text" do
    assert content(:ok) == ~s("ok")
    assert content(true) == "true"
    assert content(nil) == "null"
  end
```

In `test/schema/redact_test.exs`, add these modules after `defmodule Person ... end` and before `@secret`:

```elixir
  defmodule DerivedLogin do
    use Normandy.Schema
    @derive {Jason.Encoder, only: [:name, :password]}

    io_schema "login with a derived encoder" do
      field(:name, :string, description: "user name")
      field(:password, :string, description: "password", redact: true)
    end
  end

  defmodule DerivedAll do
    use Normandy.Schema
    @derive Jason.Encoder

    io_schema "every field derived" do
      field(:name, :string, description: "user name")
      field(:home, Address, description: "home")
    end
  end
```

Then add these tests inside `describe "redact: true keeps the value out of every serialization"`, before `test "__str__ and __rich__"`:

```elixir
    test "a derived encoder that names a redacted field gets null, never the value" do
      json = BaseIOSchema.to_json(%DerivedLogin{name: "ana", password: @secret})

      assert Jason.decode!(json) == %{"name" => "ana", "password" => nil}
    end

    test "a bare @derive encodes __meta__ as null and still hides nested redacted fields" do
      json =
        BaseIOSchema.to_json(%DerivedAll{
          name: "ana",
          home: %Address{street: "Main", pin: @secret}
        })

      assert Jason.decode!(json) == %{
               "name" => "ana",
               "home" => %{"street" => "Main"},
               "__meta__" => nil
             }
    end
```

In `test/app_env_config_test.exs`:

1. Change `alias Normandy.Components.{BaseIOSchema, StreamProcessor}` to `alias Normandy.Components.{AgentMemory, BaseIOSchema, StreamProcessor}`.
2. Replace the `TaggingJson` stub (lines 52-56). Its `encode!/1` was never called once every encode goes through `encode!/2`:

```elixir
    # Normandy.JSON calls an adapter's encode!/2 and decode/1, nothing else.
    defmodule TaggingJson do
      @moduledoc false
      def encode!(_value, []), do: "tagged"
      def encode!(_value, pretty: true), do: "tagged-pretty"
    end
```

`TaggingDecoder` (`decode/1` and `encode!/2`) is unchanged.

3. Add these tests at the end of `describe ":adapter"`, after the test that ends `assert system =~ "schema-by-adapter"`:

```elixir
    test "decode!/1 and AgentMemory.load/1 need only the adapter's decode/1" do
      put_env(:adapter, TaggingDecoder)

      assert %{"decoded_by" => "adapter"} = Normandy.JSON.decode!("{}")

      assert_raise ArgumentError, ~r/unsupported dump version nil/, fn ->
        AgentMemory.load("{}")
      end
    end

    defmodule BareReasonDecoder do
      @moduledoc false
      def decode(_json), do: {:error, :invalid}
      def encode!(_value, _opts), do: "{}"
    end

    test "a decode/1 that returns a bare reason is an ArgumentError naming the adapter" do
      put_env(:adapter, BareReasonDecoder)

      assert_raise ArgumentError,
                   "Normandy.AppEnvConfigTest.BareReasonDecoder.decode/1 must return " <>
                     "{:ok, term} or {:error, exception}, got: {:error, a reason that is not an exception}",
                   fn -> Normandy.JSON.decode("{}") end
    end

    test "an adapter that is not a module is an ArgumentError" do
      put_env(:adapter, "Jason")

      assert_raise ArgumentError,
                   "config :normandy, :adapter must be a module with encode!/2 and decode/1, " <>
                     "got: a string (5 bytes)",
                   fn -> Normandy.JSON.encode!(%{}) end
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/json_test.exs test/json_struct_encoding_test.exs test/components/tool_result_test.exs test/schema/redact_test.exs test/app_env_config_test.exs`

Expected: FAIL.
- Every `Normandy.JSONTest` test fails with `UndefinedFunctionError ... (module Normandy.JSON is not available)`.
- In `JSONStructEncodingTest`, "a tool output JSON cannot express..." fails because the result has `is_error: false`, and "an error reason JSON cannot express..." fails because `output.error` is the tuple. The memory, estimate and summary tests pass under Poison, which encodes any struct. They guard the switch to Jason.
- `tool_result_test` fails on `content(:ok)`, which is `":ok"`.
- The two new redact tests fail because Poison ignores `Jason.Encoder` derives.
- `app_env_config_test` fails on "is read when an io_schema struct is encoded" (`TaggingJson.encode!/1` is undefined) and on the three new tests.

- [ ] **Step 3: Create `lib/normandy/json.ex`**

```elixir
defmodule Normandy.JSON do
  @moduledoc """
  The one place Normandy encodes and decodes JSON.

  ## Adapter

  The JSON library is `config :normandy, adapter: Module`, read on every call (so
  runtime config applies), default `Jason`. Normandy calls exactly two of its
  functions, so any module that provides them works:

    * `encode!(term, opts) :: String.t()` â raises on a term it cannot encode.
      `opts` is `[]` or `[pretty: true]`.
    * `decode(String.t()) :: {:ok, term()} | {:error, Exception.t()}` â objects
      decode to string-keyed maps.

  ## Structs

  Before the adapter sees a term, every struct in it, at any depth, is either kept
  or replaced by a plain map:

    * A struct with its own `Jason.Encoder` implementation (`@derive Jason.Encoder`,
      a `defimpl`, or one Jason ships: `Date`, `DateTime`, `Decimal`, ...) is kept,
      and that implementation decides its fields. Its fields are not walked.
    * Any other struct becomes its map without `:__struct__` and `:__meta__`, and
      its values are walked the same way.

  The check is `Jason.Encoder` whatever the adapter, because Jason is always a
  Normandy dependency. With another adapter, a derived struct reaches that adapter
  as a struct and the adapter decides how to encode it.

  A term JSON cannot express (a tuple, a pid, a reference, a function) is left as
  it is: the adapter raises on it, and `encode/2` returns that exception.
  """

  alias Normandy.Components.ContentBlock.Describe

  @doc "Encodes `term`; raises the adapter's exception when it cannot."
  @spec encode!(term(), keyword()) :: String.t()
  def encode!(term, opts \\ []) when is_list(opts) do
    adapter().encode!(normalize(term), opts)
  end

  @doc """
  Encodes `term`, returning `{:error, exception}` with whatever the adapter raised
  (for Jason, `Protocol.UndefinedError` or `Jason.EncodeError`).
  """
  @spec encode(term(), keyword()) :: {:ok, String.t()} | {:error, Exception.t()}
  def encode(term, opts \\ []) when is_list(opts) do
    normalized = normalize(term)
    adapter = adapter()

    try do
      {:ok, adapter.encode!(normalized, opts)}
    rescue
      exception -> {:error, exception}
    end
  end

  @doc "Decodes a JSON string; objects become string-keyed maps."
  @spec decode(String.t()) :: {:ok, term()} | {:error, Exception.t()}
  def decode(json) when is_binary(json) do
    adapter = adapter()

    case adapter.decode(json) do
      {:ok, _value} = ok ->
        ok

      {:error, %{__exception__: true}} = error ->
        error

      other ->
        raise ArgumentError,
              "#{inspect(adapter)}.decode/1 must return {:ok, term} or {:error, exception}, " <>
                "got: #{shape(other)}"
    end
  end

  @doc "Decodes a JSON string; raises the adapter's exception when it is not JSON."
  @spec decode!(String.t()) :: term()
  def decode!(json) when is_binary(json) do
    case decode(json) do
      {:ok, value} -> value
      {:error, exception} -> raise exception
    end
  end

  defp adapter do
    case Application.get_env(:normandy, :adapter, Jason) do
      module when is_atom(module) and not is_nil(module) ->
        module

      other ->
        raise ArgumentError,
              "config :normandy, :adapter must be a module with encode!/2 and decode/1, " <>
                "got: #{Describe.type_of(other)}"
    end
  end

  defp shape({:error, _reason}), do: "{:error, a reason that is not an exception}"
  defp shape(other), do: Describe.type_of(other)

  defp normalize(%_{} = struct) do
    if own_encoder?(struct) do
      struct
    else
      struct |> Map.from_struct() |> Map.delete(:__meta__) |> normalize()
    end
  end

  defp normalize(map) when is_map(map), do: :maps.map(fn _key, value -> normalize(value) end, map)
  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  @doc false
  # Shared with Normandy.Schema.__serializable__/1, which applies the same rule.
  @spec own_encoder?(struct()) :: boolean()
  def own_encoder?(struct), do: Jason.Encoder.impl_for(struct) not in [nil, Jason.Encoder.Any]
end
```

`rescue exception ->` in `encode/2` wraps only the adapter call. It is not a fallback: the exception goes back to the caller as `{:error, exception}`, and the spec promises that shape. `Jason.Encoder.impl_for/1` returns `Jason.Encoder.Any` for a struct with no derive, because Jason sets `@fallback_to_any true`. That `Any` impl is the one that raises `Protocol.UndefinedError`.

Run: `mix test test/json_test.exs`. Expected: `9 tests, 0 failures`.

- [ ] **Step 4: Route the schema encoder through `Normandy.JSON`**

In `lib/normandy/schema.ex`, replace `__serializable__/1`'s first clause and its comment (lines 274-287):

```elixir
  @doc false
  # What an io_schema's to_json encodes: __meta__ (internal bookkeeping) and every
  # redact: true field removed, at every depth, so a nested schema hides its
  # secrets too. Schema structs stay structs (missing those keys), so a @derive'd
  # encoder still handles the remaining fields; other structs are left alone.
  @spec __serializable__(term()) :: term()
  def __serializable__(%mod{} = struct) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1) do
      kept = Map.drop(struct, [:__meta__ | mod.__schema__(:redact_fields)])
      :maps.map(fn _key, value -> __serializable__(value) end, kept)
    else
      struct
    end
  end
```

with:

```elixir
  @doc false
  # What an io_schema's to_json encodes: __meta__ (internal bookkeeping) and every
  # redact: true field removed, at every depth, so a nested schema hides its
  # secrets too. The struct rule is Normandy.JSON's: a struct with its own
  # Jason.Encoder impl stays a struct and the impl picks the fields, so a schema
  # one keeps every key (a derived impl matches on all the fields it encodes)
  # with __meta__ and the redacted fields set to nil; any other struct becomes a
  # plain map without them.
  @spec __serializable__(term()) :: term()
  def __serializable__(%mod{} = struct) do
    schema? = Code.ensure_loaded?(mod) and function_exported?(mod, :__schema__, 1)
    hidden = if schema?, do: [:__meta__ | mod.__schema__(:redact_fields)], else: [:__meta__]

    cond do
      not Normandy.JSON.own_encoder?(struct) ->
        struct |> Map.from_struct() |> Map.drop(hidden) |> __serializable__()

      schema? ->
        :maps.map(&serializable_field(&1, &2, hidden), struct)

      true ->
        struct
    end
  end
```

After `def __serializable__(other), do: other`, add:

```elixir

  defp serializable_field(:__struct__, module, _hidden), do: module

  defp serializable_field(key, value, hidden),
    do: if(key in hidden, do: nil, else: __serializable__(value))
```

In the generated impl (lines 410-417), replace:

```elixir
            def __str__(str), do: adapter().encode!(serializable(str))
            def __rich__(str), do: adapter().encode!(serializable(str), pretty: true)
            def to_json(str), do: adapter().encode!(serializable(str))

            # Read when encoding, like every other JSON call in Normandy: a value
            # captured at compile time would ignore runtime config, and a release
            # would refuse to boot when the two differ.
            defp adapter, do: Application.get_env(:normandy, :adapter, Poison)
```

with:

```elixir
            def __str__(str), do: Normandy.JSON.encode!(serializable(str))
            def __rich__(str), do: Normandy.JSON.encode!(serializable(str), pretty: true)
            def to_json(str), do: Normandy.JSON.encode!(serializable(str))
```

(Task 3.6 deletes `__str__`/`__rich__`. This task only reroutes them.)

In `lib/normandy/agents/io_model.ex`, delete both lines `  @derive {Poison.Encoder, only: [:chat_message]}` (9 and 24). `chat_message` is each schema's only field besides `__meta__`, which `__serializable__/1` drops, so the JSON is unchanged.

- [ ] **Step 5: Route every other adapter site through `Normandy.JSON`**

a. `lib/normandy/llm/json_deserializer.ex`:
- Lines 161 and 193: `adapter = Keyword.get(opts, :adapter, get_json_adapter())` becomes `adapter = Keyword.get(opts, :adapter, Normandy.JSON)`.
- Lines 63 and 127 (the two docs of `:adapter`): `` `:adapter` - JSON adapter module (default: from `:normandy` app config) `` becomes `` `:adapter` - a module with `decode/1` and `encode!/2` (default: `Normandy.JSON`) ``.
- Delete the last function (lines 393-398):

```elixir

  # Get JSON adapter from application config
  @doc false
  def get_json_adapter do
    Application.get_env(:normandy, :adapter, Poison)
  end
```

b. `lib/normandy/llm/claudio_adapter.ex:1432-1435`. Replace:

```elixir
        adapter = JsonDeserializer.get_json_adapter()

        with {:ok, parsed} when is_map(parsed) <-
               Decoder.decode(content, adapter, []),
```

with:

```elixir
        with {:ok, parsed} when is_map(parsed) <-
               Decoder.decode(content, Normandy.JSON, []),
```

The `JsonDeserializer` alias is still used elsewhere in the file, and the compile in Step 6 confirms it.

At lines 337-339, the stale comment is wrong: Claudio 0.7 decodes SSE data with `Jason.decode/1` and string keys (see `../Claudio/lib/claudio/messages/stream.ex:647-654`). Replace:

```elixir
    # Claudio's parse_events emits `%{event: "...", data: %{...}}` where
    # `data` was decoded with `Poison.decode(..., keys: :atoms)` â so its
    # keys are atoms. Normandy's StreamProcessor pattern-matches
```

with:

```elixir
    # Claudio's parse_events emits `%{event: "...", data: %{...}}`; `data` is
    # decoded with string keys (Claudio < 0.7 used atom keys), and data_get/2
    # reads either form. Normandy's StreamProcessor pattern-matches
```

c. One-line rewrites. Each `Application.get_env(:normandy, :adapter, Poison).<fun>(` becomes `Normandy.JSON.<fun>(`:
- `lib/normandy/agents/dispatch.ex:468`: `case Normandy.JSON.decode(input) do`
- `lib/normandy/agents/base_agent.ex:551`: `case Normandy.JSON.decode(content) do`
- `lib/normandy/components/stream_processor.ex:196`: `case Normandy.JSON.decode(json) do`
- `lib/normandy/agents/base_agent.ex:1362-1363`: change the two lines

```elixir
        schema_json =
          Application.get_env(:normandy, :adapter, Poison).encode!(schema, pretty: true)
```

into one line:

```elixir
        schema_json = Normandy.JSON.encode!(schema, pretty: true)
```

d. `lib/normandy/agents/dispatch.ex:346-354`. Replace `execute_and_wrap/4`:

```elixir
  defp execute_and_wrap(config, call, prepared, execute_fn) do
    case call_execute_fn(execute_fn, config, prepared, call) do
      {:ok, result} ->
        %ToolResult{tool_call_id: call.id, output: result, is_error: false}

      {:error, error} ->
        %ToolResult{tool_call_id: call.id, output: %{error: error}, is_error: true}
    end
  end
```

with:

```elixir
  defp execute_and_wrap(config, call, prepared, execute_fn) do
    case call_execute_fn(execute_fn, config, prepared, call) do
      {:ok, result} -> wrap_output(call, result)
      {:error, error} -> wrap_error(call, error)
    end
  end

  # The model reads a tool result as JSON (ToolResult's BaseIOSchema impl), and
  # memory keeps the result for every later request. So an output JSON cannot
  # express (a tuple, a pid) is replaced here by an error result that says so,
  # before it reaches memory.
  defp wrap_output(call, output) when is_binary(output) or is_number(output),
    do: %ToolResult{tool_call_id: call.id, output: output, is_error: false}

  defp wrap_output(call, output) do
    case Normandy.JSON.encode(output) do
      {:ok, _json} ->
        %ToolResult{tool_call_id: call.id, output: output, is_error: false}

      {:error, exception} ->
        %ToolResult{
          tool_call_id: call.id,
          output: %{
            error:
              "the tool ran, but its output cannot be sent as JSON: #{unencodable(exception)}"
          },
          is_error: true
        }
    end
  end

  # An error reason is a message for the model: one JSON cannot express (a tuple
  # such as {:http, 500}) is sent as its inspect/1 text, the only form it has.
  defp wrap_error(call, error) do
    output =
      case Normandy.JSON.encode(%{error: error}) do
        {:ok, _json} -> %{error: error}
        {:error, _exception} -> %{error: inspect(error)}
      end

    %ToolResult{tool_call_id: call.id, output: output, is_error: true}
  end

  defp unencodable(%Protocol.UndefinedError{value: value}),
    do: "it contains #{Describe.type_of(value)}"

  defp unencodable(exception), do: Exception.message(exception)
```

(`Describe` is already aliased in `dispatch.ex`.) All three shells (`run/2`, `stream/3` and `Turn.Server`) execute tools through `Dispatch.execute/4` and then `execute_and_wrap/4` (`base_agent.ex:1822,1829`, `turn/server.ex:1520,1554`), so one change covers them.

e. `lib/normandy/components/tool_result.ex:45-58`. Replace:

```elixir
  # Maps and lists (a search tool's results) go to the model as JSON, through
  # the configured adapter. A term JSON cannot express (a tuple, a pid) is
  # shown with inspect/1, which still gives the model the whole value.
  defp format_tool_output(output) when is_map(output) or is_list(output) do
    adapter = Application.get_env(:normandy, :adapter, Poison)

    try do
      adapter.encode!(output)
    rescue
      _ -> inspect(output)
    end
  end

  defp format_tool_output(output), do: inspect(output)
```

with:

```elixir
  # Anything else (a map, a list, an atom, a boolean, nil) goes to the model as
  # JSON. Dispatch has already turned an output JSON cannot express into an
  # error result, so this raises only for a ToolResult built by hand.
  defp format_tool_output(output), do: Normandy.JSON.encode!(output)
```

The two clauses above it, for a binary and a number, stay.

f. `lib/normandy/components/agent_memory.ex`:
- In `dump/1`, delete `    adapter = Application.get_env(:normandy, :adapter, Poison)` and the blank line after it, and change `adapter.encode!(%{` to `Normandy.JSON.encode!(%{`.
- In `load/1`, delete `    adapter = Application.get_env(:normandy, :adapter, Poison)`, which sits directly above the `# Decode with string keys only.` comment, and change `loaded = adapter.decode!(dump)` to `loaded = Normandy.JSON.decode!(dump)`.

g. `lib/normandy/components/base_io_schema.ex:38-43`. Replace the Map impl's `to_json/1`:

```elixir
  def to_json(map) do
    # Convert map to JSON string using the configured JSON adapter
    adapter = Application.get_env(:normandy, :adapter, Poison)
    adapter.encode!(map)
  end
```

with:

```elixir
  def to_json(map), do: Normandy.JSON.encode!(map)
```

h. The hard-coded `Poison.encode!` calls. Each depended on "Poison encodes any struct", which `Normandy.JSON` now provides.
- `lib/normandy/context/window_manager.ex:176-179`: replace

```elixir
    # For structured content, estimate based on JSON representation. Poison, not
    # the configured adapter: it encodes any struct, and this is only a size.
    content
    |> Poison.encode!()
```

with

```elixir
    # For structured content, estimate based on its JSON (structs as their maps).
    content
    |> Normandy.JSON.encode!()
```

- `window_manager.ex:202-204`: change the comment `# never silently count zero (Poison: it encodes any struct).` to `# never silently count zero.`, and change `block |> Poison.encode!() |> estimate_tokens()` to `block |> Normandy.JSON.encode!() |> estimate_tokens()`.
- `lib/normandy/context/token_counter.ex:199-201`: replace

```elixir
    # For structured content, convert to JSON (a text rendering; Poison, not the
    # configured adapter, because it encodes any struct)
    Poison.encode!(content)
```

with

```elixir
    # For structured content, convert to JSON (a text rendering; structs as their maps)
    Normandy.JSON.encode!(content)
```

- `token_counter.ex:263`: `|> Poison.encode!()` becomes `|> Normandy.JSON.encode!()`.
- `lib/normandy/context/summarizer.ex:185-188`: replace

```elixir
    # Try to extract chat_message or convert to JSON. Poison, not the configured
    # adapter: this is text for the summary prompt, and Poison encodes any struct.
    case Map.get(content, :chat_message) do
      nil -> Poison.encode!(content)
```

with

```elixir
    # Try to extract chat_message or convert to JSON (structs as their maps).
    case Map.get(content, :chat_message) do
      nil -> Normandy.JSON.encode!(content)
```

Acceptance grep: `grep -rn "Poison\|Application.get_env(:normandy, :adapter" lib/`. Expected output: exactly one line, `lib/normandy/json.ex:...: case Application.get_env(:normandy, :adapter, Jason) do`.

- [ ] **Step 6: Drop Poison from the build**

`mix.exs`:
- In `deps/0`, delete the line `      {:poison, "~> 6.0"},`.
- In the `hex:` comment (lines 18-19), replace

```elixir
      # decimal arrives only with the optional ecto/postgrex deps; its fix (3.0.0) is blocked
      # by poison 6.0.0, the latest release, which declares an optional `decimal ~> 2.1`.
```

with

```elixir
      # decimal arrives only with the optional ecto/postgrex deps and the test-only ex_mcp; its
      # fix (3.0.0) is blocked by ex_json_schema 0.11.3 (via ex_mcp), which requires `decimal ~> 2.0`.
```

  Keep the `"EEF-CVE-2026-32686"` ignore entry. After the unlock, `mix.lock` still pins `decimal 2.4.1`, `ex_json_schema 0.11.3` requires `decimal ~> 2.0`, and `mix hex.audit` still reports the advisory. I verified all three in a scratch copy.
- In `docs: [groups_for_modules: [Core: [...]]]`, change `Normandy.ParameterizedType` to `Normandy.ParameterizedType,` and add `Normandy.JSON` after it.

`config/dev.exs`: the whole file becomes:

```elixir
import Config
```

`config/test.exs`: delete lines 3-4 (`config :normandy,` and `  adapter: Poison`) and the blank line after them, so the file starts `import Config`, a blank line, then `# Configure Claudio HTTP timeouts ...`.

Run:

```bash
mix deps.unlock poison
mix deps.unlock --check-unused && echo unlock-ok
mix deps.clean poison          # removes only deps/poison and its _build dirs, to prove nothing still loads it
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
grep -n ":poison" mix.exs
```

Expected:
- `Unlocked deps: * poison`, then `unlock-ok`.
- Both compiles finish with no warnings.
- The last grep prints nothing. `mix.lock` still contains the word `poison` once: the stale `"claudio": {:hex, :claudio, "0.6.0", ...}` entry lists it as a dependency of Claudio 0.6.0. `mix.exs` uses the path dep `../Claudio` (0.7.0, Jason only), so that entry is never resolved. Leave it alone: it changes when Claudio 0.7.0 is published (decision 2).

- [ ] **Step 7: Rewrite the 51 test lines that name Poison**

Run each command from the repository root. The counts are lines changed.

```bash
# 19 lines: the option now names the module that is the default anyway
perl -pi -e 's/adapter: Poison\b/adapter: Normandy.JSON/g' test/llm/json_deserializer_test.exs
# 6 lines
perl -pi -e 's/, Poison\)/, Normandy.JSON)/; s/^(\s+)Poison$/$1Normandy.JSON/; s/build\/4 with Poison includes/build\/4 with Normandy.JSON includes/' test/llm/json/retry_feedback_test.exs
# 6 lines
perl -pi -e 's/, Poison, /, Normandy.JSON, /g' test/llm/json/decoder_test.exs
# 13 lines: decode or encode what Normandy produced with Jason itself
perl -pi -e 's/\bPoison\.(encode|decode)/Jason.$1/g' test/llm/json/scanner_test.exs test/schema_nested_test.exs test/schema/json_schema_types_test.exs test/schema/redact_test.exs test/schema/io_schema_json_test.exs test/components/agent_memory_test.exs
# 2 lines
perl -pi -e 's/\@derive \{Poison\.Encoder/\@derive {Jason.Encoder/' test/schema/io_schema_json_test.exs test/support/iotest.ex
# 3 lines: the hand-written BaseIOSchema impl encodes through Normandy.JSON
perl -pi -e 's/Poison\.encode!\(str/Normandy.JSON.encode!(str/' test/support/iotest.ex
# 1 line (a comment)
perl -pi -e 's/`Poison\.encode!`s the whole thing/encodes the whole thing/' test/agents/base_agent_streaming_test.exs
```

In `test/components/base_io_schema_test.exs` ("Map impl regression"), replace

```elixir
      adapter = Application.get_env(:normandy, :adapter, Poison)
      expected = adapter.encode!(%{a: 1})
      assert BaseIOSchema.to_json(%{a: 1}) == expected
```

with

```elixir
      assert BaseIOSchema.to_json(%{a: 1}) == ~s({"a":1})
```

Check: `grep -rn "Poison" lib/ test/ config/` prints nothing.

`io_schema_json_test.exs`'s "a derived encoder still decides the fields" test keeps its meaning (Ruling 3). Its `Derived` module now derives `Jason.Encoder, only: [:shown]`, and the expected JSON is unchanged.

- [ ] **Step 8: Run the new and touched tests**

Run: `mix format && mix test test/json_test.exs test/json_struct_encoding_test.exs test/components/tool_result_test.exs test/schema/redact_test.exs test/schema/io_schema_json_test.exs test/app_env_config_test.exs test/llm test/components test/context test/schema`

Expected: ` 0 failures`. `mix format` re-wraps two lines in `json_deserializer_test.exs` (304, 307) that the rename made too long.

- [ ] **Step 9: Docs and example configs**

`CLAUDE.md`:
- Line 130: `  - Uses adapter from `:normandy` app config (`:adapter` key, typically Poison)` becomes `` `  - Encodes through `Normandy.JSON` (adapter from `config :normandy, :adapter`, default Jason)` ``.
- Line 199: `- Application config requires `:adapter` (JSON encoder/decoder, e.g., Poison)` becomes ``- `:adapter` (optional, default `Jason`) - the JSON library `Normandy.JSON` calls; any module with `encode!/2` and `decode/1` (see the `Normandy.JSON` moduledoc)``.
- Line 207: `- **Poison** - JSON encoding/decoding` becomes `- **Jason** - JSON encoding/decoding (the default `:adapter`)`.

`examples/README.md`: replace lines 52-57

````markdown
2. Configure the JSON adapter in `config/config.exs`:

```elixir
config :normandy,
  adapter: Poison  # or Jason
```
````

with

```markdown
2. No JSON configuration is needed: Normandy uses Jason. To use another library, set
   `config :normandy, adapter: MyJSON` (a module with `encode!/2` and `decode/1`).
```

Then change line 181, `3. Add config files for JSON adapter`, to `3. Add config files (Normandy needs no JSON adapter setting)`.

Example apps (the Poison lines only; Wave 7 owns the rest):
- `examples/agent_horde/config/config.exs`: delete line 3, `config :normandy, adapter: Poison`, and the blank line after it.
- `examples/customer_support_app/config/config.exs`: delete the three lines `# Configure the JSON adapter for Normandy`, `config :normandy,` and `  adapter: Poison`, and the blank line after them.
- `examples/customer_support_app/config/dev.exs`, `prod.exs`, `test.exs`: delete the three lines `# Configure JSON adapter`, `config :normandy,` and `  adapter: Poison`, and the blank line before them.

Check: `git ls-files examples | xargs grep -n "Poison"` now prints only the two stale example `mix.lock` lines (Wave 7).

- [ ] **Step 10: MIGRATING**

Append a new section to `MIGRATING-2.0.md`, numbered §23 (after Task 3.2's §22; check with `grep -n '^## [0-9]' MIGRATING-2.0.md | tail -1`), placed before `## New, non-breaking`:

```markdown
## 23. JSON goes through `Normandy.JSON`; Jason is the default and Poison is gone

- Normandy no longer depends on Poison. `config :normandy, :adapter` is optional and
  defaults to `Jason`. Remove `adapter: Poison` from your config, or keep it and add
  `{:poison, "~> 6.0"}` to your own deps.
- An adapter is any module with `encode!(term, opts)` (opts is `[]` or `[pretty: true]`)
  and `decode(json)` returning `{:ok, term}` or `{:error, exception}`. Normandy calls
  nothing else. A `decode/1` that returns `{:error, reason}` with a reason that is not an
  exception raises `ArgumentError`.
- Structs: a struct with its own `Jason.Encoder` implementation is encoded by it; any
  other struct is encoded as its map without `:__struct__` and `:__meta__`, at any depth.
  Normandy no longer looks at `Poison.Encoder`: replace `@derive {Poison.Encoder, ...}`
  with `@derive {Jason.Encoder, ...}`. On an `io_schema`, a derived encoder that lists a
  `redact: true` field encodes it as `null`, and a bare `@derive Jason.Encoder` encodes
  `"__meta__": null`; derive with `only:` (or `except: [:__meta__]`).
- Tool results: an atom, a boolean or `nil` output reaches the model as JSON (`"ok"`,
  `true`, `null`), not as `inspect/1` text (`:ok`, `nil`). An output JSON cannot express
  (a tuple, a pid) is now an `is_error: true` result, "the tool ran, but its output
  cannot be sent as JSON: it contains a tuple", instead of its `inspect/1` text. An
  error reason JSON cannot express (`{:error, {:http, 503}}`) is still sent as its
  `inspect/1` text.
- `Normandy.LLM.JsonDeserializer.get_json_adapter/0` is removed. The `:adapter` option
  of `parse_and_validate/3` and `deserialize_with_retry/5` defaults to `Normandy.JSON`.
```

- [ ] **Step 11: Full suite and commit**

Run: `mix format && mix test 2>&1 | tail -3`. Expected: ` 0 failures`.

Run: `mix credo --strict 2>&1 | grep found`. Expected: `found no issues`.

```bash
git add lib/normandy/json.ex lib/normandy/schema.ex lib/normandy/agents/io_model.ex \
  lib/normandy/agents/dispatch.ex lib/normandy/agents/base_agent.ex \
  lib/normandy/components/stream_processor.ex lib/normandy/components/agent_memory.ex \
  lib/normandy/components/base_io_schema.ex lib/normandy/components/tool_result.ex \
  lib/normandy/context/window_manager.ex lib/normandy/context/token_counter.ex \
  lib/normandy/context/summarizer.ex lib/normandy/llm/json_deserializer.ex \
  lib/normandy/llm/claudio_adapter.ex mix.exs mix.lock config/dev.exs config/test.exs \
  CLAUDE.md examples/README.md examples/agent_horde/config/config.exs \
  examples/customer_support_app/config/config.exs examples/customer_support_app/config/dev.exs \
  examples/customer_support_app/config/prod.exs examples/customer_support_app/config/test.exs \
  MIGRATING-2.0.md test/json_test.exs test/json_struct_encoding_test.exs \
  test/app_env_config_test.exs test/components/tool_result_test.exs test/schema/redact_test.exs \
  test/llm/json_deserializer_test.exs test/llm/json/retry_feedback_test.exs \
  test/llm/json/decoder_test.exs test/llm/json/scanner_test.exs test/schema_nested_test.exs \
  test/schema/json_schema_types_test.exs test/schema/io_schema_json_test.exs \
  test/components/agent_memory_test.exs test/support/iotest.ex \
  test/agents/base_agent_streaming_test.exs test/components/base_io_schema_test.exs
git commit -m "feat!(json): Normandy.JSON with Jason by default; drop Poison"
```

---

### Task 3.3b: Example tools leave `lib/` (roadmap 3.7; DX-25)

**Files:**
- Move: `lib/normandy/tools/examples/{calculator,enhanced_calculator,list_processor,string_manipulator}.ex` â `test/support/tools/` (same file names)
- Move: `lib/normandy/tools/examples/weather.ex` â `examples/tools/weather.ex`
- Modify: `lib/normandy/agents/base_agent.ex:2014-2016` (the `register_tool/2` doc example)
- Modify: `test/support/normandy_integration_helper.ex:88-98`, `test/support/integration_helper.ex:248-259`
- Modify: `examples/README.md`, `MIGRATING-2.0.md`
- Test: `test/tools/examples_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: no `Normandy.Tools.Examples.*` module in the library or on HexDocs. The test fixtures `Normandy.Tools.Examples.Calculator`, `.EnhancedCalculator`, `.ListProcessor` and `.StringManipulator` live in `test/support/tools/` and **keep their module names** (controller ruling C1: Task 3.4 names them throughout, and the 17 test files that use them stay untouched). The example weather tool `MyApp.Tools.Weather` is in `examples/tools/weather.ex`. Mix does not compile it. The live test that uses it compiles it at run time.
- Rename rule: only `Normandy.Tools.Examples.Weather` is renamed, to `MyApp.Tools.Weather`; it appears only in `examples/tools/weather.ex` and `test/support/normandy_integration_helper.ex`.
- The moved tools keep the *current* contract (`use Normandy.Tools.SchemaBaseTool` / `defimpl Normandy.Tools.BaseTool`). Task 3.4c migrates them. It must also migrate `examples/tools/weather.ex` by hand, because no compile reaches that file.

- [ ] **Step 1: Write the failing test**

In `test/tools/examples_test.exs`, add this as the first test of the module, after the aliases:

```elixir
  test "the example tools are test fixtures, not part of the library" do
    for name <- ~w(Calculator EnhancedCalculator ListProcessor StringManipulator) do
      module = Module.concat(Normandy.Tools.Examples, name)
      assert Code.ensure_loaded?(module), "#{inspect(module)} is not compiled in the test env"
      source = module.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()

      assert source =~ "/test/support/tools/",
             "#{inspect(module)} is compiled from #{source}, expected test/support/tools/"
    end

    refute Code.ensure_loaded?(Normandy.Tools.Examples.Weather),
           "Normandy.Tools.Examples.Weather is still compiled from lib/"
  end
```

The four fixtures keep their module names (ruling C1), so the test checks where each is compiled from rather than whether it exists; `Weather` leaves the build entirely.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/tools/examples_test.exs`
Expected: FAIL with `Normandy.Tools.Examples.Calculator is compiled from <repo>/lib/normandy/tools/examples/calculator.ex, expected test/support/tools/`.

- [ ] **Step 3: Move the files and fix the weather helpers**

```bash
mkdir -p test/support/tools examples/tools
git mv lib/normandy/tools/examples/calculator.ex test/support/tools/calculator.ex
git mv lib/normandy/tools/examples/enhanced_calculator.ex test/support/tools/enhanced_calculator.ex
git mv lib/normandy/tools/examples/list_processor.ex test/support/tools/list_processor.ex
git mv lib/normandy/tools/examples/string_manipulator.ex test/support/tools/string_manipulator.ex
git mv lib/normandy/tools/examples/weather.ex examples/tools/weather.ex
```

`lib/normandy/tools/examples/` is now empty, and git no longer tracks it. If the directory is still on disk, delete it with `rmdir lib/normandy/tools/examples`, which refuses to remove a directory that is not empty.

In `examples/tools/weather.ex`, replace the module line and the moduledoc (lines 1-17) with:

```elixir
defmodule MyApp.Tools.Weather do
  @moduledoc """
  An example tool that fetches current weather from the Open-Meteo API (no API key).

  Copy it into your application and rename the module. Normandy's live test
  `test/normandy_integration/basic_agent_test.exs` uses it: a model cannot know
  current weather, so it must call the tool.

      agent = Normandy.Agents.BaseAgent.register_tool(agent, %MyApp.Tools.Weather{})

  Supported cities are the keys of `@city_coords`.
  """
```

The rest of the file is unchanged.

In `test/support/integration_helper.ex`, delete `create_weather_tool/0` and its `@doc` (lines 248-259):

```elixir

  @doc """
  Creates a weather tool for testing.

  This tool fetches real weather data, ensuring models must use it
  as they cannot know current weather conditions.
  """
  def create_weather_tool do
    %Normandy.Tools.Examples.Weather{
      city: ""
    }
  end
```

Nothing calls it: `grep -rn "IntegrationHelper.create_weather_tool" test` is empty. The only caller of a weather helper is `test/normandy_integration/basic_agent_test.exs:62`, which uses `NormandyIntegrationHelper`'s.

In `test/support/normandy_integration_helper.ex`, replace lines 88-98:

```elixir
  @doc """
  Creates a weather tool for testing.

  This tool fetches real weather data, ensuring models must use it
  as they cannot know current weather conditions.
  """
  def create_weather_tool do
    %Normandy.Tools.Examples.Weather{
      city: ""
    }
  end
```

with:

```elixir
  @weather_source Path.expand("../../examples/tools/weather.ex", __DIR__)

  @doc """
  Creates the example weather tool (`examples/tools/weather.ex`).

  It fetches real weather data, so a model must call it: it cannot know current
  conditions. It lives in `examples/`, which mix does not compile, so it is
  compiled here, on first use, only by the live tests that call this.
  """
  def create_weather_tool do
    _ = unless Code.ensure_loaded?(MyApp.Tools.Weather), do: Code.compile_file(@weather_source)
    struct(MyApp.Tools.Weather, city: "")
  end
```

`_ =` is needed because Dialyzer in the test env reports `unmatched_return` without it. `struct/2` with a module atom creates no compile-time dependency, so the default build never needs the module. Its only caller, `basic_agent_test.exs`, carries `@moduletag :normandy_integration`, and `test/test_helper.exs` excludes that tag. So the weather tests stay out of the default suite, as before. They run with `mix test --only normandy_integration test/normandy_integration/basic_agent_test.exs` when an API key is set.

- [ ] **Step 4: Check the fixture module names are unchanged**

The four fixtures keep `Normandy.Tools.Examples.*` (ruling C1), so no test file is rewritten.

Run: `grep -rn "Tools\.Examples" lib`
Expected: exactly one line, `lib/normandy/agents/base_agent.ex:2015`, which Step 5 fixes.

Run: `grep -rn "Tools\.Examples\.Weather" test lib`
Expected: no output (Step 3 rewrote both helpers).

- [ ] **Step 5: The `register_tool/2` doc example**

In `lib/normandy/agents/base_agent.ex:2014-2016`, replace:

```elixir
      iex> agent = BaseAgent.init(config)
      iex> tool = %Normandy.Tools.Examples.Calculator{}
      iex> agent = BaseAgent.register_tool(agent, tool)
```

with:

```elixir
      iex> agent = BaseAgent.init(config)
      iex> agent = BaseAgent.register_tool(agent, %MyApp.Tools.Search{})
```

No test runs `doctest Normandy.Agents.BaseAgent` (`grep -rn "doctest" test` lists five other modules), so the example is not executed.

- [ ] **Step 6: examples/README.md**

After the "### 1. Customer Support Application" block, before `## Phoenix LiveView Integration`, add:

```markdown
### 2. A tool that calls an HTTP API

**Location**: `tools/weather.ex`

`MyApp.Tools.Weather` fetches current weather from Open-Meteo (no API key needed).
Copy it into your application and rename the module. It is not part of the Normandy
package.
```

- [ ] **Step 7: Run to verify it passes, then check the package**

Run: `mix format && mix test test/tools test/agents test/integration test/telemetry 2>&1 | tail -3`. Expected: ` 0 failures`.

Run: `mix compile --warnings-as-errors && MIX_ENV=test mix compile --warnings-as-errors`. Expected: no warnings. The dev build drops the five beams.

Package check. `mix hex.build --unpack` refuses to build while `claudio` is a path dependency: `** (Mix) Stopping package build due to errors. Dependencies excluded from the package (only Hex packages can be dependencies): claudio`. I verified that in a scratch copy. hex.build prints the package file list before it stops, so check that list:

```bash
mix hex.build 2>&1 | sed -n '/Files:/,/Version:/p' | grep -ciE 'examples|weather|calculator|list_processor|string_manipulator'
```

Expected: `0`. On today's tree, before this task, the same command prints `6`: the directory and the five files. Once Claudio 0.7.0 is on Hex (decision 2), the full acceptance check is:

```bash
out="$(mktemp -d)/normandy" && mix hex.build --unpack --output "$out" && find "$out" -ipath '*examples*' -o -ipath '*weather*' -o -ipath '*calculator*'
```

Expected: no output.

- [ ] **Step 8: MIGRATING**

Append a new section to `MIGRATING-2.0.md`, numbered §24 (after Task 3.3a's §23; check with `grep -n '^## [0-9]' MIGRATING-2.0.md | tail -1`), placed before `## New, non-breaking`:

```markdown
## 24. The example tools are no longer in the package

`Normandy.Tools.Examples.Calculator`, `EnhancedCalculator`, `ListProcessor`,
`StringManipulator` and `Weather` are removed from the library. They were test
fixtures, and `Weather` made live HTTP calls. If you used one, copy it from the
1.x source into your application. The weather tool is in the repository at
`examples/tools/weather.ex` (as `MyApp.Tools.Weather`).
```

- [ ] **Step 9: Full suite and commit**

Run: `mix format && mix test 2>&1 | tail -3`. Expected: ` 0 failures`.

Run: `mix credo --strict 2>&1 | grep found`. Expected: `found no issues`.

Stage the moves (`git mv` already staged the deletions) and every edited file:

```bash
git add test/support/tools/calculator.ex test/support/tools/enhanced_calculator.ex \
  test/support/tools/list_processor.ex test/support/tools/string_manipulator.ex \
  examples/tools/weather.ex examples/README.md lib/normandy/agents/base_agent.ex \
  test/support/normandy_integration_helper.ex test/support/integration_helper.ex \
  test/tools/examples_test.exs MIGRATING-2.0.md
git status --short   # expect no unstaged changes and no untracked files from this task
git commit -m "feat!(tools): move the example tools out of lib"
```

---

### Task 3.4a: `Tools.Registry` → `Tools.Toolset`; `fetch/2`, `fetch!/2`; validated registration options

**Files:**
- Move: `lib/normandy/tools/registry.ex` → `lib/normandy/tools/toolset.ex`;
  `test/tools/registry_test.exs` → `test/tools/toolset_test.exs`;
  `test/tools/registry_metadata_test.exs` → `test/tools/toolset_metadata_test.exs`
- Modify (mechanical, Step 1): every file found by the greps in Step 1 (56 files at
  `95dc149` in `lib test e2e docs/guides mix.exs`)
- Modify: `lib/normandy/tools/toolset.ex` (struct, `new/1`, `register/3`, `fetch/2`, `fetch!/2`,
  `fetch_metadata/2`, `introspect_schema/2`), `lib/normandy/exceptions.ex` (new
  `Normandy.ToolNotFoundError`), `lib/normandy/agents/base_agent.ex` (`register_tool/3`),
  `lib/normandy/behaviours/agent_template.ex` (moduledoc), `docs/guides/distributed_sessions.md:110`,
  `lib/normandy/agents/base_agent/init_options.ex` (Task 3.1b's `tool_registry` option and
  `:tools` hint, via Step 1 rule (b)), `mix.exs` (Errors docs group), `MIGRATING-2.0.md`
  (§21's `tool_registry` mentions; new section)
- Test: `test/tools/toolset_test.exs`, `test/agents/base_agent_tools_test.exs`

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3` (Task 3.1).
- Produces: `Normandy.Tools.Toolset` with `new/0`, `new/1` (`[tool | {tool, keyword()}]`),
  `register/3` (options validated; `:replace` only in this task), `fetch/2`, `fetch!/2`
  (raises `Normandy.ToolNotFoundError`), `fetch_metadata/2`, and every other 1.x `Registry`
  function under its old name. `BaseAgentConfig.toolset` (was `tool_registry`), `init/1`'s
  `:toolset` key, the DSL `new/1` override `:toolset`, the supplement key `:toolset`.
  `BaseAgent.register_tool/3` (opts forwarded to `Toolset.register/3`). `BaseAgent.get_tool/2`
  keeps its name (Task 3.6 renames it).

- [ ] **Step 1: Mechanical rename (no behaviour change)**

```bash
git mv lib/normandy/tools/registry.ex lib/normandy/tools/toolset.ex
git mv test/tools/registry_test.exs test/tools/toolset_test.exs
git mv test/tools/registry_metadata_test.exs test/tools/toolset_metadata_test.exs

# a) In files that alias Normandy.Tools.Registry, a bare `Registry` is the tool registry
#    (28 files, 233 matching lines at 95dc149). `(?<![\w.])` leaves A2ARegistry, MCPRegistry,
#    Normandy.MCP.Registry and Normandy.A2A.Registry alone.
grep -rlE "alias Normandy\.Tools\.Registry\b|alias Normandy\.Tools\.\{[^}]*\bRegistry\b" lib test e2e docs/guides \
  | xargs perl -pi -e 's/(?<![\w.])Registry\b/Toolset/g'

# b) The fully qualified name and the field/key name, everywhere (56 files; 101 and 117
#    occurrences at 95dc149).
grep -rlE "Normandy\.Tools\.Registry\b|\btool_registry\b" lib test e2e docs/guides mix.exs \
  | xargs perl -pi -e 's/Normandy\.Tools\.Registry\b/Normandy.Tools.Toolset/g; s/\btool_registry\b/toolset/g'

# c) Test module names in the moved files.
perl -pi -e 's/\bNormandyTest\.Tools\.RegistryTest\b/NormandyTest.Tools.ToolsetTest/; s/\bNormandyTest\.Tools\.RegistryMetadataTest\b/NormandyTest.Tools.ToolsetMetadataTest/' \
  test/tools/toolset_test.exs test/tools/toolset_metadata_test.exs
```

`xargs` (not `$(...)`) so the commands also word-split under zsh. Rule (b) also renames
`:tool_registry` in `BaseAgent.init/1`'s option schema and in the `:tools` hint Task 3.1 wrote
(the DSL's `new/1` schema derives from it; Task 3.1c deleted `@override_keys`), in `AgentTemplate.supplement`
(agent_template.ex:18) and in `ConfigTemplate.rebuild/3` (`toolset: supplement.toolset`).

Check what rule (b) did to `lib/normandy/agents/base_agent/init_options.ex` (Task 3.1b's
schema; DSL `new/1` derives its schema from it, so it follows): the `tool_registry:` entry is
now

```elixir
    toolset: [
      type: {:or, [{:struct, Normandy.Tools.Toolset}, nil]},
      default: nil,
      type_doc: "a `Normandy.Tools.Toolset` or `nil`",
      doc: "The agent's tools."
    ],
```

and the `:tools` entry of `@hints` reads `"tools go in :toolset (Normandy.Tools.Toolset.new([tool, ...])) or are added " <> "after init with BaseAgent.register_tool/2"`. The 3.1b test
`":tools points at the tool registry"` in `test/agents/base_agent_init_options_test.exs` was
rewritten by the same rule to expect `":toolset (Normandy.Tools.Toolset.new([tool, ...]))"`;
it must pass unchanged after Step 1. If either file still names `tool_registry` or
`Tools.Registry`, apply the edit above by hand.

Then fix by hand the prose the rules cannot see:
- `MIGRATING-2.0.md` §21 (written by Task 3.1b; not in rule (b)'s paths): "`tools:` (use
  `tool_registry:` or `register_tool/2`)" → "`tools:` (use `toolset:` or `register_tool/3`)",
  and "`:prompt_specification`, `:tool_registry` and" → "`:prompt_specification`, `:toolset` and".
  Afterwards `grep -n "tool_registry" MIGRATING-2.0.md` prints nothing (Step 6 adds the 1.x
  name back only in its table).
- `lib/normandy/tools/toolset.ex` moduledoc (replaced in Step 4).
- `lib/normandy/behaviours/agent_template.ex:4`: "the tool registry" → "the toolset".
- `docs/guides/distributed_sessions.md:110`: "prompt spec, tool-registry name, `resume_policy`"
  → "prompt spec, `resume_policy`" (the template never held a registry name; the toolset comes
  from the supplement).

Credo: `Registry` was exempt from Credo's `AliasUsage` check (aliasing it would shadow
Elixir's `Registry`); `Toolset` is not, so every fully qualified `Normandy.Tools.Toolset.f(...)`
or `%Normandy.Tools.Toolset{...}` in code becomes a "Nested modules could be aliased" finding.
At `95dc149` that is these 12 files (verified by running the rename and `mix credo --strict`):

```
test/a2a/agent_tool_test.exs
test/a2a/server_test.exs
test/agents/base_agent_tools_test.exs
test/agents/turn/resume_reaper_integration_test.exs
test/agents/turn/server_errors_test.exs
test/agents/turn/server_integration_test.exs
test/agents/turn/server_test.exs
test/agents/turn/session_test.exs
test/coordination/agent_process_server_test.exs
test/mcp/tool_wrapper_test.exs
test/support/e2e/distributed.ex
test/support/turn_config.ex
```

In each, shorten the code references (the lookahead leaves strings such as
`"Normandy.Tools.Toolset.register/3: "` alone):

```bash
perl -pi -e 's/(?<![\w."])Normandy\.Tools\.Toolset(?=\.[a-z_]+[!?]?\(|\{)/Toolset/g' <file>
```

and add `alias Normandy.Tools.Toolset` to the module's top-level alias block in alphabetical
order (after `alias Normandy.Tools.Examples...` / `alias Normandy.Test...`, before
`alias Normandy.TurnError`), or add `Toolset` to an existing `alias Normandy.Tools.{...}`.

Run:

```bash
mix compile --warnings-as-errors 2>&1 | tail -5
grep -rnE "Tools\.Registry\b|\btool_registry\b" lib test e2e docs/guides mix.exs CLAUDE.md
mix credo --strict 2>&1 | tail -3
mix test 2>&1 | tail -5
```

Expected: compiles; the grep prints nothing; Credo "found no issues"; ` 0 failures` (a pure
rename).

- [ ] **Step 2: Write the failing tests**

In `test/tools/toolset_test.exs`, replace the `describe "Toolset.get/2"` and
`describe "Toolset.get!/2"` blocks (they were `Registry.get/2` / `get!/2`, lines 84-113 before
the move) with:

```elixir
  describe "Toolset.fetch/2" do
    test "returns the registered tool" do
      tool = %Calculator{}
      toolset = Toolset.new([tool])

      assert {:ok, ^tool} = Toolset.fetch(toolset, "calculator")
    end

    test "returns :error for a name that is not registered" do
      assert :error = Toolset.fetch(Toolset.new(), "nonexistent")
    end
  end

  describe "Toolset.fetch!/2" do
    test "returns the registered tool" do
      tool = %Calculator{}
      assert ^tool = Toolset.fetch!(Toolset.new([tool]), "calculator")
    end

    test "raises ToolNotFoundError naming the tool and the registered names" do
      toolset = Toolset.new([%StringManipulator{}, %Calculator{}])

      error =
        assert_raise Normandy.ToolNotFoundError, fn -> Toolset.fetch!(toolset, "nope") end

      assert error.name == "nope"
      assert error.registered == ["calculator", "string_manipulator"]

      assert Exception.message(error) ==
               ~s(no tool named "nope" in the toolset; registered: "calculator", "string_manipulator")
    end

    test "says so when the toolset is empty" do
      error =
        assert_raise Normandy.ToolNotFoundError, fn -> Toolset.fetch!(Toolset.new(), "nope") end

      assert Exception.message(error) == ~s(no tool named "nope" in the toolset; it has no tools)
    end
  end

  describe "registration options" do
    test "new/1 takes {tool, opts} entries beside bare tools" do
      toolset = Toolset.new([{%Calculator{}, []}, %StringManipulator{}])

      assert Enum.sort(Toolset.list_names(toolset)) == ["calculator", "string_manipulator"]
    end

    test "new/1 passes an entry's options to register/3" do
      toolset = Toolset.new([%Calculator{}, {%Calculator{}, replace: true}])
      assert Toolset.count(toolset) == 1
    end

    test "an unknown option raises, naming the function and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Toolset.register(Toolset.new(), %Calculator{}, replase: true)
        end

      assert String.starts_with?(error.message, "Normandy.Tools.Toolset.register/3: ")
      assert error.message =~ ":replase"
    end

    test "a wrongly typed option raises, naming the key" do
      error =
        assert_raise ArgumentError, fn ->
          Toolset.register(Toolset.new(), %Calculator{}, replace: "yes")
        end

      assert String.starts_with?(error.message, "Normandy.Tools.Toolset.register/3: ")
      assert error.message =~ ":replace"
    end
  end
```

In `test/tools/toolset_metadata_test.exs`, Step 4's sed turns `Toolset.get_metadata(` into
`Toolset.fetch_metadata(`; no new test is needed there (6 call sites at `95dc149`).

In `test/agents/base_agent_tools_test.exs` (its `setup` builds `agent` with
`NormandyTest.Support.ModelMockup`; it aliases `BaseAgent`, `Calculator` and
`StringManipulator`; Step 1 gave it `alias Normandy.Tools.Toolset` after the `Examples` alias),
add:

```elixir
  describe "register_tool/3" do
    test "forwards options to Toolset.register/3", %{agent: agent} do
      agent =
        agent
        |> BaseAgent.register_tool(%Calculator{})
        |> BaseAgent.register_tool(%Calculator{}, replace: true)

      assert Toolset.count(agent.toolset) == 1
    end

    test "an unknown option raises from Toolset.register/3", %{agent: agent} do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.register_tool(agent, %Calculator{}, timout: 5)
        end

      assert String.starts_with?(error.message, "Normandy.Tools.Toolset.register/3: ")
      assert error.message =~ ":timout"
    end
  end
```

- [ ] **Step 3: Run to verify they fail**

Run: `mix test test/tools/toolset_test.exs test/agents/base_agent_tools_test.exs`
Expected: FAIL — `UndefinedFunctionError` for `Toolset.fetch/2`, `fetch!/2`,
`BaseAgent.register_tool/3`; `Normandy.ToolNotFoundError` is undefined; `replase: true` is
accepted.

- [ ] **Step 4: Implement**

4a. `lib/normandy/exceptions.ex`, append:

```elixir
defmodule Normandy.ToolNotFoundError do
  @moduledoc """
  Raised by `Normandy.Tools.Toolset.fetch!/2` when no tool is registered under a name.

  `:name` is the name asked for; `:registered` lists the names the toolset holds, sorted.
  """
  defexception [:name, registered: []]

  @impl true
  def message(%__MODULE__{name: name, registered: []}),
    do: "no tool named #{inspect(name)} in the toolset; it has no tools"

  def message(%__MODULE__{name: name, registered: registered}),
    do:
      "no tool named #{inspect(name)} in the toolset; registered: " <>
        Enum.map_join(registered, ", ", &inspect/1)
end
```

4b. `lib/normandy/tools/toolset.ex`. Replace everything from `defmodule` down to the end of
`register/3` (old lines 1-81) with:

```elixir
defmodule Normandy.Tools.Toolset do
  @moduledoc """
  The tools an agent can call, by name.

  Each tool is a struct holding the tool's own configuration. `register/3` indexes it by its
  name and takes options that belong to the registration (see `register/3`).
  `to_tool_schemas/1` produces the tool definitions sent to the model.
  """

  alias Normandy.Tools.BaseTool

  @type t :: %__MODULE__{tools: %{String.t() => struct()}}

  defstruct tools: %{}

  @register_schema NimbleOptions.new!(
                     replace: [
                       type: :boolean,
                       default: false,
                       doc:
                         "Replace a tool already registered under the same name instead of raising."
                     ]
                   )

  @doc "An empty toolset."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  A toolset holding `tools`, registered in order. An entry is a tool, or `{tool, opts}` to
  pass `opts` to `register/3`.

      Normandy.Tools.Toolset.new([%Search{}, {%Search{index: "b"}, replace: true}])
  """
  @spec new([struct() | {struct(), keyword()}]) :: t()
  def new(tools) when is_list(tools) do
    Enum.reduce(tools, new(), fn
      {tool, opts}, acc when is_list(opts) -> register(acc, tool, opts)
      tool, acc -> register(acc, tool, [])
    end)
  end

  @doc """
  Registers `tool` under its name.

  The name must be 1 to 64 letters, digits, underscores or dashes (what the API accepts);
  anything else raises `ArgumentError` here rather than as a 400 on the first request.
  Registering a second tool with the same name raises `ArgumentError` unless `replace: true`.
  An unknown or mistyped option raises `ArgumentError` naming it.

  ## Options

  #{Normandy.Options.docs(@register_schema)}
  """
  @spec register(t(), struct(), keyword()) :: t()
  def register(%__MODULE__{tools: tools} = toolset, tool, opts \\ []) do
    opts = Normandy.Options.validate!(opts, @register_schema, {__MODULE__, :register, 3})
    tool_name = BaseTool.tool_name(tool)

    unless valid_name?(tool_name) do
      raise ArgumentError,
            "Normandy.Tools.Toolset.register/3: #{inspect(tool_name)} is not a valid tool name; " <>
              "the API accepts 1 to 64 letters, digits, underscores and dashes"
    end

    if Map.has_key?(tools, tool_name) and not Keyword.fetch!(opts, :replace) do
      raise ArgumentError,
            "Normandy.Tools.Toolset.register/3: a tool named #{inspect(tool_name)} is already " <>
              "registered; pass replace: true to replace it"
    end

    %{toolset | tools: Map.put(tools, tool_name, tool)}
  end
```

Replace the old `get/2` and `get!/2` (old lines 83-119) with:

```elixir
  @doc "The tool registered as `tool_name`: `{:ok, tool}`, or `:error`."
  @spec fetch(t(), String.t()) :: {:ok, struct()} | :error
  def fetch(%__MODULE__{tools: tools}, tool_name), do: Map.fetch(tools, tool_name)

  @doc """
  The tool registered as `tool_name`. Raises `Normandy.ToolNotFoundError` (naming the
  registered tools) when there is none.
  """
  @spec fetch!(t(), String.t()) :: struct()
  def fetch!(%__MODULE__{tools: tools} = toolset, tool_name) do
    case fetch(toolset, tool_name) do
      {:ok, tool} ->
        tool

      :error ->
        raise Normandy.ToolNotFoundError,
          name: tool_name,
          registered: tools |> Map.keys() |> Enum.sort()
    end
  end
```

Rename `get_metadata/2` to `fetch_metadata/2` (its `@doc` example and `@spec` too), and in
`fetch_metadata/2` and `introspect_schema/2` change the internal `case get(registry, tool_name)`
to `case fetch(toolset, tool_name)` (rename the `registry` parameter to `toolset` in every
function of the module while there; Step 1's rule (a) did not touch this file's unaliased
variable names). Update the remaining `@doc` examples from `Normandy.Tools.Registry` (already
done by Step 1) and `%Normandy.Tools.Registry{...}` outputs to `%Normandy.Tools.Toolset{...}`.

4c. Rename the callers (26 call sites at `95dc149`: lib `executor.ex`, `dispatch.ex`,
`turn/server.ex`, `base_agent.ex`; tests):

```bash
grep -rlE "Toolset\.get(!|_metadata)?\(" lib test e2e docs/guides \
  | xargs perl -pi -e 's/\bToolset\.get!\(/Toolset.fetch!(/g; s/\bToolset\.get_metadata\(/Toolset.fetch_metadata(/g; s/\bToolset\.get\(/Toolset.fetch(/g'
grep -rnE "Toolset\.get(!|_metadata)?\(" lib test e2e docs/guides   # expect no output
```

4d. `lib/normandy/agents/base_agent.ex`: replace the two `register_tool/2` clauses (old
lines 2020-2028, now matching on `toolset:`) and their `@doc`/`@spec` with:

```elixir
  @doc """
  Registers `tool` in the agent's toolset, creating the toolset on first use. `opts` are
  `Normandy.Tools.Toolset.register/3`'s options.
  """
  @spec register_tool(BaseAgentConfig.t(), struct(), keyword()) :: BaseAgentConfig.t()
  def register_tool(config, tool, opts \\ [])

  def register_tool(%BaseAgentConfig{toolset: nil} = config, tool, opts),
    do: register_tool(%{config | toolset: Toolset.new()}, tool, opts)

  def register_tool(%BaseAgentConfig{toolset: %Toolset{} = toolset} = config, tool, opts),
    do: %{config | toolset: Toolset.register(toolset, tool, opts)}
```

4e. `mix.exs`, `Errors:` docs group: add `Normandy.ToolNotFoundError` after
`Normandy.TurnError`. (Step 1 already turned `Normandy.Tools.Registry` into
`Normandy.Tools.Toolset` in the `Tools:` group.)

- [ ] **Step 5: Run to verify they pass**

Run: `mix test test/tools/toolset_test.exs test/tools/toolset_metadata_test.exs test/agents/base_agent_tools_test.exs`
Expected: PASS.

The old `"raises for nonexistent tool"` test (it asserted `RuntimeError, "Tool 'nonexistent'
not found in registry"`) is gone with the `get!/2` describe block it lived in; nothing else
asserted that message (`grep -rn "not found in registry" test` shows only `Executor`'s and
`Dispatch`'s own messages, which are unchanged).

- [ ] **Step 6: MIGRATING**

Add a new section §25 after the last numbered one (Tasks 3.1–3.3 add §21–§24; check with
`grep -n '^## [0-9]' MIGRATING-2.0.md`), titled exactly as below. Tasks 3.4c
and 3.4d extend it, and Task 3.4d's error messages name it as `MIGRATING-2.0.md §25`.

```markdown
## 25. Tools: one `Normandy.Tool` behaviour

### The toolset

| 1.x | 2.0 |
|---|---|
| `Normandy.Tools.Registry` | `Normandy.Tools.Toolset` (same functions unless listed here) |
| `Registry.get(registry, name)` | `Toolset.fetch(toolset, name)` → `{:ok, tool}` / `:error` |
| `Registry.get!(registry, name)` (raised `RuntimeError`) | `Toolset.fetch!(toolset, name)` (raises `Normandy.ToolNotFoundError`, which names the registered tools) |
| `Registry.get_metadata(registry, name)` | `Toolset.fetch_metadata(toolset, name)` |
| `BaseAgentConfig.tool_registry`, `init(%{tool_registry: ...})`, DSL `new(override: [tool_registry: ...])` | `toolset` |
| `AgentTemplate` supplement key `:tool_registry` | `:toolset` |
| `BaseAgent.register_tool(agent, tool)` | unchanged; `register_tool(agent, tool, opts)` passes `opts` to `Toolset.register/3` |

- `Toolset.register/3` raises `ArgumentError` on an unknown or mistyped option (1.x ignored
  them).
```

- [ ] **Step 7: Format, full suite, commit**

Run: `mix format && mix credo --strict 2>&1 | tail -3 && mix test 2>&1 | tail -5`
Expected: Credo "found no issues"; ` 0 failures`.

```bash
git add lib/normandy/tools/toolset.ex lib/normandy/exceptions.ex mix.exs MIGRATING-2.0.md \
  docs/guides/distributed_sessions.md lib/normandy/behaviours/agent_template.ex \
  test/tools/toolset_test.exs test/tools/toolset_metadata_test.exs test/agents/base_agent_tools_test.exs
git status --short   # every other modified file is a Step 1 / 4c rename: add each one by name
```

Add each remaining modified path from `git status --short` individually (`git add <path>`; the
moves are already staged by `git mv`). Do not use `git add .` or `-A`.

```bash
git commit -m "refactor(tools)!: Tools.Registry is Tools.Toolset; fetch/fetch!; validated registration options

The tool_registry field, init/1 key, DSL override and supplement key are toolset.
Toolset.fetch!/2 raises Normandy.ToolNotFoundError. BaseAgent.register_tool/3
forwards options to Toolset.register/3, which rejects unknown ones."
```

---
### Task 3.4b: The `Normandy.Tool` behaviour, `use Normandy.Tool`, `Context.input`, the input validator

**Files:**
- Create: `lib/normandy/tool.ex`, `lib/normandy/tools/input.ex`
- Modify: `lib/normandy/tools/context.ex:1-25` (field `:input`, moduledoc, type)
- Test: `test/tools/tool_test.exs`, `test/tools/input_test.exs` (new)

**Interfaces:**
- Consumes: `Normandy.Tools.Toolset.valid_name?/1` (Task 3.4a), `Normandy.Schema.Validator.validate/2`,
  `Normandy.Components.ContentBlock.Describe.type_of/1`.
- Produces (header, decision 17a): `@callback name/1`, `description/1`, `input_schema/1`,
  `run/2`; `use Normandy.Tool, name:, description:, input:`. Additions: `Normandy.Tool.name/1`,
  `description/1`, `input_schema/1`, `run/2` (dispatch on the struct's module),
  `Normandy.Tool.implemented_by?/1`, generated `__tool_input__/0` (only with `:input`),
  `Normandy.Tools.Input.validate/2`, `Normandy.Tools.Input.message/1`, `Context.input`.
  Nothing calls these yet; Task 3.4c switches the dispatcher over. The old protocols still
  exist and still drive every tool after this task.

- [ ] **Step 1: Write the failing tests**

`test/tools/tool_test.exs`:

```elixir
defmodule Normandy.ToolTest do
  use ExUnit.Case, async: true

  alias Normandy.Tool
  alias Normandy.Tools.Context

  defmodule Search do
    @moduledoc false
    defmodule Input do
      @moduledoc false
      use Normandy.Schema

      io_schema "Search input" do
        field(:query, :string, required: true, description: "What to look for")
        field(:limit, :integer, default: 5, minimum: 1)
      end
    end

    use Normandy.Tool, name: "search", description: "Searches the catalogue", input: Input

    defstruct index: "main"

    @impl Normandy.Tool
    def run(%__MODULE__{index: index}, %Context{input: %Input{query: query, limit: limit}}),
      do: {:ok, "#{index}:#{query}:#{limit}"}
  end

  defmodule HandWritten do
    @moduledoc false
    use Normandy.Tool

    defstruct prefix: "hw"

    @impl Normandy.Tool
    def name(%__MODULE__{prefix: prefix}), do: "#{prefix}_tool"

    @impl Normandy.Tool
    def description(_tool), do: "hand-written"

    @impl Normandy.Tool
    def input_schema(_tool),
      do: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}

    @impl Normandy.Tool
    def run(_tool, %Context{input: input}), do: {:ok, input}
  end

  describe "use Normandy.Tool" do
    test "generates name/1, description/1 and input_schema/1 from its options" do
      assert Search.name(%Search{}) == "search"
      assert Search.description(%Search{}) == "Searches the catalogue"
      assert Search.input_schema(%Search{}) == Search.Input.__schema__(:specification)
      assert Search.__tool_input__() == Search.Input
    end

    test "without options the module writes the callbacks; no input module is declared" do
      assert HandWritten.name(%HandWritten{prefix: "x"}) == "x_tool"
      refute function_exported?(HandWritten, :__tool_input__, 0)
    end

    test "declares the behaviour" do
      assert Tool.implemented_by?(Search)
      assert Tool.implemented_by?(HandWritten)
      refute Tool.implemented_by?(Normandy.Tools.Context)
      refute Tool.implemented_by?(:not_a_module)
    end
  end

  describe "the dispatching functions" do
    test "call the tool module's callbacks" do
      tool = %Search{index: "books"}

      assert Tool.name(tool) == "search"
      assert Tool.description(tool) == "Searches the catalogue"
      assert Tool.input_schema(tool) == Search.Input.__schema__(:specification)

      context = %Context{tool_call_id: "c1", input: %Search.Input{query: "dune", limit: 2}}
      assert Tool.run(tool, context) == {:ok, "books:dune:2"}
    end
  end

  describe "options are checked when the tool compiles" do
    test "an unknown option names the module and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Code.compile_string("""
          defmodule Normandy.ToolTest.UnknownOption do
            use Normandy.Tool, nam: "x"
          end
          """)
        end

      assert error.message ==
               "use Normandy.Tool in Normandy.ToolTest.UnknownOption: unknown option :nam; " <>
                 "supported: :name, :description, :input"
    end

    test "a name the API would reject" do
      error =
        assert_raise ArgumentError, fn ->
          Code.compile_string("""
          defmodule Normandy.ToolTest.BadName do
            use Normandy.Tool, name: "has space"
          end
          """)
        end

      assert error.message ==
               "use Normandy.Tool in Normandy.ToolTest.BadName: :name must be 1 to 64 letters, " <>
                 ~s(digits, underscores or dashes, got: "has space")
    end

    test "an input module that is not a Normandy.Schema" do
      error =
        assert_raise ArgumentError, fn ->
          Code.compile_string("""
          defmodule Normandy.ToolTest.BadInput do
            use Normandy.Tool, input: Normandy.Tools.Context
          end
          """)
        end

      assert error.message ==
               "use Normandy.Tool in Normandy.ToolTest.BadInput: :input must be a module that " <>
                 "uses Normandy.Schema, got: Normandy.Tools.Context"
    end
  end

  test "a context has no input until the dispatcher sets one" do
    assert %Context{tool_call_id: "c"}.input == nil
  end
end
```

`test/tools/input_test.exs`:

```elixir
defmodule Normandy.Tools.InputTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.{Context, Input}

  # The SEC-1 shape: configuration on the struct, the model's input in a separate schema.
  defmodule EndpointTool do
    @moduledoc false
    defmodule Params do
      @moduledoc false
      use Normandy.Schema

      io_schema "Lookup input" do
        field(:query, :string, required: true, description: "the query")
        field(:limit, :integer, default: 5)
      end
    end

    use Normandy.Tool, name: "lookup", description: "looks a query up", input: Params

    defstruct [:endpoint, timeout: 5_000]

    @impl Normandy.Tool
    def run(_tool, %Context{input: input}), do: {:ok, input}
  end

  defmodule MapTool do
    @moduledoc false
    use Normandy.Tool, name: "map_tool", description: "hand-written schema"

    defstruct additional: false

    # Atom and string keys mixed on purpose: built-in tools use both.
    @impl Normandy.Tool
    def input_schema(%__MODULE__{additional: additional}) do
      %{
        :type => "object",
        "properties" => %{"n" => %{"type" => "integer"}, name: %{type: "string"}},
        :required => ["n"],
        "additionalProperties" => additional
      }
    end

    @impl Normandy.Tool
    def run(_tool, %Context{input: input}), do: {:ok, input}
  end

  # Any hand-written schema, as given (an MCP server's, for instance).
  defmodule SchemaTool do
    @moduledoc false
    use Normandy.Tool, name: "schema_tool", description: "the schema it is given"

    defstruct schema: %{"type" => "object"}

    @impl Normandy.Tool
    def input_schema(%__MODULE__{schema: schema}), do: schema

    @impl Normandy.Tool
    def run(_tool, %Context{input: input}), do: {:ok, input}
  end

  alias EndpointTool.Params

  describe "a tool that declared input: Schema" do
    test "string keys become the schema's struct, with defaults" do
      assert {:ok, %Params{query: "x", limit: 5}} =
               Input.validate(%EndpointTool{}, %{"query" => "x"})
    end

    test "atom keys are accepted" do
      assert {:ok, %Params{query: "x", limit: 2}} =
               Input.validate(%EndpointTool{}, %{query: "x", limit: 2})
    end

    test "keys that name the tool's config fields are unknown keys, named in the error" do
      input = %{"query" => "x", "endpoint" => "evil", "timeout" => "x"}

      assert {:error, [error]} = Input.validate(%EndpointTool{}, input)

      assert error == %{
               path: [],
               constraint: :unknown_keys,
               message: ~s(unknown keys "endpoint", "timeout"; expected only "query", "limit")
             }

      assert Input.message([error]) ==
               ~s(unknown keys "endpoint", "timeout"; expected only "query", "limit")
    end

    test "one unknown key is named in the singular" do
      assert {:error, [%{message: ~s(unknown key "x"; expected only "query", "limit")}]} =
               Input.validate(%EndpointTool{}, %{"query" => "q", "x" => 1})
    end

    test "a missing required field and a wrong type, without coercion" do
      assert {:error, errors} = Input.validate(%EndpointTool{}, %{"limit" => "5"})

      assert errors == [
               %{path: [:limit], message: "expected type integer, got string", constraint: :type},
               %{path: [:query], message: "is required", constraint: :required}
             ]

      assert Input.message(errors) == "limit expected type integer, got string; query is required"
    end

    test "a key given both as a string and as an atom is an error, not a silent pick" do
      assert {:error, [%{path: ["query"], constraint: :duplicate_key}]} =
               Input.validate(%EndpointTool{}, %{"query" => "a", query: "b"})
    end

    test "an unknown key is never turned into an atom" do
      canary = "input_canary_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(canary) end

      assert {:error, _} = Input.validate(%EndpointTool{}, %{"query" => "q", canary => 1})

      assert_raise ArgumentError, fn -> String.to_existing_atom(canary) end
    end
  end

  describe "a tool with a hand-written input_schema/1 map" do
    test "valid input comes back as a string-keyed map" do
      assert {:ok, %{"n" => 1, "name" => "a"}} =
               Input.validate(%MapTool{}, %{"n" => 1, name: "a"})
    end

    test "unknown keys, missing required keys and basic types" do
      assert {:error, errors} = Input.validate(%MapTool{}, %{"name" => 3, "extra" => true})

      assert errors == [
               %{
                 path: [],
                 message: ~s(unknown key "extra"; expected only "n", "name"),
                 constraint: :unknown_keys
               },
               %{path: ["n"], message: "is required", constraint: :required},
               %{path: ["name"], message: "expected type string, got integer", constraint: :type}
             ]
    end

    test "additionalProperties true lets other keys through" do
      assert {:ok, %{"n" => 1, "extra" => true}} =
               Input.validate(%MapTool{additional: true}, %{"n" => 1, "extra" => true})
    end

    # Decision 18: an MCP server may publish a loose schema with no `properties`.
    test "a schema with no properties key accepts any keys" do
      assert {:ok, %{"anything" => 1}} = Input.validate(%SchemaTool{}, %{"anything" => 1})
    end

    test "a schema with no properties key still checks its required keys" do
      tool = %SchemaTool{schema: %{"type" => "object", "required" => ["q"]}}

      assert {:error, [%{path: ["q"], message: "is required", constraint: :required}]} =
               Input.validate(tool, %{"anything" => 1})
    end

    test "properties without additionalProperties reject an unknown key, naming it" do
      tool = %SchemaTool{schema: %{"type" => "object", "properties" => %{"q" => %{}}}}

      assert {:error, [error]} = Input.validate(tool, %{"q" => "x", "extra" => 1})

      assert error == %{
               path: [],
               message: ~s(unknown key "extra"; expected only "q"),
               constraint: :unknown_keys
             }
    end

    test "a schema with no properties key still wants an object" do
      assert {:error, [%{path: [], constraint: :type}]} = Input.validate(%SchemaTool{}, [1])
    end
  end

  test "input that is not an object is a type error" do
    assert {:error,
            [%{path: [], constraint: :type, message: "expected a JSON object, got: a list"}]} =
             Input.validate(%EndpointTool{}, [1, 2])
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/tools/tool_test.exs test/tools/input_test.exs`
Expected: FAIL to compile — `Normandy.Tool` and `Normandy.Tools.Input` do not exist.

- [ ] **Step 3: Implement**

`lib/normandy/tool.ex`:

```elixir
defmodule Normandy.Tool do
  @moduledoc """
  The contract every tool implements.

  A tool is a struct whose module implements this behaviour. The struct holds the tool's
  configuration (an endpoint, a store, an index name), set by the application when it
  registers the tool (`Normandy.Tools.Toolset.register/3`). The model's input never goes into
  it: the dispatcher validates the input against `c:input_schema/1`
  (`Normandy.Tools.Input.validate/2`) and passes it to `c:run/2` as `context.input`.

  ## Callbacks

    * `c:name/1`: the name the model calls the tool by, 1 to 64 letters, digits, `_` or `-`.
    * `c:description/1`: what the tool does, for the model.
    * `c:input_schema/1`: the JSON Schema object of the input.
    * `c:run/2`: runs the tool. `context.input` is the validated input. Returns
      `{:ok, result}` or `{:error, reason}`; either reaches the model as the tool result.

  ## `use Normandy.Tool`

      defmodule MyApp.Search do
        defmodule Input do
          use Normandy.Schema

          io_schema "Search input" do
            field(:query, :string, required: true, description: "What to look for")
            field(:limit, :integer, default: 5, minimum: 1, maximum: 20)
          end
        end

        use Normandy.Tool, name: "search", description: "Searches the catalogue", input: Input

        defstruct [:index]

        @impl Normandy.Tool
        def run(%__MODULE__{index: index}, %Normandy.Tools.Context{input: %Input{} = input}),
          do: MyApp.Catalogue.search(index, input.query, input.limit)
      end

  `use Normandy.Tool` declares the behaviour, and each option generates one callback:
  `:name` → `c:name/1`, `:description` → `c:description/1`, `:input` (a module that uses
  `Normandy.Schema`, defined before the `use`) → `c:input_schema/1`. With `:input`,
  `context.input` is a struct of that schema. Leave an option out and write its callback
  when the value depends on the struct, or to hand-write the JSON Schema map; without
  `:input`, `context.input` is a string-keyed map checked against that map. Do not pass an
  option and also define its callback.

  `name/1`, `description/1`, `input_schema/1` and `run/2` on this module call the tool's own
  callbacks.
  """

  alias Normandy.Tools.Context
  alias Normandy.Tools.Toolset

  @callback name(tool :: struct()) :: String.t()
  @callback description(tool :: struct()) :: String.t()
  @callback input_schema(tool :: struct()) :: map()
  @callback run(tool :: struct(), Context.t()) :: {:ok, term()} | {:error, term()}

  @use_options [:name, :description, :input]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Normandy.Tool

      {normandy_tool_name, normandy_tool_description, normandy_tool_input} =
        Normandy.Tool.__use_options__!(__MODULE__, opts)

      @normandy_tool_name normandy_tool_name
      @normandy_tool_description normandy_tool_description
      @normandy_tool_input normandy_tool_input

      if normandy_tool_name do
        @impl Normandy.Tool
        def name(_tool), do: @normandy_tool_name
      end

      if normandy_tool_description do
        @impl Normandy.Tool
        def description(_tool), do: @normandy_tool_description
      end

      if normandy_tool_input do
        @impl Normandy.Tool
        def input_schema(_tool), do: @normandy_tool_input.__schema__(:specification)

        @doc false
        def __tool_input__, do: @normandy_tool_input
      end
    end
  end

  @doc false
  @spec __use_options__!(module(), term()) ::
          {String.t() | nil, String.t() | nil, module() | nil}
  def __use_options__!(module, opts) do
    check_option_keys!(module, opts)

    name = Keyword.get(opts, :name)
    description = Keyword.get(opts, :description)
    input = Keyword.get(opts, :input)

    check!(
      module,
      is_nil(name) or Toolset.valid_name?(name),
      ":name must be 1 to 64 letters, digits, underscores or dashes, got: #{inspect(name)}"
    )

    check!(
      module,
      is_nil(description) or is_binary(description),
      ":description must be a string, got: #{inspect(description)}"
    )

    check!(
      module,
      is_nil(input) or schema_module?(input),
      ":input must be a module that uses Normandy.Schema, got: #{inspect(input)}"
    )

    {name, description, input}
  end

  defp check_option_keys!(module, opts) do
    unless Keyword.keyword?(opts),
      do: fail!(module, "expected a keyword list of options, got: #{inspect(opts)}")

    # The house style of Normandy.Options (Task 3.1a): one key bare, several as a list.
    case Keyword.keys(opts) -- @use_options do
      [] ->
        :ok

      [key] ->
        fail!(module, "unknown option #{inspect(key)}; supported: :name, :description, :input")

      unknown ->
        fail!(
          module,
          "unknown options #{inspect(unknown)}; supported: :name, :description, :input"
        )
    end
  end

  defp check!(_module, true, _message), do: :ok
  defp check!(module, false, message), do: fail!(module, message)

  @spec fail!(module(), String.t()) :: no_return()
  defp fail!(module, message),
    do: raise(ArgumentError, "use Normandy.Tool in #{inspect(module)}: " <> message)

  # Waits for a module compiled in the same project (Code.ensure_compiled/1 cooperates with
  # the parallel compiler), so the input schema may live in its own file.
  defp schema_module?(input) when is_atom(input) do
    match?({:module, ^input}, Code.ensure_compiled(input)) and
      function_exported?(input, :__schema__, 1)
  end

  defp schema_module?(_input), do: false

  @doc "The tool's name, from its module's `c:name/1`."
  @spec name(struct()) :: String.t()
  def name(%module{} = tool), do: module.name(tool)

  @doc "The tool's description, from its module's `c:description/1`."
  @spec description(struct()) :: String.t()
  def description(%module{} = tool), do: module.description(tool)

  @doc "The tool's input JSON Schema, from its module's `c:input_schema/1`."
  @spec input_schema(struct()) :: map()
  def input_schema(%module{} = tool), do: module.input_schema(tool)

  @doc "Runs the tool through its module's `c:run/2`."
  @spec run(struct(), Context.t()) :: {:ok, term()} | {:error, term()}
  def run(%module{} = tool, %Context{} = context), do: module.run(tool, context)

  @doc """
  Whether `module` implements this behaviour. Loads it first, so a module this node has not
  loaded yet (interactive mode) is not taken for a non-tool.
  """
  @spec implemented_by?(atom()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      __MODULE__ in (module.module_info(:attributes)
                     |> Keyword.get_values(:behaviour)
                     |> List.flatten())
  end
end
```

`lib/normandy/tools/input.ex`:

```elixir
defmodule Normandy.Tools.Input do
  @moduledoc """
  Validates a tool call's input before the tool runs.

  The dispatcher checks the model's input here and passes the result to
  `c:Normandy.Tool.run/2` as `context.input`; it never goes into the tool struct.

    * A tool that declared `input: Schema` (`use Normandy.Tool`) gets a `%Schema{}`. Every key
      (string or atom) must name a field of the schema; the values are checked by
      `Normandy.Schema.Validator` (types, required fields, enums, ranges, formats; nothing is
      coerced, so `"5"` for an integer field is an error); missing optional fields take their
      defaults.
    * Any other tool gets a string-keyed map checked against its `c:Normandy.Tool.input_schema/1`
      map (string or atom keys): every `required` key present, each value's basic JSON type
      (`string`, `integer`, `number`, `boolean`, `object`, `array`, `null`) where its property
      declares one, and unknown keys as follows. A schema that declares `properties` is
      closed: no key outside them unless `additionalProperties` is `true` or a schema (an
      absent `additionalProperties` counts as `false` here, unlike JSON Schema's default). A
      schema with no `properties` key declares no keys, so it limits none: any key is
      accepted (an MCP server's loose `{"type": "object"}` keeps working). Nested schemas,
      enums and formats are the tool's to check.

  An unknown key is an error for a declared input schema and for a map that declares
  `properties`, and keys are matched against declared names, so model input never creates an
  atom. Errors are `%{path: [key], message: String.t(),
  constraint: atom()}`; `message/1` joins them into one line for the model.
  """

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Schema.Validator

  @type error :: %{path: [atom() | String.t()], message: String.t(), constraint: atom()}

  @doc "Validates `input` against `tool`'s input schema; see the moduledoc."
  @spec validate(struct(), term()) :: {:ok, struct() | map()} | {:error, [error()]}
  def validate(%module{} = tool, input) when is_map(input) and not is_struct(input) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__tool_input__, 0),
      do: validate_schema(module.__tool_input__(), input),
      else: validate_map(Normandy.Tool.input_schema(tool), input)
  end

  def validate(_tool, input) do
    {:error,
     [
       %{
         path: [],
         message: "expected a JSON object, got: #{Describe.type_of(input)}",
         constraint: :type
       }
     ]}
  end

  @doc ~S"""
  One line for the model: errors joined by `"; "`, each as `"<path> <message>"` (a
  path-less error is its message alone).

      iex> Normandy.Tools.Input.message([%{path: [:query], message: "is required", constraint: :required}])
      "query is required"
  """
  @spec message([error()]) :: String.t()
  def message(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: [], message: message} -> message
      %{path: path, message: message} -> Enum.map_join(path, ".", &to_string/1) <> " " <> message
    end)
  end

  defp validate_schema(schema, input) do
    fields = schema.__schema__(:fields)
    by_name = Map.new(fields, &{Atom.to_string(&1), &1})
    {known, unknown, repeated} = split_keys(input, by_name)

    errors =
      unknown_keys(unknown, Enum.map(fields, &Atom.to_string/1)) ++
        repeated_keys(repeated) ++ sort_by_path(schema_errors(Validator.validate(schema, known)))

    case errors do
      [] -> {:ok, struct(schema, known)}
      errors -> {:error, errors}
    end
  end

  # A key maps to a field through the declared names; String.to_atom/1 is never called on it.
  defp split_keys(input, by_name) do
    Enum.reduce(input, {%{}, [], []}, fn {key, value}, {known, unknown, repeated} ->
      name = key_name(key)

      case Map.fetch(by_name, name) do
        {:ok, field} when is_map_key(known, field) -> {known, unknown, [name | repeated]}
        {:ok, field} -> {Map.put(known, field, value), unknown, repeated}
        :error -> {known, [name | unknown], repeated}
      end
    end)
  end

  defp schema_errors({:ok, _data}), do: []
  defp schema_errors({:error, errors}), do: errors

  defp validate_map(schema, input) when is_map(schema) do
    properties = schema |> get(:properties, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    required = schema |> get(:required, []) |> Enum.map(&to_string/1)
    # No `properties` key: the schema names no keys, so it limits none (decision 18). With
    # `properties`, an absent `additionalProperties` closes it.
    open? =
      not has?(schema, :properties) or
        get(schema, :additionalProperties, false) not in [false, nil]
    {given, repeated} = string_keys(input)

    unknown = if open?, do: [], else: Map.keys(given) -- Map.keys(properties)
    missing = Enum.sort(required -- Map.keys(given))

    errors =
      unknown_keys(unknown, properties |> Map.keys() |> Enum.sort()) ++
        repeated_keys(repeated) ++
        Enum.map(missing, &%{path: [&1], message: "is required", constraint: :required}) ++
        sort_by_path(type_errors(given, properties))

    case errors do
      [] -> {:ok, given}
      errors -> {:error, errors}
    end
  end

  defp string_keys(input) do
    Enum.reduce(input, {%{}, []}, fn {key, value}, {given, repeated} ->
      name = key_name(key)

      if Map.has_key?(given, name),
        do: {given, [name | repeated]},
        else: {Map.put(given, name, value), repeated}
    end)
  end

  defp type_errors(given, properties) do
    Enum.flat_map(given, fn {name, value} ->
      with %{} = spec <- Map.get(properties, name),
           type when not is_nil(type) <- get(spec, :type, nil),
           false <- json_type?(value, type) do
        [
          %{
            path: [name],
            message: "expected type #{type_label(type)}, got #{json_type(value)}",
            constraint: :type
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp unknown_keys([], _expected), do: []

  defp unknown_keys(unknown, expected) do
    noun = if length(unknown) == 1, do: "unknown key", else: "unknown keys"
    expected = if expected == [], do: "no keys", else: "only " <> quote_list(expected)

    [
      %{
        path: [],
        message: "#{noun} #{quote_list(Enum.sort(unknown))}; expected #{expected}",
        constraint: :unknown_keys
      }
    ]
  end

  defp repeated_keys(repeated) do
    for name <- Enum.sort(repeated) do
      %{
        path: [name],
        message: "is given twice (as a string key and as an atom key)",
        constraint: :duplicate_key
      }
    end
  end

  defp sort_by_path(errors),
    do: Enum.sort_by(errors, &Enum.map(&1.path, fn p -> to_string(p) end))

  defp quote_list(names), do: Enum.map_join(names, ", ", &inspect/1)

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key), do: inspect(key)

  # A schema map may use atom or string keys (built-in tools use both).
  defp get(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp has?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp json_type?(value, types) when is_list(types), do: Enum.any?(types, &json_type?(value, &1))
  defp json_type?(value, type) when is_atom(type), do: json_type?(value, Atom.to_string(type))
  defp json_type?(value, "string"), do: is_binary(value)
  defp json_type?(value, "integer"), do: is_integer(value)
  defp json_type?(value, "number"), do: is_number(value)
  defp json_type?(value, "boolean"), do: is_boolean(value)
  defp json_type?(value, "object"), do: is_map(value)
  defp json_type?(value, "array"), do: is_list(value)
  defp json_type?(value, "null"), do: is_nil(value)
  # A type name outside JSON Schema's basic seven is not this module's to check.
  defp json_type?(_value, _type), do: true

  defp type_label(types) when is_list(types), do: Enum.map_join(types, " or ", &to_string/1)
  defp type_label(type), do: to_string(type)

  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_integer(value), do: "integer"
  defp json_type(value) when is_float(value), do: "number"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(nil), do: "null"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_map(value), do: "object"
  defp json_type(_value), do: "an unsupported term"
end
```

`lib/normandy/tools/context.ex`: replace lines 1-25 (moduledoc, `defstruct`, `@type`) with:

```elixir
defmodule Normandy.Tools.Context do
  @moduledoc """
  What a tool knows about the call it serves; the second argument of
  `c:Normandy.Tool.run/2`.

  Built per tool call by the dispatch pipeline from the agent config, the `%ToolCall{}` and
  the validated input. `input` is the model's input after `Normandy.Tools.Input.validate/2`:
  a struct of the tool's declared input schema, or a string-keyed map. `values` is the
  config's `tool_context`: plain data the application sets per session (for example
  `%{memory_namespace: "acme/user-42"}`). It is persisted in the session's config template,
  so it must hold no secrets; resolve secrets through `Normandy.Behaviours.CredentialProvider`,
  keyed by a value from here.

  The model sets only `input`, and only through validation; the tool struct and the rest of
  the context are out of its reach.
  """

  alias Normandy.Components.ToolCall

  @enforce_keys [:tool_call_id]
  defstruct [:session_id, :agent_name, :turn_id, :tool_call_id, input: nil, values: %{}]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          agent_name: String.t() | nil,
          turn_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          input: struct() | map() | nil,
          values: map()
        }
```

(`build/2` stays as it is until Task 3.4c.)

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/tools/tool_test.exs test/tools/input_test.exs`
Expected: PASS. If `Code.compile_string/1` reports the `ArgumentError` wrapped in a
`CompileError` on some Elixir version of the CI matrix, the `assert_raise ArgumentError` will
say so; the message checks stay as written (do not loosen them to a regex).

Also run `mix test test/tools/context_test.exs` (untouched by this task) — PASS: the new
field defaults to `nil`.

- [ ] **Step 5: Format, full suite, commit**

No MIGRATING text in this task: nothing a user calls has changed yet (Task 3.4c adds the
section's tool-author table when the old contracts go).

Run: `mix format && mix credo --strict 2>&1 | tail -3 && mix test 2>&1 | tail -5`
Expected: Credo finds no issues; ` 0 failures`.

```bash
git add lib/normandy/tool.ex lib/normandy/tools/input.ex lib/normandy/tools/context.ex \
  test/tools/tool_test.exs test/tools/input_test.exs
git commit -m "feat(tools): Normandy.Tool behaviour, use Normandy.Tool, and the tool input validator

Context gains :input. Normandy.Tools.Input validates model input into the declared
schema's struct, or a string-keyed map checked against a hand-written schema; an
unknown key is an error that names it, except under a hand-written schema with no
properties, which accepts any keys. Not wired into dispatch yet."
```

---
### Task 3.4c: The dispatcher runs `Normandy.Tool`; every tool migrates; `BaseTool`, `SchemaBaseTool`, `ContextualTool` deleted (SEC-1, decision 7)

One commit. The dispatcher change and the migration of every implementation cannot land
apart: once `Dispatch` stops calling `prepare_tool/2` and the executor calls
`c:Normandy.Tool.run/2`, every `defimpl BaseTool` tool stops working, and a temporary
adapter (a `Normandy.Tool` shim over `BaseTool`) would have to re-create exactly the struct
merge SEC-1 removes. The steps below are ordered so a reviewer can read them one concern at a
time; the suite is only green again at Step 9.

The whole task was rehearsed on a copy of the tree at `95dc149` with Tasks 3.1/3.3 stubbed
(`Normandy.Options` over NimbleOptions; the example tools moved to `test/support/tools/`):
after Step 9, `mix compile --warnings-as-errors`, `mix credo --strict` (no issues),
`mix dialyzer` (30 skipped, 0 unnecessary) and `mix test` (0 failures, 16 runs) all passed.

**Files:**
- Create: `test/tools/tool_input_isolation_test.exs` (Review Focus #2)
- Modify (lib): `lib/normandy/tools/context.ex` (`build/3`), `lib/normandy/tools/executor.ex`
  (rewrite), `lib/normandy/tools/toolset.ex` (`:timeout`, `timeout/2`, `Normandy.Tool`
  callbacks, introspection), `lib/normandy/agents/dispatch.ex`, `lib/normandy/behaviours/config.ex`
  (`to_pipeline/1`), `lib/normandy/behaviours/policy_engine.ex` (moduledoc),
  `lib/normandy/agents/base_agent.ex` (`span_execute/4`, alias),
  `lib/normandy/agents/turn/server.ex` (`dispatch/2`, `execute_approved/2`),
  `lib/normandy/telemetry/metadata.ex` (`tool/3`), `lib/normandy/tools/memory.ex`,
  `lib/normandy/tools/memory/commands.ex`, `lib/normandy/a2a/agent_tool.ex`,
  `lib/normandy/a2a/registry.ex`, `lib/normandy/a2a/server.ex`, `lib/normandy/mcp/tool_wrapper.ex`,
  `lib/normandy/mcp/registry.ex`, `mix.exs` (Tools docs group), `.dialyzer_ignore.exs` (comment)
- Delete: `lib/normandy/tools/base_tool.ex`, `lib/normandy/tools/schema_base_tool.ex`,
  `lib/normandy/tools/contextual_tool.ex`, `test/support/tool_mockup.ex` (unused: no test
  references `NormandyTest.Support.Tool`), `test/tools/base_tool_test.exs`,
  `test/tools/schema_base_tool_test.exs`
- Modify (test support): `test/support/fake_tool.ex`, `test/support/context_probe.ex`,
  `test/support/lazy_tool.ex`, `test/support/e2e/distributed.ex` (`RefundTool`),
  `test/support/memory_store_contract.ex`, `test/support/integration_helper.ex`,
  `test/support/normandy_integration_helper.ex`, `test/support/tools/{calculator,enhanced_calculator,list_processor,string_manipulator}.ex`
- Modify (tests): `test/agents/dispatch_split_test.exs` (rewrite), `test/tools/executor_test.exs`
  (rewrite), `test/tools/context_test.exs` (rewrite), `test/tools/examples_test.exs`,
  `test/agents/dispatch_test.exs`, `test/agents/tool_context_test.exs`,
  `test/agents/lazy_module_test.exs`, `test/agents/base_agent_streaming_test.exs`,
  `test/agents/base_agent_guardrails_test.exs`, `test/agents/base_agent_tool_loop_test.exs`,
  `test/agents/turn_inline_test.exs`, `test/telemetry/tool_telemetry_test.exs`,
  `test/behaviours/config_test.exs`, `test/tools/memory_test.exs`,
  `test/tools/memory_telemetry_test.exs`, `test/a2a/agent_tool_test.exs`,
  `test/a2a/registry_test.exs`, `test/mcp/tool_wrapper_test.exs`,
  `test/telemetry/a2a_propagation_test.exs`, `test/dsl/agent_memory_test.exs`,
  `test/json_struct_encoding_test.exs` (Task 3.3a's; Step 7k), plus the
  struct-literal rewrite of Step 6a (14 files)
- Modify (e2e, not compiled by `mix test`): `e2e/03_tool_loop.exs`, `e2e/05_approvals.exs`,
  `e2e/12_mcp_a2a.exs`, `e2e/13_budget_policy.exs`
- Modify: `MIGRATING-2.0.md` (the tools section from Task 3.4a)

**Interfaces:**
- Consumes: Task 3.4a (`Toolset`, `fetch/2`, `register/3` options through `Normandy.Options`),
  Task 3.4b (`Normandy.Tool`, `Normandy.Tools.Input`, `Context.input`).
- Produces:
  - `Toolset.register/3` option `timeout: pos_integer()`; `Toolset.timeout/2`.
  - `Context.build(config, call, input)` (replaces `build/2`).
  - `Executor.execute_tool/2`, `execute_tool_classified/2`: options `:context` (required, a
    `%Context{}`) and `:timeout` (default `Executor.default_timeout/0` = 30_000), validated
    through `Normandy.Options`; the tool struct's fields are never read. `execute/3`,
    `execute_parallel/3`, `execute_sequential/3` and `:max_retries` are removed (see Notes).
  - `Dispatch.Invocation{tool, input, timeout}`; `classify/3` returns
    `{:execute, Invocation.t(), call}` / `{:needs_approval, Invocation.t(), call, info}`;
    `execute/4` takes the invocation; `policy_fn.(config, call, invocation)`;
    `execute_fn.(config, invocation, name[, call])`; `Dispatch.execute_approved/3`;
    `Dispatch.executor_opts/3`. Removed: `prepare_tool/2`, `validate_input/2`,
    `normalize_tool_field_key/2` (`@doc false`).
  - The model-facing result for invalid input:
    `%ToolResult{is_error: true, output: %{error: "invalid input for <tool>: <Input.message/1>; the tool was not run", validation_errors: [...], denied: true}}`.
  - PolicyEngine ctx gains `:input`; `:tool` is the registered struct.
  - `Normandy.Tools.Memory`, `Normandy.A2A.AgentTool`, `Normandy.MCP.ToolWrapper` implement
    `Normandy.Tool`; `AgentTool` and `ToolWrapper` lose `:input`, `AgentTool` loses `:timeout`
    (`AgentTool.new/3` raises on it); `prepare_input/2` is gone from all three;
    `Memory.command/1` (`@doc false`) builds the command map. `A2A.Registry.discover_and_register/3`'s
    `:timeout` is each tool's registration timeout (default 60_000, as 1.x).

- [ ] **Step 1: Write the failing tests**

1a. `test/tools/tool_input_isolation_test.exs`, the Review Focus #2 test under `run/2`,
`stream/3` and `Turn.Server` (it decodes tool results with `Jason`, a runtime dependency; use
`Normandy.JSON.decode!/1` instead if Task 3.3 asks every JSON call to go through it):

```elixir
defmodule Normandy.Tools.ToolInputIsolationTest do
  @moduledoc false
  # Review Focus #2 (SEC-1): model input that names a tool's config fields never reaches
  # the tool struct. The unknown keys come back as an is_error tool result naming them,
  # the turn goes on, and the registration timeout (not the struct's :timeout field)
  # bounds the run. Under BaseAgent.run/2, BaseAgent.stream/3 and Turn.Server.
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Tools.Context

  defmodule LookupTool do
    @moduledoc false
    defmodule Params do
      @moduledoc false
      use Normandy.Schema

      io_schema "Lookup input" do
        field(:query, :string, required: true, description: "the query")
      end
    end

    use Normandy.Tool, name: "lookup", description: "looks a query up", input: Params

    defstruct [:endpoint, :notify, timeout: 5_000]

    @impl Normandy.Tool
    def run(%__MODULE__{} = tool, %Context{input: %Params{query: query}}) do
      send(tool.notify, {:ran, tool, query})
      # "slow" never returns: only the executor's timeout ends it.
      if query == "slow", do: Process.sleep(:infinity)
      {:ok, "#{tool.endpoint}: #{query}"}
    end
  end

  # One tool round: the hostile call and a slow one, then the final answer.
  defmodule ScriptedClient do
    @moduledoc false
    defstruct notify: nil, options: %{}

    defimpl Normandy.Agents.Model do
      alias Normandy.Agents.ToolCallResponse
      alias Normandy.Components.ToolCall

      @hostile ~s({"query":"x","endpoint":"evil","timeout":"x"})

      def converse(client, request, _opts) do
        send(client.notify, {:request, request})

        content =
          if answered?(request) do
            request.response_model
          else
            %ToolCallResponse{
              content: nil,
              tool_calls: [
                %ToolCall{id: "hostile", name: "lookup", input: Jason.decode!(@hostile)},
                %ToolCall{id: "slow", name: "lookup", input: %{"query" => "slow"}}
              ]
            }
          end

        {:ok, %Normandy.LLM.Response{content: content}}
      end

      def stream(client, request, _opts) do
        send(client.notify, {:request, request})
        events = if answered?(request), do: text_events(), else: tool_events()
        {:ok, Stream.map(events, & &1)}
      end

      defp answered?(request), do: Enum.any?(request.messages, &(&1.role == "tool"))

      defp tool_events do
        [
          %{type: "message_start", message: %{"id" => "m1", "role" => "assistant"}},
          tool_use(0, "hostile", @hostile),
          %{type: "content_block_stop", index: 0},
          tool_use(1, "slow", ~s({"query":"slow"})),
          %{type: "content_block_stop", index: 1},
          %{type: "message_stop"}
        ]
        |> List.flatten()
      end

      defp tool_use(index, id, json) do
        [
          %{
            type: "content_block_start",
            content_block: %{"type" => "tool_use", "id" => id, "name" => "lookup"},
            index: index
          },
          %{
            type: "content_block_delta",
            delta: %{"type" => "input_json_delta", "partial_json" => json},
            index: index
          }
        ]
      end

      defp text_events do
        [
          %{type: "message_start", message: %{"id" => "m2", "role" => "assistant"}},
          %{
            type: "content_block_start",
            content_block: %{"type" => "text", "text" => ""},
            index: 0
          },
          %{
            type: "content_block_delta",
            delta: %{"type" => "text_delta", "text" => "done"},
            index: 0
          },
          %{type: "content_block_stop", index: 0},
          %{type: "message_stop"}
        ]
      end
    end
  end

  defp tool, do: %LookupTool{endpoint: "https://ok.example", notify: self()}

  defp agent do
    BaseAgent.init(%{client: %ScriptedClient{notify: self()}, model: "m"})
    |> BaseAgent.register_tool(tool(), timeout: 50)
  end

  # The second request carries the tool results the model was sent.
  defp assert_isolated do
    assert_received {:request, _first}
    assert_received {:request, second}

    results =
      second.messages
      |> Enum.filter(&(&1.role == "tool"))
      |> Enum.flat_map(& &1.content)
      |> Map.new(&{&1.tool_use_id, &1})

    hostile = Map.fetch!(results, "hostile")
    assert hostile.is_error
    output = Jason.decode!(hostile.content)

    assert output["error"] ==
             ~s(invalid input for lookup: unknown keys "endpoint", "timeout"; ) <>
               ~s(expected only "query"; the tool was not run)

    assert [%{"constraint" => "unknown_keys"}] = output["validation_errors"]

    slow = Map.fetch!(results, "slow")
    assert slow.is_error
    assert Jason.decode!(slow.content) == %{"error" => "Tool execution timeout after 50ms"}

    # The tool ran once, for "slow", with its struct exactly as registered.
    expected = tool()
    assert_received {:ran, ^expected, "slow"}
    refute_received {:ran, _tool, "x"}
  end

  test "BaseAgent.run/2" do
    assert {:ok, _config, _output} = BaseAgent.run(agent(), "go")
    assert_isolated()
  end

  test "BaseAgent.stream/3" do
    assert {:ok, _config, _output} = BaseAgent.stream(agent(), "go", fn _event -> :ok end)
    assert_isolated()
  end

  test "Turn.Server" do
    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "isolation-#{System.unique_integer([:positive])}",
        config: agent(),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()}
      )

    assert {:ok, _output} = Turn.Server.run(srv, "go")
    assert_isolated()
  end
end
```

1b. Replace `test/agents/dispatch_split_test.exs` with the following. Gone with their
subjects: the `ValidateOnlyTool` / `GarbageValidatorTool` / `PrepareInputTool` cases (the
`validate/1`-shape detection and `prepare_input/2` no longer exist). New: the invocation
shape, the registration timeout, policy seeing the invocation, unknown keys and basic types
on a hand-written schema, validation after a hook's rewrite, and `execute_approved/3`.

```elixir
defmodule Normandy.Agents.DispatchSplitTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Dispatch.Invocation
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Test.FakeTool
  alias Normandy.Tools.{Context, Executor, Toolset}

  # A tool with a declared input schema (required + enum). run/2's return value
  # ("did <op>") is the only way to get a non-error ToolResult, so seeing it proves the
  # tool ran; a validation denial is a different (denied) result, proving it did not.
  defmodule SchemaTool do
    @moduledoc false
    defmodule Params do
      @moduledoc false
      use Normandy.Schema

      io_schema "enum + required constrained input" do
        field(:operation, :string, required: true, enum: ["add", "subtract"])
      end
    end

    use Normandy.Tool,
      name: "schema_tool",
      description: "enum + required constrained tool",
      input: Params

    defstruct []

    @impl Normandy.Tool
    def run(_tool, %Context{input: %Params{operation: op}}), do: {:ok, "did #{op}"}
  end

  defp config_with_tools(tools), do: %{name: "test-agent", toolset: Toolset.new(tools)}

  describe "classify/3" do
    test "allow → {:execute, %Invocation{}, call}: the tool as registered, the validated input, the registration timeout" do
      tool = %FakeTool{}
      config = config_with_tools([{tool, timeout: 1_234}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      assert {:execute, %Invocation{tool: ^tool, input: %{"city" => "NYC"}, timeout: 1_234},
              %ToolCall{id: "c1"}} = Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "a tool registered without :timeout gets the executor's default" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{}}
      default = Executor.default_timeout()

      assert {:execute, %Invocation{timeout: ^default}, _call} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "input that is not a JSON object is refused and the model is told" do
      config = config_with_tools([%FakeTool{}])

      for input <- [~s({"city": "NY), "[1, 2]", 42] do
        call = %ToolCall{id: "bad", name: "weather", input: input}

        assert {:deny, %ToolResult{tool_call_id: "bad", is_error: true, output: output}} =
                 Dispatch.classify(config, call, Dispatch.default_pipeline())

        assert output.error =~ "not a JSON object"
      end
    end

    test "deny → {:deny, error ToolResult}, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c2", name: "weather", input: %{"city" => "NYC"}}

      deny = fn _c, _call, _invocation -> {:deny, %{reason: "blocked", rule_id: "R-1"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny}

      assert {:deny, %ToolResult{tool_call_id: "c2", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "needs_approval → {:needs_approval, %Invocation{}, call, info}" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c3", name: "weather", input: %{"city" => "NYC"}}

      approve = fn _c, _call, _invocation -> {:needs_approval, %{rationale: "high-cost"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert {:needs_approval, %Invocation{tool: %FakeTool{}}, %ToolCall{id: "c3"},
              %{rationale: "high-cost"}} = Dispatch.classify(config, call, pipeline)
    end

    test "policy_fn gets the invocation: the registered tool and the validated input" do
      parent = self()
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c13", name: "weather", input: %{"city" => "NYC"}}

      policy = fn _c, _call, invocation ->
        send(parent, {:policy_saw, invocation})
        {:allow, %{}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: policy}

      assert {:execute, _invocation, _call} = Dispatch.classify(config, call, pipeline)

      assert_received {:policy_saw,
                       %Invocation{tool: %FakeTool{name: "weather"}, input: %{"city" => "NYC"}}}
    end

    test "toolset miss → {:deny, not-found ToolResult}" do
      config = config_with_tools([])
      call = %ToolCall{id: "c4", name: "nope", input: %{}}

      assert {:deny, %ToolResult{tool_call_id: "c4", is_error: true}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "before-hook {:halt, result} → {:deny, result}, policy not consulted" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c5", name: "weather", input: %{"city" => "NYC"}}

      halt = fn _c, %ToolCall{id: id} ->
        {:halt, %ToolResult{tool_call_id: id, output: %{error: "hooked"}, is_error: true}}
      end

      pipeline = %{Dispatch.default_pipeline() | before_hooks: [halt]}

      assert {:deny, %ToolResult{tool_call_id: "c5", output: %{error: "hooked"}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "policy_fn that raises → {:deny}, fail-closed (belt-and-suspenders)" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c11", name: "weather", input: %{"city" => "NYC"}}

      boom = fn _c, _call, _invocation -> raise "policy engine down" end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: boom}

      assert {:deny, %ToolResult{tool_call_id: "c11", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "policy_fn that exits (timeout/unreachable) → {:deny}, fail-closed" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c12", name: "weather", input: %{"city" => "NYC"}}

      timeout = fn _c, _call, _invocation -> exit(:timeout) end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: timeout}

      assert {:deny, %ToolResult{tool_call_id: "c12", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "accepts a raw string-keyed map" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c6", "name" => "weather", "input" => %{"city" => "LA"}}

      assert {:execute, %Invocation{input: %{"city" => "LA"}}, %ToolCall{id: "c6"}} =
               Dispatch.classify(config, raw, Dispatch.default_pipeline())
    end
  end

  describe "classify/3 input validation" do
    test "an enum violation → {:deny, validation error}, never classified to :execute" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v1", name: "schema_tool", input: %{"operation" => "power"}}

      assert {:deny, %ToolResult{tool_call_id: "v1", is_error: true} = result} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert result.output.denied == true
      assert [%{constraint: :enum, path: [:operation]}] = result.output.validation_errors

      assert result.output.error ==
               ~s(invalid input for schema_tool: operation must be one of ["add", "subtract"]; ) <>
                 "the tool was not run"
    end

    test "a missing required field → {:deny, validation error}" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v2", name: "schema_tool", input: %{}}

      assert {:deny, %ToolResult{tool_call_id: "v2", is_error: true} = result} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert [%{constraint: :required, path: [:operation]}] = result.output.validation_errors
    end

    test "valid input becomes the declared schema's struct" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v3", name: "schema_tool", input: %{"operation" => "add"}}

      assert {:execute,
              %Invocation{tool: %SchemaTool{}, input: %SchemaTool.Params{operation: "add"}},
              %ToolCall{id: "v3"}} = Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "unknown keys on a hand-written schema are named in the result" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "v6", name: "weather", input: %{"city" => "x", "bogus" => 1}}

      assert {:deny, %ToolResult{is_error: true, output: output}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert output.error ==
               ~s(invalid input for weather: unknown key "bogus"; expected only "city"; ) <>
                 "the tool was not run"
    end

    test "a value of the wrong basic type on a hand-written schema" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "v7", name: "weather", input: %{"city" => 123}}

      assert {:deny, %ToolResult{output: %{validation_errors: [error]}}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert error == %{
               path: ["city"],
               message: "expected type string, got integer",
               constraint: :type
             }
    end

    test "the input a before-hook produced is what gets validated" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "v8", name: "weather", input: %{"city" => "x"}}
      hook = fn _c, call -> {:cont, %{call | input: Map.put(call.input, "bogus", 1)}} end
      pipeline = %{Dispatch.default_pipeline() | before_hooks: [hook]}

      assert {:deny, %ToolResult{output: %{validation_errors: [%{constraint: :unknown_keys}]}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "dispatch_one: a malformed call never reaches run/2" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v4", name: "schema_tool", input: %{"operation" => "power"}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "v4", is_error: true, output: %{denied: true}} = result
      # run/2 would have produced the string "did power"; a map proves it never ran.
      refute result.output == "did power"
    end

    test "dispatch_one: a valid call runs run/2 (its return value is the result)" do
      config = config_with_tools([%SchemaTool{}])
      call = %ToolCall{id: "v5", name: "schema_tool", input: %{"operation" => "add"}}

      assert %ToolResult{is_error: false, output: "did add"} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())
    end
  end

  describe "execute/4" do
    test "runs the tool and returns a success ToolResult" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c7", name: "weather", input: %{"city" => "NYC"}}

      {:execute, invocation, call} =
        Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c7", output: "weather in NYC", is_error: false} =
               Dispatch.execute(config, invocation, call, Dispatch.default_pipeline())
    end

    test "budget {:error, reason} → budget-denial result, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c8", name: "weather", input: %{"city" => "NYC"}}

      {:execute, invocation, call} =
        Dispatch.classify(config, call, Dispatch.default_pipeline())

      over = fn _c, _call -> {:error, :cap} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over}

      result = Dispatch.execute(config, invocation, call, pipeline)
      assert %ToolResult{tool_call_id: "c8", is_error: true, output: %{denied: true}} = result
      assert result.output.error =~ "budget check failed"
    end

    test "the registration timeout bounds the run" do
      config = config_with_tools([{%FakeTool{sleep_ms: 1_000}, timeout: 20}])
      call = %ToolCall{id: "c14", name: "weather", input: %{}}

      assert %ToolResult{is_error: true, output: %{error: "Tool execution timeout after 20ms"}} =
               Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())
    end
  end

  describe "execute_approved/3" do
    test "re-validates the parked call's input and runs it without consulting policy" do
      parent = self()
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "a1", name: "weather", input: %{"city" => "Oslo"}}

      policy = fn _c, _call, _invocation ->
        send(parent, :policy_ran)
        {:deny, %{reason: "no"}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: policy}

      assert %ToolResult{tool_call_id: "a1", output: "weather in Oslo", is_error: false} =
               Dispatch.execute_approved(config, call, pipeline)

      refute_received :policy_ran
    end

    test "a tool no longer registered is a not-found result, not a crash" do
      config = config_with_tools([])
      call = %ToolCall{id: "a2", name: "weather", input: %{}}

      assert %ToolResult{tool_call_id: "a2", is_error: true, output: %{error: error}} =
               Dispatch.execute_approved(config, call, Dispatch.default_pipeline())

      assert error =~ "weather"
    end

    test "input that no longer validates is answered with the validation result" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "a3", name: "weather", input: %{"bogus" => 1}}

      assert %ToolResult{
               tool_call_id: "a3",
               is_error: true,
               output: %{denied: true, validation_errors: [%{constraint: :unknown_keys}]}
             } = Dispatch.execute_approved(config, call, Dispatch.default_pipeline())
    end
  end

  describe "dispatch_one/3 == classify ➞ execute" do
    test "allow path equals execute of the classified call" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c9", name: "weather", input: %{"city" => "NYC"}}
      p = Dispatch.default_pipeline()

      {:execute, invocation, call2} = Dispatch.classify(config, call, p)

      assert Dispatch.dispatch_one(config, call, p) ==
               Dispatch.execute(config, invocation, call2, p)
    end

    test "needs_approval still collapses to the interim denial (pending_approval: true)" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c10", name: "weather", input: %{"city" => "NYC"}}
      approve = fn _c, _call, _invocation -> {:needs_approval, %{rationale: "r"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert %ToolResult{is_error: true, output: %{pending_approval: true, denied: true}} =
               Dispatch.dispatch_one(config, call, pipeline)
    end
  end
end
```

1c. Replace `test/tools/executor_test.exs` (the executor no longer looks tools up or merges
input, so the `execute/3`, `execute_parallel/3` and `execute_sequential/3` tests go):

```elixir
defmodule NormandyTest.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  alias Normandy.Tools.{Context, Executor}
  alias Normandy.Tools.Examples.{Calculator, ListProcessor, StringManipulator}

  defp ctx(input), do: %Context{tool_call_id: "t1", input: input}

  describe "execute_tool/2" do
    test "runs the tool with the context's input" do
      input = %Calculator.Input{operation: "multiply", a: 6, b: 7}

      assert {:ok, 42.0} = Executor.execute_tool(%Calculator{}, context: ctx(input))
    end

    test "a tool with a hand-written schema gets a string-keyed map" do
      assert {:ok, "olleh"} =
               Executor.execute_tool(%StringManipulator{},
                 context: ctx(%{"operation" => "reverse", "text" => "hello"})
               )

      assert {:ok, 15} =
               Executor.execute_tool(%ListProcessor{},
                 context: ctx(%{"operation" => "sum", "numbers" => [1, 2, 3, 4, 5]})
               )
    end

    test "the tool's own error comes back as is" do
      input = %Calculator.Input{operation: "divide", a: 10, b: 0}

      assert {:error, "Cannot divide by zero"} =
               Executor.execute_tool(%Calculator{}, context: ctx(input))
    end
  end

  describe "timeout" do
    defmodule SlowTool do
      @moduledoc false
      use Normandy.Tool, name: "slow_tool", description: "sleeps for its input's delay"

      # A struct field named :timeout is configuration like any other; the executor
      # never reads it.
      defstruct timeout: 10_000

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{delay: %{type: "integer"}}}

      @impl Normandy.Tool
      def run(_tool, %Context{input: %{"delay" => delay}}) do
        Process.sleep(delay)
        {:ok, "completed"}
      end
    end

    test "a run within :timeout completes" do
      assert {:ok, "completed"} =
               Executor.execute_tool(%SlowTool{}, context: ctx(%{"delay" => 10}), timeout: 1_000)
    end

    test "a run past :timeout fails; the struct's :timeout field is not read" do
      assert {:error, "Tool execution timeout after 20ms"} =
               Executor.execute_tool(%SlowTool{timeout: 10_000},
                 context: ctx(%{"delay" => 1_000}),
                 timeout: 20
               )
    end

    test "the default is 30 seconds" do
      assert Executor.default_timeout() == 30_000
    end
  end

  describe "error handling" do
    defmodule CrashingTool do
      @moduledoc false
      use Normandy.Tool, name: "crasher", description: "A tool that crashes"

      defstruct []

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object"}

      @impl Normandy.Tool
      def run(_tool, _context), do: raise("Intentional crash for testing")
    end

    test "catches and reports tool crashes" do
      assert {:error, error} = Executor.execute_tool(%CrashingTool{}, context: ctx(%{}))
      assert error =~ "Tool execution failed"
      assert error =~ "Intentional crash"
    end
  end

  describe "results the model can use" do
    defmodule ReturnTool do
      @moduledoc false
      use Normandy.Tool, name: "return_tool", description: "returns or exits with its value"

      defstruct [:value]

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{}}

      @impl Normandy.Tool
      def run(%{value: {:exit, reason}}, _context), do: exit(reason)
      def run(%{value: {:sleep, ms}}, _context), do: Process.sleep(ms) && {:ok, :slept}
      def run(%{value: value}, _context), do: value
    end

    test "a result that is not {:ok, _} or {:error, _} becomes an error result" do
      for bad <- [:ok, "bare string", nil] do
        assert {:error, message} =
                 Executor.execute_tool(%ReturnTool{value: bad}, context: ctx(%{}))

        assert message =~ "invalid result"
      end
    end

    test "an exit reason is named by its tag, not copied into the result" do
      tool = %ReturnTool{value: {:exit, {:timeout, {GenServer, :call, [:db, "SELECT secret"]}}}}

      assert {:error, message} = Executor.execute_tool(tool, context: ctx(%{}))
      assert message =~ ":timeout"
      refute message =~ "SELECT secret"
    end

    test "options are validated, naming the function and the key" do
      tool = %ReturnTool{value: {:ok, 1}}

      for {opts, key} <- [
            {[context: ctx(%{}), timeout: nil], ":timeout"},
            {[context: ctx(%{}), max_retries: 1], ":max_retries"},
            {[], ":context"}
          ] do
        error = assert_raise ArgumentError, fn -> Executor.execute_tool(tool, opts) end
        assert String.starts_with?(error.message, "Normandy.Tools.Executor.execute_tool/2: ")
        assert error.message =~ key
      end
    end

    test ":context must be a %Normandy.Tools.Context{}" do
      error =
        assert_raise ArgumentError, fn ->
          Executor.execute_tool(%ReturnTool{value: {:ok, 1}}, context: %{})
        end

      assert error.message ==
               "Normandy.Tools.Executor.execute_tool/2: :context must be a " <>
                 "%Normandy.Tools.Context{}, got: a map"
    end
  end

  describe "execute_tool_classified/2" do
    alias NormandyTest.Tools.ExecutorTest.{CrashingTool, ReturnTool}

    test "success carries no error type" do
      assert {{:ok, 1}, nil} =
               Executor.execute_tool_classified(%ReturnTool{value: {:ok, 1}}, context: ctx(%{}))
    end

    test "each failure kind is named, with the same {:error, msg} execute_tool/2 returns" do
      cases = [
        {%ReturnTool{value: {:error, "nope"}}, [], :tool_error},
        {%ReturnTool{value: :bare}, [], :invalid_result},
        {%ReturnTool{value: {:exit, :boom}}, [], :exit},
        {%ReturnTool{value: {:sleep, 100}}, [timeout: 10], :timeout},
        {%CrashingTool{}, [], :exception}
      ]

      for {tool, opts, kind} <- cases do
        opts = [context: ctx(%{})] ++ opts
        assert {{:error, message}, ^kind} = Executor.execute_tool_classified(tool, opts)
        assert {:error, ^message} = Executor.execute_tool(tool, opts)
      end
    end
  end

  describe "OTel context propagation" do
    # `Task.async` spawns a fresh process, which gets an empty process
    # dictionary — and therefore an empty OpenTelemetry context. Without the
    # capture/restore dance in `Executor`, any span opened inside the tool's
    # `run/2` becomes a root span in a fresh trace instead of a child of the
    # caller's active span.
    defmodule CtxCapturingTool do
      @moduledoc false
      use Normandy.Tool, name: "ctx_capturing_tool", description: "Snapshots OTel ctx"

      defstruct [:reply_to]

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object", properties: %{}}

      @impl Normandy.Tool
      def run(%{reply_to: pid}, _context) do
        value = OpenTelemetry.Ctx.get_value(:normandy_test_marker, :missing)
        send(pid, {:captured_marker, value})
        {:ok, :captured}
      end
    end

    setup do
      on_exit(fn -> OpenTelemetry.Ctx.clear() end)
      :ok
    end

    test "execute_tool/2 propagates the active OTel context into the task" do
      marker = make_ref()
      OpenTelemetry.Ctx.set_value(:normandy_test_marker, marker)

      assert {:ok, :captured} =
               Executor.execute_tool(%CtxCapturingTool{reply_to: self()}, context: ctx(%{}))

      assert_receive {:captured_marker, ^marker}, 1_000
    end

    test "with no context set the tool still runs (no-op restore)" do
      assert {:ok, :captured} =
               Executor.execute_tool(%CtxCapturingTool{reply_to: self()}, context: ctx(%{}))

      assert_receive {:captured_marker, :missing}, 1_000
    end
  end
end
```

1d. Replace `test/tools/context_test.exs`:

```elixir
defmodule Normandy.Tools.ContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.{AgentMemory, ToolCall}
  alias Normandy.Test.{ContextProbe, FakeTool}
  alias Normandy.Tools.{Context, Executor}

  defp ctx(values \\ %{memory_namespace: "acme/u-1"}),
    do: %Context{tool_call_id: "c1", values: values, input: %{}}

  describe "Context.build/3" do
    test "takes ids from the config and the call, values from tool_context, and the input" do
      memory = %{AgentMemory.new_memory() | current_turn_id: "turn-1"}

      config = %{
        session_id: "s1",
        name: "agent",
        memory: memory,
        tool_context: %{memory_namespace: "acme/u-1"}
      }

      assert %Context{
               session_id: "s1",
               agent_name: "agent",
               turn_id: "turn-1",
               tool_call_id: "call-9",
               input: %{"q" => 1},
               values: %{memory_namespace: "acme/u-1"}
             } =
               Context.build(config, %ToolCall{id: "call-9", name: "probe", input: %{}}, %{
                 "q" => 1
               })
    end

    test "a partial config gives nil ids and empty values" do
      assert %Context{session_id: nil, agent_name: nil, turn_id: nil, values: %{}} =
               Context.build(%{}, %ToolCall{id: "c", name: "probe", input: %{}}, %{})
    end
  end

  describe "Executor passes the context to run/2" do
    test "the tool receives the context it was given" do
      assert {:ok, ~s(ns="acme/u-1")} =
               Executor.execute_tool(%ContextProbe{notify: self()}, context: ctx())

      assert_receive {:probe_ctx, %Context{tool_call_id: "c1"}}
    end

    test "the input reaches the tool through the context" do
      assert {:ok, "weather in Oslo"} =
               Executor.execute_tool(%FakeTool{}, context: %{ctx() | input: %{"city" => "Oslo"}})
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/tools/tool_input_isolation_test.exs test/agents/dispatch_split_test.exs test/tools/executor_test.exs test/tools/context_test.exs`
Expected: FAIL. `Normandy.Agents.Dispatch.Invocation` and `Context.build/3` are undefined;
registering a `use Normandy.Tool` struct fails in `Toolset.register/3` with
`Protocol.UndefinedError` (`Normandy.Tools.BaseTool` not implemented); `Calculator.Input`
does not exist yet.

- [ ] **Step 3: Context, executor, toolset**

3a. `lib/normandy/tools/context.ex`: replace `build/2` (its `@doc`, `@spec` and body, the end
of the file) with:

```elixir
  @doc """
  Builds the context for `call` from `config` (a `%BaseAgentConfig{}` or a partial map) and
  the call's validated `input`.
  """
  @spec build(map(), ToolCall.t(), struct() | map()) :: t()
  def build(config, %ToolCall{} = call, input) do
    memory = Map.get(config, :memory)

    %__MODULE__{
      session_id: Map.get(config, :session_id),
      agent_name: Map.get(config, :name),
      turn_id: memory && Map.get(memory, :current_turn_id),
      tool_call_id: call.id,
      input: input,
      values: Map.get(config, :tool_context) || %{}
    }
  end
```

3b. Replace `lib/normandy/tools/executor.ex` with the file below. What changes: the tool runs
through `Normandy.Tool.run/2` with the given context; the timeout is the `:timeout` option or
`default_timeout/0`, never a struct field; options are validated by `Normandy.Options`
(`:context` required); `execute/3`, `execute_parallel/3`, `execute_sequential/3`, the retry
loop and the `BaseTool`/`ContextualTool`/`Toolset` aliases go. The failure classification,
messages and OTel propagation are unchanged.

```elixir
defmodule Normandy.Tools.Executor do
  @moduledoc """
  Runs one tool call safely: `c:Normandy.Tool.run/2` in a separate task, with a timeout and
  error handling.

  - The tool gets the `%Normandy.Tools.Context{}` passed as `:context`; its `input` is the
    call's validated input.
  - Timeout: `:timeout` milliseconds, default `default_timeout/0`. The dispatch pipeline
    passes the tool's registration timeout (`Normandy.Tools.Toolset.register/3`); a
    `:timeout` field on the tool struct is never read.
  - A raise, exit, throw or timeout becomes `{:error, message}`.
  - A result that is not `{:ok, value}` or `{:error, reason}` becomes an error.

  Error messages reach the model as tool results, so an exit or throw is named
  by its tag only (its terms can carry call arguments), and an exception
  message is cut to 500 characters.
  """

  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Tool
  alias Normandy.Tools.Context

  @type execution_result :: {:ok, term()} | {:error, String.t()}
  @typedoc """
  What made a tool execution fail: the tool raised (or threw) (`:exception`),
  exited (`:exit`), ran past its timeout (`:timeout`), returned `{:error, _}`
  itself (`:tool_error`), or returned something else (`:invalid_result`).
  """
  @type error_type :: :exception | :exit | :timeout | :tool_error | :invalid_result
  @type execution_options :: [context: Context.t(), timeout: pos_integer()]

  @default_timeout 30_000

  @opts_schema NimbleOptions.new!(
                 context: [
                   type: :any,
                   required: true,
                   doc: "The call's `%Normandy.Tools.Context{}`, carrying the validated input."
                 ],
                 timeout: [
                   type: :pos_integer,
                   default: @default_timeout,
                   doc: "Milliseconds the tool may run before the call fails with a timeout."
                 ]
               )

  @doc "The timeout of a tool registered without `:timeout`, in milliseconds."
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc """
  Runs `tool` with the given context.

  ## Options

  #{Normandy.Options.docs(@opts_schema)}
  """
  @spec execute_tool(struct(), execution_options()) :: execution_result()
  def execute_tool(tool, opts \\ []) do
    opts = Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute_tool, 2})
    {result, _error_type} = run_classified(tool, opts, "execute_tool/2")
    result
  end

  @doc """
  Like `execute_tool/2`, but also says why a failed execution failed (see
  `t:error_type/0`); the error type is `nil` on success. The `{:error, message}`
  result is exactly the one `execute_tool/2` returns.
  """
  @spec execute_tool_classified(struct(), execution_options()) ::
          {{:ok, term()}, nil} | {{:error, String.t()}, error_type()}
  def execute_tool_classified(tool, opts \\ []) do
    opts =
      Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute_tool_classified, 2})

    run_classified(tool, opts, "execute_tool_classified/2")
  end

  defp run_classified(tool, opts, function) do
    context = context!(Keyword.fetch!(opts, :context), function)
    execute_with_timeout(tool, Keyword.fetch!(opts, :timeout), context)
  end

  defp context!(%Context{} = context, _function), do: context

  defp context!(other, function) do
    raise ArgumentError,
          "Normandy.Tools.Executor.#{function}: :context must be a %Normandy.Tools.Context{}, " <>
            "got: #{Describe.type_of(other)}"
  end

  defp execute_with_timeout(tool, timeout, context) do
    parent_ctx = OtelCtx.capture()

    task =
      Task.async(fn ->
        OtelCtx.restore(parent_ctx)

        try do
          tool |> Tool.run(context) |> check_result()
        rescue
          error ->
            {{:error, "Tool execution failed: #{error |> Exception.message() |> truncate()}"},
             :exception}
        catch
          :exit, reason ->
            {{:error, "Tool execution exited: #{describe_reason(reason)}"}, :exit}

          kind, reason ->
            {{:error, "Tool execution failed (#{kind}): #{describe_reason(reason)}"}, :exception}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, classified} ->
        classified

      nil ->
        {{:error, "Tool execution timeout after #{timeout}ms"}, :timeout}
    end
  end

  defp check_result({:ok, _value} = ok), do: {ok, nil}
  defp check_result({:error, _reason} = error), do: {error, :tool_error}

  defp check_result(other) do
    {{:error,
      "Tool returned an invalid result: expected {:ok, value} or {:error, reason}, got " <>
        Describe.type_of(other)}, :invalid_result}
  end

  defp describe_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: inspect(elem(reason, 0))

  defp describe_reason(reason) when is_atom(reason), do: inspect(reason)
  defp describe_reason(reason), do: Describe.type_of(reason)

  # Characters, not bytes, so a multibyte character is never cut in half.
  @max_message 500
  defp truncate(message) do
    if String.length(message) <= @max_message,
      do: message,
      else: String.slice(message, 0, @max_message) <> "..."
  end
end
```

3c. `lib/normandy/tools/toolset.ex`:
- Replace `alias Normandy.Tools.BaseTool`, the `@type t` and `defstruct` with:

```elixir
  alias Normandy.Schema.Introspection
  alias Normandy.Tool

  @type t :: %__MODULE__{
          tools: %{String.t() => struct()},
          timeouts: %{String.t() => pos_integer()}
        }

  defstruct tools: %{}, timeouts: %{}
```

- In `@register_schema`, add before `replace:`:

```elixir
                     timeout: [
                       type: :pos_integer,
                       doc:
                         "Milliseconds a call to this tool may run before it fails with a timeout. " <>
                           "Without it, `Normandy.Tools.Executor.default_timeout/0` (30_000)."
                     ],
```

- In `register/3`: the head becomes
  `def register(%__MODULE__{tools: tools, timeouts: timeouts} = toolset, tool, opts \\ []) do`,
  `tool_name = BaseTool.tool_name(tool)` becomes `tool_name = Tool.name(tool)`, and the last
  line `%{toolset | tools: Map.put(tools, tool_name, tool)}` becomes:

```elixir
    timeouts =
      case Keyword.fetch(opts, :timeout) do
        {:ok, timeout} -> Map.put(timeouts, tool_name, timeout)
        :error -> Map.delete(timeouts, tool_name)
      end

    %{toolset | tools: Map.put(tools, tool_name, tool), timeouts: timeouts}
  end

  @doc """
  The `:timeout` `tool_name` was registered with, or `nil` when it was registered without
  one (or is not registered).
  """
  @spec timeout(t(), String.t()) :: pos_integer() | nil
  def timeout(%__MODULE__{timeouts: timeouts}, tool_name), do: Map.get(timeouts, tool_name)
```

- `unregister/2` drops the timeout too:

```elixir
  def unregister(%__MODULE__{tools: tools, timeouts: timeouts} = toolset, tool_name) do
    %{toolset | tools: Map.delete(tools, tool_name), timeouts: Map.delete(timeouts, tool_name)}
  end
```

- Rewrite rule for the rest of the file (7 sites at `95dc149`): `BaseTool.tool_name(tool)` →
  `Tool.name(tool)`, `BaseTool.tool_description(tool)` → `Tool.description(tool)`,
  `BaseTool.input_schema(tool)` → `Tool.input_schema(tool)`.
- Replace `get_schema_introspection/1` (it introspected the tool struct's own module, which
  was the input schema under `SchemaBaseTool`) with:

```elixir
  # Field introspection for a tool that declared `input: Schema`; nil for a tool with a
  # hand-written input_schema/1 map.
  defp get_schema_introspection(%module{}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__tool_input__, 0) do
      input = module.__tool_input__()
      required_fields = Introspection.get_required_fields(input)

      Enum.map(Introspection.list_fields(input), fn field_name ->
        %{
          name: field_name,
          type: Introspection.get_field_type(input, field_name),
          required: field_name in required_fields,
          metadata: Introspection.get_field_metadata(input, field_name)
        }
      end)
    end
  end
```

- [ ] **Step 4: The dispatcher and its three callers**

4a. `lib/normandy/agents/dispatch.ex`, in order:

- Moduledoc: the first paragraph's pipeline becomes "toolset lookup → before-hooks → input
  validation → policy check → budget pre-check → execute → budget record → after-hooks"; the
  second paragraph becomes:

```elixir
  The pipeline is also exposed as two composable halves: `classify/3` (toolset lookup →
  before-hooks → input validation → policy, producing a verdict with no side effects) and
  `execute/4` (budget → execute → record → after, running an already-classified call).
  `dispatch_one/3` is exactly `classify ➞ execute`; a durable shell consults
  `classify/3` to park a `:needs_approval` call before any side effect runs, and runs an
  approved one with `execute_approved/3`.

  ## Input

  The model's input is validated against the tool's input schema
  (`Normandy.Tools.Input.validate/2`) after the before-hooks, so a hook's rewrite is what is
  checked. The validated input travels in an `Invocation` beside the registered tool, and
  reaches the tool as `context.input`; the tool struct is never changed. Invalid input (an
  unknown key, a missing required key, a wrong type) answers the call with an `is_error`
  result naming the keys, and the turn goes on.
```

  and the `## \`execute_fn\`` section becomes:

```elixir
  ## `policy_fn` and `execute_fn`

  `policy_fn` is called as `(config, tool_call, invocation)`. `execute_fn` is called as
  `(config, invocation, tool_name)` when it has arity 3, or
  `(config, invocation, tool_name, tool_call)` when it has arity 4; `executor_opts/3` builds
  the `Normandy.Tools.Executor` options (context with the input, registration timeout) from
  them.
```

- Aliases: add `alias Normandy.Tools.Input` (between `Executor` and `Toolset`).
- Before `defmodule Pipeline`, add:

```elixir
  defmodule Invocation do
    @moduledoc """
    A tool call ready to run: the tool as registered (never changed by the call), the
    model's input validated against the tool's input schema, and the call's timeout (the
    tool's registration `:timeout`, else `Normandy.Tools.Executor.default_timeout/0`).
    """
    @enforce_keys [:tool, :input, :timeout]
    defstruct [:tool, :input, :timeout]

    @type t :: %__MODULE__{tool: struct(), input: struct() | map(), timeout: pos_integer()}
  end
```

- In `Pipeline`'s `@type t`, `execute_fn:` becomes:

```elixir
            execute_fn:
              (map(), Normandy.Agents.Dispatch.Invocation.t(), String.t() ->
                 Executor.execution_result())
              | (map(), Normandy.Agents.Dispatch.Invocation.t(), String.t(), ToolCall.t() ->
                   Executor.execution_result()),
```

- `default_pipeline/0`: the doc's first sentence ends "passing the call's
  `%Normandy.Tools.Context{}` (with the validated input) and timeout."; its `execute_fn`:

```elixir
      execute_fn: fn config, invocation, _name, call ->
        Executor.execute_tool(invocation.tool, executor_opts(config, invocation, call))
      end,
```

- Delete `prepare_tool/2`, `validate_input/2` and `atomize_known_keys/2` (from
  `@doc """\n  Builds the tool struct from LLM-supplied input.` down to just before
  `@doc """\n  Classifies one tool call:`) and put in their place:

```elixir
  @doc """
  The `Normandy.Tools.Executor` options for `invocation`: the call's
  `%Normandy.Tools.Context{}` carrying the validated input, and the invocation's timeout.
  """
  @spec executor_opts(map(), Invocation.t(), ToolCall.t()) :: keyword()
  def executor_opts(config, %Invocation{} = invocation, %ToolCall{} = call),
    do: [context: Context.build(config, call, invocation.input), timeout: invocation.timeout]
```

- `classify/3`'s `@doc`: "Classifies one tool call: toolset lookup → before-hooks → input
  validation → policy." and its verdict bullets and `@spec`:

```elixir
    * `{:execute, %Invocation{}, call}` — allowed; `call` is the post-before-hook
      `%ToolCall{}` (hooks may have rewritten it).
    * `{:deny, %ToolResult{}}` — a toolset miss, input that is not an object or fails
      validation, a before-hook `:halt`, or a policy `:deny`, already shaped into the
      error/denial result.
    * `{:needs_approval, %Invocation{}, call, info}` — policy wants human approval.
  """
  @spec classify(map(), ToolCall.t() | map(), Pipeline.t()) ::
          {:execute, Invocation.t(), ToolCall.t()}
          | {:deny, ToolResult.t()}
          | {:needs_approval, Invocation.t(), ToolCall.t(), map()}
```

  (this also drops the duplicated `{:needs_approval, ...}` bullet, research §0.6).
- Replace `route/3` (with its `credo:disable` line) with:

```elixir
  defp route(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case fetch_tool(config, call.name) do
      {:ok, _tool} when not is_map(call.input) ->
        {:deny, invalid_input_result(call)}

      {:ok, tool} ->
        # A hook may change a call's input, not which call it is: the result must
        # answer the model's tool_use id, and both shells order results by it.
        case run_before_hooks(config, call, pipeline.before_hooks) do
          {:halt, %ToolResult{} = result} ->
            emit_denied(config, call, :hook_halt)
            {:deny, %{result | tool_call_id: call.id}}

          {:cont, hooked} ->
            validate_and_decide(pipeline, config, tool, %{hooked | id: call.id})
        end

      :error ->
        {:deny, not_found_result(call)}
    end
  end

  defp validate_and_decide(pipeline, config, tool, call) do
    with {:ok, invocation} <- invocation(config, tool, call),
         do: decide(pipeline, config, call, invocation)
  end

  defp decide(pipeline, config, call, invocation) do
    case apply_policy(pipeline, config, call, invocation) do
      {:allow, _meta} -> {:execute, invocation, call}
      {:deny, info} -> {:deny, policy_denial(config, call, info, false)}
      {:needs_approval, info} -> {:needs_approval, invocation, call, info}
    end
  end

  defp fetch_tool(%{toolset: %Toolset{} = toolset}, name), do: Toolset.fetch(toolset, name)
  defp fetch_tool(_config, _name), do: :error

  # The validated input and the registration timeout, beside the tool as registered.
  defp invocation(config, tool, %ToolCall{} = call) do
    case Input.validate(tool, call.input) do
      {:ok, input} ->
        {:ok, %Invocation{tool: tool, input: input, timeout: timeout(config, call.name)}}

      {:error, errors} ->
        {:deny, validation_error_result(call, errors)}
    end
  end

  defp timeout(%{toolset: toolset}, name) do
    case Toolset.timeout(toolset, name) do
      nil -> Executor.default_timeout()
      timeout -> timeout
    end
  end
```

- `execute/4`'s `@doc` says `{:execute, invocation, call}`; its head and `@spec`:

```elixir
  @spec execute(map(), Invocation.t(), ToolCall.t(), Pipeline.t()) :: ToolResult.t()
  def execute(config, %Invocation{} = invocation, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case pipeline.budget_check_fn.(config, call) do
      :ok ->
        result = execute_and_wrap(config, call, invocation, pipeline.execute_fn)
```

- After `execute/4`, add:

```elixir
  @doc """
  Executes a call a human approved (a `:needs_approval` verdict a durable shell parked):
  looks the tool up again and validates the parked call's input again (both are
  deterministic), then runs `execute/4`. Policy is not consulted again: it would park the
  call again. A tool no longer registered, or input that no longer validates, answers the
  call with the same result `classify/3` would give, through the `after_tool` slot.
  """
  @spec execute_approved(map(), ToolCall.t(), Pipeline.t()) :: ToolResult.t()
  def execute_approved(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    with {:ok, tool} <- fetch_tool(config, call.name),
         {:ok, invocation} <- invocation(config, tool, call) do
      execute(config, invocation, call, pipeline)
    else
      :error -> answer(config, call, not_found_result(call), pipeline)
      {:deny, %ToolResult{} = result} -> answer(config, call, result, pipeline)
    end
  end
```

- Rename `prepared` to `invocation` in `dispatch_one/3` (`{:execute, invocation, call}`,
  `{:needs_approval, _invocation, call, info}`), `execute_and_wrap/4`, both
  `call_execute_fn/4` clauses and `apply_policy/4` (`pipeline.policy_fn.(config, call, invocation)`).
  Keep the body of `execute_and_wrap/4` otherwise as Task 3.3a left it: it still routes
  `{:ok, result}` through `wrap_output/2` and `{:error, error}` through `wrap_error/2`, and
  `wrap_output/2`, `wrap_error/2` and `unencodable/1` stay unchanged. They turn a tool output
  JSON cannot express into an `is_error: true` result before it reaches memory (Task 3.3a;
  `tool_result.ex` no longer falls back to `inspect/1`). Step 7k keeps their tests running.
- `validation_error_result/2`'s `error:` becomes
  `"invalid input for #{call.name}: #{Input.message(errors)}; the tool was not run",`.
- Delete `normalize_tool_field_key/2` (all three clauses and the comment above them) and
  `exports?/3` with its comment. Keep `normalize_tool_input/1` as Task 3.3 left it.

4b. `lib/normandy/behaviours/config.ex`: replace `alias Normandy.Tools.Context` with
`alias Normandy.Agents.Dispatch` and `alias Normandy.Agents.Dispatch.Invocation` (keep the
aliases sorted: they go above `alias Normandy.Agents.Dispatch.Pipeline`), and in
`to_pipeline/1`:

```elixir
      policy_fn: fn config, call, %Invocation{tool: tool, input: input} ->
        policy_mod.check(call, %{config: config, tool: tool, input: input, opts: policy_opts})
      end,
```

```elixir
      execute_fn: fn config, invocation, _name, call ->
        Executor.execute_tool(invocation.tool, Dispatch.executor_opts(config, invocation, call))
      end
```

4c. `lib/normandy/behaviours/policy_engine.ex` moduledoc: replace "`check/2` returns one of:"
with:

```elixir
  `check/2` gets the `%ToolCall{}` and a ctx map: `config` (the agent config), `tool` (the
  tool struct as registered; the model's input is never merged into it), `input` (the
  model's input after `Normandy.Tools.Input.validate/2`: the tool's input-schema struct, or
  a string-keyed map) and `opts` (the policy ref's opts). It returns one of:
```

4d. `lib/normandy/agents/base_agent.ex`: delete `alias Normandy.Tools.Context` (now unused)
and replace `span_execute/4` (lines ~1804-1818) with:

```elixir
  defp span_execute(config, %Dispatch.Invocation{} = invocation, tool_name, %ToolCall{} = call) do
    tool_meta = Metadata.tool(config, call, invocation.tool)

    with_tool_execute_span(config, tool_name, tool_meta, fn ->
      {r, error_type} =
        Executor.execute_tool_classified(
          invocation.tool,
          Dispatch.executor_opts(config, invocation, call)
        )

      stop_meta =
        case error_type do
          nil -> Map.put(tool_meta, :status, elem(r, 0))
          type -> Map.merge(tool_meta, %{status: elem(r, 0), error_type: type})
        end

      {r, stop_meta}
    end)
  end
```

4e. `lib/normandy/agents/turn/server.ex`: in `dispatch/2`, rename `prepared` to `invocation`
(the `runnable` comprehension and the `Task.async_stream` function; the verdict shapes are
unchanged); in `execute_approved/2` replace the comment and the three lines that fetched the
tool, called `Dispatch.prepare_tool/2` and ran `Dispatch.execute/4` with:

```elixir
  # Run already-approved calls through Dispatch.execute_approved/3 (toolset lookup and
  # input validation again, deterministic, no policy). NOT re-classify — re-running
  # policy would re-park. Concurrency mirrors dispatch/2.
```

```elixir
      fn %ToolCall{} = call ->
        OtelCtx.restore(parent_ctx)
        Dispatch.execute_approved(config, call, pipeline)
      end,
```

(A parked call whose tool is no longer in the toolset now gets the not-found result instead
of crashing the server on `{:ok, tool} = ...`.)

4f. `lib/normandy/telemetry/metadata.ex`: `alias Normandy.Tools.BaseTool` →
`alias Normandy.Tool`; `tool/3`'s doc ("run by `tool` (the tool as registered)"), parameter
`prepared` → `tool` (3 uses), and:

```elixir
  # Runs before the tool, outside the Executor's protection, so it must never
  # fail the call: a raising description/1 just leaves the key out.
  defp tool_description(tool) do
    Tool.description(tool)
  rescue
    _ -> nil
  catch
    _kind, _value -> nil
  end
```

- [ ] **Step 5: Built-in tools; delete the 1.x contracts**

5a. `lib/normandy/tools/memory.ex`:
- After the moduledoc: `use Normandy.Tool, name: "memory"` (above the aliases).
- `defstruct` and `@type t`: delete `command: nil` / `command: map() | nil`.
- Replace `prepare_input/2` and `run/2` (old lines 121-151) with:

```elixir
  @doc false
  # The command fields of a call's input, atom-keyed for Commands. Dispatch hands run/2 the
  # input Normandy.Tools.Input validated (string keys); a string key beats an atom one.
  @spec command(map()) :: map()
  def command(input) when is_map(input),
    do: Map.new(@fields, &{&1, Map.get(input, Atom.to_string(&1), Map.get(input, &1))})

  @impl Normandy.Tool
  @spec run(t(), Context.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%__MODULE__{} = tool, %Context{input: input} = ctx) do
    namespace = namespace!(tool, ctx)
    cmd = command(input)
    meta = telemetry_metadata(tool, cmd, namespace)

    Span.span([:normandy, :memory, :command], meta, fn ->
      # :start can only name the session namespace; by :stop the path has been resolved,
      # so a mounted path reports the mount's namespace.
      stop_meta = stop_namespace(meta, tool, cmd, namespace)

      case Commands.run(tool, cmd, namespace) do
        {:ok, text, stats} ->
          {{:ok, text}, measurements(stats), Map.put(stop_meta, :status, :ok)}

        {:error, type, text} ->
          {{:error, text}, measurements(%{}),
           Map.merge(stop_meta, %{status: :error, error_type: type})}
      end
    end)
  end
```

- `def input_schema do` becomes `@impl Normandy.Tool` + `def input_schema(_tool) do` (drop its
  `@doc false`); `description/1` gets `@impl Normandy.Tool` instead of `@doc false`.
- `telemetry_metadata/2` and `stop_namespace/3` become:

```elixir
  defp telemetry_metadata(%__MODULE__{store: {mod, _}} = tool, cmd, namespace) do
    # only a known name reaches telemetry: the model's raw value would be unbounded
    base = %{command: if(cmd.command in @commands, do: cmd.command), store: mod}

    if tool.telemetry_include_paths,
      do: Map.merge(base, %{namespace: namespace, path: cmd.path || cmd.old_path}),
      else: base
  end

  defp stop_namespace(%{namespace: _} = meta, tool, cmd, session_ns),
    do: %{meta | namespace: Commands.namespace(tool, cmd, session_ns)}

  defp stop_namespace(meta, _tool, _cmd, _session_ns), do: meta
```

- Delete both `defimpl` blocks at the end (old lines 306-321).

5b. `lib/normandy/tools/memory/commands.ex`: the command map becomes an argument.

```elixir
  @spec namespace(Memory.t(), map(), String.t()) :: String.t()
  def namespace(%Memory{} = tool, cmd, ns) do
```

(delete the `namespace(%Memory{command: nil}, ns)` clause: `Map.get(cmd, :path)` is nil for a
command-less map and falls to `ns` already), the comment above it says `run/3`, and:

```elixir
  def run(%Memory{}, %{command: nil}, _ns),
    do: {:error, :invalid_input, "Error: no memory command was given"}

  def run(%Memory{} = tool, cmd, ns) do
```

5c. `lib/normandy/a2a/agent_tool.ex`:
- Moduledoc: "Wraps a remote A2A agent as a `Normandy.Tool`." and the example:

```elixir
      tool = AgentTool.new("https://agent.example.com/a2a", card, auth_token: "bearer-token")

      agent = BaseAgent.register_tool(agent, tool, timeout: 60_000)

  The tool polls a remote task until it ends; the registration `:timeout` (default
  `Normandy.Tools.Executor.default_timeout/0`, 30 s) bounds the whole call, so give a
  remote agent that works for minutes a longer one.
```

- Replace `@default_timeout 60_000` with `use Normandy.Tool` (above the aliases) and add
  `alias Normandy.Tools.Context`.
- `@type t` and `defstruct`: delete `timeout` and `input`.
- `new/3`: the `- \`:timeout\`` doc line becomes the paragraph "The call's timeout is a
  registration option: `BaseAgent.register_tool(agent, tool, timeout: ms)`. Passing `:timeout`
  here raises `ArgumentError`."; the body starts with the check below and no longer sets
  `timeout:`.

```elixir
    if Keyword.has_key?(opts, :timeout) do
      raise ArgumentError,
            "Normandy.A2A.AgentTool.new/3: :timeout is a registration option in 2.0; pass it " <>
              "to BaseAgent.register_tool/3 or Normandy.Tools.Toolset.register/3"
    end
```

- Delete `prepare_input/2`.
- `poll_for_result/4`: its first lines become

```elixir
  @doc false
  # `deadline` is a monotonic time in ms, or :infinity when the executor's timeout is the
  # only bound (run/2).
  def poll_for_result(endpoint, task_id, opts, deadline) do
    if deadline != :infinity and System.monotonic_time(:millisecond) >= deadline do
```

- Replace the `defimpl Normandy.Tools.BaseTool` block with:

```elixir
  @impl Normandy.Tool
  def name(%__MODULE__{agent_card: card, skill_id: nil}),
    do: "a2a__#{sanitize_name(card.name)}"

  def name(%__MODULE__{agent_card: card, skill_id: skill_id}),
    do: "a2a__#{sanitize_name(card.name)}__#{sanitize_name(skill_id)}"

  @impl Normandy.Tool
  def description(%__MODULE__{agent_card: card, skill_id: nil}),
    do: "Remote A2A agent: #{card.description}"

  def description(%__MODULE__{agent_card: card, skill_id: skill_id}) do
    case Enum.find(card.skills, fn s -> s.id == skill_id end) do
      nil -> "Remote A2A agent: #{card.description} (skill: #{skill_id})"
      skill -> "#{card.name} - #{skill.description}"
    end
  end

  @impl Normandy.Tool
  def input_schema(_tool) do
    %{
      "type" => "object",
      "properties" => %{
        "message" => %{
          "type" => "string",
          "description" => "Message to send to the remote agent"
        }
      },
      "required" => ["message"]
    }
  end

  @impl Normandy.Tool
  def run(%__MODULE__{} = tool, %Context{input: %{"message" => message_text}}) do
    message = Message.new(:user, [Part.text(message_text)])

    opts =
      tool.transport_opts
      |> Keyword.merge(if(tool.auth_token, do: [auth_token: tool.auth_token], else: []))
      |> put_trace_headers()

    case Client.send_message(tool.endpoint, message, opts) do
      {:ok, %Claudio.A2A.Task{} = task} ->
        if Claudio.A2A.Task.terminal?(task),
          do: extract_task_result(task),
          else: poll_for_result(tool.endpoint, task.id, opts, :infinity)

      {:ok, %Claudio.A2A.Message{} = response_msg} ->
        {:ok, Enum.map_join(response_msg.parts, "\n", fn part -> Map.get(part, :text, "") end)}

      {:error, reason} ->
        {:error, "A2A request failed: #{inspect(reason)}"}
    end
  end
```

5d. `lib/normandy/mcp/tool_wrapper.ex`: moduledoc first line "Wraps an MCP tool as a
`Normandy.Tool`."; replace the `@type`/`defstruct` with:

```elixir
  use Normandy.Tool

  alias Normandy.Tools.Context

  @type t :: %__MODULE__{
          adapter: module(),
          client: term(),
          tool: Claudio.MCP.Client.Tool.t(),
          prefix: String.t() | nil
        }

  defstruct [:adapter, :client, :tool, :prefix]
```

and replace `prepare_input/2` and the `defimpl` block with:

```elixir
  @impl Normandy.Tool
  def name(%__MODULE__{tool: tool, prefix: nil}), do: tool.name
  def name(%__MODULE__{tool: tool, prefix: prefix}), do: "#{prefix}__#{tool.name}"

  @impl Normandy.Tool
  def description(%__MODULE__{tool: %{description: nil} = tool}), do: "MCP tool: #{tool.name}"
  def description(%__MODULE__{tool: tool}), do: tool.description

  # The server's JSON Schema. Normandy.Tools.Input checks required keys, unknown keys and
  # basic types against it before run/2; a schema without `properties` accepts any keys
  # (decision 18), one with `properties` only those unless it sets `additionalProperties`.
  @impl Normandy.Tool
  def input_schema(%__MODULE__{tool: tool}), do: tool.input_schema

  @impl Normandy.Tool
  def run(%__MODULE__{adapter: adapter, client: client, tool: tool}, %Context{input: input}) do
    case adapter.call_tool(client, tool.name, input, []) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "MCP tool '#{tool.name}' failed: #{inspect(reason)}"}
    end
  end
```

5e. `lib/normandy/a2a/registry.ex`, `lib/normandy/mcp/registry.ex`, `lib/normandy/a2a/server.ex`:
`alias Normandy.Tools.BaseTool` → `alias Normandy.Tool`; `BaseTool.tool_name(` → `Tool.name(`,
`BaseTool.tool_description(` → `Tool.description(` (5 sites). In `A2A.Registry` also:

```elixir
    - `:timeout` - each tool's registration timeout, in ms (`Normandy.Tools.Toolset.register/3`;
      default 60_000, as in 1.x)
```

`register_all(tools, registry)` in `discover_and_register/3` becomes
`register_all(tools, registry, timeout: Keyword.get(opts, :timeout, 60_000))`;
`from_agent_card/3` takes `Keyword.take(opts, [:auth_token, :transport_opts])`;
`defp register_all(tools, registry, register_opts)` registers with
`Toolset.register(reg, tool, register_opts)`.

5f. Delete the 1.x contracts and fix the docs group and the dialyzer comment:

```bash
git rm lib/normandy/tools/base_tool.ex lib/normandy/tools/schema_base_tool.ex lib/normandy/tools/contextual_tool.ex
```

`mix.exs`, `Tools:` group:

```elixir
          Tools: [
            Normandy.Tool,
            Normandy.Tools.Toolset,
            Normandy.Tools.Context,
            Normandy.Tools.Input,
            Normandy.Tools.Executor
          ],
```

`.dialyzer_ignore.exs`: the comment above `{"lib/normandy/tools/executor.ex", :pattern_match_cov}`
says "`Normandy.Tool.run/2`'s spec allows only ..." instead of "`BaseTool.run/1`'s spec ...".
(The rehearsal's `mix dialyzer` still uses the entry: 30 skipped, 0 unnecessary.)

Run: `mix compile --warnings-as-errors 2>&1 | tail -3` (the dev env compiles `lib` only, not
`test/support`). Expected: compiles with no warning.

- [ ] **Step 6: Test support tools**

6a. Example-struct literals. The four example tools no longer have input fields, so a literal
such as `%Calculator{operation: "add", a: 0, b: 0}` no longer compiles. Every test that only
registers or lists them gets the bare struct (14 files at `95dc149` once Task 3.3 has moved
the tools: the agent, toolset, telemetry, integration tests and the two integration helpers;
`executor_test.exs`, `examples_test.exs` and the deleted `schema_base_tool_test.exs` are
rewritten instead):

```bash
grep -rlE "%(Normandy\.Tools\.Examples\.)?(Calculator|EnhancedCalculator|StringManipulator|ListProcessor|Weather)\{" test \
  | grep -vE "test/tools/(executor|examples|schema_base_tool)_test.exs" \
  | xargs perl -0777 -pi -e 's/%((?:Normandy\.Tools\.Examples\.)?(?:Calculator|EnhancedCalculator|StringManipulator|ListProcessor|Weather))\{[^}]*\}/%$1\{\}/g'
```

(`-0777` because the helpers' literals span lines. If Task 3.3 removed `Weather` from the
helpers, the `Weather` alternative simply matches nothing.)

6b. Replace the four example tools Task 3.3 moved:

`test/support/tools/calculator.ex`:

```elixir
defmodule Normandy.Tools.Examples.Calculator do
  @moduledoc """
  A test tool: adds, subtracts, multiplies or divides two numbers. Its input is
  `Normandy.Tools.Examples.Calculator.Input` (types are checked, not coerced: `a: "5"` is
  rejected before `run/2`).
  """

  defmodule Input do
    @moduledoc false
    use Normandy.Schema

    io_schema "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers" do
      field(:operation, :string,
        required: true,
        enum: ["add", "subtract", "multiply", "divide"],
        description: "The arithmetic operation to perform"
      )

      field(:a, :float, required: true, description: "The first number (operand)")
      field(:b, :float, required: true, description: "The second number (operand)")
    end
  end

  use Normandy.Tool,
    name: "calculator",
    description:
      "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers",
    input: Input

  alias Normandy.Tools.Context

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Context{input: %Input{} = input}), do: calculate(input)

  defp calculate(%Input{operation: "add", a: a, b: b}), do: {:ok, to_float(a) + to_float(b)}
  defp calculate(%Input{operation: "subtract", a: a, b: b}), do: {:ok, to_float(a) - to_float(b)}
  defp calculate(%Input{operation: "multiply", a: a, b: b}), do: {:ok, to_float(a) * to_float(b)}

  defp calculate(%Input{operation: "divide", b: b}) when b == 0 or b == 0.0,
    do: {:error, "Cannot divide by zero"}

  defp calculate(%Input{operation: "divide", a: a, b: b}), do: {:ok, to_float(a) / to_float(b)}
  defp calculate(%Input{operation: operation}), do: {:error, "Unknown operation: #{operation}"}

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
end
```

`test/support/tools/enhanced_calculator.ex`:

```elixir
defmodule Normandy.Tools.Examples.EnhancedCalculator do
  @moduledoc """
  A test tool: `Normandy.Tools.Examples.Calculator` with a `precision` input (decimal places
  of the result, default 2, 0 to 10).
  """

  defmodule Input do
    @moduledoc false
    use Normandy.Schema

    io_schema "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers with validation" do
      field(:operation, :string,
        required: true,
        enum: ["add", "subtract", "multiply", "divide"],
        description: "The arithmetic operation to perform"
      )

      field(:a, :float, required: true, description: "The first number (operand)")
      field(:b, :float, required: true, description: "The second number (operand)")

      field(:precision, :integer,
        description: "Number of decimal places in result",
        default: 2,
        minimum: 0,
        maximum: 10
      )
    end
  end

  use Normandy.Tool,
    name: "enhanced_calculator",
    description:
      "Performs basic arithmetic operations (add, subtract, multiply, divide) on two numbers with validation",
    input: Input

  alias Normandy.Tools.Context

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Context{input: %Input{} = input}), do: calculate(input)

  defp calculate(%Input{operation: "divide", b: b}) when b == 0 or b == 0.0,
    do: {:error, "Cannot divide by zero"}

  defp calculate(%Input{operation: operation, a: a, b: b, precision: precision}) do
    result =
      case operation do
        "add" -> to_float(a) + to_float(b)
        "subtract" -> to_float(a) - to_float(b)
        "multiply" -> to_float(a) * to_float(b)
        "divide" -> to_float(a) / to_float(b)
      end

    {:ok, Float.round(result, precision)}
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
end
```

`test/support/tools/list_processor.ex`:

```elixir
defmodule Normandy.Tools.Examples.ListProcessor do
  @moduledoc """
  A test tool with a hand-written input schema: sum, average, min, max, sort or count a list
  of numbers. `run/2` gets the validated input as a string-keyed map.
  """
  use Normandy.Tool,
    name: "list_processor",
    description: "Performs operations on lists of numbers: sum, average, min, max, sort, count"

  alias Normandy.Tools.Context

  defstruct []

  @impl Normandy.Tool
  def input_schema(_tool) do
    %{
      type: "object",
      properties: %{
        operation: %{
          type: "string",
          enum: ["sum", "average", "min", "max", "sort_asc", "sort_desc", "count"],
          description: "The list operation to perform"
        },
        numbers: %{
          type: "array",
          items: %{type: "number"},
          description: "The list of numbers to process"
        }
      },
      required: ["operation", "numbers"]
    }
  end

  @impl Normandy.Tool
  def run(_tool, %Context{input: %{"operation" => operation, "numbers" => numbers}}),
    do: process(operation, numbers)

  defp process("sum", numbers), do: {:ok, Enum.sum(numbers)}
  defp process("average", []), do: {:error, "Cannot calculate average of empty list"}
  defp process("average", numbers), do: {:ok, Enum.sum(numbers) / length(numbers)}
  defp process("min", []), do: {:error, "Cannot find minimum of empty list"}
  defp process("min", numbers), do: {:ok, Enum.min(numbers)}
  defp process("max", []), do: {:error, "Cannot find maximum of empty list"}
  defp process("max", numbers), do: {:ok, Enum.max(numbers)}
  defp process("sort_asc", numbers), do: {:ok, Enum.sort(numbers)}
  defp process("sort_desc", numbers), do: {:ok, Enum.sort(numbers, :desc)}
  defp process("count", numbers), do: {:ok, length(numbers)}
  defp process(operation, _numbers), do: {:error, "Unknown operation: #{operation}"}
end
```

`test/support/tools/string_manipulator.ex`:

```elixir
defmodule Normandy.Tools.Examples.StringManipulator do
  @moduledoc """
  A test tool with a hand-written input schema: uppercase, lowercase, reverse, split,
  truncate or measure a string. `run/2` gets the validated input as a string-keyed map.
  """
  use Normandy.Tool,
    name: "string_manipulator",
    description:
      "Performs various string manipulation operations like uppercase, lowercase, reverse, split, truncate, etc."

  alias Normandy.Tools.Context

  defstruct []

  @impl Normandy.Tool
  def input_schema(_tool) do
    %{
      type: "object",
      properties: %{
        operation: %{
          type: "string",
          enum: ["uppercase", "lowercase", "reverse", "split", "truncate", "length"],
          description: "The string operation to perform"
        },
        text: %{type: "string", description: "The input text to manipulate"},
        delimiter: %{type: "string", description: "Delimiter for split operation (optional)"},
        count: %{
          type: "integer",
          description: "Number of characters for truncate operation (optional)"
        }
      },
      required: ["operation", "text"]
    }
  end

  @impl Normandy.Tool
  def run(_tool, %Context{input: %{"operation" => operation, "text" => text} = input}),
    do: process(operation, text, input)

  defp process("uppercase", text, _input), do: {:ok, String.upcase(text)}
  defp process("lowercase", text, _input), do: {:ok, String.downcase(text)}
  defp process("reverse", text, _input), do: {:ok, String.reverse(text)}

  defp process("split", text, %{"delimiter" => delimiter}),
    do: {:ok, String.split(text, delimiter)}

  defp process("split", text, _input), do: {:ok, String.split(text)}
  defp process("truncate", text, %{"count" => count}), do: {:ok, String.slice(text, 0, count)}

  defp process("truncate", _text, _input),
    do: {:error, "truncate operation requires 'count' parameter"}

  defp process("length", text, _input), do: {:ok, String.length(text)}
  defp process(operation, _text, _input), do: {:error, "Unknown operation: #{operation}"}
end
```

6c. `test/support/fake_tool.ex` (the schema struct with a `city` field becomes a plain struct;
`city` is input now):

```elixir
defmodule Normandy.Test.FakeTool do
  @moduledoc """
  A tool for tests. It is named by `:name` (default `"weather"`), takes an optional string
  `"city"` input, and returns `"weather in <city>"` whatever its name. With `:sleep_ms`, it
  sleeps first. With `:notify`, it sends `{:tool_ran, name}` to that pid when it runs.
  """
  use Normandy.Tool, description: "fake"

  alias Normandy.Tools.Context

  defstruct name: "weather", notify: nil, sleep_ms: 0

  @impl Normandy.Tool
  def name(%__MODULE__{name: name}), do: name

  @impl Normandy.Tool
  def input_schema(_tool), do: %{type: "object", properties: %{city: %{type: "string"}}}

  @impl Normandy.Tool
  def run(%__MODULE__{} = tool, %Context{input: input}) do
    if tool.sleep_ms > 0, do: Process.sleep(tool.sleep_ms)
    if tool.notify, do: send(tool.notify, {:tool_ran, tool.name})
    {:ok, "weather in #{input["city"]}"}
  end
end
```

6d. `test/support/context_probe.ex` (open input schema: `test/hooks/tool_hooks_test.exs`
rewrites the probe's input to `%{"redacted" => true}` and expects it to run):

```elixir
defmodule Normandy.Test.ContextProbe do
  @moduledoc """
  A tool for tests that reports its context: it sends `{:probe_ctx, ctx}` to `:notify`
  (when set) and returns `{:ok, "ns=<inspect of :memory_namespace>"}`. Its input schema is
  open (`additionalProperties: true`), so a hook may rewrite its input freely.
  """
  use Normandy.Tool, description: "context probe"

  alias Normandy.Tools.Context

  defstruct name: "probe", notify: nil

  @impl Normandy.Tool
  def name(%__MODULE__{name: name}), do: name

  @impl Normandy.Tool
  def input_schema(_tool), do: %{type: "object", properties: %{}, additionalProperties: true}

  @impl Normandy.Tool
  def run(%__MODULE__{} = tool, %Context{} = ctx) do
    if tool.notify, do: send(tool.notify, {:probe_ctx, ctx})
    {:ok, "ns=" <> inspect(Map.get(ctx.values, :memory_namespace))}
  end
end
```

6e. `test/support/lazy_tool.ex`:

```elixir
defmodule Normandy.Test.LazyToolInput do
  @moduledoc false
  # Normandy.Test.LazyTool's input schema.
  use Normandy.Schema

  io_schema "a tool whose module may not be loaded" do
    field(:operation, :string, required: true, enum: ["add"])
  end
end

defmodule Normandy.Test.LazyTool do
  @moduledoc false
  # Referenced only by Normandy.Agents.LazyModuleTest, which unloads it to act
  # like a module a fresh node has not loaded yet.
  use Normandy.Tool,
    name: "lazy_tool",
    description: "a tool whose module may not be loaded",
    input: Normandy.Test.LazyToolInput

  defstruct []

  @impl Normandy.Tool
  def run(_tool, _context), do: {:ok, "ran"}
end

defmodule Normandy.Test.LazyInput do
  @moduledoc false
  # See Normandy.Test.LazyTool.
  use Normandy.Schema

  io_schema "input whose module may not be loaded" do
    field(:query, :string, description: "query", required: true)
  end
end
```

6f. `test/support/e2e/distributed.ex`: replace `defmodule RefundTool do ... end` with:

```elixir
  defmodule RefundTool do
    @moduledoc false
    defmodule Input do
      @moduledoc false
      use Normandy.Schema

      io_schema "Issue a refund for an order. Needs human approval." do
        field(:order_id, :string, required: true, description: "the order id")
      end
    end

    use Normandy.Tool,
      name: "issue_refund",
      description: "Issue a refund for an order. Needs human approval.",
      input: Input

    alias Normandy.Tools.Context
    alias NormandyTest.E2E.Distributed

    defstruct []

    @impl Normandy.Tool
    def run(_tool, %Context{input: %Input{order_id: id}}) do
      Distributed.sink({:tool_ran, node(), id})
      {:ok, "refund issued for #{id}"}
    end
  end
```

6g. `git rm test/support/tool_mockup.ex`.

- [ ] **Step 7: Tests that define or drive tools**

7a. Delete `test/tools/base_tool_test.exs` and `test/tools/schema_base_tool_test.exs`
(`git rm`): their subjects are gone; `test/tools/tool_test.exs` and `test/tools/input_test.exs`
(Task 3.4b) cover the behaviour, the generated callbacks and the validation they tested.

7b. In-test tool modules. Rewrite rule for each `defstruct` + `defimpl Normandy.Tools.BaseTool`
module: `use Normandy.Tool, name: N, description: D` (constant name/description), keep
`defstruct`, `@impl Normandy.Tool def input_schema(_tool)`, and `run/1` becomes
`run(tool, context)` reading input from `context.input`. Exactly:

- `test/agents/base_agent_streaming_test.exs` `TestCalculator`:

```elixir
  defmodule TestCalculator do
    use Normandy.Tool, name: "calculator", description: "Performs calculations"

    defstruct []

    @impl Normandy.Tool
    def input_schema(_tool), do: %{type: "object", properties: %{}, required: []}

    @impl Normandy.Tool
    def run(_tool, _context), do: {:ok, 42}
  end
```

- `test/agents/base_agent_guardrails_test.exs` `NoopTool`:

```elixir
  defmodule NoopTool do
    use Normandy.Tool, name: "noop", description: "no-op tool used to force the tool-loop path"

    defstruct []

    @impl Normandy.Tool
    def input_schema(_tool), do: %{type: "object", properties: %{}, required: []}

    @impl Normandy.Tool
    def run(_tool, _context), do: {:ok, :noop}
  end
```

- `test/agents/base_agent_tool_loop_test.exs` `BrokenCalculator` (and its use becomes
  `broken_calc = %BrokenCalculator{}`):

```elixir
    defmodule BrokenCalculator do
      use Normandy.Tool, name: "broken_calculator", description: "A calculator that always fails"

      defstruct []

      @impl Normandy.Tool
      def input_schema(_tool), do: %{type: "object"}

      @impl Normandy.Tool
      def run(_tool, _context), do: {:error, "Calculator is broken"}
    end
```

  `SleepyTool` (the mock sends atom keys; validation turns them into strings):

```elixir
    defmodule SleepyTool do
      use Normandy.Tool, name: "sleepy", description: "Sleeps then returns its label."

      alias Normandy.Tools.Context
      alias NormandyTest.Agents.SleepyProbe

      defstruct []

      @impl Normandy.Tool
      def input_schema(_tool) do
        %{
          type: "object",
          properties: %{sleep_ms: %{type: "integer"}, label: %{type: "string"}},
          required: ["sleep_ms", "label"]
        }
      end

      @impl Normandy.Tool
      def run(_tool, %Context{input: %{"sleep_ms" => ms, "label" => label}}) do
        SleepyProbe.enter()
        :timer.sleep(ms)
        SleepyProbe.leave()
        {:ok, label}
      end
    end
```

  In the `"Tool input atom-table hardening"` describe, the comment above
  `MockHostileToolClient` becomes:

```elixir
    # Mock client that emits a tool_use whose `input` map mixes valid binary
    # keys with a canary key (one that does NOT correspond to any field of
    # the tool's input schema). This exercises the binary-key path of
    # Normandy.Tools.Input.validate/2; a 1.x helper on that path called
    # `String.to_atom/1` and could be coerced into exhausting the BEAM atom
    # table by attacker-controlled LLM input.
```

  and the canary test is renamed `"refuses unknown input keys without registering them as atoms"`,
  its closing comment becoming "If the legacy `String.to_atom/1` reducer had still been in
  place, the canary key would now be a registered atom and this call would succeed.
  Normandy.Tools.Input matches keys against the declared field names, so the unknown key is
  refused without touching the atom table." (the assertions stay: the run still answers, the
  canary is still no atom).

- `test/agents/turn_inline_test.exs`: replace `WeatherTool` and its `defimpl` with:

```elixir
  defmodule WeatherTool do
    use Normandy.Tool, name: "weather", description: "fake weather"

    defstruct []

    @impl Normandy.Tool
    def input_schema(_tool), do: %{type: "object", properties: %{city: %{type: "string"}}}

    @impl Normandy.Tool
    def run(_tool, %Normandy.Tools.Context{input: input}),
      do: {:ok, "weather in #{input["city"]}"}
  end
```

- `test/telemetry/tool_telemetry_test.exs` `RaisingDescriptionTool`:

```elixir
  defmodule RaisingDescriptionTool do
    use Normandy.Tool, name: "raising_description"

    defstruct []

    @impl Normandy.Tool
    def description(_tool), do: raise("no description")

    @impl Normandy.Tool
    def input_schema(_tool), do: %{}

    @impl Normandy.Tool
    def run(_tool, _context), do: {:ok, "ran"}
  end
```

7c. `test/tools/examples_test.exs`:

```bash
perl -pi -e 's/^(\s+)(\w+) = %(Calculator|StringManipulator|ListProcessor)\{([^}]+)\}$/$1$2 = {%$3\{\}, %\{$4\}}/; s/\bBaseTool\.run\((\w+)\)/run_tool($1)/g' test/tools/examples_test.exs
```

(26 literals and 25 `BaseTool.run` calls at `95dc149`), then replace
`alias Normandy.Tools.BaseTool` with:

```elixir
  alias Normandy.Tool
  alias Normandy.Tools.{Context, Input}
```

and add, below the aliases:

```elixir
  # What the dispatcher does: validate the input, then run the tool with it.
  defp run_tool({tool, input}) do
    case Input.validate(tool, input) do
      {:ok, validated} -> Tool.run(tool, %Context{tool_call_id: "t", input: validated})
      {:error, errors} -> {:error, Input.message(errors)}
    end
  end
```

By hand: the Calculator `"handles unknown operation"` test becomes (the enum now stops
`"power"` before the tool runs)

```elixir
    test "an operation outside the enum is refused before the tool runs" do
      tool = {%Calculator{}, %{operation: "power", a: 2, b: 3}}

      assert {:error, ~s(operation must be one of ["add", "subtract", "multiply", "divide"])} =
               run_tool(tool)
    end
```

and in `"provides correct metadata"`, `tool = %Calculator{}` and `BaseTool.tool_name` /
`tool_description` / `input_schema` → `Tool.name` / `description` / `input_schema`.

7d. `test/agents/dispatch_test.exs`: delete `FakeToolWithPrepare` and the
`describe "prepare_tool/2"` block; rename the test "a %ToolCall{} with nil input is
normalized, not crashed, before prepare_tool" to "... before validation". (Its assertion,
`output: "weather in "`, holds: `nil` input normalizes to `%{}` and FakeTool reads
`input["city"]`.)

7e. `test/agents/tool_context_test.exs`: the alias becomes `alias Normandy.Tools.{Context, Toolset}`
and the last test ("a user arity-3 execute_fn has no call, so a contextual tool returns its
error"; there is no "contextual tool" any more) becomes:

```elixir
  test "a user arity-3 execute_fn gets the invocation, without the call" do
    parent = self()
    config = %{name: "a", toolset: Toolset.new([%ContextProbe{}])}

    execute_fn = fn _config, invocation, name ->
      send(parent, {:invocation, invocation, name})
      {:ok, "ran"}
    end

    pipeline = %{Dispatch.default_pipeline() | execute_fn: execute_fn}

    assert %ToolResult{is_error: false, output: "ran"} =
             Dispatch.dispatch_one(config, probe_call(), pipeline)

    assert_received {:invocation, %Dispatch.Invocation{tool: %ContextProbe{}, input: %{}},
                     "probe"}
  end
```

7f. `test/agents/lazy_module_test.exs`: drop `Dispatch` from the `Normandy.Agents` alias, add
`alias Normandy.Tools.Input`, and the first test becomes:

```elixir
  test "Input.validate validates a tool whose module is not loaded yet" do
    tool = unloaded_struct(LazyTool, %{})

    assert {:error, [%{constraint: :enum}]} =
             Input.validate(tool, %{"operation" => "bogus"})
  end
```

7g. `test/behaviours/config_test.exs` (the `to_pipeline` default test calls `policy_fn` directly):

```elixir
      invocation = %Dispatch.Invocation{tool: %FakeTool{}, input: %{}, timeout: 30_000}
      assert p.policy_fn.(%{}, %ToolCall{name: "x"}, invocation) == {:allow, %{}}
```

7h. Memory tests.
- `test/tools/memory_test.exs`: the alias line becomes `alias Normandy.Tool` +
  `alias Normandy.Tools.{Context, Input, Memory}`; the three tests from
  `"BaseTool: name, schema, description, and run/1 without context is an error"` through
  `"prepare_input/2: atom-keyed options are ignored, ..."` are replaced by:

```elixir
  test "Normandy.Tool: name, input schema and description" do
    t = tool(mounts: %{"/memories/org" => {"acme/kb", :read_only}})
    assert Tool.name(t) == "memory"

    assert %{required: ["command"], properties: %{command: %{enum: enum}}} = Tool.input_schema(t)

    assert enum == ~w(view create str_replace insert delete rename)

    assert Tool.description(t) =~
             "ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE"

    assert Tool.description(t) =~ "/memories/org (read-only)"
  end

  test "model input naming the store, mounts or limits is refused before the tool runs (Review Focus #5)" do
    input = %{
      "command" => "view",
      "path" => "/memories",
      "store" => "evil",
      "mounts" => %{"/memories/x" => "other"},
      "max_document_bytes" => 1,
      "namespace_key" => "other"
    }

    assert {:error, [%{constraint: :unknown_keys, message: message}]} =
             Input.validate(tool(), input)

    assert message ==
             ~s(unknown keys "max_document_bytes", "mounts", "namespace_key", "store"; ) <>
               ~s(expected only "command", "file_text", "insert_line", "insert_text", ) <>
               ~s("new_path", "new_str", "old_path", "old_str", "path", "view_range")
  end

  test "command/1 takes only the command fields, string keys first" do
    cmd = Memory.command(%{"command" => "view", :command => "delete", "extra" => 1})

    assert Map.keys(cmd) |> Enum.sort() ==
             Enum.sort(
               ~w(command path view_range file_text old_str new_str insert_line insert_text old_path new_path)a
             )

    assert cmd.command == "view"
    assert cmd.file_text == nil
  end
```

  and the remaining `prepare_input` sites (5 at `95dc149`):

```elixir
  test "a missing namespace raises, naming the key and the keys present" do
    ctx = %Context{
      tool_call_id: "c",
      values: %{tenant: "acme"},
      input: %{"command" => "view", "path" => "/memories"}
    }

    assert_raise ArgumentError, ~r/tool_context\[:memory_namespace\].*\[:tenant\]/, fn ->
      Memory.run(tool(), ctx)
    end
  end
```

```elixir
    defp run_with(input) do
      Memory.run(tool(), %Context{
        tool_call_id: "c",
        values: %{memory_namespace: "acme/u"},
        input: input
      })
    end
```

```elixir
    defp call(tool, input, ns \\ "acme/u-1"),
      do:
        Memory.run(tool, %Context{
          tool_call_id: "c",
          values: %{memory_namespace: ns},
          input: input
        })
```

```elixir
    defp typed(tool, input, ns \\ "acme/u-1"),
      do: Commands.run(tool, Memory.command(input), ns)
```

  and in the backend-error test (old lines ~731-735) delete the
  `t = Memory.prepare_input(Memory.new(store: store), input)` line and assert
  `{:error, :backend, ^text} = Commands.run(Memory.new(store: store), Memory.command(input), "acme/u-1")`.
- `test/tools/memory_telemetry_test.exs` (1 site) and `test/support/memory_store_contract.ex`
  (2 sites): `Memory.run(Memory.prepare_input(tool, input), ctx)` →
  `Memory.run(tool, %{ctx | input: input})`.

7i. A2A and MCP.
- `test/a2a/agent_tool_test.exs`: `alias Normandy.Tools.BaseTool` → `alias Normandy.Tool`;
  `BaseTool.tool_name(` / `tool_description(` / `input_schema(` → `Tool.name(` /
  `Tool.description(` / `Tool.input_schema(` (6 sites); `describe "BaseTool protocol"` →
  `describe "Normandy.Tool callbacks"`; the `new/3` describe and the deleted `prepare_input/2`
  describe become:

```elixir
  describe "new/3" do
    test "creates tool with defaults", %{tool: tool} do
      assert tool.endpoint == "https://agent.example.com/a2a"
      assert tool.agent_card.name == "Research Agent"
      assert tool.skill_id == nil
      assert tool.auth_token == nil
      refute Map.has_key?(tool, :timeout)
      refute Map.has_key?(tool, :input)
    end

    test "creates tool with options", %{card: card} do
      tool =
        AgentTool.new("https://agent.example.com/a2a", card,
          skill_id: "web_search",
          auth_token: "my-token"
        )

      assert tool.skill_id == "web_search"
      assert tool.auth_token == "my-token"
    end

    test ":timeout is a registration option now", %{card: card} do
      error =
        assert_raise ArgumentError, fn ->
          AgentTool.new("https://agent.example.com/a2a", card, timeout: 30_000)
        end

      assert error.message ==
               "Normandy.A2A.AgentTool.new/3: :timeout is a registration option in 2.0; pass it " <>
                 "to BaseAgent.register_tool/3 or Normandy.Tools.Toolset.register/3"
    end
  end
```

- `test/mcp/tool_wrapper_test.exs`: aliases `alias Normandy.Tool` and `alias Normandy.Tools.Context`;
  `wrapper.input == %{}` → `refute Map.has_key?(wrapper, :input)`; delete the
  `prepare_input/2` describe; `describe "BaseTool protocol"` → `"Normandy.Tool callbacks"`;
  `BaseTool.tool_name/description/input_schema` → `Tool.name/description/input_schema`; the two
  run tests:

```elixir
    test "run succeeds with valid input", %{wrapper: wrapper} do
      context = %Context{tool_call_id: "t", input: %{"query" => "elixir"}}
      assert {:ok, "Results for: elixir"} = Tool.run(wrapper, context)
    end
```

```elixir
      wrapper = ToolWrapper.new(MockAdapter, :client, tool)

      assert {:error, msg} = Tool.run(wrapper, %Context{tool_call_id: "t", input: %{}})
```

- `test/telemetry/a2a_propagation_test.exs`: aliases `Normandy.Tool`, `Normandy.Tools.Context`;
  `agent_tool/2` no longer pipes into `prepare_input/2`, and a helper replaces the 4
  `BaseTool.run(x)` calls (`BaseTool.run(` → `run(`):

```elixir
  defp agent_tool(bypass, opts \\ []) do
    AgentTool.new(
      "http://localhost:#{bypass.port}/a2a",
      AgentCard.new("remote", "a remote agent"),
      opts
    )
  end

  defp run(tool), do: Tool.run(tool, %Context{tool_call_id: "t", input: %{"message" => "hi"}})
```

- `test/a2a/registry_test.exs`: the `"passes options through"` test stops passing and
  asserting `:timeout` (`A2ARegistry.from_agent_card(card, "https://example.com/a2a",
  auth_token: "tok")`, `assert tool.auth_token == "tok"`), and the `discover_and_register/3`
  describe gains a transport and a test:

```elixir
  defmodule OkTransport do
    def discover(_url, _opts), do: {:ok, AgentCard.new("Agent", "An agent")}
  end
```

```elixir
    test ":timeout is each tool's registration timeout; 60 s when not given" do
      opts = [transport_opts: [transport: OkTransport]]

      assert {:ok, toolset} =
               A2ARegistry.discover_and_register(
                 Toolset.new(),
                 "http://agent.test",
                 [timeout: 5_000] ++ opts
               )

      assert Toolset.timeout(toolset, "a2a__agent") == 5_000

      assert {:ok, toolset} =
               A2ARegistry.discover_and_register(Toolset.new(), "http://agent.test", opts)

      assert Toolset.timeout(toolset, "a2a__agent") == 60_000
    end
```

7j. `test/dsl/agent_memory_test.exs`: `alias Normandy.Tools.{BaseTool, Memory, Toolset}` →
`alias Normandy.Tool` + `alias Normandy.Tools.{Memory, Toolset}`; `BaseTool.tool_name(tool)` →
`Tool.name(tool)`.

7k. `test/json_struct_encoding_test.exs` (Task 3.3a; Review Focus #4). Its `execute/1` helper
calls `Dispatch.execute/4` with a tool struct; `execute/4` now takes an invocation. Replace

```elixir
    Dispatch.execute(%{name: "agent"}, %FakeTool{}, call, pipeline)
```

with

```elixir
    invocation = %Dispatch.Invocation{tool: %FakeTool{}, input: %{}, timeout: 30_000}
    Dispatch.execute(%{name: "agent"}, invocation, call, pipeline)
```

Nothing else in the file changes. Its tests "a tool output JSON cannot express becomes an
error result naming its type" and "an error reason JSON cannot express is sent as its text"
are the guard that `execute_and_wrap/4` kept Task 3.3a's `wrap_output/2` / `wrap_error/2`
checks; both must pass in Step 9:

Run: `mix test test/json_struct_encoding_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 8: e2e scenarios (not run by `mix test`)**

Same rewrite as the example tools: the `tool_schema` fields move into a nested `Input`
schema, `execute(%__MODULE__{...})` becomes `run(_tool, %Normandy.Tools.Context{input: %Input{...}})`.

`e2e/03_tool_loop.exs` — replace `E2E.S03.Calculator` and `E2E.S03.KV`:

```elixir
defmodule E2E.S03.Calculator do
  defmodule Input do
    use Normandy.Schema

    io_schema "Exact integer arithmetic. Use for every calculation." do
      field(:op, :string, required: true, enum: ["add", "multiply"], description: "operation")
      field(:a, :integer, required: true, description: "left operand")
      field(:b, :integer, required: true, description: "right operand")
    end
  end

  use Normandy.Tool,
    name: "calculator",
    description: "Exact integer arithmetic. Use for every calculation.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{op: "add", a: a, b: b}}),
    do: {:ok, Integer.to_string(a + b)}

  def run(_tool, %Normandy.Tools.Context{input: %Input{op: "multiply", a: a, b: b}}),
    do: {:ok, Integer.to_string(a * b)}
end

defmodule E2E.S03.KV do
  defmodule Input do
    use Normandy.Schema

    io_schema "A persistent key-value store. put saves a value; get reads one." do
      field(:action, :string, required: true, enum: ["get", "put"], description: "get or put")
      field(:key, :string, required: true, description: "the key")
      field(:value, :string, description: "the value (put only)")
    end
  end

  use Normandy.Tool,
    name: "kv_store",
    description: "A persistent key-value store. put saves a value; get reads one.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{action: "put", key: k, value: v}}) do
    Agent.update(E2E.S03.Store, &Map.put(&1, k, v))
    {:ok, "stored #{k}"}
  end

  def run(_tool, %Normandy.Tools.Context{input: %Input{action: "get", key: k}}) do
    case Agent.get(E2E.S03.Store, &Map.fetch(&1, k)) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, "no value for #{k}"}
    end
  end
end
```

`e2e/05_approvals.exs` — replace `E2E.S05.DeleteRecord`:

```elixir
defmodule E2E.S05.DeleteRecord do
  defmodule Input do
    use Normandy.Schema

    io_schema "Permanently delete a customer record by id." do
      field(:record_id, :string, required: true, description: "the record id")
    end
  end

  use Normandy.Tool,
    name: "delete_record",
    description: "Permanently delete a customer record by id.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{record_id: id}}) do
    Agent.update(E2E.S05.Deleted, &[id | &1])
    {:ok, "deleted #{id}"}
  end
end
```

`e2e/13_budget_policy.exs` — replace `E2E.S13.LookupPrice` and `E2E.S13.DropTable` (their
bodies after the head are unchanged):

```elixir
defmodule E2E.S13.LookupPrice do
  defmodule Input do
    use Normandy.Schema

    io_schema "Look up today's market price of one fruit, in euros per kilo." do
      field(:fruit, :string, required: true, description: "one fruit name")
    end
  end

  use Normandy.Tool,
    name: "lookup_price",
    description: "Look up today's market price of one fruit, in euros per kilo.",
    input: Input

  defstruct []

  @prices %{"apple" => "2.40", "pear" => "3.15", "plum" => "0.85"}

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{fruit: fruit}}) do
    Agent.update(E2E.S13.Looked, &[String.downcase(fruit) | &1])
    {:ok, "#{fruit}: #{Map.get(@prices, String.downcase(fruit), "unknown")} EUR/kg"}
  end
end

defmodule E2E.S13.DropTable do
  defmodule Input do
    use Normandy.Schema

    io_schema "Drop a database table." do
      field(:table, :string, required: true, description: "table name")
    end
  end

  use Normandy.Tool, name: "drop_table", description: "Drop a database table.", input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{table: t}}) do
    Agent.update(E2E.S13.Dropped, &[t | &1])
    {:ok, "dropped #{t}"}
  end
end
```

`e2e/12_mcp_a2a.exs`: `|> BaseAgent.register_tool(harbour)` →
`|> BaseAgent.register_tool(harbour, timeout: 60_000)` (1.x ran the A2A tool under its
struct's 60 s default; the executor default is 30 s).

Check (parses every scenario; the live run is Q's step, decision 4):

```bash
grep -rnE "SchemaBaseTool|tool_schema|BaseTool|ContextualTool|prepare_input" e2e   # no output
mix run --no-start -e 'for f <- Path.wildcard("e2e/*.exs"), do: f |> File.read!() |> Code.string_to_quoted!(file: f); IO.puts(:parsed)'
```

Expected: `parsed`. (The rehearsal also compiled the five rewritten tool modules on their
own: they compile.)

- [ ] **Step 9: Run to verify everything passes**

```bash
mix compile --warnings-as-errors 2>&1 | tail -3
grep -rnE "Tools\.BaseTool|BaseTool\.|SchemaBaseTool|ContextualTool|prepare_tool|normalize_tool_field_key|Dispatch\.validate_input" lib test e2e
grep -rln "prepare_input" lib test e2e
mix test test/tools/tool_input_isolation_test.exs test/agents/dispatch_split_test.exs test/tools/executor_test.exs test/tools/context_test.exs test/json_struct_encoding_test.exs
mix format && mix test 2>&1 | tail -5
mix credo --strict 2>&1 | tail -3
mix dialyzer 2>&1 | grep -E "Total errors|passed"
```

Expected: compiles; the first grep prints nothing; the second lists only
`lib/normandy/coordination/{agent_process,parallel_orchestrator,reactive,sequential_orchestrator}.ex`,
`lib/normandy/dsl/{agent,workflow}.ex` and `test/coordination/agent_process_server_test.exs`
(their `prepare_input/1` turns agent input into a chat message; unrelated to tools); the five
files PASS; ` 0 failures`; Credo finds no issues; Dialyzer passes with no unnecessary skip.

- [ ] **Step 10: MIGRATING**

Append to the "Tools: one `Normandy.Tool` behaviour" section (after its toolset table):

```markdown
### Writing a tool

`Normandy.Tools.BaseTool`, `Normandy.Tools.SchemaBaseTool` and `Normandy.Tools.ContextualTool`
are gone. A tool is a struct whose module implements `Normandy.Tool`: `name/1`,
`description/1`, `input_schema/1` and `run(tool, context)`. The struct holds configuration
only. The model's input is validated against the input schema and passed as
`context.input`; it is never merged into the struct (1.x copied any input key that matched
a struct field into the struct, including fields such as `:endpoint` or `:timeout`).

| 1.x | 2.0 |
|---|---|
| `use Normandy.Tools.SchemaBaseTool` + `tool_schema "n", "d" do fields end` | an input module (`use Normandy.Schema` + `io_schema "d" do fields end`) and `use Normandy.Tool, name: "n", description: "d", input: Input` |
| `def execute(%__MODULE__{a: a})` | `def run(_tool, %Normandy.Tools.Context{input: %Input{a: a}})` |
| `defimpl Normandy.Tools.BaseTool` with `tool_name/1`, `tool_description/1`, `input_schema/1`, `run/1` | `use Normandy.Tool` and the callbacks `name/1`, `description/1`, `input_schema/1`, `run/2` in the module |
| `run(%{field: value})` reading input from the struct | `run(tool, %Context{input: %{"field" => value}})`: with a hand-written schema the input is a string-keyed map |
| `defimpl Normandy.Tools.ContextualTool`, `run(tool, ctx)` | every tool gets the context: `run(tool, ctx)`; `ctx.values` is still `tool_context` |
| `prepare_input/2` on the tool | gone; validation is the dispatcher's |
| `Tool.validate/1`, `validate!/1` (generated) | `Normandy.Tools.Input.validate(tool, input)` |
| `BaseTool.tool_name(t)` / `tool_description(t)` / `input_schema(t)` / `run(t)` | `Normandy.Tool.name(t)` / `description(t)` / `input_schema(t)` / `run(t, context)` |
| a `:timeout` field on the tool struct | `register_tool(agent, tool, timeout: ms)` / `Toolset.register(t, tool, timeout: ms)`; a struct field is not read |

- Input is checked before the tool runs. An unknown key, a missing required key or a wrong
  type answers the call with an `is_error: true` tool result naming the keys
  (`"invalid input for lookup: unknown keys \"endpoint\", \"timeout\"; expected only \"query\"; the tool was not run"`);
  the turn goes on. With `input: Schema` every schema constraint applies and nothing is
  coerced; with a hand-written map, required keys and basic JSON types are checked, and
  unknown keys are rejected when the map declares `properties` (unless
  `additionalProperties` is `true`; an absent `additionalProperties` counts as `false`). A
  map with no `properties` key accepts any keys. 1.x validated `SchemaBaseTool` tools only
  and dropped unknown keys silently.
- `Normandy.A2A.AgentTool` and `Normandy.MCP.ToolWrapper` lose their `:input` field;
  `AgentTool` loses `:timeout` and `AgentTool.new/3` raises on it: pass `timeout:` when
  registering (default 30 s; `A2A.Registry.discover_and_register/3` registers with its
  `:timeout`, default 60 s as before). An MCP tool's server schema is checked the same way:
  one with no `properties` key accepts any input keys; one that lists `properties` rejects
  other keys unless the server sets `additionalProperties: true`.
- `Normandy.Tools.Memory`'s `:command` field and `prepare_input/2` are gone.
- `Normandy.Tools.Executor`: `execute_tool/2` and `execute_tool_classified/2` take
  `context:` (required, carrying the input) and `timeout:`; any other option raises.
  `execute/3`, `execute_parallel/3`, `execute_sequential/3` and `:max_retries` are removed:
  they ran tools whose input lived in the struct. Run a tool through an agent, or call
  `Executor.execute_tool(tool, context: %Normandy.Tools.Context{tool_call_id: id, input: input})`.
- Custom pipelines: `Dispatch.classify/3` verdicts carry a `%Dispatch.Invocation{tool, input, timeout}`
  where they carried the input-merged struct; `execute/4`, `policy_fn` and `execute_fn`
  receive it. `Dispatch.prepare_tool/2` and `validate_input/2` are gone;
  `Dispatch.execute_approved/3` runs an approved call. A `PolicyEngine` sees the registered
  tool as `ctx.tool` and the validated input as `ctx.input`.
- `Context.build/2` is `Context.build(config, call, input)`.
```

- [ ] **Step 11: Commit**

```bash
git status --short
```

Add every path it lists individually (`git add <path>`; the `git rm`s are already staged).
Expected set: the lib, test, test/support and e2e files under **Files** above, the 14 files
of Step 6a, `mix.exs`, `.dialyzer_ignore.exs`, `MIGRATING-2.0.md`.

```bash
git commit -m "feat(tools)!: one Normandy.Tool contract; model input never reaches the tool struct

Dispatch validates input against the tool's input schema and passes it as
context.input; unknown keys answer with an is_error result naming them (SEC-1),
except under a hand-written schema with no properties, which accepts any keys.
The call's timeout is the registration option. BaseTool, SchemaBaseTool and
ContextualTool are deleted; Memory, A2A.AgentTool, MCP.ToolWrapper, the test
tools and the e2e scenarios implement Normandy.Tool."
```

---
### Task 3.4d: The 1.x tool guard (Ruling 5), DSL `tool Mod, opts`, docs

**Files:**
- Modify: `lib/normandy/tools/toolset.ex` (`check_tool!/2`, called by `register/3`),
  `lib/normandy/agents/config_template.ex` (`supplement_toolset!/1`),
  `lib/normandy/behaviours/agent_template.ex` (supplement type),
  `lib/normandy/dsl/agent.ex` (`tool/2`, `register_tools/1`, moduledoc), `.formatter.exs`
  (`tool: 2`), `examples/tools/weather.ex` (Task 3.3 moved it there; not compiled by `mix`),
  `test/support/normandy_integration_helper.ex` (`create_weather_tool/0`),
  `MIGRATING-2.0.md`, `CLAUDE.md`, `docs/guides/agent-memory.md`
- Test: `test/tools/toolset_test.exs`, `test/agents/config_template_test.exs`,
  `test/dsl/agent_tool_test.exs` (new)

**Interfaces:**
- Consumes: `Normandy.Tool.implemented_by?/1` (3.4b), `Toolset` (3.4a/3.4c).
- Produces: `Toolset.register/3` and `ConfigTemplate.rebuild/3` raise `ArgumentError` naming
  the module of a tool that does not implement `Normandy.Tool`, pointing at MIGRATING's
  "Tools: one `Normandy.Tool` behaviour" section (Ruling 5); `rebuild/3` also refuses a
  supplement keyed `:tool_registry` and a `:toolset` that is not a `%Toolset{}` or `nil`.
  `Toolset.check_tool!/2` is `@doc false`, shared by both. DSL `tool(module, opts \\ [])`.

- [ ] **Step 1: Write the failing tests**

1a. `test/tools/toolset_test.exs`, a new describe at the end:

```elixir
  describe "1.x tools (Ruling 5)" do
    defmodule OldStyleTool do
      @moduledoc false
      defstruct api_key: "secret-value"
    end

    test "a struct whose module does not implement Normandy.Tool raises, naming the module" do
      error =
        assert_raise ArgumentError, fn -> Toolset.register(Toolset.new(), %OldStyleTool{}) end

      assert error.message ==
               "Normandy.Tools.Toolset.register/3: NormandyTest.Tools.ToolsetTest.OldStyleTool " <>
                 "does not implement the Normandy.Tool behaviour. 1.x tools " <>
                 "(Normandy.Tools.BaseTool, SchemaBaseTool, ContextualTool) are replaced by it " <>
                 ~s(in 2.0; see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour))

      refute error.message =~ "secret-value"
    end

    test "something that is not a struct raises" do
      error = assert_raise ArgumentError, fn -> Toolset.new([%{name: "x"}]) end

      assert error.message ==
               "Normandy.Tools.Toolset.register/3: expected a tool struct whose module " <>
                 "implements Normandy.Tool, got: a map; " <>
                 ~s(see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour))
    end
  end
```

1b. `test/agents/config_template_test.exs`:
- add `alias Normandy.Tools.Toolset` and, below the aliases,

```elixir
  defmodule OldStyleTool do
    @moduledoc false
    defstruct []
  end
```

- the test that builds `tr = %Normandy.Tools.Toolset{tools: %{"t" => %{}}}` (old line ~117: a
  bare map is not a tool, which the guard now refuses) uses
  `tr = Toolset.new([%Normandy.Test.FakeTool{name: "t"}])`;
- in `describe "round trip"`, before `"a template saved before hooks existed rebuilds with []"`:

```elixir
    test "a supplement still keyed :tool_registry (1.x) raises, naming the key" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")
      old = supp |> Map.delete(:toolset) |> Map.put(:tool_registry, supp.toolset)

      error = assert_raise ArgumentError, fn -> ConfigTemplate.rebuild(tmpl, old, "TOKEN") end

      assert error.message ==
               "ConfigTemplate.rebuild/3: the supplement has :tool_registry, which 2.0 calls " <>
                 ":toolset (a %Normandy.Tools.Toolset{} or nil); " <>
                 ~s(see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour))
    end

    test "a supplement toolset holding a 1.x tool raises, naming its module" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")
      bad = %{supp | toolset: %Toolset{tools: %{"old" => %OldStyleTool{}}}}

      error = assert_raise ArgumentError, fn -> ConfigTemplate.rebuild(tmpl, bad, "TOKEN") end

      assert error.message =~
               "ConfigTemplate.rebuild/3: Normandy.Agents.ConfigTemplateTest.OldStyleTool " <>
                 "does not implement the Normandy.Tool behaviour."
    end

    test "a supplement :toolset that is not a Toolset raises" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t")

      error =
        assert_raise ArgumentError, fn ->
          ConfigTemplate.rebuild(tmpl, %{supp | toolset: [:tool]}, "TOKEN")
        end

      assert error.message ==
               "ConfigTemplate.rebuild/3: the supplement's :toolset must be a " <>
                 "%Normandy.Tools.Toolset{} or nil, got: a list"
    end
```

(If Task 3.2 renamed `round_trip_supplement/1` or `full_config/1`, use its names; the tests
need a valid template and a supplement that rebuilds it.)

1c. `test/dsl/agent_tool_test.exs`:

```elixir
defmodule Normandy.DSL.AgentToolTest do
  use ExUnit.Case, async: true

  alias Normandy.Test.FakeTool
  alias Normandy.Tools.Examples.Calculator
  alias Normandy.Tools.Toolset

  defmodule ToolAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      tool(Normandy.Test.FakeTool, timeout: 1_234)
      tool(Normandy.Tools.Examples.Calculator)
    end
  end

  defmodule PlainStruct do
    @moduledoc false
    defstruct []
  end

  defmodule NotAToolAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      tool(Normandy.DSL.AgentToolTest.PlainStruct)
    end
  end

  defp client, do: %NormandyTest.Support.ModelMockup{}

  test "tool registers the module's struct with its registration options" do
    agent = ToolAgent.new(client: client())

    assert {:ok, %FakeTool{}} = Toolset.fetch(agent.toolset, "weather")
    assert {:ok, %Calculator{}} = Toolset.fetch(agent.toolset, "calculator")
    assert Toolset.timeout(agent.toolset, "weather") == 1_234
    assert Toolset.timeout(agent.toolset, "calculator") == nil
  end

  test "a module that is not a Normandy.Tool raises at new/1, naming it" do
    error = assert_raise ArgumentError, fn -> NotAToolAgent.new(client: client()) end

    assert error.message =~
             "Normandy.DSL.AgentToolTest.PlainStruct does not implement the Normandy.Tool behaviour"
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/tools/toolset_test.exs test/agents/config_template_test.exs test/dsl/agent_tool_test.exs`
Expected: FAIL. `Toolset.register/3` raises `UndefinedFunctionError` (`OldStyleTool.name/1`)
or `FunctionClauseError` (a map) instead of the `ArgumentError`; `rebuild/3` raises
`KeyError` for the `:tool_registry` supplement and accepts the old-style tool; `tool/2` is
undefined in the DSL (compile error naming `tool/2`).

- [ ] **Step 3: Implement**

3a. `lib/normandy/tools/toolset.ex`: add `alias Normandy.Components.ContentBlock.Describe`
(first in the alias block); in `register/3`'s `@doc`, after the `replace: true` sentence:
"A struct whose module does not implement `Normandy.Tool` (a 1.x tool) raises
`ArgumentError` naming the module."; in its body, right after the options are validated:

```elixir
    :ok = check_tool!(tool, "Normandy.Tools.Toolset.register/3")
```

and, before `timeout/2`:

```elixir
  @migration ~s(see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour))

  @doc false
  # Ruling 5: a 1.x tool reaches a 2.0 node only through registration or a template
  # supplement's toolset (ConfigTemplate.rebuild/3), so both check here. Names the module,
  # never the struct's values (they can be credentials).
  @spec check_tool!(term(), String.t()) :: :ok
  def check_tool!(%module{}, caller) do
    if Tool.implemented_by?(module) do
      :ok
    else
      raise ArgumentError,
            "#{caller}: #{inspect(module)} does not implement the Normandy.Tool behaviour. " <>
              "1.x tools (Normandy.Tools.BaseTool, SchemaBaseTool, ContextualTool) are " <>
              "replaced by it in 2.0; #{@migration}"
    end
  end

  def check_tool!(other, caller) do
    raise ArgumentError,
          "#{caller}: expected a tool struct whose module implements Normandy.Tool, got: " <>
            "#{Describe.type_of(other)}; #{@migration}"
  end
```

3b. `lib/normandy/agents/config_template.ex`: add `alias Normandy.Components.ContentBlock.Describe`
and `alias Normandy.Tools.Toolset`; in `rebuild/3`'s `%BaseAgentConfig{}`,
`toolset: supplement.toolset` becomes `toolset: supplement_toolset!(supplement)`; add, above
`node_local_fields!/2`:

```elixir
  @tools_section ~s(see MIGRATING-2.0.md §25 (Tools: one Normandy.Tool behaviour))

  # Ruling 5: the supplement is where a 1.x tool setup can reach a 2.0 node.
  defp supplement_toolset!(%{tool_registry: _}) do
    raise ArgumentError,
          "ConfigTemplate.rebuild/3: the supplement has :tool_registry, which 2.0 calls " <>
            ":toolset (a %Normandy.Tools.Toolset{} or nil); #{@tools_section}"
  end

  defp supplement_toolset!(%{toolset: nil}), do: nil

  defp supplement_toolset!(%{toolset: %Toolset{} = toolset}) do
    toolset |> Toolset.list() |> Enum.each(&Toolset.check_tool!(&1, "ConfigTemplate.rebuild/3"))
    toolset
  end

  defp supplement_toolset!(%{toolset: other}) do
    raise ArgumentError,
          "ConfigTemplate.rebuild/3: the supplement's :toolset must be a " <>
            "%Normandy.Tools.Toolset{} or nil, got: #{Describe.type_of(other)}"
  end

  defp supplement_toolset!(_supplement) do
    raise ArgumentError,
          "ConfigTemplate.rebuild/3: the supplement has no :toolset (a " <>
            "%Normandy.Tools.Toolset{} or nil)"
  end
```

Add to `rebuild/3`'s `@doc`: "Raises `ArgumentError` for a supplement that still uses the 1.x
key `:tool_registry`, whose `:toolset` is not a `%Normandy.Tools.Toolset{}` or `nil`, or whose
toolset holds a struct whose module does not implement `Normandy.Tool`."

3c. `lib/normandy/behaviours/agent_template.ex`: in `@type supplement`,
`required(:toolset) => term()` becomes `required(:toolset) => Normandy.Tools.Toolset.t() | nil`.

3d. `lib/normandy/dsl/agent.ex`:
- moduledoc option list (old line 110): `- \`tool\` - Register a tool module (can be called
  multiple times)` becomes

```elixir
  - `tool` - Register a tool: `tool MyTool` registers `%MyTool{}`, `tool MyTool, timeout: 60_000`
    passes registration options (`Normandy.Tools.Toolset.register/3`); can be called multiple
    times
```

- the macro:

```elixir
  @doc """
  Registers a tool: `new/1` registers `%module{}` with `opts`
  (`Normandy.Tools.Toolset.register/3`'s options, e.g. `timeout: 60_000`). A tool whose
  struct needs configuration is registered at runtime with `BaseAgent.register_tool/3`.
  """
  defmacro tool(module, opts \\ []) do
    quote do
      Module.put_attribute(__MODULE__, :agent_tools, {unquote(module), unquote(opts)})
    end
  end
```

- `register_tools/1` in the generated code:

```elixir
      defp register_tools(agent) do
        Enum.reduce(@agent_compile_config.tools, agent, fn {tool_module, opts}, acc ->
          BaseAgent.register_tool(acc, struct!(tool_module), opts)
        end)
      end
```

  (`struct!/1`: a tool with `@enforce_keys` needs configuration and raises here, naming the
  keys, instead of registering a half-built struct; `config/0`'s `tools:` now lists
  `{module, opts}` pairs.)

3e. `.formatter.exs`: after `tool: 1,` add `tool: 2,` (`test/formatter_export_test.exs` requires
every DSL macro arity in the export).

3f. `examples/tools/weather.ex` (moved by Task 3.3; not compiled by `mix`): the same rewrite as
the test Calculator. Replace `use Normandy.Tools.SchemaBaseTool` and the `tool_schema` block with

```elixir
  defmodule Input do
    @moduledoc false
    use Normandy.Schema

    io_schema "Fetches current weather information for a given city using real-time data" do
      field(:city, :string,
        required: true,
        description: "The city name to get weather for (e.g., 'San Francisco', 'London', 'Tokyo')"
      )
    end
  end

  use Normandy.Tool,
    name: "weather",
    description: "Fetches current weather information for a given city using real-time data",
    input: Input

  alias Normandy.Tools.Context

  defstruct []
```

`def execute(%__MODULE__{city: city}) do` becomes `@impl Normandy.Tool` +
`def run(_tool, %Context{input: %Input{city: city}}) do`, and the moduledoc example becomes

```elixir
      iex> {:ok, input} = Normandy.Tools.Input.validate(%Weather{}, %{"city" => "San Francisco"})
      iex> Weather.run(%Weather{}, %Normandy.Tools.Context{tool_call_id: "t", input: input})
      {:ok, "Current weather in San Francisco: 15.2°C, Clear sky"}
```

Check it compiles: `MIX_ENV=test mix run --no-start -e 'Code.compile_file("examples/tools/weather.ex"); IO.puts(:ok)'` → `ok`
(the test env does not consolidate protocols, so `io_schema`'s `BaseIOSchema` impl compiles
without the consolidation warning the dev env prints).

In `test/support/normandy_integration_helper.ex` (Task 3.3b's `create_weather_tool/0`),
`struct(MyApp.Tools.Weather, city: "")` becomes `struct(MyApp.Tools.Weather)`: the struct has no
`:city` field any more (the city is model input), and `struct/2` would drop the key silently.

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/tools/toolset_test.exs test/agents/config_template_test.exs test/dsl/agent_tool_test.exs test/formatter_export_test.exs`
Expected: PASS.

- [ ] **Step 5: Docs**

5a. `docs/guides/agent-memory.md`: replace the section `## Writing contextual tools` (through
the paragraph about arity-3 `execute_fn`) with:

````markdown
## Tools that read the session context

Every tool's `run/2` receives a `%Normandy.Tools.Context{}`: `input` is the call's validated
input, `values` is `tool_context`, and `session_id`, `agent_name`, `turn_id` and
`tool_call_id` identify the call.

```elixir
defmodule MyApp.Tools.OrderLookup do
  defmodule Input do
    use Normandy.Schema

    io_schema "Order lookup input" do
      field(:order_id, :string, required: true, description: "the order id")
    end
  end

  use Normandy.Tool,
    name: "order_lookup",
    description: "Looks up one of the current customer's orders.",
    input: Input

  defstruct []

  @impl Normandy.Tool
  def run(_tool, %Normandy.Tools.Context{input: %Input{order_id: id}, values: %{customer_id: customer}}),
    do: MyApp.Orders.fetch(customer, id)
end
```

The customer comes from `tool_context`, which the model cannot set; the order id comes from
the model and is validated against `Input` before `run/2` is called.
````

5b. `CLAUDE.md`, section "Long-term Memory & Tool Context": replace the
`Normandy.Tools.Context` / `Normandy.Tools.ContextualTool` bullet with:

```markdown
- **`Normandy.Tool`** - The one tool contract: `name/1`, `description/1`, `input_schema/1`,
  `run(tool, %Normandy.Tools.Context{})`; `use Normandy.Tool, name:, description:, input: Schema`
  generates the first three. The struct holds configuration only; the model's input is
  validated (`Normandy.Tools.Input`: unknown keys refused, except under a hand-written schema with no `properties`) and arrives as `context.input`
- **`Normandy.Tools.Toolset`** - Tools by name (`BaseAgentConfig.toolset`); `register/3`
  options `:timeout` (the call's timeout; a struct field is never read) and `:replace`;
  `fetch/2`, `fetch!/2`. A struct whose module is not a `Normandy.Tool` raises at
  registration and in `ConfigTemplate.rebuild/3` (1.x tools)
- **`Normandy.Tools.Context`** - Per-call context: `input`, plus `values` from
  `BaseAgentConfig.tool_context` (plain data, persisted in the config template), built by
  every pipeline through `Dispatch.executor_opts/3`
```

In the same file's "Agent System" section, the `BaseAgent` bullet's tool loop is unchanged;
nothing else there names the old contracts (`grep -n "BaseTool\|ContextualTool\|tool_registry\|Tools.Registry" CLAUDE.md`
prints nothing after this step).

5c. `docs/guides/distributed_sessions.md` was updated by Task 3.4a (`toolset:`);
`docs/guides/hooks.md` and `README.md` name no tool contract (checked: `grep -n
"BaseTool\|ContextualTool\|SchemaBaseTool\|tool_registry" docs/guides/*.md README.md` prints
nothing after 5a).

5d. `examples/` apps — listed for Wave 7, which owns their builds; not edited here. Each uses
the 1.x contract (`defimpl Normandy.Tools.BaseTool` / `SchemaBaseTool` / `tool_registry`):

```
examples/agent_horde/lib/agent_horde/pipeline.ex
examples/agent_horde/lib/agent_horde/tools/{exa_search,firecrawl_scrape,serpapi_search,serper_search}.ex
examples/agent_horde/test/agent_horde_test.exs
examples/agent_horde/test/support/stub_tool.exs
examples/customer_support_app/lib/customer_support/agents/{billing_support,greeter,order_support,technical_support}_agent.ex
examples/customer_support_app/lib/customer_support/tools/{knowledge_base,order_lookup,refund_processor,ticket_creation}_tool.ex
examples/customer_support_app/{ARCHITECTURE,README}.md
examples/README.md
```

(`grep -rlE "BaseTool|SchemaBaseTool|ContextualTool|Tools\.Registry|tool_registry|prepare_input" examples | grep -v "/deps/\|/_build/\|erl_crash"` lists exactly these 18 files at `95dc149`.)

- [ ] **Step 6: MIGRATING**

Append to the "Tools: one `Normandy.Tool` behaviour" section:

```markdown
### Rolling upgrades and templates

- Config templates hold no tools: `ConfigTemplate.rebuild/3` takes the toolset from the
  `AgentTemplate` supplement registered on each node. Rename its `:tool_registry` key to
  `:toolset`; `rebuild/3` raises `ArgumentError` on the old key, on a `:toolset` that is not a
  `%Normandy.Tools.Toolset{}` or `nil`, and on a tool whose module does not implement
  `Normandy.Tool`. `Toolset.register/3` (and `BaseAgent.register_tool/3`) raise the same
  error for a 1.x tool. Each names the module and this section.
- A session parked on an approval under 1.x resumes under 2.0: the parked call's input is
  validated again when it is approved, and a call whose tool is gone or whose input no
  longer validates is answered with an error result instead of crashing the server.
- DSL: `tool MyTool, timeout: 60_000` passes registration options. `tool MyTool` builds
  `%MyTool{}` with `struct!/1`: a tool with enforced keys raises at `new/1`; register it with
  `BaseAgent.register_tool/3` after `new/1` instead.
```

- [ ] **Step 7: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -5 && mix credo --strict 2>&1 | tail -3 && mix docs --warnings-as-errors 2>&1 | tail -2`
Expected: ` 0 failures`; Credo finds no issues; docs build.

```bash
git add lib/normandy/tools/toolset.ex lib/normandy/agents/config_template.ex \
  lib/normandy/behaviours/agent_template.ex lib/normandy/dsl/agent.ex .formatter.exs \
  examples/tools/weather.ex test/support/normandy_integration_helper.ex \
  MIGRATING-2.0.md CLAUDE.md docs/guides/agent-memory.md \
  test/tools/toolset_test.exs test/agents/config_template_test.exs test/dsl/agent_tool_test.exs
git commit -m "feat(tools): refuse 1.x tools at registration and template rebuild; DSL tool options

Toolset.register/3 and ConfigTemplate.rebuild/3 raise ArgumentError naming a
struct's module when it does not implement Normandy.Tool, and rebuild/3 refuses
a supplement keyed :tool_registry. DSL tool/2 passes registration options.
Guides, CLAUDE.md and MIGRATING describe the one tool contract."
```

---

### Task 3.5a: `Turn.Session` is a handle built once (DX-14)

**Files:**
- Modify: `lib/normandy/agents/turn/session.ex` (whole file, 242 lines today)
- Modify: `lib/normandy/coordination/agent_process.ex` — moduledoc `:28-48`; `approve/2` doc and spec `:145-160`; `init/1` `:253-306`; `session_opts/1` `:370-384` (deleted); `handle_call({:update_agent, ...})` `:464-481`; `handle_call({:approve, ...})` `:489-492`; `handle_cast({:run_async, ...})` `:503-534`; `spawn_run/3` `:560-585`; `reconstruct_agent/1` `:664`
- Modify: `lib/normandy/turn_error.ex:30-31` (the `:session_unavailable` bullet)
- Modify: `docs/guides/agent-memory.md:34-82`, `docs/guides/distributed_sessions.md:45-46`
- Modify: `e2e/04_durable_server.exs:15-30`, `e2e/05_approvals.exs:46-61`, `test/support/e2e/distributed.ex:150,156`
- Modify: `MIGRATING-2.0.md` (new section before `## New, non-breaking`)
- Test: `test/agents/turn/session_test.exs`, `test/agents/turn/server_errors_test.exs`, `test/agents/turn/server_integration_test.exs`, `test/agents/turn/server_postgres_e2e_test.exs`, `test/agents/turn/eager_handoff_distributed_test.exs`, `test/agents/turn/tier2_integration_test.exs`, `test/coordination/agent_process_server_test.exs`

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`, `Normandy.Options.docs/1` (Task 3.1).
- Produces:
  - `Normandy.Agents.Turn.Session.new(keyword()) :: Session.t()` — raises `ArgumentError` prefixed `"Normandy.Agents.Turn.Session.new/1: "`.
  - `Session.run(Session.t(), input) :: {:ok, output} | {:error, Exception.t()}`.
  - `Session.approve(Session.t(), decisions) :: :ok | {:error, Normandy.TurnError.t()}`.
  - `Session.put_config(Session.t(), BaseAgentConfig.t()) :: Session.t()`.
  - `%Session{session_id, registry, supervisor, supervisor_mod, store, config, template_provider, template_id, resume_policy, subscriber, handlers, server_options}` (`server_options`: the keyword of `:approval_timeout_ms`, `:on_approval_timeout`, `:idle_timeout_ms` that were given).
  - `AgentProcess.approve/2` returns what `Session.approve/2` returns (plus `{:error, :inline_mode}`, unchanged).

**How `AgentProcess` holds a session (the staleness problem).** Today `session_opts/1`
(`agent_process.ex:372-384`) rebuilds the keyword list on every `run`, `cast` and `approve`
from `state.agent`, so the config a server starts with is always the latest one. The config
is only *read* by `Turn.Session` on a registry miss (first start, restart after
passivation, Tier-2 template save); a live server keeps the config it started with. In
`:server` mode the only writer of `state.agent` is `handle_call({:update_agent, ...})`
(`:464-481`); the inline `{:run, ...}` clause writes it only in `:inline` mode, where no
session exists. So: `init/1` builds the `%Session{}` once (validated there) and stores it in
`state.session`; `update_agent/2` replaces both `state.agent` and
`state.session` (`Session.put_config/2`). Every other read uses `state.session` as is. The
fields `store`, `registry`, `supervisor`, `supervisor_mod`, `template_provider`,
`resume_policy`, `template_id` and `extra_session_opts` leave the state map (they live in the
session); `owned` stays.

- [ ] **Step 1: Write the failing tests**

In `test/agents/turn/session_test.exs`, add after `defp session_config do ... end` (`:49-59`):

```elixir
  # A complete option list for new/1 that starts nothing.
  defp new_opts(extra \\ []) do
    Keyword.merge(
      [
        session_id: "s-new",
        config: session_config(),
        store: {InMemory, :store},
        registry: {Native, :reg},
        supervisor: :sup
      ],
      extra
    )
  end

  describe "new/1" do
    test "returns a %Turn.Session{} with the defaults filled in" do
      assert %Turn.Session{
               session_id: "s-new",
               store: {InMemory, :store},
               registry: {Native, :reg},
               supervisor: :sup,
               supervisor_mod: Turn.Supervisor,
               resume_policy: :lazy,
               template_provider: nil,
               template_id: nil,
               subscriber: nil,
               handlers: nil,
               server_options: []
             } = Turn.Session.new(new_opts())
    end

    test "keeps only the server options it was given" do
      assert %Turn.Session{server_options: [on_approval_timeout: :fail]} =
               Turn.Session.new(new_opts(on_approval_timeout: :fail))
    end

    test "requires :config or :template_provider" do
      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.new/1: requires :config " <>
                     "(a %Normandy.Agents.BaseAgentConfig{}) or :template_provider " <>
                     "({module, handle}), got neither",
                   fn -> Turn.Session.new(Keyword.delete(new_opts(), :config)) end
    end

    test "a missing required key names the function and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Session.new(Keyword.delete(new_opts(), :store))
        end

      assert error.message =~ "Normandy.Agents.Turn.Session.new/1: "
      assert error.message =~ ":store"
    end

    test "a misspelled key names the function and the key" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Session.new(new_opts(approval_timout_ms: 1))
        end

      assert error.message =~ "Normandy.Agents.Turn.Session.new/1: "
      assert error.message =~ ":approval_timout_ms"
    end

    test "a :config that is not a BaseAgentConfig is rejected without echoing it" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Session.new(new_opts(config: %{client: %{api_key: "sk-secret"}}))
        end

      assert error.message =~ ":config"
      refute error.message =~ "sk-secret"
    end

    test ":resume_policy must be :lazy or :eager" do
      error =
        assert_raise ArgumentError, fn -> Turn.Session.new(new_opts(resume_policy: :sometimes)) end

      assert error.message =~ ":resume_policy"
      assert error.message =~ ":sometimes"
    end

    test "something other than a keyword list is rejected" do
      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.new/1: expected a keyword list, got: a map",
                   fn -> Turn.Session.new(%{session_id: "s"}) end
    end
  end

  describe "run/2, approve/2 and put_config/2" do
    test "run/2 and approve/2 reject an option list with a pointer to new/1" do
      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.run/2: expected a %Normandy.Agents.Turn.Session{} " <>
                     "(build one with Normandy.Agents.Turn.Session.new/1), got: a list",
                   fn -> Turn.Session.run(new_opts(), "hi") end

      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.approve/2: expected a %Normandy.Agents.Turn.Session{} " <>
                     "(build one with Normandy.Agents.Turn.Session.new/1), got: a list",
                   fn -> Turn.Session.approve(new_opts(), %{}) end
    end

    test "put_config/2 replaces the config a later start uses" do
      session = Turn.Session.new(new_opts())
      config = %{session_config() | temperature: 0.42}

      assert %Turn.Session{config: ^config} = Turn.Session.put_config(session, config)

      assert_raise ArgumentError,
                   "Normandy.Agents.Turn.Session.put_config/2: expected a " <>
                     "%Normandy.Agents.BaseAgentConfig{}, got: a map",
                   fn -> Turn.Session.put_config(session, %{}) end
    end
  end
```

In `test/coordination/agent_process_server_test.exs`:

1. `:107-108`, replace

```elixir
      %{store: {_sm, store_h}, registry: {_rm, reg_name}, supervisor: sup, owned: owned} =
        :sys.get_state(pid)
```

with

```elixir
      %{
        session: %Normandy.Agents.Turn.Session{
          store: {_sm, store_h},
          registry: {_rm, reg_name},
          supervisor: sup
        },
        owned: owned
      } = :sys.get_state(pid)
```

2. `:248-257`, replace the test `"unknown session returns {:error, :no_session}"` with

```elixir
    test "unknown session returns a :session_unavailable TurnError" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra
        )

      assert {:error, %Normandy.TurnError{type: :session_unavailable, reason: :no_session}} =
               AgentProcess.approve(pid, %{"pk1" => :approve})
    end
```

3. In `":server update_agent/2"` (`:454-458`), replace

```elixir
      %{agent: agent} = :sys.get_state(pid)
```

with

```elixir
      %{agent: agent, session: %Normandy.Agents.Turn.Session{config: session_config}} =
        :sys.get_state(pid)

      # The held session starts the next server with the updated config.
      assert session_config == agent
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/turn/session_test.exs test/coordination/agent_process_server_test.exs`
Expected: FAIL. `UndefinedFunctionError: function Normandy.Agents.Turn.Session.new/1 is undefined`
for the new `session_test` tests; `MatchError` on `:sys.get_state(pid)` (no `:session` key)
and `{:error, :no_session}` not matching in `agent_process_server_test`.

- [ ] **Step 3: Rewrite `lib/normandy/agents/turn/session.ex`**

Replace the whole file with:

```elixir
defmodule Normandy.Agents.Turn.Session do
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn.{Server, Supervisor}
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.TurnError

  # Plain-data server options saved with a Tier-2 template, so a server started
  # without them (e.g. by ResumeReaper) restores them. Functions (:subscriber,
  # :handlers) cannot be stored; the starter must pass those.
  @stored_server_options [:approval_timeout_ms, :on_approval_timeout, :idle_timeout_ms]

  @schema NimbleOptions.new!(
            session_id: [
              type: :string,
              required: true,
              doc: "The session's id: its key in the registry and in the store."
            ],
            registry: [
              type: {:custom, __MODULE__, :validate_module_handle, []},
              required: true,
              doc: "The `Normandy.Behaviours.SessionRegistry`, as `{module, handle}`."
            ],
            supervisor: [
              type: {:or, [:pid, :atom, {:tuple, [:atom, :any]}, {:tuple, [:atom, :atom, :any]}]},
              required: true,
              doc: "The supervisor that starts the session's `Turn.Server`: a pid or a name."
            ],
            supervisor_mod: [
              type: :atom,
              default: Supervisor,
              doc:
                "The module whose `start_server/2` starts the server " <>
                  "(`Normandy.Agents.Turn.Supervisor.Horde` in a cluster)."
            ],
            store: [
              type: {:custom, __MODULE__, :validate_module_handle, []},
              required: true,
              doc: "The `Normandy.Behaviours.SessionStore`, as `{module, handle}`."
            ],
            config: [
              type: {:custom, __MODULE__, :validate_config, []},
              doc:
                "The `%Normandy.Agents.BaseAgentConfig{}` a server starts with. With " <>
                  "`:template_provider` too, it is saved as the session's template on first start."
            ],
            template_provider: [
              type: {:custom, __MODULE__, :validate_module_handle, []},
              doc:
                "A `Normandy.Behaviours.AgentTemplate`, as `{module, handle}`: the server " <>
                  "rebuilds its config from the stored template and this node's supplement."
            ],
            template_id: [
              type: :string,
              doc:
                "The supplement's id in the template provider. Default: the config's " <>
                  "`:name`, else `\"default\"`."
            ],
            resume_policy: [
              type: {:in, [:lazy, :eager]},
              default: :lazy,
              doc:
                "`:eager` resumes an unfinished turn when the server restarts, and a Tier-2 " <>
                  "start saves it so `ResumeReaper` restarts the session after a node loss."
            ],
            subscriber: [
              type: {:fun, 2},
              doc: "`fn event_name, meta -> any end`, passed to `Turn.Server`."
            ],
            handlers: [
              type: {:struct, Normandy.Agents.Turn.Driver.Handlers},
              doc: "A `Turn.Driver.Handlers` set, passed to `Turn.Server`."
            ],
            approval_timeout_ms: [
              type: :pos_integer,
              doc: "Passed to `Turn.Server`; saved with a Tier-2 template."
            ],
            on_approval_timeout: [
              type: {:in, [:continue, :fail]},
              doc: "Passed to `Turn.Server`; saved with a Tier-2 template."
            ],
            idle_timeout_ms: [
              type: :pos_integer,
              doc: "Passed to `Turn.Server`; saved with a Tier-2 template."
            ]
          )

  @moduledoc """
  A handle on one durable session. `new/1` checks the options once; `run/2` routes a turn
  to the session's `Turn.Server` and `approve/2` delivers approval decisions to it.

      session =
        Turn.Session.new(
          session_id: "user-42",
          config: config,
          store: {Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo},
          registry: {Normandy.Behaviours.SessionRegistry.Native, MyApp.SessionRegistry},
          supervisor: MyApp.TurnSupervisor
        )

      {:ok, output} = Turn.Session.run(session, "hello")

  `run/2` resolves `session_id` to a live pid via the `SessionRegistry`; on a miss, it
  starts a `Turn.Server` under the supervisor with the **caller-supplied** config (the
  store never holds config/credentials). The server loads its turn state and
  conversation memory from the `SessionStore` on every start, so a supervisor restart
  resumes from the store, not from the state captured when the session first started.
  A `%Turn.Session{}` is plain data: building one starts nothing, and the same handle can
  be used from any process.

  ## Options

  #{Normandy.Options.docs(@schema)}

  ## Tier-2 thin start (when `:template_provider` is set)

  With a `:config` and a `:template_provider`, the first start persists a secret-free
  `ConfigTemplate` derived from the config, then launches `Turn.Server` with **thin**
  options (no `:config`). The server reconstructs the full config node-locally from the
  stored template + supplement + credential token. Later starts (after passivation)
  find the persisted template in the store and reconstruct without any caller config.

  A session may also have only a `:template_provider` (no `:config`), for example on a
  surviving node after the session's node died: the server starts from the template
  already saved in the store. With no saved template, `run/2` returns
  `{:error, %Normandy.TurnError{type: :session_unavailable, reason:
  {:no_config_template, session_id}}}`.

  ## Resume policy (`:resume_policy`, `:lazy` or `:eager`)

  `:lazy` (default) restarts a session only when a caller routes to it. With
  `:eager`, a restarted server resumes a non-terminal turn on its own, and a
  Tier-2 start saves the policy in the template, so `ResumeReaper` restarts the
  session when its node goes down. A session started from a saved template keeps
  the policy it was saved with.

  ## Start-time race

  For `:self_register` (Native) registries the race between `whereis` returning
  `:none` and the new child finishing `register/3` is best-effort: a concurrent
  caller may start a second child, which then loses the race and keeps running
  unregistered. This was acceptable for single-router usage.

  For via-based registries (Horde) the race is **closed**: the supervisor supplies
  a `:name` computed by `child_name/2`, so the OTP supervisor performs atomic
  registration at start. Any concurrent caller that loses the start race gets
  `{:error, {:already_started, pid}}`, which `run/2` treats as `{:ok, pid}` so all
  callers converge on the single winner.
  """

  @type t :: %__MODULE__{
          session_id: String.t(),
          registry: {module(), term()},
          supervisor: GenServer.server(),
          supervisor_mod: module(),
          store: {module(), term()},
          config: BaseAgentConfig.t() | nil,
          template_provider: {module(), term()} | nil,
          template_id: String.t() | nil,
          resume_policy: :lazy | :eager,
          subscriber: (atom(), map() -> any()) | nil,
          handlers: Normandy.Agents.Turn.Driver.Handlers.t() | nil,
          server_options: keyword()
        }

  @enforce_keys [:session_id, :registry, :supervisor, :store]
  defstruct [
    :session_id,
    :registry,
    :supervisor,
    :store,
    :config,
    :template_provider,
    :template_id,
    :subscriber,
    :handlers,
    supervisor_mod: Supervisor,
    resume_policy: :lazy,
    server_options: []
  ]

  @doc """
  Builds a session handle. Starts nothing.

  Raises `ArgumentError` naming the key for an unknown key, a missing required key or a
  value of the wrong type, and when neither `:config` nor `:template_provider` is given.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = Normandy.Options.validate!(opts, @schema, {__MODULE__, :new, 1})

    unless Keyword.has_key?(opts, :config) or Keyword.has_key?(opts, :template_provider) do
      raise ArgumentError,
            "Normandy.Agents.Turn.Session.new/1: requires :config " <>
              "(a %Normandy.Agents.BaseAgentConfig{}) or :template_provider " <>
              "({module, handle}), got neither"
    end

    struct!(
      __MODULE__,
      [server_options: Keyword.take(opts, @stored_server_options)] ++
        Keyword.drop(opts, @stored_server_options)
    )
  end

  def new(other) do
    raise ArgumentError,
          "Normandy.Agents.Turn.Session.new/1: expected a keyword list, got: " <>
            Describe.type_of(other)
  end

  @doc """
  Routes a turn to the session's server, starting it if needed, and returns what
  `Turn.Server.run/2` returns: `{:ok, output}` or `{:error, exception}`. A session that
  cannot be started (a registry or store fault, no saved template) returns
  `{:error, %Normandy.TurnError{type: :session_unavailable, reason: reason}}`.
  """
  @spec run(t(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def run(%__MODULE__{} = session, user_input) do
    case ensure_server(session) do
      {:ok, pid} ->
        Server.run(pid, user_input)

      # A start function that raised comes back from the supervisor as
      # {exception, stacktrace}: the stacktrace is dropped (decision 6).
      {:error, reason} ->
        {:error,
         %TurnError{type: :session_unavailable, reason: TurnError.drop_stacktraces(reason)}}
    end
  end

  def run(other, _user_input), do: raise(ArgumentError, not_a_session(:run, other))

  @doc """
  Delivers approval decisions (`tool_call_id => :approve | :reject`) to the session's
  parked server and returns `:ok`; the turn's result goes to the `run/2` caller waiting
  on it. Never starts a server: with none live it returns `{:error,
  %Normandy.TurnError{type: :session_unavailable, reason: :no_session}}`, and a registry
  that cannot answer returns that `TurnError` with the registry's reason.
  """
  @spec approve(t(), %{optional(String.t()) => :approve | :reject}) ::
          :ok | {:error, TurnError.t()}
  def approve(%__MODULE__{registry: {reg_mod, reg_handle}, session_id: sid}, decisions) do
    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} ->
        Server.approve(pid, decisions)

      # Approval only makes sense against a live, parked server. An
      # awaiting-approval server never passivates (only :idle does), so a
      # registry miss means there is no session to approve: fail closed
      # instead of booting a fresh server and silently dropping the approval.
      :none ->
        {:error, %TurnError{type: :session_unavailable, reason: :no_session}}

      {:error, reason} ->
        {:error, %TurnError{type: :session_unavailable, reason: reason}}
    end
  end

  def approve(other, _decisions), do: raise(ArgumentError, not_a_session(:approve, other))

  @doc """
  Returns `session` with `config` as the config a later server start uses (a first
  start, a restart after passivation, a Tier-2 template save). A live server keeps the
  config it started with.
  """
  @spec put_config(t(), BaseAgentConfig.t()) :: t()
  def put_config(%__MODULE__{} = session, %BaseAgentConfig{} = config),
    do: %{session | config: config}

  def put_config(%__MODULE__{}, other) do
    raise ArgumentError,
          "Normandy.Agents.Turn.Session.put_config/2: expected a " <>
            "%Normandy.Agents.BaseAgentConfig{}, got: " <> Describe.type_of(other)
  end

  @doc false
  # NimbleOptions :custom types. The error never echoes the value: a config holds the
  # client and its credentials, a handle may hold a connection.
  def validate_module_handle({module, _handle} = value) when is_atom(module) and module != nil,
    do: {:ok, value}

  def validate_module_handle(other),
    do: {:error, "expected a {module, handle} tuple, got: " <> Describe.type_of(other)}

  @doc false
  def validate_config(%BaseAgentConfig{} = config), do: {:ok, config}

  def validate_config(other),
    do:
      {:error,
       "expected a %Normandy.Agents.BaseAgentConfig{}, got: " <> Describe.type_of(other)}

  defp not_a_session(fun, other) do
    "Normandy.Agents.Turn.Session.#{fun}/2: expected a %Normandy.Agents.Turn.Session{} " <>
      "(build one with Normandy.Agents.Turn.Session.new/1), got: " <> Describe.type_of(other)
  end

  defp ensure_server(%__MODULE__{registry: {reg_mod, reg_handle}, session_id: sid} = session) do
    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} -> {:ok, pid}
      :none -> rehydrate_and_start(session)
      # The registry could not answer: starting would risk a second server.
      {:error, reason} -> {:error, reason}
    end
  end

  # Turn.Server.init/1 loads the turn state and rebuilds memory from the store
  # itself (on every start, including supervisor restarts), so the server opts
  # carry only the caller's config and options. A store fault in that load
  # comes back as run/2's {:error, reason} (the server starts :unavailable).
  defp rehydrate_and_start(%__MODULE__{} = session) do
    {reg_mod, reg_handle} = session.registry

    with {:ok, server_opts} <- server_opts(session) do
      start_with_retry(
        session.supervisor_mod,
        session.supervisor,
        server_opts,
        reg_mod,
        reg_handle,
        session.session_id
      )
    end
  end

  # Three ways to start: a :config with no template provider (Tier 0/1); a :config
  # with a template provider, which saves the template first (Tier 2, first
  # start); or a template provider alone, which starts from the template already
  # in the store (Tier 2, e.g. a caller on a surviving node that has no config).
  # new/1 guarantees at least one of the two.
  defp server_opts(%__MODULE__{config: config, template_provider: nil} = session)
       when config != nil,
       do: {:ok, Keyword.put(base_server_opts(session), :config, config)}

  defp server_opts(%__MODULE__{config: nil} = session) do
    case load_template(session) do
      {:ok, _tmpl} -> {:ok, thin_server_opts(session)}
      :error -> {:error, {:no_config_template, session.session_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp server_opts(%__MODULE__{config: config} = session) do
    with :ok <- save_template(session, config), do: {:ok, thin_server_opts(session)}
  end

  defp save_template(%__MODULE__{store: {store_mod, store_handle}} = session, config) do
    tmpl =
      config
      |> ConfigTemplate.from_config(template_id_of(session, config), session.resume_policy)
      |> Map.put(:server_options, Map.new(session.server_options))

    store_mod.save_config_template(store_handle, session.session_id, tmpl)
  end

  defp load_template(%__MODULE__{store: {store_mod, store_handle}, session_id: sid}),
    do: store_mod.load_config_template(store_handle, sid)

  # The options Turn.Server.start_link/1 takes. :subscriber and :handlers only when set,
  # as before (Keyword.take of the caller's list).
  defp base_server_opts(%__MODULE__{} = session) do
    [session_id: session.session_id, store: session.store, registry: session.registry]
    |> put_set(:subscriber, session.subscriber)
    |> put_set(:handlers, session.handlers)
    |> Keyword.merge(session.server_options)
    |> Keyword.put(:resume_policy, session.resume_policy)
  end

  defp put_set(opts, _key, nil), do: opts
  defp put_set(opts, key, value), do: Keyword.put(opts, key, value)

  defp thin_server_opts(%__MODULE__{} = session),
    do: Keyword.put(base_server_opts(session), :template_provider, session.template_provider)

  # Start the server, tolerating Horde's eventually-consistent `:via` registration.
  # Two race shapes surface (and each supervisor nests them differently):
  #   * `{:already_started, pid}` — a concurrent caller won; route to that pid.
  #   * `{:process_not_registered_via, _}` — the via registration was not resolvable
  #     at start time (a concurrent winner mid-registration, OR a registry that has
  #     not converged yet). Route to the winner if one is now visible, else retry the
  #     start briefly. Genuine errors propagate unchanged.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp start_with_retry(sup_mod, sup, server_opts, reg_mod, reg_handle, sid, retries \\ 20) do
    case sup_mod.start_server(sup, server_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        cond do
          pid = already_started_pid(reason) ->
            {:ok, pid}

          via_race?(reason) and retries > 0 ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case reg_mod.whereis(reg_handle, sid) do
              {:ok, pid} ->
                {:ok, pid}

              :none ->
                Process.sleep(10)
                start_with_retry(sup_mod, sup, server_opts, reg_mod, reg_handle, sid, retries - 1)

              {:error, lookup_error} ->
                {:error, lookup_error}
            end

          true ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  # Extract the winner pid from either the bare or supervisor-nested already-started shape.
  defp already_started_pid({:already_started, pid}), do: pid
  defp already_started_pid({{:already_started, pid}, _child}), do: pid
  defp already_started_pid(_), do: nil

  # Recognize the via-not-registered race in either the bare or nested shape.
  defp via_race?({:process_not_registered_via, _}), do: true
  defp via_race?({{:process_not_registered_via, _}, _child}), do: true
  defp via_race?(_), do: false

  defp template_id_of(%__MODULE__{template_id: template_id}, config),
    do: template_id || config.name || "default"
end
```

(`validate_resume_policy!/1` is gone: the schema's `{:in, [:lazy, :eager]}` does it, in `new/1`.)

- [ ] **Step 4: `AgentProcess` holds the session**

In `lib/normandy/coordination/agent_process.ex`:

(a) After `@agent_id_key :"$normandy_agent_id"` (`:56`), add:

```elixir
  # start_link options that go to Turn.Session.new/1 in :server mode, besides the infra.
  @session_options [
    :supervisor_mod,
    :template_provider,
    :template_id,
    :resume_policy,
    :subscriber,
    :handlers,
    :approval_timeout_ms,
    :on_approval_timeout,
    :idle_timeout_ms
  ]
```

(b) In `init/1`, replace the `base` map keys

```elixir
      store: nil,
      registry: nil,
      supervisor: nil,
      supervisor_mod: Keyword.get(opts, :supervisor_mod, Normandy.Agents.Turn.Supervisor),
      template_provider: Keyword.get(opts, :template_provider),
      resume_policy: Keyword.get(opts, :resume_policy, :lazy),
      template_id: Keyword.get(opts, :template_id),
      extra_session_opts: [],
      owned: [],
```

with

```elixir
      # :server mode's Turn.Session handle, built once below. update_agent/2 is the only
      # writer of :agent in :server mode, and it refreshes the session's config.
      session: nil,
      owned: [],
```

and replace the `:server` branch's success clause

```elixir
          {:ok, store, registry, supervisor, owned} ->
            {:ok,
             %{
               base
               | store: store,
                 registry: registry,
                 supervisor: supervisor,
                 owned: owned,
                 extra_session_opts:
                   Keyword.take(opts, [
                     :subscriber,
                     :handlers,
                     :approval_timeout_ms,
                     :on_approval_timeout,
                     :idle_timeout_ms
                   ])
             }}
```

with

```elixir
          {:ok, store, registry, supervisor, owned} ->
            session =
              Turn.Session.new(
                [
                  session_id: agent_id,
                  config: agent,
                  store: store,
                  registry: registry,
                  supervisor: supervisor
                ] ++ Keyword.take(opts, @session_options)
              )

            {:ok, %{base | session: session, owned: owned}}
```

(c) Delete `session_opts/1` and its two comment lines (`:370-384`).

(d) `handle_call({:update_agent, update_fn}, _from, %{turn_engine: :server} = state)`: replace
the last line `{:reply, :ok, %{state | agent: new_agent}}` with

```elixir
    {:reply, :ok,
     %{state | agent: new_agent, session: Turn.Session.put_config(state.session, new_agent)}}
```

(e) `handle_call({:approve, decisions}, _from, %{turn_engine: :server} = state)`: replace
`Turn.Session.approve(session_opts(state), decisions)` with
`Turn.Session.approve(state.session, decisions)`.

(f) `handle_cast({:run_async, ...}, %{turn_engine: :server} = state)`: replace
`opts = session_opts(state)` with `session = state.session` and
`case Turn.Session.run(opts, user_input) do` with `case Turn.Session.run(session, user_input) do`.

(g) `spawn_run/3`: same two replacements (`opts = session_opts(state)` →
`session = state.session`; `Turn.Session.run(opts, user_input)` →
`Turn.Session.run(session, user_input)`).

(h) `reconstruct_agent/1`: replace the head
`defp reconstruct_agent(%{store: {mod, handle}, agent: agent, agent_id: sid}) do` with

```elixir
  defp reconstruct_agent(%{
         session: %Turn.Session{store: {mod, handle}},
         agent: agent,
         agent_id: sid
       }) do
```

(i) `approve/2` doc and spec (`:145-160`): replace the "Returns ..." paragraph and the spec with

```elixir
  Returns `:ok`; with no live parked session, `{:error, %Normandy.TurnError{type:
  :session_unavailable, reason: :no_session}}` (see `Normandy.Agents.Turn.Session.approve/2`);
  `{:error, :inline_mode}` when the process runs in `:inline` mode.
  """
  @spec approve(GenServer.server(), %{optional(String.t()) => :approve | :reject}) ::
          :ok | {:error, TurnError.t()} | {:error, :inline_mode}
```

(j) Moduledoc `:44-48`: replace the bullet starting "Session infra" with

```elixir
  - Session infra (`:store`, `:registry`, `:supervisor`) may be supplied via
    `start_link`; if omitted, the process starts and owns in-memory defaults
    that terminate with it. `start_link` builds one `Turn.Session` from them and from
    `:supervisor_mod`, `:template_provider`, `:template_id`, `:resume_policy`,
    `:subscriber`, `:handlers`, `:approval_timeout_ms`, `:on_approval_timeout` and
    `:idle_timeout_ms` (see `Turn.Session.new/1`; an invalid one stops the process);
    `update_agent/2` gives it the new config for the next server start.
```

Verify nothing reads the removed keys: `grep -n "state\.\(store\|registry\|supervisor\|extra_session_opts\|template_provider\|template_id\|resume_policy\)\|session_opts" lib/normandy/coordination/agent_process.ex` → no output.

- [ ] **Step 5: `TurnError` moduledoc**

`lib/normandy/turn_error.ex:30-31`, replace

```
    * `:session_unavailable` - the session could not be loaded or started (store,
      registry, template or credential failure); `:reason` is that failure
```

with

```
    * `:session_unavailable` - the session could not be loaded or started (store,
      registry, template or credential failure); `:reason` is that failure.
      `Turn.Session.approve/2` returns it with `reason: :no_session` when no server is live
```

- [ ] **Step 6: Migrate the call sites**

Mechanical rule: wrap the first argument of every `Session.run(` / `Session.approve(` in the
same module's `new/1`. Command (keeps each file's own alias spelling):

```bash
perl -0pi -e 's/((?:Normandy\.Agents\.)?(?:Turn\.)?Session)\.(run|approve)\((\s*)((?:[^(),\[\]{}]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)|\[(?:[^\[\]]|\[(?:[^\[\]]|\[[^\[\]]*\])*\])*\]|\{[^{}]*\})+?),/$1.$2($3$1.new($4),/g' \
  test/agents/turn/session_test.exs test/agents/turn/server_integration_test.exs \
  test/agents/turn/server_errors_test.exs test/agents/turn/server_postgres_e2e_test.exs \
  test/agents/turn/eager_handoff_distributed_test.exs test/agents/turn/tier2_integration_test.exs \
  test/support/e2e/distributed.ex
grep -c "Session.new(" test/agents/turn/session_test.exs test/agents/turn/server_integration_test.exs test/agents/turn/server_errors_test.exs test/agents/turn/server_postgres_e2e_test.exs test/agents/turn/eager_handoff_distributed_test.exs test/agents/turn/tier2_integration_test.exs test/support/e2e/distributed.ex
```

Expected counts (37 total, verified against HEAD 95dc149 on a copy): session_test 25,
server_integration 3, server_errors 3, server_postgres_e2e 2, eager_handoff_distributed 1,
tier2_integration 1, distributed.ex 2. Run the perl before the explicit edits below (they
contain `Turn.Session.run(session, ...)` with a struct, which must not be wrapped again).

Then these explicit edits (after the perl):

1. `session_test.exs`, the test `"approve/2 returns {:error, :no_session} for an unknown session"`
   (`:164-171`) becomes:

```elixir
  test "approve/2 returns a :session_unavailable TurnError for an unknown session" do
    session =
      Turn.Session.new(
        session_id: "ghost",
        config: session_config(),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        supervisor: self(),
        supervisor_mod: CapturingSupervisor
      )

    # No live session exists, so approval cannot succeed and must not boot one.
    assert {:error, %TurnError{type: :session_unavailable, reason: :no_session}} =
             Turn.Session.approve(session, %{})

    refute_received {:server_opts, _}
  end
```

   (`CapturingSupervisor`, defined at the top of the file, reports any start as
   `{:server_opts, opts}`; `NoStartSupervisor` cannot be used here because it is defined
   further down, after this test, so its alias is not in scope yet.)

2. `session_test.exs` `:248`: replace
   `assert {:error, :registry_down} = Turn.Session.approve(Turn.Session.new(opts), %{})` with

```elixir
    assert {:error, %TurnError{type: :session_unavailable, reason: :registry_down}} =
             Turn.Session.approve(Turn.Session.new(opts), %{})
```

3. `session_test.exs`, the test `"any other value is rejected"` in `describe "resume_policy: :eager"`
   (`:356-378`): delete it (the `new/1` describe covers it, `":resume_policy must be :lazy or :eager"`).

4. `server_errors_test.exs`, the test `"a server whose start_link raises replies :session_unavailable with no stacktrace"`
   (`:171-192`): `new/1` now rejects `on_approval_timeout: :sometimes` before any start, so
   reach `Turn.Server.start_link/1`'s own check by editing a valid handle. Replace the
   `assert ... = Turn.Session.run(Turn.Session.new([...]), "hi")` expression with:

```elixir
    session =
      Turn.Session.new(
        session_id: "s-bad-opt-#{System.unique_integer([:positive])}",
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        supervisor: sup,
        config: BaseAgent.init(%{client: %Normandy.Test.StubClient{}, model: "m"})
      )

    # Bypasses new/1's check on purpose: this test is about a start_link that raises.
    session = %{session | server_options: [on_approval_timeout: :sometimes]}

    assert {:error, %TurnError{type: :session_unavailable, reason: reason} = error} =
             Turn.Session.run(session, "hi")
```

   (keep the two assertions that follow).

5. `e2e/04_durable_server.exs:15-30`: replace `opts = [` ... `]` with
   `opts = Turn.Session.new([` ... `])` (same keys); `Turn.Session.run(opts, ...)` stays.

6. `e2e/05_approvals.exs:46-56`: the body of `session = fn sid, mode -> ... end` becomes
   `Turn.Session.new([` ... `])` (same keys). `:60`: replace `opts[:session_id]` with
   `opts.session_id` (a struct has no `Access`). `:92` (`Turn.Session.approve(opts, ...)`)
   stays.

7. `docs/guides/agent-memory.md`, the `Session.run(` call (`:65-76`) becomes:

```elixir
session =
  Session.new(
    session_id: sid,
    registry: {Native, MyApp.SessionRegistry},
    supervisor: MyApp.TurnSupervisor,
    store: session_store,
    template_provider: {Catalog, MyApp.AgentTemplates},
    template_id: "support-bot",
    config: session_config
  )

Session.run(session, input)
```

   and the sentence after the block, "See `distributed_sessions.md` for the rest of the
   session options." becomes "`Turn.Session.new/1` lists every session option."

8. `docs/guides/distributed_sessions.md:45-46`: "Then pass `store: {...}` to the session
   opts." becomes "Then pass `store: {Normandy.Behaviours.SessionStore.Postgres, MyApp.Repo}`
   to `Turn.Session.new/1`."

Check nothing calls the old shape: read every hit of
`grep -rn "Session\.\(run\|approve\)(" lib test e2e docs/guides`. Each first argument must be
a `Session.new(...)` call, `state.session`/`session` (bound to one) or, in `e2e/04` and
`e2e/05`, `opts` (now bound to one). A miss also fails loudly in Step 7: `run/2` and
`approve/2` raise the "expected a %Normandy.Agents.Turn.Session{}" `ArgumentError` for a list.

- [ ] **Step 7: Run to verify they pass**

Run: `mix test test/agents/turn/ test/coordination/agent_process_server_test.exs test/coordination/agent_process_test.exs`
Expected: ` 0 failures` (the `:distributed`, `:postgres` and `:integration` tags are excluded by
default; run `mix test --include postgres test/agents/turn/server_postgres_e2e_test.exs` and
`mix test --include distributed test/agents/turn/eager_handoff_distributed_test.exs` if those
services are up, and say in the commit body whether they ran).

- [ ] **Step 8: MIGRATING**

Insert before `## New, non-breaking`, as §26 (after Task 3.4's §25):

````markdown
## 26. `Turn.Session` is a handle built once

`Turn.Session.run/2` and `Turn.Session.approve/2` take a `%Turn.Session{}` from
`Turn.Session.new/1` instead of the option list. `new/1` checks the options once: an
unknown or misspelled key, a missing `:session_id`, `:registry`, `:supervisor` or `:store`,
a value of the wrong type, or neither `:config` nor `:template_provider` raises
`ArgumentError` naming the key. `:session_id` must be a string.

```elixir
# 1.x
Turn.Session.run([session_id: sid, config: config, store: store, registry: reg, supervisor: sup], input)
:ok = Turn.Session.approve([session_id: sid, registry: reg], decisions)

# 2.0
session = Turn.Session.new(session_id: sid, config: config, store: store, registry: reg, supervisor: sup)
{:ok, output} = Turn.Session.run(session, input)
:ok = Turn.Session.approve(session, decisions)
```

- `approve/2` takes the same handle as `run/2` (1.x read only `:session_id` and `:registry`).
- With no live server, `approve/2` returns `{:error, %Normandy.TurnError{type:
  :session_unavailable, reason: :no_session}}` (was `{:error, :no_session}`); a registry that
  cannot answer gives the same `TurnError` with the registry's reason (was the bare reason).
  `AgentProcess.approve/2` returns what `Turn.Session.approve/2` returns.
- `Turn.Session.put_config/2` sets the config a later server start uses. A live server keeps
  the config it started with, as before.
- A `:resume_policy` other than `:lazy` or `:eager` raises in `new/1`, not in `run/2`.
- `AgentProcess` in `:server` mode builds its session in `start_link/1`: an invalid
  `:template_provider`, `:resume_policy`, `:approval_timeout_ms` ... stops the process at
  start instead of failing the first turn.
````

- [ ] **Step 9: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`.

```bash
git add lib/normandy/agents/turn/session.ex lib/normandy/coordination/agent_process.ex lib/normandy/turn_error.ex docs/guides/agent-memory.md docs/guides/distributed_sessions.md e2e/04_durable_server.exs e2e/05_approvals.exs test/support/e2e/distributed.ex MIGRATING-2.0.md test/agents/turn/session_test.exs test/agents/turn/server_errors_test.exs test/agents/turn/server_integration_test.exs test/agents/turn/server_postgres_e2e_test.exs test/agents/turn/eager_handoff_distributed_test.exs test/agents/turn/tier2_integration_test.exs test/coordination/agent_process_server_test.exs
git commit -m "feat(session)!: Turn.Session.new/1 builds a validated handle for run/2 and approve/2" -m "BREAKING CHANGE: Turn.Session.run/2 and approve/2 take a %Turn.Session{}; approve/2 returns a :session_unavailable TurnError instead of {:error, :no_session}. AgentProcess holds one session and refreshes its config on update_agent/2. See MIGRATING-2.0.md."
```

---

### Task 3.5b: `ParallelOrchestrator.execute(agents, input, opts \\ [])` and the orchestrator result shape (DX-15)

**Ruling (Q may override): one result shape, a map keyed by agent id, strict on failure.**

```elixir
{:ok, results}                                    # every agent succeeded
{:error, %Normandy.OrchestrationError{results: results, errors: errors}}  # one or more failed
results :: %{agent_id :: String.t() => output}    # output: the agent's response after :transform
errors  :: %{agent_id :: String.t() => Exception.t()}
```

Why a map keyed by id and not a list: `ParallelOrchestrator` already keys by id (completion
order is not agent order), `HierarchicalCoordinator` consumes a map by id (`aggregation_message/1`,
`hierarchical_coordinator.ex:362-374`), `Reactive.all/3` and `Reactive.some/3` return
`%{id => ...}` maps, and a failure must say *which* agent failed — a list needs the ids anyway.
Order is recoverable from the caller's own spec list; for a pipeline the output is
`results[last_id]`. Ids must therefore be unique (a repeated id raises; today Parallel
silently keeps one of them). Why strict (`{:error, ...}` when any agent failed) rather than
`{:ok, %{id => {:ok, out} | {:error, e}}}`: a caller cannot match `{:ok, results}` and
forget a failure, and `OrchestrationError` still carries every success. Why per-agent errors
are exceptions: decisions 6 and 15b (`{:exception, e, stacktrace}` and `{:exit, reason}`
tuples carry stacktraces and are the tagged tuples Wave 2 removed elsewhere).

What leaves with the old shape: `success`, `context` and `aggregated` fields, so the options
that only fed them — `:shared_context`, `:aggregate`, `:ordered` (Parallel) and
`:store_intermediate` (Sequential, Task 3.5c) — are removed and rejected by name.
`execute_same_input/3` is removed: it is `execute(specs, input, opts)`.

**Files:**
- Create: `lib/normandy/orchestration_error.ex`, `lib/normandy/coordination/orchestration.ex`
- Modify: `lib/normandy/coordination/parallel_orchestrator.ex` (whole file, 406 lines today)
- Modify: `lib/normandy/coordination/hierarchical_coordinator.ex:25`, `:113-116`, `:163-168`, `:390-395`
- Modify: `lib/normandy/telemetry.ex:167`, `mix.exs:140-143` (Errors group)
- Modify: `MIGRATING-2.0.md` (new section before `## New, non-breaking`)
- Test: `test/coordination/orchestrator_contract_test.exs` (create), `test/coordination/parallel_orchestrator_test.exs` (rewrite), `test/telemetry/killed_run_test.exs:236-247,280-288`, `test/telemetry/span_hierarchy_test.exs:584,665`, `test/telemetry/workflow_span_test.exs:88-104`, `test/integration/multi_agent_workflows_test.exs:78-83`, `test/normandy_integration/multi_agent_test.exs:75-80`

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`, `Normandy.Options.docs/1` (Task 3.1); `Normandy.TurnError.log_raised/3`, `TurnError.from_reason/1` (existing).
- Produces:
  - `ParallelOrchestrator.execute([agent], input, keyword()) :: {:ok, %{String.t() => term()}} | {:error, Normandy.OrchestrationError.t()}` where `agent :: %BaseAgentConfig{} | %{required(:id) => String.t(), required(:agent) => %BaseAgentConfig{}, optional(:input) => term(), optional(:transform) => (term() -> term())}`. Options: `:max_concurrency` (10), `:timeout` (300_000), `:on_agent_complete` (`fn id, output -> any end`).
  - `Normandy.OrchestrationError` (`defexception results: %{}, errors: %{}`).
  - `Normandy.Coordination.Orchestration` (`@moduledoc false`): `specs!/3`, `run_agent/3`, `guard/2`, `result/2` — Task 3.5c reuses them.
  - `ParallelOrchestrator.execute_stream/2` keeps its signature; a failed agent is `{:ok, {:error, {id, exception}}}`.
  - Removed: `ParallelOrchestrator.execute/2` (the overloaded form), `execute_same_input/3`.

- [ ] **Step 1: Write the failing tests**

Create `test/coordination/orchestrator_contract_test.exs`:

```elixir
defmodule Normandy.Coordination.OrchestratorContractTest do
  @moduledoc """
  Every orchestrator's execute/3 returns {:ok, %{agent_id => output}} when each agent
  succeeded and {:error, %Normandy.OrchestrationError{}} otherwise. A new orchestrator
  joins @orchestrators.
  """
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Coordination.ParallelOrchestrator
  alias Normandy.OrchestrationError
  alias Normandy.Test.{StubClient, TaggingClient}
  alias Normandy.TurnError

  @moduletag :capture_log

  @orchestrators [ParallelOrchestrator]

  defp agent(name, opts \\ []),
    do: BaseAgent.init(%{client: struct(TaggingClient, [name: name] ++ opts), model: "test-model"})

  for orchestrator <- @orchestrators do
    describe "#{inspect(orchestrator)}.execute/3" do
      @orchestrator orchestrator

      test "every agent succeeds: {:ok, outputs keyed by spec id}" do
        assert {:ok, results} =
                 @orchestrator.execute(
                   [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}],
                   "go"
                 )

        assert results |> Map.keys() |> Enum.sort() == ["a", "b"]
        assert results["a"].chat_message =~ "a("
        assert results["b"].chat_message =~ "b("
      end

      test "bare agents are keyed agent_0, agent_1, ... in list order" do
        assert {:ok, results} = @orchestrator.execute([agent("a"), agent("b")], "go")
        assert results |> Map.keys() |> Enum.sort() == ["agent_0", "agent_1"]
        assert results["agent_0"].chat_message =~ "a("
        assert results["agent_1"].chat_message =~ "b("
      end

      test "a struct input reaches the first agent" do
        assert {:ok, %{"agent_0" => %{chat_message: "a(x)"}}} =
                 @orchestrator.execute(
                   [agent("a"), agent("b")],
                   %BaseAgentInputSchema{chat_message: "x"}
                 )
      end

      test "no agents: {:ok, %{}}" do
        assert {:ok, %{}} = @orchestrator.execute([], "go")
      end

      test "a failing agent: {:error, %OrchestrationError{}} keeping the other outputs" do
        assert {:error, %OrchestrationError{results: results, errors: errors} = error} =
                 @orchestrator.execute(
                   [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b", fail_on: "go")}],
                   "go"
                 )

        assert Map.keys(results) == ["a"]
        assert %{"b" => %RuntimeError{message: "b failed"}} = errors
        assert Exception.message(error) == ~s|1 agent(s) failed: "b" (RuntimeError)|
      end

      test "an agent that exits fails with a :task_down TurnError, not an exit of the caller" do
        exiting =
          BaseAgent.init(%{client: %StubClient{reply: fn _ -> exit(:boom) end}, model: "test-model"})

        assert {:error,
                %OrchestrationError{errors: %{"e" => %TurnError{type: :task_down, reason: :boom}}}} =
                 @orchestrator.execute([%{id: "e", agent: exiting}], "x")
      end

      test "a repeated id raises before any agent runs" do
        assert_raise ArgumentError,
                     "#{inspect(@orchestrator)}.execute/3: agent ids must be unique, " <>
                       ~s(got ["a"] more than once),
                     fn ->
                       @orchestrator.execute(
                         [%{id: "a", agent: agent("a")}, %{id: "a", agent: agent("b")}],
                         "x"
                       )
                     end
      end

      test "something that is not an agent raises naming its position" do
        error =
          assert_raise ArgumentError, fn ->
            @orchestrator.execute([agent("a"), %{agent: agent("b")}], "x")
          end

        assert error.message =~
                 "#{inspect(@orchestrator)}.execute/3: agent 1 must be a " <>
                   "%Normandy.Agents.BaseAgentConfig{} or a spec"

        assert error.message =~ "got: a map"
      end

      test "an unknown spec key raises naming it" do
        error =
          assert_raise ArgumentError, fn ->
            @orchestrator.execute([%{id: "a", agent: agent("a"), retries: 3}], "x")
          end

        assert error.message =~
                 "#{inspect(@orchestrator)}.execute/3: unknown agent spec keys [:retries]"
      end

      test "an unknown option names the function and the key" do
        error =
          assert_raise ArgumentError, fn ->
            @orchestrator.execute([agent("a")], "x", shared_context: :ctx)
          end

        assert error.message =~ "#{inspect(@orchestrator)}.execute/3: "
        assert error.message =~ ":shared_context"
      end
    end
  end
end
```

Replace `test/coordination/parallel_orchestrator_test.exs` with:

```elixir
defmodule Normandy.Coordination.ParallelOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, BaseAgentInputSchema}
  alias Normandy.Coordination.ParallelOrchestrator
  alias Normandy.OrchestrationError
  alias Normandy.Test.{StubClient, TaggingClient}
  alias Normandy.TurnError

  @moduletag :capture_log

  defp tagging(name, opts \\ []) do
    BaseAgent.init(%{client: struct(TaggingClient, [name: name] ++ opts), model: "test-model"})
  end

  # An agent whose model call exits (as a timed-out GenServer.call does) instead of raising.
  defp exiting_agent,
    do:
      BaseAgent.init(%{client: %StubClient{reply: fn _ -> exit(:boom) end}, model: "test-model"})

  describe "execute/3 input" do
    test "a struct input reaches every agent" do
      assert {:ok, %{"agent_0" => a, "agent_1" => b}} =
               ParallelOrchestrator.execute(
                 [tagging("a"), tagging("b")],
                 %BaseAgentInputSchema{chat_message: "x"}
               )

      assert a.chat_message == "a(x)"
      assert b.chat_message == "b(x)"
    end

    test "a string or a chat_message map reaches every agent" do
      specs = [%{id: "a", agent: tagging("a")}, %{id: "b", agent: tagging("b")}]

      for input <- ["x", %{chat_message: "x"}] do
        assert {:ok, %{"a" => %{chat_message: "a(x)"}, "b" => %{chat_message: "b(x)"}}} =
                 ParallelOrchestrator.execute(specs, input)
      end
    end

    test "a spec's :input replaces the shared input for that agent" do
      specs = [%{id: "a", agent: tagging("a"), input: "one"}, %{id: "b", agent: tagging("b")}]

      assert {:ok, %{"a" => %{chat_message: "a(one)"}, "b" => %{chat_message: "b(two)"}}} =
               ParallelOrchestrator.execute(specs, "two")
    end

    test "a :transform shapes the agent's output" do
      specs = [
        %{id: "a", agent: tagging("a"), transform: &String.upcase(&1.chat_message)}
      ]

      assert {:ok, %{"a" => "A(X)"}} = ParallelOrchestrator.execute(specs, "x")
    end
  end

  describe "execute/3 options" do
    test ":on_agent_complete is called once per successful agent with its output" do
      parent = self()
      specs = [%{id: "a", agent: tagging("a")}, %{id: "b", agent: tagging("b")}]

      {:ok, _} =
        ParallelOrchestrator.execute(specs, "x",
          on_agent_complete: fn id, output -> send(parent, {:done, id, output.chat_message}) end
        )

      assert_received {:done, "a", "a(x)"}
      assert_received {:done, "b", "b(x)"}
    end

    test "an agent past :timeout fails with a :task_down TurnError; the others still finish" do
      specs = [
        %{id: "fast", agent: tagging("fast")},
        %{id: "slow", agent: tagging("slow", sleep_ms: 500)}
      ]

      assert {:error,
              %OrchestrationError{
                results: %{"fast" => _},
                errors: %{"slow" => %TurnError{type: :task_down, reason: :timeout}}
              }} = ParallelOrchestrator.execute(specs, "x", timeout: 100)
    end

    test "agents run concurrently" do
      specs = for n <- 1..4, do: %{id: "#{n}", agent: tagging("#{n}", sleep_ms: 200)}
      start = System.monotonic_time(:millisecond)

      {:ok, _} = ParallelOrchestrator.execute(specs, "x", max_concurrency: 4)

      # Four 200 ms agents in sequence would take 800 ms.
      assert System.monotonic_time(:millisecond) - start < 600
    end

    test "the 1.x options are rejected by name" do
      for {key, value} <- [shared_context: %{}, aggregate: &Function.identity/1, ordered: true] do
        error =
          assert_raise ArgumentError, fn ->
            ParallelOrchestrator.execute([tagging("a")], "x", [{key, value}])
          end

        assert error.message =~ "Normandy.Coordination.ParallelOrchestrator.execute/3: "
        assert error.message =~ inspect(key)
      end
    end
  end

  describe "callbacks that raise" do
    test "a raising :transform is the agent's error, not a crash of the caller" do
      specs = [
        %{id: "ok", agent: tagging("ok")},
        %{id: "t", agent: tagging("t"), transform: fn _ -> raise "transform failed" end}
      ]

      assert {:error,
              %OrchestrationError{
                results: %{"ok" => _},
                errors: %{"t" => %RuntimeError{message: "transform failed"}}
              }} = ParallelOrchestrator.execute(specs, "x")
    end

    test "a raising :on_agent_complete is the agent's error, not a crash of the caller" do
      assert {:error, %OrchestrationError{errors: %{"a" => %RuntimeError{message: "boom"}}}} =
               ParallelOrchestrator.execute([%{id: "a", agent: tagging("a")}], "x",
                 on_agent_complete: fn _, _ -> raise "boom" end
               )
    end

    test "execute_stream/2: a raising :transform is the agent's error" do
      specs = [%{id: "t", agent: tagging("t"), input: "x", transform: fn _ -> raise "no" end}]

      assert [{:ok, {:error, {"t", %RuntimeError{message: "no"}}}}] =
               specs |> ParallelOrchestrator.execute_stream() |> Enum.to_list()
    end
  end

  describe "execute_stream/2" do
    test "yields an exit as a :task_down TurnError" do
      specs = [%{id: "exits", agent: exiting_agent(), input: "x"}]

      assert [{:ok, {:error, {"exits", %TurnError{type: :task_down, reason: :boom}}}}] =
               specs |> ParallelOrchestrator.execute_stream() |> Enum.to_list()
    end

    test "an agent past :timeout is reported by id; the stream goes on" do
      specs = [
        %{id: "fast", agent: tagging("fast"), input: "x"},
        # Killed at the timeout; the margin keeps "fast" in time on a loaded machine.
        %{id: "slow", agent: tagging("slow", sleep_ms: 10_000), input: "x"}
      ]

      outcomes = specs |> ParallelOrchestrator.execute_stream(timeout: 1_000) |> Enum.to_list()

      assert {:exit, {"slow", :timeout}} in outcomes
      assert Enum.any?(outcomes, &match?({:ok, {:ok, {"fast", _}}}, &1))
    end

    test "yields each agent's result or error tagged with its id" do
      specs = [
        %{id: "a", agent: tagging("a"), input: "x"},
        %{id: "bad", agent: tagging("bad", fail_on: "x"), input: "x"}
      ]

      outcomes = specs |> ParallelOrchestrator.execute_stream() |> Enum.map(fn {:ok, r} -> r end)

      assert {:ok, {"a", %{chat_message: "a(" <> _}}} = Enum.find(outcomes, &match?({:ok, _}, &1))

      assert {:error, {"bad", %RuntimeError{message: "bad failed"}}} =
               Enum.find(outcomes, &match?({:error, _}, &1))
    end
  end
end
```

(The dropped tests — "results and context are keyed by id", ":aggregate receives ...",
"execute/2 with plain agents", "execute/2 reports the exit under the agent's id" — are covered
by the contract test or test removed features.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/coordination/orchestrator_contract_test.exs test/coordination/parallel_orchestrator_test.exs`
Expected: FAIL. `Normandy.OrchestrationError.__struct__/1 is undefined` (compile error in
both files) — after a stub, `execute/3` with a struct input raises a `KeyError` /
`BadMapError` (`:erlang.map_get(:id, %BaseAgentConfig{...})`, the bug this task fixes) and
the spec forms return `{:ok, %{success: ...}}`.

- [ ] **Step 3: Create `lib/normandy/orchestration_error.ex`**

```elixir
defmodule Normandy.OrchestrationError do
  @moduledoc """
  One or more agents of a `Normandy.Coordination.SequentialOrchestrator.execute/3` or
  `Normandy.Coordination.ParallelOrchestrator.execute/3` call failed.

    * `:results` - `%{agent_id => output}` for the agents that succeeded.
    * `:errors` - `%{agent_id => exception}` for the agents that failed: Normandy's own
      exception (`Normandy.LLMError`, `Normandy.Schema.ValidationError`, ...), the
      exception a bug raised (logged with its stacktrace where it was raised; the
      stacktrace is not kept here), or a `:task_down` `Normandy.TurnError` for an agent
      that exited (`reason` the exit reason) or ran past `:timeout` (`reason: :timeout`).

  An agent in neither map did not run (`SequentialOrchestrator` with `on_error: :stop`).
  The message names the failed agents and their exception modules, never values from
  them.
  """
  defexception results: %{}, errors: %{}

  @type t :: %__MODULE__{
          results: %{String.t() => term()},
          errors: %{String.t() => Exception.t()}
        }

  @impl true
  def message(%__MODULE__{errors: errors}) do
    failed =
      errors
      |> Enum.sort_by(fn {id, _exception} -> id end)
      |> Enum.map_join(", ", fn {id, %module{}} -> "#{inspect(id)} (#{inspect(module)})" end)

    "#{map_size(errors)} agent(s) failed: #{failed}"
  end
end
```

- [ ] **Step 4: Create `lib/normandy/coordination/orchestration.ex`**

```elixir
defmodule Normandy.Coordination.Orchestration do
  @moduledoc false
  # What SequentialOrchestrator and ParallelOrchestrator share: the agent list's normal
  # form, one agent's run, and the {:ok, results} | {:error, OrchestrationError} shape.

  alias Normandy.Agents.{BaseAgent, BaseAgentConfig}
  alias Normandy.Components.ContentBlock.Describe
  alias Normandy.OrchestrationError
  alias Normandy.TurnError

  @type spec :: %{
          required(:id) => String.t(),
          required(:agent) => BaseAgentConfig.t(),
          optional(:input) => term(),
          optional(:transform) => (term() -> term())
        }

  @type agent :: BaseAgentConfig.t() | spec()

  @type result ::
          {:ok, %{String.t() => term()}} | {:error, OrchestrationError.t()}

  # The agents as specs, in list order. A bare %BaseAgentConfig{} gets the id
  # "agent_<index>". A spec key outside `allowed`, a repeated id or anything that is not
  # an agent raises: results are keyed by id, so a repeated id would hide an output.
  @spec specs!(term(), [atom()], String.t()) :: [spec()]
  def specs!(agents, allowed, caller) when is_list(agents) do
    specs =
      agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, idx} -> spec!(agent, idx, allowed, caller) end)

    repeated =
      specs
      |> Enum.frequencies_by(& &1.id)
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)
      |> Enum.sort()

    if repeated != [] do
      raise ArgumentError,
            "#{caller}: agent ids must be unique, got #{inspect(repeated)} more than once"
    end

    specs
  end

  def specs!(other, _allowed, caller) do
    raise ArgumentError,
          "#{caller}: expected a list of agents, got: " <> Describe.type_of(other)
  end

  defp spec!(%BaseAgentConfig{} = agent, idx, _allowed, _caller),
    do: %{id: "agent_#{idx}", agent: agent}

  defp spec!(%{id: id, agent: %BaseAgentConfig{}} = spec, _idx, allowed, caller)
       when is_binary(id) and not is_struct(spec) do
    case spec |> Map.keys() |> Enum.reject(&(&1 in allowed)) do
      [] ->
        spec

      unknown ->
        raise ArgumentError,
              "#{caller}: unknown agent spec keys #{inspect(Enum.sort(unknown))} " <>
                "for #{inspect(id)}, supported: #{inspect(allowed)}"
    end
  end

  defp spec!(other, idx, allowed, caller) do
    raise ArgumentError,
          "#{caller}: agent #{idx} must be a %Normandy.Agents.BaseAgentConfig{} or a spec " <>
            "with keys #{inspect(allowed)} (:id a string, :agent a " <>
            "%Normandy.Agents.BaseAgentConfig{}), got: " <> Describe.type_of(other)
  end

  # One agent's run: {:ok, output} or {:error, exception}, never a stacktrace. Normandy's
  # own errors come back from BaseAgent.run/2; a raise (a bug) is logged with its
  # stacktrace (arities only) and returned; an exit (a timed-out GenServer.call, a client
  # that exits) is a :task_down TurnError.
  @spec run_agent(String.t(), BaseAgentConfig.t(), term()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_agent(id, %BaseAgentConfig{} = agent, input) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _agent, output} -> {:ok, output}
      {:error, exception} -> {:error, exception}
    end
  rescue
    e -> TurnError.log_raised("Agent #{inspect(id)}", e, __STACKTRACE__)
  catch
    :exit, reason -> {:error, TurnError.from_reason({:task_down, reason})}
  end

  # A spec's callback (:transform, :on_agent_complete) run where a crash would take the
  # caller down (a linked task): a raise or an exit becomes that agent's error, as in
  # run_agent/3.
  @spec guard(String.t(), (-> term())) :: {:ok, term()} | {:error, Exception.t()}
  def guard(id, fun) do
    {:ok, fun.()}
  rescue
    e -> TurnError.log_raised("Agent #{inspect(id)} callback", e, __STACKTRACE__)
  catch
    :exit, reason -> {:error, TurnError.from_reason({:task_down, reason})}
  end

  @spec result(%{String.t() => term()}, %{String.t() => Exception.t()}) :: result()
  def result(results, errors) when map_size(errors) == 0, do: {:ok, results}
  def result(results, errors), do: {:error, %OrchestrationError{results: results, errors: errors}}

  # A string or a map with a chat_message is the chat message; a struct goes as is.
  defp prepare_input(input) when is_binary(input), do: %{chat_message: input}

  defp prepare_input(input) when is_map(input) and not is_struct(input),
    do: Map.get(input, :chat_message) || Map.get(input, "chat_message") || input

  defp prepare_input(input), do: input
end
```

(`prepare_input/1` is today's `SequentialOrchestrator.prepare_input/1`, moved; Parallel's
`is_map_key(:__struct__)` version has the same effect.)

- [ ] **Step 5: Rewrite `lib/normandy/coordination/parallel_orchestrator.ex`**

Replace the whole file with:

```elixir
defmodule Normandy.Coordination.ParallelOrchestrator do
  alias Normandy.Coordination.Orchestration
  alias Normandy.Telemetry.KilledRun
  alias Normandy.Telemetry.OtelCtx
  alias Normandy.Telemetry.WorkflowSpan
  alias Normandy.TurnError

  @opts_schema NimbleOptions.new!(
                 max_concurrency: [
                   type: :pos_integer,
                   default: 10,
                   doc: "How many agents run at once."
                 ],
                 timeout: [
                   type: :pos_integer,
                   default: 300_000,
                   doc:
                     "Each agent's limit in ms. An agent past it is stopped and fails with " <>
                       "`%Normandy.TurnError{type: :task_down, reason: :timeout}`."
                 ],
                 on_agent_complete: [
                   type: {:fun, 2},
                   doc:
                     "`fn agent_id, output -> any end`, called in the agent's task after it " <>
                       "succeeds (after `:transform`). A raise in it is that agent's error."
                 ]
               )

  @spec_keys [:id, :agent, :input, :transform]

  @moduledoc """
  Runs agents concurrently on one input.

      {:ok, results} =
        ParallelOrchestrator.execute(
          [%{id: "pros", agent: pros_agent}, %{id: "cons", agent: cons_agent}],
          %{chat_message: "Should we adopt Elixir?"},
          max_concurrency: 2
        )

      results["pros"].chat_message

  `agents` holds `%Normandy.Agents.BaseAgentConfig{}` structs (keyed `"agent_0"`,
  `"agent_1"`, ... in list order) or specs `%{id: id, agent: config}` with an optional
  `:transform` (`fn output -> term end`, applied to the agent's output) and an optional
  `:input`, which replaces `input` for that agent:

      ParallelOrchestrator.execute(
        [%{id: "a", agent: agent, input: query_a}, %{id: "b", agent: agent, input: query_b}],
        nil
      )

  ## Results

  `{:ok, %{id => output}}` when every agent succeeded; otherwise
  `{:error, %Normandy.OrchestrationError{results: %{id => output}, errors: %{id =>
  exception}}}`, with every agent in one of the two maps. A failure never stops the other
  agents or exits the caller. See `Normandy.OrchestrationError` for what the exceptions
  are.

  ## Telemetry

  An agent that runs past `:timeout` is killed mid-run, so its
  `[:normandy, :agent, :run]` span never closes on its own. `execute/3` and
  `execute_stream/2` emit a synthetic `[:normandy, :agent, :run, :exception]`
  with `reason: :killed` for it (`execute_stream/2` when the timed-out element
  is consumed) unless its run had already returned and the timeout hit its
  `:transform` or `:on_agent_complete` callback, possibly without a matching `:start`;
  the `llm_call`/`tool` spans open inside it stay open. See `Normandy.Telemetry.KilledRun`.
  """

  @doc """
  Runs `agents` concurrently, each on `input` or its spec's `:input`; see "Results".

  ## Options

  #{Normandy.Options.docs(@opts_schema)}
  """
  @spec execute([Orchestration.agent()], term(), keyword()) :: Orchestration.result()
  def execute(agents, input, opts \\ []) do
    opts = Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute, 3})
    specs = Orchestration.specs!(agents, @spec_keys, "#{inspect(__MODULE__)}.execute/3")

    WorkflowSpan.span(:parallel, %{step_count: length(specs)}, fn ->
      run_specs(specs, input, opts)
    end)
  end

  # Runs specs without opening a workflow span, for HierarchicalCoordinator, which already
  # holds one so a call yields exactly one span. Every spec carries its own :input.
  @doc false
  @spec execute_specs([Orchestration.spec()], keyword()) :: Orchestration.result()
  def execute_specs(specs, opts) do
    opts = Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute_specs, 2})

    specs
    |> Orchestration.specs!(@spec_keys, "#{inspect(__MODULE__)}.execute_specs/2")
    |> run_specs(nil, opts)
  end

  defp run_specs(specs, input, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    on_complete = opts[:on_agent_complete]
    parent_otel_ctx = OtelCtx.capture()
    run_marks = KilledRun.new_run_marks(length(specs))

    outcomes =
      specs
      |> Enum.with_index()
      |> Task.async_stream(
        fn {spec, idx} ->
          OtelCtx.restore(parent_otel_ctx)
          on_run_done = fn -> KilledRun.mark_run_done(run_marks, idx) end
          {spec.id, run_spec(spec, input, on_complete, on_run_done)}
        end,
        max_concurrency: Keyword.fetch!(opts, :max_concurrency),
        timeout: timeout,
        # A slow agent fails on its own instead of exiting the caller.
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.to_list()

    Enum.each(outcomes, &report_kill(&1, run_marks, timeout, parent_otel_ctx))

    {results, errors} =
      Enum.reduce(outcomes, {%{}, %{}}, fn
        {:ok, {id, {:ok, output}}}, {ok, failed} ->
          {Map.put(ok, id, output), failed}

        {:ok, {id, {:error, exception}}}, {ok, failed} ->
          {ok, Map.put(failed, id, exception)}

        # Killed past :timeout (reason :timeout), or the task died.
        {:exit, {{%{id: id}, _idx}, reason}}, {ok, failed} ->
          {ok, Map.put(failed, id, TurnError.from_reason({:task_down, reason}))}
      end)

    Orchestration.result(results, errors)
  end

  @doc """
  Runs agent specs and yields each result as its agent finishes. Each element is one of:

  - `{:ok, {:ok, {agent_id, output}}}` - the agent finished
  - `{:ok, {:error, {agent_id, exception}}}` - the agent failed (exceptions as in
    `Normandy.OrchestrationError`)
  - `{:exit, {agent_id, :timeout}}` - the agent ran past `:timeout` and was stopped

  Emits no `[:normandy, :workflow, :run]` span: the stream is lazy, so it has no
  defined start and end (a current limitation).

  ## Example

      stream = ParallelOrchestrator.execute_stream(specs, timeout: 60_000)

      stream
      |> Stream.each(fn
        {:ok, {:ok, {agent_id, output}}} -> IO.puts("Agent \#{agent_id}: \#{inspect(output)}")
        {:ok, {:error, {agent_id, e}}} -> IO.puts("Agent \#{agent_id} failed: \#{Exception.message(e)}")
        {:exit, {agent_id, :timeout}} -> IO.puts("Agent \#{agent_id} timed out")
      end)
      |> Stream.run()
  """
  @spec execute_stream([Orchestration.spec()], keyword()) :: Enumerable.t()
  def execute_stream(agent_specs, opts \\ []) do
    specs = Orchestration.specs!(agent_specs, @spec_keys, "#{inspect(__MODULE__)}.execute_stream/2")
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    timeout = Keyword.get(opts, :timeout, 300_000)

    parent_otel_ctx = OtelCtx.capture()

    # Run marks are per enumeration, so they're made when the stream runs.
    Stream.flat_map([specs], fn specs ->
      stream_specs(specs, max_concurrency, timeout, parent_otel_ctx)
    end)
  end

  defp stream_specs(specs, max_concurrency, timeout, parent_otel_ctx) do
    run_marks = KilledRun.new_run_marks(length(specs))

    Task.async_stream(
      Enum.with_index(specs),
      fn {spec, idx} ->
        OtelCtx.restore(parent_otel_ctx)
        on_run_done = fn -> KilledRun.mark_run_done(run_marks, idx) end

        case run_spec(spec, nil, nil, on_run_done) do
          {:ok, output} -> {:ok, {spec.id, output}}
          {:error, exception} -> {:error, {spec.id, exception}}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      # A slow agent fails on its own instead of exiting the caller.
      on_timeout: :kill_task,
      zip_input_on_exit: true,
      ordered: false
    )
    |> Stream.map(fn
      {:exit, {{%{id: agent_id}, _idx}, reason}} = exit ->
        :ok = report_kill(exit, run_marks, timeout, parent_otel_ctx)
        {:exit, {agent_id, reason}}

      other ->
        other
    end)
  end

  # An agent killed past the timeout before its run returned left its run span
  # open: report it.
  defp report_kill({:exit, {{%{agent: agent}, idx}, :timeout}}, run_marks, timeout, otel_ctx) do
    if KilledRun.run_done?(run_marks, idx),
      do: :ok,
      else: KilledRun.emit_timeout(agent, timeout, otel_ctx)
  end

  defp report_kill(_result, _run_marks, _timeout, _otel_ctx), do: :ok

  # Runs one spec's agent, then its :transform and the :on_agent_complete callback.
  # The callbacks run in the agent's task, so they are guarded: a crash would take
  # the caller down through the task's link.
  # `on_run_done` runs as soon as the agent's run returns, before the callbacks.
  defp run_spec(spec, input, on_complete, on_run_done) do
    outcome = Orchestration.run_agent(spec.id, spec.agent, Map.get(spec, :input, input))
    :ok = on_run_done.()

    with {:ok, output} <- outcome do
      Orchestration.guard(spec.id, fn -> run_callbacks(spec, output, on_complete) end)
    end
  end

  defp run_callbacks(spec, output, on_complete) do
    transformed = Map.get(spec, :transform, &Function.identity/1).(output)
    if on_complete, do: on_complete.(spec.id, transformed)
    transformed
  end
end
```

- [ ] **Step 6: `HierarchicalCoordinator` reads the new shape**

In `lib/normandy/coordination/hierarchical_coordinator.ex`:

(a) `:25`: `alias Normandy.Coordination.{ParallelOrchestrator, SharedContext}` becomes

```elixir
  alias Normandy.Coordination.{ParallelOrchestrator, SharedContext}
  alias Normandy.OrchestrationError
```

(b) In `run_hierarchy/3` (`:112-117`) replace

```elixir
        # Step 3: Execute workers
        {:ok, worker_results} =
          ParallelOrchestrator.execute_specs(worker_specs, max_concurrency: max_concurrency)

        # Step 4: Manager aggregates results
        aggregate_with_manager(coordinator.manager, worker_results, context)
```

with

```elixir
        # Step 3: Execute workers; failed workers are reported to the manager.
        worker_results =
          worker_specs
          |> ParallelOrchestrator.execute_specs(max_concurrency: max_concurrency)
          |> worker_outcome()

        # Step 4: Manager aggregates results
        aggregate_with_manager(coordinator.manager, worker_results, context)
```

and in `run_tasks/3` (`:163-168`) replace

```elixir
    {:ok, worker_results} =
      ParallelOrchestrator.execute_specs(worker_specs, max_concurrency: max_concurrency)
```

with

```elixir
    worker_results =
      worker_specs
      |> ParallelOrchestrator.execute_specs(max_concurrency: max_concurrency)
      |> worker_outcome()
```

(c) After `aggregation_message/1`, add:

```elixir
  # The workers' outputs and failures, whichever way execute_specs/2 returned.
  defp worker_outcome({:ok, results}), do: %{results: results, errors: %{}}

  defp worker_outcome({:error, %OrchestrationError{results: results, errors: errors}}),
    do: %{results: results, errors: errors}
```

(d) Replace the two `failure_text/1` clauses (`:394-395`) with

```elixir
  defp failure_text(exception), do: Exception.message(exception)
```

`test/coordination/hierarchical_coordinator_test.exs` needs no change (`"failed workers are
reported to the manager"` asserts the text `"worker down"`, the `RuntimeError` message).

- [ ] **Step 7: Other call sites**

1. `lib/normandy/telemetry.ex:167`: `` `ParallelOrchestrator` (`execute/2`, `execute_same_input/3`) and `` becomes `` `ParallelOrchestrator` (`execute/3`) and ``.
2. `mix.exs:140-143`: the `Errors` group becomes `[Normandy.LLMError, Normandy.TurnError, Normandy.OrchestrationError]`.
3. `test/telemetry/killed_run_test.exs`: add `alias Normandy.OrchestrationError` between `:16` and `:17` and `alias Normandy.TurnError` after `:18` (alphabetical, for Credo's `AliasOrder`). `:242-246` becomes

```elixir
        assert {:error,
                %OrchestrationError{
                  errors: %{"done" => %TurnError{type: :task_down, reason: :timeout}}
                }} =
                 ParallelOrchestrator.execute(specs, nil,
                   timeout: 100,
                   on_agent_complete: fn _, _ -> after_run.() end
                 )
```

   and `:283-284` becomes

```elixir
      assert {:error,
              %OrchestrationError{
                errors: %{"stuck" => %TurnError{type: :task_down, reason: :timeout}}
              }} = ParallelOrchestrator.execute(specs, nil, timeout: 100)
```

4. `test/telemetry/span_hierarchy_test.exs:584` `ParallelOrchestrator.execute(specs, [])` → `ParallelOrchestrator.execute(specs, nil)`; `:665` `assert {:ok, %{success: true}} = ParallelOrchestrator.execute(specs, [])` → `assert {:ok, _} = ParallelOrchestrator.execute(specs, nil)`.
5. `test/telemetry/workflow_span_test.exs:88-104`: the three Parallel tests become

```elixir
  test "ParallelOrchestrator.execute/3 with spec inputs" do
    input = %{chat_message: "x"}
    ps = Enum.map(specs(), &Map.put(&1, :input, input))
    spans = workflow_spans(fn -> {:ok, _} = ParallelOrchestrator.execute(ps, nil) end)
    assert_one_span(spans, :parallel, 2)
  end

  test "ParallelOrchestrator.execute/3 with a shared input" do
    spans = workflow_spans(fn -> {:ok, _} = ParallelOrchestrator.execute(specs(), "x") end)
    assert_one_span(spans, :parallel, 2)
  end

  test "ParallelOrchestrator.execute/3 with bare agents" do
    spans = workflow_spans(fn -> {:ok, _} = ParallelOrchestrator.execute([agent("a")], "x") end)
    assert_one_span(spans, :parallel, 1)
  end
```

6. `test/integration/multi_agent_workflows_test.exs:78-83` and `test/normandy_integration/multi_agent_test.exs:75-80` (live, tagged): replace

```elixir
      {:ok, results} = ParallelOrchestrator.execute(agents, input)
      ...
      assert is_list(results)
      assert length(results) == N
      assert Enum.all?(results, &match?({:ok, %{chat_message: _}}, &1))
```

   (N = 3 and 2) with

```elixir
      {:ok, results} = ParallelOrchestrator.execute(agents, input)

      assert map_size(results) == N
      assert Enum.all?(Map.values(results), &match?(%{chat_message: _}, &1))
```

   keeping each file's comment line.

Find stragglers: `grep -rn "ParallelOrchestrator.execute\(_same_input\)\?(" lib test e2e docs README.md` →
every hit must have three arguments or two with the second being the input (no keyword list
second argument, no `execute_same_input`).

- [ ] **Step 8: Run to verify they pass**

Run: `mix test test/coordination/ test/telemetry/`
Expected: ` 0 failures`.

- [ ] **Step 9: MIGRATING**

Insert before `## New, non-breaking`, as §27:

````markdown
## 27. Orchestrators: `execute(agents, input, opts)` and one result shape

`ParallelOrchestrator.execute/3` (and `SequentialOrchestrator.execute/3`, see below) take the
agents, one input and options, and return:

- `{:ok, %{agent_id => output}}` when every agent succeeded; `output` is the agent's response
  after its spec's `:transform`;
- `{:error, %Normandy.OrchestrationError{results: %{agent_id => output}, errors: %{agent_id
  => exception}}}` when any agent failed.

| 1.x | 2.0 |
|---|---|
| `ParallelOrchestrator.execute(specs, opts)` | `ParallelOrchestrator.execute(specs, nil, opts)` (each spec keeps its `:input`) |
| `ParallelOrchestrator.execute(agents, input)` → `{:ok, [{:ok, r} \| {:error, e}]}` | `{:ok, %{"agent_0" => r, ...}}` or `{:error, %OrchestrationError{}}` |
| `ParallelOrchestrator.execute_same_input(specs, input, opts)` | `ParallelOrchestrator.execute(specs, input, opts)` |
| `{:ok, %{success: true, results: results, errors: %{}, context: ctx, aggregated: a}}` | `{:ok, results}` |
| `{:ok, %{success: false, results: r, errors: e}}` | `{:error, %OrchestrationError{results: r, errors: e}}` |
| an agent's error `{:exception, e, stacktrace}` | `e` (logged with its stacktrace where it was raised) |
| an agent's error `{:exit, reason}` (an exit, or `:timeout`) | `%Normandy.TurnError{type: :task_down, reason: reason}` |
| `:shared_context`, `:aggregate`, `:ordered` | removed (rejected by name): aggregate `results` yourself |

- `agents` holds `%BaseAgentConfig{}` structs, keyed `"agent_0"`, `"agent_1"`, ..., or specs
  `%{id: string, agent: %BaseAgentConfig{}}` with optional `:transform` and, for
  `ParallelOrchestrator`, `:input`, which replaces `input` for that agent. Any other spec key,
  a repeated id, or anything else in `agents` raises `ArgumentError`. An unknown option raises
  `ArgumentError`.
- A struct input (`%BaseAgentInputSchema{}`) reaches every agent; 1.x dropped it, and with bare
  agents raised a `KeyError` in a linked task.
- `ParallelOrchestrator.execute_stream/2` yields `{:ok, {:error, {id, exception}}}` for a failed
  agent (was `{id, {:exception, e, stacktrace}}` or `{id, {:exit, reason}}`).
- `HierarchicalCoordinator` keeps its shapes; its aggregation prompt names a failed worker
  with the exception's message.
````

- [ ] **Step 10: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`.

```bash
git add lib/normandy/orchestration_error.ex lib/normandy/coordination/orchestration.ex lib/normandy/coordination/parallel_orchestrator.ex lib/normandy/coordination/hierarchical_coordinator.ex lib/normandy/telemetry.ex mix.exs MIGRATING-2.0.md test/coordination/orchestrator_contract_test.exs test/coordination/parallel_orchestrator_test.exs test/telemetry/killed_run_test.exs test/telemetry/span_hierarchy_test.exs test/telemetry/workflow_span_test.exs test/integration/multi_agent_workflows_test.exs test/normandy_integration/multi_agent_test.exs
git commit -m "feat(coordination)!: ParallelOrchestrator.execute/3 returns {:ok, results} | {:error, OrchestrationError}" -m "BREAKING CHANGE: execute(agents, input, opts \\\\ []) replaces the overloaded execute/2 and execute_same_input/3; results are keyed by agent id; per-agent errors are exceptions. A struct input now reaches every agent. See MIGRATING-2.0.md."
```

---

### Task 3.5c: `SequentialOrchestrator` joins the result shape

**Files:**
- Modify: `lib/normandy/coordination/sequential_orchestrator.ex` (whole file, 285 lines today)
- Modify: `e2e/10_coordination.exs:173-174`
- Modify: `MIGRATING-2.0.md` (the section Task 3.5b added)
- Test: `test/coordination/orchestrator_contract_test.exs` (`@orchestrators`), `test/coordination/sequential_orchestrator_test.exs` (rewrite), `test/integration/multi_agent_workflows_test.exs:41-45`, `test/normandy_integration/multi_agent_test.exs:46-51`

**Interfaces:**
- Consumes: `Normandy.Coordination.Orchestration.specs!/3`, `run_agent/3`, `result/2`; `Normandy.OrchestrationError` (Task 3.5b).
- Produces: `SequentialOrchestrator.execute([agent], input, keyword()) :: {:ok, %{String.t() => term()}} | {:error, Normandy.OrchestrationError.t()}`; options `:on_agent_complete` (`fn id, output -> any end`), `:on_error` (`:stop` default | `:continue`). `execute_with_messages/3` validates its (empty) options.

- [ ] **Step 1: Write the failing tests**

In `test/coordination/orchestrator_contract_test.exs`: `alias Normandy.Coordination.ParallelOrchestrator`
becomes `alias Normandy.Coordination.{ParallelOrchestrator, SequentialOrchestrator}` and
`@orchestrators [ParallelOrchestrator]` becomes `@orchestrators [SequentialOrchestrator, ParallelOrchestrator]`.
(For Sequential, `fail_on: "go"` on `"b"` fails because `"b"` receives `"a(go)"`.)

Replace `test/coordination/sequential_orchestrator_test.exs` with:

```elixir
defmodule Normandy.Coordination.SequentialOrchestratorTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Coordination.{AgentMessage, SequentialOrchestrator}
  alias Normandy.OrchestrationError
  alias Normandy.Test.TaggingClient

  @moduletag :capture_log

  defp agent(name, opts \\ []) do
    BaseAgent.init(%{client: struct(TaggingClient, [name: name] ++ opts), model: "test-model"})
  end

  defp failing_pipeline,
    do: [
      %{id: "a", agent: agent("a")},
      %{id: "b", agent: agent("b", fail_on: "a(")},
      %{id: "c", agent: agent("c")}
    ]

  describe "execute/3" do
    test "each agent receives the previous agent's output" do
      specs = [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}]

      assert {:ok, %{"a" => first, "b" => second}} =
               SequentialOrchestrator.execute(specs, "start")

      assert first.chat_message =~ ~r/^a\(.*start.*\)$/
      assert second.chat_message =~ ~r/^b\(.*a\(.*start/
    end

    test "a :transform shapes the result and what the next agent receives" do
      specs = [
        %{id: "a", agent: agent("a"), transform: fn r -> "only " <> r.chat_message end},
        %{id: "b", agent: agent("b")}
      ]

      assert {:ok, %{"a" => "only a(" <> _ = first, "b" => second}} =
               SequentialOrchestrator.execute(specs, "start", on_error: :stop)

      assert first =~ "start"
      assert second.chat_message =~ ~r/^b\(.*only a\(/
    end

    test "on_agent_complete is called after each agent, in order, with its output" do
      parent = self()
      specs = [%{id: "a", agent: agent("a")}, %{id: "b", agent: agent("b")}]

      {:ok, _} =
        SequentialOrchestrator.execute(specs, "x",
          on_agent_complete: fn id, output -> send(parent, {:done, id, output.chat_message}) end
        )

      assert_received {:done, "a", "a(" <> _}
      assert_received {:done, "b", "b(" <> _}
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "on_error: :stop ends at the failing agent; the agents after it do not run" do
      assert {:error, %OrchestrationError{results: results, errors: errors}} =
               SequentialOrchestrator.execute(failing_pipeline(), "x", on_error: :stop)

      assert %{"a" => %{chat_message: "a(" <> _}} = results
      assert map_size(results) == 1
      assert errors == %{"b" => %RuntimeError{message: "b failed"}}
    end

    test "the last output of plain agents is under the last id" do
      assert {:ok, %{"agent_1" => %{chat_message: last}}} =
               SequentialOrchestrator.execute([agent("a"), agent("b")], "go")

      assert last =~ "b("
    end

    test "the 1.x options are rejected by name" do
      for {key, value} <- [shared_context: %{}, store_intermediate: false] do
        error =
          assert_raise ArgumentError, fn ->
            SequentialOrchestrator.execute([agent("a")], "x", [{key, value}])
          end

        assert error.message =~ "Normandy.Coordination.SequentialOrchestrator.execute/3: "
        assert error.message =~ inspect(key)
      end
    end
  end

  describe "on_error: :continue" do
    test "the agent after a failure gets the last successful output; the result is an error" do
      assert {:error,
              %OrchestrationError{
                results: %{"a" => a, "c" => c},
                errors: %{"b" => %RuntimeError{message: "b failed"}}
              }} = SequentialOrchestrator.execute(failing_pipeline(), "x", on_error: :continue)

      assert a.chat_message =~ "a("
      assert c.chat_message =~ ~r/^c\(.*a\(/
      refute c.chat_message =~ "error"
    end

    test "with no failure it is {:ok, results}" do
      assert {:ok, %{"a" => _}} =
               SequentialOrchestrator.execute([%{id: "a", agent: agent("a")}], "x",
                 on_error: :continue
               )
    end
  end

  describe "execute_with_messages/3" do
    test "each agent answers the previous message with a reply addressed back" do
      first = AgentMessage.new(from: "user", to: "a", payload: %{chat_message: "hi"})
      specs = [%{id: "a", agent: agent("a")}]

      assert {:ok, [^first, reply]} = SequentialOrchestrator.execute_with_messages(specs, first)

      assert %AgentMessage{type: "response", from: "a", to: "user"} = reply
      assert reply.payload.chat_message =~ ~r/^a\(.*hi/
    end

    test "a failing agent produces an error message carrying the exception's message" do
      first = AgentMessage.new(from: "user", to: "a", payload: %{chat_message: "hi"})
      specs = [%{id: "a", agent: agent("a", fail_on: "hi")}]

      assert {:ok, [_, %AgentMessage{type: "error", from: "a", to: "user"} = error]} =
               SequentialOrchestrator.execute_with_messages(specs, first)

      assert error.payload.error == "a failed"
    end

    test "rejects options" do
      first = AgentMessage.new(from: "user", to: "a", payload: %{chat_message: "hi"})

      error =
        assert_raise ArgumentError, fn ->
          SequentialOrchestrator.execute_with_messages([], first, shared_context: %{})
        end

      assert error.message =~
               "Normandy.Coordination.SequentialOrchestrator.execute_with_messages/3: "

      assert error.message =~ ":shared_context"
    end
  end
end
```

(Dropped: the two shared-context tests and `"an agent that exits"` — the context is gone and
the exit case is in the contract test.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/coordination/orchestrator_contract_test.exs test/coordination/sequential_orchestrator_test.exs`
Expected: FAIL. The `SequentialOrchestrator` contract tests get `{:ok, %{success: true, results:
[...], ...}}`; the bare-agent test gets `{:ok, %{chat_message: ...}}`; `shared_context:` is
accepted.

- [ ] **Step 3: Rewrite `lib/normandy/coordination/sequential_orchestrator.ex`**

Replace the whole file with:

```elixir
defmodule Normandy.Coordination.SequentialOrchestrator do
  alias Normandy.Coordination.{AgentMessage, Orchestration}
  alias Normandy.Telemetry.WorkflowSpan

  @opts_schema NimbleOptions.new!(
                 on_agent_complete: [
                   type: {:fun, 2},
                   doc:
                     "`fn agent_id, output -> any end`, called after each agent that " <>
                       "succeeds (after `:transform`)."
                 ],
                 on_error: [
                   type: {:in, [:stop, :continue]},
                   default: :stop,
                   doc:
                     "`:stop` ends the pipeline at the first failure. `:continue` runs the " <>
                       "remaining agents, the next one receiving the last successful output " <>
                       "(or `input`). Either way a failure makes the result " <>
                       "`{:error, %Normandy.OrchestrationError{}}`."
                 ]
               )

  @messages_opts_schema NimbleOptions.new!([])

  @spec_keys [:id, :agent, :transform]

  @moduledoc """
  Runs agents one after another, each on the previous agent's output.

      {:ok, results} =
        SequentialOrchestrator.execute(
          [
            %{id: "research", agent: research_agent, transform: &extract_data/1},
            %{id: "write", agent: writing_agent}
          ],
          "Summarize the 2026 Elixir survey"
        )

      results["write"]

  `agents` holds `%Normandy.Agents.BaseAgentConfig{}` structs (keyed `"agent_0"`,
  `"agent_1"`, ... in list order) or specs `%{id: id, agent: config}` with an optional
  `:transform` (`fn output -> term end`): what it returns is the agent's result and the
  next agent's input. The first agent receives `input`.

  ## Results

  `{:ok, %{id => output}}` when every agent succeeded; the pipeline's output is the last
  agent's. Otherwise `{:error, %Normandy.OrchestrationError{}}` with the outputs of the
  agents that succeeded and the exception of each that failed. With `on_error: :stop`
  the agents after the failure did not run and are in neither map.
  """

  @doc """
  Runs `agents` in order, the first on `input`; see "Results".

  ## Options

  #{Normandy.Options.docs(@opts_schema)}
  """
  @spec execute([Orchestration.agent()], term(), keyword()) :: Orchestration.result()
  def execute(agents, input, opts \\ []) do
    opts = Normandy.Options.validate!(opts, @opts_schema, {__MODULE__, :execute, 3})
    specs = Orchestration.specs!(agents, @spec_keys, "#{inspect(__MODULE__)}.execute/3")

    WorkflowSpan.span(:sequential, %{step_count: length(specs)}, fn ->
      run_pipeline(specs, input, opts)
    end)
  end

  defp run_pipeline(specs, input, opts) do
    {_last_input, results, errors} =
      Enum.reduce_while(specs, {input, %{}, %{}}, &step(&1, &2, opts))

    Orchestration.result(results, errors)
  end

  # One agent. Its output feeds the next agent; a failure ends the pipeline or, with
  # on_error: :continue, leaves the next agent the last successful output.
  defp step(spec, {input, results, errors}, opts) do
    case Orchestration.run_agent(spec.id, spec.agent, input) do
      {:ok, output} ->
        output = Map.get(spec, :transform, &Function.identity/1).(output)
        on_complete = opts[:on_agent_complete]
        if on_complete, do: on_complete.(spec.id, output)
        {:cont, {output, Map.put(results, spec.id, output), errors}}

      {:error, exception} ->
        acc = {input, results, Map.put(errors, spec.id, exception)}
        halt_or_continue(Keyword.fetch!(opts, :on_error), acc)
    end
  end

  defp halt_or_continue(:stop, acc), do: {:halt, acc}
  defp halt_or_continue(:continue, acc), do: {:cont, acc}

  @doc """
  Runs agent specs with message-based communication. Each agent receives the previous
  `AgentMessage`'s payload and answers with a reply, or an error message whose payload
  `:error` is the exception's message. Takes no options.

  ## Example

      {:ok, messages} = SequentialOrchestrator.execute_with_messages(specs, initial_message)
  """
  @spec execute_with_messages([Orchestration.spec()], AgentMessage.t(), keyword()) ::
          {:ok, [AgentMessage.t()]}
  def execute_with_messages(agent_specs, initial_message, opts \\ []) do
    Normandy.Options.validate!(
      opts,
      @messages_opts_schema,
      {__MODULE__, :execute_with_messages, 3}
    )

    WorkflowSpan.span(:sequential, %{step_count: length(agent_specs)}, fn ->
      run_with_messages(agent_specs, initial_message)
    end)
  end

  defp run_with_messages(agent_specs, initial_message) do
    messages =
      Enum.reduce(agent_specs, [initial_message], fn spec, [current_msg | _] = acc ->
        agent_id = Map.fetch!(spec, :id)
        agent = Map.fetch!(spec, :agent)

        # Pattern match to validate struct type
        %AgentMessage{} = current_msg

        request_msg = %{current_msg | to: agent_id, type: "request"}

        case Orchestration.run_agent(agent_id, agent, request_msg.payload) do
          {:ok, result} ->
            [AgentMessage.reply(request_msg, result) | acc]

          {:error, exception} ->
            [AgentMessage.error(request_msg, Exception.message(exception)) | acc]
        end
      end)

    {:ok, Enum.reverse(messages)}
  end
end
```

- [ ] **Step 4: Other call sites**

1. `e2e/10_coordination.exs:173-174`:

```elixir
{:ok, %{"translate" => first, "count" => second}} =
  SequentialOrchestrator.execute(specs, "The library opens at nine in the morning.")
```

2. `test/integration/multi_agent_workflows_test.exs:41` and `test/normandy_integration/multi_agent_test.exs:46`:
   `{:ok, final_result} = SequentialOrchestrator.execute(agents, input)` becomes
   `{:ok, %{"agent_1" => final_result}} = SequentialOrchestrator.execute(agents, input)` (both
   pipelines have two agents; the assertions after it are unchanged).

3. `test/telemetry/workflow_span_test.exs:67-75` and `test/telemetry/span_hierarchy_test.exs:553`
   need no change (they match `{:ok, _}` and the agents succeed).

Find stragglers: `grep -rn "SequentialOrchestrator.execute(" lib test e2e docs README.md` — read
every hit; none may match `%{success:`, `results: [`, or pass `:shared_context` /
`:store_intermediate`.

- [ ] **Step 5: Run to verify they pass**

Run: `mix test test/coordination/ test/telemetry/`
Expected: ` 0 failures`.

- [ ] **Step 6: MIGRATING**

Append to the orchestrators section (§27, Task 3.5b):

```markdown
- `SequentialOrchestrator.execute/3` has the same shape. 1.x returned
  `{:ok, %{success: _, results: [...], errors: [...], context: ctx}}`, `{:error, %{...}}` on
  `on_error: :stop`, and `{:ok, last_result}` for bare agents; 2.0 returns `{:ok, %{id =>
  output}}` (the pipeline's output is the last agent's, `results["agent_<n-1>"]` for bare
  agents) or `{:error, %OrchestrationError{}}`, also after `on_error: :continue` with a
  failure. With `:stop` the agents after the failure are in neither map.
- `on_agent_complete` takes `fn id, output -> ... end` (1.x: `fn id, result, ctx -> ... end`).
  `:shared_context` and `:store_intermediate` are removed.
- `SequentialOrchestrator.execute_with_messages/3` rejects options (it ignored
  `:shared_context`); an error message's `payload.error` is the exception's message (was
  `inspect/1` of `{:exception, e, stacktrace}`).
```

- [ ] **Step 7: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`.

```bash
git add lib/normandy/coordination/sequential_orchestrator.ex e2e/10_coordination.exs MIGRATING-2.0.md test/coordination/orchestrator_contract_test.exs test/coordination/sequential_orchestrator_test.exs test/integration/multi_agent_workflows_test.exs test/normandy_integration/multi_agent_test.exs
git commit -m "feat(coordination)!: SequentialOrchestrator.execute/3 returns the orchestrator result shape" -m "BREAKING CHANGE: results are %{id => output}; any failure is {:error, %OrchestrationError{}}; :shared_context and :store_intermediate are removed; on_agent_complete takes (id, output). See MIGRATING-2.0.md."
```

---

### Task 3.5d: `Reactive`'s error shapes (Wave 2 ruling D5)

**Review result.** `Normandy.Coordination.Reactive` (`race/3`, `all/3`, `some/3`, `map/3`) and
`HierarchicalCoordinator` (`execute/3`, `execute_with_tasks/3`) exist. Neither joins the
orchestrator shape, and the contract test does not cover them:

- `Reactive` is a set of completion strategies, not "run these agents and report each":
  `race/3` returns one output by definition (`{:ok, output}`), `some/3` returns the first
  `count` successes (`{:ok, %{id => output}}`, already the success shape), and `all/3` reports
  every agent including failures (`{:ok, %{id => {:ok, output} | {:error, exception}}}`), which
  `Normandy.DSL.Workflow`'s `parallel` step consumes (`workflow.ex:479`, `name_results/2`).
  The combinator-level failures stay atoms: `{:error, :all_failed}`, `{:error, :timeout}`,
  `{:error, :insufficient_successes}` (Wave 2 ruling D5 keeps the last).
- `HierarchicalCoordinator` returns the manager's aggregation (`{:ok, term}`), one value.

What does change, so every per-agent error in `Normandy.Coordination` is an exception
(decision 6):

1. `all/3` reports an agent that exited or ran past `:timeout` as
   `{:error, %TurnError{type: :task_down, reason: reason}}` (was `{:error, {:exit, reason}}`),
   also as `fail_fast`'s return.
2. `execute_agent/2` catches an exit. Today an agent struct whose client exits takes down the
   task, and through `Task.async`'s link **the caller of `race/3` or `some/3`** (verified on
   HEAD 95dc149 with a scratch script: `Reactive.race([exiting], "x", timeout: 1000)` returns
   `{:error, :timeout}` after the full timeout and the caller receives `{:EXIT, task, :boom}`;
   without `trap_exit` the caller dies).
3. `some/3` with `count:` above the number of agents raises `ArgumentError` (a caller bug,
   found before any agent runs) instead of returning `{:error, :count_exceeds_agent_count}`.

The Wave 2 deferral "reactive_test.exs:381 vacuous assertion" is already closed: verified at
`test/coordination/reactive_test.exs:375-385` (`{:error, :all_failed}` plus each agent's
`ValidationError` through `on_complete`) and `:405-420` (`{:error, :insufficient_successes}`).
Nothing to do there.

**Files:**
- Modify: `lib/normandy/coordination/reactive.ex` — `all/3` doc `:139-174` and body `:198-217`; `some/3` doc `:254-261` and `:267-268`; `execute_agent/2` `:392-405`
- Modify: `MIGRATING-2.0.md` (the orchestrators section)
- Test: `test/coordination/reactive_test.exs:95-115`, `:223-229`, new tests in `describe "race/3"` and `describe "all/3"`

**Interfaces:**
- Produces: `Reactive.all/3` per-agent `{:error, Exception.t()}` only; `Reactive.race/3`, `some/3`, `map/3` and `when_result/3` see an exiting agent as `{:error, %TurnError{type: :task_down}}`; `Reactive.some/3` raises `ArgumentError` for `count > length(agents)`.

- [ ] **Step 1: Write the failing tests**

In `test/coordination/reactive_test.exs`, add `alias Normandy.TurnError` after
`alias Normandy.Coordination.{AgentProcess, Reactive}` and, after `create_agent_process/0`:

```elixir
  # An agent whose model call exits (as a timed-out GenServer.call does) instead of raising.
  defp exiting_agent do
    BaseAgent.init(%{
      client: %Normandy.Test.StubClient{reply: fn _ -> exit(:boom) end},
      model: "exiting-model"
    })
  end
```

In `describe "race/3"`, add:

```elixir
    test "an agent that exits is a failure, not an exit of the caller" do
      test_pid = self()

      assert {:error, :all_failed} =
               Reactive.race([exiting_agent()], "x",
                 on_complete: fn id, result -> send(test_pid, {:done, id, result}) end
               )

      assert_receive {:done, "agent_0", {:error, %TurnError{type: :task_down, reason: :boom}}}
    end
```

In `describe "all/3"`, replace in `"keeps the other results when an agent times out"`
`"agent_1" => {:error, {:exit, :timeout}},` with
`"agent_1" => {:error, %TurnError{type: :task_down, reason: :timeout}},`; in
`"fail_fast still stops on an agent that times out"` replace
`assert {:error, {:exit, :timeout}} =` with
`assert {:error, %TurnError{type: :task_down, reason: :timeout}} =`; and add:

```elixir
    test "an agent that exits is reported as a :task_down TurnError" do
      assert {:ok, %{"agent_0" => {:error, %TurnError{type: :task_down, reason: :boom}}}} =
               Reactive.all([exiting_agent()], "x")
    end
```

In `describe "some/3"`, replace the test `"returns error if count exceeds agent count"` with:

```elixir
    test "a count above the number of agents raises before any agent runs" do
      agents = [create_test_agent(), create_test_agent()]

      assert_raise ArgumentError,
                   "Normandy.Coordination.Reactive.some/3: :count must be at most the " <>
                     "number of agents (2), got: 5",
                   fn -> Reactive.some(agents, "test", count: 5) end
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/coordination/reactive_test.exs`
Expected: FAIL. The race test process exits with `:boom` (`** (EXIT from #PID<...>) :boom`);
the `all/3` tests get `{:error, {:exit, :timeout}}` / `{:error, {:exit, :boom}}`; `some/3`
returns `{:error, :count_exceeds_agent_count}`.

- [ ] **Step 3: Implement**

(a) `execute_agent/2` (`:392-405`) becomes:

```elixir
  @doc false
  # One agent's result: {:ok, output} or {:error, exception}. A raise (a bug) is logged
  # and returned; an exit (a timed-out call, a client that exits) is a :task_down
  # TurnError, so it never takes down the task and, through Task.async's link, the caller.
  def execute_agent(agent, input) do
    run_one(agent, input)
  rescue
    e -> TurnError.log_raised("Reactive agent", e, __STACKTRACE__)
  catch
    :exit, reason -> {:error, TurnError.from_reason({:task_down, reason})}
  end

  defp run_one(pid, input) when is_pid(pid), do: AgentProcess.run(pid, input)

  defp run_one(agent, input) do
    case BaseAgent.run(agent, prepare_input(input)) do
      {:ok, _updated_agent, response} -> {:ok, response}
      {:error, exception} -> {:error, exception}
    end
  end
```

(b) In `all/3`'s `Enum.reduce_while` (`:209-216`), replace

```elixir
        {:exit, {agent_id, reason}}, {:ok, acc} ->
          if fail_fast do
            {:halt, {:error, {:exit, reason}}}
          else
            {:cont, {:ok, Map.put(acc, agent_id, {:error, {:exit, reason}})}}
          end
```

with

```elixir
        # Killed past :timeout, or the task died.
        {:exit, {agent_id, reason}}, {:ok, acc} ->
          error = TurnError.from_reason({:task_down, reason})

          if fail_fast do
            {:halt, {:error, error}}
          else
            {:cont, {:ok, Map.put(acc, agent_id, {:error, error})}}
          end
```

(c) `all/3`'s `## Returns` block (`:165-174`) becomes:

```
  ## Returns

  - `{:ok, %{agent_id => {:ok, output} | {:error, exception}}}` - every agent's result.
    An agent that runs past `:timeout` (the limit applies to each agent) is stopped and
    appears as `{:error, %Normandy.TurnError{type: :task_down, reason: :timeout}}`; one
    that exits, as that `TurnError` with the exit reason
  - `{:error, exception}` - with `fail_fast: true`, the first failure
```

and the example `#=> {:ok, %{... "agent_2" => {:error, reason}}}` stays.

(d) `some/3`: replace

```elixir
    if count > length(agents) do
      {:error, :count_exceeds_agent_count}
    else
```

with

```elixir
    if count > length(agents) do
      raise ArgumentError,
            "Normandy.Coordination.Reactive.some/3: :count must be at most the number of " <>
              "agents (#{length(agents)}), got: #{inspect(count)}"
    else
```

and add to its `## Returns` list: ``Raises `ArgumentError` when `:count` is above the number of agents.``

(e) The `@spec` of `some/3` (`:262`) and `all/3` (`:176`) stay; `@type result` (`:54`) becomes
`@type result :: {:ok, term()} | {:error, Exception.t() | :all_failed | :timeout | :insufficient_successes}`.

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/coordination/reactive_test.exs test/dsl/ test/telemetry/killed_run_test.exs`
Expected: ` 0 failures`.

- [ ] **Step 5: MIGRATING**

Append to the orchestrators section (§27):

```markdown
- `Reactive` keeps its shapes (`race/3` → `{:ok, output}`, `all/3` → `{:ok, %{id => {:ok,
  output} | {:error, e}}}`, `some/3` → `{:ok, %{id => output}}`, and `{:error, :all_failed |
  :timeout | :insufficient_successes}`). An agent that exits or runs past `:timeout` is
  `{:error, %Normandy.TurnError{type: :task_down}}` (was `{:error, {:exit, reason}}`), and an
  agent struct that exits no longer takes down the caller of `race/3` or `some/3`.
- `Reactive.some/3` with `count:` above the number of agents raises `ArgumentError` (was
  `{:error, :count_exceeds_agent_count}`).
```

- [ ] **Step 6: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`.

```bash
git add lib/normandy/coordination/reactive.ex MIGRATING-2.0.md test/coordination/reactive_test.exs
git commit -m "fix(coordination)!: Reactive reports an exiting agent as a :task_down TurnError" -m "BREAKING CHANGE: all/3 reports exits and timeouts as %TurnError{type: :task_down}; an agent that exits no longer kills the caller of race/3 or some/3; some/3 raises ArgumentError for a count above the agent count. See MIGRATING-2.0.md."
```

---

### Task 3.6a: `fetch_*` lookups; `TurnNotFoundError` and `ContextProviderNotFoundError` (DX-16, DX-17; decision 17b)

**Files:**
- Modify: `lib/normandy/exceptions.ex:15-37` (the two exception modules)
- Modify: `lib/normandy/agents/base_agent.ex:1961-1975` (`get_context_provider/2`), `:2030-2045` (`get_tool/2` and its doc)
- Modify: `lib/normandy/components/agent_memory.ex:136-137` (`get_entry/2`), `:145` (the raise in `delete_turn/2`)
- Modify: `mix.exs:140-144` (Errors group), `CLAUDE.md:59`
- Modify: `MIGRATING-2.0.md` (new section before `## New, non-breaking`)
- Test: `test/agents/base_agent_test.exs:55-73`, `test/agents/base_agent_tools_test.exs:24,54-69`, `test/components/context_provider_test.exs:147,168-170`, `test/components/date_time_provider_test.exs:45`, `test/components/agent_memory_test.exs:243-245,346`

**Interfaces:**
- Consumes: `Normandy.Tools.Toolset.new/1`, `Toolset.fetch/2`, `Toolset.fetch!/2`, `Normandy.ToolNotFoundError` (Task 3.4a/b). `BaseAgentConfig.toolset` holds the `%Toolset{}` (Task 3.4a renamed the field from `tool_registry`).
- Produces:
  - `BaseAgent.fetch_tool(BaseAgentConfig.t(), String.t()) :: {:ok, struct()} | :error`, `fetch_tool!/2 :: struct()` (raises `Normandy.ToolNotFoundError`, via `Toolset.fetch!/2`)
  - `BaseAgent.fetch_context_provider(BaseAgentConfig.t(), atom()) :: {:ok, struct()} | :error`, `fetch_context_provider!/2 :: struct()` (raises `Normandy.ContextProviderNotFoundError`)
  - `AgentMemory.fetch_entry(t(), String.t()) :: {:ok, Entry.t()} | :error`, `fetch_entry!/2 :: Entry.t()` (raises `KeyError`)
  - `Normandy.TurnNotFoundError` (`defexception [:turn_id]`), `Normandy.ContextProviderNotFoundError` (`defexception [:name, registered: []]`)
  - Removed: `BaseAgent.get_tool/2`, `BaseAgent.get_context_provider/2`, `AgentMemory.get_entry/2`, `Normandy.NonExistentTurn`, `Normandy.NonExistentContextProvider`.

**Ruling (Q may override): `fetch_entry!/2` raises `KeyError`.** An entry is not a turn, the
header lists no entry exception, and `KeyError` is what `Map.fetch!/2` raises. It is built with
`key:` and `message:` only, so the message never prints the memory (`term:` would).

- [ ] **Step 1: Write the failing tests**

1. `test/agents/base_agent_test.exs:55-73`: replace the test `"get context provider"` with

```elixir
  test "fetch_context_provider/2 and fetch_context_provider!/2", %{agent: agent} do
    provider = %ContextProvider{}
    agent = BaseAgent.register_context_provider(agent, :ctx, provider)

    assert {:ok, ^provider} = BaseAgent.fetch_context_provider(agent, :ctx)
    assert :error = BaseAgent.fetch_context_provider(agent, :not_exists)
    assert BaseAgent.fetch_context_provider!(agent, :ctx) == provider

    assert_raise Normandy.ContextProviderNotFoundError,
                 "no context provider :not_exists; registered: [:ctx]",
                 fn -> BaseAgent.fetch_context_provider!(agent, :not_exists) end
  end
```

2. `test/components/context_provider_test.exs:147`: `BaseAgent.get_context_provider(agent, :datetime)` → `BaseAgent.fetch_context_provider!(agent, :datetime)`. `:168-170` becomes

```elixir
      assert :error = BaseAgent.fetch_context_provider(agent, :user)

      assert_raise Normandy.ContextProviderNotFoundError,
                   "no context provider :user; registered: []",
                   fn -> BaseAgent.fetch_context_provider!(agent, :user) end
```

3. `test/components/date_time_provider_test.exs:45`: `BaseAgent.get_context_provider(agent, :datetime)` → `BaseAgent.fetch_context_provider!(agent, :datetime)`.

4. `test/agents/base_agent_tools_test.exs`: run
   `perl -pi -e 's/BaseAgent\.get_tool\(/BaseAgent.fetch_tool(/g; s/describe "BaseAgent\.get_tool\/2"/describe "BaseAgent.fetch_tool\/2 and fetch_tool!\/2"/' test/agents/base_agent_tools_test.exs`
   (expected: 4 calls and 1 describe title renamed; `grep -c "fetch_tool(" test/agents/base_agent_tools_test.exs` → 4).
   Then, in the test `"retrieves registered tool"`, after its `assert {:ok, ^tool} = BaseAgent.fetch_tool(agent, <name>)`
   line add `assert BaseAgent.fetch_tool!(agent, <name>) == tool` with the same name string;
   and add to the describe:

```elixir
    test "fetch_tool!/2 raises Normandy.ToolNotFoundError, with or without a toolset", %{
      agent: agent
    } do
      assert agent.toolset == nil
      assert_raise Normandy.ToolNotFoundError, fn -> BaseAgent.fetch_tool!(agent, "missing") end
    end
```

5. `test/components/agent_memory_test.exs:243-245`: replace

```elixir
    assert_raise Normandy.NonExistentTurn, fn ->
      AgentMemory.delete_turn(memory, other_turn_id)
    end
```

   with

```elixir
    assert_raise Normandy.TurnNotFoundError,
                 "no turn #{inspect(other_turn_id)} in this AgentMemory",
                 fn -> AgentMemory.delete_turn(memory, other_turn_id) end
```

   `:346`: `AgentMemory.get_entry(result, "c").parent_id` → `AgentMemory.fetch_entry!(result, "c").parent_id`. And add:

```elixir
  test "fetch_entry/2 and fetch_entry!/2" do
    memory =
      AgentMemory.new_memory()
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("user", %{c: "a"})

    id = memory.head

    assert {:ok, %Normandy.Components.AgentMemory.Entry{role: "user"}} =
             AgentMemory.fetch_entry(memory, id)

    assert :error = AgentMemory.fetch_entry(memory, "missing")
    assert %Normandy.Components.AgentMemory.Entry{role: "user"} = AgentMemory.fetch_entry!(memory, id)

    assert_raise KeyError, ~s(no entry "missing" in this AgentMemory), fn ->
      AgentMemory.fetch_entry!(memory, "missing")
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/agents/base_agent_test.exs test/agents/base_agent_tools_test.exs test/components/context_provider_test.exs test/components/date_time_provider_test.exs test/components/agent_memory_test.exs`
Expected: FAIL. `UndefinedFunctionError` for `fetch_context_provider/2`, `fetch_tool/2`,
`fetch_entry/2`; `Normandy.TurnNotFoundError` / `Normandy.ContextProviderNotFoundError` are
undefined modules (`assert_raise` reports `UndefinedFunctionError ... exception/1`).

- [ ] **Step 3: Implement**

(a) `lib/normandy/exceptions.ex:15-37`: replace both modules (and the two
`# credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames` lines above them) with

```elixir
defmodule Normandy.TurnNotFoundError do
  @moduledoc """
  Raised by `Normandy.Components.AgentMemory.delete_turn/2` when no entry in the memory
  belongs to the turn. `:turn_id` is the id that was asked for.
  """
  defexception [:turn_id]

  @type t :: %__MODULE__{turn_id: String.t()}

  @impl true
  def message(%__MODULE__{turn_id: turn_id}),
    do: "no turn #{inspect(turn_id)} in this AgentMemory"
end

defmodule Normandy.ContextProviderNotFoundError do
  @moduledoc """
  Raised by `Normandy.Agents.BaseAgent.fetch_context_provider!/2` when the agent's prompt
  specification has no context provider under the name. `:name` is the name that was
  asked for; `:registered` lists the names that exist, sorted.
  """
  defexception [:name, registered: []]

  @type t :: %__MODULE__{name: atom(), registered: [atom()]}

  @impl true
  def message(%__MODULE__{name: name, registered: registered}),
    do: "no context provider #{inspect(name)}; registered: #{inspect(registered)}"
end
```

(b) `lib/normandy/agents/base_agent.ex`. Replace `get_context_provider/2` (`:1961-1975`) with

```elixir
  @doc """
  Looks up the context provider registered under `name`: `{:ok, provider}` or `:error`.
  """
  @spec fetch_context_provider(BaseAgentConfig.t(), atom()) :: {:ok, struct()} | :error
  def fetch_context_provider(
        %BaseAgentConfig{prompt_specification: %{context_providers: providers}},
        name
      ),
      do: Map.fetch(providers, name)

  @doc """
  Like `fetch_context_provider/2`, but returns the provider or raises
  `Normandy.ContextProviderNotFoundError`.
  """
  @spec fetch_context_provider!(BaseAgentConfig.t(), atom()) :: struct()
  def fetch_context_provider!(
        %BaseAgentConfig{prompt_specification: %{context_providers: providers}},
        name
      ) do
    case Map.fetch(providers, name) do
      {:ok, provider} ->
        provider

      :error ->
        raise Normandy.ContextProviderNotFoundError,
          name: name,
          registered: providers |> Map.keys() |> Enum.sort()
    end
  end
```

Replace `get_tool/2` with its doc (`:2030-2045`) with

```elixir
  @doc """
  Looks up a registered tool by name: `{:ok, tool}` or `:error` (also when no tool is
  registered).
  """
  @spec fetch_tool(BaseAgentConfig.t(), String.t()) :: {:ok, struct()} | :error
  def fetch_tool(%BaseAgentConfig{} = config, tool_name),
    do: Toolset.fetch(toolset_of(config), tool_name)

  @doc """
  Like `fetch_tool/2`, but returns the tool or raises `Normandy.ToolNotFoundError`.
  """
  @spec fetch_tool!(BaseAgentConfig.t(), String.t()) :: struct()
  def fetch_tool!(%BaseAgentConfig{} = config, tool_name),
    do: Toolset.fetch!(toolset_of(config), tool_name)

  # No toolset yet is an empty one: the lookups answer the same way.
  defp toolset_of(%BaseAgentConfig{toolset: nil}), do: Toolset.new([])
  defp toolset_of(%BaseAgentConfig{toolset: toolset}), do: toolset
```

`Toolset` must be aliased: `grep -n "alias Normandy.Tools.Toolset" lib/normandy/agents/base_agent.ex`
(Task 3.4a's rename leaves it at `:52`); add `alias Normandy.Tools.Toolset` there if the grep is
empty.

(c) `lib/normandy/components/agent_memory.ex:136-137`: replace `get_entry/2` with

```elixir
  @doc "Looks up the entry with id `id`: `{:ok, entry}` or `:error`."
  @spec fetch_entry(t(), String.t()) :: {:ok, Entry.t()} | :error
  def fetch_entry(%__MODULE__{entries: entries}, id), do: Map.fetch(entries, id)

  @doc """
  Like `fetch_entry/2`, but returns the entry or raises `KeyError` (its message names the
  id, never the memory).
  """
  @spec fetch_entry!(t(), String.t()) :: Entry.t()
  def fetch_entry!(%__MODULE__{entries: entries}, id) do
    case Map.fetch(entries, id) do
      {:ok, entry} -> entry
      :error -> raise KeyError, key: id, message: "no entry #{inspect(id)} in this AgentMemory"
    end
  end
```

and `:145` `raise Normandy.NonExistentTurn, value: turn_id` → `raise Normandy.TurnNotFoundError, turn_id: turn_id`.
Add a `@doc` to `delete_turn/2` (it has only a `@spec`):

```elixir
  @doc """
  Removes every entry of turn `turn_id`, re-linking the survivors around it. Raises
  `Normandy.TurnNotFoundError` when the memory has no entry of that turn.
  """
```

(d) `mix.exs` `Errors:` group becomes

```elixir
          Errors: [
            Normandy.LLMError,
            Normandy.TurnError,
            Normandy.OrchestrationError,
            Normandy.ToolNotFoundError,
            Normandy.TurnNotFoundError,
            Normandy.ContextProviderNotFoundError,
            Normandy.HookHaltError,
            Normandy.ModelCatalogError,
            Normandy.Schema.ValidationError,
            Normandy.CastError,
            Normandy.InvalidChangesetError
          ],
```

(every `defexception` in `lib/` except `Normandy.Guardrails.ViolationError`, which stays in
the Guardrails group; check with `grep -rln "defexception" lib/` → the modules above plus
`guardrails/violation_error.ex`; keep any entry Task 3.4 added).

(e) `CLAUDE.md:59`: `` `register_context_provider/3`, `get_context_provider/2`, `delete_context_provider/2` `` →
`` `register_context_provider/3`, `fetch_context_provider/2` and `fetch_context_provider!/2`, `delete_context_provider/2` ``.

Check: `grep -rn "get_tool\b\|get_tool(\|get_context_provider\|get_entry\|NonExistent" lib test e2e docs/guides README.md CLAUDE.md MIGRATING-2.0.md` → no output.

- [ ] **Step 4: Run to verify they pass**

Run: the Step 2 command.
Expected: ` 0 failures`. Then `mix credo --strict lib/normandy/exceptions.ex` → no
`ExceptionNames` issue with the inline disables gone.

- [ ] **Step 5: MIGRATING**

Insert before `## New, non-breaking`, as §28:

```markdown
## 28. Lookups are `fetch_*`; two exceptions renamed

A lookup returns `{:ok, value}` or `:error`; its `!` variant returns the value or raises.

| 1.x | 2.0 |
|---|---|
| `BaseAgent.get_tool(agent, name)` → `{:ok, tool} \| :error` | `BaseAgent.fetch_tool(agent, name)` (same result); `fetch_tool!/2` returns the tool or raises `Normandy.ToolNotFoundError` |
| `BaseAgent.get_context_provider(agent, name)` → the provider, or raises `Normandy.NonExistentContextProvider` | `BaseAgent.fetch_context_provider(agent, name)` → `{:ok, provider} \| :error`; `fetch_context_provider!/2` returns it or raises `Normandy.ContextProviderNotFoundError` |
| `AgentMemory.get_entry(memory, id)` → the entry or `nil` | `AgentMemory.fetch_entry(memory, id)` → `{:ok, entry} \| :error`; `fetch_entry!/2` returns it or raises `KeyError` |
| `rescue Normandy.NonExistentTurn` (`AgentMemory.delete_turn/2`) | `rescue Normandy.TurnNotFoundError`; field `:turn_id` (was `:value`) |
| `rescue Normandy.NonExistentContextProvider` | `rescue Normandy.ContextProviderNotFoundError`; fields `:name` and `:registered` (was `:value`) |

The renamed exceptions build their own message and take no `:message` option.
```

- [ ] **Step 6: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`.

```bash
git add lib/normandy/exceptions.ex lib/normandy/agents/base_agent.ex lib/normandy/components/agent_memory.ex mix.exs CLAUDE.md MIGRATING-2.0.md test/agents/base_agent_test.exs test/agents/base_agent_tools_test.exs test/components/context_provider_test.exs test/components/date_time_provider_test.exs test/components/agent_memory_test.exs
git commit -m "feat!: fetch_* lookups; TurnNotFoundError and ContextProviderNotFoundError" -m "BREAKING CHANGE: BaseAgent.get_tool/2, get_context_provider/2 and AgentMemory.get_entry/2 are fetch_tool/2, fetch_context_provider/2 and fetch_entry/2 returning {:ok, v} | :error, each with a raising ! variant. NonExistentTurn and NonExistentContextProvider are renamed. See MIGRATING-2.0.md."
```

---

### Task 3.6b: The other lookups follow the rule

**Scan of public lookups in `lib/` (HEAD 95dc149) and the decision for each:**

| Function | Not found today | Decision |
|---|---|---|
| `Coordination.SharedContext.get/2` | `{:error, :not_found}` | **Rename** `fetch/2` → `{:ok, v} \| :error`. `get/3` (value or default, like `Map.get/3`) stays |
| `Coordination.StatefulContext.get/2` | `{:error, :not_found}` | **Rename** `fetch/2`, same. `get/3` stays |
| `Coordination.AgentSupervisor.find_agent/2` | `{:error, :not_found}` | **Rename** `fetch_agent/2` → `{:ok, pid} \| :error` |
| `Tools.Toolset.get_metadata/2` (was `Registry`) | `:error` | **Done in Task 3.4a** (`fetch_metadata/2`); not touched here |
| `Schema.Introspection.get_field_type/2`, `get_field_metadata/2`, `get_field_constraints/2`, `get_description/1`, `get_required_fields/1`, `get_specification/1` | `nil` / `[]` | **Defer** to the Wave 7 schema-accessor task (the four-ways-to-get-a-schema consolidation the plan header puts out of scope) |
| `Behaviours.MemoryStore.get/3` (callback) | `:not_found \| {:error, term}` | **Keep**: a backend call has two failure modes (missing, backend error); `:error` cannot carry the second |
| `Behaviours.CredentialProvider.get_token/2` (callback) | `{:error, reason}` | **Keep**: fetching a credential can fail for a reason |
| `Validate.get_field/3` | the default | **Keep**: Ecto's changeset API (value or default) |
| `AgentProcess.get_agent/1`, `get_id/1`, `get_stats/1`, `StatefulContext.get_table/1`, `AgentMemory.get_current_turn_id/1` | always present | **Keep**: accessors, not lookups |
| `BaseAgent.get_response/2` | — | **Keep**: makes an LLM call, not a lookup |
| `ContextProvider.get_info/1` (protocol) | — | **Keep**: a protocol callback |
| `AgentMemory.fork/2` | `{:error, :no_such_entry}` | **Keep**: an operation with a reason, not a lookup |
| `AgentSupervisor.terminate_agent/2` | `{:error, :not_found}` | **Keep**: an operation; mirrors `DynamicSupervisor.terminate_child/2` |
| `StatefulContext` change events (`{:context_changed, key, old, new}`) | `old` = `{:error, :not_found}` | **Keep**: an event payload, not a lookup return; changing it breaks subscribers for no gain |
| `SessionRegistry.whereis/2` (callback) | `:none \| {:error, term}` | **Keep**: OTP naming, three outcomes |

**Files:**
- Modify: `lib/normandy/coordination/shared_context.ex:15-20` (moduledoc example), `:76-108`
- Modify: `lib/normandy/coordination/stateful_context.ex:20-25` (moduledoc example), `:79-113`
- Modify: `lib/normandy/coordination/agent_supervisor.ex:165-180`
- Modify: `MIGRATING-2.0.md` (the Task 3.6a section)
- Test: `test/coordination/shared_context_test.exs`, `test/coordination/stateful_context_test.exs`, `test/coordination/agent_supervisor_test.exs`

**Interfaces:**
- Produces: `SharedContext.fetch(t(), key()) :: {:ok, term()} | :error`; `StatefulContext.fetch(GenServer.server(), key()) :: {:ok, term()} | :error`; `AgentSupervisor.fetch_agent(Supervisor.supervisor(), String.t()) :: {:ok, pid()} | :error`. Removed: `SharedContext.get/2`, `StatefulContext.get/2`, `AgentSupervisor.find_agent/2`. (`Toolset.fetch_metadata/2` already replaced `get_metadata/2` in Task 3.4a; this task does not touch `toolset.ex`.)

- [ ] **Step 1: Rewrite the tests (they fail until Step 3)**

```bash
perl -pi -e 's/SharedContext\.get\((\w+), ([^,()]+|\{[^{}]*\})\)/SharedContext.fetch($1, $2)/g; s/\{:error, :not_found\} = SharedContext\.fetch/:error = SharedContext.fetch/g; s/test "put\/get round-trips a value; a missing key is \{:error, :not_found\}"/test "put\/fetch round-trips a value; a missing key is :error"/' test/coordination/shared_context_test.exs
perl -pi -e 's/StatefulContext\.get\((\w+), ([^,()]+|\{[^{}]*\})\)/StatefulContext.fetch($1, $2)/g; s/\{:error, :not_found\} = StatefulContext\.fetch/:error = StatefulContext.fetch/g' test/coordination/stateful_context_test.exs
perl -pi -e 's/AgentSupervisor\.find_agent\(/AgentSupervisor.fetch_agent(/g; s/\{:error, :not_found\} = AgentSupervisor\.fetch_agent/:error = AgentSupervisor.fetch_agent/g; s/(AgentSupervisor\.fetch_agent\(sup, "temporary"\)) == \{:error, :not_found\}/$1 == :error/g' test/coordination/agent_supervisor_test.exs
grep -c "SharedContext.fetch(" test/coordination/shared_context_test.exs
grep -c "StatefulContext.fetch(" test/coordination/stateful_context_test.exs
grep -c "AgentSupervisor.fetch_agent(" test/coordination/agent_supervisor_test.exs
grep -n "not_found" test/coordination/shared_context_test.exs test/coordination/stateful_context_test.exs test/coordination/agent_supervisor_test.exs
```

Expected (verified on a copy at HEAD 95dc149; Task 3.5 removes no line of these files): 5,
11, 12; the `not_found` grep shows only `agent_supervisor_test.exs:119`
(`terminate_agent/2`, kept) and `stateful_context_test.exs:217` (the change event, kept). The
3-arity `get(ctx, key, default)` calls are untouched (the patterns require `)` after the
second argument).

Toolset metadata: Task 3.4a already renamed `Toolset.get_metadata/2` to `fetch_metadata/2`
(Step 4c there). Check: `grep -rn "get_metadata(" lib test` → no output. Nothing to do here.

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/coordination/shared_context_test.exs test/coordination/stateful_context_test.exs test/coordination/agent_supervisor_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `SharedContext.fetch/2`,
`StatefulContext.fetch/2`, `AgentSupervisor.fetch_agent/2`.

- [ ] **Step 3: Implement**

`lib/normandy/coordination/shared_context.ex`: replace `get/2` with its doc (`:76-93`) by

```elixir
  @doc """
  Looks up `key`: `{:ok, value}` or `:error`.

  ## Examples

      {:ok, value} = SharedContext.fetch(context, "key")
      :error = SharedContext.fetch(context, "missing")
  """
  @spec fetch(t(), key()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{data: data}, key), do: Map.fetch(data, normalize_key(key))
```

and the body of `get/3` (`:104-109`) by

```elixir
  def get(%__MODULE__{} = context, key, default) do
    case fetch(context, key) do
      {:ok, value} -> value
      :error -> default
    end
  end
```

In the moduledoc (`:18`), `{:ok, data} = SharedContext.get(context, "research_results")` →
`{:ok, data} = SharedContext.fetch(context, "research_results")`.

`lib/normandy/coordination/stateful_context.ex`: replace `get/2` with its doc (`:79-98`) by

```elixir
  @doc """
  Looks up `key`: `{:ok, value}` or `:error`.

  Reads directly from ETS for maximum performance (no GenServer call).

  ## Examples

      {:ok, value} = StatefulContext.fetch(pid, "key")
      :error = StatefulContext.fetch(pid, "missing")
  """
  @spec fetch(GenServer.server(), key()) :: {:ok, term()} | :error
  def fetch(server, key) do
    table = get_table(server)
    normalized_key = normalize_key(key)

    case :ets.lookup(table, normalized_key) do
      [{^normalized_key, value}] -> {:ok, value}
      [] -> :error
    end
  end
```

the body of `get/3` (`:108-113`) by

```elixir
  def get(server, key, default) do
    case fetch(server, key) do
      {:ok, value} -> value
      :error -> default
    end
  end
```

and the moduledoc example (`:23`) `{:ok, "value"} = StatefulContext.get(pid, "key")` →
`{:ok, "value"} = StatefulContext.fetch(pid, "key")`. The `{:error, :not_found}` "old value"
in `handle_call({:put, ...})` and `handle_call({:delete, ...})` stays (change events).

`lib/normandy/coordination/agent_supervisor.ex:165-180`: replace `find_agent/2` with

```elixir
  @doc """
  Looks up a running agent by its agent_id: `{:ok, pid}` or `:error`.

  ## Example

      {:ok, pid} = AgentSupervisor.fetch_agent(supervisor, "agent_1")
  """
  @spec fetch_agent(Supervisor.supervisor(), String.t()) :: {:ok, pid()} | :error
  def fetch_agent(supervisor, agent_id) do
    case Enum.find(list_agents(supervisor), fn {_pid, id} -> id == agent_id end) do
      {pid, _id} -> {:ok, pid}
      nil -> :error
    end
  end
```

Check: `grep -rn "SharedContext.get(\|StatefulContext.get(\|find_agent\|get_metadata" lib test e2e docs/guides README.md`
→ only 3-arity `get(..., default)` calls.

- [ ] **Step 4: Run to verify they pass**

Run: the Step 2 command.
Expected: ` 0 failures`.

- [ ] **Step 5: MIGRATING**

Add these rows to the table of §28, "Lookups are `fetch_*`" (Task 3.6a):

```markdown
| `SharedContext.get(ctx, key)` → `{:ok, v} \| {:error, :not_found}` | `SharedContext.fetch(ctx, key)` → `{:ok, v} \| :error`; `get/3` with a default is unchanged |
| `StatefulContext.get(pid, key)` → `{:ok, v} \| {:error, :not_found}` | `StatefulContext.fetch(pid, key)` → `{:ok, v} \| :error`; `get/3` is unchanged |
| `AgentSupervisor.find_agent(sup, id)` → `{:ok, pid} \| {:error, :not_found}` | `AgentSupervisor.fetch_agent(sup, id)` → `{:ok, pid} \| :error` |
```

- [ ] **Step 6: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`.

```bash
git add lib/normandy/coordination/shared_context.ex lib/normandy/coordination/stateful_context.ex lib/normandy/coordination/agent_supervisor.ex MIGRATING-2.0.md test/coordination/shared_context_test.exs test/coordination/stateful_context_test.exs test/coordination/agent_supervisor_test.exs
git commit -m "feat(coordination)!: SharedContext, StatefulContext and AgentSupervisor lookups are fetch_*" -m "BREAKING CHANGE: SharedContext.get/2 and StatefulContext.get/2 are fetch/2, AgentSupervisor.find_agent/2 is fetch_agent/2; a miss is :error. See MIGRATING-2.0.md."
```

---

### Task 3.6c: `BaseIOSchema` drops `__str__/1` and `__rich__/1` (DX-21, the dunders only)

**Files:**
- Modify: `lib/normandy/components/base_io_schema.ex:1-66` (protocol and the built-in impls)
- Modify: `lib/normandy/schema.ex:21-22` (moduledoc), `:409-424` (the `defimpl` in `io_schema`'s postlude)
- Modify: `lib/normandy/agents/tool_call_response.ex:124-125`, `lib/normandy/components/tool_result.ex:64-65`
- Modify: `CLAUDE.md:129`, `MIGRATING-2.0.md` (new section before `## New, non-breaking`)
- Test: `test/components/base_io_schema_test.exs:20-23`, `test/agents/base_agent_test.exs:117-125`, `test/app_env_config_test.exs:64-65`, `test/schema/redact_test.exs:63-68`, `test/support/iotest.ex:11-12`, `test/agents/turn/server_test.exs:30-31`, `test/hooks/server_hooks_test.exs:27-28`

**Interfaces:**
- Produces: `Normandy.Components.BaseIOSchema` with exactly `to_json/1` and `get_schema/1`. Renaming `get_schema/1`/`get_json_schema/0` is out of scope (plan header: Wave 7).

Coverage of the adapter's `pretty: true` path does not depend on `__rich__/1`:
`test/app_env_config_test.exs` "decodes model output and tool input, and encodes the schema
prompt" drives `encode!/2` with `pretty: true` through the output-schema prompt
(`base_agent.ex:1363`, through `Normandy.JSON` after Task 3.3; its `TaggingDecoder.encode!/2`
returns `"schema-by-adapter"`, asserted in that test). No new test is needed; Step 4 checks it
still passes.

- [ ] **Step 1: Write the failing test**

`test/components/base_io_schema_test.exs:20-23`: replace the test `"__str__/1 and __rich__/1 return strings"` with

```elixir
    test "the protocol is to_json/1 and get_schema/1" do
      assert BaseIOSchema.__protocol__(:functions) |> Enum.sort() == [get_schema: 1, to_json: 1]
    end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/components/base_io_schema_test.exs`
Expected: FAIL: left is `[__rich__: 1, __str__: 1, get_schema: 1, to_json: 1]`.

- [ ] **Step 3: Implement**

1. `lib/normandy/components/base_io_schema.ex`: the moduledoc becomes

```elixir
  @moduledoc """
  How a value goes to the model: `to_json/1` encodes it (a string, or a list of content
  blocks), and `get_schema/1` returns its schema. Implemented for strings, maps, lists,
  content blocks and every `io_schema` struct.
  """
```

   delete the `__str__/1` and `__rich__/1` definitions with their `@doc` and `@spec` (`:11-17`),
   and delete every `def __str__` / `def __rich__` line in the impls below (`:29-30`,
   `:36-37`, `:49-50`, `:63-64`).
2. `lib/normandy/schema.ex`, in the `defimpl Normandy.Components.BaseIOSchema, for: __MODULE__`
   block of the postlude: delete the two lines starting `def __str__(str)` and
   `def __rich__(str)` (whatever their bodies became in Task 3.3). Moduledoc `:21-22`:
   "JSON an `io_schema` sends to the model (`to_json/1`, `__str__/1`, `__rich__/1`) and of"
   becomes "JSON an `io_schema` sends to the model (`to_json/1`) and of".
3. `lib/normandy/agents/tool_call_response.ex:124-125` and `lib/normandy/components/tool_result.ex:64-65`:
   delete the `def __str__(_)` and `def __rich__(_)` lines.
4. Test impls: delete the `def __str__` / `def __rich__` lines in `test/support/iotest.ex`
   (`:11-12`), `test/agents/turn/server_test.exs` (`:30-31`), `test/hooks/server_hooks_test.exs` (`:27-28`).
5. `test/agents/base_agent_test.exs:117-125`: replace the test `"rich base agent io str and rich"` with

```elixir
  test "an io_schema struct encodes to its JSON" do
    test_io = %Normandy.Agents.BaseAgentInputSchema{chat_message: "chat message"}

    assert BaseIOSchema.to_json(test_io) == ~s({"chat_message":"chat message"})
  end
```

6. `test/app_env_config_test.exs:64-65` (line numbers at `95dc149`; Task 3.3a's `TaggingJson`
   rewrite shifts them, so find them with `grep -n "__str__\|__rich__" test/app_env_config_test.exs`):
   delete the `__str__` and `__rich__` assertions (the
   `to_json` one above them stays). Leave `TaggingJson` and both its `encode!` clauses as Task
   3.3a left them (`encode!(_value, [])` and `encode!(_value, pretty: true)`): `Normandy.JSON`
   calls the adapter's `encode!/2` even without options.
7. `test/schema/redact_test.exs:63-68`: delete the test `"__str__ and __rich__"` (the `to_json`
   redaction test above it stays and covers what the model sees).
8. `CLAUDE.md:129`: `` - Methods: `to_json/1`, `get_schema/1`, `__str__/1`, `__rich__/1` `` →
   `` - Methods: `to_json/1`, `get_schema/1` ``.

Check: `grep -rn "__str__\|__rich__" lib test e2e examples docs/guides README.md CLAUDE.md` →
no output (`examples/agent_horde/erl_crash.dump` is not a source file; exclude it if `examples`
matches).

- [ ] **Step 4: Run to verify it passes**

Run: `mix compile --warnings-as-errors && mix test test/components/base_io_schema_test.exs test/agents/base_agent_test.exs test/app_env_config_test.exs test/schema/redact_test.exs test/agents/turn/server_test.exs test/hooks/server_hooks_test.exs`
Expected: compile clean (no "required by protocol" or unused-clause warning), ` 0 failures`.

- [ ] **Step 5: MIGRATING**

Insert before `## New, non-breaking`, as §29:

```markdown
## 29. `BaseIOSchema` drops `__str__/1` and `__rich__/1`

`Normandy.Components.BaseIOSchema` is `to_json/1` and `get_schema/1`; nothing in Normandy
called the other two. Delete `def __str__/1` and `def __rich__/1` from your own `defimpl
Normandy.Components.BaseIOSchema` blocks (left in, they are dead code, not an error), and
call `BaseIOSchema.to_json/1` where you called `__str__/1`: it leaves out `redact: true`
fields, as `__str__/1` did.
```

- [ ] **Step 6: Format, full suite, commit**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`.

```bash
git add lib/normandy/components/base_io_schema.ex lib/normandy/schema.ex lib/normandy/agents/tool_call_response.ex lib/normandy/components/tool_result.ex CLAUDE.md MIGRATING-2.0.md test/components/base_io_schema_test.exs test/agents/base_agent_test.exs test/app_env_config_test.exs test/schema/redact_test.exs test/support/iotest.ex test/agents/turn/server_test.exs test/hooks/server_hooks_test.exs
git commit -m "feat(schema)!: BaseIOSchema is to_json/1 and get_schema/1" -m "BREAKING CHANGE: the __str__/1 and __rich__/1 protocol functions are removed. See MIGRATING-2.0.md."
```

---

## Conventions for Tasks 3.7a–3.7d

Every rule below applies to every entry point in this group; the tasks give the schemas.

1. **One compiled schema per entry point**, a module attribute named after the function:
   `@start_link_opts_schema`, `@run_opts_schema`, `@ok_opts_schema` (drop a trailing `!`/`?`).
   Entry points with the same keys may share one attribute; the task says which.
2. **Validation is the first expression of the body**, before any process starts, any message is
   sent and any span opens:
   `opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})`
   with `alias Normandy.Options`. NimbleOptions checks unknown keys before required ones, so a
   misspelled key is reported even when a required key is also missing.
3. **Defaults.** A key gets `default:` unless its absence means something its default can't
   express. Those keys get no `default:`, state the default in `doc:`, and keep `Keyword.get/3` or
   `Keyword.get_lazy/3` at the reader:
   - a saved template value applies only when the key is absent (`Turn.Server`'s
     `:approval_timeout_ms`, `:on_approval_timeout`, `:idle_timeout_ms`, `:resume_policy`;
     `server.ex:367-377` and `509-528`);
   - the default is computed per call (`UUID.uuid4/0`, `SharedContext.new/0` — it stamps
     `created_at`, `length(agents)`, `[node()]`, a generated table name);
   - another function owns the default (`AgentProcess` passes `:supervisor_mod` and
     `:resume_policy` on to `Turn.Session.new/1`, whose schema defaults them).
   For every other key the default moves into the schema and the reader becomes
   `Keyword.fetch!(opts, :key)`.
4. **Types.** Caller-facing waits are `:timeout` (ms or `:infinity`; DX-28). A `{module, handle}`
   pair is `{:tuple, [:atom, :any]}`. A struct is `{:struct, Mod}`. A plain map is
   `{:custom, Normandy.Options, :plain_map, []}`. A callback is `{:fun, n}`. An option a
   caller may pass as an explicit `nil` (built from a struct field) is `{:or, [type, nil]}`.
5. **Docs.** The function's `@doc` gets an `## Options` heading followed by
   `#{Options.docs(@start_link_opts_schema)}`; the hand-written option bullets it replaces are
   deleted (they would drift). A function without a `@doc` gets one.
6. **A schema another module reuses** is exposed as `@doc false def __opts_schema__(:fun_name)`.
   Composition reads the compiled schema's keyword list (`%NimbleOptions{schema: kw}`, the public
   `t:NimbleOptions.t/0` field).
7. **Tests.** Each sub-task adds `test/options/<area>_options_test.exs` with a `@cases` table of
   `{misspelled_key, {module, function, args}}` rows (literal args; the call raises before it uses
   them), one generated test per row through `Normandy.Test.OptionsAssertions.assert_rejects/4`
   (exact prefix `"#{inspect(mod)}.#{fun}/#{length(args)}: "` and the key), and one test that every
   row's function documents its options.
8. **Existing callers.** When the full suite shows a caller (lib or test) passing a key a schema
   rejects: if the code reads that key, the schema is missing it — add it with the type the code
   expects; otherwise the caller is wrong — fix the caller and name it in the commit body.
9. **Step 0 of every sub-task re-inventories** the files with the grep it gives, because Tasks 3.4
   and 3.5 edit some of them first. The schema lists exactly the keys the code reads: a key read
   but missing from the schema is added; a schema key no longer read is deleted; an entry point
   the grep no longer finds loses its row.
10. **Values that can carry a credential are never echoed.** NimbleOptions' "invalid value"
    messages include the value (`expected Normandy.Agents.BaseAgentConfig, got: %{client: ...}`).
    Task 3.1's `Normandy.Options` hides the value of any key in its `@sensitive_keys` list
    (`:api_key, :authorization, :client, :credential, :headers, :mcp_servers, :password,
    :req_options, :secret, :token`; `3.1-3.2.md` Step 4). Each sub-task adds the keys it
    introduces whose value can hold an agent config, a client, a token, a URL with a password or
    connection options: 3.7a `:config`; 3.7b `:agent`, `:agent_config`, `:agents`; 3.7c
    `:auth_token`, `:transport_opts`, `:context`; 3.7d `:url`, `:redix`, `:templates`. Each adds
    one test that a bad value under one of them does not appear in the message.
    `Options.plain_map/1` never echoes (it names the type through `Describe.type_of/1`).

---

### Task 3.7a: Options at the turn entry points

**Files:**
- Modify: `lib/normandy/options.ex` (Task 3.1's module: `:config` joins `@sensitive_keys`)
- Create: `test/support/options_assertions.ex`
- Modify: `lib/normandy/agents/turn/server.ex` (moduledoc lines 10-28; `start_link/1` lines 221-229)
- Modify: `lib/normandy/agents/turn/supervisor.ex` (whole module, 69 lines)
- Modify: `lib/normandy/agents/turn/supervisor/horde.ex` (`start_link/1` 20-32, `start_server/2` 34-47)
- Modify: `lib/normandy/agents/turn/resume_reaper.ex` (`start_link/1` 43-49, `init/1` 52-66)
- Modify: `lib/normandy/agents/turn.ex` (`new/1` docs and body, lines 75-101)
- Modify: `MIGRATING-2.0.md` (new section)
- Create: `test/options/turn_options_test.exs`
- Modify: `test/agents/turn_test.exs:32`, `test/agents/turn/server_test.exs:2138-2149`

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`, `Normandy.Options.docs/1`, `Normandy.Options.plain_map/1`
  (Task 3.1a; decision 18). `Turn.Session.new/1`
  is validated by Task 3.5 and is not touched here (listed in the coverage test, Task 3.7d).
- Produces: `Turn.Server.__opts_schema__(:start_link) :: NimbleOptions.t()`
  (`@doc false`); `Normandy.Test.OptionsAssertions.assert_rejects/4` and
  `assert_documents_options/3` (test support, used by 3.7b–3.7d). Validated:
  `Turn.Server.start_link/1`, `Turn.Supervisor.start_link/1`, `Turn.Supervisor.start_server/2`,
  `Turn.Supervisor.Horde.start_link/1`, `Turn.Supervisor.Horde.start_server/2`,
  `Turn.ResumeReaper.start_link/1`, `Turn.new/1`.

- [ ] **Step 0: Re-inventory**

```bash
grep -n "Keyword\.\(get\|get_lazy\|fetch\|fetch!\|pop\|take\)(opts\|Keyword\.get(server_opts" \
  lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/supervisor.ex \
  lib/normandy/agents/turn/supervisor/horde.ex lib/normandy/agents/turn/resume_reaper.ex \
  lib/normandy/agents/turn.ex
```

Expected keys (as of `95dc149`): `server.ex` — `:on_approval_timeout`, `:name`, `:store`,
`:session_id`, `:registry`, `:idle_timeout_ms`, `:config`, `:template_provider`, `:resume_policy`,
`:subscriber`, `:handlers`, plus `server_option/4`'s generic `Keyword.fetch(opts, key)` for
`:approval_timeout_ms`, `:on_approval_timeout`, `:idle_timeout_ms`; `supervisor.ex` — `:name`,
`:max_restarts`, `:max_seconds`, `:registry`, `:session_id`; `horde.ex` — the same plus
`:resume_policy`; `resume_reaper.ex` — `:name`, `:store`, `:registry`, `:supervisor`,
`:supervisor_mod`, `:template_provider`, and `Keyword.take(opts, [:subscriber, :handlers])`;
`turn.ex` — `:max_iterations`, `:response_model`, `:output_schema`. Apply Convention 9 to any
difference.

- [ ] **Step 1: Write the test support module and the failing tests**

Create `test/support/options_assertions.ex`:

```elixir
defmodule Normandy.Test.OptionsAssertions do
  @moduledoc """
  Assertions for the option-validation tests (Tasks 3.7a–3.7d): a misspelled key raises
  `ArgumentError` with the `Module.function/arity: ` prefix and names the key, and every
  entry point documents its options.
  """
  import ExUnit.Assertions

  @spec assert_rejects(atom(), module(), atom(), list()) :: ArgumentError.t()
  def assert_rejects(key, mod, fun, args) do
    prefix = "#{inspect(mod)}.#{fun}/#{length(args)}: "
    error = assert_raise ArgumentError, fn -> apply(mod, fun, args) end

    assert String.starts_with?(error.message, prefix),
           "expected #{inspect(error.message)} to start with #{inspect(prefix)}"

    assert error.message =~ inspect(key),
           "expected #{inspect(error.message)} to name #{inspect(key)}"

    error
  end

  @spec assert_documents_options(module(), atom(), arity()) :: :ok
  def assert_documents_options(mod, fun, arity) do
    assert {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(mod)

    doc =
      Enum.find_value(docs, fn
        {{:function, ^fun, ^arity}, _anno, _sig, %{"en" => text}, _meta} -> text
        _ -> nil
      end)

    assert is_binary(doc), "#{inspect(mod)}.#{fun}/#{arity} has no @doc"
    assert doc =~ "## Options", "#{inspect(mod)}.#{fun}/#{arity} has no ## Options section"
    :ok
  end
end
```

Create `test/options/turn_options_test.exs`:

```elixir
defmodule Normandy.Options.TurnOptionsTest do
  use ExUnit.Case, async: true

  import Normandy.Test.OptionsAssertions

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory

  # {misspelled key, {module, function, args}}. The unknown-key check runs first, so the
  # rows omit required keys and the call raises before it starts or sends anything.
  @cases [
    {:approval_timout_ms, {Turn.Server, :start_link, [[approval_timout_ms: 1]]}},
    {:max_restart, {Turn.Supervisor, :start_link, [[max_restart: 1]]}},
    {:idle_timout_ms, {Turn.Supervisor, :start_server, [:no_supervisor, [idle_timout_ms: 1]]}},
    {:max_restart, {Turn.Supervisor.Horde, :start_link, [[max_restart: 1]]}},
    {:idle_timout_ms,
     {Turn.Supervisor.Horde, :start_server, [:no_supervisor, [idle_timout_ms: 1]]}},
    {:supervisor_md, {Turn.ResumeReaper, :start_link, [[supervisor_md: Turn.Supervisor]]}},
    {:max_iteration, {Turn, :new, [[max_iteration: 3]]}}
  ]

  for {key, {mod, fun, args}} <- @cases do
    test "#{inspect(mod)}.#{fun}/#{length(args)} rejects #{inspect(key)}" do
      assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))
    end
  end

  test "every entry point documents its options" do
    for {_key, {mod, fun, args}} <- @cases, do: assert_documents_options(mod, fun, length(args))
  end

  describe "a misspelled or missing option raises in the caller (Review Focus #3)" do
    test "Turn.Supervisor.start_server/2 raises instead of returning the supervisor's {:error, _}" do
      sup = start_supervised!(Turn.Supervisor)

      opts = [
        session_id: "s-typo",
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        approval_timout_ms: 1
      ]

      error = assert_raise ArgumentError, fn -> Turn.Supervisor.start_server(sup, opts) end

      assert error.message =~
               ~r/^Normandy\.Agents\.Turn\.Supervisor\.start_server\/2: unknown option :approval_timout_ms; supported: /

      assert %{active: 0} = DynamicSupervisor.count_children(sup)
    end

    test "a :config that is not a BaseAgentConfig is rejected without echoing it" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Server.start_link(
            session_id: "s-bad-config",
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()},
            config: %{client: %{api_key: "sk-secret"}}
          )
        end

      assert error.message =~ "Normandy.Agents.Turn.Server.start_link/1: "
      assert error.message =~ ":config"
      refute error.message =~ "sk-secret"
    end

    test "Turn.Server.start_link/1 without :store raises ArgumentError, not a KeyError in init/1" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Server.start_link(session_id: "s-no-store", registry: {Native, Native.new()})
        end

      assert error.message =~
               "Normandy.Agents.Turn.Server.start_link/1: required :store option not found"
    end

    test "a bad :resume_policy names the key and the allowed values" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Server.start_link(
            session_id: "s-bad-policy",
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()},
            resume_policy: :sometimes
          )
        end

      assert error.message =~
               "invalid value for :resume_policy option: expected one of [:lazy, :eager], got: :sometimes"
    end

    test "a struct where :handlers expects a map is an ArgumentError, not Protocol.UndefinedError" do
      error =
        assert_raise ArgumentError, fn ->
          Turn.Server.start_link(
            session_id: "s-bad-handlers",
            store: {InMemory, InMemory.new()},
            registry: {Native, Native.new()},
            handlers: %URI{}
          )
        end

      assert error.message =~ ":handlers"
    end
  end
end
```

The existing tests `test/agents/turn/server_test.exs` "explicit start options win over the saved
ones" (~line 1380) and the saved-`server_options` case (~line 1341) guard Convention 3 for
`Turn.Server`; they must still pass unchanged.

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/options/turn_options_test.exs`
Expected: FAIL. Every `rejects` row reports "Expected exception ArgumentError but nothing was
raised" or another exception (`Turn.Server.start_link/1` starts and crashes in `init/1`, which can
also exit the test process); the docs test fails on `Turn.Supervisor.start_link/1` ("has no
@doc").

- [ ] **Step 3a: `:config` is a sensitive key**

In `lib/normandy/options.ex`, add `:config` to `@sensitive_keys` (Convention 10; keep the list
sorted). `Normandy.Options.plain_map/1`, used below for `:handlers`, exists since Task 3.1a
(decision 18); this task does not add it.

- [ ] **Step 3b: `Turn.Server`**

Add `alias Normandy.Options` to the alias block. Above `@spec start_link(keyword())` (line 221) add
the schema, the accessor and the doc:

```elixir
  @start_link_opts_schema NimbleOptions.new!(
                            session_id: [
                              type: :string,
                              required: true,
                              doc: "The session this server runs."
                            ],
                            store: [
                              type: {:tuple, [:atom, :any]},
                              required: true,
                              doc: "The `Normandy.Behaviours.SessionStore` as `{module, handle}`."
                            ],
                            registry: [
                              type: {:tuple, [:atom, :any]},
                              required: true,
                              doc:
                                "The `Normandy.Behaviours.SessionRegistry` as `{module, handle}`. " <>
                                  "The server registers itself under `:session_id` unless it " <>
                                  "was started under a `:via` name."
                            ],
                            config: [
                              type: {:struct, Normandy.Agents.BaseAgentConfig},
                              doc:
                                "The agent config. Without it the server rebuilds the config " <>
                                  "from the template saved in `:store` (a thin start), which " <>
                                  "needs `:template_provider`."
                            ],
                            template_provider: [
                              type: {:or, [{:tuple, [:atom, :any]}, nil]},
                              doc:
                                "The `Normandy.Behaviours.AgentTemplate` as `{module, handle}`, " <>
                                  "for a thin start."
                            ],
                            resume_policy: [
                              type: {:in, [:lazy, :eager]},
                              doc:
                                "`:lazy` (the default) or `:eager`: `:eager` resumes an " <>
                                  "in-flight turn as soon as the server starts. A saved " <>
                                  "template's value wins over this option."
                            ],
                            subscriber: [
                              type: {:or, [{:fun, 2}, nil]},
                              doc:
                                "`fn event_name, meta -> any end`, called in the server process " <>
                                  "for every event. A crash in it is logged, reported as " <>
                                  "`[:normandy, :turn, :subscriber, :exception]` telemetry, " <>
                                  "and ignored. Never saved with the template."
                            ],
                            handlers: [
                              type:
                                {:or,
                                 [
                                   {:struct, Normandy.Agents.Turn.Driver.Handlers},
                                   {:custom, Normandy.Options, :plain_map, []},
                                   nil
                                 ]},
                              doc:
                                "A `Normandy.Agents.Turn.Driver.Handlers` set (default " <>
                                  "`Normandy.Agents.BaseAgent.non_streaming_handlers/0`). A `nil` " <>
                                  "`:emit` is skipped. Hook modules' `before_llm` and " <>
                                  "`after_compact` run around whichever set is used. Never saved " <>
                                  "with the template."
                            ],
                            approval_timeout_ms: [
                              type: :timeout,
                              doc:
                                "How long a parked turn waits for `approve/2`, in ms (default " <>
                                  "300_000). Wins over a saved template's value."
                            ],
                            on_approval_timeout: [
                              type: {:in, [:continue, :fail]},
                              doc:
                                "`:continue` (the default) or `:fail`. On expiry every parked " <>
                                  "call gets an `expired: true` tool result; `:continue` hands it " <>
                                  "to the model, `:fail` ends the turn with `{:error, " <>
                                  "%Normandy.TurnError{type: :approval_timeout}}`. Wins over a " <>
                                  "saved template's value."
                            ],
                            idle_timeout_ms: [
                              type: :timeout,
                              doc:
                                "Idle time before passivation, in ms (default 60_000). Wins " <>
                                  "over a saved template's value."
                            ],
                            name: [
                              type: :any,
                              doc:
                                "A `:gen_statem` server name. `Turn.Supervisor.start_server/2` " <>
                                  "sets it from the registry's `child_name/2`."
                            ]
                          )

  @doc false
  def __opts_schema__(:start_link), do: @start_link_opts_schema

  @doc """
  Starts a session server. Options are checked here, in the caller, so a bad option raises
  `ArgumentError` instead of failing `init/1`.

  ## Options

  #{Options.docs(@start_link_opts_schema)}
  """
```

Replace the body of `start_link/1` (lines 222-229):

```elixir
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end
```

`validate_on_approval_timeout!/1` stays: `timeout_options/2` (line 515) still checks a value read
from a saved template. No `Keyword.get(opts, ...)` reader in `init/1` changes: none of those keys
has a schema default (Convention 3).

In the moduledoc, replace lines 10-28 (from `## Options (besides ...` through the
`:idle_timeout_ms` bullet) with:

```markdown
  ## Options

  See `start_link/1`. Approval expiry emits `[:normandy, :turn, :approval, :expired]` for the
  batch and a `[:normandy, :tool, :denied]` (reason `:approval_expired`) per call; a rejected
  call emits `[:normandy, :tool, :denied]` with `:approval_rejected`.
```

- [ ] **Step 3c: `Turn.Supervisor`**

Replace everything in `lib/normandy/agents/turn/supervisor.ex` above `defp put_child_name/1`
(lines 1-54) with:

```elixir
defmodule Normandy.Agents.Turn.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Turn.Server` processes (one per live session).

  A crashed session restarts (`restart: :transient`) and reloads its turn state
  and memory from the store. See `start_link/1` for options.
  """
  use DynamicSupervisor

  alias Normandy.Agents.Turn.Server
  alias Normandy.Options

  @default_max_restarts 100
  @default_max_seconds 5

  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the supervisor."],
                            max_restarts: [
                              type: :non_neg_integer,
                              default: @default_max_restarts,
                              doc:
                                "Restarts allowed within `:max_seconds`. The limit is shared by " <>
                                  "every session under this supervisor; exceeding it stops the " <>
                                  "supervisor and all of its sessions. The OTP default (3 in 5 " <>
                                  "seconds) would let a few unrelated session crashes take every " <>
                                  "session down."
                            ],
                            max_seconds: [
                              type: :pos_integer,
                              default: @default_max_seconds,
                              doc: "The window for `:max_restarts`, in seconds."
                            ]
                          )

  @doc false
  def default_restart_limit,
    do: [max_restarts: @default_max_restarts, max_seconds: @default_max_seconds]

  @doc """
  Starts the supervisor.

  ## Options

  #{Options.docs(@start_link_opts_schema)}
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})
    name = Keyword.get(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: Keyword.fetch!(opts, :max_restarts),
      max_seconds: Keyword.fetch!(opts, :max_seconds)
    )
  end

  @doc """
  Starts a `Turn.Server` for a session under `sup`, named through the registry's
  `child_name/2` when it has one.

  `server_opts` are checked here, in the caller, before the supervisor starts anything:
  a bad option raises `ArgumentError` instead of coming back as the supervisor's
  `{:error, {exception, stacktrace}}`.

  ## Options

  The options of `Normandy.Agents.Turn.Server.start_link/1`.
  """
  @spec start_server(:gen_statem.server_ref() | pid(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_server(sup, server_opts) do
    server_opts =
      server_opts
      |> Options.validate!(Server.__opts_schema__(:start_link), {__MODULE__, :start_server, 2})
      |> put_child_name()

    spec = %{
      id: Server,
      start: {Server, :start_link, [server_opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(sup, spec)
  end
```

`put_child_name/1` (the private function after it) is unchanged.

- [ ] **Step 3d: `Turn.Supervisor.Horde`**

Add `alias Normandy.Options` under `alias Normandy.Agents.Turn.Server`. Replace `start_link/1` and
`start_server/2` (lines 20-47) with:

```elixir
    @start_link_opts_schema NimbleOptions.new!(
                              name: [
                                type: :any,
                                default: __MODULE__,
                                doc: "The Horde supervisor's name; pass it to `start_server/2`."
                              ],
                              max_restarts: [
                                type: :non_neg_integer,
                                default:
                                  Normandy.Agents.Turn.Supervisor.default_restart_limit()[
                                    :max_restarts
                                  ],
                                doc: "Restarts allowed within `:max_seconds`."
                              ],
                              max_seconds: [
                                type: :pos_integer,
                                default:
                                  Normandy.Agents.Turn.Supervisor.default_restart_limit()[
                                    :max_seconds
                                  ],
                                doc: "The window for `:max_restarts`, in seconds."
                              ]
                            )

    @doc """
    Starts the Horde supervisor (`members: :auto`).

    ## Options

    #{Options.docs(@start_link_opts_schema)}
    """
    @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
    def start_link(opts) do
      opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

      Horde.DynamicSupervisor.start_link(
        name: Keyword.fetch!(opts, :name),
        strategy: :one_for_one,
        members: :auto,
        max_restarts: Keyword.fetch!(opts, :max_restarts),
        max_seconds: Keyword.fetch!(opts, :max_seconds)
      )
    end

    @doc """
    Starts a `Turn.Server` for a session under the Horde supervisor `sup` (its name).
    `server_opts` are checked in the caller before Horde starts anything.

    ## Options

    The options of `Normandy.Agents.Turn.Server.start_link/1`.
    """
    @spec start_server(term(), keyword()) :: {:ok, pid()} | {:error, term()}
    def start_server(sup, server_opts) do
      server_opts =
        server_opts
        |> Options.validate!(Server.__opts_schema__(:start_link), {__MODULE__, :start_server, 2})
        |> put_child_name()

      restart = restart_for(Keyword.get(server_opts, :resume_policy, :lazy))

      spec = %{
        id: Keyword.fetch!(server_opts, :session_id),
        start: {Server, :start_link, [server_opts]},
        restart: restart,
        type: :worker
      }

      Horde.DynamicSupervisor.start_child(sup, spec)
    end
```

- [ ] **Step 3e: `Turn.ResumeReaper`**

Add `alias Normandy.Options`. Above `@spec start_link(opts())` add:

```elixir
  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the reaper."],
                            store: [
                              type: {:tuple, [:atom, :any]},
                              required: true,
                              doc:
                                "The `SessionStore` as `{module, handle}`; its " <>
                                  "`list_resumable/1` names the `:eager` sessions."
                            ],
                            registry: [
                              type: {:tuple, [:atom, :any]},
                              required: true,
                              doc: "The `SessionRegistry` as `{module, handle}`."
                            ],
                            supervisor: [
                              type: :any,
                              required: true,
                              doc: "The supervisor sessions restart under (its name, for Horde)."
                            ],
                            supervisor_mod: [
                              type: :atom,
                              default: Normandy.Agents.Turn.Supervisor.Horde,
                              doc: "The module whose `start_server/2` restarts a session."
                            ],
                            template_provider: [
                              type: {:tuple, [:atom, :any]},
                              required: true,
                              doc: "The `AgentTemplate` as `{module, handle}` (thin starts)."
                            ],
                            subscriber: [
                              type: {:or, [{:fun, 2}, nil]},
                              doc: "Passed to every session the reaper restarts."
                            ],
                            handlers: [
                              type:
                                {:or,
                                 [
                                   {:struct, Normandy.Agents.Turn.Driver.Handlers},
                                   {:custom, Normandy.Options, :plain_map, []},
                                   nil
                                 ]},
                              doc: "Passed to every session the reaper restarts."
                            ]
                          )

  @doc """
  Starts the reaper.

  ## Options

  #{Options.docs(@start_link_opts_schema)}
  """
```

Replace `start_link/1`'s body:

```elixir
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end
```

In `init/1`, replace
`supervisor_mod: Keyword.get(opts, :supervisor_mod, Normandy.Agents.Turn.Supervisor.Horde),`
with `supervisor_mod: Keyword.fetch!(opts, :supervisor_mod),`.

- [ ] **Step 3f: `Turn.new/1`**

Add `alias Normandy.Options`. Replace the `@doc`, `@spec` and `new/1` (lines 75-101) with:

```elixir
  @new_opts_schema NimbleOptions.new!(
                     max_iterations: [
                       type: :pos_integer,
                       default: 5,
                       doc:
                         "Tool-loop iterations before the forced final call. Enforces the " <>
                           "`pos_integer()` contract on `State.max_iterations` (`BaseAgent.init/1` " <>
                           "applies the same check at the shell boundary)."
                     ],
                     response_model: [
                       type: :any,
                       doc:
                         "The response model for tool-loop LLM calls, e.g. `%ToolCallResponse{}`."
                     ],
                     output_schema: [
                       type: :any,
                       doc:
                         "The response model for the forced final call when the iteration cap is hit."
                     ]
                   )

  @doc """
  Builds the initial `:provisioning` state for a turn.

  ## Options

  #{Options.docs(@new_opts_schema)}
  """
  @spec new(keyword()) :: State.t()
  def new(opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})
    max = Keyword.fetch!(opts, :max_iterations)

    %State{
      status: :provisioning,
      max_iterations: max,
      iterations_left: max,
      response_model: Keyword.get(opts, :response_model),
      output_schema: Keyword.get(opts, :output_schema)
    }
  end
```

If Task 3.1–3.6 added other fields to the `%State{}` built here, keep them: only the opts reads and
the `unless ... raise` block change.

- [ ] **Step 4: Update the two tests that pinned the old messages**

`test/agents/turn_test.exs:32`: replace `~r/:max_iterations must be an integer >= 1/` with
`~r/^Normandy\.Agents\.Turn\.new\/1: invalid value for :max_iterations option: expected positive integer, got: 0/`.
The `got: -1`, `got: 1.5` and `got: "5"` assertions (lines 36-47) still match.

`test/agents/turn/server_test.exs:2138-2149`: rename the test to
`"an invalid :on_approval_timeout raises ArgumentError naming the key, the allowed values and the value"`
and replace the regex with
`~r/^Normandy\.Agents\.Turn\.Server\.start_link\/1: invalid value for :on_approval_timeout option: expected one of \[:continue, :fail\], got: :sometimes/`.

- [ ] **Step 5: Run the new tests**

Run: `mix test test/options/turn_options_test.exs test/agents/turn_test.exs test/agents/turn/server_test.exs`
Expected: PASS, ` 0 failures`.

- [ ] **Step 6: MIGRATING**

Insert, before `## New, non-breaking`, §30 (after Task 3.6c's §29; check with
`grep -n '^## [0-9]' MIGRATING-2.0.md | tail -1`):

```markdown
## 30. Every option is checked

Every public function that takes a keyword list of options validates it. A misspelled or
unsupported key, a missing required key or a value of the wrong type raises `ArgumentError`
in the caller, naming the function and the key:

    Normandy.Agents.Turn.Server.start_link/1: unknown option :approval_timout_ms; supported: :session_id, :store, ...

In 1.x most of these keys were ignored, so a typo silently kept the default. Each function's
`## Options` docs list its keys, types and defaults.

- `Turn.Server.start_link/1`, `Turn.Supervisor.start_server/2` and
  `Turn.Supervisor.Horde.start_server/2` raise in the caller. A missing `:store`, `:registry`
  or `:session_id` used to crash `Turn.Server.init/1` with a `KeyError`, which came back as the
  supervisor's `{:error, {%KeyError{}, stacktrace}}`. `Turn.ResumeReaper.start_link/1`
  likewise raises for a missing `:store`, `:registry`, `:supervisor` or `:template_provider`.
- The messages for a bad `:on_approval_timeout` and a bad `Turn.new/1` `:max_iterations`
  changed: `...: invalid value for :on_approval_timeout option: expected one of
  [:continue, :fail], got: :sometimes`.
- `:handlers` must be a `Turn.Driver.Handlers` struct or a plain map.
```

- [ ] **Step 7: Format and run the suite**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`. A failing caller is handled by Convention 8; name each fixed caller in the
commit body.

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/options.ex test/support/options_assertions.ex \
  lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/supervisor.ex \
  lib/normandy/agents/turn/supervisor/horde.ex lib/normandy/agents/turn/resume_reaper.ex \
  lib/normandy/agents/turn.ex MIGRATING-2.0.md test/options/turn_options_test.exs \
  test/agents/turn_test.exs test/agents/turn/server_test.exs
git commit -m "feat(turn): reject unknown options at the turn entry points"
```

Add any caller fixed under Convention 8 to the `git add` line by name.

---

### Task 3.7b: Options at the coordination, batch, workflow and resilience entry points

**Files:**
- Modify: `lib/normandy/options.ex` (`:agent`, `:agent_config`, `:agents` join `@sensitive_keys`)
- Modify: `lib/normandy/coordination/agent_process.ex` (`start_link/1` 70-103, `run/3` 105-121,
  `cast/3` 123-146, `init/1` 253-272, `@type run_opts` 63-67)
- Modify: `lib/normandy/coordination/agent_supervisor.ex` (`start_link/1` 40-71, `start_agent/2` 73-110)
- Modify: `lib/normandy/coordination/agent_pool.ex` (`start_link/1` 77-111, `transaction/3`
  113-162, `checkout/2` 164-207, `init/1` 264-268)
- Modify: `lib/normandy/coordination/parallel_orchestrator.ex` (`execute_stream/2` only)
- Modify: `lib/normandy/coordination/hierarchical_coordinator.ex` (`new/1` 41-70, `execute/3`
  72-104, `execute_with_tasks/3` 120-153)
- Modify: `lib/normandy/coordination/reactive.ex` (`race/3` ~93, `all/3` ~176, `some/3` ~263)
- Modify: `lib/normandy/batch/processor.ex` (`@type batch_option` 56-61, docs 81-118,
  `process_batch/3` 121-128, `process_batch_with_stats/3` 192-196, `process_batch_chunked/3` 222-252)
- Modify: `lib/normandy/agents/base_agent.ex` (`process_batch/3`, `process_batch_with_stats/3`, ~2130-2192)
- Modify: `lib/normandy/dsl/workflow.ex` (module attributes; the generated `execute/1` and its doc, 399-430)
- Modify: `lib/normandy/resilience/circuit_breaker.ex` (`start_link/1` 92-122, `init/1` 238-254)
- Modify: `MIGRATING-2.0.md` (Task 3.7a's section)
- Create: `test/options/coordination_options_test.exs`
- Modify: `test/coordination/agent_pool_test.exs:296-305`

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`, `docs/1`, `plain_map/1` (Task 3.1a);
  `Normandy.Test.OptionsAssertions` (Task 3.7a); Task 3.5a's `AgentProcess` (a `Turn.Session`
  handle built in `init/1` from `@session_options`); Task 3.5b's `ParallelOrchestrator`
  `@opts_schema`. Not touched (validated by Task 3.5): `ParallelOrchestrator.execute/3`,
  `execute_specs/2`, `SequentialOrchestrator.execute/3`, `execute_with_messages/3`.
- Produces: `AgentProcess.__opts_schema__(:start_link)`, `Batch.Processor.__opts_schema__/1`
  (`:process_batch | :process_batch_with_stats`), `Normandy.DSL.Workflow.__validate_execute_opts__/2`
  (all `@doc false`). Validated: `AgentProcess.start_link/1`, `run/3`, `cast/3`;
  `AgentSupervisor.start_link/1`, `start_agent/2`; `AgentPool.start_link/1`, `transaction/3`,
  `checkout/2`; `ParallelOrchestrator.execute_stream/2`;
  `HierarchicalCoordinator.new/1`, `execute/3`, `execute_with_tasks/3`; `Reactive.race/3`,
  `all/3`, `some/3`; `Batch.Processor.process_batch/3`, `process_batch_with_stats/3`,
  `process_batch_chunked/3`; `BaseAgent.process_batch/3`, `process_batch_with_stats/3`; every
  `use Normandy.DSL.Workflow` module's `execute/1`; `CircuitBreaker.start_link/1`.

- [ ] **Step 0: Re-inventory**

```bash
grep -n "^  def \|Keyword\.\(get\|get_lazy\|fetch\|fetch!\|pop\|take\|put\|drop\)(opts" \
  lib/normandy/coordination/{agent_process,agent_supervisor,agent_pool,parallel_orchestrator,hierarchical_coordinator,reactive}.ex \
  lib/normandy/batch/processor.ex lib/normandy/resilience/circuit_breaker.ex
grep -n "Keyword\.\(get\|fetch!\)(opts" lib/normandy/dsl/workflow.ex
```

Expected keys (as of `95dc149`; Task 3.5 rewrites the two orchestrators): AgentProcess
`:agent :name :agent_id :context_pid :turn_engine :supervisor_mod :template_provider
:resume_policy :template_id :store :registry :supervisor`, the `Keyword.take` of `:subscriber
:handlers :approval_timeout_ms :on_approval_timeout :idle_timeout_ms`, `run/3` `:timeout`,
`cast/3` `:reply_to`; AgentSupervisor `:name :strategy :max_restarts :max_seconds :agent
:restart`; AgentPool `:name :timeout :block :agent_config :size :max_overflow :strategy`;
Parallel `execute_stream/2` `:max_concurrency :timeout`; Hierarchical `:manager :workers
:delegation_strategy :shared_context :max_concurrency :manager_prompt`; Reactive `:timeout
:on_complete :max_concurrency :fail_fast :count`; Processor `:max_concurrency :ordered :timeout
:on_progress :on_error :chunk_size :chunk_delay`; CircuitBreaker `:name :failure_threshold
:success_threshold :timeout :half_open_max_calls`; Workflow `:agents :initial_input :context`.
After Task 3.5a, `AgentProcess.init/1` passes `Keyword.take(opts, @session_options)`
(`:supervisor_mod :template_provider :template_id :resume_policy :subscriber :handlers
:approval_timeout_ms :on_approval_timeout :idle_timeout_ms`) to `Turn.Session.new/1` instead of
reading them; they stay in the `start_link/1` schema. Apply Convention 9 to any difference.

- [ ] **Step 1: Write the failing tests**

Create `test/options/coordination_options_test.exs`:

```elixir
defmodule Normandy.Options.CoordinationOptionsTest do
  use ExUnit.Case, async: true

  import Normandy.Test.OptionsAssertions

  alias Normandy.Agents.BaseAgent
  alias Normandy.Batch.Processor
  alias Normandy.Coordination.{
    AgentPool,
    AgentProcess,
    AgentSupervisor,
    HierarchicalCoordinator,
    ParallelOrchestrator,
    Reactive
  }

  alias Normandy.Resilience.CircuitBreaker
  alias Normandy.Test.StubClient

  defmodule OneStepWorkflow do
    use Normandy.DSL.Workflow

    workflow do
      step :only do
        agent(OptionsProbeAgent)
        input("go")
      end
    end
  end

  # {misspelled key, {module, function, args}}; each call raises before it touches its
  # other arguments, so they are placeholders.
  @cases [
    {:agnt, {AgentProcess, :start_link, [[agnt: :x]]}},
    {:timout, {AgentProcess, :run, [:no_server, "hi", [timout: 1]]}},
    {:replyto, {AgentProcess, :cast, [:no_server, "hi", [replyto: :x]]}},
    {:max_restart, {AgentSupervisor, :start_link, [[max_restart: 1]]}},
    {:restrat, {AgentSupervisor, :start_agent, [:no_sup, [restrat: :temporary]]}},
    {:sise, {AgentPool, :start_link, [[sise: 3]]}},
    {:timout, {AgentPool, :transaction, [:no_pool, [timout: 1], &Function.identity/1]}},
    {:blok, {AgentPool, :checkout, [:no_pool, [blok: false]]}},
    {:max_concurency, {ParallelOrchestrator, :execute_stream, [[], [max_concurency: 2]]}},
    {:workrs, {HierarchicalCoordinator, :new, [[workrs: []]]}},
    {:max_concurency,
     {HierarchicalCoordinator, :execute, [%HierarchicalCoordinator{}, "go", [max_concurency: 2]]}},
    {:max_concurency,
     {HierarchicalCoordinator, :execute_with_tasks,
      [%HierarchicalCoordinator{}, [], [max_concurency: 2]]}},
    {:timout, {Reactive, :race, [[], "go", [timout: 1]]}},
    {:fail_fats, {Reactive, :all, [[], "go", [fail_fats: true]]}},
    {:cuont, {Reactive, :some, [[], "go", [cuont: 1]]}},
    {:max_concurency, {Processor, :process_batch, [:agent, [], [max_concurency: 2]]}},
    {:ordered, {Processor, :process_batch_with_stats, [:agent, [], [ordered: true]]}},
    {:chunk_sise, {Processor, :process_batch_chunked, [:agent, [], [chunk_sise: 2]]}},
    {:max_concurency, {BaseAgent, :process_batch, [:agent, [], [max_concurency: 2]]}},
    {:ordered, {BaseAgent, :process_batch_with_stats, [:agent, [], [ordered: true]]}},
    {:initial_imput, {OneStepWorkflow, :execute, [[initial_imput: "go"]]}},
    {:failure_treshold, {CircuitBreaker, :start_link, [[failure_treshold: 3]]}}
  ]

  for {key, {mod, fun, args}} <- @cases do
    test "#{inspect(mod)}.#{fun}/#{length(args)} rejects #{inspect(key)}" do
      assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))
    end
  end

  # OneStepWorkflow is compiled from this .exs file and has no docs chunk (its execute/1 doc
  # is the DSL's @execute_doc).
  test "every entry point documents its options" do
    for {_key, {mod, fun, args}} <- @cases, mod != OneStepWorkflow do
      assert_documents_options(mod, fun, length(args))
    end
  end

  defp agent, do: BaseAgent.init(%{client: %StubClient{}, model: "m"})

  describe "behaviour the schemas must keep" do
    test "AgentSupervisor.start_agent/2 keeps :restart for the child spec and does not pass it on" do
      sup = start_supervised!(AgentSupervisor)
      assert {:ok, pid} = AgentSupervisor.start_agent(sup, agent: agent(), restart: :temporary)
      assert is_pid(pid)
    end

    test "an unknown :turn_engine raises in the caller instead of crashing init/1" do
      error =
        assert_raise ArgumentError, fn ->
          AgentProcess.start_link(agent: agent(), turn_engine: :async)
        end

      assert error.message =~
               "invalid value for :turn_engine option: expected one of [:inline, :server], got: :async"
    end

    test "a misspelled circuit_breaker option raises when the agent is built" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(
            model: "m",
            client: %StubClient{},
            circuit_breaker: [failure_treshold: 3]
          )
        end

      assert error.message =~ ":failure_treshold"
    end

    test "a bad :agent value is rejected without echoing it" do
      error =
        assert_raise ArgumentError, fn ->
          AgentProcess.start_link(agent: %{client: %{api_key: "sk-secret"}})
        end

      assert error.message =~ "Normandy.Coordination.AgentProcess.start_link/1: "
      assert error.message =~ ":agent"
      refute error.message =~ "sk-secret"
    end

    test "a struct where AgentPool expects an agent config map is an ArgumentError" do
      error = assert_raise ArgumentError, fn -> AgentPool.start_link(agent_config: %URI{}) end
      assert error.message =~ "Normandy.Coordination.AgentPool.start_link/1: "
      assert error.message =~ ":agent_config"
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/options/coordination_options_test.exs`
Expected: FAIL. Rows report "nothing was raised" or another exception (`KeyError` from
`AgentProcess.start_link/1`, an exit from `GenServer.call(:no_server, ...)`,
`FunctionClauseError`/`CaseClauseError` from the orchestrators); the docs test fails on the
first function without generated options; the `:turn_engine` test gets a `CaseClauseError` exit.

- [ ] **Step 3: Sensitive keys**

In `lib/normandy/options.ex`, add `:agent`, `:agent_config` and `:agents` to `@sensitive_keys`
(Convention 10): each holds agent configs, whose `:client` carries an API key.

- [ ] **Step 3a: `AgentProcess`**

Add `alias Normandy.Options`. Replace `@type run_opts` (lines 63-67) with
`@type run_opts :: [timeout: timeout()]`. Above `start_link/1`'s `@doc` add:

```elixir
  @start_link_opts_schema NimbleOptions.new!(
                            agent: [
                              type: {:struct, Normandy.Agents.BaseAgentConfig},
                              required: true,
                              doc: "The agent config the process runs."
                            ],
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the process."],
                            agent_id: [
                              type: :string,
                              doc:
                                "The agent's id (default: a new UUID). In `:server` mode it is " <>
                                  "also the session id."
                            ],
                            context_pid: [
                              type: {:or, [:pid, :atom]},
                              doc:
                                "A `Normandy.Coordination.StatefulContext` process, kept in the " <>
                                  "agent's state."
                            ],
                            turn_engine: [
                              type: {:in, [:inline, :server]},
                              default: :inline,
                              doc:
                                "`:inline` runs `BaseAgent.run/2` in this process; `:server` " <>
                                  "routes turns through `Turn.Session`/`Turn.Server` (approval " <>
                                  "parking, passivation, persistence)."
                            ],
                            store: [
                              type: {:tuple, [:atom, :any]},
                              doc:
                                "`:server` mode: the `SessionStore` as `{module, handle}`. " <>
                                  "Without it the process starts and owns an in-memory store."
                            ],
                            registry: [
                              type: {:tuple, [:atom, :any]},
                              doc:
                                "`:server` mode: the `SessionRegistry` as `{module, handle}`. " <>
                                  "Without it the process starts and owns a `Native` registry."
                            ],
                            supervisor: [
                              type: :any,
                              doc:
                                "`:server` mode: the session supervisor. Without it the process " <>
                                  "starts and owns a `Turn.Supervisor`."
                            ],
                            supervisor_mod: [
                              type: :atom,
                              doc:
                                "`:server` mode: the module whose `start_server/2` starts " <>
                                  "sessions (default `Normandy.Agents.Turn.Supervisor`)."
                            ],
                            template_provider: [
                              type: {:tuple, [:atom, :any]},
                              doc: "`:server` mode: the `AgentTemplate` as `{module, handle}`."
                            ],
                            resume_policy: [
                              type: {:in, [:lazy, :eager]},
                              doc: "`:server` mode: the session's resume policy (default `:lazy`)."
                            ],
                            template_id: [
                              type: :string,
                              doc: "`:server` mode: the template id (default: the config's name)."
                            ],
                            subscriber: [
                              type: {:fun, 2},
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ],
                            handlers: [
                              type:
                                {:or,
                                 [
                                   {:struct, Normandy.Agents.Turn.Driver.Handlers},
                                   {:custom, Normandy.Options, :plain_map, []}
                                 ]},
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ],
                            approval_timeout_ms: [
                              type: :timeout,
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ],
                            on_approval_timeout: [
                              type: {:in, [:continue, :fail]},
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ],
                            idle_timeout_ms: [
                              type: :timeout,
                              doc: "`:server` mode: passed to `Turn.Server.start_link/1`."
                            ]
                          )

  @run_opts_schema NimbleOptions.new!(
                     timeout: [
                       type: :timeout,
                       default: 60_000,
                       doc: "How long the caller waits for the reply, in ms."
                     ]
                   )

  @cast_opts_schema NimbleOptions.new!(
                      reply_to: [
                        type: {:or, [:pid, :atom]},
                        doc: "Where to send `{:agent_result, agent_id, result}` when the run ends."
                      ]
                    )

  @doc false
  def __opts_schema__(:start_link), do: @start_link_opts_schema
```

In the three `@doc`s, replace each `## Options` bullet list with
`## Options\n\n#{Options.docs(@start_link_opts_schema)}` (respectively `@run_opts_schema`,
`@cast_opts_schema`). Bodies:

```elixir
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def run(server, input, opts \\ []) do
    opts = Options.validate!(opts, @run_opts_schema, {__MODULE__, :run, 3})
    GenServer.call(server, {:run, input, OtelCtx.capture()}, Keyword.fetch!(opts, :timeout))
  end

  def cast(server, input, opts \\ []) do
    opts = Options.validate!(opts, @cast_opts_schema, {__MODULE__, :cast, 3})
    reply_to = Keyword.get(opts, :reply_to)
    GenServer.cast(server, {:run_async, input, reply_to, OtelCtx.capture()})
  end
```

In `init/1`: `Keyword.get(opts, :agent_id, UUID.uuid4())` → `Keyword.get_lazy(opts, :agent_id, &UUID.uuid4/0)`;
`Keyword.get(opts, :turn_engine, :inline)` → `Keyword.fetch!(opts, :turn_engine)`. `:store`,
`:registry`, `:supervisor` keep `Keyword.get/2` (absent means "start and own one"); the
`@session_options` keys go on to `Turn.Session.new/1` untouched (Task 3.5a), which owns their
defaults (Convention 3).

- [ ] **Step 3b: `AgentSupervisor`**

Add `alias Normandy.Options`. Above `start_link/1`'s `@doc`:

```elixir
  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the supervisor."],
                            strategy: [
                              type: {:in, [:one_for_one]},
                              default: :one_for_one,
                              doc: "`DynamicSupervisor` supports only `:one_for_one`."
                            ],
                            max_restarts: [
                              type: :non_neg_integer,
                              default: 3,
                              doc: "Restarts allowed within `:max_seconds`."
                            ],
                            max_seconds: [
                              type: :pos_integer,
                              default: 5,
                              doc: "The window for `:max_restarts`, in seconds."
                            ]
                          )

  # The agent process's own options plus :restart, which stays here for the child spec.
  @start_agent_opts_schema NimbleOptions.new!(
                             AgentProcess.__opts_schema__(:start_link).schema ++
                               [
                                 restart: [
                                   type: {:in, [:permanent, :temporary, :transient]},
                                   default: :transient,
                                   doc:
                                     "The child's restart value. Not passed to the agent process."
                                 ]
                               ]
                           )
```

Replace both `## Options` bullet lists with the generated docs, and the bodies:

```elixir
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.pop(opts, :name) do
      {nil, sup_opts} -> DynamicSupervisor.start_link(__MODULE__, sup_opts)
      {name, sup_opts} -> DynamicSupervisor.start_link(__MODULE__, sup_opts, name: name)
    end
  end

  def start_agent(supervisor, opts) do
    opts = Options.validate!(opts, @start_agent_opts_schema, {__MODULE__, :start_agent, 2})
    {restart, process_opts} = Keyword.pop!(opts, :restart)

    child_spec = %{
      id: AgentProcess,
      start: {AgentProcess, :start_link, [process_opts]},
      restart: restart,
      shutdown: 5000,
      type: :worker
    }

    DynamicSupervisor.start_child(supervisor, child_spec)
  end
```

`init/1` (`DynamicSupervisor.init(opts)`) is unchanged: it receives `:strategy`, `:max_restarts`
and `:max_seconds` only.

- [ ] **Step 3c: `AgentPool`**

Add `alias Normandy.Options`. Schemas:

```elixir
  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the pool."],
                            agent_config: [
                              type:
                                {:or,
                                 [{:custom, Normandy.Options, :plain_map, []}, :keyword_list]},
                              required: true,
                              doc: "The `BaseAgent.init/1` config every pooled agent is built from."
                            ],
                            size: [type: :pos_integer, default: 10, doc: "Agents started up front."],
                            max_overflow: [
                              type: :non_neg_integer,
                              default: 5,
                              doc: "Extra agents started while every pooled agent is checked out."
                            ],
                            strategy: [
                              type: {:in, [:lifo, :fifo]},
                              default: :lifo,
                              doc:
                                "Which free agent a checkout gets: the most (`:lifo`) or least " <>
                                  "(`:fifo`) recently returned."
                            ]
                          )

  @transaction_opts_schema NimbleOptions.new!(
                             timeout: [
                               type: :timeout,
                               default: 5000,
                               doc: "How long to wait for a free agent, in ms."
                             ]
                           )

  @checkout_opts_schema NimbleOptions.new!(
                          timeout: [
                            type: :timeout,
                            default: 5000,
                            doc: "How long to wait for a free agent, in ms (blocking checkout)."
                          ],
                          block: [
                            type: :boolean,
                            default: true,
                            doc:
                              "`false` returns `{:error, :no_agents}` at once when every agent " <>
                                "is in use and the overflow limit is reached."
                          ]
                        )
```

Docs as Convention 5. Bodies:

```elixir
  def start_link(opts) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def transaction(pool, opts \\ [], fun) when is_function(fun, 1) do
    opts = Options.validate!(opts, @transaction_opts_schema, {__MODULE__, :transaction, 3})

    case checkout(pool, timeout: Keyword.fetch!(opts, :timeout)) do
      {:ok, agent_pid} ->
        try do
          result = fun.(agent_pid)
          {:ok, result}
        after
          checkin(pool, agent_pid)
        end

      error ->
        error
    end
  end

  def checkout(pool, opts \\ []) do
    opts = Options.validate!(opts, @checkout_opts_schema, {__MODULE__, :checkout, 2})

    # The pool enforces the timeout and always replies, so a caller never exits
    # on a busy pool and an agent is never handed to a caller that gave up.
    GenServer.call(
      pool,
      {:checkout, Keyword.fetch!(opts, :block), Keyword.fetch!(opts, :timeout)},
      :infinity
    )
  end
```

In `init/1`: `Keyword.get(opts, :size, 10)` → `Keyword.fetch!(opts, :size)`;
`Keyword.get(opts, :max_overflow, 5)` → `Keyword.fetch!(opts, :max_overflow)`;
`Keyword.get(opts, :strategy, :lifo)` → `Keyword.fetch!(opts, :strategy)`.

`test/coordination/agent_pool_test.exs:296-305`: replace the regex with
`~r/^Normandy\.Coordination\.AgentPool\.checkout\/2: invalid value for :timeout option: expected non-negative integer or :infinity, got: -1/`.

- [ ] **Step 3d: `ParallelOrchestrator.execute_stream/2`**

Task 3.5b validates `ParallelOrchestrator.execute/3` and `execute_specs/2` (one `@opts_schema`
with `:max_concurrency`, `:timeout`, `:on_agent_complete`) and Task 3.5c validates
`SequentialOrchestrator.execute/3` and `execute_with_messages/3`; they are not touched here
(the coverage test of Task 3.7d lists them). `execute_stream/2` is left. Below Task 3.5b's
`@opts_schema` add:

```elixir
  @execute_stream_opts_schema NimbleOptions.new!(
                                Keyword.take(@opts_schema.schema, [:max_concurrency, :timeout])
                              )
```

`execute_stream/2`'s first expression becomes
`opts = Normandy.Options.validate!(opts, @execute_stream_opts_schema, {__MODULE__, :execute_stream, 2})`
(before `Orchestration.specs!/3`); `Keyword.get(opts, :max_concurrency, 10)` →
`Keyword.fetch!(opts, :max_concurrency)` and `Keyword.get(opts, :timeout, 300_000)` →
`Keyword.fetch!(opts, :timeout)`; its `@doc` gets
`## Options\n\n#{Normandy.Options.docs(@execute_stream_opts_schema)}`. If Task 3.5b named its
schema differently, take the two keys from that attribute.

- [ ] **Step 3e: `HierarchicalCoordinator`**

Add `alias Normandy.Options`. Schemas:

```elixir
  @new_opts_schema NimbleOptions.new!(
                     manager: [type: :any, required: true, doc: "The manager agent."],
                     workers: [
                       type: {:list, {:custom, Normandy.Options, :plain_map, []}},
                       required: true,
                       doc: "The workers, each `%{id: String.t(), agent: agent}`."
                     ],
                     delegation_strategy: [
                       type: {:in, [:round_robin, :broadcast, :conditional]},
                       default: :round_robin,
                       doc: "How the manager's plan is delegated."
                     ],
                     shared_context: [
                       type: {:struct, Normandy.Coordination.SharedContext},
                       doc: "The context the agents share (default: a new `SharedContext`)."
                     ]
                   )

  @execute_opts_schema NimbleOptions.new!(
                         shared_context: [
                           type: {:struct, Normandy.Coordination.SharedContext},
                           doc: "Overrides the coordinator's shared context for this run."
                         ],
                         max_concurrency: [
                           type: :pos_integer,
                           default: 5,
                           doc: "Workers run at once."
                         ],
                         manager_prompt: [
                           type: :string,
                           doc: "A prompt put before the input the manager gets."
                         ]
                       )

  @execute_with_tasks_opts_schema NimbleOptions.new!(
                                    Keyword.take(@execute_opts_schema.schema, [
                                      :shared_context,
                                      :max_concurrency
                                    ])
                                  )
```

Bodies: `new/1` starts with
`opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})` and builds the struct
with `delegation_strategy: Keyword.fetch!(opts, :delegation_strategy)` and
`shared_context: Keyword.get_lazy(opts, :shared_context, &SharedContext.new/0)`; `execute/3` and
`execute_with_tasks/3` validate as their first expression (before `WorkflowSpan.span/3`) with
`{__MODULE__, :execute, 3}` / `{__MODULE__, :execute_with_tasks, 3}`; in `run_hierarchy/3` and
`run_tasks/3`, `Keyword.get(opts, :max_concurrency, 5)` → `Keyword.fetch!(opts, :max_concurrency)`
(2 occurrences). The three `@doc`s get generated docs.

- [ ] **Step 3f: `Reactive`**

Add `alias Normandy.Options`. Schemas:

```elixir
  @timeout_opt [
    timeout: [type: :timeout, default: 60_000, doc: "How long to wait, in ms."]
  ]
  @on_complete_opt [
    on_complete: [
      type: {:fun, 2},
      doc: "Called as each agent finishes: `(agent_id, result -> any)`."
    ]
  ]

  @race_opts_schema NimbleOptions.new!(@timeout_opt ++ @on_complete_opt)
  @all_opts_schema NimbleOptions.new!(
                     @timeout_opt ++
                       @on_complete_opt ++
                       [
                         max_concurrency: [
                           type: :pos_integer,
                           doc: "Agents run at once (default: all of them)."
                         ],
                         fail_fast: [
                           type: :boolean,
                           default: false,
                           doc: "Stop at the first failure."
                         ]
                       ]
                   )
  @some_opts_schema NimbleOptions.new!(
                      [count: [type: :pos_integer, required: true, doc: "Successes needed."]] ++
                        @timeout_opt ++ @on_complete_opt
                    )
```

First expression of `race/3`, `all/3`, `some/3`:
`opts = Options.validate!(opts, @race_opts_schema, {__MODULE__, :race, 3})` (resp. `@all_opts_schema`/`:all`,
`@some_opts_schema`/`:some`). Readers: `Keyword.get(opts, :timeout, 60_000)` →
`Keyword.fetch!(opts, :timeout)` (3 occurrences); `Keyword.get(opts, :fail_fast, false)` →
`Keyword.fetch!(opts, :fail_fast)`; `:max_concurrency` keeps `Keyword.get(opts, :max_concurrency, length(agents))`;
`:on_complete` keeps `Keyword.get/2`. The three `@doc`s get generated docs.

- [ ] **Step 3g: `Batch.Processor` and `BaseAgent`'s batch functions**

In `processor.ex` add `alias Normandy.Options`; change `@type batch_option`'s
`{:timeout, pos_integer()}` to `{:timeout, timeout()}` and add `| {:chunk_size, pos_integer()} |
{:chunk_delay, non_neg_integer()}`. After `@default_timeout` add:

```elixir
  # Keys every batch entry point takes. process_batch_with_stats/3 takes only these: it
  # always returns the stats map, so an :ordered option would be ignored.
  @batch_opts [
    max_concurrency: [
      type: :pos_integer,
      default: @default_max_concurrency,
      doc: "Items processed at once."
    ],
    timeout: [
      type: :timeout,
      default: @default_timeout,
      doc:
        "Timeout per item, in ms. An item that runs past it is stopped and fails with " <>
          "`{:exit, :timeout}`; the other items carry on."
    ],
    on_progress: [
      type: {:fun, 2},
      doc: "Called in the caller after each item completes: `(completed, total -> any)`."
    ],
    on_error: [
      type: {:fun, 2},
      doc: "Called in the caller for each failed item: `(input, error -> any)`."
    ]
  ]
  @ordered_opt [
    ordered: [
      type: :boolean,
      default: true,
      doc: "`true`: one result per input, in input order. `false`: a `batch_result` map."
    ]
  ]

  @process_batch_opts_schema NimbleOptions.new!(@batch_opts ++ @ordered_opt)
  @process_batch_with_stats_opts_schema NimbleOptions.new!(@batch_opts)
  @process_batch_chunked_opts_schema NimbleOptions.new!(
                                       @batch_opts ++
                                         @ordered_opt ++
                                         [
                                           chunk_size: [
                                             type: :pos_integer,
                                             default: 100,
                                             doc: "Items per chunk."
                                           ],
                                           chunk_delay: [
                                             type: :non_neg_integer,
                                             default: 0,
                                             doc: "Milliseconds to wait between chunks."
                                           ]
                                         ]
                                     )

  @doc false
  def __opts_schema__(:process_batch), do: @process_batch_opts_schema
  def __opts_schema__(:process_batch_with_stats), do: @process_batch_with_stats_opts_schema
```

Replace each of the three `## Options` blocks (in `process_batch/3`'s doc, the bullet list from
`## Options` to `## Returns`; in `process_batch_chunked/3`'s, from `## Options` to the paragraph
"Returns the same shape...") with the generated docs; `process_batch_with_stats/3`'s doc gets
`## Options\n\n#{Options.docs(@process_batch_with_stats_opts_schema)}` before `## Example`.

`process_batch/3`, first lines of the body:

```elixir
    opts = Options.validate!(opts, @process_batch_opts_schema, {__MODULE__, :process_batch, 3})
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)
    ordered = Keyword.fetch!(opts, :ordered)
    timeout = Keyword.fetch!(opts, :timeout)
    on_progress = Keyword.get(opts, :on_progress)
    on_error = Keyword.get(opts, :on_error)
```

`process_batch_with_stats/3`:

```elixir
  def process_batch_with_stats(agent, inputs, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        @process_batch_with_stats_opts_schema,
        {__MODULE__, :process_batch_with_stats, 3}
      )

    process_batch(agent, inputs, Keyword.put(opts, :ordered, false))
  end
```

`process_batch_chunked/3`, replace its first three lines with:

```elixir
    opts =
      Options.validate!(
        opts,
        @process_batch_chunked_opts_schema,
        {__MODULE__, :process_batch_chunked, 3}
      )

    {chunk_size, opts} = Keyword.pop!(opts, :chunk_size)
    {chunk_delay, opts} = Keyword.pop!(opts, :chunk_delay)
```

and `if Keyword.get(opts, :ordered, true) do` → `if Keyword.fetch!(opts, :ordered) do`.

In `base_agent.ex` (add `alias Normandy.Options` if Task 3.1 did not), the two delegates become:

```elixir
  def process_batch(agent, inputs, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        Processor.__opts_schema__(:process_batch),
        {__MODULE__, :process_batch, 3}
      )

    Processor.process_batch(agent, inputs, opts)
  end

  def process_batch_with_stats(agent, inputs, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        Processor.__opts_schema__(:process_batch_with_stats),
        {__MODULE__, :process_batch_with_stats, 3}
      )

    Processor.process_batch_with_stats(agent, inputs, opts)
  end
```

and each of their `@doc`s gets `## Options\n\nThe options of `Normandy.Batch.Processor.process_batch/3``
(resp. `process_batch_with_stats/3`). The docs are not generated from Processor's schema on
purpose: that would make `BaseAgent` a compile-time dependent of `Batch.Processor`.

- [ ] **Step 3h: The workflow DSL's generated `execute/1`**

In `lib/normandy/dsl/workflow.ex` add `alias Normandy.Options` and, above
`defmacro __using__/1`:

```elixir
  @execute_opts_schema NimbleOptions.new!(
                         agents: [
                           type: {:custom, Normandy.Options, :plain_map, []},
                           required: true,
                           doc: "Each step's agent module mapped to its agent config."
                         ],
                         initial_input: [
                           type: :any,
                           required: true,
                           doc: "The first step's input."
                         ],
                         context: [
                           type: {:custom, Normandy.Options, :plain_map, []},
                           default: %{},
                           doc: "A context map the steps share."
                         ]
                       )

  @execute_doc """
  Executes the workflow.

  ## Options

  #{Options.docs(@execute_opts_schema)}
  ## Examples

      {:ok, result} = MyWorkflow.execute(
        agents: %{MyAgent => agent_instance},
        initial_input: "start here"
      )
  """

  @doc false
  # Called by every workflow's generated execute/1, so the error names that module.
  @spec __validate_execute_opts__(keyword(), module()) :: keyword()
  def __validate_execute_opts__(opts, workflow),
    do: Options.validate!(opts, @execute_opts_schema, {workflow, :execute, 1})
```

In `__before_compile__/1`'s final `quote`, replace the generated `@doc """ Executes the workflow.
... """` block (the heredoc above `def execute(opts)`) with `@doc unquote(@execute_doc)`, and the
first three lines of `execute/1` with:

```elixir
      def execute(opts) do
        opts = Normandy.DSL.Workflow.__validate_execute_opts__(opts, __MODULE__)
        agents_map = Keyword.fetch!(opts, :agents)
        initial_input = Keyword.fetch!(opts, :initial_input)
        context = Keyword.fetch!(opts, :context)
```

- [ ] **Step 3i: `CircuitBreaker`**

Add `alias Normandy.Options`. Above `start_link/1`'s `@doc`:

```elixir
  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the breaker."],
                            failure_threshold: [
                              type: :pos_integer,
                              default: 5,
                              doc: "Failures that open the breaker."
                            ],
                            success_threshold: [
                              type: :pos_integer,
                              default: 2,
                              doc: "Successes while half-open that close it again."
                            ],
                            timeout: [
                              type: :pos_integer,
                              default: 60_000,
                              doc:
                                "Milliseconds the breaker stays open before it lets probe " <>
                                  "calls through (half-open). Not a call timeout."
                            ],
                            half_open_max_calls: [
                              type: :pos_integer,
                              default: 1,
                              doc: "Probe calls allowed at once while half-open."
                            ]
                          )
```

Replace the doc's `## Options` list with the generated docs. Bodies:

```elixir
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end
```

In `init/1` the four `Keyword.get(opts, :key, default)` become `Keyword.fetch!(opts, :key)`.
`:timeout` keeps its name and meaning (Wave 4 owns the breaker's options).

- [ ] **Step 4: Run the new tests**

Run: `mix test test/options/coordination_options_test.exs test/coordination test/batch test/resilience test/dsl`
Expected: PASS, ` 0 failures`.

- [ ] **Step 5: MIGRATING**

Append to Task 3.7a's section (§30):

```markdown
- `AgentProcess.start_link/1` raises for a `:turn_engine` other than `:inline` or `:server`
  (it used to crash `init/1` with a `CaseClauseError`), and `AgentPool.start_link/1` for a
  missing `:agent_config` (a `KeyError` exit from `init/1`).
- `AgentSupervisor.start_link/1`'s `:strategy` accepts only `:one_for_one`, the only strategy
  `DynamicSupervisor` has (any other value crashed `init/1`).
- `Batch.Processor.process_batch_with_stats/3` and `BaseAgent.process_batch_with_stats/3`
  reject `:ordered`; it was overridden to `false`.
- `HierarchicalCoordinator.new/1`'s `:delegation_strategy` must be `:round_robin`,
  `:broadcast` or `:conditional`.
- A misspelled `circuit_breaker:` option (`failure_treshold:`) raises when the agent is built.
- `AgentPool.checkout/2`'s message for a bad `:timeout` is now `...: invalid value for :timeout
  option: expected non-negative integer or :infinity, got: -1`.
- A workflow's `execute/1` raises for a missing `:agents` or `:initial_input` (it raised
  `KeyError`) and for an unknown key.
```

- [ ] **Step 6: Format and run the suite**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`. Callers fixed under Convention 8 are named in the commit body.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/options.ex lib/normandy/coordination/agent_process.ex \
  lib/normandy/coordination/agent_supervisor.ex \
  lib/normandy/coordination/agent_pool.ex lib/normandy/coordination/parallel_orchestrator.ex \
  lib/normandy/coordination/hierarchical_coordinator.ex lib/normandy/coordination/reactive.ex \
  lib/normandy/batch/processor.ex lib/normandy/agents/base_agent.ex lib/normandy/dsl/workflow.ex \
  lib/normandy/resilience/circuit_breaker.ex MIGRATING-2.0.md \
  test/options/coordination_options_test.exs test/coordination/agent_pool_test.exs
git commit -m "feat(coordination): reject unknown options at the coordination, batch and workflow entry points"
```

---

### Task 3.7c: Options at the A2A, MCP, context, executor and remaining coordination entry points

**Files:**
- Modify: `lib/normandy/options.ex` (`:auth_token`, `:transport_opts`, `:context` join `@sensitive_keys`)
- Modify: `lib/normandy/a2a/agent_tool.ex` (`new/3` 51-75)
- Modify: `lib/normandy/a2a/registry.ex` (`discover_and_register/3` 25-55, `from_agent_card/3` 57-73)
- Modify: `lib/normandy/a2a/server.ex` (`build_agent_card/2` 38-88)
- Modify: `lib/normandy/mcp/tool_wrapper.ex` (`new/4` 52-71)
- Modify: `lib/normandy/mcp/registry.ex` (`discover_and_register/4`, `wrap_tools/4`)
- Modify: `lib/normandy/agents/base_agent.ex` (`register_mcp_tools/4` ~2100-2128,
  `validate_compaction_config!/1` ~974)
- Modify: `lib/normandy/context/summarizer.ex` (`summarize_messages/4`, `compress_conversation/3`,
  `estimate_savings/2`, `do_compress_conversation/7` line ~396)
- Modify: `lib/normandy/context/window_manager.ex` (`new/1` 57-97)
- Modify: `lib/normandy/behaviours/compactor/window_manager.ex` (schema, `validate_opts!/1`,
  `checked_manager/2`)
- Modify: `lib/normandy/coordination/stateful_context.ex` (`start_link/1` 38-63, `init/1` 232-233)
- Modify: `lib/normandy/coordination/agent_message.ex` (`new/1` 43-75)
- Modify: `lib/normandy/coordination/pattern.ex` (`ok!/2` 84-106, `error!/2` 124-145)
- Modify: `lib/normandy/components/agent_memory.ex` (`add_message/4` 40-51)
- Modify: `MIGRATING-2.0.md` (Task 3.7a's section)
- Create: `test/options/integration_options_test.exs`
- Modify: `test/context/window_manager_test.exs:9-21`
- Not touched: `lib/normandy/tools/executor.ex` (Task 3.4c already validates `execute_tool/2` and
  `execute_tool_classified/2` through `Normandy.Options` and deleted `execute/3`,
  `execute_parallel/3`, `execute_sequential/3` and `:max_retries`)

**Interfaces:**
- Consumes: `Normandy.Options.validate!/3`, `docs/1`, `plain_map/1`, the redacted-key list of
  `Normandy.Options` (Task 3.1); `Normandy.Tools.Toolset` (Task 3.4a); the tool contract and
  `Executor` as Task 3.4c leaves them; the compactor key `:context_window` (Task 3.2).
- Produces: `A2A.AgentTool.__opts_schema__(:new)`, `MCP.Registry.__opts_schema__(:discover_and_register)`,
  `Normandy.Behaviours.Compactor.WindowManager.validate_opts!/1` (all `@doc false`). Validated:
  `A2A.AgentTool.new/3`, `A2A.Registry.discover_and_register/3`, `from_agent_card/3`,
  `A2A.Server.build_agent_card/2`, `MCP.ToolWrapper.new/4`, `MCP.Registry.discover_and_register/4`,
  `wrap_tools/4`, `BaseAgent.register_mcp_tools/4`, `Context.Summarizer.summarize_messages/4`,
  `compress_conversation/3`, `estimate_savings/2`, `Context.WindowManager.new/1`, the
  `Compactor.WindowManager` compactor's opts (at `BaseAgent.init/1` and template rebuild),
  `StatefulContext.start_link/1`, `AgentMessage.new/1`, `Pattern.ok!/2`,
  `error!/2`, `AgentMemory.add_message/4`. Already validated by Task 3.4 (not re-done here,
  listed in Task 3.7d's coverage test): `Tools.Executor.execute_tool/2`,
  `execute_tool_classified/2`, `Toolset.register/3`, and `A2A.AgentTool.new/3`'s `:timeout`
  check (its hand-written registration-option message stays and runs before the schema).

- [ ] **Step 0: Re-inventory**

```bash
grep -n "^  def \|Keyword\.\(get\|get_lazy\|fetch\|fetch!\|pop\|take\|validate!\)(opts\|opts\[:" \
  lib/normandy/a2a/{agent_tool,registry,server}.ex lib/normandy/mcp/{tool_wrapper,registry}.ex \
  lib/normandy/context/{summarizer,window_manager}.ex lib/normandy/behaviours/compactor/window_manager.ex \
  lib/normandy/tools/executor.ex lib/normandy/coordination/{stateful_context,agent_message,pattern}.ex \
  lib/normandy/components/agent_memory.ex
```

Expected keys (as of `95dc149`): AgentTool `:skill_id :auth_token :transport_opts :timeout`;
A2A.Registry `:transport_opts` and `Keyword.take(opts, [:auth_token, :transport_opts, :timeout])`;
A2A.Server `:name :description :version :provider_url :provider_org :url :expose_tools`;
ToolWrapper `:prefix`; Summarizer `:prompt :max_tokens :keep_recent :summary_role
:summary_tokens :model`; WindowManager `:max_tokens :reserved_tokens :strategy`; the compactor
(after Task 3.2) `:context_window :reserved_tokens :strategy`; Executor: none to add (Task 3.4c
validates `:context`/`:timeout` itself); StatefulContext `:name :notify_on_change`; AgentMessage `:from :to :type :payload
:metadata`; Pattern `:default`; AgentMemory `:turn_id :id`. After Task 3.4c: `AgentTool` has no
`:timeout` field (its `new/3` raises on `:timeout` with a registration-option message);
`A2A.Registry.discover_and_register/3` reads `:timeout` as the registration timeout
(`Keyword.get(opts, :timeout, 60_000)`) and `from_agent_card/3` takes
`Keyword.take(opts, [:auth_token, :transport_opts])`. Apply Convention 9 to any other drift.

- [ ] **Step 1: Write the failing tests**

Create `test/options/integration_options_test.exs`:

```elixir
defmodule Normandy.Options.IntegrationOptionsTest do
  use ExUnit.Case, async: true

  import Normandy.Test.OptionsAssertions

  alias Normandy.A2A.AgentTool
  alias Normandy.A2A.Registry, as: A2ARegistry
  alias Normandy.A2A.Server, as: A2AServer
  alias Normandy.Agents.{BaseAgent, BaseAgentConfig}
  alias Normandy.Behaviours.Compactor.WindowManager, as: WindowCompactor
  alias Normandy.Components.AgentMemory
  alias Normandy.Context.{Summarizer, WindowManager}
  alias Normandy.Coordination.{AgentMessage, Pattern, StatefulContext}
  alias Normandy.MCP.Registry, as: MCPRegistry
  alias Normandy.MCP.ToolWrapper
  alias Normandy.Test.StubClient
  alias Normandy.Tools.Toolset

  @cases [
    {:skil_id, {AgentTool, :new, ["http://a", nil, [skil_id: "s"]]}},
    {:auth_tokn, {A2ARegistry, :discover_and_register, [%Toolset{}, "http://a", [auth_tokn: "t"]]}},
    {:auth_tokn, {A2ARegistry, :from_agent_card, [nil, "http://a", [auth_tokn: "t"]]}},
    {:expose_tool, {A2AServer, :build_agent_card, [%BaseAgentConfig{}, [expose_tool: :all]]}},
    {:prefx, {ToolWrapper, :new, [NoAdapter, nil, nil, [prefx: "p"]]}},
    {:prefx, {MCPRegistry, :discover_and_register, [%Toolset{}, NoAdapter, nil, [prefx: "p"]]}},
    {:prefx, {MCPRegistry, :wrap_tools, [NoAdapter, nil, [], [prefx: "p"]]}},
    {:prefx, {BaseAgent, :register_mcp_tools, [%BaseAgentConfig{}, NoAdapter, nil, [prefx: "p"]]}},
    {:max_token, {Summarizer, :summarize_messages, [nil, %{}, [], [max_token: 10]]}},
    {:max_summary_tokens,
     {Summarizer, :compress_conversation, [nil, %{}, [max_summary_tokens: 10]]}},
    {:summary_token, {Summarizer, :estimate_savings, [[], [summary_token: 2]]}},
    {:stratgy, {WindowManager, :new, [[max_tokens: 1000, stratgy: :oldest_first]]}},
    {:notify_on_chnage, {StatefulContext, :start_link, [[notify_on_chnage: false]]}},
    {:paylod, {AgentMessage, :new, [[paylod: %{}]]}},
    {:defualt, {Pattern, :ok!, [{:ok, 1}, [defualt: 2]]}},
    {:defualt, {Pattern, :error!, [{:error, 1}, [defualt: 2]]}},
    {:turnid, {AgentMemory, :add_message, [%AgentMemory{}, "user", "hi", [turnid: "t"]]}}
  ]

  for {key, {mod, fun, args}} <- @cases do
    test "#{inspect(mod)}.#{fun}/#{length(args)} rejects #{inspect(key)}" do
      assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))
    end
  end

  test "every entry point documents its options" do
    for {_key, {mod, fun, args}} <- @cases, do: assert_documents_options(mod, fun, length(args))
  end

  describe "behaviour the schemas must keep" do
    test "a bad :auth_token value is not echoed in the error" do
      error =
        assert_raise ArgumentError, fn ->
          AgentTool.new("http://a", nil, auth_token: :"sk-ant-secret")
        end

      assert error.message =~ ":auth_token"
      refute error.message =~ "sk-ant-secret"
    end

    test "Pattern.ok!/2 validates on the {:ok, _} path too, and still returns the value" do
      assert Pattern.ok!({:ok, 1}, default: 2) == 1
      assert Pattern.ok!({:error, :x}, default: 2) == 2
    end

    test "compress_conversation/3 hands only the summary options to summarize_messages/4" do
      # Same setup as summarizer_test.exs "uses custom summary role when provided".
      client = %Normandy.Test.MockSummarizerClient{summary_response: "the summary"}

      memory =
        Enum.reduce(1..15, AgentMemory.new_memory(), fn i, mem ->
          AgentMemory.add_message(mem, "user", "Message #{i}")
        end)

      agent = %{memory: memory, model: "test-model", config: %{client: client, model: "test-model"}}

      assert {:ok, %{memory: compressed}} =
               Summarizer.compress_conversation(client, agent,
                 keep_recent: 5,
                 summary_role: "user",
                 max_tokens: 50
               )

      assert AgentMemory.count_messages(compressed) < AgentMemory.count_messages(memory)
    end

    test "a misspelled WindowManager compactor option raises when the agent is built" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(
            model: "m",
            client: %StubClient{},
            behaviours: %Normandy.Behaviours.Config{
              compactor: {WindowCompactor, [context_window: 50_000, stratgy: :x]}
            }
          )
        end

      assert error.message =~ "Normandy.Agents.BaseAgent.init/1: "
      assert error.message =~ ":stratgy"
    end

    test "WindowManager.new/1 keeps its explanation for a missing :max_tokens" do
      error = assert_raise ArgumentError, fn -> WindowManager.new(strategy: :oldest_first) end

      assert error.message =~
               ~r/^Normandy\.Context\.WindowManager\.new\/1: requires :max_tokens/
    end
  end
end
```

The compactor test passes the compactor as `test/agents/base_agent_compaction_config_test.exs`
does at `95dc149` (`behaviours: %Behaviours.Config{compactor: {mod, opts}}`). If Task 3.2
changed how `init/1` takes it, check with
`grep -n "compactor" test/agents/base_agent_compaction_config_test.exs | head -5` and write this
test's `init` call the same way.

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/options/integration_options_test.exs`
Expected: FAIL. Rows report "nothing was raised" or another exception (a `Keyword.validate!`
`ArgumentError` without the prefix for `add_message/4`, `FunctionClauseError` and so on); the
`:auth_token` test fails on the value showing up (or nothing raised); the compactor test sees no
error; the `WindowManager` message test sees the old prefix `WindowManager.new/1 requires`.

- [ ] **Step 3a: Sensitive keys**

In `lib/normandy/options.ex`, add `:auth_token` (the A2A bearer token), `:transport_opts` (its
`:headers` can carry an `authorization` header) and `:context` (a `Tools.Context` holds the
agent's `tool_context` data) to `@sensitive_keys` (Convention 10).

- [ ] **Step 3b: A2A**

`agent_tool.ex` (add `alias Normandy.Options`):

```elixir
  @new_opts_schema NimbleOptions.new!(
                     skill_id: [
                       type: :string,
                       doc: "The skill to expose (default: general access to the agent)."
                     ],
                     auth_token: [type: :string, doc: "A bearer token for the remote agent."],
                     transport_opts: [
                       type: :keyword_list,
                       default: [],
                       doc:
                         "Options for the A2A transport. Its `:headers` (`[{name, value}]`) " <>
                           "are sent on every request; with OpenTelemetry loaded and a span " <>
                           "active, W3C `traceparent`/`tracestate` headers are added beside them " <>
                           "(a same-named header you set is kept)."
                     ]
                   )

  @doc false
  def __opts_schema__(:new), do: @new_opts_schema
```

No `:timeout` key: Task 3.4c removed the struct's `:timeout` field and made `new/3` raise on
`:timeout` with its own message (a registration option in 2.0). That check is already done and
stays; it runs before the schema so a caller passing `:timeout` keeps the message that tells
them where it went instead of "unknown option :timeout".

`new/3`'s doc replaces its `## Options` list with the generated docs (keep 3.4c's paragraph
about the registration timeout); body:

```elixir
  def new(endpoint, agent_card, opts \\ []) do
    if Keyword.has_key?(opts, :timeout) do
      raise ArgumentError,
            "Normandy.A2A.AgentTool.new/3: :timeout is a registration option in 2.0; pass it " <>
              "to BaseAgent.register_tool/3 or Normandy.Tools.Toolset.register/3"
    end

    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 3})

    %__MODULE__{
      endpoint: endpoint,
      agent_card: agent_card,
      skill_id: Keyword.get(opts, :skill_id),
      auth_token: Keyword.get(opts, :auth_token),
      transport_opts: Keyword.fetch!(opts, :transport_opts)
    }
  end
```

(The `if` is Task 3.4c's check, unchanged.)

`registry.ex` (add `alias Normandy.Options`):

```elixir
  # AgentTool.new/3's options except :skill_id, which from_agent_card/3 sets per skill.
  @card_opts Keyword.delete(AgentTool.__opts_schema__(:new).schema, :skill_id)
  @from_agent_card_opts_schema NimbleOptions.new!(@card_opts)
  # Task 3.4c: discover_and_register/3's :timeout is each tool's registration timeout.
  @discover_and_register_opts_schema NimbleOptions.new!(
                                       @card_opts ++
                                         [
                                           timeout: [
                                             type: :pos_integer,
                                             default: 60_000,
                                             doc:
                                               "Each tool's registration timeout, in ms " <>
                                                 "(`Normandy.Tools.Toolset.register/3`; " <>
                                                 "60_000 as in 1.x)."
                                           ]
                                         ]
                                     )
```

Each `@doc` replaces its `## Options` list with the generated docs of its own schema (add an
`## Options` heading to `from_agent_card/3`'s doc). Bodies:

```elixir
  def discover_and_register(%Toolset{} = toolset, base_url, opts \\ []) do
    opts =
      Options.validate!(
        opts,
        @discover_and_register_opts_schema,
        {__MODULE__, :discover_and_register, 3}
      )

    case Client.discover(base_url, Keyword.fetch!(opts, :transport_opts)) do
      {:ok, agent_card} ->
        endpoint = derive_endpoint(base_url, agent_card)
        tools = from_agent_card(agent_card, endpoint, Keyword.delete(opts, :timeout))

        register_all(tools, toolset, timeout: Keyword.fetch!(opts, :timeout))

      {:error, _reason} = error ->
        error
    end
  end

  def from_agent_card(agent_card, endpoint, opts \\ []) do
    tool_opts =
      Options.validate!(opts, @from_agent_card_opts_schema, {__MODULE__, :from_agent_card, 3})

    case agent_card.skills do
      [] ->
        [AgentTool.new(endpoint, agent_card, tool_opts)]

      skills ->
        Enum.map(skills, fn skill ->
          AgentTool.new(endpoint, agent_card, Keyword.put(tool_opts, :skill_id, skill.id))
        end)
    end
  end
```

(`%Toolset{} = toolset` is whatever head Task 3.4a gave the function, and `register_all/3` is
Task 3.4c's; only the body changes. Task 3.4c's `Keyword.get(opts, :timeout, 60_000)` and
`Keyword.take(opts, [:auth_token, :transport_opts])` are replaced by the schemas above.)

`server.ex` (add `alias Normandy.Options`):

```elixir
  @build_agent_card_opts_schema NimbleOptions.new!(
                                  name: [type: :string, required: true, doc: "The agent's name."],
                                  description: [
                                    type: :string,
                                    required: true,
                                    doc: "What the agent does."
                                  ],
                                  url: [type: :string, doc: "The A2A endpoint URL."],
                                  version: [type: :string, doc: "The agent's version."],
                                  provider_url: [type: :string, doc: "The provider's URL."],
                                  provider_org: [
                                    type: :string,
                                    doc: "The provider's organization (used with `:provider_url`)."
                                  ],
                                  expose_tools: [
                                    type: {:or, [{:list, :string}, {:in, [:all]}]},
                                    default: [],
                                    doc:
                                      "Tool names to list as skills in the public card, or " <>
                                        "`:all`. By default none, so an internal or privileged " <>
                                        "tool is not advertised unless you choose to."
                                  ]
                                )
```

The doc's `## Required Options` and `## Optional` lists become one generated `## Options`. First
lines of the body:

```elixir
    opts =
      Options.validate!(opts, @build_agent_card_opts_schema, {__MODULE__, :build_agent_card, 2})

    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
```

and the last line's `Keyword.get(opts, :expose_tools, [])` → `Keyword.fetch!(opts, :expose_tools)`.

- [ ] **Step 3c: MCP and `BaseAgent.register_mcp_tools/4`**

`tool_wrapper.ex` (add `alias Normandy.Options`):

```elixir
  @new_opts_schema NimbleOptions.new!(
                     prefix: [
                       type: :string,
                       doc: "Namespaces the tool's name as `prefix__name`."
                     ]
                   )
```

`new/4`'s doc: replace the `opts` bullet under `## Parameters` with "`opts` - see Options" and
add `## Options\n\n#{Options.docs(@new_opts_schema)}`. First body line
`opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 4})`.

`mcp/registry.ex` (add `alias Normandy.Options`): `@opts_schema` with the same `prefix:` entry as
`ToolWrapper` (one attribute shared by both functions, Convention 1), plus
`@doc false def __opts_schema__(:discover_and_register), do: @opts_schema`. Both `@doc`s use the
generated docs; first body lines
`opts = Options.validate!(opts, @opts_schema, {__MODULE__, :discover_and_register, 4})` and
`opts = Options.validate!(opts, @opts_schema, {__MODULE__, :wrap_tools, 4})`.

`base_agent.ex` `register_mcp_tools/4`, first body line:

```elixir
    opts =
      Options.validate!(
        opts,
        Normandy.MCP.Registry.__opts_schema__(:discover_and_register),
        {__MODULE__, :register_mcp_tools, 4}
      )
```

and its `@doc` gets `## Options\n\nThe options of `Normandy.MCP.Registry.discover_and_register/4`.`

- [ ] **Step 3d: `Context.Summarizer`**

Add `alias Normandy.Options`. Schemas:

```elixir
  @summary_opts [
    prompt: [
      type: :string,
      doc: "The summarization prompt (default: the built-in prompt, which keeps stated facts)."
    ],
    model: [type: :string, doc: "The model to summarize with (default: the agent's model)."],
    max_tokens: [type: :pos_integer, default: 500, doc: "Maximum tokens for the summary."]
  ]

  @summarize_messages_opts_schema NimbleOptions.new!(@summary_opts)
  @compress_conversation_opts_schema NimbleOptions.new!(
                                       [
                                         keep_recent: [
                                           type: :non_neg_integer,
                                           default: 10,
                                           doc:
                                             "Recent messages kept as they are. The kept " <>
                                               "messages start at a user message: the oldest " <>
                                               "one among the last `:keep_recent`, or the " <>
                                               "newest one when none is."
                                         ],
                                         summary_role: [
                                           type: {:in, ["user", "assistant"]},
                                           default: "user",
                                           doc:
                                             "The summary message's role. Not \"system\": the " <>
                                               "adapter sends the agent's own system prompt and " <>
                                               "refuses a second one."
                                         ]
                                       ] ++ @summary_opts
                                     )
  @estimate_savings_opts_schema NimbleOptions.new!(
                                  summary_tokens: [
                                    type: :non_neg_integer,
                                    default: 500,
                                    doc: "The summary's expected size in tokens."
                                  ]
                                )
```

The three `@doc`s use generated docs (`compress_conversation/3`'s `:max_summary_tokens` bullet
goes: it was never read; the summary size is `:max_tokens`, as in `summarize_messages/4`;
`estimate_savings/2` gains an `## Options` heading). Bodies:
- `summarize_messages/4`: first line
  `opts = Options.validate!(opts, @summarize_messages_opts_schema, {__MODULE__, :summarize_messages, 4})`;
  `Keyword.get(opts, :max_tokens, 500)` → `Keyword.fetch!(opts, :max_tokens)`; `:prompt` keeps
  `Keyword.get(opts, :prompt, @default_summarization_prompt)`.
- `compress_conversation/3`: first line
  `opts = Options.validate!(opts, @compress_conversation_opts_schema, {__MODULE__, :compress_conversation, 3})`;
  `Keyword.get(opts, :keep_recent, 10)` → `Keyword.fetch!(opts, :keep_recent)`;
  `Keyword.get(opts, :summary_role, "user")` → `Keyword.fetch!(opts, :summary_role)`.
- `do_compress_conversation/7` (second clause): `summarize_messages(client, agent, old_messages, opts)`
  → `summarize_messages(client, agent, old_messages, Keyword.take(opts, [:prompt, :model, :max_tokens]))`.
  Without it `summarize_messages/4` would reject `:keep_recent` and `:summary_role`; the
  `take` drops nothing a caller wrote, because `opts` is already validated.
- `estimate_savings/2`: first line
  `opts = Options.validate!(opts, @estimate_savings_opts_schema, {__MODULE__, :estimate_savings, 2})`;
  `Keyword.get(opts, :summary_tokens, 500)` → `Keyword.fetch!(opts, :summary_tokens)`.

- [ ] **Step 3e: `Context.WindowManager.new/1`**

Add `alias Normandy.Options`. Schema (no `required: true` on `:max_tokens`, so the absent case
keeps its explanation):

```elixir
  @new_opts_schema NimbleOptions.new!(
                     max_tokens: [
                       type: :pos_integer,
                       doc:
                         "**Required.** The model's context window in tokens. Inside an agent the " <>
                           "compactor passes the window resolved through the configured " <>
                           "`Normandy.Behaviours.ModelCatalog`; standalone, take it from " <>
                           "`Claudio.Models.get/2` (`\"max_input_tokens\"`)."
                     ],
                     reserved_tokens: [
                       type: :non_neg_integer,
                       default: 4096,
                       doc: "Tokens kept free for the response."
                     ],
                     strategy: [
                       type: {:in, [:oldest_first, :sliding_window, :summarize]},
                       default: :oldest_first,
                       doc: "The truncation strategy."
                     ]
                   )
```

`new/1`:

```elixir
  def new(opts \\ []) when is_list(opts) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})

    unless Keyword.has_key?(opts, :max_tokens) do
      raise ArgumentError,
            "Normandy.Context.WindowManager.new/1: requires :max_tokens (the model's context " <>
              "window in tokens); Normandy no longer ships a static model table. Use the " <>
              "agent's resolved window or Claudio.Models.get/2 \"max_input_tokens\"."
    end

    %__MODULE__{
      max_tokens: Keyword.fetch!(opts, :max_tokens),
      reserved_tokens: Keyword.fetch!(opts, :reserved_tokens),
      strategy: Keyword.fetch!(opts, :strategy)
    }
  end
```

`test/context/window_manager_test.exs:17-21` (`positive integer`) still matches the NimbleOptions
message; lines 9-13 (`requires :max_tokens`) still match the kept message.

- [ ] **Step 3f: The `WindowManager` compactor's opts are checked at build time**

With `WindowManager.new/1` strict, a key it doesn't know reaching it from the compactor opts
would raise mid-turn. In `lib/normandy/behaviours/compactor/window_manager.ex` add
`alias Normandy.Options` and:

```elixir
  @opts_schema NimbleOptions.new!(
                 context_window: [
                   type: :pos_integer,
                   doc: "Pins the context window instead of asking the model catalog."
                 ],
                 reserved_tokens: [
                   type: :non_neg_integer,
                   doc:
                     "Tokens kept free for the answer (default: the agent's `max_tokens`). " <>
                       "Must be smaller than the context window."
                 ],
                 strategy: [
                   type: {:in, [:oldest_first, :sliding_window, :summarize]},
                   doc: "The truncation strategy (default `:oldest_first`)."
                 ]
               )

  @doc false
  # Called by BaseAgent.validate_compaction_config!/1, i.e. at BaseAgent.init/1 and at
  # template rebuild, so a typo surfaces where the config is made, not mid-turn.
  @spec validate_opts!(keyword()) :: keyword()
  def validate_opts!(opts),
    do: Options.validate!(opts, @opts_schema, {Normandy.Agents.BaseAgent, :init, 1})
```

In `checked_manager/2`, replace the final
`WM.new([max_tokens: window, reserved_tokens: reserved] ++ Keyword.drop(opts, [:reserved_tokens]))`
(Task 3.2a's form; `mix format` may have wrapped it) with an explicit list, so only
`WindowManager.new/1`'s keys reach it whatever the compactor opts hold:

```elixir
    WM.new(
      max_tokens: window,
      reserved_tokens: reserved,
      strategy: Keyword.get(opts, :strategy, :oldest_first)
    )
```

(`window` and `reserved` are the locals `checked_manager/2` already computes.) In
`BaseAgent.validate_compaction_config!/1`, right after the `:max_tokens` rename check Task 3.2a
added (the `if compactor == Normandy.Behaviours.Compactor.WindowManager and
Keyword.has_key?(compactor_opts, :max_tokens) do raise ... end` block, which must keep firing
first so 3.2a's test "the 1.x :max_tokens pin on Compactor.WindowManager raises at init, naming
:context_window" still sees its own message rather than "unknown option :max_tokens"), add:

```elixir
    if compactor == Normandy.Behaviours.Compactor.WindowManager,
      do: Normandy.Behaviours.Compactor.WindowManager.validate_opts!(compactor_opts)
```

Update the moduledoc sentence "`opts` flow straight to `WindowManager.new/1` (...)" to "`opts`:
`:context_window`, `:reserved_tokens`, `:strategy`; any other key raises `ArgumentError` at
`BaseAgent.init/1`."

- [ ] **Step 3g: `Tools.Executor` (already done by Task 3.4c)**

Nothing to change. Task 3.4c rewrote `lib/normandy/tools/executor.ex`: `execute_tool/2` and
`execute_tool_classified/2` validate `:context` (required) and `:timeout` (default
`Executor.default_timeout/0`) through `Normandy.Options` with the `Module.fun/arity: ` prefix,
and `execute/3`, `execute_parallel/3`, `execute_sequential/3` and `:max_retries` are gone.
`test/tools/executor_test.exs` was rewritten there. Check:

```bash
grep -n "Options.validate!" lib/normandy/tools/executor.ex
grep -n "def execute(\|def execute_parallel\|def execute_sequential\|max_retries" lib/normandy/tools/executor.ex
```

Expected: two `Options.validate!` lines (`execute_tool/2`, `execute_tool_classified/2`); the
second grep prints nothing. Both functions are rows of Task 3.7d's coverage test.

- [ ] **Step 3h: `StatefulContext`, `AgentMessage`, `Pattern`, `AgentMemory.add_message/4`**

`stateful_context.ex` (add `alias Normandy.Options`):

```elixir
  @start_link_opts_schema NimbleOptions.new!(
                            name: [type: :any, doc: "A `t:GenServer.name/0` for the context."],
                            notify_on_change: [
                              type: :boolean,
                              default: true,
                              doc: "Send subscribers a message on every change."
                            ]
                          )
```

`start_link/1`: first line `opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})`,
the rest as today; `init/1`: `Keyword.get(opts, :notify_on_change, true)` →
`Keyword.fetch!(opts, :notify_on_change)`. Generated docs replace the `## Options` list.

`agent_message.ex` (add `alias Normandy.Options`):

```elixir
  @new_opts_schema NimbleOptions.new!(
                     from: [type: {:or, [:string, :atom]}, required: true, doc: "The sender's id."],
                     to: [type: {:or, [:string, :atom]}, required: true, doc: "The recipient's id."],
                     type: [
                       type: {:or, [:atom, :string]},
                       default: :request,
                       doc: "`:request`, `:response`, `:broadcast` or `:error` (stored as a string)."
                     ],
                     payload: [type: :any, default: %{}, doc: "The message content."],
                     metadata: [
                       type: {:custom, Normandy.Options, :plain_map, []},
                       default: %{},
                       doc: "Extra data about the message."
                     ]
                   )
```

`new/1`:

```elixir
  def new(opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})

    %__MODULE__{
      id: UUID.uuid4(),
      from: Keyword.fetch!(opts, :from),
      to: Keyword.fetch!(opts, :to),
      type: opts |> Keyword.fetch!(:type) |> to_string(),
      payload: Keyword.fetch!(opts, :payload),
      metadata: Keyword.fetch!(opts, :metadata),
      timestamp: :os.system_time(:second)
    }
  end
```

`pattern.ex` (add `alias Normandy.Options`):

```elixir
  @default_opts_schema NimbleOptions.new!(
                         default: [type: :any, doc: "Returned when the result does not match."]
                       )
```

Replace the bodiless head and two clauses of `ok!/2` with one clause (the `@doc` keeps its
doctests and gets `## Options\n\n#{Options.docs(@default_opts_schema)}` instead of its
`## Options` bullet):

```elixir
  def ok!(result, opts \\ []) do
    opts = Options.validate!(opts, @default_opts_schema, {__MODULE__, :ok!, 2})

    case result do
      {:ok, value} -> value
      _other -> Keyword.get(opts, :default)
    end
  end
```

and `error!/2` the same way with `{:error, reason} -> reason` and `{__MODULE__, :error!, 2}`
(the two functions share `@default_opts_schema`).

`agent_memory.ex` (add `alias Normandy.Options`):

```elixir
  @add_message_opts_schema NimbleOptions.new!(
                             turn_id: [
                               type: {:or, [:string, nil]},
                               doc: "Store the message under this turn instead of the current one."
                             ],
                             id: [
                               type: {:or, [:string, nil]},
                               doc:
                                 "The entry's id (default: a new UUID). It must not already be " <>
                                   "in the memory."
                             ]
                           )
```

In `add_message/4` replace `opts = Keyword.validate!(opts, [:turn_id, :id])` with
`opts = Options.validate!(opts, @add_message_opts_schema, {__MODULE__, :add_message, 4})`, and
append `## Options\n\n#{Options.docs(@add_message_opts_schema)}` to its `@doc` (the prose about
`turn_id:`/`id:` stays).

- [ ] **Step 4: Run the new tests**

Run: `mix test test/options/integration_options_test.exs test/a2a test/mcp test/context test/tools test/coordination test/components test/behaviours/compactor_test.exs`
Expected: PASS, ` 0 failures`.

- [ ] **Step 5: MIGRATING**

Append to Task 3.7a's section (§30):

```markdown
- `Context.Summarizer.compress_conversation/3` documented `:max_summary_tokens` but never read
  it; the summary size is `:max_tokens`, as in `summarize_messages/4`, and
  `:max_summary_tokens` now raises. `:summary_role` must be `"user"` or `"assistant"`.
- `A2A.Registry.from_agent_card/3` used to drop keys it did not use (including `:timeout`,
  which only `discover_and_register/3` reads, as the registration timeout); they now raise.
- `Context.WindowManager.new/1`: `:strategy` must be `:oldest_first`, `:sliding_window` or
  `:summarize`, and `:reserved_tokens` a non-negative integer. A
  `Compactor.WindowManager` compactor's opts (`:context_window`, `:reserved_tokens`,
  `:strategy`) are checked at `BaseAgent.init/1`.
- `AgentMemory.add_message/4`'s message for an unknown option now names the function.
- `Coordination.Pattern.ok!/2` and `error!/2` check their options on every call, including
  when the result matches.
```

- [ ] **Step 6: Format and run the suite**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`. Callers fixed under Convention 8 are named in the commit body.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/options.ex lib/normandy/a2a/agent_tool.ex lib/normandy/a2a/registry.ex \
  lib/normandy/a2a/server.ex lib/normandy/mcp/tool_wrapper.ex lib/normandy/mcp/registry.ex \
  lib/normandy/agents/base_agent.ex lib/normandy/context/summarizer.ex \
  lib/normandy/context/window_manager.ex lib/normandy/behaviours/compactor/window_manager.ex \
  lib/normandy/coordination/stateful_context.ex \
  lib/normandy/coordination/agent_message.ex lib/normandy/coordination/pattern.ex \
  lib/normandy/components/agent_memory.ex MIGRATING-2.0.md \
  test/options/integration_options_test.exs
git commit -m "feat: reject unknown options at the A2A, MCP and context entry points"
```

---

### Task 3.7d: Options at the store, registry and cluster constructors; the coverage test; one timeouts table

**Files:**
- Modify: `lib/normandy/behaviours/session_registry/native.ex` (`start_link/1` 9-14, `new/1` 16-22)
- Modify: `lib/normandy/behaviours/session_registry/horde.ex` (`start_link/1` 14-19, `new/1` 21-37)
- Modify: `lib/normandy/behaviours/session_registry/redis.ex` (`new/1` 44-63, `start_link/1` 64-68, `init/1` 70-86)
- Modify: `lib/normandy/behaviours/session_store/in_memory.ex` (`start_link/1`, `new/1`, 15-27)
- Modify: `lib/normandy/behaviours/session_store/ets.ex` (`start_link/1`, `new/1` 22-32, `init/1` 72-75)
- Modify: `lib/normandy/behaviours/session_store/mnesia.ex` (`new/1` 35-43, `create_tables/1` 45-70)
- Modify: `lib/normandy/behaviours/session_store/redis.ex` (`new/1` 31-55)
- Modify: `lib/normandy/behaviours/memory_store/in_memory.ex` (`new/1` 11-16)
- Modify: `lib/normandy/behaviours/memory_store/ets.ex` (`new/1` 13-18)
- Modify: `lib/normandy/behaviours/memory_store/mnesia.ex` (`new/1` 21-27, `create_tables/1` 29-50)
- Modify: `lib/normandy/behaviours/memory_store/redis.ex` (`new/1` 101-113)
- Modify: `lib/normandy/behaviours/agent_template.ex` (`Catalog.start_link/1` 33-42)
- Modify: `lib/normandy/cluster.ex` (`child_specs/1` 42-58, `setup_mnesia_store!/1` 60-66,
  `redis_child_specs/1` 68-92, `libcluster_specs/2` ~120)
- Modify: `lib/normandy/options.ex` (moduledoc: `## Timeouts`; `:url`, `:redix`, `:templates` join `@sensitive_keys`)
- Modify: `MIGRATING-2.0.md` (Task 3.7a's section)
- Create: `test/options/store_options_test.exs`, `test/options_coverage_test.exs`

**Interfaces:**
- Consumes: everything Tasks 3.1–3.7c validate (the coverage test lists them).
- Produces: `SessionStore.Mnesia.__opts_schema__(:create_tables)` (`@doc false`, used by
  `Cluster.setup_mnesia_store!/1`). Validated: `SessionRegistry.Native.start_link/1`, `new/1`;
  `SessionRegistry.Horde.start_link/1`, `new/1`; `SessionRegistry.Redis.new/1`, `start_link/1`;
  `SessionStore.InMemory.start_link/1`, `new/1`; `SessionStore.ETS.start_link/1`, `new/1`;
  `SessionStore.Mnesia.new/1`, `create_tables/1`; `SessionStore.Redis.new/1`;
  `MemoryStore.InMemory.new/1`, `MemoryStore.ETS.new/1`, `MemoryStore.Mnesia.new/1`,
  `create_tables/1`, `MemoryStore.Redis.new/1`; `AgentTemplate.Catalog.start_link/1`;
  `Cluster.child_specs/1`, `redis_child_specs/1`, `setup_mnesia_store!/1`. Plus
  `test/options_coverage_test.exs` (Ruling 6).

- [ ] **Step 0: Re-inventory**

```bash
grep -rn "def start_link\|def new\|def create_tables\|def child_specs\|def redis_child_specs\|def setup_mnesia_store!\|Keyword\.\(get\|get_lazy\|fetch\|fetch!\|pop\)(opts" \
  lib/normandy/behaviours/session_registry lib/normandy/behaviours/session_store \
  lib/normandy/behaviours/memory_store lib/normandy/behaviours/agent_template.ex lib/normandy/cluster.ex
```

Expected keys (as of `95dc149`): Native/Horde registries `:name`; Redis registry `:name :url
:namespace` (`new`), `:name :conn :url :namespace :ttl_ms` (`start_link`/`init`); InMemory
session store none (`_opts`); ETS session store `:name`; Mnesia session store `:entries
:sessions :copies :nodes :wait_timeout`; Redis session store `:url :wait :namespace`; InMemory
and ETS memory stores none; Mnesia memory store `:table :copies :nodes :wait_timeout`; Redis
memory store `:url :prefix`; Catalog `:name :templates`; Cluster `:registry :supervisor :store
:template_provider :topologies :redix :namespace`. The Postgres stores' `new/0` take no options.
Apply Convention 9 to any difference.

- [ ] **Step 1: Write the failing table test**

Create `test/options/store_options_test.exs`:

```elixir
defmodule Normandy.Options.StoreOptionsTest do
  use ExUnit.Case, async: true

  import Normandy.Test.OptionsAssertions

  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.MemoryStore.ETS, as: EtsMem
  alias Normandy.Behaviours.MemoryStore.InMemory, as: InMemoryMem
  alias Normandy.Behaviours.MemoryStore.Mnesia, as: MnesiaMem
  alias Normandy.Behaviours.MemoryStore.Redis, as: RedisMem
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HordeReg
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionRegistry.Redis, as: RedisReg
  alias Normandy.Behaviours.SessionStore.ETS, as: EtsStore
  alias Normandy.Behaviours.SessionStore.InMemory, as: InMemoryStore
  alias Normandy.Behaviours.SessionStore.Mnesia, as: MnesiaStore
  alias Normandy.Behaviours.SessionStore.Redis, as: RedisStore
  alias Normandy.Cluster

  # Each call raises before it starts a process, connects to Redis or touches Mnesia.
  @cases [
    {:nam, {Native, :start_link, [[nam: :x]]}},
    {:nam, {Native, :new, [[nam: :x]]}},
    {:nam, {HordeReg, :start_link, [[nam: :x]]}},
    {:nam, {HordeReg, :new, [[nam: :x]]}},
    {:namespce, {RedisReg, :new, [[namespce: "n"]]}},
    {:ttl, {RedisReg, :start_link, [[ttl: 1]]}},
    {:name, {InMemoryStore, :start_link, [[name: :x]]}},
    {:name, {InMemoryStore, :new, [[name: :x]]}},
    {:nam, {EtsStore, :start_link, [[nam: :x]]}},
    {:nam, {EtsStore, :new, [[nam: :x]]}},
    {:entires, {MnesiaStore, :new, [[entires: :x]]}},
    {:copys, {MnesiaStore, :create_tables, [[copys: :ram_copies]]}},
    {:wiat, {RedisStore, :new, [[wiat: {0, 0}]]}},
    {:name, {InMemoryMem, :new, [[name: :x]]}},
    {:name, {EtsMem, :new, [[name: :x]]}},
    {:tabel, {MnesiaMem, :new, [[tabel: :x]]}},
    {:tabel, {MnesiaMem, :create_tables, [[tabel: :x]]}},
    {:prefx, {RedisMem, :new, [[prefx: "p"]]}},
    {:templats, {Catalog, :start_link, [[templats: %{}]]}},
    {:topologys, {Cluster, :child_specs, [[topologys: []]]}},
    {:namespce, {Cluster, :redis_child_specs, [[namespce: "n"]]}},
    {:copys, {Cluster, :setup_mnesia_store!, [[copys: :ram_copies]]}}
  ]

  for {key, {mod, fun, args}} <- @cases do
    test "#{inspect(mod)}.#{fun}/#{length(args)} rejects #{inspect(key)}" do
      assert_rejects(unquote(key), unquote(mod), unquote(fun), unquote(Macro.escape(args)))
    end
  end

  test "every entry point documents its options" do
    for {_key, {mod, fun, args}} <- @cases, do: assert_documents_options(mod, fun, length(args))
  end

  test "SessionRegistry.Redis.start_link/1 needs :conn or :url" do
    error =
      assert_raise ArgumentError, fn -> RedisReg.start_link(name: :reg_x, namespace: "n") end

    assert error.message ==
             "Normandy.Behaviours.SessionRegistry.Redis.start_link/1: requires :conn (a Redix " <>
               "connection) or :url"
  end

  test "a bad :redix value is rejected without echoing it" do
    error =
      assert_raise ArgumentError, fn ->
        Cluster.redis_child_specs(
          redix: %{password: "sk-secret"},
          namespace: "n",
          registry: :r,
          supervisor: :s
        )
      end

    assert error.message =~ "Normandy.Cluster.redis_child_specs/1: "
    assert error.message =~ ":redix"
    refute error.message =~ "sk-secret"
  end

  test "Cluster.redis_child_specs/1 names a :redix list without :name" do
    error =
      assert_raise ArgumentError, fn ->
        Cluster.redis_child_specs(redix: [host: "h"], namespace: "n", registry: :r, supervisor: :s)
      end

    assert error.message ==
             "Normandy.Cluster.redis_child_specs/1: :redix must include :name, the Redix " <>
               "connection's registered name"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/options/store_options_test.exs`
Expected: FAIL. Rows report "nothing was raised" or another exception (`KeyError` in
`Cluster` and the Redis registry's `start_link/1`; the `_opts`-ignoring constructors start a
process and return it); the docs test fails on the first function without an `## Options` section.

- [ ] **Step 3: Sensitive keys**

In `lib/normandy/options.ex`, add `:url` (a Redis URL can hold a password), `:redix` (Redix
connection options can) and `:templates` (template supplements hold clients) to
`@sensitive_keys` (Convention 10).

- [ ] **Step 3a: Session registries**

`native.ex` (add `alias Normandy.Options`):

```elixir
  @start_link_opts_schema NimbleOptions.new!(
                            name: [
                              type: :atom,
                              default: __MODULE__,
                              doc: "The registry's name, which is also its handle."
                            ]
                          )
  @new_opts_schema NimbleOptions.new!(
                     name: [type: :atom, doc: "The registry's name (default: a unique one)."]
                   )

  @doc """
  Starts a unique `Registry`.

  ## Options

  #{Options.docs(@start_link_opts_schema)}
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})
    Registry.start_link(keys: :unique, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Starts a registry and returns its name as the handle.

  ## Options

  #{Options.docs(@new_opts_schema)}
  """
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})
    name = Keyword.get_lazy(opts, :name, fn -> unique_name() end)
    {:ok, _pid} = start_link(name: name)
    name
  end
```

`horde.ex`: the same two schemas and the same first lines in `start_link/1` and `new/1`
(`Horde.Registry.start_link(name: Keyword.fetch!(opts, :name), keys: :unique, members: :auto)`);
`new/1` keeps its `await_ready/1` gate and its docs paragraph, with the generated `## Options`
appended.

`redis.ex` (add `alias Normandy.Options`):

```elixir
    @new_opts_schema NimbleOptions.new!(
                       name: [type: :atom, doc: "The owner's name (default: a unique one)."],
                       url: [
                         type: :string,
                         doc: "The Redis URL (default: `config :normandy, :redis_url`)."
                       ],
                       namespace: [type: :string, doc: "The key namespace (default: a unique one)."]
                     )

    @start_link_opts_schema NimbleOptions.new!(
                              name: [
                                type: :atom,
                                required: true,
                                doc: "The owner's registered name, which is also the handle."
                              ],
                              conn: [type: :any, doc: "A started Redix connection (pid or name)."],
                              url: [
                                type: :string,
                                doc: "A Redis URL to connect to when `:conn` is not given."
                              ],
                              namespace: [type: :string, required: true, doc: "The key namespace."],
                              ttl_ms: [
                                type: :pos_integer,
                                default: @default_ttl_ms,
                                doc:
                                  "Registration TTL in ms, refreshed every `ttl_ms / 2`; a dead " <>
                                    "node's keys lapse after it."
                              ]
                            )
```

`new/1` starts with `opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})`
(its `Keyword.get_lazy`/`Keyword.get` reads stay: their defaults are computed). `start_link/1`:

```elixir
    def start_link(opts) do
      opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})

      unless Keyword.has_key?(opts, :conn) or Keyword.has_key?(opts, :url) do
        raise ArgumentError,
              "Normandy.Behaviours.SessionRegistry.Redis.start_link/1: requires :conn (a Redix " <>
                "connection) or :url"
      end

      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end
```

In `init/1`, `Keyword.get(opts, :ttl_ms, @default_ttl_ms)` → `Keyword.fetch!(opts, :ttl_ms)`.
Both functions get `@doc`s with generated `## Options` (`new/1` keeps its one-line summary).

- [ ] **Step 3b: Session stores**

`in_memory.ex` (add `alias Normandy.Options`):

```elixir
  @no_opts_schema NimbleOptions.new!([])

  @doc """
  Starts a store.

  ## Options

  None; any key raises `ArgumentError`.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Options.validate!(opts, @no_opts_schema, {__MODULE__, :start_link, 1})
    Agent.start_link(fn -> %{sessions: %{}, turn_states: %{}, config_templates: %{}} end)
  end

  @doc """
  Starts a fresh store and returns its handle (a pid).

  ## Options

  None; any key raises `ArgumentError`.
  """
  @spec new(keyword()) :: pid()
  def new(opts \\ []) do
    Options.validate!(opts, @no_opts_schema, {__MODULE__, :new, 1})
    {:ok, pid} = start_link()
    pid
  end
```

`ets.ex` (add `alias Normandy.Options`):

```elixir
  @opts_schema NimbleOptions.new!(
                 name: [
                   type: :atom,
                   default: :normandy_session_store,
                   doc: "The ETS table's name (a label: the table is not a named table)."
                 ]
               )
```

`start_link/1` becomes `def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, Options.validate!(opts, @opts_schema, {__MODULE__, :start_link, 1}))`
written as a multi-line function; `new/1` starts with
`opts = Options.validate!(opts, @opts_schema, {__MODULE__, :new, 1})`; `init/1`'s
`Keyword.get(opts, :name, :normandy_session_store)` → `Keyword.fetch!(opts, :name)`. Both get
`@doc`s with `## Options\n\n#{Options.docs(@opts_schema)}`.

`mnesia.ex` (add `alias Normandy.Options`):

```elixir
  @new_opts_schema NimbleOptions.new!(
                     entries: [type: :atom, doc: "The entries table (default: a unique name)."],
                     sessions: [type: :atom, doc: "The sessions table (default: a unique name)."]
                   )

  @create_tables_opts_schema NimbleOptions.new!(
                               entries: [type: :atom, required: true, doc: "The entries table."],
                               sessions: [type: :atom, required: true, doc: "The sessions table."],
                               copies: [
                                 type: {:in, [:disc_copies, :ram_copies]},
                                 default: :disc_copies,
                                 doc:
                                   "`:disc_copies` converts this node's schema to disc first so " <>
                                     "the tables survive a restart (needs a writable Mnesia dir)."
                               ],
                               nodes: [
                                 type: {:list, :atom},
                                 doc: "The nodes holding copies (default: `[node()]`)."
                               ],
                               wait_timeout: [
                                 type: :timeout,
                                 default: 30_000,
                                 doc: "How long to wait for the tables to load, in ms; raises on timeout."
                               ]
                             )

  @doc false
  def __opts_schema__(:create_tables), do: @create_tables_opts_schema
```

`new/1` and `create_tables/1` start with their `Options.validate!/3` line; `create_tables/1`'s
`Keyword.get(opts, :copies, :disc_copies)` → `Keyword.fetch!(opts, :copies)` and
`Keyword.get(opts, :wait_timeout, 30_000)` → `Keyword.fetch!(opts, :wait_timeout)`; `:nodes`
keeps `Keyword.get(opts, :nodes, [node()])`. Their `@doc`s: `new/1` gets an `## Options`
section; `create_tables/1`'s "Opts: ..." sentence is replaced by the generated `## Options`.

`redis.ex` (add `alias Normandy.Options`):

```elixir
    @new_opts_schema NimbleOptions.new!(
                       url: [
                         type: :string,
                         doc: "The Redis URL (default: `config :normandy, :redis_url`)."
                       ],
                       wait: [
                         type: {:tuple, [:non_neg_integer, :non_neg_integer]},
                         doc:
                           "`{replicas, timeout_ms}` for `WAIT` after each write (default: " <>
                             "`config :normandy, :redis_wait`). With replicas, `timeout_ms` " <>
                             "must be positive."
                       ],
                       namespace: [type: :string, doc: "The key namespace (default: a unique one)."]
                     )
```

`new/1` starts with `opts = Options.validate!(opts, @new_opts_schema, {__MODULE__, :new, 1})`;
its `check_wait!/2` calls stay (they check `timeout_ms > 0` when replicas are asked for, which
the type cannot express). Its `@doc` gets the generated `## Options`.

- [ ] **Step 3c: Memory stores and the template catalog**

`memory_store/in_memory.ex` and `memory_store/ets.ex`: add `alias Normandy.Options`,
`@no_opts_schema NimbleOptions.new!([])`, and as `new/1`'s first line
`Options.validate!(opts, @no_opts_schema, {__MODULE__, :new, 1})` (rename the `_opts` parameter
to `opts`; ETS then calls `GenServer.start_link(__MODULE__, [])`). Each `@doc` gets
`## Options\n\nNone; any key raises `ArgumentError`.`

`memory_store/mnesia.ex` (add `alias Normandy.Options`):

```elixir
  @new_opts_schema NimbleOptions.new!(
                     table: [type: :atom, doc: "The table (default: a unique name)."]
                   )

  @create_tables_opts_schema NimbleOptions.new!(
                               table: [
                                 type: :atom,
                                 default: :normandy_memory_documents,
                                 doc: "The table."
                               ],
                               copies: [
                                 type: {:in, [:disc_copies, :ram_copies]},
                                 default: :disc_copies,
                                 doc: "Disc or RAM copies."
                               ],
                               nodes: [
                                 type: {:list, :atom},
                                 doc: "The nodes holding copies (default: `[node()]`)."
                               ],
                               wait_timeout: [
                                 type: :timeout,
                                 default: 30_000,
                                 doc: "How long to wait for the table to load, in ms."
                               ]
                             )
```

Same pattern as the session store: validate first; `:table`, `:copies`, `:wait_timeout` in
`create_tables/1` → `Keyword.fetch!/2`; `:nodes` and `new/1`'s `:table` keep their computed
defaults; generated `## Options` in both docs.

`memory_store/redis.ex`: `@new_opts_schema` with `url:` (as the session store's) and
`prefix: [type: :string, doc: "The key prefix (default: a unique one)."]`; validate first;
generated docs.

`agent_template.ex`, inside `defmodule Catalog` (add `alias Normandy.Options`):

```elixir
    @start_link_opts_schema NimbleOptions.new!(
                              name: [type: :any, doc: "A `t:GenServer.name/0` for the catalog."],
                              templates: [
                                type: {:custom, Normandy.Options, :plain_map, []},
                                default: %{},
                                doc: "The initial `template_id => supplement` map."
                              ]
                            )

    @doc """
    Starts the catalog.

    ## Options

    #{Options.docs(@start_link_opts_schema)}
    """
    @spec start_link(keyword()) :: Agent.on_start()
    def start_link(opts) do
      opts = Options.validate!(opts, @start_link_opts_schema, {__MODULE__, :start_link, 1})
      name = Keyword.get(opts, :name)
      init = Keyword.fetch!(opts, :templates)

      if name,
        do: Agent.start_link(fn -> init end, name: name),
        else: Agent.start_link(fn -> init end)
    end
```

- [ ] **Step 3d: `Normandy.Cluster`**

Add `alias Normandy.Options`. Schemas:

```elixir
  @child_specs_opts_schema NimbleOptions.new!(
                             registry: [
                               type: :atom,
                               required: true,
                               doc: "The Horde registry's name."
                             ],
                             supervisor: [
                               type: :atom,
                               required: true,
                               doc: "The Horde supervisor's name."
                             ],
                             store: [
                               type: {:tuple, [:atom, :any]},
                               doc: "The `SessionStore`; with `:template_provider`, starts the reaper."
                             ],
                             template_provider: [
                               type: {:tuple, [:atom, :any]},
                               doc: "The `AgentTemplate`; with `:store`, starts the reaper."
                             ],
                             topologies: [
                               type: :keyword_list,
                               default: [],
                               doc:
                                 "libcluster topologies; adds `Cluster.Supervisor` when libcluster " <>
                                   "is loaded."
                             ]
                           )

  @redis_child_specs_opts_schema NimbleOptions.new!(
                                   redix: [
                                     type: :keyword_list,
                                     required: true,
                                     doc: "Options for the Redix connection; must include `:name`."
                                   ],
                                   namespace: [
                                     type: :string,
                                     required: true,
                                     doc: "The key namespace for the registry and the store."
                                   ],
                                   registry: [
                                     type: :atom,
                                     required: true,
                                     doc: "The Redis registry owner's name."
                                   ],
                                   supervisor: [
                                     type: :atom,
                                     required: true,
                                     doc: "The local `Turn.Supervisor`'s name."
                                   ],
                                   template_provider: [
                                     type: {:tuple, [:atom, :any]},
                                     doc: "The `AgentTemplate`; starts the reaper."
                                   ]
                                 )
```

Bodies (docs: each "Required: ... Optional: ..." sentence is replaced by the generated
`## Options`; `setup_mnesia_store!/1`'s by "## Options\n\nThe options of
`Normandy.Behaviours.SessionStore.Mnesia.create_tables/1`."):

```elixir
  def child_specs(opts) do
    opts = Options.validate!(opts, @child_specs_opts_schema, {__MODULE__, :child_specs, 1})
    reg = Keyword.fetch!(opts, :registry)
    sup = Keyword.fetch!(opts, :supervisor)

    libcluster_specs(opts, reg) ++
      [
        %{id: reg, start: {HReg, :start_link, [[name: reg]]}},
        %{id: sup, start: {HSup, :start_link, [[name: sup]]}}
      ] ++
      reaper_specs(opts, reg, sup)
  end

  def setup_mnesia_store!(opts) do
    opts
    |> Options.validate!(
      MnesiaStore.__opts_schema__(:create_tables),
      {__MODULE__, :setup_mnesia_store!, 1}
    )
    |> MnesiaStore.create_tables()
  end

  def redis_child_specs(opts) do
    opts =
      Options.validate!(opts, @redis_child_specs_opts_schema, {__MODULE__, :redis_child_specs, 1})

    redix = Keyword.fetch!(opts, :redix)

    conn_name =
      case Keyword.fetch(redix, :name) do
        {:ok, name} ->
          name

        :error ->
          raise ArgumentError,
                "Normandy.Cluster.redis_child_specs/1: :redix must include :name, the Redix " <>
                  "connection's registered name"
      end

    ns = Keyword.fetch!(opts, :namespace)
    registry = Keyword.fetch!(opts, :registry)
    supervisor = Keyword.fetch!(opts, :supervisor)

    [
      {Redix, redix},
      %{
        id: registry,
        start: {RedisReg, :start_link, [[name: registry, conn: conn_name, namespace: ns]]}
      },
      %{id: supervisor, start: {LocalSup, :start_link, [[name: supervisor]]}}
    ] ++ redis_reaper_specs(opts, conn_name, ns, registry, supervisor)
  end
```

In `libcluster_specs/2`, `Keyword.get(opts, :topologies, [])` → `Keyword.fetch!(opts, :topologies)`.

- [ ] **Step 3e: One place for every timeout default (DX-28)**

Append to `Normandy.Options`'s moduledoc (`lib/normandy/options.ex`):

```markdown
  ## Timeouts

  Every option a caller waits on is called `:timeout` (ms or `:infinity`), except the
  durable server's two `_ms` options, which are not waits on a call. Defaults:

  | Option | Where | Default |
  |---|---|---|
  | `:timeout` | `AgentProcess.run/3` | 60_000 |
  | `:timeout` | `AgentPool.checkout/2`, `AgentPool.transaction/3` | 5_000 |
  | `:timeout` | `Reactive.race/3`, `all/3`, `some/3` | 60_000 |
  | `:timeout` | `ParallelOrchestrator.execute/3`, `execute_stream/2` | 300_000 per agent |
  | `:timeout` | `Batch.Processor.process_batch/3` and its variants, `BaseAgent.process_batch/3` | 300_000 per item |
  | `:timeout` | `Toolset.register/3`, `BaseAgent.register_tool/3`, DSL `tool Mod, timeout: ms` | the tool call's timeout; unset: 30_000 (`Tools.Executor.default_timeout/0`) |
  | `:timeout` | `Tools.Executor.execute_tool/2`, `execute_tool_classified/2` | 30_000 (the dispatcher passes the registration timeout) |
  | `:timeout` | `A2A.Registry.discover_and_register/3` | 60_000 (each registered tool's timeout) |
  | `:approval_timeout_ms` | `Turn.Server.start_link/1` | 300_000 |
  | `:idle_timeout_ms` | `Turn.Server.start_link/1` | 60_000 |
  | `:wait_timeout` | `SessionStore.Mnesia.create_tables/1`, `MemoryStore.Mnesia.create_tables/1` | 30_000 |
  | (none) | `Turn.Server.run/2` | `:infinity` |

  `CircuitBreaker.start_link/1`'s `:timeout` (60_000) is how long an open breaker waits before
  it lets probe calls through, not a call timeout.
```

(`A2A.AgentTool` has no `:timeout` since Task 3.4c: a remote agent's call is bounded by its
registration timeout.)

- [ ] **Step 4: Run the table test**

Run: `mix test test/options/store_options_test.exs test/behaviours test/cluster_test.exs`
Expected: PASS, ` 0 failures` (the `:redis`, `:postgres` and `:distributed` tags stay excluded
here; Task 3.8 runs them).

- [ ] **Step 5: Write the coverage test (Ruling 6)**

Create `test/options_coverage_test.exs`:

```elixir
defmodule Normandy.OptionsCoverageTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Turn}
  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Coordination.{ParallelOrchestrator, SequentialOrchestrator}
  alias Normandy.Resilience.Retry
  alias Normandy.Test.StubClient
  alias Normandy.Tools.{Executor, Memory, Toolset}

  # Ruling 6 (plan-wave-3.md): every lib/ file that reads `Keyword.get(opts` is either a
  # file whose public entry points validate their options with Normandy.Options.validate!/3
  # (@validated) or a file whose reads are not entry-point options (@internal, with the
  # reason). A new file fails the first test until it joins one of the two lists.
  @pattern "Keyword.get(opts"

  @validated [
    "lib/normandy/a2a/agent_tool.ex",
    "lib/normandy/a2a/registry.ex",
    "lib/normandy/a2a/server.ex",
    "lib/normandy/agents/base_agent.ex",
    "lib/normandy/agents/base_agent/init_options.ex",
    "lib/normandy/agents/turn.ex",
    "lib/normandy/agents/turn/resume_reaper.ex",
    "lib/normandy/agents/turn/server.ex",
    "lib/normandy/agents/turn/session.ex",
    "lib/normandy/agents/turn/supervisor.ex",
    "lib/normandy/agents/turn/supervisor/horde.ex",
    "lib/normandy/batch/processor.ex",
    "lib/normandy/behaviours/agent_template.ex",
    "lib/normandy/behaviours/compactor/window_manager.ex",
    "lib/normandy/behaviours/memory_store/ets.ex",
    "lib/normandy/behaviours/memory_store/in_memory.ex",
    "lib/normandy/behaviours/memory_store/mnesia.ex",
    "lib/normandy/behaviours/memory_store/redis.ex",
    "lib/normandy/behaviours/session_registry/horde.ex",
    "lib/normandy/behaviours/session_registry/native.ex",
    "lib/normandy/behaviours/session_registry/redis.ex",
    "lib/normandy/behaviours/session_store/ets.ex",
    "lib/normandy/behaviours/session_store/in_memory.ex",
    "lib/normandy/behaviours/session_store/mnesia.ex",
    "lib/normandy/behaviours/session_store/redis.ex",
    "lib/normandy/cluster.ex",
    "lib/normandy/components/agent_memory.ex",
    "lib/normandy/context/summarizer.ex",
    "lib/normandy/context/window_manager.ex",
    "lib/normandy/coordination/agent_message.ex",
    "lib/normandy/coordination/agent_pool.ex",
    "lib/normandy/coordination/agent_process.ex",
    "lib/normandy/coordination/agent_supervisor.ex",
    "lib/normandy/coordination/hierarchical_coordinator.ex",
    "lib/normandy/coordination/parallel_orchestrator.ex",
    "lib/normandy/coordination/pattern.ex",
    "lib/normandy/coordination/reactive.ex",
    "lib/normandy/coordination/sequential_orchestrator.ex",
    "lib/normandy/coordination/stateful_context.ex",
    "lib/normandy/dsl/agent.ex",
    "lib/normandy/dsl/workflow.ex",
    "lib/normandy/mcp/registry.ex",
    "lib/normandy/mcp/tool_wrapper.ex",
    "lib/normandy/resilience/circuit_breaker.ex",
    "lib/normandy/tools/executor.ex",
    "lib/normandy/tools/toolset.ex"
  ]

  @internal %{
    "lib/normandy/behaviours/hooks.ex" =>
      "validate_entries!/2's :load comes from BaseAgent.init/1 and Turn.Server; each hook " <>
        "entry's :on_error is checked by validate_on_error!/2",
    "lib/normandy/guardrails.ex" =>
      "a guard entry's own :on_error, checked when the agent is built",
    "lib/normandy/guardrails/builtins/forbidden_substrings.ex" =>
      "guard config read by check/2; the guard checks its own keys",
    "lib/normandy/guardrails/builtins/max_length.ex" =>
      "guard config read by check/2; the guard checks its own keys",
    "lib/normandy/guardrails/builtins/regex_guard.ex" =>
      "guard config read by check/2; the guard checks its own keys",
    "lib/normandy/guardrails/builtins/semantic_scope.ex" =>
      "guard config read by check/2; the guard checks its own keys",
    "lib/normandy/guardrails/violation_error.ex" => "Exception.exception/1 fields",
    "lib/normandy/schema/validation_error.ex" => "Exception.exception/1 fields",
    "lib/normandy/llm/claudio_adapter.ex" =>
      "per-call options Normandy builds for the Model protocol (:request_kind, " <>
        ":request_tracker, :json_retries); client options are checked by validate_options!/1",
    "lib/normandy/llm/openai_compatible_adapter.ex" =>
      "per-call options Normandy builds for the Model protocol; client options are checked " <>
        "by validate_options!/1",
    "lib/normandy/llm/json_deserializer.ex" =>
      "parsing options built by Normandy's adapters (:adapter, :max_retries, :on_retry_usage)",
    "lib/normandy/llm/json/decoder.ex" => "parsing options built by JsonDeserializer",
    "lib/normandy/llm/structured_outputs.ex" =>
      "reads :structured_outputs from client.options, checked by the adapter's validate_options!/1",
    "lib/normandy/schema.ex" => "field/3 macro options, read at compile time",
    "lib/normandy/tool.ex" =>
      "`use Normandy.Tool` options, read at compile time after check_option_keys!/2 (Task 3.4b)",
    "lib/normandy/validate.ex" => "Ecto-style per-validation options (:message, ...)",
    "lib/normandy/telemetry/metadata.ex" => "telemetry metadata builder called by Normandy",
    "lib/normandy/telemetry/provider.ex" => "telemetry metadata builder called by Normandy"
  }

  defp lib_files_reading_opts do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.filter(&(File.read!(&1) =~ @pattern))
    |> Enum.sort()
  end

  describe "Ruling 6 allowlist" do
    test "every lib file that reads Keyword.get(opts is validated or allowlisted" do
      unknown = lib_files_reading_opts() -- (@validated ++ Map.keys(@internal))

      assert unknown == [], """
      These files read `#{@pattern}` but are in neither list:

      #{Enum.join(unknown, "\n")}

      If the file has a public function that takes options, validate them with
      Normandy.Options.validate!/3 and add the file to @validated; otherwise add it to
      @internal with the reason its reads are not entry-point options.
      """
    end

    test "every @validated file calls Normandy.Options.validate!/3" do
      missing = Enum.reject(@validated, &(File.exists?(&1) and File.read!(&1) =~ "Options.validate!("))
      assert missing == [], "listed in @validated but never call Options.validate!/3: #{inspect(missing)}"
    end

    test "every @internal file still reads Keyword.get(opts" do
      stale =
        Enum.reject(Map.keys(@internal), &(File.exists?(&1) and File.read!(&1) =~ @pattern))

      assert stale == [], "remove from @internal: #{inspect(stale)}"
    end
  end

  # Entry points validated before Tasks 3.7a–3.7d: BaseAgent.init/1, run/3 and DSL new/1 (3.1),
  # Toolset.register/3, the Executor options and AgentTool.new/3's :timeout (3.4),
  # Turn.Session.new/1 and the orchestrators (3.5); Tools.Memory.new/1 and Retry keep their own.
  describe "entry points validated elsewhere still reject a misspelled key" do
    defmodule ProbeAgent do
      use Normandy.DSL.Agent

      agent do
        model("m")
      end
    end

    test "BaseAgent.init/1 (Task 3.1)" do
      error =
        assert_raise ArgumentError, fn ->
          BaseAgent.init(model: "m", client: %StubClient{}, max_tokns: 10)
        end

      assert error.message =~ ~r/^Normandy\.Agents\.BaseAgent\.init\/1: /
      assert error.message =~ ":max_tokns"
    end

    test "BaseAgent.run/3 (Task 3.1)" do
      agent = BaseAgent.init(model: "m", client: %StubClient{})
      error = assert_raise ArgumentError, fn -> BaseAgent.run(agent, "hi", timout: 1) end
      assert error.message =~ ~r/^Normandy\.Agents\.BaseAgent\.run\/3: /
      assert error.message =~ ":timout"
    end

    test "Turn.Session.new/1 (Task 3.5)" do
      error = assert_raise ArgumentError, fn -> Turn.Session.new(sesion_id: "s") end
      assert error.message =~ ~r/^Normandy\.Agents\.Turn\.Session\.new\/1: /
      assert error.message =~ ":sesion_id"
    end

    test "the orchestrators (Task 3.5b/3.5c)" do
      calls = [
        {"Normandy.Coordination.ParallelOrchestrator.execute/3",
         fn -> ParallelOrchestrator.execute([], "go", max_concurency: 2) end},
        {"Normandy.Coordination.ParallelOrchestrator.execute_specs/2",
         fn -> ParallelOrchestrator.execute_specs([], max_concurency: 2) end},
        {"Normandy.Coordination.SequentialOrchestrator.execute/3",
         fn -> SequentialOrchestrator.execute([], "go", max_concurency: 2) end},
        {"Normandy.Coordination.SequentialOrchestrator.execute_with_messages/3",
         fn -> SequentialOrchestrator.execute_with_messages([], nil, max_concurency: 2) end}
      ]

      for {label, call} <- calls do
        error = assert_raise ArgumentError, call
        assert String.starts_with?(error.message, label <> ": "), "#{label}: #{error.message}"
        assert error.message =~ ":max_concurency"
      end
    end

    test "Tools.Executor.execute_tool/2 and execute_tool_classified/2 (Task 3.4c)" do
      tool = Memory.new(store: {MemoryStore.InMemory, MemoryStore.InMemory.new()})

      for fun <- [:execute_tool, :execute_tool_classified] do
        error = assert_raise ArgumentError, fn -> apply(Executor, fun, [tool, [timout: 1]]) end
        assert error.message =~ ~r/^Normandy\.Tools\.Executor\.#{fun}\/2: /
        assert error.message =~ ":timout"
      end
    end

    test "A2A.AgentTool.new/3's :timeout check (Task 3.4c)" do
      assert_raise ArgumentError,
                   "Normandy.A2A.AgentTool.new/3: :timeout is a registration option in 2.0; " <>
                     "pass it to BaseAgent.register_tool/3 or Normandy.Tools.Toolset.register/3",
                   fn -> Normandy.A2A.AgentTool.new("http://a", nil, timeout: 1) end
    end

    test "Toolset.register/3 (Task 3.4)" do
      tool = Memory.new(store: {MemoryStore.InMemory, MemoryStore.InMemory.new()})

      error =
        assert_raise ArgumentError, fn -> Toolset.register(Toolset.new([]), tool, timeot: 1) end

      assert error.message =~ ~r/^Normandy\.Tools\.Toolset\.register\/3: /
      assert error.message =~ ":timeot"
    end

    test "Tools.Memory.new/1 (its own check)" do
      error =
        assert_raise ArgumentError, fn ->
          Memory.new(store: {MemoryStore.InMemory, MemoryStore.InMemory.new()}, max_view_char: 1)
        end

      assert error.message =~ ~r/^Normandy\.Tools\.Memory\.new\/1: /
      assert error.message =~ ":max_view_char"
    end

    test "Retry.with_retry/2 (its own check)" do
      error =
        assert_raise ArgumentError, fn -> Retry.with_retry(fn -> {:ok, 1} end, max_attemps: 2) end

      assert error.message =~ ~r/^Retry\.with_retry\/2: /
      assert error.message =~ ":max_attemps"
    end

    test "a DSL agent's generated new/1 (Task 3.1c: BaseAgent.init/1's schema under MyAgent.new/1)" do
      error =
        assert_raise ArgumentError, fn -> ProbeAgent.new(client: %StubClient{}, temprature: 0.1) end

      assert error.message =~ "#{inspect(ProbeAgent)}.new/1: "
      assert error.message =~ ":temprature"
    end
  end
end
```

- [ ] **Step 6: Run the coverage test and reconcile the lists with the code**

Run: `mix test test/options_coverage_test.exs`
Expected: PASS. The lists above are the expected end state after Tasks 3.1–3.7c. When the first
test names an unlisted file, decide by its reads: a public function taking options gets validated
(write it here, with a row in the matching `test/options/*_options_test.exs`) and joins
`@validated`; anything else joins `@internal` with its reason. When the second names a file
that never calls `Options.validate!(`, that file's task did not land the validation: fix the file,
not the list. When the third names a stale `@internal` entry, delete it. When a test in the second
describe fails, the earlier task's message does not have the `Mod.fun/arity: ` prefix and the key:
fix that task's message (it is the contract the header promises), not this test.

- [ ] **Step 7: MIGRATING**

Append to Task 3.7a's section (§30):

```markdown
- `SessionStore.InMemory.new/1` and `start_link/1`, `MemoryStore.InMemory.new/1` and
  `MemoryStore.ETS.new/1` take no options; a key raises (it was ignored).
- `SessionRegistry.Redis.start_link/1` raises without `:conn` or `:url` (it crashed `init/1`
  with a `KeyError`). `Cluster.child_specs/1` and `redis_child_specs/1` raise for a missing or
  misspelled key; a `:redix` list without `:name` raises `ArgumentError` naming it.
- The session and memory stores' Mnesia `create_tables/1`: `:copies` must be `:disc_copies` or
  `:ram_copies`.
- `Normandy.Options`' docs list every timeout option and its default in one table.
```

- [ ] **Step 8: Format and run the suite**

Run: `mix format && mix test 2>&1 | tail -5`
Expected: ` 0 failures`.

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/behaviours/session_registry/native.ex \
  lib/normandy/behaviours/session_registry/horde.ex lib/normandy/behaviours/session_registry/redis.ex \
  lib/normandy/behaviours/session_store/in_memory.ex lib/normandy/behaviours/session_store/ets.ex \
  lib/normandy/behaviours/session_store/mnesia.ex lib/normandy/behaviours/session_store/redis.ex \
  lib/normandy/behaviours/memory_store/in_memory.ex lib/normandy/behaviours/memory_store/ets.ex \
  lib/normandy/behaviours/memory_store/mnesia.ex lib/normandy/behaviours/memory_store/redis.ex \
  lib/normandy/behaviours/agent_template.ex lib/normandy/cluster.ex lib/normandy/options.ex \
  MIGRATING-2.0.md test/options/store_options_test.exs test/options_coverage_test.exs
git commit -m "feat(stores): reject unknown options at the store, registry and cluster constructors"
```

Add any file fixed in Step 6 to the `git add` line by name and say why in the commit body.

---

### Task 3.8: Wave 3 gate

**Files:**
- Modify: `investigations/pre-2.0-audit/decisions.md` ("Progress")
- Modify: `/Users/antonio/.claude/projects/-Users-antonio-personal-normandy/memory/pre-2-0-audit-2026-10.md`
  and its line in `MEMORY.md` (same directory)
- Modify: `mix.exs` docs groups only if Step 2 reports a module missing from them

**Interfaces:**
- Consumes: Tasks 3.1–3.7d committed.
- Produces: a recorded gate result; no code change unless a step below fails (then: Global
  Constraints, "If any test fails, fix it").

- [ ] **Step 1: Precommit**

```bash
LOG="${TMPDIR:-/tmp}/normandy-wave3-precommit.log"
mix format && mix precommit > "$LOG" 2>&1; echo "precommit exit=$?"
grep -E " 0 failures| [1-9][0-9]* failures?|Unnecessary Skips|found no issues|issues? found" "$LOG"
```

Expected: `precommit exit=0`; the test line contains ` 0 failures`; credo "found no issues";
dialyzer `Unnecessary Skips: 0`. Gate on the exit code and the literal ` 0 failures`, never on a
`| tail`. A new dialyzer warning gets fixed, or a `.dialyzer_ignore.exs` entry with a reason
comment. Record the test count and the seed from `$LOG`.

- [ ] **Step 2: Docs and trace**

```bash
mix docs --warnings-as-errors; echo "docs exit=$?"
mix test --trace 2>&1 | tail -3
```

Expected: `docs exit=0`; the trace run ends with ` 0 failures`. A warning for a module missing
from a `mix.exs` docs group: add it next to its neighbours (`Normandy.Options` beside the
`Agents` group's config modules, `Normandy.Tool` and `Normandy.Tools.Toolset` in `Tools`, the
`*NotFoundError` exceptions in `Errors`); the full regrouping is Task 7.2.

- [ ] **Step 3: Tagged suites**

```bash
docker ps --filter name=normandy-test-redis --filter name=normandy-test-pg --format '{{.Names}} {{.Status}}'
NORMANDY_REDIS=true mix test --only redis 2>&1 | tail -3
POSTGRES_PORT=55432 PGPORT=55432 mix test.postgres 2>&1 | tail -3
POSTGRES_PORT=55432 PGPORT=55432 NORMANDY_POSTGRES=true mix test --only distributed --include postgres 2>&1 | tail -3
```

Expected: both containers `Up` (start a stopped one with `docker start normandy-test-redis` or
`docker start normandy-test-pg`; `normandy-test-pg` is the throwaway Postgres on port 55432);
each run ends with ` 0 failures`. Wave 2 did not run these 203 tagged tests, so a failure here
may predate Wave 3: find the commit that introduced it (`git log -S` on the failing assertion, or
check the test out at `36a9310`) and record it either way; fix it in this wave (Global
Constraints).

The `:integration` and `:normandy_integration` suites call the Anthropic API and need
`ANTHROPIC_API_KEY` (or `API_KEY`). Run them only when Q provides a key:
`mix test --only integration --only normandy_integration 2>&1 | tail -3`, expecting
` 0 failures`; otherwise record "integration suites not run (no API key)".

- [ ] **Step 4: Package contents**

```bash
mix hex.build 2>&1 | sed -n '/Files:/,/Version:/p' > "${TMPDIR:-/tmp}/normandy-wave3-files.txt"
grep -c "tools/examples" "${TMPDIR:-/tmp}/normandy-wave3-files.txt"
grep -c "lib/normandy/options.ex\|lib/normandy/json.ex\|lib/normandy/tool.ex\|lib/normandy/tools/toolset.ex" \
  "${TMPDIR:-/tmp}/normandy-wave3-files.txt"
mix hex.build 2>&1 | tail -2
```

Expected: `0` (no `tools/examples` in the package), `4` (the four new Wave 3 modules are in it),
and the build's last line is `Dependencies excluded from the package (only Hex packages can be
dependencies): claudio` with `** (Mix) Stopping package build due to errors.` before it. That
error is expected until Claudio 0.7.0 is on Hex (decision 2; Claudio is `path: "../Claudio"`),
and it is why this step reads the printed file list instead of `mix hex.build --unpack`, which
stops before unpacking. Any other build error fails the gate.

- [ ] **Step 5: Acceptance greps**

```bash
grep -rn "Poison" lib config mix.exs
grep -rn "Keyword.validate!(opts" lib
grep -rln "NonExistentTurn\|NonExistentContextProvider\|__str__\|__rich__\|SchemaBaseTool\|ContextualTool\|Tools\.BaseTool\|Tools\.Registry\b" lib test config
grep -rn "def get_tool\|def get_context_provider\|def get_entry" lib
grep -rln "retry_options\|enable_circuit_breaker\|circuit_breaker_options" lib test config
```

Expected: the first four print nothing, except that the third may list
`lib/normandy/tools/toolset.ex`, `lib/normandy/agents/config_template.ex` and their tests when the
hit is the 1.x guard of Ruling 5 naming a removed module (open each hit: anything else is a
missed rename). The fifth lists only the 1.x template translation (`config_template.ex`, Task
3.2), its tests and fixtures; any other file still uses a 1.x option name.

- [ ] **Step 6: Record**

Append a Wave 3 line to `investigations/pre-2.0-audit/decisions.md` → "Progress", in the form of
the Wave 2 line: the commit range (`git log --oneline 95dc149..HEAD | tail -1` and `| head -1`),
the test count and seeds from Steps 1-2, the tagged-suite results from Step 3 (including "not
run" for any suite that was not), the package check from Step 4, and every ruling made while
executing the wave (Convention 8 caller fixes, Convention 9 schema changes, anything Q decided).
Update the memory file `pre-2-0-audit-2026-10.md` (Wave 3 done, range, next: `plan-wave-4.md`)
and its one-line entry in `MEMORY.md`. Do not commit the memory files (they are outside the repo);
commit `decisions.md`:

```bash
git add investigations/pre-2.0-audit/decisions.md
git commit -m "docs(investigations): record the Wave 3 gate"
```

---

## Appendix: open questions for Q

**Settled.** Q accepted every recommendation below on 2026-10-05 (`decisions.md` decision 18),
with three outcomes that differ from or extend the recommendation: #2 (the prefixed message,
as recommended, now applied), #9 (no `properties` key ⇒ open) and #26 (one `plain_map/1` in
`Normandy.Options`, Task 3.1a). The plan above implements those outcomes; the entries stay as
the record of what was asked and accepted.

1. **DSL `new/1` return shape (DX-5 rest; Task 3.1c).** Implemented: `new/1` returns the
   `%BaseAgentConfig{}` and raises (59 call sites change); controller ruling C4 adopted this.
   Alternative: keep `{:ok, agent}` and add `new!/1`. Recommend: as written (`new/1` never
   returned `{:error, _}`).
2. **The missing-`:model` message (Task 3.1b).** Implemented: the exact `plan.md` text
   `"BaseAgent.init/1 requires :model (a string), got none"`, the one `init/1` message without
   the `Normandy.Agents.` prefix (header records it). Writer recommends switching to
   `"Normandy.Agents.BaseAgent.init/1: requires :model (a string), got none"` for consistency
   (one string in `InitOptions.validate!/1` and one test).
   **Outcome (decision 18): switched.** `"Normandy.Agents.BaseAgent.init/1: requires :model (a
   string), got none"` in Task 3.1b (code, test, MIGRATING §21, header); a DSL agent that
   declares no model raises `"MyAgent.new/1: requires :model (a string), got none"` (Task 3.1c,
   was a `RuntimeError`).
3. **`circuit_breaker:` drops 1.x's `:name` (Task 3.1b/3.2b).** A named breaker made a second
   `init/1` with the same options crash. Recommend: keep it out; Wave 4 replaces the pid with a key.
4. **`guardrails` read leniently (Task 3.2b).** A hand-built `%BaseAgentConfig{guardrails: [output: x]}`
   reads the other four keys as defaults; `init/1` always fills all five. Recommend: as written.
5. **Templates from unreleased 2.0 builds raise (Task 3.2c, decision 17c).** Long-lived dev
   deployments must recreate those sessions. Recommend: as decided.
6. **Hook-rewritten tool output that JSON cannot express (Task 3.3a).** An `after_tool` hook (or
   `after_hooks` fn) that rewrites a result's output to a tuple runs after Dispatch's check and
   still raises later. Should the hook runner check it too? Recommend: no, not this wave (a hook
   returning a tuple is a programming error and the raise names it).
7. **Error reasons JSON cannot express (Task 3.3a).** `{:error, {:http, 503}}` goes to the model as
   `inspect/1` text. Keep, or treat like an unencodable output? Recommend: keep (the model loses
   nothing; structs never take this path).
8. **Executor API removal (Task 3.4c).** `Executor.execute/3`, `execute_parallel/3`,
   `execute_sequential/3` and `:max_retries` are deleted (only tests called them). Recommend:
   accept (MIGRATING §25 says so). Alternative: keep them with an `input:` argument.
9. **Strict hand-written tool schemas (Task 3.4b/c).** Without `input: Schema`, an absent
   `additionalProperties` counts as `false`, so an MCP tool whose server schema omits
   `properties` refuses every key. Recommend: keep strict (SEC-1). Alternative: "no `properties`
   key ⇒ open".
   **Outcome (decision 18): the alternative.** A hand-written schema with no `properties` key
   accepts any keys (still an object; `required` still checked); one that declares `properties`
   stays strict unless `additionalProperties` is `true`. Task 3.4b (validator, moduledoc, four
   tests), Task 3.4c (`MCP.ToolWrapper` comment, MIGRATING §25, commit message), Task 3.4d
   (CLAUDE.md).
10. **A2A timeout default (Task 3.4c).** A hand-registered `AgentTool` now runs under the
    executor's 30 s (1.x: its struct's 60 s); `A2A.Registry.discover_and_register/3` keeps 60 s.
    Recommend: accept (e2e 12 registers with `timeout: 60_000`).
11. **Field rename `tool_registry` → `toolset` (Task 3.4a)** in the config, `init/1`, the DSL
    override and the supplement: one more breaking rename. Recommend: accept.
12. **Orchestrator result: strict vs lenient (Task 3.5b).** Implemented strict:
    `{:error, %OrchestrationError{}}` when any agent failed, successes inside it. Alternative:
    `{:ok, %{id => {:ok, out} | {:error, e}}}`. Recommend: strict.
13. **API removed beyond DX-15 (Tasks 3.5b/c).** `execute_same_input/3`, the `:shared_context`,
    `:aggregate`, `:ordered`, `:store_intermediate` options and the returned
    `context`/`aggregated` go (they only fed the old result map). A repeated agent id now raises
    in Parallel. Recommend: accept (MIGRATING §27 lists each).
14. **`Reactive` and `HierarchicalCoordinator` stay outside the orchestrator shape (Task 3.5d).**
    Recommend: yes.
15. **Tagged tuples with stacktraces left in place.** `HierarchicalCoordinator` returns
    `{:error, {:manager_failed, {:exception, e, stacktrace}}}` / `{:error, {:aggregation_failed, e,
    stacktrace}}`; `Batch.Processor.process_batch` items `{:error, {:exit, :timeout}}` (against
    decision 6). Recommend: a Wave 6 (process hygiene) follow-up replying the bare exception.
16. **`AgentProcess.approve/2` keeps `{:error, :inline_mode}`.** Recommend: decide with Wave 6's
    "AgentProcess default mode" task.
17. **`ParallelOrchestrator.execute_stream/2` keeps `(specs, opts)`.** Recommend: keep (DX-15
    names `execute` only).
18. **`AgentMemory.fetch_entry!/2` raises `KeyError` (Task 3.6a ruling).** Recommend: keep.
19. **`AgentMemory.delete_turn/2` raises without a `!`; `fork/2` returns `{:error, :no_such_entry}`.**
    Recommend: keep (operations, not lookups).
20. **`Schema.Introspection.get_*` (nil on a miss).** Deferred. Recommend: Wave 7's
    schema-accessor task applies the `fetch_*` rule to `get_field_type/2` and `get_field_metadata/2`.
21. **Behaviour changes in Tasks 3.7b–d Q may veto** (recommendation in brackets):
    `process_batch_with_stats/3` rejects `:ordered` [keep: it was silently overridden];
    `compress_conversation/3` rejects the documented but unread `:max_summary_tokens` [keep
    `:max_tokens`]; `:summary_role` limited to `"user"`/`"assistant"` [keep]; `InMemory`/`ETS`
    store constructors reject every key [keep]; `A2A.Registry.from_agent_card/3` rejects
    `:timeout` it used to drop [keep; controller change].
22. **`Retry` and `Tools.Memory.new/1` keep their own checks and prefixes** (`"Retry.with_retry/2: "`,
    `"...; allowed: ..."`) and get no generated docs. Recommend: leave them this wave; the coverage
    test pins their prefixes.
23. **`Turn.Server.run/2` has no `:timeout`** (DX-28's `run/3` suggestion is a new API).
    Recommend: raise with Q for Wave 4 or later; listed in the timeouts table only.
24. **`AgentProcess`'s `:context_pid` is stored but never read.** Kept and documented. Recommend:
    deleting it is a separate breaking change, not this wave.
25. **The `mix hex.build --unpack` acceptance check** cannot pass while Claudio is a path dep.
    Recommend: use the printed-file-list check (Tasks 3.3b Step 7, 3.8 Step 4) until Claudio
    0.7.0 is on Hex, then switch back to `--unpack`.
26. **Two `plain_map/1` helpers (controller finding).** Task 3.1b's `InitOptions.plain_map/1`
    (`"expected a map of plain data, got ..."`, asserted by two 3.1b test rewrites) and Task 3.7a's
    `Normandy.Options.plain_map/1` (`"expected a plain map (not a struct), got: ..."`). Recommend:
    leave both this wave (each is pinned by tests); a later cleanup can point `:tool_context` at
    `Options.plain_map/1` and update the two 3.1b assertions.
    **Outcome (decision 18): one helper now.** `Normandy.Options.plain_map/1` is created in Task
    3.1a (with its test) and is the only one; its message is
    `"expected a plain map (not a struct), got: <Describe.type_of/1>"`. Task 3.1b's `:tool_context`
    uses it (`InitOptions.plain_map/1` is not written; the two test rewrites assert the new
    message); Task 3.7a consumes it instead of creating it.

## Appendix: writer notes

Remaining risks and unverified items from the sections' notes, deduplicated and shortened.

**How each section was checked**
- 3.1–3.2: applied in order to a scratch export of `95dc149`; full `mix test` green after each task
  (3.1a 2710 … 3.2c 2772 tests), `mix precommit` and `mix docs --warnings-as-errors` exit 0 after
  3.2c. Diffs in 3.2a–3.2c carry post-previous-task line numbers (apply by hand if `git apply`
  fails). Not run: the tagged suites (postgres, redis, distributed, Horde, integration; 203 tests)
  and live e2e 02, 06, 07, 08, 09.
- 3.3: 3.3a+3.3b applied to a scratch copy (without 3.1/3.2): `mix precommit` exit 0, 2714 tests;
  the live weather test passed (real API calls). 3.3b was written with renamed fixtures; the
  controller's ruling C1 (keep `Normandy.Tools.Examples.*`) changed its Steps 1, 2, 4 and 9
  after that rehearsal — those steps are unrehearsed.
- 3.4: rehearsed on a copy with 3.1 stubbed (`Options.validate!/3` = NimbleOptions + prefix) and
  3.3 simulated (tools moved, names kept): compile, credo, dialyzer, docs clean; `mix test` 0
  failures in 16 consecutive runs. One run of 17 had 1 failure that did not recur and whose name
  was not captured. Not verified: 3.1's exact message text (3.4 tests assert only prefix + key),
  3.2's final `rebuild/3`, live e2e, tagged suites.
- 3.5–3.6: none of the planned code was compiled or run (depends on 3.1–3.4); scratch scripts on
  `95dc149` verified the baseline behaviours and the perl rewrite counts (37 Session call sites;
  5/11/12 in 3.6b). Dialyzer on the new specs is unchecked.
- 3.7–3.8: none of the plan's tests were run (they need 3.1–3.6). Verified: NimbleOptions 1.1.1
  messages, unknown-before-required ordering, `{:map, _, _}` raising on structs, schema reuse via
  `.schema`, function captures in generated tests, `mix hex.build` with the path dep. Each 3.7
  sub-task's Step 0 grep and Convention 9 absorb key drift from earlier tasks; Task 3.7d Step 6
  reconciles the Ruling 6 lists with the real tree.
- All line numbers are at `95dc149`; re-grep before editing when an earlier task moved them.

**Risks and behaviour changes**
- Stricter `init/1` may reject 1.x user code the suite cannot see: `:memory` must be an
  `AgentMemory` struct (not a dumped map), `:client` a struct, `:name`/`:session_id` strings,
  schemas structs or `nil`. MIGRATING §21 names each.
- `AgentPool` calls `BaseAgent.init(state.agent_config)` inside the pool process, so a bad
  `agent_config` *value* raises there, not in the caller (Review Focus #3 covers the option keys
  only).
- Task 3.2b is ~880 diff lines (over the ~400 guideline) and cannot split without a red suite;
  ~550 are the regroup script and its table — review through the script's per-file counts.
- `ConfigTemplate.rebuild/3` checks field names, `max_tokens` and the compactor pin but does not
  run `init/1`'s schema over the other values; a hand-corrupted 2.0 template value fails later.
  `server_options` (written by `Turn.Session`) is an allowed template key.
- `Normandy.Context.WindowManager.new/1` keeps `:max_tokens` (standalone API); only the
  compactor option is renamed.
- Derived `Jason.Encoder` on an `io_schema`: redacted fields and `__meta__` encode as `null`
  (keys present, values never leak). Non-Jason adapters ignore a `Jason.Encoder` derive.
- `mix.lock` keeps the stale `claudio 0.6.0` entry that lists poison; example apps' lock files
  list poison (Wave 7). When Claudio switches to Hex `~> 0.7.0`, confirm its requirements exclude
  poison. The `decimal` advisory ignore stays (via `ex_json_schema`, test-only); check
  `mix hex.outdated ex_json_schema` at the gate.
- `examples/tools/weather.ex` is not compiled or formatted by the root project; its only check is
  the live test (and the `Code.compile_file` check in Task 3.4d).
- Task 3.4 placement: the `:timeout` registration option lands in 3.4c (with the executor that
  reads it), the DSL `tool Mod, opts` form in 3.4d; 3.4a validates `:replace` only.
- Smaller 3.4 changes a reviewer may ask about: a tool's input schema `title` is the input
  module's last segment; `Dispatch` answers "not found" when the config has no toolset (1.x
  raised `FunctionClauseError`); a parked approval whose tool disappeared is answered "not found"
  instead of crashing `Turn.Server`; DSL `config().tools` lists `{module, opts}`; `Toolset` is
  not exempt from Credo's `AliasUsage`, so 3.4a aliases it in 12 test files.
- `AgentProcess` in `:server` mode with an explicit `nil` session option (e.g.
  `template_provider: nil`) now fails `Turn.Session.new/1`; 1.x treated nil as unset.
- Compile-time coupling added by 3.7: `AgentSupervisor` reads `AgentProcess.__opts_schema__/1`,
  `A2A.Registry` reads `A2A.AgentTool.__opts_schema__/1`, `Turn.Supervisor.Horde` calls
  `Turn.Supervisor.default_restart_limit/0` (no cycles).
- Out of scope, noticed: the DSL's generated `run/3`/`run!/3` report errors as `BaseAgent.run/3`,
  not `MyAgent.run/3`.
