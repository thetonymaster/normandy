# Dispatch Chokepoint (Phase 1a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Funnel both of Normandy's tool-dispatch sites through a single `Normandy.Agents.Dispatch.dispatch_one/3` seam implementing the chokepoint pipeline (before-hooks → policy → budget-check → execute → budget-record → after-hooks, plus registry-miss denial), with all behaviours stubbed to current behavior so production output is unchanged.

**Architecture:** A new pure module `Normandy.Agents.Dispatch` owns tool-call normalization, input preparation, and the per-call pipeline. A `Pipeline` struct holds the behaviour functions (policy, budget, hooks, execute) so they are injectable for testing now and swappable for real behaviours in Phase 2. `BaseAgent` keeps its telemetry span by passing a span-wrapped `execute_fn`. The default pipeline is allow-all / no-op / identity, so existing agents behave identically; the deny / needs_approval / hook / budget paths are verified via injected pipelines in tests.

**Tech Stack:** Elixir, ExUnit, `:telemetry`. Existing modules touched: `Normandy.Agents.BaseAgent`, `Normandy.Components.ToolCall`, `Normandy.Components.ToolResult`, `Normandy.Tools.Registry`, `Normandy.Tools.Executor`.

**Context for the implementer:**
- This is part 1 of Phase 1 in `docs/superpowers/specs/2026-05-29-harness-decomposition-design.md`. Phase 1b (pure FSM core) and Phases 2–5 are separate plans written after this lands.
- Behavior must NOT change for existing callers. The two existing private functions `execute_one_tool_call/2` and `execute_one_streaming_tool_call/2` (in `lib/normandy/agents/base_agent.ex`) are the only dispatch sites today; they have identical pipelines differing only in input shape (`%ToolCall{}` struct vs string-keyed JSON map).
- Project rule (`CLAUDE.md`): run `mix format` before tests. If tests fail, fix them. Add files individually to git (no `git add .`).
- Run a single test with: `mix test test/path/to/test.exs:LINE`.

---

## File Structure

- **Create:** `lib/normandy/agents/dispatch.ex` — the chokepoint. Holds `Dispatch.Pipeline` struct, `Dispatch.DenialEnvelope` struct, `default_pipeline/0`, `dispatch_one/3`, plus moved-in helpers `to_tool_call/1`, `prepare_tool/2`, `normalize_tool_input/1`, `normalize_tool_field_key/2`.
- **Create:** `test/normandy/agents/dispatch_test.exs` — unit tests for the seam.
- **Modify:** `lib/normandy/agents/base_agent.ex` — both dispatch sites delegate to `Dispatch.dispatch_one/3`; add `base_agent_pipeline/0` and `span_execute/3`; remove the now-dead private helpers.

---

## Task 1: Pipeline and DenialEnvelope structs + default pipeline

