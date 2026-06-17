# Phase 4a — Approval Core + Chokepoint Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the pure `Turn` FSM core real human-approval *parking* transitions (suspend/resume, no process shell yet) and split the dispatch chokepoint into `classify` (verdict) + `execute` (run), with `dispatch_one/3` re-expressed as `classify ➞ execute` so its observable behavior is byte-identical.

**Architecture:** This is the first half of Phase 4 (Phase 1-style a/b split). It changes only two source files — `dispatch.ex` (add `classify/3` + `execute/4`) and `turn.ex` (add `:awaiting_approval` transitions, two `State` fields, a factored `apply_tool_results/2`) — plus tests and the version/CHANGELOG correction. **No process shell** (`Turn.Server`) lands here; the new core events/effects are exercised by unit + property tests only. The inline `Driver` path never emits them, so the existing end-to-end suite is the parity oracle.

**Tech Stack:** Elixir, ExUnit, StreamData (`use ExUnitProperties`), the existing `Normandy.Components.{ToolCall,ToolResult}` structs.

**Spec:** `docs/superpowers/specs/2026-06-15-phase-4-gen-statem-shell-design.md` (Decisions 1 & 2). Phase 4b builds the `:gen_statem` shell on top.

**Gates (run at every Commit step):** `mix format` → `mix compile --warnings-as-errors --force` (clean) → `mix test` (full suite green). No AI attribution in commits. Add files individually — never `git add .`.

**Branch:** all work lands on `phase-4-gen-statem-shell` (already created; the design commit is `df67eb0`).

---

### Task 1: Chokepoint split — `Dispatch.classify/3` + `Dispatch.execute/4`

Split `dispatch_one/3`'s fixed pipeline into a verdict half (`classify`: registry → before-hooks → policy) and a run half (`execute`: budget → execute → record → after). Re-express `dispatch_one/3` as `classify ➞ execute`. The existing `test/agents/dispatch_test.exs` is the parity oracle and must stay green unchanged.

**Files:**
- Modify: `lib/normandy/agents/dispatch.ex:108-137`
- Test: `test/agents/dispatch_split_test.exs` (new)

- [ ] **Step 1: Write the failing test for `classify/3` and `execute/4`**

Create `test/agents/dispatch_split_test.exs`:

