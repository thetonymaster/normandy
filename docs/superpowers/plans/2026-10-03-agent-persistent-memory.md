# Agent Persistent Memory and Tool Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents can opt in to a `memory` tool that reads and writes namespaced, path-addressed text documents that outlive sessions. Contextual tools receive per-session context that survives `Turn.Server` rehydration.

**Architecture:**

- **Tool context.** `BaseAgentConfig.tool_context` holds plain data and is carried in `ConfigTemplate`. Per call, `Tools.Context.build/2` turns it into a context struct, which reaches tools implementing the new `Tools.ContextualTool` protocol through the `Executor`'s `context:` option.
- **Store.** The `MemoryStore` behaviour is a small compare-and-set document store with five backends (InMemory, ETS, Mnesia, Postgres, Redis).
- **Tool.** `Tools.Memory` implements Anthropic's native memory-tool command set on top of the store. Its command logic lives in `Commands`, path rules in `Paths`, and output formatting in `Render`.

**Tech Stack:** Elixir ~> 1.15, ExUnit, `:telemetry` 1.4 (3-tuple `span`), Ecto SQL/Postgrex (optional), Redix with Lua scripts (optional), Mnesia.

**Spec:** `docs/superpowers/specs/2026-10-03-agent-persistent-memory-design.md`

## Global Constraints

- Before running tests, run `mix format`. Before any commit gate, `mix precommit` must report ` 0 failures`. Never chain a commit after `mix precommit | tail`.
- Never `git add .`. Add files one by one. Commit messages carry **no** AI attribution: no Co-Authored-By, no "Generated with".
- `credo --strict` uses the stock config. For complexity or nesting findings, add an inline `# credo:disable-for-next-line <Check>`; never change a global threshold.
- Each new `:telemetry` event must appear in the `Normandy.Telemetry` moduledoc (`test/telemetry/catalogue_test.exs`).
- No silent fallbacks:
  - A backend failure is `{:error, reason}`, never `:not_found`.
  - A missing namespace raises.
  - A contextual tool run without context returns an error.
- Paths sit under `/memories`, with a 255-byte maximum. Default limits:
  - `max_document_bytes: 100_000`
  - `max_view_chars: 16_000`
  - `max_cas_retries: 3`
  - `list` returns at most 1,000 entries
- Model-facing strings are the native memory-tool reference strings quoted in the spec §3. Copy them exactly.
- Optional deps: wrap Postgres modules in `if Code.ensure_loaded?(Ecto.Adapters.SQL)` (and the migration in `if Code.ensure_loaded?(Ecto.Migration)`), and the Redis module in `if Code.ensure_loaded?(Redix)`.
- Postgres tests carry `@moduletag :postgres` (run with `mix test --include postgres …`). Redis tests carry `@moduletag :redis` (run with `mix test --include redis …`).

## Deviations from the spec (decided while planning; flag in review)

1. **InMemory, ETS and Mnesia store one row per namespace** (`ns → %{path => doc}`) and share a pure module, `MemoryStore.Docs`, inside their serialized writer. Spec §2 described `{ns, path}` rows. The guarantees are the same, the code is written once, and memory namespaces are small.
2. **Postgres matches prefixes with `starts_with(path, $p)`** rather than `LIKE`, so there is nothing to escape. Ordering uses `COLLATE "C"`, so it matches Elixir's byte ordering.
3. **A contextual tool run without context returns its own `BaseTool.run/1` error,** classified `:tool_error`, rather than an `:exception` classification. The model-facing text is the same.
4. **The rehydration regression test runs on one node** with a fresh supervisor and registry. `ConfigTemplate.rebuild/3` is the code path under test, and it is the same on a fresh node. There is no `:distributed` peer.
5. **The e2e scenario uses the InMemory memory store.** Postgres and Redis are covered by the tagged contract tests.
6. **The telemetry `error_type` list adds `:invalid_input`** for a missing or ill-typed command field or an unknown command, and for deleting or renaming a root.

## Review Focus

1. **Two sessions of one template with different namespaces, after rehydration.** Each must still see only its own namespace. This is the bug the design exists to prevent. Tests: Task 2, Step 7.
2. **A path that tries to escape `/memories`** (`/memories/../x`, `%2e%2e`, `\`, a trailing `/`, NUL) must be rejected before any store call. Tests: Task 8.
3. **Concurrent edits of one document** must keep every edit on every backend. Tests: the concurrency test in the Task 3 contract, run by Tasks 3–7.
4. **A backend timeout during `view` or `str_replace`** must be reported as "memory store unavailable", never as "does not exist". Tests: Task 10, `DownStore`.
5. **Model input naming `store`, `mounts` or a limit** must not change the tool. Tests: Task 9, `prepare_input/2`.

---

### Task 1: Tool context core: `Context`, `ContextualTool`, Executor `context:`

**Files:**
- Create: `lib/normandy/tools/context.ex`
- Create: `lib/normandy/tools/contextual_tool.ex`
- Modify: `lib/normandy/tools/executor.ex`
- Create: `test/support/context_probe.ex`
- Test: `test/tools/context_test.exs`

**Interfaces:**
- Produces:
  - `%Normandy.Tools.Context{session_id, agent_name, turn_id, tool_call_id, values}`.
  - `Context.build(config :: map(), %ToolCall{}) :: Context.t()`.
  - The protocol `Normandy.Tools.ContextualTool.run(tool, ctx) :: {:ok, term} | {:error, String.t()}`.
  - The `Executor` option `context: Context.t()` on `execute/3`, `execute_tool/2`, `execute_tool_classified/2`, `execute_parallel/3` and `execute_sequential/3`.
  - The test tool `%Normandy.Test.ContextProbe{name: "probe", notify: pid | nil}`. When it runs with context it sends `{:probe_ctx, ctx}` and returns `{:ok, "ns=" <> inspect(ns)}`. Without context it returns `{:error, "probe requires tool context; it was called outside the dispatch pipeline"}`.

- [ ] **Step 1: Write the probe tool and the failing tests**

`test/support/context_probe.ex`:

```elixir
defmodule Normandy.Test.ContextProbe do
  @moduledoc """
  A contextual tool for tests. With context it sends `{:probe_ctx, ctx}` to
  `:notify` (when set) and returns `{:ok, "ns=<inspect of :memory_namespace>"}`;
  run without context (`BaseTool.run/1`) it returns the "requires tool context" error.
  """
  defstruct name: "probe", notify: nil

  defimpl Normandy.Tools.BaseTool do
    def tool_name(tool), do: tool.name
    def tool_description(_tool), do: "context probe"
    def input_schema(_tool), do: %{type: "object", properties: %{}}

    def run(tool),
      do: {:error, "#{tool.name} requires tool context; it was called outside the dispatch pipeline"}
  end

  defimpl Normandy.Tools.ContextualTool do
    def run(tool, ctx) do
      if tool.notify, do: send(tool.notify, {:probe_ctx, ctx})
      {:ok, "ns=" <> inspect(Map.get(ctx.values, :memory_namespace))}
    end
  end
end
```

`test/tools/context_test.exs`:

```elixir
defmodule Normandy.Tools.ContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.{AgentMemory, ToolCall}
  alias Normandy.Test.{ContextProbe, FakeTool}
  alias Normandy.Tools.{Context, Executor, Registry}

  defp ctx(values \\ %{memory_namespace: "acme/u-1"}),
    do: %Context{tool_call_id: "c1", values: values}

  describe "Context.build/2" do
    test "takes ids from the config and the call, and values from tool_context" do
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
               values: %{memory_namespace: "acme/u-1"}
             } = Context.build(config, %ToolCall{id: "call-9", name: "probe", input: %{}})
    end

    test "a partial config gives nil ids and empty values" do
      assert %Context{session_id: nil, agent_name: nil, turn_id: nil, values: %{}} =
               Context.build(%{}, %ToolCall{id: "c", name: "probe", input: %{}})
    end
  end

  describe "Executor with context:" do
    test "a contextual tool gets the context" do
      assert {:ok, ~s(ns="acme/u-1")} =
               Executor.execute_tool(%ContextProbe{notify: self()}, context: ctx())

      assert_receive {:probe_ctx, %Context{tool_call_id: "c1"}}
    end

    test "a contextual tool without context returns its error" do
      assert {{:error, "probe requires tool context; it was called outside the dispatch pipeline"},
              :tool_error} = Executor.execute_tool_classified(%ContextProbe{})
    end

    test "a plain tool ignores the context" do
      assert {:ok, "weather in Oslo"} =
               Executor.execute_tool(%FakeTool{city: "Oslo"}, context: ctx())
    end

    test "execute/3 and execute_parallel/3 forward the context" do
      registry = Registry.new([%ContextProbe{notify: self()}])
      assert {:ok, _} = Executor.execute(registry, "probe", context: ctx())
      assert_receive {:probe_ctx, _}

      assert [{:ok, _}] =
               Executor.execute_parallel(registry, [{"p", %ContextProbe{}}], context: ctx())
    end
  end
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix format && mix test test/tools/context_test.exs`
Expected: compile error, `Normandy.Tools.Context.__struct__/1 is undefined` (or "protocol Normandy.Tools.ContextualTool not defined").

- [ ] **Step 3: Implement `Context` and `ContextualTool`**

`lib/normandy/tools/context.ex`:

```elixir
defmodule Normandy.Tools.Context do
  @moduledoc """
  What a `Normandy.Tools.ContextualTool` knows about the call it serves.

  Built per tool call by the dispatch pipeline (`build/2`) from the agent config and the
  `%ToolCall{}`. `values` is the config's `tool_context`: plain data the application sets
  per session (for example `%{memory_namespace: "acme/user-42"}`). It is persisted in the
  session's config template, so it must hold no secrets; resolve secrets through
  `Normandy.Behaviours.CredentialProvider`, keyed by a value from here.

  The model never sees or sets any of this: the context lives outside the tool struct.
  """

  alias Normandy.Components.ToolCall

  @enforce_keys [:tool_call_id]
  defstruct [:session_id, :agent_name, :turn_id, :tool_call_id, values: %{}]

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          agent_name: String.t() | nil,
          turn_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          values: map()
        }

  @doc "Builds the context for `call` from `config` (a `%BaseAgentConfig{}` or a partial map)."
  @spec build(map(), ToolCall.t()) :: t()
  def build(config, %ToolCall{} = call) do
    memory = Map.get(config, :memory)

    %__MODULE__{
      session_id: Map.get(config, :session_id),
      agent_name: Map.get(config, :name),
      turn_id: memory && Map.get(memory, :current_turn_id),
      tool_call_id: call.id,
      values: Map.get(config, :tool_context) || %{}
    }
  end
end
```

`lib/normandy/tools/contextual_tool.ex`:

```elixir
defprotocol Normandy.Tools.ContextualTool do
  @moduledoc """
  Opt-in protocol for tools that need to know whom they run for.

  A contextual tool still implements `Normandy.Tools.BaseTool` (name, description, input
  schema). The executor calls `run/2` instead of `BaseTool.run/1` when it has a
  `%Normandy.Tools.Context{}`; the dispatch pipeline always passes one. Its
  `BaseTool.run/1` should return
  `{:error, "<name> requires tool context; it was called outside the dispatch pipeline"}`
  so a caller that bypasses dispatch fails visibly.
  """

  @spec run(struct(), Normandy.Tools.Context.t()) :: {:ok, term()} | {:error, String.t()}
  def run(tool, ctx)
end
```

- [ ] **Step 4: Thread `context:` through the Executor**

In `lib/normandy/tools/executor.ex`:

1. Add aliases `Normandy.Tools.Context` and `Normandy.Tools.ContextualTool`.
2. Extend `execution_options`: `context: Context.t()`.
3. Document `:context` in the `execute/3` options list: "a `%Normandy.Tools.Context{}`; a `Normandy.Tools.ContextualTool` runs with it".
4. Thread the context into every entry point:

```elixir
  def execute(registry, tool_name, opts \\ []) do
    max_retries = max_retries!(opts)

    case Registry.get(registry, tool_name) do
      {:ok, tool} ->
        execute_with_retries(tool, max_retries, timeout!(opts, tool), opts[:context])

      :error ->
        {:error, "Tool '#{tool_name}' not found in registry"}
    end
  end
```

```elixir
  def execute_tool_classified(tool, opts \\ []) do
    execute_with_timeout(tool, timeout!(opts, tool), opts[:context])
  end
```

In `execute_parallel/3`, inside the `Task.async`:

```elixir
        execute_with_retries(tool, max_retries, timeout, opts[:context])