**Files:**
- Create: `lib/normandy/agents/dispatch.ex`
- Test: `test/normandy/agents/dispatch_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/normandy/agents/dispatch_test.exs
defmodule Normandy.Agents.DispatchTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Dispatch
  alias Normandy.Agents.Dispatch.Pipeline

  describe "default_pipeline/0" do
    test "returns a Pipeline with allow-all policy and no-op budget/hooks" do
      p = Dispatch.default_pipeline()

      assert %Pipeline{} = p
      assert p.before_hooks == []
      assert p.after_hooks == []
      assert p.policy_fn.(%{}, %{}, %{}) == {:allow, %{}}
      assert p.budget_check_fn.(%{}, %{}) == :ok
      assert p.budget_record_fn.(%{}, %{}, %{}) == :ok
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/normandy/agents/dispatch_test.exs`
Expected: FAIL — `module Normandy.Agents.Dispatch is not available`.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/normandy/agents/dispatch.ex
defmodule Normandy.Agents.Dispatch do
  @moduledoc """
  The single chokepoint every agent tool call flows through.

  `dispatch_one/3` runs one tool call through a fixed pipeline:
  registry resolution → before-hooks → policy check → budget pre-check →
  execute → budget record → after-hooks. The behaviours are carried on a
  `Pipeline` struct so they can be injected in tests and replaced by real
  implementations in later phases. The default pipeline is allow-all / no-op /
  identity, preserving current behavior.
  """

  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Executor
  alias Normandy.Tools.Registry

  defmodule DenialEnvelope do
    @moduledoc "Structured record of a denied (or approval-pending) tool call."
    @type t :: %__MODULE__{
            call_id: String.t() | nil,
            reason: String.t(),
            rule_id: String.t() | nil,
            rationale: String.t() | nil,
            pending_approval: boolean()
          }
    defstruct call_id: nil,
              reason: "denied",
              rule_id: nil,
              rationale: nil,
              pending_approval: false
  end

  defmodule Pipeline do
    @moduledoc "Carries the behaviour functions the chokepoint consults."
    @type t :: %__MODULE__{
            before_hooks: [function()],
            policy_fn: function(),
            budget_check_fn: function(),
            budget_record_fn: function(),
            execute_fn: function(),
            after_hooks: [function()]
          }
    defstruct before_hooks: [],
              policy_fn: nil,
              budget_check_fn: nil,
              budget_record_fn: nil,
              execute_fn: nil,
              after_hooks: []
  end

  @doc """
  The default pipeline: allow-all policy, no-op budget, no hooks, bare executor.
  Reproduces current behavior. Callers (e.g. BaseAgent) override `execute_fn`
  to add telemetry, and later phases override the behaviour functions.
  """
  @spec default_pipeline() :: Pipeline.t()
  def default_pipeline do
    %Pipeline{
      before_hooks: [],
      policy_fn: fn _config, _call, _tool -> {:allow, %{}} end,
      budget_check_fn: fn _config, _call -> :ok end,
      budget_record_fn: fn _config, _call, _result -> :ok end,
      execute_fn: fn _config, tool, _name -> Executor.execute_tool(tool) end,
      after_hooks: []
    }
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/normandy/agents/dispatch_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/dispatch.ex test/normandy/agents/dispatch_test.exs
git commit -m "feat(dispatch): add Pipeline/DenialEnvelope structs and default pipeline"
```

---

## Task 2: tool-call normalization and input preparation

**Files:**
- Modify: `lib/normandy/agents/dispatch.ex`
- Test: `test/normandy/agents/dispatch_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `test/normandy/agents/dispatch_test.exs` (inside the module, after the existing `describe`):

```elixir
  alias Normandy.Components.ToolCall

  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:city, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.DispatchTest.FakeTool do
    def tool_name(_), do: "weather"
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}
    def run(tool), do: {:ok, "weather in #{tool.city}"}
  end

  describe "to_tool_call/1" do
    test "passes a %ToolCall{} through unchanged" do
      call = %ToolCall{id: "c1", name: "weather", input: %{city: "NYC"}}
      assert Dispatch.to_tool_call(call) == call
    end

    test "normalizes a string-keyed JSON map into a %ToolCall{}" do
      raw = %{"id" => "c2", "name" => "weather", "input" => %{"city" => "LA"}}

      assert Dispatch.to_tool_call(raw) ==
               %ToolCall{id: "c2", name: "weather", input: %{"city" => "LA"}}
    end

    test "decodes a JSON-string input and degrades non-map input to %{}" do
      raw = %{"id" => "c3", "name" => "weather", "input" => ~s({"city":"SF"})}
      assert Dispatch.to_tool_call(raw).input == %{"city" => "SF"}

      bad = %{"id" => "c4", "name" => "weather", "input" => [1, 2, 3]}
      assert Dispatch.to_tool_call(bad).input == %{}
    end
  end

  describe "prepare_tool/2" do
    test "maps known string keys onto struct fields and drops unknown keys" do
      prepared = Dispatch.prepare_tool(%FakeTool{}, %{"city" => "NYC", "bogus" => 1})
      assert prepared == %FakeTool{city: "NYC"}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/normandy/agents/dispatch_test.exs`