```elixir
defmodule Normandy.Agents.DispatchSplitTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Dispatch
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
  alias Normandy.Tools.Registry

  defmodule FakeTool do
    use Normandy.Schema
    schema do
      field(:city, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.DispatchSplitTest.FakeTool do
    def tool_name(_), do: "weather"
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}
    def run(tool), do: {:ok, "weather in #{tool.city}"}
  end

  defp config_with_tools(tools) do
    %{name: "test-agent", tool_registry: Registry.new(tools)}
  end

  describe "classify/3" do
    test "allow → {:execute, prepared_tool, normalized_call}" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c1", name: "weather", input: %{"city" => "NYC"}}

      assert {:execute, %FakeTool{city: "NYC"}, %ToolCall{id: "c1"}} =
               Dispatch.classify(config, call, Dispatch.default_pipeline())
    end

    test "deny → {:deny, error ToolResult}, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c2", name: "weather", input: %{"city" => "NYC"}}

      deny = fn _c, _call, _tool -> {:deny, %{reason: "blocked", rule_id: "R-1"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: deny}

      assert {:deny, %ToolResult{tool_call_id: "c2", is_error: true, output: %{denied: true}}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "needs_approval → {:needs_approval, prepared, call, info}" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c3", name: "weather", input: %{"city" => "NYC"}}

      approve = fn _c, _call, _tool -> {:needs_approval, %{rationale: "high-cost"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert {:needs_approval, %FakeTool{}, %ToolCall{id: "c3"}, %{rationale: "high-cost"}} =
               Dispatch.classify(config, call, pipeline)
    end

    test "registry miss → {:deny, not-found ToolResult}" do
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

    test "accepts a raw string-keyed map" do
      config = config_with_tools([%FakeTool{}])
      raw = %{"id" => "c6", "name" => "weather", "input" => %{"city" => "LA"}}

      assert {:execute, %FakeTool{city: "LA"}, %ToolCall{id: "c6"}} =
               Dispatch.classify(config, raw, Dispatch.default_pipeline())
    end
  end

  describe "execute/4" do
    test "runs the tool and returns a success ToolResult" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c7", name: "weather", input: %{"city" => "NYC"}}
      {:execute, prepared, call} = Dispatch.classify(config, call, Dispatch.default_pipeline())

      assert %ToolResult{tool_call_id: "c7", output: "weather in NYC", is_error: false} =
               Dispatch.execute(config, prepared, call, Dispatch.default_pipeline())
    end

    test "budget {:error, reason} → budget-denial result, tool not run" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c8", name: "weather", input: %{"city" => "NYC"}}
      {:execute, prepared, call} = Dispatch.classify(config, call, Dispatch.default_pipeline())

      over = fn _c, _call -> {:error, :cap} end
      pipeline = %{Dispatch.default_pipeline() | budget_check_fn: over}

      result = Dispatch.execute(config, prepared, call, pipeline)
      assert %ToolResult{tool_call_id: "c8", is_error: true, output: %{denied: true}} = result
      assert result.output.error =~ "budget check failed"
    end
  end

  describe "dispatch_one/3 == classify ➞ execute" do
    test "allow path equals execute of the classified call" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c9", name: "weather", input: %{"city" => "NYC"}}
      p = Dispatch.default_pipeline()

      {:execute, prepared, call2} = Dispatch.classify(config, call, p)
      assert Dispatch.dispatch_one(config, call, p) == Dispatch.execute(config, prepared, call2, p)
    end

    test "needs_approval still collapses to the interim denial (pending_approval: true)" do
      config = config_with_tools([%FakeTool{}])
      call = %ToolCall{id: "c10", name: "weather", input: %{"city" => "NYC"}}
      approve = fn _c, _call, _tool -> {:needs_approval, %{rationale: "r"}} end
      pipeline = %{Dispatch.default_pipeline() | policy_fn: approve}

      assert %ToolResult{is_error: true, output: %{pending_approval: true, denied: true}} =
               Dispatch.dispatch_one(config, call, pipeline)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/agents/dispatch_split_test.exs`
Expected: FAIL — `Normandy.Agents.Dispatch.classify/3 is undefined`.

- [ ] **Step 3: Implement the split in `dispatch.ex`**

In `lib/normandy/agents/dispatch.ex`, replace the entire `dispatch_one/3` block (the `@spec dispatch_one ...` header at line 108 through the raw-map clause ending at line 137) with:

```elixir
  @doc """
  Classifies one tool call: registry resolution → before-hooks → policy. Returns
  the routing decision WITHOUT executing the tool, so a durable shell can act on a
  `:needs_approval` verdict (park) before any side effect runs.

    * `{:execute, prepared, call}` — allowed; `prepared` is the built tool struct,
      `call` the post-before-hook `%ToolCall{}` (hooks may have rewritten it).
    * `{:deny, %ToolResult{}}` — registry miss, a before-hook `:halt`, or a policy
      `:deny`, already shaped into the error/denial result.
    * `{:needs_approval, prepared, call, info}` — policy wants human approval.
  """
  @spec classify(map(), ToolCall.t() | map(), Pipeline.t()) ::
          {:execute, struct(), ToolCall.t()}
          | {:deny, ToolResult.t()}
          | {:needs_approval, struct(), ToolCall.t(), map()}
  def classify(config, tool_call, pipeline \\ default_pipeline())

  def classify(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    call = %{call | input: normalize_tool_input(call.input)}

    case Registry.get(config.tool_registry, call.name) do
      {:ok, tool} ->
        case run_before_hooks(config, call, pipeline.before_hooks) do
          {:halt, %ToolResult{} = result} ->
            {:deny, result}

          {:cont, call} ->
            prepared = prepare_tool(tool, call.input)

            case pipeline.policy_fn.(config, call, prepared) do
              {:allow, _meta} -> {:execute, prepared, call}
              {:deny, info} -> {:deny, denial_result(call, info, false)}
              {:needs_approval, info} -> {:needs_approval, prepared, call, info}
            end
        end

      :error ->
        {:deny, not_found_result(call)}
    end
  end

  def classify(config, raw_call, %Pipeline{} = pipeline) when is_map(raw_call) do
    classify(config, to_tool_call(raw_call), pipeline)
  end

  @doc """
  Executes a classified (`{:execute, prepared, call}`) tool call: budget pre-check →
  execute → budget record → after-hooks. Returns a `%ToolResult{}`. Skips
  re-classification — the verdict was already decided by `classify/3` (and, for an
  approved call, by a human), so re-running policy here would re-deny/re-park.
  """
  @spec execute(map(), struct(), ToolCall.t(), Pipeline.t()) :: ToolResult.t()
  def execute(config, prepared, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case pipeline.budget_check_fn.(config, call) do
      :ok ->
        result = execute_and_wrap(config, call, prepared, pipeline.execute_fn)
        pipeline.budget_record_fn.(config, call, result)
        run_after_hooks(config, call, result, pipeline.after_hooks)

      {:error, reason} ->
        budget_denial_result(call, reason)
    end
  end

  @doc """
  Runs one tool call through the chokepoint pipeline and returns a %ToolResult{}.

  Re-expressed as `classify ➞ execute`; observable behavior is unchanged. Accepts
  either a %ToolCall{} (non-streaming) or a raw string-keyed map (streaming); the
  latter is normalized first. A `:needs_approval` verdict collapses to the interim
  denial result here (the synchronous path cannot wait for a human); only the
  durable shell parks on it.
  """
  @spec dispatch_one(map(), ToolCall.t() | map(), Pipeline.t()) :: ToolResult.t()
  def dispatch_one(config, tool_call, pipeline \\ default_pipeline())

  def dispatch_one(config, %ToolCall{} = call, %Pipeline{} = pipeline) do
    case classify(config, call, pipeline) do
      {:execute, prepared, call} -> execute(config, prepared, call, pipeline)
      {:deny, %ToolResult{} = result} -> result
      {:needs_approval, _prepared, call, info} -> denial_result(call, info, true)
    end
  end

  def dispatch_one(config, raw_call, %Pipeline{} = pipeline) when is_map(raw_call) do
    dispatch_one(config, to_tool_call(raw_call), pipeline)
  end
```

(The private helpers `run_before_hooks/3`, `prepare_tool/2`, `execute_and_wrap/4`, `run_after_hooks/4`, `denial_result/3`, `budget_denial_result/2`, `not_found_result/1`, `normalize_tool_input/1`, `to_tool_call/1` are unchanged and already defined below this block.)

- [ ] **Step 4: Run the new test + the parity oracle**

Run: `mix test test/agents/dispatch_split_test.exs test/agents/dispatch_test.exs`
Expected: PASS — new split tests green AND every existing `dispatch_test.exs` case green (parity: `dispatch_one/3` behavior unchanged).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/normandy/agents/dispatch.ex test/agents/dispatch_split_test.exs
git commit -m "feat(dispatch): split chokepoint into classify/3 + execute/4"
```

---

### Task 2: Core — add `parked_calls`/`held_results` fields + factor `apply_tool_results/2`

Add the two serializable `State` fields the approval transitions need, and factor the existing `:tool_dispatch` + `{:tool_results, …}` body into a private `apply_tool_results/2` (no behavior change — the existing `turn_test.exs` stays green). The only added effect of the refactor is that `apply_tool_results/2` also clears `parked_calls`/`held_results` (already `[]` on the normal path, so no observable change).

**Files:**
- Modify: `lib/normandy/agents/turn.ex` (State struct + type; `:tool_dispatch` clause)

- [ ] **Step 1: Add the two fields to `State`**

In `lib/normandy/agents/turn.ex`, in `defmodule State`, add to the `@type t` (after `pending_calls: [term()],`):

```elixir
            parked_calls: [term()],
            held_results: [term()],
```

and add to `defstruct` (after `pending_calls: [],`):

```elixir
              parked_calls: [],
              held_results: [],