```

Then change the private helpers:

```elixir
  defp execute_with_retries(tool, retries_left, timeout, context) do
    {result, _error_type} = execute_with_timeout(tool, timeout, context)

    case result do
      {:ok, result} ->
        {:ok, result}

      {:error, _reason} when retries_left > 0 ->
        execute_with_retries(tool, retries_left - 1, timeout, context)

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_with_timeout(tool, timeout, context) do
    parent_ctx = OtelCtx.capture()

    task =
      Task.async(fn ->
        OtelCtx.restore(parent_ctx)

        try do
          tool |> run_tool(context) |> check_result()
        rescue
          # (unchanged rescue/catch clauses)
```

Add:

```elixir
  # A contextual tool runs with the context when there is one; without it, its own
  # BaseTool.run/1 reports that it needs one.
  defp run_tool(tool, %Context{} = context) do
    if ContextualTool.impl_for(tool),
      do: ContextualTool.run(tool, context),
      else: BaseTool.run(tool)
  end

  defp run_tool(tool, nil), do: BaseTool.run(tool)
```

`execute_sequential/3` already passes `opts` to `execute/3`, so it needs no change.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `mix format && mix test test/tools/context_test.exs test/tools`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/tools/context.ex lib/normandy/tools/contextual_tool.ex lib/normandy/tools/executor.ex test/support/context_probe.ex test/tools/context_test.exs
git commit -m "feat(tools): tool context struct, ContextualTool protocol, executor context option"
```

---

### Task 2: Carry `tool_context` through config, template and every pipeline

**Files:**
- Modify: `lib/normandy/agents/base_agent_config.ex`
- Modify: `lib/normandy/agents/base_agent.ex` (`init/1` at ~:131, `span_execute/4` at ~:1812)
- Modify: `lib/normandy/agents/config_template.ex` (`@data_fields`)
- Modify: `lib/normandy/agents/dispatch.ex` (`default_pipeline/0` at :82-93)
- Modify: `lib/normandy/behaviours/config.ex` (`to_pipeline/1` at :80)
- Create: `test/support/scripted_tool_client.ex`
- Test: `test/agents/tool_context_test.exs`
- Test: `test/agents/config_template_test.exs` (add cases)

**Interfaces:**
- Consumes: `Context.build/2`, `ContextProbe`, the Executor `context:` option (Task 1).
- Produces:
  - `BaseAgentConfig.tool_context :: map()`, default `%{}`.
  - `BaseAgent.init/1` accepts `:tool_context` (a map; anything else raises `ArgumentError`).
  - Every built-in `execute_fn` takes four arguments and passes `context: Context.build(config, call)`.
  - The test client `%Normandy.Test.ScriptedToolClient{calls: [%ToolCall{}]}`.

- [ ] **Step 1: Write the scripted client**

`test/support/scripted_tool_client.ex`:

```elixir
defmodule Normandy.Test.ScriptedToolClient do
  @moduledoc """
  A model client for tests. While the conversation holds no tool result it answers with
  `:calls` as tool calls; once one is present it returns the response model unchanged.
  One tool round per conversation.
  """
  defstruct calls: [], options: %{}

  defimpl Normandy.Agents.Model do
    alias Normandy.Agents.ToolCallResponse

    def completitions(_client, _model, _temperature, _max_tokens, _messages, response_model),
      do: response_model

    def converse(client, _model, _temperature, _max_tokens, messages, response_model, _opts) do
      if Enum.any?(messages, &(Map.get(&1, :role) == "tool")),
        do: response_model,
        else: %ToolCallResponse{content: nil, tool_calls: client.calls}
    end
  end
end
```

- [ ] **Step 2: Write the failing tests**

`test/agents/tool_context_test.exs`:

```elixir
defmodule Normandy.Agents.ToolContextTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.{BaseAgent, Dispatch}
  alias Normandy.Components.{ToolCall, ToolResult}
  alias Normandy.Test.{ContextProbe, ScriptedToolClient}
  alias Normandy.Tools.{Context, Executor, Registry}

  defp probe_call, do: %ToolCall{id: "call_1", name: "probe", input: %{}}

  defp agent(extra \\ %{}) do
    %{client: %ScriptedToolClient{calls: [probe_call()]}, model: "test", name: "ctx-agent"}
    |> Map.merge(extra)
    |> BaseAgent.init()
    |> BaseAgent.register_tool(%ContextProbe{notify: self()})
  end

  test "init/1 defaults tool_context to %{} and rejects a non-map" do
    assert agent().tool_context == %{}

    assert_raise ArgumentError, ~r/tool_context must be a map/, fn ->
      BaseAgent.init(%{client: %ScriptedToolClient{}, model: "test", tool_context: [a: 1]})
    end
  end

  test "a BaseAgent turn hands the contextual tool the session's context" do
    config = agent(%{tool_context: %{memory_namespace: "acme/u-1"}})

    {_config, _response} = BaseAgent.run_with_tools(config, %{chat_message: "go"})

    assert_receive {:probe_ctx,
                    %Context{
                      tool_call_id: "call_1",
                      agent_name: "ctx-agent",
                      values: %{memory_namespace: "acme/u-1"}
                    } = ctx}

    assert is_binary(ctx.turn_id)
  end

  test "base_agent_pipeline/1 (used by every interpreter) passes the context" do
    config = agent(%{tool_context: %{memory_namespace: "acme/u-2"}})

    assert %ToolResult{is_error: false, output: ~s(ns="acme/u-2")} =
             Dispatch.dispatch_one(config, probe_call(), BaseAgent.base_agent_pipeline(config))
  end

  test "default_pipeline/0 passes the context" do
    config = %{name: "a", tool_registry: Registry.new([%ContextProbe{}]), tool_context: %{memory_namespace: "n"}}

    assert %ToolResult{is_error: false, output: ~s(ns="n")} =
             Dispatch.dispatch_one(config, probe_call(), Dispatch.default_pipeline())
  end

  test "a user arity-3 execute_fn has no call, so a contextual tool returns its error" do
    config = %{name: "a", tool_registry: Registry.new([%ContextProbe{}])}

    pipeline = %{
      Dispatch.default_pipeline()
      | execute_fn: fn _config, tool, _name -> Executor.execute_tool(tool) end
    }

    assert %ToolResult{is_error: true, output: %{error: msg}} =
             Dispatch.dispatch_one(config, probe_call(), pipeline)

    assert msg =~ "requires tool context"
  end
end
```

Add these to `test/agents/config_template_test.exs`, inside the `describe` that defines `full_config/1`. Also add `tool_context: %{memory_namespace: "acme/u-1"}` to the `full_config/1` struct literal, so the existing "rebuild(from_config(c)) gives back c" test covers the field.

```elixir
    test "tool_context travels in the template" do
      supp = round_trip_supplement()
      config = %{full_config(supp) | tool_context: %{memory_namespace: "acme/u-7"}}

      tmpl = ConfigTemplate.from_config(config, "t")

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").tool_context ==
               %{memory_namespace: "acme/u-7"}
    end

    test "a template saved before tool_context existed rebuilds with %{}" do
      supp = round_trip_supplement()
      tmpl = full_config(supp) |> ConfigTemplate.from_config("t") |> Map.delete(:tool_context)

      assert ConfigTemplate.rebuild(tmpl, supp, "TOKEN").tool_context == %{}
    end

    test "from_config refuses a pid in tool_context" do
      config = %{full_config(round_trip_supplement()) | tool_context: %{owner: self()}}

      assert_raise ArgumentError, ~r/:tool_context/, fn ->
        ConfigTemplate.from_config(config, "t")
      end
    end
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `mix format && mix test test/agents/tool_context_test.exs test/agents/config_template_test.exs`
Expected: FAIL. `BaseAgentConfig` has no `:tool_context` (KeyError, or "unknown key :tool_context").

- [ ] **Step 4: Add the field, the init option and the template field**

`lib/normandy/agents/base_agent_config.ex`: add `tool_context: map()` to `@type t`, and add a field after `session_id`:

```elixir
    field(:session_id, :string, default: nil)
    field(:tool_context, :map, default: %{})
```

`lib/normandy/agents/base_agent.ex`, `init/1`: first, next to the other guardrail checks before the circuit breaker starts, validate the value:

```elixir
    tool_context = Map.get(config, :tool_context, %{})

    unless is_map(tool_context) do
      raise ArgumentError,
            "tool_context must be a map of plain data, got: #{inspect(tool_context)}"
    end
```

Then add `tool_context: tool_context,` to the `%BaseAgentConfig{}` literal, after `session_id:`.

`lib/normandy/agents/config_template.ex`: append `:tool_context` to `@data_fields`. Then add `tool_context` to the moduledoc's "Everything else travels in the template" list, with: "`tool_context` must hold no secrets: the template is stored in plaintext."

- [ ] **Step 5: Make every built-in `execute_fn` pass the context**

In `lib/normandy/agents/base_agent.ex`, `span_execute/4`, change the executor call:

```elixir
      {r, error_type} =
        Executor.execute_tool_classified(prepared_tool, context: Context.build(config, call))
```

Add `alias Normandy.Tools.Context` to BaseAgent's aliases.

In `lib/normandy/agents/dispatch.ex`, `default_pipeline/0`:

```elixir
      execute_fn: fn config, tool, _name, call ->
        Executor.execute_tool(tool, context: Context.build(config, call))
      end,
```

Add `alias Normandy.Tools.Context`. Then update the `default_pipeline/0` doc to say: "the bare executor, passing the call's `%Normandy.Tools.Context{}`".

In `lib/normandy/behaviours/config.ex`, `to_pipeline/1`, make the same change with the same alias:

```elixir
      execute_fn: fn config, tool, _name, call ->
        Executor.execute_tool(tool, context: Context.build(config, call))
      end
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `mix format && mix test test/agents/tool_context_test.exs test/agents/config_template_test.exs test/agents/dispatch_test.exs test/telemetry/tool_telemetry_test.exs`
Expected: all pass.

- [ ] **Step 7: Write the rehydration regression test (Review Focus #1)**

Append to `test/agents/turn/session_test.exs` (it already aliases `BaseAgent`, `Turn`, `Catalog`, `Native`, `InMemory` and `AgentMemory`):

```elixir
  describe "tool context after rehydration" do
    alias Normandy.Components.ToolCall
    alias Normandy.Test.{ContextProbe, TurnConfig}
    alias Normandy.Tools.Context

    # First LLM call of a turn asks for the probe; once a tool result is the last
    # message, it answers.
    defp probe_handlers do
      %{
        BaseAgent.non_streaming_handlers()
        | call_llm: fn c, _s, _r ->
            case c.memory |> AgentMemory.messages() |> List.last() do
              %{role: "tool"} ->
                %TurnConfig.Resp{content: "done"}

              _ ->
                id = "call-#{System.unique_integer([:positive])}"
                %TurnConfig.Resp{content: "", tool_calls: [%ToolCall{id: id, name: "probe", input: %{}}]}
            end
          end
      }
    end

    defp fresh_node_opts(base) do
      {:ok, sup} = Turn.Supervisor.start_link([])

      base
      |> Keyword.delete(:config)
      |> Keyword.put(:supervisor, sup)
      |> Keyword.put(:registry, {Native, Native.new()})
    end

    test "two sessions of one template keep their own tool_context on a fresh node" do
      store = InMemory.new()
      {:ok, cat} = Catalog.start_link([])
      {:ok, sup} = Turn.Supervisor.start_link([])
      reg = Native.new()

      :ok =
        Catalog.put(cat, "mem-kind", %{
          tool_registry: Normandy.Tools.Registry.new([%ContextProbe{notify: self()}]),
          before_hooks: [],
          after_hooks: [],
          client_builder: fn _token -> %{api_key: "k"} end
        })

      base = fn sid, ns ->
        [
          session_id: sid,
          config: %{TurnConfig.build() | tool_context: %{memory_namespace: ns}},
          store: {InMemory, store},
          registry: {Native, reg},
          supervisor: sup,
          template_provider: {Catalog, cat},
          template_id: "mem-kind",
          handlers: probe_handlers()
        ]
      end

      sid_a = "ctx-a-#{System.unique_integer([:positive])}"
      sid_b = "ctx-b-#{System.unique_integer([:positive])}"

      assert {:ok, _} = Turn.Session.run(base.(sid_a, "acme/a"), "hi")
      assert_receive {:probe_ctx, %Context{session_id: ^sid_a, values: %{memory_namespace: "acme/a"}}}, 2000
      assert {:ok, _} = Turn.Session.run(base.(sid_b, "acme/b"), "hi")
      assert_receive {:probe_ctx, %Context{session_id: ^sid_b, values: %{memory_namespace: "acme/b"}}}, 2000

      # A fresh supervisor and registry: no live server, so each session is rebuilt from
      # its stored template + the shared supplement, as on another node.
      assert {:ok, _} = Turn.Session.run(fresh_node_opts(base.(sid_a, "ignored")), "again")
      assert_receive {:probe_ctx, %Context{session_id: ^sid_a, values: %{memory_namespace: "acme/a"}}}, 2000
      assert {:ok, _} = Turn.Session.run(fresh_node_opts(base.(sid_b, "ignored")), "again")
      assert_receive {:probe_ctx, %Context{session_id: ^sid_b, values: %{memory_namespace: "acme/b"}}}, 2000
    end
  end
```

- [ ] **Step 8: Run it and the whole suite**

Run: `mix format && mix test test/agents/turn/session_test.exs && mix test`
Expected: PASS, 0 failures.

**If the session test fails:**
- A `:no_config_template` error means the template is saved under a different key. Read `session.ex:107-140` before changing anything.
- A namespace of `"ignored"` means the template was overwritten: Session re-saves when it is given a `:config`. `fresh_node_opts/1` must drop `:config`.

Either way, stop and report under RULE 0. Do not loosen the assertion.

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/agents/base_agent_config.ex lib/normandy/agents/base_agent.ex lib/normandy/agents/config_template.ex lib/normandy/agents/dispatch.ex lib/normandy/behaviours/config.ex test/support/scripted_tool_client.ex test/agents/tool_context_test.exs test/agents/config_template_test.exs test/agents/turn/session_test.exs
git commit -m "feat(agents): tool_context on BaseAgentConfig, carried in templates and passed by every pipeline"
```

---

### Task 3: `MemoryStore` behaviour, pure `Docs`, InMemory backend, shared contract

**Files:**
- Create: `lib/normandy/behaviours/memory_store.ex`
- Create: `lib/normandy/behaviours/memory_store/docs.ex`
- Create: `lib/normandy/behaviours/memory_store/in_memory.ex`
- Create: `test/support/memory_store_contract.ex`
- Test: `test/behaviours/memory_store/in_memory_test.exs`
- Test: `test/behaviours/memory_store/docs_test.exs`

**Interfaces:**
- Produces:
  - The behaviour `Normandy.Behaviours.MemoryStore`, with these callbacks:
    - `list/3 :: {:ok, [%{path, size, updated_at}]} | {:error, term}`
    - `get/3 :: {:ok, %{content, version}} | :not_found | {:error, term}`
    - `put/5`, taking `expected :: pos_integer | :new | :any`, `:: {:ok, version} | {:error, :conflict} | {:error, term}`
    - `delete/4 :: :ok | :not_found | {:error, :conflict} | {:error, term}`
    - `delete_tree/3 :: {:ok, non_neg_integer} | {:error, term}`
    - `rename/4 :: {:ok, pos_integer} | :not_found | {:error, :exists} | {:error, term}`
    - `delete_namespace/2 :: :ok | {:error, term}`
  - Helpers: `MemoryStore.list_limit/0` (1000), `at_or_under?/2`, `under?/2`, `reparent/3`.
  - `MemoryStore.Docs`: pure functions over `%{path => %{content, version, updated_at}}`. Each write returns `{reply, docs}`.
  - `MemoryStore.InMemory.new/0` returns a pid handle.
  - `use Normandy.MemoryStoreContract, impl: Mod`. The impl must export `new/0` returning a bare handle.

- [ ] **Step 1: Write the contract (it will be the failing test)**

`test/support/memory_store_contract.ex`:

```elixir
defmodule Normandy.MemoryStoreContract do
  @moduledoc """
  Shared ExUnit contract for `Normandy.Behaviours.MemoryStore` impls:

      use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.InMemory

  The impl exports `new/0` returning the bare handle. Each test uses its own namespace,
  so impls with a shared backing store (Postgres, Redis) stay isolated.
  """

  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)

    quote bind_quoted: [impl: impl] do
      alias Normandy.Behaviours.MemoryStore

      @store impl

      setup do
        {:ok, handle: @store.new(), ns: "contract-#{System.unique_integer([:positive])}"}
      end

      test "get on a missing document is :not_found", %{handle: h, ns: ns} do
        assert :not_found = @store.get(h, ns, "/memories/a.md")
      end

      test "put :new creates version 1; a second :new conflicts", %{handle: h, ns: ns} do
        assert {:ok, 1} = @store.put(h, ns, "/memories/a.md", "one", :new)
        assert {:error, :conflict} = @store.put(h, ns, "/memories/a.md", "two", :new)
        assert {:ok, %{content: "one", version: 1}} = @store.get(h, ns, "/memories/a.md")
      end

      test "put with the current version bumps it; a stale version conflicts", %{handle: h, ns: ns} do
        {:ok, 1} = @store.put(h, ns, "/memories/a.md", "one", :new)
        assert {:ok, 2} = @store.put(h, ns, "/memories/a.md", "two", 1)
        assert {:error, :conflict} = @store.put(h, ns, "/memories/a.md", "three", 1)
        assert {:ok, %{content: "two", version: 2}} = @store.get(h, ns, "/memories/a.md")
      end

      test "put with a version on a missing document conflicts", %{handle: h, ns: ns} do
        assert {:error, :conflict} = @store.put(h, ns, "/memories/a.md", "x", 3)
      end

      test "put :any creates or overwrites, bumping the version", %{handle: h, ns: ns} do
        assert {:ok, 1} = @store.put(h, ns, "/memories/a.md", "one", :any)
        assert {:ok, 2} = @store.put(h, ns, "/memories/a.md", "two", :any)
      end

      test "content round-trips UTF-8 and newlines exactly", %{handle: h, ns: ns} do
        text = "línea 1\n日本語\n\nend\n"
        {:ok, _} = @store.put(h, ns, "/memories/u.md", text, :new)
        assert {:ok, %{content: ^text}} = @store.get(h, ns, "/memories/u.md")
      end

      test "list returns documents at or under the prefix, sorted, with sizes", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/b/2.md", "22", :new)
        {:ok, _} = @store.put(h, ns, "/memories/b/1.md", "1", :new)
        {:ok, _} = @store.put(h, ns, "/memories/bb.md", "x", :new)
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "aaa", :new)

        assert {:ok, entries} = @store.list(h, ns, "/memories/b")
        assert Enum.map(entries, &{&1.path, &1.size}) == [{"/memories/b/1.md", 1}, {"/memories/b/2.md", 2}]
        assert Enum.all?(entries, &match?(%DateTime{}, &1.updated_at))

        assert {:ok, all} = @store.list(h, ns, "/memories")
        assert Enum.map(all, & &1.path) ==
                 ["/memories/a.md", "/memories/b/1.md", "/memories/b/2.md", "/memories/bb.md"]
      end

      test "list includes the prefix itself when it is a document", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a", "file", :new)
        assert {:ok, [%{path: "/memories/a"}]} = @store.list(h, ns, "/memories/a")
      end

      test "updated_at moves forward on write", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/t.md", "1", :new)
        {:ok, [%{updated_at: t1}]} = @store.list(h, ns, "/memories/t.md")
        Process.sleep(5)
        {:ok, _} = @store.put(h, ns, "/memories/t.md", "2", :any)
        {:ok, [%{updated_at: t2}]} = @store.list(h, ns, "/memories/t.md")
        assert DateTime.compare(t2, t1) == :gt
      end

      test "list stops at list_limit/0 entries", %{handle: h, ns: ns} do
        limit = MemoryStore.list_limit()

        for i <- 1..(limit + 1) do
          {:ok, _} = @store.put(h, ns, "/memories/f#{String.pad_leading("#{i}", 5, "0")}", "x", :new)
        end

        assert {:ok, entries} = @store.list(h, ns, "/memories")
        assert length(entries) == limit
      end

      test "namespaces are isolated", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "mine", :new)
        assert :not_found = @store.get(h, ns <> "-other", "/memories/a.md")
        assert {:ok, []} = @store.list(h, ns <> "-other", "/memories")
      end

      test "delete :any removes; a missing path is :not_found", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "x", :new)
        assert :ok = @store.delete(h, ns, "/memories/a.md", :any)
        assert :not_found = @store.delete(h, ns, "/memories/a.md", :any)
      end

      test "delete with a stale version conflicts and keeps the document", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "x", :new)
        {:ok, 2} = @store.put(h, ns, "/memories/a.md", "y", 1)
        assert {:error, :conflict} = @store.delete(h, ns, "/memories/a.md", 1)
        assert :ok = @store.delete(h, ns, "/memories/a.md", 2)
      end

      test "delete_tree removes the prefix and everything under it", %{handle: h, ns: ns} do
        for p <- ["/memories/d", "/memories/d/1", "/memories/d/e/2", "/memories/dd"] do
          {:ok, _} = @store.put(h, ns, p, "x", :new)
        end

        assert {:ok, 3} = @store.delete_tree(h, ns, "/memories/d")
        assert {:ok, [%{path: "/memories/dd"}]} = @store.list(h, ns, "/memories")
        assert {:ok, 0} = @store.delete_tree(h, ns, "/memories/nothing")
      end

      test "rename moves a document and keeps its version", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "x", :new)
        {:ok, 2} = @store.put(h, ns, "/memories/a.md", "y", 1)
        assert {:ok, 1} = @store.rename(h, ns, "/memories/a.md", "/memories/b.md")
        assert :not_found = @store.get(h, ns, "/memories/a.md")
        assert {:ok, %{content: "y", version: 2}} = @store.get(h, ns, "/memories/b.md")
      end

      test "rename of a directory moves every document under it", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/d/1", "1", :new)
        {:ok, _} = @store.put(h, ns, "/memories/d/e/2", "2", :new)
        {:ok, _} = @store.put(h, ns, "/memories/dd", "keep", :new)

        assert {:ok, 2} = @store.rename(h, ns, "/memories/d", "/memories/z")
        assert {:ok, all} = @store.list(h, ns, "/memories")
        assert Enum.map(all, & &1.path) == ["/memories/dd", "/memories/z/1", "/memories/z/e/2"]
      end

      test "rename onto an existing document or non-empty directory is {:error, :exists}", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a", "a", :new)
        {:ok, _} = @store.put(h, ns, "/memories/b", "b", :new)
        {:ok, _} = @store.put(h, ns, "/memories/dir/x", "x", :new)

        assert {:error, :exists} = @store.rename(h, ns, "/memories/a", "/memories/b")
        assert {:error, :exists} = @store.rename(h, ns, "/memories/a", "/memories/dir")
        assert {:ok, %{content: "a"}} = @store.get(h, ns, "/memories/a")
      end

      test "rename of a missing path is :not_found", %{handle: h, ns: ns} do
        assert :not_found = @store.rename(h, ns, "/memories/nope", "/memories/x")
      end

      test "delete_namespace removes everything and is idempotent", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a", "a", :new)
        {:ok, _} = @store.put(h, ns <> "-keep", "/memories/a", "a", :new)
        assert :ok = @store.delete_namespace(h, ns)
        assert {:ok, []} = @store.list(h, ns, "/memories")
        assert {:ok, [_]} = @store.list(h, ns <> "-keep", "/memories")
        assert :ok = @store.delete_namespace(h, "never-used")
      end

      # Review Focus #3: the concurrency tests run through the memory tool, which
      # does not exist yet; Task 10, Step 5 replaces this comment with them.
    end
  end
end
```

`test/behaviours/memory_store/in_memory_test.exs`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.InMemoryTest do
  use ExUnit.Case, async: true
  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.InMemory
end
```

`test/behaviours/memory_store/docs_test.exs`. This holds the helpers' edge cases:

```elixir
defmodule Normandy.Behaviours.MemoryStore.DocsTest do
  use ExUnit.Case, async: true
  alias Normandy.Behaviours.MemoryStore

  test "at_or_under?/2 matches on a / boundary only" do
    assert MemoryStore.at_or_under?("/memories/a", "/memories/a")
    assert MemoryStore.at_or_under?("/memories/a/b", "/memories/a")
    refute MemoryStore.at_or_under?("/memories/ab", "/memories/a")
  end

  test "reparent/3 swaps the prefix" do
    assert MemoryStore.reparent("/memories/d/e/2", "/memories/d", "/memories/z") == "/memories/z/e/2"
  end
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix format && mix test test/behaviours/memory_store`
Expected: compile error, `Normandy.Behaviours.MemoryStore.InMemory` undefined.

- [ ] **Step 3: Implement the behaviour, `Docs` and InMemory**

`lib/normandy/behaviours/memory_store.ex`:

```elixir
defmodule Normandy.Behaviours.MemoryStore do
  @moduledoc """
  Contract for agent long-term memory: path-addressed UTF-8 documents grouped in
  namespaces, with optimistic versioning.

  A namespace is an opaque string the application chooses (per user, per tenant, per
  agent: Normandy gives it no meaning). Paths are validated by `Normandy.Tools.Memory`
  before they reach a store. Directories exist only as path prefixes.

  Semantics every impl must pass (`Normandy.MemoryStoreContract`):

    * A missing document is `:not_found`, a value. A backend failure (timeout, lost
      connection, aborted transaction) is always `{:error, reason}`, so a timeout is never
      read as "no memory yet".
    * Versions count per document from 1. `put(…, :new)` conflicts when the path exists;
      `put(…, v)` conflicts unless the stored version is `v`; `put(…, :any)` always writes.
    * `list/3` and `delete_tree/3` match the prefix itself or on a `/` boundary, so
      `/memories/a` never matches `/memories/ab`. `list/3` returns at most `list_limit/0`
      entries, sorted by path (byte order).
    * `rename/4` is atomic: a document at `from` moves alone; otherwise every document
      under `from/` moves, keeping relative paths and versions. `{:error, :exists}` when
      `to` is a document or has documents under it.
    * `delete_tree/3` and `delete_namespace/2` are atomic; `delete_namespace/2` is
      idempotent and exists for erasure (the memory tool never calls it).
  """

  @type handle :: term()
  @type namespace :: String.t()
  @type path :: String.t()
  @type version :: pos_integer()
  @type entry :: %{path: path(), size: non_neg_integer(), updated_at: DateTime.t()}

  @callback list(handle(), namespace(), prefix :: path()) :: {:ok, [entry()]} | {:error, term()}
  @callback get(handle(), namespace(), path()) ::
              {:ok, %{content: String.t(), version: version()}} | :not_found | {:error, term()}
  @callback put(handle(), namespace(), path(), content :: String.t(), version() | :new | :any) ::
              {:ok, version()} | {:error, :conflict} | {:error, term()}
  @callback delete(handle(), namespace(), path(), version() | :any) ::
              :ok | :not_found | {:error, :conflict} | {:error, term()}
  @callback delete_tree(handle(), namespace(), prefix :: path()) ::
              {:ok, non_neg_integer()} | {:error, term()}
  @callback rename(handle(), namespace(), from :: path(), to :: path()) ::
              {:ok, pos_integer()} | :not_found | {:error, :exists} | {:error, term()}
  @callback delete_namespace(handle(), namespace()) :: :ok | {:error, term()}

  @list_limit 1000

  @doc "The most entries `list/3` returns."
  @spec list_limit() :: pos_integer()
  def list_limit, do: @list_limit

  @doc "True when `path` is `prefix` or lies below it on a `/` boundary."
  @spec at_or_under?(path(), path()) :: boolean()
  def at_or_under?(path, prefix), do: path == prefix or under?(path, prefix)

  @doc "True when `path` lies strictly below `prefix` on a `/` boundary."
  @spec under?(path(), path()) :: boolean()
  def under?(path, prefix), do: String.starts_with?(path, prefix <> "/")

  @doc "Moves `path` from below `from` to the same place below `to`."
  @spec reparent(path(), path(), path()) :: path()
  def reparent(path, from, to), do: to <> String.replace_prefix(path, from, "")
end
```