Expected: FAIL — `function Normandy.Agents.Dispatch.to_tool_call/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Add these functions inside `Normandy.Agents.Dispatch` (after `default_pipeline/0`):

```elixir
  @doc "Normalizes a raw LLM tool call (struct or string-keyed map) into a %ToolCall{}."
  @spec to_tool_call(ToolCall.t() | map()) :: ToolCall.t()
  def to_tool_call(%ToolCall{} = call), do: call

  def to_tool_call(%{} = raw) do
    %ToolCall{
      id: raw["id"] || raw[:id],
      name: raw["name"] || raw[:name],
      input: normalize_tool_input(raw["input"] || raw[:input])
    }
  end

  @doc """
  Builds the tool struct from LLM-supplied input. Uses the tool's
  `prepare_input/2` if exported; otherwise maps known keys onto struct fields.
  """
  @spec prepare_tool(struct(), map()) :: struct()
  def prepare_tool(tool, input) do
    if function_exported?(tool.__struct__, :prepare_input, 2) do
      tool.__struct__.prepare_input(tool, input)
    else
      input_with_atom_keys =
        Enum.reduce(input, %{}, fn {key, value}, acc ->
          case normalize_tool_field_key(tool, key) do
            {:ok, atom_key} -> Map.put(acc, atom_key, value)
            :error -> acc
          end
        end)

      struct(tool, input_with_atom_keys)
    end
  end

  @doc false
  def normalize_tool_input(nil), do: %{}
  def normalize_tool_input(input) when is_map(input), do: input

  def normalize_tool_input(input) when is_binary(input) do
    case Poison.decode(input) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  def normalize_tool_input(_), do: %{}

  # Map an LLM-supplied input key (atom or binary) to a struct field atom on the
  # tool, returning :error for keys that don't correspond to any field. NEVER
  # calls String.to_atom/1 on untrusted input (atom-table exhaustion / DoS).
  @doc false
  def normalize_tool_field_key(tool, key) when is_atom(key) do
    if key != :__struct__ and Map.has_key?(tool, key), do: {:ok, key}, else: :error
  end

  def normalize_tool_field_key(tool, key) when is_binary(key) do
    Enum.find_value(Map.keys(tool), :error, fn field ->
      if is_atom(field) and field != :__struct__ and Atom.to_string(field) == key do
        {:ok, field}
      end
    end)
  end

  def normalize_tool_field_key(_tool, _key), do: :error
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/normandy/agents/dispatch_test.exs`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/dispatch.ex test/normandy/agents/dispatch_test.exs
git commit -m "feat(dispatch): add tool-call normalization and input preparation"
```

---

## Task 3: dispatch_one happy path (allow → execute → result)

**Files:**
- Modify: `lib/normandy/agents/dispatch.ex`
- Test: `test/normandy/agents/dispatch_test.exs`

- [ ] **Step 1: Write the failing test**

Append a helper and a `describe` block to the test module:

```elixir
  alias Normandy.Tools.Registry
  alias Normandy.Components.ToolResult

  defp config_with_tools(tools) do
    %{name: "test-agent", tool_registry: Registry.new(tools)}
  end

  describe "dispatch_one/3 happy path" do
    test "allow → executes the tool and returns a success ToolResult" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{
               tool_call_id: "c1",
               output: "weather in NYC",
               is_error: false
             } = result
    end

    test "accepts a raw string-keyed map (streaming shape)" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c9", "name" => "weather", "input" => %{"city" => "LA"}}

      result = Dispatch.dispatch_one(config, raw, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c9", output: "weather in LA", is_error: false} = result
    end
  end
```