```

- [ ] **Step 2: Factor `apply_tool_results/2` out of the `:tool_dispatch` clause**

In `lib/normandy/agents/turn.ex`, replace the existing clause:

```elixir
  def step(%State{status: :tool_dispatch} = s, {:tool_results, results}) do
    new_left = s.iterations_left - 1
    append_effects = Enum.map(results, fn r -> {:append_message, "tool", r} end)
    steering = {:emit_event, :steering, %{iterations_left: new_left}}

    if new_left <= 0 do
      # Iteration cap reached: one forced final call against the output schema,
      # then finalize regardless of tool calls (see :assistant_streaming +
      # awaiting_final in Task 5). `:steering` is where compaction will hook in
      # Phase 5; today it is only an emitted boundary event, not a resting state.
      {%{
         s
         | status: :assistant_streaming,
           awaiting_final: true,
           iterations_left: new_left,
           pending_calls: []
       },
       append_effects ++ [steering, {:call_llm, %{response_model: s.output_schema, final: true}}]}
    else
      iteration =
        {:emit_event, :iteration,
         %{iteration: s.max_iterations - new_left + 1, iterations_left: new_left}}

      {%{s | status: :assistant_streaming, iterations_left: new_left, pending_calls: []},
       append_effects ++
         [steering, iteration, {:call_llm, %{response_model: s.response_model, final: false}}]}
    end
  end
```

with a thin clause delegating to a shared helper:

```elixir
  def step(%State{status: :tool_dispatch} = s, {:tool_results, results}) do
    apply_tool_results(s, results)
  end
```

and add this private function (place it just before `defp tool_calls/1` near the bottom of the module):

```elixir
  # The batch-results transition, shared by the normal `:tool_dispatch` path and
  # the approval-resume paths (Tasks 4 & 5). Appends each result, decrements the
  # iteration counter exactly once per batch, emits the steering boundary, and
  # either continues (next LLM call) or issues the forced-final call at the cap.
  # Always clears the per-batch scratch fields (`pending_calls`, `parked_calls`,
  # `held_results`); on the normal path the latter two are already empty.
  defp apply_tool_results(%State{} = s, results) do
    new_left = s.iterations_left - 1
    append_effects = Enum.map(results, fn r -> {:append_message, "tool", r} end)
    steering = {:emit_event, :steering, %{iterations_left: new_left}}
    base = %{s | pending_calls: [], parked_calls: [], held_results: []}

    if new_left <= 0 do
      {%{base | status: :assistant_streaming, awaiting_final: true, iterations_left: new_left},
       append_effects ++ [steering, {:call_llm, %{response_model: s.output_schema, final: true}}]}
    else
      iteration =
        {:emit_event, :iteration,
         %{iteration: s.max_iterations - new_left + 1, iterations_left: new_left}}

      {%{base | status: :assistant_streaming, iterations_left: new_left},
       append_effects ++
         [steering, iteration, {:call_llm, %{response_model: s.response_model, final: false}}]}
    end
  end