`lib/normandy/behaviours/memory_store/docs.ex`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.Docs do
  @moduledoc false
  # Pure operations on one namespace's documents, `%{path => %{content, version,
  # updated_at}}`. InMemory, ETS and Mnesia run these inside their single serialized
  # writer (an Agent call, the ETS owner, a Mnesia transaction), which makes each atomic.
  # Every write returns `{reply, docs}`.

  alias Normandy.Behaviours.MemoryStore

  def list(docs, prefix) do
    docs
    |> Enum.filter(fn {path, _} -> MemoryStore.at_or_under?(path, prefix) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(MemoryStore.list_limit())
    |> Enum.map(fn {path, d} ->
      %{path: path, size: byte_size(d.content), updated_at: d.updated_at}
    end)
  end

  def get(docs, path) do
    case Map.fetch(docs, path) do
      {:ok, d} -> {:ok, %{content: d.content, version: d.version}}
      :error -> :not_found
    end
  end

  def put(docs, path, content, expected) do
    case {Map.get(docs, path), expected} do
      {nil, e} when e in [:new, :any] -> write(docs, path, content, 1)
      {%{version: v}, :any} -> write(docs, path, content, v + 1)
      {%{version: v}, v} -> write(docs, path, content, v + 1)
      _ -> {{:error, :conflict}, docs}
    end
  end

  def delete(docs, path, expected) do
    case {Map.get(docs, path), expected} do
      {nil, _} -> {:not_found, docs}
      {_, :any} -> {:ok, Map.delete(docs, path)}
      {%{version: v}, v} -> {:ok, Map.delete(docs, path)}
      _ -> {{:error, :conflict}, docs}
    end
  end

  def delete_tree(docs, prefix) do
    {gone, kept} = Map.split_with(docs, fn {path, _} -> MemoryStore.at_or_under?(path, prefix) end)
    {{:ok, map_size(gone)}, kept}
  end

  def rename(docs, from, to) do
    moving =
      if Map.has_key?(docs, from),
        do: [from],
        else: docs |> Map.keys() |> Enum.filter(&MemoryStore.under?(&1, from))

    cond do
      moving == [] ->
        {:not_found, docs}

      Enum.any?(Map.keys(docs), &MemoryStore.at_or_under?(&1, to)) ->
        {{:error, :exists}, docs}

      true ->
        moved = Map.new(moving, &{MemoryStore.reparent(&1, from, to), Map.fetch!(docs, &1)})
        {{:ok, length(moving)}, docs |> Map.drop(moving) |> Map.merge(moved)}
    end
  end

  defp write(docs, path, content, version) do
    doc = %{content: content, version: version, updated_at: DateTime.utc_now()}
    {{:ok, version}, Map.put(docs, path, doc)}
  end
end
```

`lib/normandy/behaviours/memory_store/in_memory.ex`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.InMemory do
  @moduledoc """
  Process-backed in-memory `MemoryStore`, for tests and single-node runs. One `Agent`
  holds every namespace; each operation is one Agent call, so it is atomic. The handle
  is the pid.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  alias Normandy.Behaviours.MemoryStore.Docs

  @doc "Starts a fresh store and returns its handle (a pid)."
  @spec new(keyword()) :: pid()
  def new(_opts \\ []) do
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    pid
  end

  @impl true
  def list(pid, ns, prefix), do: {:ok, Agent.get(pid, &Docs.list(Map.get(&1, ns, %{}), prefix))}

  @impl true
  def get(pid, ns, path), do: Agent.get(pid, &Docs.get(Map.get(&1, ns, %{}), path))

  @impl true
  def put(pid, ns, path, content, expected),
    do: update(pid, ns, &Docs.put(&1, path, content, expected))

  @impl true
  def delete(pid, ns, path, expected), do: update(pid, ns, &Docs.delete(&1, path, expected))

  @impl true
  def delete_tree(pid, ns, prefix), do: update(pid, ns, &Docs.delete_tree(&1, prefix))

  @impl true
  def rename(pid, ns, from, to), do: update(pid, ns, &Docs.rename(&1, from, to))

  @impl true
  def delete_namespace(pid, ns), do: Agent.update(pid, &Map.delete(&1, ns))

  defp update(pid, ns, fun) do
    Agent.get_and_update(pid, fn state ->
      {reply, docs} = fun.(Map.get(state, ns, %{}))
      {reply, if(docs == %{}, do: Map.delete(state, ns), else: Map.put(state, ns, docs))}
    end)
  end
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix format && mix test test/behaviours/memory_store`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/memory_store.ex lib/normandy/behaviours/memory_store/docs.ex lib/normandy/behaviours/memory_store/in_memory.ex test/support/memory_store_contract.ex test/behaviours/memory_store/in_memory_test.exs test/behaviours/memory_store/docs_test.exs
git commit -m "feat(memory): MemoryStore behaviour, contract and InMemory backend"
```

---

### Task 4: ETS backend

**Files:**
- Create: `lib/normandy/behaviours/memory_store/ets.ex`
- Test: `test/behaviours/memory_store/ets_test.exs`

**Interfaces:**
- Consumes: `MemoryStore.Docs` (Task 3).
- Produces: `MemoryStore.ETS.new/0 :: {pid, :ets.tid()}`, the handle.

- [ ] **Step 1: Write the failing test**

`test/behaviours/memory_store/ets_test.exs`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.ETSTest do
  use ExUnit.Case, async: true
  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.ETS
end
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix format && mix test test/behaviours/memory_store/ets_test.exs`
Expected: FAIL, `Normandy.Behaviours.MemoryStore.ETS.new/0 is undefined`.

- [ ] **Step 3: Implement**

`lib/normandy/behaviours/memory_store/ets.ex`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.ETS do
  @moduledoc """
  ETS-backed `MemoryStore`, in-node. One row per namespace, `{namespace, docs}`. A
  GenServer owns the `:protected` table and serializes every write, so compare-and-set
  and rename are atomic; reads go to the table directly. The handle is `{pid, table}`.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  use GenServer

  alias Normandy.Behaviours.MemoryStore.Docs

  @doc "Starts a fresh store; returns its handle `{owner_pid, table}`."
  @spec new(keyword()) :: {pid(), :ets.tid()}
  def new(opts \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)
    {pid, GenServer.call(pid, :table)}
  end

  @impl Normandy.Behaviours.MemoryStore
  def list({_pid, table}, ns, prefix), do: {:ok, Docs.list(docs(table, ns), prefix)}

  @impl Normandy.Behaviours.MemoryStore
  def get({_pid, table}, ns, path), do: Docs.get(docs(table, ns), path)

  @impl Normandy.Behaviours.MemoryStore
  def put({pid, _}, ns, path, content, expected),
    do: GenServer.call(pid, {:apply, ns, :put, [path, content, expected]})

  @impl Normandy.Behaviours.MemoryStore
  def delete({pid, _}, ns, path, expected),
    do: GenServer.call(pid, {:apply, ns, :delete, [path, expected]})

  @impl Normandy.Behaviours.MemoryStore
  def delete_tree({pid, _}, ns, prefix),
    do: GenServer.call(pid, {:apply, ns, :delete_tree, [prefix]})

  @impl Normandy.Behaviours.MemoryStore
  def rename({pid, _}, ns, from, to), do: GenServer.call(pid, {:apply, ns, :rename, [from, to]})

  @impl Normandy.Behaviours.MemoryStore
  def delete_namespace({pid, _}, ns), do: GenServer.call(pid, {:delete_namespace, ns})

  @impl GenServer
  def init(_opts), do: {:ok, :ets.new(:normandy_memory_store, [:set, :protected, read_concurrency: true])}

  @impl GenServer
  def handle_call(:table, _from, table), do: {:reply, table, table}

  def handle_call({:apply, ns, fun, args}, _from, table) do
    {reply, docs} = apply(Docs, fun, [docs(table, ns) | args])
    if docs == %{}, do: :ets.delete(table, ns), else: :ets.insert(table, {ns, docs})
    {:reply, reply, table}
  end

  def handle_call({:delete_namespace, ns}, _from, table) do
    :ets.delete(table, ns)
    {:reply, :ok, table}
  end

  defp docs(table, ns) do
    case :ets.lookup(table, ns) do
      [{^ns, docs}] -> docs
      [] -> %{}
    end
  end
end
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `mix format && mix test test/behaviours/memory_store/ets_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/memory_store/ets.ex test/behaviours/memory_store/ets_test.exs
git commit -m "feat(memory): ETS MemoryStore backend"
```

---

### Task 5: Mnesia backend and shared Mnesia setup

**Files:**
- Create: `lib/normandy/behaviours/mnesia_setup.ex`
- Modify: `lib/normandy/behaviours/session_store/mnesia.ex` (`create_tables/1` at :52-77; delete the private helpers at :237-271)
- Create: `lib/normandy/behaviours/memory_store/mnesia.ex`
- Test: `test/behaviours/memory_store/mnesia_test.exs`

**Interfaces:**
- Consumes: `MemoryStore.Docs`.
- Produces:
  - `Normandy.Behaviours.MnesiaSetup` with `ensure_started!/0`, `ensure_disc_schema!/1`, `create_table!(name, attrs, copies, nodes)` and `wait_for_tables!(tables, timeout, label)`.
  - `MemoryStore.Mnesia.new/1 :: atom()`, the table name and handle.
  - `MemoryStore.Mnesia.create_tables(table: atom, copies: :disc_copies | :ram_copies, nodes: [node], wait_timeout: ms)`.

- [ ] **Step 1: Write the failing test**

`test/behaviours/memory_store/mnesia_test.exs`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.MnesiaTest do
  # async: false — Mnesia is node-global state. The reset mirrors
  # test/behaviours/session_store/mnesia_test.exs (see its comment on the phantom
  # :nonode@nohost db_node).
  use ExUnit.Case, async: false

  setup do
    :mnesia.stop()
    :mnesia.delete_schema([node()])
    :ok = :mnesia.start()
    on_exit(fn -> :mnesia.stop() end)
  end

  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.Mnesia

  test "a missing table is a backend error, not :not_found" do
    assert {:error, _} = Normandy.Behaviours.MemoryStore.Mnesia.get(:normandy_no_such_table, "ns", "/memories/a")
  end
end
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix format && mix test test/behaviours/memory_store/mnesia_test.exs`
Expected: FAIL, `MemoryStore.Mnesia.new/0 is undefined`.

- [ ] **Step 3: Extract the shared Mnesia setup**

`lib/normandy/behaviours/mnesia_setup.ex`. Move the three private helpers out of `SessionStore.Mnesia` without changing their bodies, and add `wait_for_tables!/3`:

```elixir
defmodule Normandy.Behaviours.MnesiaSetup do
  @moduledoc false
  # Table setup shared by SessionStore.Mnesia and MemoryStore.Mnesia.

  @compile {:no_warn_undefined, :mnesia}

  def ensure_started! do
    case :mnesia.system_info(:is_running) do
      :yes -> :ok
      _ -> :mnesia.start()
    end
  end

  def ensure_disc_schema!(nodes) do
    Enum.each(nodes, fn n ->
      case :mnesia.change_table_copy_type(:schema, n, :disc_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, :schema, _, :disc_copies}} -> :ok
        {:aborted, reason} -> raise "Mnesia disc schema setup failed on #{inspect(n)}: #{inspect(reason)}"
      end
    end)
  end

  def create_table!(name, attrs, copies, nodes) do
    case :mnesia.create_table(name, [{:attributes, attrs}, {:type, :set}, {copies, nodes}]) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^name}} -> :ok
      {:aborted, reason} -> raise "Mnesia create_table #{inspect(name)} failed: #{inspect(reason)}"
    end
  end

  # After a restart, disc_copies tables already exist but load in the background; a
  # transaction before they finish aborts with :no_exists.
  def wait_for_tables!(tables, timeout, label) do
    case :mnesia.wait_for_tables(tables, timeout) do
      :ok -> :ok
      {:timeout, tables} -> raise "#{label}: tables not loaded within the wait timeout: #{inspect(tables)}"
      {:error, reason} -> raise "#{label}: waiting for tables failed: #{inspect(reason)}"
    end
  end
end
```

In `lib/normandy/behaviours/session_store/mnesia.ex`, replace the body of `create_tables/1` from `:ok = ensure_started!()` onward with:

```elixir
    :ok = MnesiaSetup.ensure_started!()
    if copies == :disc_copies, do: MnesiaSetup.ensure_disc_schema!(nodes)

    :ok = MnesiaSetup.create_table!(entries, [:id, :data], copies, nodes)
    :ok = MnesiaSetup.create_table!(sessions, [:session_id, :data], copies, nodes)

    MnesiaSetup.wait_for_tables!(
      [entries, sessions],
      Keyword.get(opts, :wait_timeout, 30_000),
      "SessionStore.Mnesia"
    )
```

Add `alias Normandy.Behaviours.MnesiaSetup`, and delete the private `ensure_started!/0`, `ensure_disc_schema!/1` and `create_table/4`.

Then run `mix format && mix test test/behaviours/session_store/mnesia_test.exs`.
Expected: all pass. The refactor must not change behaviour.

- [ ] **Step 4: Implement `MemoryStore.Mnesia`**

`lib/normandy/behaviours/memory_store/mnesia.ex`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.Mnesia do
  @moduledoc """
  Distributed, durable `MemoryStore` over Mnesia. One row per namespace,
  `{table, namespace, docs}`; every operation is one `:mnesia.transaction/1` that takes a
  write lock on the namespace row, so compare-and-set, rename and delete_tree are atomic
  across the cluster.

  The handle is the table name. Create it with `create_tables/1` (`copies: :disc_copies`
  by default, for durability); `new/1` makes a uniquely named `ram_copies` table for
  tests. A release using this store must include `:mnesia` in `extra_applications`.
  """
  @behaviour Normandy.Behaviours.MemoryStore

  @compile {:no_warn_undefined, :mnesia}

  alias Normandy.Behaviours.MemoryStore.Docs
  alias Normandy.Behaviours.MnesiaSetup

  @doc "Test/default handle: a fresh uniquely named `ram_copies` table on this node."
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    table = Keyword.get(opts, :table, :"normandy_memory_#{System.unique_integer([:positive])}")
    :ok = create_tables(table: table, copies: :ram_copies)
    table
  end

  @doc """
  Creates the memory table. Opts: `:table` (required), `:copies` (`:disc_copies` default |
  `:ram_copies`), `:nodes` (default `[node()]`), `:wait_timeout` (ms, default 30_000).
  """
  @spec create_tables(keyword()) :: :ok
  def create_tables(opts) do
    table = Keyword.fetch!(opts, :table)
    copies = Keyword.get(opts, :copies, :disc_copies)
    nodes = Keyword.get(opts, :nodes, [node()])

    :ok = MnesiaSetup.ensure_started!()
    if copies == :disc_copies, do: MnesiaSetup.ensure_disc_schema!(nodes)
    :ok = MnesiaSetup.create_table!(table, [:namespace, :docs], copies, nodes)
    MnesiaSetup.wait_for_tables!([table], Keyword.get(opts, :wait_timeout, 30_000), "MemoryStore.Mnesia")
  end

  @impl true
  def list(table, ns, prefix), do: read(table, ns, &{:ok, Docs.list(&1, prefix)})

  @impl true
  def get(table, ns, path), do: read(table, ns, &Docs.get(&1, path))

  @impl true
  def put(table, ns, path, content, expected),
    do: update(table, ns, &Docs.put(&1, path, content, expected))

  @impl true
  def delete(table, ns, path, expected), do: update(table, ns, &Docs.delete(&1, path, expected))

  @impl true
  def delete_tree(table, ns, prefix), do: update(table, ns, &Docs.delete_tree(&1, prefix))

  @impl true
  def rename(table, ns, from, to), do: update(table, ns, &Docs.rename(&1, from, to))

  @impl true
  def delete_namespace(table, ns), do: txn(fn -> :mnesia.delete({table, ns}) end)

  defp read(table, ns, fun), do: txn(fn -> fun.(docs(table, ns, :read)) end)

  defp update(table, ns, fun) do
    txn(fn ->
      {reply, docs} = fun.(docs(table, ns, :write))
      if docs == %{}, do: :mnesia.delete({table, ns}), else: :mnesia.write({table, ns, docs})
      reply
    end)
  end

  defp docs(table, ns, lock) do
    case :mnesia.read(table, ns, lock) do
      [{^table, ^ns, docs}] -> docs
      [] -> %{}
    end
  end

  # The transaction's own value is the reply; an abort is a backend error.
  defp txn(fun) do
    case :mnesia.transaction(fun) do
      {:atomic, reply} -> reply
      {:aborted, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `mix format && mix test test/behaviours/memory_store/mnesia_test.exs test/behaviours/session_store/mnesia_test.exs`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/behaviours/mnesia_setup.ex lib/normandy/behaviours/session_store/mnesia.ex lib/normandy/behaviours/memory_store/mnesia.ex test/behaviours/memory_store/mnesia_test.exs
git commit -m "feat(memory): Mnesia MemoryStore backend; share Mnesia table setup"
```

---

### Task 6: Postgres backend and migration

**Files:**
- Create: `lib/normandy/behaviours/memory_store/postgres.ex`
- Create: `lib/normandy/behaviours/memory_store/postgres/migration.ex`
- Create: `priv/test_repo/migrations/20261003000000_create_memory_store.exs`
- Test: `test/behaviours/memory_store/postgres_test.exs`

**Interfaces:**
- Produces:
  - `MemoryStore.Postgres`, whose handle is the Repo module. `new/0` returns the configured `:ecto_repos` head.
  - `MemoryStore.Postgres.Migration.up/0` and `down/0`.
  - Table `normandy_memory_documents (namespace text, path text, content text, version integer, updated_at timestamp(6))`, with primary key `(namespace, path)`.

- [ ] **Step 1: Write the failing test**

`test/behaviours/memory_store/postgres_test.exs`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.PostgresTest do
  @moduledoc "Run with `mix test --include postgres`. Requires Postgres and `MIX_ENV=test mix ecto.migrate`."
  # async: false — the Postgres sandbox runs in shared mode (the contract's concurrency
  # test spawns tasks).
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Normandy.TestRepo)
    Sandbox.mode(Normandy.TestRepo, {:shared, self()})
    :ok
  end

  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.Postgres
end
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix format && mix test --include postgres test/behaviours/memory_store/postgres_test.exs`
Expected: FAIL, `MemoryStore.Postgres.new/0 is undefined`.

If Postgres is not reachable, start it first with `docker compose -f docker-compose.verify.yml up -d`. Do not mark this task done with the test not run: that would be `VERIFY: DID NOT RUN`.

- [ ] **Step 3: Write the migration and the test-repo migration**

`lib/normandy/behaviours/memory_store/postgres/migration.ex`:

```elixir
if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Normandy.Behaviours.MemoryStore.Postgres.Migration do
    @moduledoc """
    Migration for the Postgres `MemoryStore`. Call from a host migration:

        defmodule MyApp.Repo.Migrations.AddNormandyMemory do
          use Ecto.Migration
          def up, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.up()
          def down, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.down()
        end
    """
    use Ecto.Migration

    def up do
      create table(:normandy_memory_documents, primary_key: false) do
        add(:namespace, :text, primary_key: true)
        add(:path, :text, primary_key: true)
        add(:content, :text, null: false)
        add(:version, :integer, null: false)
        add(:updated_at, :utc_datetime_usec, null: false)
      end
    end

    def down, do: drop(table(:normandy_memory_documents))
  end
end
```

`priv/test_repo/migrations/20261003000000_create_memory_store.exs`:

```elixir
defmodule Normandy.TestRepo.Migrations.CreateMemoryStore do
  use Ecto.Migration

  def up, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.up()
  def down, do: Normandy.Behaviours.MemoryStore.Postgres.Migration.down()
end
```

Run: `MIX_ENV=test mix ecto.migrate`
Expected: `create table normandy_memory_documents`.

- [ ] **Step 4: Implement the store**

`lib/normandy/behaviours/memory_store/postgres.ex`:

```elixir
if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Normandy.Behaviours.MemoryStore.Postgres do
    @moduledoc """
    Durable, cluster-shared `MemoryStore` over Postgres. The handle is the host's Ecto
    Repo module; run `Normandy.Behaviours.MemoryStore.Postgres.Migration` from a host
    migration.

    Compare-and-set is a conditional `UPDATE … WHERE version = $v`; `:new` is
    `INSERT … ON CONFLICT DO NOTHING`. `rename/4` locks the moving rows `FOR UPDATE` in
    one transaction. Prefixes match with `starts_with/2` (nothing to escape); listing
    orders by `path COLLATE "C"` (byte order).
    """
    @behaviour Normandy.Behaviours.MemoryStore

    alias Normandy.Behaviours.MemoryStore

    @table "normandy_memory_documents"

    @doc "Test/default handle: the Repo configured for :normandy."
    @spec new() :: module()
    def new, do: hd(Application.fetch_env!(:normandy, :ecto_repos))

    @impl true
    def list(repo, ns, prefix) do
      backend(fn ->
        sql = """
        SELECT path, octet_length(content), updated_at FROM #{@table}
        WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3))
        ORDER BY path COLLATE "C" LIMIT $4
        """

        with {:ok, %{rows: rows}} <- repo.query(sql, [ns, prefix, prefix <> "/", MemoryStore.list_limit()]) do
          {:ok, Enum.map(rows, fn [path, size, at] -> %{path: path, size: size, updated_at: utc(at)} end)}
        end
      end)
    end

    @impl true
    def get(repo, ns, path) do
      backend(fn ->
        case repo.query("SELECT content, version FROM #{@table} WHERE namespace = $1 AND path = $2", [ns, path]) do
          {:ok, %{rows: [[content, version]]}} -> {:ok, %{content: content, version: version}}
          {:ok, %{rows: []}} -> :not_found
          {:error, _} = error -> error
        end
      end)
    end

    @impl true
    def put(repo, ns, path, content, :new) do
      sql = "INSERT INTO #{@table} VALUES ($1, $2, $3, 1, $4) ON CONFLICT DO NOTHING"
      backend(fn -> repo.query(sql, [ns, path, content, now()]) |> one_row(1) end)
    end

    def put(repo, ns, path, content, :any) do
      sql = """
      INSERT INTO #{@table} VALUES ($1, $2, $3, 1, $4)
      ON CONFLICT (namespace, path) DO UPDATE
        SET content = EXCLUDED.content, version = #{@table}.version + 1, updated_at = EXCLUDED.updated_at
      RETURNING version
      """

      backend(fn -> repo.query(sql, [ns, path, content, now()]) |> returned_version() end)
    end

    def put(repo, ns, path, content, version) when is_integer(version) do
      sql = """
      UPDATE #{@table} SET content = $3, version = version + 1, updated_at = $5
      WHERE namespace = $1 AND path = $2 AND version = $4
      RETURNING version
      """

      backend(fn -> repo.query(sql, [ns, path, content, version, now()]) |> returned_version() end)
    end

    @impl true
    def delete(repo, ns, path, :any) do
      backend(fn ->
        case repo.query("DELETE FROM #{@table} WHERE namespace = $1 AND path = $2", [ns, path]) do
          {:ok, %{num_rows: 1}} -> :ok
          {:ok, %{num_rows: 0}} -> :not_found
          {:error, _} = error -> error
        end
      end)
    end

    def delete(repo, ns, path, version) when is_integer(version) do
      # The outer SELECT sees the snapshot before the CTE's DELETE, so `existed` tells a
      # stale version (conflict) from a missing document.
      sql = """
      WITH d AS (DELETE FROM #{@table} WHERE namespace = $1 AND path = $2 AND version = $3 RETURNING 1)
      SELECT (SELECT count(*) FROM d), (SELECT count(*) FROM #{@table} WHERE namespace = $1 AND path = $2)
      """

      backend(fn ->
        case repo.query(sql, [ns, path, version]) do
          {:ok, %{rows: [[1, _]]}} -> :ok
          {:ok, %{rows: [[0, 1]]}} -> {:error, :conflict}
          {:ok, %{rows: [[0, 0]]}} -> :not_found
          {:error, _} = error -> error
        end
      end)
    end

    @impl true
    def delete_tree(repo, ns, prefix) do
      sql = "DELETE FROM #{@table} WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3))"

      backend(fn ->
        with {:ok, %{num_rows: n}} <- repo.query(sql, [ns, prefix, prefix <> "/"]), do: {:ok, n}
      end)
    end

    @impl true
    def rename(repo, ns, from, to) do
      backend(fn ->
        repo.transaction(fn ->
          moving = lock_moving(repo, ns, from)

          cond do
            moving == [] ->
              :not_found

            destination_taken?(repo, ns, to) ->
              {:error, :exists}

            true ->
              %{num_rows: n} =
                repo.query!(
                  "UPDATE #{@table} SET path = $3::text || substr(path, length($2::text) + 1) WHERE namespace = $1 AND path = ANY($4::text[])",
                  [ns, from, to, moving]
                )

              {:ok, n}
          end
        end)
        |> case do
          {:ok, reply} -> reply
          {:error, _} = error -> error
        end
      end)
    end

    @impl true
    def delete_namespace(repo, ns) do
      backend(fn ->
        with {:ok, _} <- repo.query("DELETE FROM #{@table} WHERE namespace = $1", [ns]), do: :ok
      end)
    end

    # A document at `from` moves alone; otherwise everything under `from/`.
    defp lock_moving(repo, ns, from) do
      %{rows: own} =
        repo.query!("SELECT path FROM #{@table} WHERE namespace = $1 AND path = $2 FOR UPDATE", [ns, from])

      case own do
        [[path]] ->
          [path]

        [] ->
          %{rows: rows} =
            repo.query!(
              "SELECT path FROM #{@table} WHERE namespace = $1 AND starts_with(path, $2) FOR UPDATE",
              [ns, from <> "/"]
            )

          List.flatten(rows)
      end
    end

    defp destination_taken?(repo, ns, to) do
      %{rows: rows} =
        repo.query!(
          "SELECT 1 FROM #{@table} WHERE namespace = $1 AND (path = $2 OR starts_with(path, $3)) LIMIT 1",
          [ns, to, to <> "/"]
        )

      rows != []
    end

    defp one_row({:ok, %{num_rows: 1}}, version), do: {:ok, version}
    defp one_row({:ok, %{num_rows: 0}}, _version), do: {:error, :conflict}
    defp one_row({:error, _} = error, _version), do: error

    defp returned_version({:ok, %{rows: [[version]]}}), do: {:ok, version}
    defp returned_version({:ok, %{rows: []}}), do: {:error, :conflict}
    defp returned_version({:error, _} = error), do: error

    defp now, do: NaiveDateTime.utc_now()
    defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

    # A dropped connection or a raised Postgrex error is a backend error, never :not_found.
    defp backend(fun) do
      fun.()
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, e}
    end
  end
end
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `mix format && mix test --include postgres test/behaviours/memory_store/postgres_test.exs`
Expected: all pass. Record `VERIFY: Ran postgres_test.exs — Result: PASS`.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/behaviours/memory_store/postgres.ex lib/normandy/behaviours/memory_store/postgres/migration.ex priv/test_repo/migrations/20261003000000_create_memory_store.exs test/behaviours/memory_store/postgres_test.exs
git commit -m "feat(memory): Postgres MemoryStore backend and migration"
```

---

### Task 7: Redis backend (Lua compare-and-set)

**Files:**
- Create: `lib/normandy/behaviours/memory_store/redis.ex`
- Test: `test/behaviours/memory_store/redis_test.exs`

**Interfaces:**
- Produces: `MemoryStore.Redis`, with handle `{conn, prefix}`. `new/1` takes `url:` and `prefix:`, and defaults to the `:redis_url` config with a unique test prefix.
- Keys:
  - `#{prefix}:mem:{#{ns}}:doc:#{path}` (hash: `content`, `version`, `updated_at` as unix µs)
  - `#{prefix}:mem:{#{ns}}:idx` (sorted set, score 0, member = path)

- [ ] **Step 1: Write the failing test**

`test/behaviours/memory_store/redis_test.exs`:

```elixir
defmodule Normandy.Behaviours.MemoryStore.RedisTest do
  use ExUnit.Case, async: true
  @moduletag :redis
  use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.Redis

  test "a script missing from the server cache is reloaded (NOSCRIPT fallback)", %{handle: {conn, _} = h, ns: ns} do
    {:ok, "OK"} = Redix.command(conn, ["SCRIPT", "FLUSH"])
    assert {:ok, 1} = Normandy.Behaviours.MemoryStore.Redis.put(h, ns, "/memories/a", "x", :new)
  end
end
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `mix format && mix test --include redis test/behaviours/memory_store/redis_test.exs`
Expected: FAIL, `MemoryStore.Redis.new/0 is undefined`. If Redis is not reachable, start it with `docker compose -f docker-compose.verify.yml up -d`.

- [ ] **Step 3: Implement**

`lib/normandy/behaviours/memory_store/redis.ex`:

```elixir
if Code.ensure_loaded?(Redix) do
  defmodule Normandy.Behaviours.MemoryStore.Redis do
    @moduledoc """
    Durable `MemoryStore` over Redis. Each document is a hash; each namespace keeps a
    sorted set of its paths (score 0, so lexical order) for listing and prefixes. Every
    write is one Lua script, so compare-and-set, rename and delete_tree are atomic. All of
    a namespace's keys share the `{namespace}` hash tag, so they live in one Redis Cluster
    slot; the scripts derive document keys from the declared index key's prefix.

    The handle is `{conn, prefix}`; the host owns the Redix connection.
    """
    @behaviour Normandy.Behaviours.MemoryStore

    alias Normandy.Behaviours.MemoryStore

    @put """
    local cur = redis.call('HGET', KEYS[2], 'version')
    local exp = ARGV[3]
    if exp == 'new' and cur then return -1 end
    if exp ~= 'new' and exp ~= 'any' and cur ~= exp then return -1 end
    local v = 1
    if cur then v = tonumber(cur) + 1 end
    redis.call('HSET', KEYS[2], 'content', ARGV[2], 'version', v, 'updated_at', ARGV[4])
    redis.call('ZADD', KEYS[1], 0, ARGV[1])
    return v
    """

    @delete """
    local cur = redis.call('HGET', KEYS[2], 'version')
    if not cur then return 0 end
    if ARGV[2] ~= 'any' and cur ~= ARGV[2] then return -1 end
    redis.call('DEL', KEYS[2])
    redis.call('ZREM', KEYS[1], ARGV[1])
    return 1
    """

    @list """
    local out = {}
    local function add(p)
      local k = ARGV[1] .. p
      table.insert(out, p)
      table.insert(out, redis.call('HSTRLEN', k, 'content'))
      table.insert(out, redis.call('HGET', k, 'updated_at'))
    end
    if redis.call('ZSCORE', KEYS[1], ARGV[2]) then add(ARGV[2]) end
    local kids = redis.call('ZRANGEBYLEX', KEYS[1], '[' .. ARGV[2] .. '/', '[' .. ARGV[2] .. '/\\255', 'LIMIT', 0, tonumber(ARGV[3]))
    for _, p in ipairs(kids) do add(p) end
    return out
    """

    @delete_tree """
    local n = 0
    local function del(p)
      redis.call('DEL', ARGV[1] .. p)
      redis.call('ZREM', KEYS[1], p)
      n = n + 1
    end
    if redis.call('ZSCORE', KEYS[1], ARGV[2]) then del(ARGV[2]) end
    for _, p in ipairs(redis.call('ZRANGEBYLEX', KEYS[1], '[' .. ARGV[2] .. '/', '[' .. ARGV[2] .. '/\\255')) do del(p) end
    return n
    """

    @rename """
    local idx, dp, from, to = KEYS[1], ARGV[1], ARGV[2], ARGV[3]
    local moving
    if redis.call('ZSCORE', idx, from) then
      moving = {from}
    else
      moving = redis.call('ZRANGEBYLEX', idx, '[' .. from .. '/', '[' .. from .. '/\\255')
    end
    if #moving == 0 then return 0 end
    if redis.call('ZSCORE', idx, to) then return -1 end
    if #redis.call('ZRANGEBYLEX', idx, '[' .. to .. '/', '[' .. to .. '/\\255', 'LIMIT', 0, 1) > 0 then return -1 end
    for _, p in ipairs(moving) do
      local np = to .. string.sub(p, #from + 1)
      redis.call('RENAME', dp .. p, dp .. np)
      redis.call('ZREM', idx, p)
      redis.call('ZADD', idx, 0, np)
    end
    return #moving
    """

    @delete_namespace """
    for _, p in ipairs(redis.call('ZRANGE', KEYS[1], 0, -1)) do redis.call('DEL', ARGV[1] .. p) end
    redis.call('DEL', KEYS[1])
    return 1
    """

    @scripts %{
      put: @put,
      delete: @delete,
      list: @list,
      delete_tree: @delete_tree,
      rename: @rename,
      delete_namespace: @delete_namespace
    }
    @shas Map.new(@scripts, fn {k, s} -> {k, :crypto.hash(:sha, s) |> Base.encode16(case: :lower)} end)

    @doc "Test/default handle: a Redix conn to the configured URL and a unique key prefix."
    @spec new(keyword()) :: {pid(), String.t()}
    def new(opts \\ []) do
      url = Keyword.get(opts, :url, Application.get_env(:normandy, :redis_url, "redis://localhost:6379"))
      {:ok, conn} = Redix.start_link(url)
      {conn, Keyword.get(opts, :prefix, "normandy_test_mem_#{UUID.uuid4()}")}
    end

    @impl true
    def list({conn, _} = h, ns, prefix) do
      with {:ok, flat} <-
             eval(conn, :list, [idx(h, ns)], [doc_prefix(h, ns), prefix, MemoryStore.list_limit()]) do
        entries =
          flat
          |> Enum.chunk_every(3)
          |> Enum.map(fn [path, size, at] -> %{path: path, size: size, updated_at: from_micros(at)} end)
          |> Enum.take(MemoryStore.list_limit())

        {:ok, entries}
      end
    end

    @impl true
    def get({conn, _} = h, ns, path) do
      case Redix.command(conn, ["HMGET", doc(h, ns, path), "content", "version"]) do
        {:ok, [nil, _]} -> :not_found
        {:ok, [content, version]} -> {:ok, %{content: content, version: String.to_integer(version)}}
        {:error, _} = error -> error
      end
    end

    @impl true
    def put({conn, _} = h, ns, path, content, expected) do
      args = [path, content, expected_arg(expected), Integer.to_string(System.os_time(:microsecond))]

      case eval(conn, :put, [idx(h, ns), doc(h, ns, path)], args) do
        {:ok, -1} -> {:error, :conflict}
        {:ok, version} -> {:ok, version}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete({conn, _} = h, ns, path, expected) do
      case eval(conn, :delete, [idx(h, ns), doc(h, ns, path)], [path, expected_arg(expected)]) do
        {:ok, 1} -> :ok
        {:ok, 0} -> :not_found
        {:ok, -1} -> {:error, :conflict}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete_tree({conn, _} = h, ns, prefix),
      do: eval(conn, :delete_tree, [idx(h, ns)], [doc_prefix(h, ns), prefix])

    @impl true
    def rename({conn, _} = h, ns, from, to) do
      case eval(conn, :rename, [idx(h, ns)], [doc_prefix(h, ns), from, to]) do
        {:ok, 0} -> :not_found
        {:ok, -1} -> {:error, :exists}
        {:ok, n} -> {:ok, n}
        {:error, _} = error -> error
      end
    end

    @impl true
    def delete_namespace({conn, _} = h, ns) do
      with {:ok, 1} <- eval(conn, :delete_namespace, [idx(h, ns)], [doc_prefix(h, ns)]), do: :ok
    end

    # EVALSHA first; on NOSCRIPT (a restarted or flushed server) send the source once.
    defp eval(conn, name, keys, args) do
      args = Enum.map(args, &to_string/1)
      base = [Integer.to_string(length(keys)) | keys ++ args]

      case Redix.command(conn, ["EVALSHA", Map.fetch!(@shas, name) | base]) do
        {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
          Redix.command(conn, ["EVAL", Map.fetch!(@scripts, name) | base])

        other ->
          other
      end
    end

    defp expected_arg(:new), do: "new"
    defp expected_arg(:any), do: "any"
    defp expected_arg(v) when is_integer(v), do: Integer.to_string(v)

    defp idx({_, prefix}, ns), do: "#{prefix}:mem:{#{ns}}:idx"
    defp doc_prefix({_, prefix}, ns), do: "#{prefix}:mem:{#{ns}}:doc:"
    defp doc(h, ns, path), do: doc_prefix(h, ns) <> path

    defp from_micros(at), do: at |> String.to_integer() |> DateTime.from_unix!(:microsecond)
  end
end
```

Lua `'\\255'` in the Elixir heredoc becomes `'\255'` in Lua: the byte 0xFF, which valid UTF-8 never contains. That makes it a safe upper bound for the lexical range.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `mix format && mix test --include redis test/behaviours/memory_store/redis_test.exs`
Expected: all pass. Record `VERIFY: Ran redis_test.exs — Result: PASS`.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/memory_store/redis.ex test/behaviours/memory_store/redis_test.exs
git commit -m "feat(memory): Redis MemoryStore backend with Lua compare-and-set"
```

---

### Task 8: Memory paths: validation and mounts

**Files:**
- Create: `lib/normandy/tools/memory/paths.ex`
- Test: `test/tools/memory/paths_test.exs`

**Interfaces:**
- Produces:
  - `Paths.validate(term) :: {:ok, String.t()} | {:error, :invalid_path, String.t()}`.
  - `Paths.resolve(path, default_ns, mounts) :: %{namespace, path, model_path, access, mount}`. Here `path` is the store path, `access` is `:read_write | :read_only`, and `mount` is `String.t() | nil`.
  - `Paths.to_model(store_path, mount | nil) :: String.t()`.
  - `Paths.root/0` returns `"/memories"`.

- [ ] **Step 1: Write the failing tests**

`test/tools/memory/paths_test.exs`:

```elixir
defmodule Normandy.Tools.Memory.PathsTest do
  use ExUnit.Case, async: true
  alias Normandy.Tools.Memory.Paths

  test "accepts the root and paths under it" do
    for p <- ["/memories", "/memories/a.md", "/memories/notes/2026/q4.md", "/memories/.hidden"] do
      assert {:ok, ^p} = Paths.validate(p)
    end
  end

  test "rejects every escape and malformed form before any store call" do
    for p <- [
          "/memories/../secrets.env",
          "/memories/a/../../x",
          "/memories/./a",
          "/memoriesX/a",
          "/etc/passwd",
          "memories/a",
          "/memories//a",
          "/memories/a/",
          "/memories/a\\b",
          "/memories/%2e%2e/x",
          "/memories/a\0b",
          "/memories/a\nb",
          "/memories/" <> String.duplicate("a", 250),
          <<"/memories/", 0xFF>>
        ] do
      assert {:error, :invalid_path, "Error: " <> _} = Paths.validate(p), "accepted #{inspect(p)}"
    end
  end

  test "rejects a non-string path" do
    assert {:error, :invalid_path, "Error: path must be a string, got: nil"} = Paths.validate(nil)
  end

  test "resolve maps a mounted path to the mount's namespace and a store path under /memories" do
    mounts = %{"/memories/org" => {"acme/org-kb", :read_only}}

    assert %{namespace: "acme/org-kb", path: "/memories/kb.md", model_path: "/memories/org/kb.md",
             access: :read_only, mount: "/memories/org"} =
             Paths.resolve("/memories/org/kb.md", "acme/u-1", mounts)

    assert %{namespace: "acme/org-kb", path: "/memories", mount: "/memories/org"} =
             Paths.resolve("/memories/org", "acme/u-1", mounts)

    assert %{namespace: "acme/u-1", path: "/memories/orgs.md", access: :read_write, mount: nil} =
             Paths.resolve("/memories/orgs.md", "acme/u-1", mounts)
  end

  test "resolve picks the longest matching mount" do
    mounts = %{"/memories/org" => {"a", :read_only}, "/memories/org/team" => {"b", :read_write}}
    assert %{namespace: "b", path: "/memories/x"} = Paths.resolve("/memories/org/team/x", "u", mounts)
  end

  test "to_model/2 inverts the mount rewrite" do
    assert Paths.to_model("/memories/kb.md", "/memories/org") == "/memories/org/kb.md"
    assert Paths.to_model("/memories/kb.md", nil) == "/memories/kb.md"
  end
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix format && mix test test/tools/memory/paths_test.exs`
Expected: FAIL, `Normandy.Tools.Memory.Paths` undefined.

- [ ] **Step 3: Implement**

`lib/normandy/tools/memory/paths.ex`:

```elixir
defmodule Normandy.Tools.Memory.Paths do
  @moduledoc false
  # Path rules for the memory tool. Every path in every command passes validate/1 before
  # any store call. Nothing is ever URL-decoded: `%` is simply not allowed.

  alias Normandy.Behaviours.MemoryStore

  @root "/memories"
  @max_bytes 255

  def root, do: @root

  def validate(path) when is_binary(path) do
    cond do
      not String.valid?(path) -> invalid("path is not valid UTF-8")
      byte_size(path) > @max_bytes -> invalid("path is longer than #{@max_bytes} bytes")
      not MemoryStore.at_or_under?(path, @root) -> invalid("#{path} is outside /memories")
      String.contains?(path, ["\\", "%"]) -> invalid("#{path} contains \\ or %")
      String.match?(path, ~r/[\x00-\x1F\x7F]/) -> invalid("path contains a control character")
      bad_segment?(path) -> invalid("#{path} has an empty, . or .. segment")
      true -> {:ok, path}
    end
  end

  def validate(other), do: invalid("path must be a string, got: #{inspect(other)}")

  def resolve(path, default_ns, mounts) do
    mounts
    |> Enum.filter(fn {mount, _} -> MemoryStore.at_or_under?(path, mount) end)
    |> Enum.max_by(fn {mount, _} -> byte_size(mount) end, fn -> nil end)
    |> case do
      nil ->
        %{namespace: default_ns, path: path, model_path: path, access: :read_write, mount: nil}

      {mount, {ns, access}} ->
        store_path = MemoryStore.reparent(path, mount, @root)
        %{namespace: ns, path: store_path, model_path: path, access: access, mount: mount}
    end
  end

  def to_model(store_path, nil), do: store_path
  def to_model(store_path, mount), do: MemoryStore.reparent(store_path, @root, mount)

  defp bad_segment?(path) do
    path |> String.split("/") |> tl() |> Enum.any?(&(&1 in ["", ".", ".."]))
  end

  defp invalid(why), do: {:error, :invalid_path, "Error: " <> why}
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix format && mix test test/tools/memory/paths_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/tools/memory/paths.ex test/tools/memory/paths_test.exs
git commit -m "feat(memory): memory path validation and mounts"
```

---

### Task 9: Memory rendering and the tool shell (`new/1`, schema, `prepare_input/2`)

**Files:**
- Create: `lib/normandy/tools/memory/render.ex`
- Create: `lib/normandy/tools/memory.ex`
- Create: `test/support/memory_stub_stores.ex`
- Test: `test/tools/memory/render_test.exs`
- Test: `test/tools/memory_test.exs`

**Interfaces:**
- Consumes: `Paths` (Task 8), `MemoryStore` (Task 3), `Context` and `ContextualTool` (Task 1).
- Produces:
  - `Render.directory(dir, [%{path, size}]) :: String.t()`.
  - `Render.file(path, content, view_range | nil, max_chars) :: {:ok, String.t()} | {:error, :invalid_line, String.t()}`.
  - `Render.snippet(content, first_line, last_line) :: String.t()`.
  - `Render.human(bytes) :: String.t()`.
  - `%Normandy.Tools.Memory{store, namespace_key, mounts, max_document_bytes, max_view_chars, max_cas_retries, telemetry_include_paths, command}`.
  - `Memory.new/1`, `Memory.prepare_input/2`, `Memory.input_schema/0` and `Memory.description/1`.
  - `Memory.run/2` (ContextualTool), which delegates to `Commands.run/2` (Task 10).
  - Test stores `Normandy.Test.ConflictStore` and `Normandy.Test.DownStore`.

- [ ] **Step 1: Write the failing tests**

`test/tools/memory/render_test.exs`:

```elixir
defmodule Normandy.Tools.Memory.RenderTest do
  use ExUnit.Case, async: true
  alias Normandy.Tools.Memory.Render

  test "directory/2: header, root line, two levels, hidden and node_modules excluded" do
    docs = [
      %{path: "/memories/a.md", size: 1536},
      %{path: "/memories/notes/q4.md", size: 100},
      %{path: "/memories/notes/deep/x.md", size: 50},
      %{path: "/memories/.secret", size: 9},
      %{path: "/memories/node_modules/y", size: 9}
    ]

    assert Render.directory("/memories", docs) ==
             """
             Here're the files and directories up to 2 levels deep in /memories, excluding hidden items and node_modules:
             1.6K\t/memories
             1.5K\t/memories/a.md
             150B\t/memories/notes
             50B\t/memories/notes/deep
             100B\t/memories/notes/q4.md\
             """
  end

  test "directory/2 on an empty root is the header and the root line" do
    assert Render.directory("/memories", []) ==
             "Here're the files and directories up to 2 levels deep in /memories, excluding hidden items and node_modules:\n0B\t/memories"
  end

  test "file/4 numbers lines six wide with a tab" do
    assert {:ok,
            "Here's the content of /memories/n.txt with line numbers:\n     1\tHello\n     2\tWorld"} =
             Render.file("/memories/n.txt", "Hello\nWorld\n", nil, 16_000)
  end

  test "file/4 view_range slices, -1 reads to the end, a bad range is an error" do
    text = "a\nb\nc\nd"
    assert {:ok, out} = Render.file("/memories/n", text, [2, 3], 16_000)
    assert out =~ "     2\tb\n     3\tc"
    refute out =~ "\td"
    assert {:ok, out} = Render.file("/memories/n", text, [3, -1], 16_000)
    assert out =~ "     3\tc\n     4\td"

    assert {:error, :invalid_line,
            "Error: Invalid `view_range` parameter: [3, 9]. It should be within the range of lines of the file: [1, 4]"} =
             Render.file("/memories/n", text, [3, 9], 16_000)
  end

  test "file/4 cuts at max_chars and says where to continue" do
    text = Enum.map_join(1..100, "\n", &"line #{&1}")
    assert {:ok, out} = Render.file("/memories/n", text, nil, 200)
    assert out =~ "[truncated at line"
    assert out =~ "use view_range ["
  end

  test "snippet/3 shows the edited lines with four lines of context" do
    text = Enum.map_join(1..20, "\n", &"l#{&1}")
    out = Render.snippet(text, 10, 10)
    assert out =~ "     6\tl6"
    assert out =~ "    14\tl14"
    refute out =~ "\tl5\n"
  end

  test "human/1" do
    assert Render.human(512) == "512B"
    assert Render.human(1536) == "1.5K"
    assert Render.human(1_258_291) == "1.2M"
  end
end
```

`test/support/memory_stub_stores.ex`:

```elixir
defmodule Normandy.Test.ConflictStore do
  @moduledoc "A MemoryStore whose get/3 always finds a document and whose writes always conflict."
  @behaviour Normandy.Behaviours.MemoryStore
  def list(_, _, _), do: {:ok, []}
  def get(_, _, _), do: {:ok, %{content: "alpha\nbeta", version: 1}}
  def put(_, _, _, _, _), do: {:error, :conflict}
  def delete(_, _, _, _), do: {:error, :conflict}
  def delete_tree(_, _, _), do: {:ok, 0}
  def rename(_, _, _, _), do: :not_found
  def delete_namespace(_, _), do: :ok
end

defmodule Normandy.Test.DownStore do
  @moduledoc "A MemoryStore whose every call is a backend failure."
  @behaviour Normandy.Behaviours.MemoryStore
  def list(_, _, _), do: {:error, :timeout}
  def get(_, _, _), do: {:error, :timeout}
  def put(_, _, _, _, _), do: {:error, :timeout}
  def delete(_, _, _, _), do: {:error, :timeout}
  def delete_tree(_, _, _), do: {:error, :timeout}
  def rename(_, _, _, _), do: {:error, :timeout}
  def delete_namespace(_, _), do: {:error, :timeout}
end
```

`test/tools/memory_test.exs`. This file covers the shell; the command tests are added in Task 10.

```elixir
defmodule Normandy.Tools.MemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{BaseTool, Context, Memory}

  defp tool(opts \\ []), do: Memory.new(Keyword.merge([store: {InMemory, InMemory.new()}], opts))

  describe "new/1" do
    test "defaults" do
      t = tool()
      assert %Memory{namespace_key: :memory_namespace, mounts: %{}, max_document_bytes: 100_000,
                     max_view_chars: 16_000, max_cas_retries: 3, telemetry_include_paths: false} = t
    end

    test "raises on each malformed option, naming it" do
      for {opts, pattern} <- [
            {[], ~r/:store is required/},
            {[store: :nope], ~r/:store must be \{module, handle\}/},
            {[store: {String, nil}], ~r/does not implement Normandy.Behaviours.MemoryStore/},
            {[store: {InMemory, nil}, bogus: 1], ~r/unknown option :bogus/},
            {[store: {InMemory, nil}, mounts: %{"/etc" => {"n", :read_only}}], ~r/:mounts/},
            {[store: {InMemory, nil}, mounts: %{"/memories" => {"n", :read_only}}], ~r/:mounts/},
            {[store: {InMemory, nil}, mounts: %{"/memories/o" => {"", :read_only}}], ~r/:mounts/},
            {[store: {InMemory, nil}, mounts: %{"/memories/o" => {"n", :rw}}], ~r/:mounts/},
            {[store: {InMemory, nil}, max_document_bytes: 0], ~r/:max_document_bytes/},
            {[store: {InMemory, nil}, max_cas_retries: -1], ~r/:max_cas_retries/},
            {[store: {InMemory, nil}, namespace_key: "k"], ~r/:namespace_key/}
          ] do
        assert_raise ArgumentError, pattern, fn -> Memory.new(opts) end
      end
    end
  end

  test "BaseTool: name, schema, description, and run/1 without context is an error" do
    t = tool(mounts: %{"/memories/org" => {"acme/kb", :read_only}})
    assert BaseTool.tool_name(t) == "memory"
    assert %{required: ["command"], properties: %{command: %{enum: enum}}} = BaseTool.input_schema(t)
    assert enum == ~w(view create str_replace insert delete rename)
    assert BaseTool.tool_description(t) =~ "ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE"
    assert BaseTool.tool_description(t) =~ "/memories/org (read-only)"
    assert {:error, "memory requires tool context" <> _} = BaseTool.run(t)
  end

  test "prepare_input/2 fills only :command; model input cannot set store, mounts or limits (Review Focus #5)" do
    t = tool()

    prepared =
      Memory.prepare_input(t, %{
        "command" => "view",
        "path" => "/memories",
        "store" => {Evil, :x},
        "mounts" => %{"/memories/x" => {"other", :read_write}},
        "max_document_bytes" => 1,
        :namespace_key => :other
      })

    assert prepared.store == t.store
    assert prepared.mounts == %{}
    assert prepared.max_document_bytes == 100_000
    assert prepared.namespace_key == :memory_namespace
    assert prepared.command.command == "view"
    assert prepared.command.path == "/memories"
    assert prepared.command.file_text == nil
  end

  test "a missing namespace raises, naming the key and the keys present" do
    t = Memory.prepare_input(tool(), %{"command" => "view", "path" => "/memories"})

    assert_raise ArgumentError, ~r/tool_context\[:memory_namespace\].*\[:tenant\]/, fn ->
      Memory.run(t, %Context{tool_call_id: "c", values: %{tenant: "acme"}})
    end
  end
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix format && mix test test/tools/memory/render_test.exs test/tools/memory_test.exs`
Expected: FAIL, `Normandy.Tools.Memory.Render` undefined.

- [ ] **Step 3: Implement `Render`**

`lib/normandy/tools/memory/render.ex`:

```elixir
defmodule Normandy.Tools.Memory.Render do
  @moduledoc false
  # The model-facing text of the memory tool, matching Anthropic's memory-tool reference.

  @max_lines 999_999

  def directory(dir, docs) do
    visible = Enum.reject(docs, &hidden?(rel(&1.path, dir)))

    rows =
      visible
      |> Enum.flat_map(fn %{path: path, size: size} ->
        segs = rel(path, dir)
        depth = length(segs)
        dirs = for d <- 1..min(depth - 1, 2)//1, do: {Enum.join([dir | Enum.take(segs, d)], "/"), size}
        if depth <= 2, do: dirs ++ [{path, size}], else: dirs
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {path, sizes} -> {path, Enum.sum(sizes)} end)
      |> Enum.sort()

    total = visible |> Enum.map(& &1.size) |> Enum.sum()

    header =
      "Here're the files and directories up to 2 levels deep in #{dir}, excluding hidden items and node_modules:"

    Enum.join([header, "#{human(total)}\t#{dir}" | Enum.map(rows, fn {p, s} -> "#{human(s)}\t#{p}" end)], "\n")
  end

  def file(path, content, range, max_chars) do
    lines = content |> String.trim_trailing("\n") |> String.split("\n")
    n = length(lines)

    with :ok <- line_limit(path, n),
         {:ok, first, last} <- range(range, n) do
      shown = lines |> Enum.with_index(1) |> Enum.slice((first - 1)..(last - 1)//1)
      {body, cut_after} = cap(shown, max_chars)

      note =
        if cut_after,
          do: "\n[truncated at line #{cut_after} of #{n}; use view_range [#{cut_after + 1}, -1] to read on]",
          else: ""

      {:ok, "Here's the content of #{path} with line numbers:\n" <> body <> note}
    end
  end

  def snippet(content, first, last) do
    lines = String.split(content, "\n")
    from = max(first - 4, 1)
    to = min(last + 4, length(lines))

    lines
    |> Enum.with_index(1)
    |> Enum.slice((from - 1)..(to - 1)//1)
    |> Enum.map_join("\n", fn {line, i} -> numbered(i, line) end)
  end

  def human(bytes) when bytes < 1024, do: "#{bytes}B"
  def human(bytes) when bytes < 1024 * 1024, do: one_decimal(bytes / 1024) <> "K"
  def human(bytes), do: one_decimal(bytes / (1024 * 1024)) <> "M"

  defp one_decimal(x), do: :erlang.float_to_binary(x, decimals: 1)

  defp numbered(i, line), do: String.pad_leading(Integer.to_string(i), 6) <> "\t" <> line

  defp cap(shown, max_chars) do
    Enum.reduce_while(shown, {[], 0, nil}, fn {line, i}, {acc, used, _} ->
      text = numbered(i, line)
      used = used + String.length(text) + 1

      if used > max_chars and acc != [],
        do: {:halt, {acc, used, i - 1}},
        else: {:cont, {[text | acc], used, nil}}
    end)
    |> then(fn {acc, _used, cut} -> {acc |> Enum.reverse() |> Enum.join("\n"), cut} end)
  end

  defp range(nil, n), do: {:ok, 1, n}
  defp range([first, -1], n) when is_integer(first) and first >= 1 and first <= n, do: {:ok, first, n}

  defp range([first, last], n)
       when is_integer(first) and is_integer(last) and first >= 1 and first <= last and last <= n,
       do: {:ok, first, last}

  defp range(other, n),
    do:
      {:error, :invalid_line,
       "Error: Invalid `view_range` parameter: #{inspect(other)}. It should be within the range of lines of the file: [1, #{n}]"}

  defp line_limit(path, n) when n > @max_lines,
    do: {:error, :invalid_line, "File #{path} exceeds maximum line limit of 999,999 lines."}

  defp line_limit(_path, _n), do: :ok

  defp rel(path, dir), do: path |> String.replace_prefix(dir <> "/", "") |> String.split("/")
  defp hidden?(segs), do: Enum.any?(segs, &(String.starts_with?(&1, ".") or &1 == "node_modules"))
end
```

Check the expected strings in `render_test.exs` against this code. In the `directory/2` test the total is 1536 + 100 + 50 = 1686 → `1.6K`, and `/memories/notes` is 150B. If the arithmetic in the test disagrees with the code, fix the **test literal**; the semantics in the code must stay as written.

- [ ] **Step 4: Implement the tool shell**

`lib/normandy/tools/memory.ex`:

```elixir
defmodule Normandy.Tools.Memory do
  @moduledoc """
  Persistent agent memory: the `memory` tool. The model reads and writes text files under
  `/memories` with Anthropic's memory-tool commands (`view`, `create`, `str_replace`,
  `insert`, `delete`, `rename`); this tool executes them against a
  `Normandy.Behaviours.MemoryStore`.

  The namespace comes from the session's `tool_context` (`namespace_key`, default
  `:memory_namespace`), never from the tool struct, so it survives `Turn.Server`
  rehydration and the model cannot change it. A missing namespace raises: there is no
  default namespace.

      BaseAgent.init(%{client: c, model: m, tool_context: %{memory_namespace: "acme/user-42"}})
      |> BaseAgent.register_tool(Memory.new(store: {MemoryStore.Postgres, MyApp.Repo}))

  Options (`new/1`): `:store` (required, `{module, handle}`), `:namespace_key`, `:mounts`
  (`%{"/memories/org" => {"acme/org-kb", :read_only | :read_write}}`),
  `:max_document_bytes` (100_000), `:max_view_chars` (16_000), `:max_cas_retries` (3),
  `:telemetry_include_paths` (false).

  Memory carries content across sessions, so it is a prompt-injection channel that
  persists: keep a namespace no wider than the trust boundary of the people whose input
  reaches the agent. Never store secrets in memory.
  """

  alias Normandy.Tools.Context
  alias Normandy.Tools.Memory.{Commands, Paths}

  @enforce_keys [:store]
  defstruct store: nil,
            namespace_key: :memory_namespace,
            mounts: %{},
            max_document_bytes: 100_000,
            max_view_chars: 16_000,
            max_cas_retries: 3,
            telemetry_include_paths: false,
            command: nil

  @type t :: %__MODULE__{
          store: {module(), term()},
          namespace_key: atom(),
          mounts: %{String.t() => {String.t(), :read_only | :read_write}},
          max_document_bytes: pos_integer(),
          max_view_chars: pos_integer(),
          max_cas_retries: non_neg_integer(),
          telemetry_include_paths: boolean(),
          command: map() | nil
        }

  @options [:store, :namespace_key, :mounts, :max_document_bytes, :max_view_chars,
            :max_cas_retries, :telemetry_include_paths]
  @fields ~w(command path view_range file_text old_str new_str insert_line insert_text old_path new_path)a
  @commands ~w(view create str_replace insert delete rename)

  @doc "Builds the tool, validating every option; raises `ArgumentError` naming a bad one."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      [key | _] -> raise ArgumentError, "Normandy.Tools.Memory.new/1: unknown option #{inspect(key)}; allowed: #{Enum.map_join(@options, ", ", &inspect/1)}"
    end

    unless Keyword.has_key?(opts, :store),
      do: raise(ArgumentError, "Normandy.Tools.Memory.new/1: :store is required: {module, handle}")

    tool = struct!(__MODULE__, opts)
    validate_store!(tool.store)
    validate_mounts!(tool.mounts)
    check!(:namespace_key, tool.namespace_key, is_atom(tool.namespace_key), "an atom")
    for key <- [:max_document_bytes, :max_view_chars], do: positive!(key, Map.fetch!(tool, key))
    check!(:max_cas_retries, tool.max_cas_retries, is_integer(tool.max_cas_retries) and tool.max_cas_retries >= 0, "a non-negative integer")
    check!(:telemetry_include_paths, tool.telemetry_include_paths, is_boolean(tool.telemetry_include_paths), "a boolean")
    tool
  end

  @doc false
  # Called by dispatch instead of struct/2: model input fills :command and nothing else.
  @spec prepare_input(t(), map()) :: t()
  def prepare_input(%__MODULE__{} = tool, input) when is_map(input) do
    %{tool | command: Map.new(@fields, &{&1, Map.get(input, Atom.to_string(&1), Map.get(input, &1))})}
  end

  @doc false
  @spec run(t(), Context.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%__MODULE__{} = tool, %Context{} = ctx) do
    namespace = namespace!(tool, ctx)
    meta = telemetry_metadata(tool, namespace)

    :telemetry.span([:normandy, :memory, :command], meta, fn ->
      case Commands.run(tool, namespace) do
        {:ok, text, stats} ->
          {{:ok, text}, measurements(stats), Map.put(meta, :status, :ok)}

        {:error, type, text} ->
          {{:error, text}, measurements(%{}), Map.merge(meta, %{status: :error, error_type: type})}
      end
    end)
  end

  @doc false
  def input_schema do
    %{
      type: "object",
      properties: %{
        command: %{type: "string", enum: @commands, description: "The memory operation."},
        path: %{type: "string", description: "A path under /memories (every command except rename)."},
        view_range: %{type: "array", items: %{type: "integer"}, description: "view only: [start_line, end_line]; end_line -1 reads to the end."},
        file_text: %{type: "string", description: "create only: the whole file content."},
        old_str: %{type: "string", description: "str_replace only: text that occurs exactly once in the file."},
        new_str: %{type: "string", description: "str_replace only: the replacement; omit it to delete old_str."},
        insert_line: %{type: "integer", description: "insert only: insert after this line; 0 inserts at the top."},
        insert_text: %{type: "string", description: "insert only: the text to insert."},
        old_path: %{type: "string", description: "rename only: the file or directory to move."},
        new_path: %{type: "string", description: "rename only: where to move it."}
      },
      required: ["command"]
    }
  end

  @doc false
  def description(%__MODULE__{mounts: mounts}) do
    base = """
    Persistent memory that survives across conversations, stored as files under /memories.
    IMPORTANT: ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE.
    MEMORY PROTOCOL:
    1. Use the `view` command to check for earlier progress.
    2. As you make progress, record status, progress and thoughts in your memory.
    ASSUME INTERRUPTION: your context window might be reset at any moment, so you risk losing any progress that is not recorded in your memory directory.
    Keep the directory up to date, coherent and organized: rename or delete files that are no longer relevant, and do not create new files unless necessary. Never store secrets.
    Commands: view (a directory listing or a file with line numbers), create (create or overwrite a file), str_replace, insert, delete (a file or a directory), rename (a file or a directory).\
    """

    case Enum.sort(mounts) do
      [] -> base
      list -> base <> "\nShared directories: " <> Enum.map_join(list, ", ", fn {m, {_, a}} -> "#{m} (#{access_label(a)})" end) <> "."
    end
  end

  defp access_label(:read_only), do: "read-only"
  defp access_label(:read_write), do: "read-write"

  defp namespace!(tool, ctx) do
    case Map.get(ctx.values, tool.namespace_key) do
      ns when is_binary(ns) and ns != "" ->
        ns

      _ ->
        raise ArgumentError,
              "memory tool needs tool_context[#{inspect(tool.namespace_key)}] to be a non-empty string; " <>
                "got keys #{inspect(Map.keys(ctx.values))}"
    end
  end

  defp telemetry_metadata(%__MODULE__{store: {mod, _}, command: cmd} = tool, namespace) do
    base = %{command: cmd && cmd.command, store: mod}

    if tool.telemetry_include_paths,
      do: Map.merge(base, %{namespace: namespace, path: cmd && (cmd.path || cmd.old_path)}),
      else: base
  end

  defp measurements(stats), do: Map.merge(%{bytes_read: 0, bytes_written: 0, cas_retries: 0}, stats)

  defp validate_store!({mod, _handle}) when is_atom(mod) do
    behaviours = if Code.ensure_loaded?(mod), do: Keyword.get_values(mod.module_info(:attributes), :behaviour) |> List.flatten(), else: []

    unless Normandy.Behaviours.MemoryStore in behaviours,
      do: raise(ArgumentError, "Normandy.Tools.Memory.new/1: :store module #{inspect(mod)} does not implement Normandy.Behaviours.MemoryStore")
  end

  defp validate_store!(other),
    do: raise(ArgumentError, "Normandy.Tools.Memory.new/1: :store must be {module, handle}, got: #{inspect(other)}")

  defp validate_mounts!(mounts) when is_map(mounts) do
    Enum.each(mounts, fn
      {mount, {ns, access}}
      when is_binary(ns) and ns != "" and access in [:read_only, :read_write] ->
        unless match?({:ok, _}, Paths.validate(mount)) and mount != Paths.root(),
          do: bad_mount!(mount)

      {mount, _} ->
        bad_mount!(mount)
    end)
  end

  defp validate_mounts!(other), do: bad_mount!(other)

  defp bad_mount!(what),
    do:
      raise(ArgumentError,
        "Normandy.Tools.Memory.new/1: :mounts must map a path under /memories (not /memories itself) " <>
          "to {namespace, :read_only | :read_write}; bad entry: #{inspect(what)}")

  defp positive!(key, value), do: check!(key, value, is_integer(value) and value > 0, "a positive integer")

  defp check!(_key, _value, true, _want), do: :ok

  defp check!(key, value, false, want),
    do: raise(ArgumentError, "Normandy.Tools.Memory.new/1: #{inspect(key)} must be #{want}, got: #{inspect(value)}")

  defimpl Normandy.Tools.BaseTool do
    def tool_name(_tool), do: "memory"
    def tool_description(tool), do: Normandy.Tools.Memory.description(tool)
    def input_schema(_tool), do: Normandy.Tools.Memory.input_schema()

    def run(_tool),
      do: {:error, "memory requires tool context; it was called outside the dispatch pipeline"}
  end

  defimpl Normandy.Tools.ContextualTool do
    def run(tool, ctx), do: Normandy.Tools.Memory.run(tool, ctx)
  end
end
```

`Commands` does not exist yet. So that this task compiles, create a placeholder `lib/normandy/tools/memory/commands.ex`. Task 10 replaces its body in its first step:

```elixir
defmodule Normandy.Tools.Memory.Commands do
  @moduledoc false
  def run(_tool, _namespace), do: {:error, :invalid_input, "Error: memory commands are not implemented"}
end
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `mix format && mix test test/tools/memory/render_test.exs test/tools/memory_test.exs`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/tools/memory.ex lib/normandy/tools/memory/render.ex lib/normandy/tools/memory/commands.ex test/support/memory_stub_stores.ex test/tools/memory/render_test.exs test/tools/memory_test.exs
git commit -m "feat(memory): memory tool shell, options, schema and rendering"
```

---

### Task 10: Memory commands with compare-and-set, plus the contract concurrency test

**Files:**
- Modify: `lib/normandy/tools/memory/commands.ex` (replace the placeholder)
- Modify: `test/tools/memory_test.exs` (add command tests)
- Modify: `test/support/memory_store_contract.ex` (add the concurrency test)

**Interfaces:**
- Consumes: `Paths`, `Render`, `%Memory{}` and the `MemoryStore` callbacks.
- Produces: `Commands.run(%Memory{}, namespace) :: {:ok, text, stats} | {:error, error_type, text}`. `stats` is a subset of `%{bytes_read, bytes_written, cas_retries}`. `error_type` is one of `:not_found | :conflict_exhausted | :invalid_path | :read_only | :too_large | :no_match | :ambiguous_match | :invalid_line | :exists | :backend | :invalid_input`.

- [ ] **Step 1: Write the failing command tests**

Append to `test/tools/memory_test.exs`:

```elixir
  describe "commands" do
    alias Normandy.Test.{ConflictStore, DownStore}

    setup do
      store = InMemory.new()
      {:ok, store: store, t: Memory.new(store: {InMemory, store})}
    end

    defp call(tool, input, ns \\ "acme/u-1"),
      do: Memory.run(Memory.prepare_input(tool, input), %Context{tool_call_id: "c", values: %{memory_namespace: ns}})

    test "view of an empty root is a listing, not an error", %{t: t} do
      assert {:ok, "Here're the files and directories up to 2 levels deep in /memories" <> _} =
               call(t, %{"command" => "view", "path" => "/memories"})
    end

    test "create, view, and the exact strings", %{t: t} do
      assert {:ok, "File created successfully at: /memories/p.md"} =
               call(t, %{"command" => "create", "path" => "/memories/p.md", "file_text" => "color: blue\n"})

      assert {:ok, "Here's the content of /memories/p.md with line numbers:\n     1\tcolor: blue"} =
               call(t, %{"command" => "view", "path" => "/memories/p.md"})

      assert {:ok, "File created successfully at: /memories/p.md"} =
               call(t, %{"command" => "create", "path" => "/memories/p.md", "file_text" => "overwritten"})

      assert {:error, "The path /memories/nope does not exist. Please provide a valid path."} =
               call(t, %{"command" => "view", "path" => "/memories/nope"})
    end

    test "str_replace: success snippet, no match, multiple matches, missing file, delete by omitting new_str", %{t: t} do
      call(t, %{"command" => "create", "path" => "/memories/p.md", "file_text" => "a\ncolor: blue\nb\nx x"})

      assert {:ok, "The memory file has been edited.\n" <> snippet} =
               call(t, %{"command" => "str_replace", "path" => "/memories/p.md", "old_str" => "blue", "new_str" => "green"})

      assert snippet =~ "     2\tcolor: green"

      assert {:error, "No replacement was performed, old_str `purple` did not appear verbatim in /memories/p.md."} =
               call(t, %{"command" => "str_replace", "path" => "/memories/p.md", "old_str" => "purple", "new_str" => "x"})

      assert {:error, "No replacement was performed. Multiple occurrences of old_str `x` in lines: 4, 4. Please ensure it is unique"} =
               call(t, %{"command" => "str_replace", "path" => "/memories/p.md", "old_str" => "x", "new_str" => "y"})

      assert {:error, "Error: The path /memories/q.md does not exist. Please provide a valid path."} =
               call(t, %{"command" => "str_replace", "path" => "/memories/q.md", "old_str" => "a", "new_str" => "b"})

      assert {:ok, _} = call(t, %{"command" => "str_replace", "path" => "/memories/p.md", "old_str" => "a\n"})
      assert {:ok, view} = call(t, %{"command" => "view", "path" => "/memories/p.md"})
      assert view =~ "     1\tcolor: green"
    end

    test "insert: at the top, after a line, out of range, missing file", %{t: t} do
      call(t, %{"command" => "create", "path" => "/memories/todo", "file_text" => "one\ntwo"})

      assert {:ok, "The file /memories/todo has been edited."} =
               call(t, %{"command" => "insert", "path" => "/memories/todo", "insert_line" => 0, "insert_text" => "zero\n"})

      assert {:ok, "The file /memories/todo has been edited."} =
               call(t, %{"command" => "insert", "path" => "/memories/todo", "insert_line" => 3, "insert_text" => "three"})

      assert {:ok, view} = call(t, %{"command" => "view", "path" => "/memories/todo"})
      assert view =~ "     1\tzero\n     2\tone\n     3\ttwo\n     4\tthree"

      assert {:error, "Error: Invalid `insert_line` parameter: 9. It should be within the range of lines of the file: [0, 4]"} =
               call(t, %{"command" => "insert", "path" => "/memories/todo", "insert_line" => 9, "insert_text" => "x"})

      assert {:error, "Error: The path /memories/none does not exist"} =
               call(t, %{"command" => "insert", "path" => "/memories/none", "insert_line" => 0, "insert_text" => "x"})
    end

    test "delete: a file, a directory recursively, missing, and never the root", %{t: t} do
      for p <- ["/memories/a", "/memories/d/1", "/memories/d/e/2"],
          do: call(t, %{"command" => "create", "path" => p, "file_text" => "x"})

      assert {:ok, "Successfully deleted /memories/a"} = call(t, %{"command" => "delete", "path" => "/memories/a"})
      assert {:ok, "Successfully deleted /memories/d"} = call(t, %{"command" => "delete", "path" => "/memories/d"})
      assert {:error, "Error: The path /memories/d does not exist"} = call(t, %{"command" => "delete", "path" => "/memories/d"})
      assert {:error, "Error: cannot delete the /memories directory"} = call(t, %{"command" => "delete", "path" => "/memories"})
    end

    test "rename: a file, a directory, onto an existing path, missing, and never the root", %{t: t} do
      for p <- ["/memories/a", "/memories/b", "/memories/d/1"],
          do: call(t, %{"command" => "create", "path" => p, "file_text" => "x"})

      assert {:ok, "Successfully renamed /memories/a to /memories/c"} =
               call(t, %{"command" => "rename", "old_path" => "/memories/a", "new_path" => "/memories/c"})

      assert {:ok, "Successfully renamed /memories/d to /memories/z"} =
               call(t, %{"command" => "rename", "old_path" => "/memories/d", "new_path" => "/memories/z"})

      assert {:error, "Error: The destination /memories/b already exists"} =
               call(t, %{"command" => "rename", "old_path" => "/memories/c", "new_path" => "/memories/b"})

      assert {:error, "Error: The path /memories/nope does not exist"} =
               call(t, %{"command" => "rename", "old_path" => "/memories/nope", "new_path" => "/memories/x"})

      assert {:error, "Error: cannot rename the /memories directory"} =
               call(t, %{"command" => "rename", "old_path" => "/memories", "new_path" => "/memories/x"})
    end

    test "invalid paths never reach the store", %{t: _} do
      down = Memory.new(store: {DownStore, nil})

      assert {:error, "Error: " <> _} =
               call(down, %{"command" => "view", "path" => "/memories/../etc/passwd"})
    end

    test "unknown command and missing fields", %{t: t} do
      assert {:error, "Error: unknown command \"wipe\"" <> _} = call(t, %{"command" => "wipe"})
      assert {:error, "Error: `file_text` must be a UTF-8 string"} = call(t, %{"command" => "create", "path" => "/memories/a"})
      assert {:error, "Error: `old_str` must not be empty"} = call(t, %{"command" => "str_replace", "path" => "/memories/a", "old_str" => ""})
      assert {:error, "Error: `insert_line` must be an integer"} = call(t, %{"command" => "insert", "path" => "/memories/a", "insert_text" => "x"})
    end

    test "namespaces are separate", %{t: t} do
      call(t, %{"command" => "create", "path" => "/memories/a", "file_text" => "mine"}, "acme/u-1")
      assert {:error, "The path /memories/a does not exist" <> _} = call(t, %{"command" => "view", "path" => "/memories/a"}, "acme/u-2")
    end

    test "mounts: read through, writes to a read-only mount refused, no rename across mounts", %{store: store} do
      {:ok, _} = InMemory.put(store, "acme/kb", "/memories/policy.md", "be kind", :new)
      t = Memory.new(store: {InMemory, store}, mounts: %{"/memories/org" => {"acme/kb", :read_only}})

      assert {:ok, view} = call(t, %{"command" => "view", "path" => "/memories/org/policy.md"})
      assert view =~ "Here's the content of /memories/org/policy.md"
      assert {:ok, listing} = call(t, %{"command" => "view", "path" => "/memories/org"})
      assert listing =~ "\t/memories/org/policy.md"

      assert {:error, "Error: /memories/org/policy.md is read-only"} =
               call(t, %{"command" => "create", "path" => "/memories/org/policy.md", "file_text" => "x"})

      rw = Memory.new(store: {InMemory, store}, mounts: %{"/memories/team" => {"acme/team", :read_write}})
      call(rw, %{"command" => "create", "path" => "/memories/mine", "file_text" => "x"})

      assert {:error, "Error: cannot rename across mounts"} =
               call(rw, %{"command" => "rename", "old_path" => "/memories/mine", "new_path" => "/memories/team/mine"})
    end

    test "a document over max_document_bytes is refused", %{store: store} do
      t = Memory.new(store: {InMemory, store}, max_document_bytes: 10)

      assert {:error, "Error: /memories/big would be 11 bytes; the limit is 10"} =
               call(t, %{"command" => "create", "path" => "/memories/big", "file_text" => String.duplicate("x", 11)})
    end

    test "compare-and-set gives up after max_cas_retries" do
      t = Memory.new(store: {ConflictStore, nil}, max_cas_retries: 2)

      assert {:error, "Error: /memories/a was changed by another writer 3 times while editing; view it and retry"} =
               call(t, %{"command" => "str_replace", "path" => "/memories/a", "old_str" => "alpha", "new_str" => "x"})
    end

    test "a backend failure is reported as unavailable, never as missing (Review Focus #4)" do
      t = Memory.new(store: {DownStore, nil})

      for input <- [
            %{"command" => "view", "path" => "/memories/a"},
            %{"command" => "str_replace", "path" => "/memories/a", "old_str" => "a", "new_str" => "b"},
            %{"command" => "delete", "path" => "/memories/a"},
            %{"command" => "rename", "old_path" => "/memories/a", "new_path" => "/memories/b"}
          ] do
        assert {:error, "Error: memory store unavailable: :timeout"} = call(t, input)
      end
    end
  end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix format && mix test test/tools/memory_test.exs`
Expected: the `commands` tests FAIL with "Error: memory commands are not implemented".

- [ ] **Step 3: Implement `Commands`**

Replace `lib/normandy/tools/memory/commands.ex`:

```elixir
defmodule Normandy.Tools.Memory.Commands do
  @moduledoc false
  # The six memory commands. Strings follow Anthropic's memory-tool reference. Each
  # returns {:ok, text, stats} or {:error, error_type, text}; Normandy.Tools.Memory turns
  # that into the tool result and telemetry.

  alias Normandy.Behaviours.MemoryStore
  alias Normandy.Tools.Memory
  alias Normandy.Tools.Memory.{Paths, Render}

  @root "/memories"

  def run(%Memory{command: nil}, _ns), do: {:error, :invalid_input, "Error: no memory command was given"}

  def run(%Memory{command: cmd} = tool, ns) do
    case cmd.command do
      "view" -> view(tool, ns, cmd)
      "create" -> create(tool, ns, cmd)
      "str_replace" -> str_replace(tool, ns, cmd)
      "insert" -> insert(tool, ns, cmd)
      "delete" -> delete(tool, ns, cmd)
      "rename" -> rename(tool, ns, cmd)
      other -> {:error, :invalid_input, "Error: unknown command #{inspect(other)}; expected one of view, create, str_replace, insert, delete, rename"}
    end
  end

  defp view(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :read) do
      case store(tool, :get, [loc.namespace, loc.path]) do
        {:ok, %{content: content}} ->
          with {:ok, text} <- Render.file(loc.model_path, content, cmd.view_range, tool.max_view_chars),
               do: {:ok, text, %{bytes_read: byte_size(content)}}

        :not_found ->
          view_directory(tool, loc)

        {:error, reason} ->
          backend(reason)
      end
    end
  end

  defp view_directory(tool, loc) do
    case store(tool, :list, [loc.namespace, loc.path]) do
      {:ok, []} when loc.path != @root ->
        {:error, :not_found, "The path #{loc.model_path} does not exist. Please provide a valid path."}

      {:ok, entries} ->
        docs = Enum.map(entries, &%{path: Paths.to_model(&1.path, loc.mount), size: &1.size})
        limit = MemoryStore.list_limit()

        note =
          if length(entries) >= limit,
            do: "\n(listing stopped at #{limit} files; view a subdirectory to see the rest)",
            else: ""

        {:ok, Render.directory(loc.model_path, docs) <> note, %{}}

      {:error, reason} ->
        backend(reason)
    end
  end

  defp create(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :write),
         :ok <- not_root(loc, "create a file at"),
         {:ok, text} <- text(cmd, :file_text),
         :ok <- fits(tool, loc, text) do
      case store(tool, :put, [loc.namespace, loc.path, text, :any]) do
        {:ok, _version} -> {:ok, "File created successfully at: #{loc.model_path}", %{bytes_written: byte_size(text)}}
        {:error, reason} -> backend(reason)
      end
    end
  end

  defp str_replace(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :write),
         {:ok, old} <- text(cmd, :old_str),
         :ok <- non_empty(old, :old_str),
         {:ok, new} <- optional_text(cmd, :new_str) do
      edit(tool, loc, "Error: The path #{loc.model_path} does not exist. Please provide a valid path.",
        &replace_once(&1, old, new, loc.model_path),
        fn content, info -> "The memory file has been edited.\n" <> Render.snippet(content, info.first, info.last) end)
    end
  end

  defp insert(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :write),
         {:ok, text} <- text(cmd, :insert_text),
         {:ok, line} <- integer(cmd.insert_line, :insert_line) do
      edit(tool, loc, "Error: The path #{loc.model_path} does not exist",
        &insert_at(&1, line, text),
        fn _content, _info -> "The file #{loc.model_path} has been edited." end)
    end
  end

  defp delete(tool, ns, cmd) do
    with {:ok, loc} <- locate(tool, ns, cmd.path, :write),
         :ok <- not_root(loc, "delete") do
      case store(tool, :delete, [loc.namespace, loc.path, :any]) do
        :ok -> {:ok, "Successfully deleted #{loc.model_path}", %{}}
        :not_found -> delete_directory(tool, loc)
        {:error, reason} -> backend(reason)
      end
    end
  end

  defp delete_directory(tool, loc) do
    case store(tool, :delete_tree, [loc.namespace, loc.path]) do
      {:ok, 0} -> {:error, :not_found, "Error: The path #{loc.model_path} does not exist"}
      {:ok, _n} -> {:ok, "Successfully deleted #{loc.model_path}", %{}}
      {:error, reason} -> backend(reason)
    end
  end

  defp rename(tool, ns, cmd) do
    with {:ok, from} <- locate(tool, ns, cmd.old_path, :write),
         {:ok, to} <- locate(tool, ns, cmd.new_path, :write),
         :ok <- not_root(from, "rename"),
         :ok <- same_mount(from, to) do
      case store(tool, :rename, [from.namespace, from.path, to.path]) do
        {:ok, _n} -> {:ok, "Successfully renamed #{from.model_path} to #{to.model_path}", %{}}
        :not_found -> {:error, :not_found, "Error: The path #{from.model_path} does not exist"}
        {:error, :exists} -> {:error, :exists, "Error: The destination #{to.model_path} already exists"}
        {:error, reason} -> backend(reason)
      end
    end
  end

  # Read-modify-write with compare-and-set. A lost race re-reads and re-applies, up to
  # max_cas_retries extra attempts.
  defp edit(tool, loc, missing, transform, success, attempt \\ 0) do
    case store(tool, :get, [loc.namespace, loc.path]) do
      :not_found ->
        {:error, :not_found, missing}

      {:error, reason} ->
        backend(reason)

      {:ok, %{content: content, version: version}} ->
        with {:ok, updated, info} <- transform.(content),
             :ok <- fits(tool, loc, updated) do
          case store(tool, :put, [loc.namespace, loc.path, updated, version]) do
            {:ok, _} ->
              {:ok, success.(updated, info),
               %{bytes_read: byte_size(content), bytes_written: byte_size(updated), cas_retries: attempt}}

            {:error, :conflict} when attempt < tool.max_cas_retries ->
              edit(tool, loc, missing, transform, success, attempt + 1)

            {:error, :conflict} ->
              {:error, :conflict_exhausted,
               "Error: #{loc.model_path} was changed by another writer #{attempt + 1} times while editing; view it and retry"}

            {:error, reason} ->
              backend(reason)
          end
        end
    end
  end

  defp replace_once(content, old, new, path) do
    case :binary.matches(content, old) do
      [] ->
        {:error, :no_match, "No replacement was performed, old_str `#{old}` did not appear verbatim in #{path}."}

      [{pos, len}] ->
        before = binary_part(content, 0, pos)
        rest = binary_part(content, pos + len, byte_size(content) - pos - len)
        first = line_of(before)
        {:ok, before <> new <> rest, %{first: first, last: first + newlines(new)}}

      many ->
        lines = Enum.map_join(many, ", ", fn {pos, _} -> line_of(binary_part(content, 0, pos)) end)

        {:error, :ambiguous_match,
         "No replacement was performed. Multiple occurrences of old_str `#{old}` in lines: #{lines}. Please ensure it is unique"}
    end
  end

  defp insert_at(content, line, text) do
    lines = String.split(content, "\n")
    n = length(lines)

    if line < 0 or line > n do
      {:error, :invalid_line,
       "Error: Invalid `insert_line` parameter: #{line}. It should be within the range of lines of the file: [0, #{n}]"}
    else
      {:ok, lines |> List.insert_at(line, String.trim_trailing(text, "\n")) |> Enum.join("\n"), %{}}
    end
  end

  defp locate(tool, ns, path, need) do
    with {:ok, path} <- Paths.validate(path) do
      loc = Paths.resolve(path, ns, tool.mounts)

      if need == :write and loc.access == :read_only,
        do: {:error, :read_only, "Error: #{loc.model_path} is read-only"},
        else: {:ok, loc}
    end
  end

  defp not_root(%{path: @root} = loc, verb),
    do: {:error, :invalid_input, "Error: cannot #{verb} the #{loc.model_path} directory"}

  defp not_root(_loc, _verb), do: :ok

  defp same_mount(%{mount: m}, %{mount: m}), do: :ok
  defp same_mount(_from, _to), do: {:error, :invalid_input, "Error: cannot rename across mounts"}

  defp fits(tool, loc, text) do
    n = byte_size(text)

    if n > tool.max_document_bytes,
      do: {:error, :too_large, "Error: #{loc.model_path} would be #{n} bytes; the limit is #{tool.max_document_bytes}"},
      else: :ok
  end

  defp text(cmd, key) do
    case Map.get(cmd, key) do
      s when is_binary(s) -> if String.valid?(s), do: {:ok, s}, else: bad_text(key)
      _ -> bad_text(key)
    end
  end

  defp optional_text(cmd, key), do: if(Map.get(cmd, key) == nil, do: {:ok, ""}, else: text(cmd, key))

  defp bad_text(key), do: {:error, :invalid_input, "Error: `#{key}` must be a UTF-8 string"}

  defp non_empty("", key), do: {:error, :invalid_input, "Error: `#{key}` must not be empty"}
  defp non_empty(_s, _key), do: :ok

  defp integer(n, _key) when is_integer(n), do: {:ok, n}
  defp integer(_n, key), do: {:error, :invalid_input, "Error: `#{key}` must be an integer"}

  defp line_of(prefix), do: newlines(prefix) + 1
  defp newlines(s), do: length(:binary.matches(s, "\n"))

  defp store(%Memory{store: {mod, handle}}, fun, args), do: apply(mod, fun, [handle | args])

  defp backend(reason), do: {:error, :backend, "Error: memory store unavailable: #{inspect(reason)}"}
end
```

The "Multiple occurrences" test expects `lines: 4, 4`, because both `x` matches in `"a\ncolor: blue\nb\nx x"` are on line 4. If credo flags `run/2` or `edit/6` for complexity, add `# credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity` (or `.Nesting`) above that function.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix format && mix test test/tools/memory_test.exs`
Expected: all pass.

- [ ] **Step 5: Add the concurrency test to the contract (Review Focus #3)**

In `test/support/memory_store_contract.ex`, add `alias Normandy.Tools.{Context, Memory}` under the existing `alias Normandy.Behaviours.MemoryStore`. It is added here, not in Task 3, because an unused alias in `test/support` fails `compile --warnings-as-errors` in `mix precommit`. Then replace the trailing comment block that starts `# Review Focus #3` with:

```elixir
      test "concurrent inserts through the memory tool lose no edit", %{handle: h, ns: ns} do
        tool = Memory.new(store: {@store, h}, max_cas_retries: 100)
        {:ok, _} = @store.put(h, ns, "/memories/log.md", "start", :new)
        ctx = %Context{tool_call_id: "c", values: %{memory_namespace: ns}}

        1..20
        |> Enum.map(fn i ->
          Task.async(fn ->
            input = %{"command" => "insert", "path" => "/memories/log.md", "insert_line" => 0, "insert_text" => "line-#{i}"}
            Memory.run(Memory.prepare_input(tool, input), ctx)
          end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))
        |> Enum.each(&assert({:ok, _} = &1))

        {:ok, %{content: content}} = @store.get(h, ns, "/memories/log.md")
        for i <- 1..20, do: assert(content =~ "line-#{i}\n", "lost line-#{i}")
      end

      test "concurrent renames and writes leave no orphaned or duplicated document", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a/doc", "x", :new)

        tasks = [
          Task.async(fn -> @store.rename(h, ns, "/memories/a", "/memories/b") end),
          Task.async(fn -> @store.put(h, ns, "/memories/a/doc", "y", :any) end)
        ]

        Enum.each(tasks, &Task.await(&1, 5_000))
        {:ok, entries} = @store.list(h, ns, "/memories")
        paths = Enum.map(entries, & &1.path)
        assert paths == Enum.uniq(paths)
        assert length(paths) in [1, 2]
      end
```

- [ ] **Step 6: Run the contract on every backend**

Run: `mix format && mix test test/behaviours/memory_store && mix test --include postgres --include redis test/behaviours/memory_store`
Expected: all pass on InMemory, ETS, Mnesia, Postgres and Redis. Record a `VERIFY:` line for each of the five files.

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/tools/memory/commands.ex test/tools/memory_test.exs test/support/memory_store_contract.ex
git commit -m "feat(memory): memory commands with compare-and-set; concurrency contract"
```

---

### Task 11: Telemetry span and catalogue entry

**Files:**
- Modify: `lib/normandy/telemetry.ex` (moduledoc, after the `[:normandy, :tool, :execute, …]` entry at ~:106-117)
- Test: `test/tools/memory_telemetry_test.exs`

**Interfaces:**
- Consumes: the `:telemetry.span` in `Memory.run/2` (Task 9).
- Produces: the documented event `[:normandy, :memory, :command, :start | :stop | :exception]`.

- [ ] **Step 1: Write the failing test**

`test/tools/memory_telemetry_test.exs`:

```elixir
defmodule Normandy.Tools.MemoryTelemetryTest do
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{Context, Memory}

  setup do
    test_pid = self()
    id = "mem-tel-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(id, [:normandy, :memory, :command, :stop], fn _e, m, meta, _ ->
        send(test_pid, {:stop, m, meta})
      end, nil)

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp call(tool, input),
    do: Memory.run(Memory.prepare_input(tool, input), %Context{tool_call_id: "c", values: %{memory_namespace: "acme/u-1"}})

  test "stop carries bytes, retries and status; no namespace or path by default" do
    t = Memory.new(store: {InMemory, InMemory.new()})
    call(t, %{"command" => "create", "path" => "/memories/a", "file_text" => "hello"})

    assert_receive {:stop, %{bytes_written: 5, bytes_read: 0, cas_retries: 0, duration: _},
                    %{command: "create", store: InMemory, status: :ok} = meta}

    refute Map.has_key?(meta, :namespace)
    refute Map.has_key?(meta, :path)
  end

  test "an error carries error_type; telemetry_include_paths adds namespace and path" do
    t = Memory.new(store: {InMemory, InMemory.new()}, telemetry_include_paths: true)
    call(t, %{"command" => "view", "path" => "/memories/missing"})

    assert_receive {:stop, _, %{status: :error, error_type: :not_found, namespace: "acme/u-1", path: "/memories/missing"}}
  end
end
```

- [ ] **Step 2: Run the tests and confirm the catalogue test fails**

Run: `mix format && mix test test/tools/memory_telemetry_test.exs test/telemetry/catalogue_test.exs`
Expected: the memory telemetry tests PASS (the span exists since Task 9). The catalogue test FAILS with `emitted but not in the Normandy.Telemetry moduledoc: [[:normandy, :memory, :command, …]]`.

- [ ] **Step 3: Document the event**

In `lib/normandy/telemetry.ex`, after the `[:normandy, :tool, :execute, …]` block, insert:

```markdown
  ### `[:normandy, :memory, :command, :start | :stop | :exception]`

  One `Normandy.Tools.Memory` command, inside its `[:normandy, :tool, :execute]` span.

    * Start metadata: `command` (`"view" | "create" | "str_replace" | "insert" | "delete" |
      "rename"`, or `nil` when the model sent none) and `store` (the `MemoryStore` module).
      With the tool's `telemetry_include_paths: true` it adds `namespace` and `path`; both
      are off by default because they can carry personal data.
    * Stop measurements add `bytes_read`, `bytes_written` and `cas_retries`.
    * Stop metadata adds `status` (`:ok | :error`) and, on error, `error_type`
      (`:not_found | :conflict_exhausted | :invalid_path | :read_only | :too_large |
      :no_match | :ambiguous_match | :invalid_line | :exists | :backend | :invalid_input`).
      Command errors are returned to the model, not raised, so they end in `:stop`.
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix format && mix test test/tools/memory_telemetry_test.exs test/telemetry/catalogue_test.exs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/telemetry.ex test/tools/memory_telemetry_test.exs
git commit -m "feat(telemetry): document the memory command span"
```

---

### Task 12: DSL `memory` declaration and `new/1` options

**Files:**
- Modify: `lib/normandy/dsl/agent.ex`:
  - add the macro next to `tool/1` at ~:214
  - `@override_keys` at ~:322
  - the `@agent_compile_config` map at ~:362
  - `new/1` at ~:436
- Test: `test/dsl/agent_memory_test.exs`

**Interfaces:**
- Consumes: `Memory.new/1`, and `BaseAgent.init/1`'s `:tool_context`.
- Produces:
  - The DSL macro `memory(opts \\ [])`, taking `Memory.new/1` options without `:store`.
  - `new/1` options `:memory_store` (`{module, handle}`) and `:tool_context` (a map).

- [ ] **Step 1: Write the failing tests**

`test/dsl/agent_memory_test.exs`:

```elixir
defmodule Normandy.DSL.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{Memory, Registry}

  defmodule MemAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      memory(mounts: %{"/memories/org" => {"acme/kb", :read_only}})
    end
  end

  defmodule PlainAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
    end
  end

  defp client, do: %NormandyTest.Support.ModelMockup{}

  test "a declared memory is registered with the runtime store, and tool_context reaches the config" do
    store = {InMemory, InMemory.new()}

    {:ok, agent} =
      MemAgent.new(client: client(), memory_store: store, tool_context: %{memory_namespace: "acme/u-1"})

    assert {:ok, %Memory{store: ^store, mounts: %{"/memories/org" => {"acme/kb", :read_only}}}} =
             Registry.get(agent.tool_registry, "memory")

    assert agent.tool_context == %{memory_namespace: "acme/u-1"}
  end

  test "declared memory without :memory_store raises, naming the option" do
    assert_raise ArgumentError, ~r/declares memory; pass memory_store: \{module, handle\}/, fn ->
      MemAgent.new(client: client())
    end
  end

  test ":memory_store on an agent without memory raises" do
    assert_raise ArgumentError, ~r/does not declare memory/, fn ->
      PlainAgent.new(client: client(), memory_store: {InMemory, InMemory.new()})
    end
  end
end
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `mix format && mix test test/dsl/agent_memory_test.exs`
Expected: compile error, `undefined function memory/1`.

- [ ] **Step 3: Implement**

In `lib/normandy/dsl/agent.ex`, after the `tool/1` macro:

```elixir
  @doc """
  Declares persistent memory (`Normandy.Tools.Memory`). Takes `Memory.new/1`'s options
  except `:store`, which a handle such as a Redis connection cannot supply at compile
  time: pass `memory_store: {module, handle}` to `new/1`. The namespace comes from
  `tool_context` (`new/1`'s `:tool_context`).
  """
  defmacro memory(opts \\ []) do
    quote do
      Module.put_attribute(__MODULE__, :agent_memory, unquote(opts))
    end
  end
```

Add `:tool_context` to `@override_keys`. Add `memory: Module.get_attribute(__MODULE__, :agent_memory),` to the `@agent_compile_config` map.

Replace `new/1`'s body:

```elixir
      def new(opts) do
        client = Keyword.fetch!(opts, :client)
        {memory_store, opts} = Keyword.pop(opts, :memory_store)
        # Built before init/1 so a missing store raises before any process starts.
        memory_tool = memory_tool!(memory_store)
        explicit = Keyword.get(opts, :override, [])
        implicit = Keyword.drop(opts, [:client, :override])
        overrides = Keyword.merge(implicit, explicit)

        config = build_config(client, overrides)
        agent = BaseAgent.init(config)

        # Apply system prompt if defined
        agent = apply_system_prompt(agent)

        # Register tools if any
        agent = register_tools(agent)

        agent = if memory_tool, do: BaseAgent.register_tool(agent, memory_tool), else: agent

        {:ok, agent}
      end
```

Add next to `register_tools/1`:

```elixir
      defp memory_tool!(store) do
        case {@agent_compile_config.memory, store} do
          {nil, nil} ->
            nil

          {nil, _store} ->
            raise ArgumentError,
                  "#{inspect(__MODULE__)}.new/1: :memory_store was given, but the agent does not declare memory"

          {_opts, nil} ->
            raise ArgumentError,
                  "#{inspect(__MODULE__)} declares memory; pass memory_store: {module, handle} to new/1"

          {opts, store} ->
            Normandy.Tools.Memory.new([{:store, store} | opts])
        end
      end
```

Add `:memory_store` to the `new/1` docstring's options list.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `mix format && mix test test/dsl`
Expected: all pass, including the existing "an unknown option raises" test.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/dsl/agent.ex test/dsl/agent_memory_test.exs
git commit -m "feat(dsl): memory declaration with runtime store and tool_context"
```

---

### Task 13: Live e2e scenario 14

**Files:**
- Create: `e2e/14_memory.exs`
- Modify: `e2e/support.exs` (`@probe_events`)
- Modify: `e2e/README.md` (count, table row)

**Interfaces:**
- Consumes: the `E2E.Support` API (`start/2`, `client/0`, `model/0`, `turn/3`, `narrate/1`, `assert!/3`, `recalls?/2`, `events/1`, `finish/0`), `Memory`, and `MemoryStore.InMemory`.

- [ ] **Step 1: Add the probe event**

In `e2e/support.exs`, add `[:normandy, :memory, :command, :stop]` to `@probe_events`.

- [ ] **Step 2: Write the scenario**

`e2e/14_memory.exs`:

```elixir
# e2e/14_memory.exs — persistent memory across sessions, isolated by namespace.
Code.require_file("support.exs", __DIR__)
alias E2E.Support, as: S
alias Normandy.Agents.BaseAgent
alias Normandy.Behaviours.MemoryStore.InMemory
alias Normandy.Tools.Memory

S.start("14_memory", cap: 18)
handle = InMemory.new()

# A new agent per session: fresh conversation memory, same long-term store.
session = fn namespace ->
  BaseAgent.init(%{
    client: S.client(),
    model: S.model(),
    max_tokens: 600,
    name: "s14",
    max_tool_iterations: 6,
    tool_context: %{memory_namespace: namespace}
  })
  |> BaseAgent.register_tool(Memory.new(store: {InMemory, handle}))
end

ask = fn agent, n, text ->
  {_agent, r} = BaseAgent.run(agent, %{chat_message: text})
  S.turn(n, text, r.chat_message)
  r.chat_message
end

S.narrate("Session 1 (alice) stores a fact; session 2 (alice) recalls it; session 3 (bob) must not.")

ask.(session.("acme/alice"), 1, "Please remember for our future conversations: my locker code is KESTREL-42.")

{:ok, entries} = InMemory.list(handle, "acme/alice", "/memories")

stored =
  Enum.map_join(entries, "\n", fn %{path: p} ->
    {:ok, %{content: c}} = InMemory.get(handle, "acme/alice", p)
    c
  end)

S.assert!("session 1 wrote the fact into alice's memory", S.recalls?(stored, "KESTREL-42"), inspect(entries))

r2 = ask.(session.("acme/alice"), 2, "What is my locker code?")
S.assert!("session 2 (same namespace) recalls the fact", S.recalls?(r2, "KESTREL-42"), r2)

r3 = ask.(session.("acme/bob"), 3, "What is my locker code?")
S.assert!("session 3 (another namespace) does not see it", not S.recalls?(r3, "KESTREL-42"), r3)

{:ok, bob} = InMemory.list(handle, "acme/bob", "/memories")

bob_text =
  Enum.map_join(bob, "\n", fn %{path: p} ->
    {:ok, %{content: c}} = InMemory.get(handle, "acme/bob", p)
    c
  end)

S.assert!("bob's namespace holds none of alice's facts", not S.recalls?(bob_text, "KESTREL-42"), inspect(bob))

stops = S.events([:normandy, :memory, :command, :stop])
S.assert!("the model used the memory tool", stops != [], "no memory command events")

S.assert!("every memory command succeeded or failed visibly",
  Enum.all?(stops, fn {_m, meta} -> meta.status in [:ok, :error] end), inspect(stops))

S.finish()
```

- [ ] **Step 3: Update the README**

In `e2e/README.md`, change "Thirteen" to "Fourteen", and add this table row after 13:

```markdown
| 14 | memory | `Tools.Memory` across sessions, namespace isolation (InMemory store) |
```

- [ ] **Step 4: Run it live**

Run: `MIX_ENV=test mix run e2e/14_memory.exs`. This calls the live Anthropic API and needs `ANTHROPIC_API_KEY`.
Expected: every `assert!` passes and the run stops under the 18-call cap.

A recall failure is a finding: print alice's stored files and r2. Model wording and lost memory are different findings. Do not retry; report under RULE 0.

- [ ] **Step 5: Commit**

```bash
git add e2e/14_memory.exs e2e/support.exs e2e/README.md
git commit -m "test(e2e): scenario 14, persistent memory across sessions"
```

---

### Task 14: Docs: guide, MIGRATING, CLAUDE.md

**Files:**
- Create: `docs/guides/agent-memory.md`
- Modify: `MIGRATING-2.0.md` (add a section before "## New, non-breaking")
- Modify: `CLAUDE.md` (the Architecture section)

- [ ] **Step 1: Write the guide**

`docs/guides/agent-memory.md`. It must contain these sections, in order, with exact option names and defaults taken from `Normandy.Tools.Memory`:

1. **What it is.** File-like long-term memory under `/memories`, curated by the model, separate from the conversation (`AgentMemory`), and outliving sessions.
2. **Opting in.** Three code blocks, copied from spec §4: plain `BaseAgent`, a `Turn.Session` (supplement plus `tool_context` in the config), and the DSL (`memory …` plus `new(memory_store:, tool_context:)`).
3. **Namespaces and mounts.** The namespace is opaque, comes from `tool_context[:memory_namespace]`, and is never a struct field. Mounts use read-only/read-write and longest-prefix resolution, and there is no rename across mounts.
4. **Backends.** Show the setup for each backend:
   - InMemory and ETS: `new/0`.
   - Mnesia: `MemoryStore.Mnesia.create_tables(table: :my_memory)`.
   - Postgres: the host migration calling `MemoryStore.Postgres.Migration`, and the handle is the Repo.
   - Redis: `{conn, "myapp"}`, plus the note that a namespace is one cluster slot.
5. **Limits.** The five defaults from Global Constraints.
6. **Erasure.** `MemoryStore.delete_namespace/2` is app-only; the model cannot call it.
7. **Security.** Memory is a persistent prompt-injection channel, so a namespace should be no wider than the trust boundary of the people whose input reaches the agent. Neither memory nor `tool_context` may hold secrets; use `CredentialProvider`. Paths are validated, and `%` and `\` are rejected.
8. **Writing contextual tools.** Implement `BaseTool` plus `ContextualTool.run/2`. A user arity-3 `execute_fn` cannot pass context.
9. **Telemetry.** Point to `Normandy.Telemetry` for `[:normandy, :memory, :command, …]`.

- [ ] **Step 2: MIGRATING**

Add before `## New, non-breaking`:

```markdown
## 15. Agent memory and tool context

- `BaseAgentConfig` gains `tool_context` (default `%{}`), plain per-session data handed to
  tools that implement `Normandy.Tools.ContextualTool`. It is stored in the config
  template: templates saved before 2.0 rebuild with `%{}`, and `from_config/2` raises on a
  function or pid inside it. Never put secrets in it.
- `Dispatch.default_pipeline/0` and `Behaviours.Config.to_pipeline/1` now build a 4-arity
  `execute_fn` that passes the call's context. A custom 3-arity `execute_fn` still works
  for ordinary tools; a contextual tool run through it returns
  "<name> requires tool context".
- To use `Normandy.Tools.Memory` with Postgres, add a host migration calling
  `Normandy.Behaviours.MemoryStore.Postgres.Migration.up/0`; with Mnesia, call
  `Normandy.Behaviours.MemoryStore.Mnesia.create_tables/1`. See
  `docs/guides/agent-memory.md`.
```

- [ ] **Step 3: CLAUDE.md**

Add under `## Architecture`, after "### Memory & Messages":

```markdown
### Long-term Memory & Tool Context

- **`Normandy.Behaviours.MemoryStore`** - Namespaced, path-addressed document store with
  compare-and-set versions; backends InMemory, ETS, Mnesia, Postgres, Redis; shared contract
  in `test/support/memory_store_contract.ex`
- **`Normandy.Tools.Memory`** - The `memory` tool (Anthropic memory-tool commands); namespace
  from `tool_context[:memory_namespace]`, never from the struct; `Commands`/`Paths`/`Render`
  hold command logic, path rules and model-facing text
- **`Normandy.Tools.Context`** / **`Normandy.Tools.ContextualTool`** - Per-call context built
  from `BaseAgentConfig.tool_context` (plain data, persisted in the config template) and
  passed by every built-in pipeline's `execute_fn`
```

- [ ] **Step 4: Full gate**

Run: `mix precommit`
Expected: the output contains ` 0 failures`, with no credo or dialyzer findings. If dialyzer flags new code, fix the code. Add to `.dialyzer_ignore.exs` only with a reason, and ask Q first.

Then run: `mix test --include postgres --include redis`
Expected: ` 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add docs/guides/agent-memory.md MIGRATING-2.0.md CLAUDE.md
git commit -m "docs: agent memory guide, migration notes, architecture entry"
```