Note: `config` here is a plain map with only `:name` and `:tool_registry`, which is all `dispatch_one/3` reads. The real caller passes a `%BaseAgentConfig{}`; structural access (`config.tool_registry`, `config.name`) works for both.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/normandy/agents/dispatch_test.exs`
Expected: FAIL — `function Normandy.Agents.Dispatch.dispatch_one/3 is undefined`.

- [ ] **Step 3: Write the implementation**

Add to `Normandy.Agents.Dispatch` (after `prepare_tool/2`):

```elixir
  @doc """
  Runs one tool call through the chokepoint pipeline and returns a %ToolResult{}.

  Accepts either a %ToolCall{} (non-streaming) or a raw string-keyed map
  (streaming); the latter is normalized first.
  """
  @spec dispatch_one(map(), ToolCall.t() | map(), Pipeline.t()) :: ToolResult.t()
  def dispatch_one(config, tool_call, pipeline \\ default_pipeline())

  def dispatch_one(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case Registry.get(config.tool_registry, call.name) do
      {:ok, tool} ->
        with {:cont, call} <- run_before_hooks(config, call, pipeline.before_hooks),
             prepared = prepare_tool(tool, call.input),
             {:allow, _meta} <- pipeline.policy_fn.(config, call, prepared),
             :ok <- pipeline.budget_check_fn.(config, call) do
          result = execute_and_wrap(config, call, prepared, pipeline.execute_fn)
          pipeline.budget_record_fn.(config, call, result)
          run_after_hooks(config, call, result, pipeline.after_hooks)
        else
          {:halt, %ToolResult{} = result} -> result
          {:deny, info} -> denial_result(call, info, false)
          {:needs_approval, info} -> denial_result(call, info, true)
          {:error, reason} -> budget_denial_result(call, reason)
        end

      :error ->
        not_found_result(call)
    end
  end

  def dispatch_one(config, raw_call, %Pipeline{} = pipeline) when is_map(raw_call) do
    dispatch_one(config, to_tool_call(raw_call), pipeline)
  end

  defp execute_and_wrap(config, call, prepared, execute_fn) do
    case execute_fn.(config, prepared, call.name) do
      {:ok, result} ->
        %ToolResult{tool_call_id: call.id, output: result, is_error: false}

      {:error, error} ->
        %ToolResult{tool_call_id: call.id, output: %{error: error}, is_error: true}
    end
  end

  defp run_before_hooks(_config, call, []), do: {:cont, call}

  defp run_before_hooks(config, call, [hook | rest]) do
    case hook.(config, call) do
      {:cont, %ToolCall{} = call} -> run_before_hooks(config, call, rest)
      {:halt, %ToolResult{} = result} -> {:halt, result}
    end
  end

  defp run_after_hooks(_config, _call, result, []), do: result

  defp run_after_hooks(config, call, result, [hook | rest]) do
    run_after_hooks(config, call, hook.(config, call, result), rest)
  end

  defp denial_result(call, info, pending?) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{
        error: Map.get(info, :reason, "denied by policy"),
        rationale: Map.get(info, :rationale),
        rule_id: Map.get(info, :rule_id),
        denied: true,
        pending_approval: pending?
      },
      is_error: true
    }
  end

  defp budget_denial_result(call, reason) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{error: "budget check failed: #{inspect(reason)}", denied: true},
      is_error: true
    }
  end

  defp not_found_result(call) do
    %ToolResult{
      tool_call_id: call.id,
      output: %{error: "Tool '#{call.name}' not found in registry"},
      is_error: true
    }
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/normandy/agents/dispatch_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/dispatch.ex test/normandy/agents/dispatch_test.exs
git commit -m "feat(dispatch): implement dispatch_one pipeline (allow path + registry miss)"
```

---

## Task 4: registry-miss denial

**Files:**
- Test: `test/normandy/agents/dispatch_test.exs`

(The implementation already exists from Task 3 via `not_found_result/1`; this task adds the regression test that pins the behavior.)

- [ ] **Step 1: Write the failing test**

Append to the `describe "dispatch_one/3 happy path"` block (or a new `describe`):

```elixir
  describe "dispatch_one/3 registry miss" do
    test "unknown tool → error ToolResult, tool not executed" do
      config = config_with_tools([])
      call = %ToolCall{id: "c5", name: "nope", input: %{}}

      result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

      assert %ToolResult{
               tool_call_id: "c5",
               is_error: true,
               output: %{error: "Tool 'nope' not found in registry"}
             } = result
    end
  end