```

- [ ] **Step 3: Run the existing core tests to verify no behavior change**

Run: `mix test test/agents/turn_test.exs test/agents/turn_property_test.exs test/agents/turn_inline_test.exs test/agents/turn_driver_test.exs test/agents/base_agent_turn_driver_test.exs`
Expected: PASS — the factored helper reproduces the old clause exactly; the two new fields default to `[]` and partial-match assertions are unaffected.

- [ ] **Step 4: Commit**

```bash
mix format
git add lib/normandy/agents/turn.ex
git commit -m "refactor(turn): add parked_calls/held_results, factor apply_tool_results/2"
```

---

### Task 3: Core — park transition (`:tool_dispatch` + `{:needs_approval, held, parked}`)

When a dispatched batch contains calls needing approval, the shell executes the allowed ones, **holds** their results, and feeds `{:needs_approval, held, parked}`. The core moves to `:awaiting_approval`, stores both lists (so the persisted state can resume without re-executing the allowed calls), and emits the persist + event effects. No memory append happens yet — the Claude API requires the *whole* batch's `tool_result`s together, so results append only when the batch fully resolves (Tasks 4 & 5).

**Files:**
- Modify: `lib/normandy/agents/turn.ex` (new `step/2` clause + moduledoc)
- Test: `test/agents/turn_approval_test.exs` (new)

- [ ] **Step 1: Write the failing test**

Create `test/agents/turn_approval_test.exs`:

```elixir
defmodule Normandy.Agents.TurnApprovalTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  describe "step/2 park (:tool_dispatch + :needs_approval)" do
    test "moves to :awaiting_approval, holds results + parked calls, emits event + persist" do
      parked = [%ToolCall{id: "p1", name: "billing", input: %{}}]
      held = [%ToolResult{tool_call_id: "a1", output: "ok", is_error: false}]

      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [
          %ToolCall{id: "a1", name: "weather", input: %{}},
          %ToolCall{id: "p1", name: "billing", input: %{}}
        ]
      }

      {s2, effects} = Turn.step(s, {:needs_approval, held, parked})

      assert s2.status == :awaiting_approval
      assert s2.held_results == held
      assert s2.parked_calls == parked
      assert s2.iterations_left == 5

      assert effects == [
               {:emit_event, :awaiting_approval, %{parked: 1}},
               {:persist, s2}
             ]
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/agents/turn_approval_test.exs`
Expected: FAIL — the `{:needs_approval, _, _}` event hits the total-function fallback and the turn goes `:failed` (so `s2.status == :awaiting_approval` fails).

- [ ] **Step 3: Add the park clause**

In `lib/normandy/agents/turn.ex`, add this clause immediately after the `:tool_dispatch` + `{:tool_results, results}` clause:

```elixir
  # Some calls in the batch need human approval. The shell has already executed the
  # allowed calls and passes their `held` results plus the `parked` calls. Park:
  # store both (the persisted state carries them, so resume needs no re-execution),
  # emit the awaiting-approval event, and persist. Results are NOT appended yet —
  # the whole batch's tool_results must go to the model together (Tasks 4 & 5).
  def step(%State{status: :tool_dispatch} = s, {:needs_approval, held, parked}) do
    s2 = %{s | status: :awaiting_approval, held_results: held, parked_calls: parked}
    {s2, [{:emit_event, :awaiting_approval, %{parked: length(parked)}}, {:persist, s2}]}
  end
```

Also update the moduledoc: change the sentence beginning "Seven statuses are defined; this phase exercises five. `:awaiting_approval` …" to:

```
  Seven statuses are defined. `:awaiting_approval` (suspend/resume for human
  approval) is entered when a dispatched batch parks calls; `:steering` as a
  *resting* state with compaction (Phase 5) is still reserved but not yet entered.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/agents/turn_approval_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/normandy/agents/turn.ex test/agents/turn_approval_test.exs