```

- [ ] **Step 2: Run test to verify it passes immediately**

Run: `mix test test/normandy/agents/dispatch_test.exs`
Expected: PASS (already implemented). If it FAILS, fix `not_found_result/1` before continuing.

- [ ] **Step 3: Commit**

```bash
git add test/normandy/agents/dispatch_test.exs
git commit -m "test(dispatch): pin registry-miss denial behavior"
```

---

## Task 5: policy deny → denial ToolResult carrying rationale

**Files:**
- Test: `test/normandy/agents/dispatch_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  describe "dispatch_one/3 policy outcomes" do
    test "deny → error ToolResult with rationale fed into output, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c6", name: "weather", input: %{"city" => "NYC"}}

      deny_policy = fn _config, _call, _tool ->
        {:deny,
         %{reason: "weather tool blocked", rule_id: "R-7", rationale: "shares state with billing"}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny_policy}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{
               tool_call_id: "c6",
               is_error: true,
               output: %{
                 error: "weather tool blocked",
                 rule_id: "R-7",
                 rationale: "shares state with billing",
                 denied: true,
                 pending_approval: false
               }
             } = result
    end

    test "needs_approval → tagged denial result with pending_approval: true" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c7", name: "weather", input: %{"city" => "NYC"}}

      approval_policy = fn _config, _call, _tool ->
        {:needs_approval, %{reason: "human review", rationale: "high-cost op"}}
      end

      pipeline = %{Dispatch.default_pipeline() | policy_fn: approval_policy}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{
               tool_call_id: "c7",
               is_error: true,
               output: %{denied: true, pending_approval: true, rationale: "high-cost op"}
             } = result
    end
  end
```

- [ ] **Step 2: Run test to verify it passes immediately**

Run: `mix test test/normandy/agents/dispatch_test.exs`
Expected: PASS (deny/needs_approval handling already implemented in Task 3).

> Note: `needs_approval` returning a tagged denial is the **interim** Phase-1 behavior. The suspendable-turn plan (Phase 4) replaces this branch with real parking/suspension. The default pipeline never returns `needs_approval`, so production behavior is unaffected.

- [ ] **Step 3: Commit**

```bash
git add test/normandy/agents/dispatch_test.exs
git commit -m "test(dispatch): verify deny carries rationale and needs_approval is tagged"
```

---

## Task 6: before-hook halt and after-hook transform

**Files:**
- Test: `test/normandy/agents/dispatch_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  describe "dispatch_one/3 hooks" do
    test "before-hook returning {:halt, result} short-circuits, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c8", name: "weather", input: %{"city" => "NYC"}}

      halting_hook = fn _config, %ToolCall{id: id} ->
        {:halt, %ToolResult{tool_call_id: id, output: %{error: "blocked by hook"}, is_error: true}}
      end

      pipeline = %{Dispatch.default_pipeline() | before_hooks: [halting_hook]}

      result = Dispatch.dispatch_one(config, call, pipeline)
      assert result == %ToolResult{tool_call_id: "c8", output: %{error: "blocked by hook"}, is_error: true}
    end

    test "before-hook returning {:cont, call} can rewrite input" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c10", name: "weather", input: %{"city" => "NYC"}}

      rewrite_hook = fn _config, %ToolCall{} = c ->
        {:cont, %{c | input: %{"city" => "Boston"}}}
      end

      pipeline = %{Dispatch.default_pipeline() | before_hooks: [rewrite_hook]}

      result = Dispatch.dispatch_one(config, call, pipeline)
      assert result.output == "weather in Boston"
    end

    test "after-hook transforms the result" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c11", name: "weather", input: %{"city" => "NYC"}}

      redact_hook = fn _config, _call, %ToolResult{} = r ->
        %{r | output: "REDACTED"}
      end

      pipeline = %{Dispatch.default_pipeline() | after_hooks: [redact_hook]}

      result = Dispatch.dispatch_one(config, call, pipeline)
      assert result.output == "REDACTED"
    end
  end
```

- [ ] **Step 2: Run test to verify it passes immediately**

Run: `mix test test/normandy/agents/dispatch_test.exs`
Expected: PASS (hook handling implemented in Task 3).

- [ ] **Step 3: Commit**

```bash
git add test/normandy/agents/dispatch_test.exs
git commit -m "test(dispatch): verify before-hook halt/rewrite and after-hook transform"
```

---

## Task 7: budget check failure and record invocation

**Files:**
- Test: `test/normandy/agents/dispatch_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
  describe "dispatch_one/3 budget" do
    test "budget_check_fn returning {:error, reason} denies before executing" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c12", name: "weather", input: %{"city" => "NYC"}}

      over_budget = fn _config, _call -> {:error, :cap_exceeded} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over_budget}

      result = Dispatch.dispatch_one(config, call, pipeline)

      assert %ToolResult{tool_call_id: "c12", is_error: true, output: %{denied: true}} = result
      assert result.output.error =~ "budget check failed"
    end

    test "budget_record_fn is called with the success result" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c13", name: "weather", input: %{"city" => "NYC"}}
      test_pid = self()

      recorder = fn _config, _call, result ->
        send(test_pid, {:recorded, result})
        :ok
      end

      pipeline = %{Dispatch.default_pipeline() | budget_record_fn: recorder}

      Dispatch.dispatch_one(config, call, pipeline)

      assert_receive {:recorded, %ToolResult{output: "weather in NYC", is_error: false}}
    end
  end
```

- [ ] **Step 2: Run test to verify it passes immediately**

Run: `mix test test/normandy/agents/dispatch_test.exs`
Expected: PASS (budget handling implemented in Task 3).

- [ ] **Step 3: Commit**

```bash
git add test/normandy/agents/dispatch_test.exs
git commit -m "test(dispatch): verify budget pre-check denial and post-record invocation"
```

---

## Task 8: integrate the chokepoint into BaseAgent's non-streaming site

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (alias + `execute_one_tool_call/2` at ~`:1374` + new private helpers)

- [ ] **Step 1: Add the alias and helpers, then rewrite `execute_one_tool_call/2`**

First, add the alias near the other aliases at the top of `Normandy.Agents.BaseAgent`:

```elixir
  alias Normandy.Agents.Dispatch
```

Replace the entire body of `execute_one_tool_call/2` (currently `base_agent.ex:1374-1415`) with:

```elixir
  defp execute_one_tool_call(config, tool_call) do
    Dispatch.dispatch_one(config, tool_call, base_agent_pipeline())
  end
```

Add these two private helpers (place them next to `with_tool_execute_span/3`):

```elixir
  # The chokepoint pipeline BaseAgent uses: default behaviours (allow-all,
  # no-op budget, no hooks) plus a telemetry-instrumented execute_fn so tool
  # spans keep nesting under the agent.run span. Real behaviours are wired in
  # the Phase 2 plan.
  defp base_agent_pipeline do
    %{Dispatch.default_pipeline() | execute_fn: &span_execute/3}
  end

  defp span_execute(config, prepared_tool, tool_name) do
    tool_meta = %{tool_name: tool_name, agent_name: config.name}

    with_tool_execute_span(config, tool_name, tool_meta, fn ->
      r = Executor.execute_tool(prepared_tool)
      {r, Map.put(tool_meta, :status, elem(r, 0))}
    end)
  end
```

- [ ] **Step 2: Run the existing agent test suite to verify no behavior change**

Run: `mix format && mix test test/normandy/agents/`
Expected: PASS — all existing BaseAgent tests green (non-streaming tool execution behaves identically).

- [ ] **Step 3: Commit**

```bash
git add lib/normandy/agents/base_agent.ex
git commit -m "refactor(base_agent): route non-streaming tool dispatch through Dispatch chokepoint"
```

---

## Task 9: integrate the chokepoint into BaseAgent's streaming site

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (`execute_one_streaming_tool_call/2` at ~`:1419`)

- [ ] **Step 1: Rewrite `execute_one_streaming_tool_call/2`**

Replace the entire body of `execute_one_streaming_tool_call/2` (currently `base_agent.ex:1419-1468`) with:

```elixir
  # Streaming-loop variant: tool_call is a string-keyed map (raw LLM JSON).
  # Dispatch.dispatch_one/3 normalizes it into a %ToolCall{} before running the
  # same chokepoint pipeline as the non-streaming path.
  defp execute_one_streaming_tool_call(config, tool_call) do
    Dispatch.dispatch_one(config, tool_call, base_agent_pipeline())
  end