git commit -m "feat(turn): park batch to :awaiting_approval on :needs_approval"
```

---

### Task 4: Core — approval resolution (`:awaiting_approval` + `{:approval, decisions}`)

A `decisions` map (`tool_call_id => :approve | :reject`) resolves the parked calls. Rejected (and any id absent from `decisions` — fail-closed) become denial results. If **none** are approved, merge held + rejected results, reorder to the original batch order, and apply the batch (continue/forced-final). If **some** are approved, stash the rejected denials into `held_results` and emit `{:execute_approved, approved}` (stay `:awaiting_approval` until the approved results return in Task 5).

**Files:**
- Modify: `lib/normandy/agents/turn.ex` (new `step/2` clause + 3 private helpers + aliases)
- Test: `test/agents/turn_approval_test.exs` (append)

- [ ] **Step 1: Write the failing tests**

Append to `test/agents/turn_approval_test.exs` (inside the module, after the existing `describe`):

```elixir
  describe "step/2 approval resolution (:awaiting_approval + :approval)" do
    setup do
      pending = [
        %ToolCall{id: "a1", name: "weather", input: %{}},
        %ToolCall{id: "p1", name: "billing", input: %{}}
      ]

      held = [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}]
      parked = [%ToolCall{id: "p1", name: "billing", input: %{}}]

      s = %State{
        status: :awaiting_approval,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: pending,
        held_results: held,
        parked_calls: parked
      }

      {:ok, s: s}
    end

    test "all rejected → applies held + denial results in batch order, decrements once", %{s: s} do
      {s2, effects} = Turn.step(s, {:approval, %{"p1" => :reject}})

      assert s2.status == :assistant_streaming
      assert s2.iterations_left == 4
      assert s2.parked_calls == []
      assert s2.held_results == []

      # held a1 first, then the rejected-p1 denial, in pending_calls order.
      assert [
               {:append_message, "tool", %ToolResult{tool_call_id: "a1", output: "sunny"}},
               {:append_message, "tool",
                %ToolResult{tool_call_id: "p1", is_error: true, output: %{denied: true}}},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ] = effects
    end

    test "absent decision is treated as rejected (fail-closed)", %{s: s} do
      {s2, effects} = Turn.step(s, {:approval, %{}})

      assert s2.status == :assistant_streaming
      assert Enum.any?(effects, &match?({:append_message, "tool", %ToolResult{tool_call_id: "p1", is_error: true}}, &1))
    end

    test "some approved → stays :awaiting_approval, stashes rejected, emits :execute_approved", %{s: s} do
      {s2, effects} = Turn.step(s, {:approval, %{"p1" => :approve}})

      assert s2.status == :awaiting_approval
      assert s2.parked_calls == []
      # held still carries the already-executed a1 (no rejected calls this time).
      assert s2.held_results == [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}]

      assert effects == [{:execute_approved, [%ToolCall{id: "p1", name: "billing", input: %{}}]}]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/agents/turn_approval_test.exs`
Expected: FAIL — `{:approval, _}` hits the total-function fallback → `:failed`.

- [ ] **Step 3: Add aliases, the approval clause, and helpers**

In `lib/normandy/agents/turn.ex`, add the struct aliases just below `alias Normandy.Agents.Turn.State`:

```elixir
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult
```

Add this `step/2` clause immediately after the park clause from Task 3:

```elixir
  # Human approval decisions arrive (tool_call_id => :approve | :reject). Anything
  # not explicitly :approve is rejected (fail-closed). Build denials for rejects;
  # if none are approved, finish the batch now (held ++ denials, reordered to the
  # original tool_use order). If some are approved, stash the denials and ask the
  # shell to run the approved calls (no re-classify — Task 5 applies the merge).
  def step(%State{status: :awaiting_approval, parked_calls: parked, held_results: held} = s,
           {:approval, decisions}) do
    {approved, rejected} =
      Enum.split_with(parked, fn %ToolCall{id: id} -> Map.get(decisions, id) == :approve end)

    rejected_results = Enum.map(rejected, &rejection_result/1)

    case approved do
      [] ->
        apply_tool_results(s, reorder(held ++ rejected_results, s.pending_calls))

      _ ->
        s2 = %{s | parked_calls: [], held_results: held ++ rejected_results}
        {s2, [{:execute_approved, approved}]}
    end
  end
```

Add these private helpers next to `apply_tool_results/2`:

```elixir
  # Reorder a merged result list to match the original batch (`pending_calls`) by
  # tool_call_id, so the next user turn presents tool_result blocks in API order.
  defp reorder(results, pending_calls) do
    index =
      pending_calls
      |> Enum.with_index()
      |> Map.new(fn {%ToolCall{id: id}, i} -> {id, i} end)

    Enum.sort_by(results, fn %ToolResult{tool_call_id: id} ->
      Map.get(index, id, length(pending_calls))
    end)
  end

  # Denial result for a parked call the approver rejected (or never decided).
  defp rejection_result(%ToolCall{id: id}) do
    %ToolResult{
      tool_call_id: id,
      output: %{error: "tool call rejected by approver", denied: true, approved: false},
      is_error: true
    }
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/agents/turn_approval_test.exs`
Expected: PASS (park + 3 resolution tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/normandy/agents/turn.ex test/agents/turn_approval_test.exs
git commit -m "feat(turn): resolve approval decisions (reject/approve) from :awaiting_approval"
```

---

### Task 5: Core — approved results (`:awaiting_approval` + `{:approved_results, results}`)

After the shell runs the approved calls (via `Dispatch.execute/4`, no re-classify), it feeds their results back. Merge with the stashed `held_results`, reorder to the original batch order, and apply the batch — the same `apply_tool_results/2` that the normal and all-rejected paths use, so iterations decrement exactly once per batch.