```

- [ ] **Step 2: Run the streaming tests**

Run: `mix format && mix test test/normandy/agents/`
Expected: PASS — streaming tool execution behaves identically.

- [ ] **Step 3: Commit**

```bash
git add lib/normandy/agents/base_agent.ex
git commit -m "refactor(base_agent): route streaming tool dispatch through Dispatch chokepoint"
```

---

## Task 10: remove the now-dead private helpers from BaseAgent

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex`

- [ ] **Step 1: Confirm the helpers are unused elsewhere**

Run: `grep -n "normalize_tool_field_key\|normalize_tool_input" lib/normandy/agents/base_agent.ex`
Expected: matches ONLY on the `defp` definitions (lines ~1054 and ~1081 region), no remaining call sites. If any call site remains outside the two functions rewritten in Tasks 8–9, stop and route it through `Dispatch` first.

- [ ] **Step 2: Delete the dead definitions**

Remove from `lib/normandy/agents/base_agent.ex`:
- `defp normalize_tool_input(nil)` through `defp normalize_tool_input(_), do: %{}` (the four clauses at ~`:1054-1064`).
- The comment block and `defp normalize_tool_field_key/2` clauses at ~`:1066-1093`.

These now live (as public `@doc false` functions) in `Normandy.Agents.Dispatch`.

- [ ] **Step 3: Compile (catch unused warnings) and run the full suite**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: Compiles with no warnings; full suite PASSES.

If `mix compile --warnings-as-errors` flags any other now-unused helper (e.g. a private function only the deleted code called), remove it too and re-run.

- [ ] **Step 4: Commit**

```bash
git add lib/normandy/agents/base_agent.ex
git commit -m "refactor(base_agent): drop tool-input helpers now owned by Dispatch"
```

---

## Task 11: full-suite verification and formatting gate

**Files:** none (verification only)

- [ ] **Step 1: Format**

Run: `mix format`

- [ ] **Step 2: Full suite**

Run: `mix test`
Expected: ALL tests pass (existing + new `dispatch_test.exs`). Record the summary line (e.g. "N tests, 0 failures").

- [ ] **Step 3: Compile clean**

Run: `mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 4: Commit any formatting changes**

```bash
git status --short
# if mix format changed files:
git add -p
git commit -m "chore(dispatch): format"
```

---

## Self-Review (completed during planning)

**Spec coverage (Phase 1a = the chokepoint, #1):**
- Single seam both paths funnel through → Tasks 8, 9. ✓
- Pipeline order before→policy→budget→execute→budget→after → Task 3 impl. ✓
- Registry miss → denial → Tasks 3/4. ✓
- Deny carries rationale fed back to model → Task 5. ✓
- needs_approval handling (interim; real parking deferred to Phase 4) → Task 5, documented. ✓
- before/after hooks → Task 6. ✓
- Budget pre-check + record → Task 7. ✓
- Behaviours default to current behavior (allow-all/no-op) → Task 1 `default_pipeline/0`; verified by existing suite in Tasks 8–10. ✓
- **Deferred (own plans):** pure FSM core (Phase 1b), real behaviour impls + config wiring (Phase 2), SessionStore (Phase 3), gen_statem shell/approval (Phase 4), compaction (Phase 5). Fail-closed policy-timeout semantics belong to Phase 2 (real PolicyEngine) since the stub never times out.

**Placeholder scan:** none — every code step contains complete code.

**Type consistency:** `dispatch_one/3`, `to_tool_call/1`, `prepare_tool/2`, `default_pipeline/0`, `Pipeline` field names (`before_hooks`, `policy_fn`, `budget_check_fn`, `budget_record_fn`, `execute_fn`, `after_hooks`), and `execute_fn` arity `(config, tool, name)` are consistent across the Dispatch impl (Task 3) and the BaseAgent `span_execute/3` (Task 8). `ToolResult` fields (`tool_call_id`, `output`, `is_error`) match `lib/normandy/components/tool_result.ex`. `ToolCall` fields (`id`, `name`, `input`) match `lib/normandy/components/tool_call.ex`.