**Files:**
- Modify: `lib/normandy/agents/turn.ex` (new `step/2` clause)
- Test: `test/agents/turn_approval_test.exs` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/agents/turn_approval_test.exs` (inside the module):

```elixir
  describe "step/2 approved results (:awaiting_approval + :approved_results)" do
    test "merges held + approved results in batch order and applies once" do
      s = %State{
        status: :awaiting_approval,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [
          %ToolCall{id: "a1", name: "weather", input: %{}},
          %ToolCall{id: "p1", name: "billing", input: %{}}
        ],
        held_results: [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}],
        parked_calls: []
      }

      approved_results = [%ToolResult{tool_call_id: "p1", output: "charged", is_error: false}]

      {s2, effects} = Turn.step(s, {:approved_results, approved_results})

      assert s2.status == :assistant_streaming
      assert s2.iterations_left == 4
      assert s2.held_results == []

      assert [
               {:append_message, "tool", %ToolResult{tool_call_id: "a1", output: "sunny"}},
               {:append_message, "tool", %ToolResult{tool_call_id: "p1", output: "charged"}},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ] = effects
    end

    test "at the iteration cap, the resolved batch issues the forced-final call" do
      s = %State{
        status: :awaiting_approval,
        iterations_left: 1,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [%ToolCall{id: "p1", name: "billing", input: %{}}],
        held_results: [],
        parked_calls: []
      }

      {s2, effects} = Turn.step(s, {:approved_results, [%ToolResult{tool_call_id: "p1", output: "x", is_error: false}]})

      assert s2.status == :assistant_streaming
      assert s2.awaiting_final == true
      assert s2.iterations_left == 0

      assert [
               {:append_message, "tool", %ToolResult{tool_call_id: "p1"}},
               {:emit_event, :steering, %{iterations_left: 0}},
               {:call_llm, %{response_model: :os, final: true}}
             ] = effects
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/agents/turn_approval_test.exs`
Expected: FAIL — `{:approved_results, _}` hits the total-function fallback → `:failed`.

- [ ] **Step 3: Add the approved-results clause**

In `lib/normandy/agents/turn.ex`, add this clause immediately after the `{:approval, decisions}` clause:

```elixir
  # The shell finished running the approved calls. Merge their results with the
  # held (allowed + rejected) results, reorder to the original batch order, and
  # apply the complete batch — decrementing the iteration counter exactly once.
  def step(%State{status: :awaiting_approval, held_results: held} = s,
           {:approved_results, results}) do
    apply_tool_results(s, reorder(held ++ results, s.pending_calls))
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/agents/turn_approval_test.exs`
Expected: PASS (all approval tests).

- [ ] **Step 5: Commit**

```bash
mix format
git add lib/normandy/agents/turn.ex test/agents/turn_approval_test.exs
git commit -m "feat(turn): apply approved results, completing the parked batch"
```

---

### Task 6: Property coverage for the approval transitions

Extend `turn_property_test.exs` so the generic invariants (never raises, status stays known, iterations never increase) cover the three new events, and add one targeted property: a park → approve → approved-results round-trip ends in a continuing/finalizing state having decremented exactly once and preserving batch order.

**Files:**
- Modify: `test/agents/turn_property_test.exs`

- [ ] **Step 1: Add the new events to `event_gen/0`**

In `test/agents/turn_property_test.exs`, add these entries to the `one_of([...])` list in `event_gen/0` (before `constant({:bogus_event, 1})`):

```elixir
      constant(
        {:needs_approval, [%ToolResult{tool_call_id: "a", output: "o", is_error: false}],
         [%ToolCall{id: "p", name: "t", input: %{}}]}
      ),
      constant({:approval, %{"p" => :approve}}),
      constant({:approval, %{"p" => :reject}}),
      constant({:approved_results, [%ToolResult{tool_call_id: "p", output: "o", is_error: false}]}),
```

- [ ] **Step 2: Add the targeted round-trip property**

Append this property to the module:

```elixir
  property "park → approve → approved-results decrements once and preserves batch order" do
    check all(left <- integer(2..6)) do
      pending = [
        %ToolCall{id: "a1", name: "weather", input: %{}},
        %ToolCall{id: "p1", name: "billing", input: %{}}
      ]

      held = [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}]
      parked = [%ToolCall{id: "p1", name: "billing", input: %{}}]

      s0 = %State{
        status: :tool_dispatch,
        iterations_left: left,
        max_iterations: 6,
        response_model: :rm,
        output_schema: :os,
        pending_calls: pending
      }

      {s1, _} = Turn.step(s0, {:needs_approval, held, parked})
      assert s1.status == :awaiting_approval

      {s2, _} = Turn.step(s1, {:approval, %{"p1" => :approve}})
      assert s2.status == :awaiting_approval

      {s3, effects} =
        Turn.step(s2, {:approved_results, [%ToolResult{tool_call_id: "p1", output: "ok", is_error: false}]})

      # exactly one decrement across the whole parked batch
      assert s3.iterations_left == left - 1

      # tool appends are in pending_calls order: a1 then p1
      appended = for {:append_message, "tool", %ToolResult{tool_call_id: id}} <- effects, do: id
      assert appended == ["a1", "p1"]
    end
  end
```

- [ ] **Step 3: Run the property suite**

Run: `mix test test/agents/turn_property_test.exs`
Expected: PASS — generic invariants hold over the new events (unexpected pairings fall to the `:failed` total-function fallback with no effects, which satisfies "known status / never raises / iterations never increase"), and the round-trip property holds.

- [ ] **Step 4: Commit**

```bash
mix format
git add test/agents/turn_property_test.exs
git commit -m "test(turn): property coverage for approval park/resume transitions"
```

---

### Task 7: Correct the mis-stamped version + CHANGELOG

The repo is stamped `1.0.0` although no `1.0.0` was tagged and `1.0.0` is reserved for the final phase. Correct Phase 3's label to its true pre-1.0 version (`0.7.0` → breaking change → `0.8.0`) and record Phase 4a under `[Unreleased]`. (Phase 4b bumps `0.8.0` → `0.9.0` when the phase completes.)

**Files:**
- Modify: `mix.exs:4` (`@version`)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Fix the version in `mix.exs`**

In `mix.exs`, change `@version "1.0.0"` to `@version "0.8.0"`.

- [ ] **Step 2: Fix the Phase 3 heading and add the Phase 4a `[Unreleased]` entry**

In `CHANGELOG.md`, change the heading `## [1.0.0] - 2026-06-12` to `## [0.8.0] - 2026-06-12`. Then, directly under the `## [Unreleased]` line, insert:

```markdown
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

### Fixed

- Corrected the version stamp: the prior `1.0.0` (Phase 3) was never tagged and
  `1.0.0` is reserved for the final phase of the harness-decomposition milestone.
  Phase 3 is re-labeled `0.8.0` (a pre-1.0 breaking change from `0.7.0`).
```

- [ ] **Step 3: Run the full suite + the compile gate**

Run: `mix format && mix compile --warnings-as-errors --force && mix test`
Expected: PASS — full suite green; version + CHANGELOG are non-code.

- [ ] **Step 4: Commit**

```bash
git add mix.exs CHANGELOG.md
git commit -m "chore: correct mis-stamped version to 0.8.0; changelog for Phase 4a"
```

---

## Final verification

After all tasks:

```bash
mix format
mix compile --warnings-as-errors --force
mix test
```

Expected: 0 failures. New tests present: `dispatch_split_test.exs` (classify/execute + equivalence), `turn_approval_test.exs` (park, reject, approve, approved-results, forced-final), the extended `turn_property_test.exs`. The existing `dispatch_test.exs` and `turn_test.exs` are green unchanged (the parity oracles). Confirm the inline path is untouched:
`grep -rn "needs_approval\|approved_results\|:approval\b" lib/normandy/agents/turn/ lib/normandy/agents/base_agent.ex` → no matches (the new events live only in `turn.ex`; no shell consumes them yet).

Then proceed to Phase 4b (the `:gen_statem` shell) — write its plan against the as-built 4a code.
