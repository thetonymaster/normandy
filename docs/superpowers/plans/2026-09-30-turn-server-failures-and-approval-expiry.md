# Turn.Server failures, events and approval expiry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Turn.Server` replies errors instead of crashing, reports events truthfully, makes approval expiry honest and configurable, and repairs unanswered `tool_use` batches.

**Architecture:** Pure changes go in the `Turn` core (`lib/normandy/agents/turn.ex`): event meta, effect order, a new `{:approval_expired, _}` event, and `unanswered_tool_calls/1`. Shell changes go in `Turn.Server` (`lib/normandy/agents/turn/server.ex`): guarded handler calls, subscriber isolation, the expiry option and telemetry, and the dangling-batch repair. `Turn.Session` and `Coordination.AgentProcess` only forward the new option.

**Tech Stack:** Elixir, `:gen_statem`, ExUnit, `:telemetry`, `Logger`.

**Spec:** `docs/superpowers/specs/2026-09-30-turn-server-failures-and-approval-expiry-design.md`

## Global Constraints

- Branch `feat/claudio-0.7-migration`. Never push.
- Commits: **no AI attribution** — no `Co-Authored-By`, no "Generated with", no `Claude-Session` line.
- `git add` each file by name. `git add .` / `git add -A` are forbidden.
- Run `mix format` before running tests.
- Every failing test must be fixed, including tests outside the task.
- Never edit `@version` in `mix.exs` or `CHANGELOG.md` (cocogitto owns them).
- Log lines and error messages never inspect a config, a client struct, `client.options` or `req_options`.
- Credo complexity/nesting findings: inline `# credo:disable-for-next-line <Check>`, never a global threshold change.
- Run commands from `/Users/antonio/personal/normandy`.
- Tool result wording, verbatim:
  - expiry: `"approval timed out: no approver responded within #{ms}ms"`
  - repair: `"tool call interrupted: the previous turn ended before a result was recorded; the tool may or may not have run"`
- New error reasons, verbatim: `{:rejected, exception}`, `{:handler_crashed, name, exception_or_term}` (name ∈ `:append | :convert | :validate | :guard | :emit`), `{:approval_timeout, [tool_call_id]}`.
- New telemetry, verbatim: `[:normandy, :turn, :subscriber, :exception]`, `[:normandy, :turn, :approval, :expired]`.

## Review Focus

1. A subscriber that `exit`s or `throw`s (not only raises) must not fail the turn. Test in Task 4.
2. A late `approve/2` arriving after a `:fail` expiry must be dropped; the server stays alive and the next turn works. Test in Task 5.
3. An approval that arrives in time must not be expired while the approved tool runs longer than `approval_timeout_ms`. Test in Task 5.
4. A repaired batch must not be repaired again on the following turn (no duplicate `tool_result`, which the API also rejects). Test in Task 6.
5. A turn that failed with `{:handler_crashed, _, _}` must leave the session usable for the next turn. Test in Task 4.

## Plan refinement over the spec

- §1 says to log `Exception.format(kind, reason, stacktrace)`. Stack frames can carry call arguments (a `FunctionClauseError`'s top frame does), and an argument may be the config. The handler-crash log therefore uses `Exception.format_banner/2` plus `Exception.format_stacktrace/1` over frames reduced to arities (`arity_only/1`, Task 4).

## File map

| File | Tasks | Responsibility |
|---|---|---|
| `lib/normandy/agents/turn.ex` | 1, 2, 3 | pure core: events, effect order, expiry transition, unanswered detection |
| `lib/normandy/agents/turn/server.ex` | 4, 5, 6, 7 | shell: failure replies, emit/subscriber, expiry shell, repair, moduledoc |
| `lib/normandy/agents/turn/session.ex` | 5 | forward `:on_approval_timeout` |
| `lib/normandy/coordination/agent_process.ex` | 5 | forward `:on_approval_timeout` |
| `test/agents/turn_test.exs` | 1, 3 | core tests |
| `test/agents/turn_approval_test.exs` | 1, 2 | core approval tests |
| `test/agents/turn_compaction_test.exs` | 1 | core compaction tests (effect order) |
| `test/agents/turn/resume_test.exs` | 1 | core resume tests |
| `test/agents/turn/server_test.exs` | 1, 4, 5, 6 | server tests |
| `test/agents/turn/session_test.exs` | 5 | option forwarding |
| `test/coordination/agent_process_server_test.exs` | 5 | option forwarding end to end |
| `MIGRATING-2.0.md`, `CLAUDE.md` | 7 | docs |

---

### Task 1: Core event fixes — final iteration, persist before `:steering`, resume re-announces

**Files:**
- Modify: `lib/normandy/agents/turn.ex` (`:start` clause ~:104, `:steering` `:compaction_done` clauses ~:163-178, park clause ~:194, `resume/1` ~:279, `apply_tool_results/2` ~:296)
- Test: `test/agents/turn_test.exs`, `test/agents/turn_approval_test.exs`, `test/agents/turn_compaction_test.exs`, `test/agents/turn/resume_test.exs`, `test/agents/turn/server_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: every `{:emit_event, :iteration, meta}` has `meta.final :: boolean()`; the forced-final call is preceded by `{:emit_event, :iteration, %{iteration: max + 1 - left, iterations_left: left, final: true}}`; `apply_tool_results/2` effects are `appends ++ [{:persist, s2}, {:emit_event, :steering, _}, {:maybe_compact, _}]`; `{:emit_event, :awaiting_approval, %{parked: n, resumed: boolean()}}`; `Turn.resume/1` on `:awaiting_approval` returns `{s, [{:emit_event, :awaiting_approval, %{parked: length(s.parked_calls), resumed: true}}]}`.

- [ ] **Step 1: Update existing core tests to the new expectations**

In `test/agents/turn_test.exs`:

- In test `":start transitions to :assistant_streaming and emits iteration + call_llm"` replace
  `{:emit_event, :iteration, %{iteration: 1, iterations_left: 5}},` with
  `{:emit_event, :iteration, %{iteration: 1, iterations_left: 5, final: false}},`
- In test `"appends each tool result, decrements iterations_left, emits steering + iteration, calls LLM"` replace

  ```elixir
               {:emit_event, :steering, %{iterations_left: 4}},
               {:persist, s2},
  ```
  with
  ```elixir
               {:persist, s2},
               {:emit_event, :steering, %{iterations_left: 4}},
  ```
  and replace `{:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},` with
  `{:emit_event, :iteration, %{iteration: 2, iterations_left: 4, final: false}},`
- In test `"tool_dispatch results that exhaust the cap issue a forced final call"` replace

  ```elixir
               {:emit_event, :steering, %{iterations_left: 0}},
               {:persist, s2},
  ```
  with
  ```elixir
               {:persist, s2},
               {:emit_event, :steering, %{iterations_left: 0}},
  ```
  and replace `assert effects2 == [{:call_llm, %{response_model: :os, final: true}}]` with

  ```elixir
      assert effects2 == [
               {:emit_event, :iteration, %{iteration: 6, iterations_left: 0, final: true}},
               {:call_llm, %{response_model: :os, final: true}}
             ]
  ```

In `test/agents/turn_approval_test.exs`:

- In the park test replace `{:emit_event, :awaiting_approval, %{parked: 1}}` with
  `{:emit_event, :awaiting_approval, %{parked: 1, resumed: false}}`.
- In each of the three places with

  ```elixir
               {:emit_event, :steering, %{iterations_left: N}},
               {:persist, ^s2},
  ```
  (N = 4, 4, 0) swap the two lines so `{:persist, ^s2},` comes first.
- Replace both `{:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},` with
  `{:emit_event, :iteration, %{iteration: 2, iterations_left: 4, final: false}},`
- In test `"at the iteration cap, the resolved batch issues the forced-final call"` replace
  `assert effects2 == [{:call_llm, %{response_model: :os, final: true}}]` with

  ```elixir
      assert effects2 == [
               {:emit_event, :iteration, %{iteration: 6, iterations_left: 0, final: true}},
               {:call_llm, %{response_model: :os, final: true}}
             ]
  ```

In `test/agents/turn_compaction_test.exs`:

- Swap `{:emit_event, :steering, %{iterations_left: 4}},` and `{:persist, s2},` so `{:persist, s2},` comes first.
- Replace `{:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},` with
  `{:emit_event, :iteration, %{iteration: 2, iterations_left: 4, final: false}},`
- In test `"compaction_done at the cap issues the forced-final call"` replace
  `assert effects == [{:call_llm, %{response_model: :os, final: true}}]` with

  ```elixir
      assert effects == [
               {:emit_event, :iteration, %{iteration: 6, iterations_left: 0, final: true}},
               {:call_llm, %{response_model: :os, final: true}}
             ]
  ```

In `test/agents/turn/resume_test.exs` replace the test `"resume from :awaiting_approval emits no effects (waits for approval)"` with:

```elixir
  test "resume from :awaiting_approval re-announces the park (resumed: true) and waits" do
    s = %State{
      status: :awaiting_approval,
      parked_calls: [:c],
      iterations_left: 1,
      max_iterations: 5
    }

    assert {^s, [{:emit_event, :awaiting_approval, %{parked: 1, resumed: true}}]} =
             Turn.resume(s)
  end
```

Add to `test/agents/turn/server_test.exs` (top level, after the existing approval timeout test):

```elixir
  test "an eagerly resumed parked turn re-announces :awaiting_approval with resumed: true" do
    test_pid = self()
    call = %ToolCall{id: "pk1", name: "billing", input: %{}}

    parked = %Turn.State{
      status: :awaiting_approval,
      iterations_left: 5,
      max_iterations: 5,
      response_model: %Resp{},
      output_schema: %Resp{},
      pending_calls: [call],
      parked_calls: [call],
      held_results: []
    }

    {:ok, _srv} =
      Turn.Server.start_link(
        session_id: "s-resume-announce",
        config: base_config(),
        store: {InMemory, InMemory.new()},
        registry: {Native, Native.new()},
        turn_state: parked,
        resume_policy: :eager,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      )

    assert_receive {:event, :awaiting_approval, %{parked: 1, resumed: true}}, 1_000
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn_test.exs test/agents/turn_approval_test.exs test/agents/turn_compaction_test.exs test/agents/turn/resume_test.exs test/agents/turn/server_test.exs`
Expected: FAIL — effect-order mismatches (`:steering` before `:persist`), missing `final` keys, missing forced-final `:iteration`, missing `resumed`, the resume test getting `[]`, and the server resume test timing out on `assert_receive`.

- [ ] **Step 3: Implement in `lib/normandy/agents/turn.ex`**

Add a private helper next to `rejection_result/1`:

```elixir
  # The :iteration event announcing the next LLM call. `final` marks the forced-final
  # call made after the tool-iteration budget is spent.
  defp iteration_event(%State{} = s, final?) do
    {:emit_event, :iteration,
     %{
       iteration: s.max_iterations - s.iterations_left + 1,
       iterations_left: s.iterations_left,
       final: final?
     }}
  end
```

Replace the `:start` clause body:

```elixir
  def step(%State{status: :provisioning} = s, :start) do
    {%{s | status: :assistant_streaming},
     [
       iteration_event(s, false),
       {:call_llm, %{response_model: s.response_model, final: false}}
     ]}
  end
```

Replace the two `:steering` + `{:compaction_done, meta}` clauses:

```elixir
  def step(%State{status: :steering, iterations_left: left} = s, {:compaction_done, meta})
      when left <= 0 do
    s = add_compacted(s, meta)

    {%{s | status: :assistant_streaming, awaiting_final: true},
     [iteration_event(s, true), {:call_llm, %{response_model: s.output_schema, final: true}}]}
  end

  def step(%State{status: :steering} = s, {:compaction_done, meta}) do
    s = add_compacted(s, meta)

    {%{s | status: :assistant_streaming},
     [iteration_event(s, false), {:call_llm, %{response_model: s.response_model, final: false}}]}
  end
```

In the park clause (`{:needs_approval, held, parked}`) replace
`{:emit_event, :awaiting_approval, %{parked: length(parked)}}` with
`{:emit_event, :awaiting_approval, %{parked: length(parked), resumed: false}}`.

Replace `def resume(%State{status: :awaiting_approval} = s), do: {s, []}` with:

```elixir
  # A parked turn waits for a decision again; re-announce it so an observer that
  # attached after the restart learns approval is pending.
  def resume(%State{status: :awaiting_approval, parked_calls: parked} = s),
    do: {s, [{:emit_event, :awaiting_approval, %{parked: length(parked), resumed: true}}]}
```

In `apply_tool_results/2` replace the return with:

```elixir
    {s2,
     append_effects ++ [{:persist, s2}, steering, {:maybe_compact, %{iterations_left: new_left}}]}
```

and update that function's comment line "emits the steering boundary event, then parks" to "persists, then emits the steering boundary event (observers see saved state), then parks".

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn_test.exs test/agents/turn_approval_test.exs test/agents/turn_compaction_test.exs test/agents/turn/resume_test.exs test/agents/turn/server_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 0 failures. If a test elsewhere pins the old effect order or exact `:iteration`/`:awaiting_approval` meta with `==`, update it the same way (map patterns in `assert_receive` already match extra keys).

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/turn.ex test/agents/turn_test.exs test/agents/turn_approval_test.exs test/agents/turn_compaction_test.exs test/agents/turn/resume_test.exs test/agents/turn/server_test.exs
git commit -m "fix(agents)!: announce the forced-final call, persist before :steering, re-announce parked turns on resume"
```

---

### Task 2: Core approval expiry transition

**Files:**
- Modify: `lib/normandy/agents/turn.ex` (new clauses after the `{:approval, decisions}` clause; helper next to `rejection_result/1`)
- Test: `test/agents/turn_approval_test.exs`

**Interfaces:**
- Consumes: Task 1's `apply_tool_results/2` effect order (`appends ++ [{:persist, s2}, steering, maybe_compact]`).
- Produces: `Turn.step(%State{status: :awaiting_approval}, {:approval_expired, %{mode: :continue | :fail, timeout_ms: pos_integer()}})`. `:continue` → `{s2, [{:emit_event, :approval_expired, %{expired: n, mode: :continue}} | apply_tool_results_effects]}`. `:fail` → status `:failed`, `error: {:approval_timeout, [id]}`, effects `appends ++ [{:emit_event, :approval_expired, %{expired: n, mode: :fail}}, {:fail, {:approval_timeout, [id]}}]`. With `parked_calls: []` → `{:unexpected_event, :awaiting_approval, :approval_expired_without_parked_calls}` failure.

- [ ] **Step 1: Write the failing tests**

Append to `test/agents/turn_approval_test.exs` (inside the module):

```elixir
  describe "step/2 approval expiry (:awaiting_approval + :approval_expired)" do
    setup do
      pending = [
        %ToolCall{id: "a1", name: "weather", input: %{}},
        %ToolCall{id: "p1", name: "billing", input: %{}}
      ]

      s = %State{
        status: :awaiting_approval,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: pending,
        held_results: [%ToolResult{tool_call_id: "a1", output: "sunny", is_error: false}],
        parked_calls: [%ToolCall{id: "p1", name: "billing", input: %{}}]
      }

      {:ok, s: s}
    end

    test ":continue appends expired results in batch order after the event, then steers",
         %{s: s} do
      {s2, effects} = Turn.step(s, {:approval_expired, %{mode: :continue, timeout_ms: 50}})

      assert s2.status == :steering
      assert s2.iterations_left == 4
      assert s2.parked_calls == []
      assert s2.held_results == []

      assert [
               {:emit_event, :approval_expired, %{expired: 1, mode: :continue}},
               {:append_message, "tool", %ToolResult{tool_call_id: "a1", output: "sunny"}},
               {:append_message, "tool",
                %ToolResult{tool_call_id: "p1", is_error: true, output: output}},
               {:persist, ^s2},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:maybe_compact, %{iterations_left: 4}}
             ] = effects

      assert output == %{
               error: "approval timed out: no approver responded within 50ms",
               denied: true,
               expired: true,
               pending_approval: false
             }
    end

    test ":fail completes the batch, then emits and fails with {:approval_timeout, ids}",
         %{s: s} do
      {s2, effects} = Turn.step(s, {:approval_expired, %{mode: :fail, timeout_ms: 50}})

      assert s2.status == :failed
      assert s2.error == {:approval_timeout, ["p1"]}
      assert s2.pending_calls == []
      assert s2.parked_calls == []
      assert s2.held_results == []

      assert [
               {:append_message, "tool", %ToolResult{tool_call_id: "a1"}},
               {:append_message, "tool",
                %ToolResult{tool_call_id: "p1", is_error: true, output: %{expired: true}}},
               {:emit_event, :approval_expired, %{expired: 1, mode: :fail}},
               {:fail, {:approval_timeout, ["p1"]}}
             ] = effects
    end

    test "expiry with no parked calls is an unexpected event", %{s: s} do
      s = %{s | parked_calls: []}
      reason = {:unexpected_event, :awaiting_approval, :approval_expired_without_parked_calls}

      {s2, effects} = Turn.step(s, {:approval_expired, %{mode: :continue, timeout_ms: 50}})

      assert s2.status == :failed
      assert s2.error == reason
      assert effects == [{:fail, reason}]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn_approval_test.exs`
Expected: FAIL — the three new tests get `{:unexpected_event, :awaiting_approval, {:approval_expired, ...}}` from the catch-all clause.

- [ ] **Step 3: Implement in `lib/normandy/agents/turn.ex`**

Directly after the `{:approval, decisions}` clause (the one ending with `{s2, [{:execute_approved, approved}]}`), add:

```elixir
  # The approval window closed with no decision (the shell's approval timeout).
  # Unlike an approver's rejection, the expired results say so. `:continue` hands
  # them to the model and steers on; `:fail` completes the batch (every tool_use
  # answered, so the conversation stays valid) and fails the turn.
  def step(%State{status: :awaiting_approval, parked_calls: []} = s, {:approval_expired, _}) do
    reason = {:unexpected_event, :awaiting_approval, :approval_expired_without_parked_calls}
    {%{s | status: :failed, error: reason}, [{:fail, reason}]}
  end

  def step(
        %State{status: :awaiting_approval, parked_calls: parked, held_results: held} = s,
        {:approval_expired, %{mode: mode, timeout_ms: ms}}
      )
      when mode in [:continue, :fail] do
    expired = Enum.map(parked, &expiry_result(&1, ms))
    results = reorder(held ++ expired, s.pending_calls)
    event = {:emit_event, :approval_expired, %{expired: length(parked), mode: mode}}

    case mode do
      :continue ->
        {s2, effects} = apply_tool_results(s, results)
        {s2, [event | effects]}

      :fail ->
        reason = {:approval_timeout, Enum.map(parked, & &1.id)}

        s2 = %{
          s
          | status: :failed,
            error: reason,
            pending_calls: [],
            parked_calls: [],
            held_results: []
        }

        appends = Enum.map(results, &{:append_message, "tool", &1})
        {s2, appends ++ [event, {:fail, reason}]}
    end
  end
```

Next to `rejection_result/1` add:

```elixir
  # Result for a parked call whose approval window expired with no decision.
  defp expiry_result(%ToolCall{id: id}, ms) do
    %ToolResult{
      tool_call_id: id,
      output: %{
        error: "approval timed out: no approver responded within #{ms}ms",
        denied: true,
        expired: true,
        pending_approval: false
      },
      is_error: true
    }
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn_approval_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/turn.ex test/agents/turn_approval_test.exs
git commit -m "feat(agents): Turn core reports approval expiry and can fail the turn on it"
```

---

### Task 3: Core `unanswered_tool_calls/1`

**Files:**
- Modify: `lib/normandy/agents/turn.ex` (new public function after `resume/1`; add `alias Normandy.Components.Message` beside the existing component aliases)
- Test: `test/agents/turn_test.exs`

**Interfaces:**
- Consumes: the existing private `tool_calls/1` (`%{tool_calls: nil} -> []`, `%{tool_calls: list} -> list`, `_ -> []`).
- Produces: `@spec Turn.unanswered_tool_calls([Message.t()]) :: [ToolCall.t() | map()]` — tool calls of the latest `"assistant"` message lacking a `%ToolResult{tool_call_id: id}` in a later `"tool"` message, in `tool_use` order; `[]` otherwise.

- [ ] **Step 1: Write the failing tests**

Add `alias Normandy.Components.Message` to the aliases at the top of `test/agents/turn_test.exs`, then append inside the module:

```elixir
  describe "unanswered_tool_calls/1" do
    defp call(id), do: %ToolCall{id: id, name: "tool_#{id}", input: %{}}
    defp assistant_msg(calls), do: %Message{role: "assistant", content: %{content: "", tool_calls: calls}}
    defp tool_msg(id), do: %Message{role: "tool", content: %ToolResult{tool_call_id: id, output: "x"}}
    defp user_msg(text), do: %Message{role: "user", content: text}

    test "an empty history has none" do
      assert Turn.unanswered_tool_calls([]) == []
    end

    test "a latest assistant message without tool calls has none" do
      assert Turn.unanswered_tool_calls([user_msg("hi"), %Message{role: "assistant", content: "hello"}]) == []
      assert Turn.unanswered_tool_calls([user_msg("hi"), assistant_msg(nil)]) == []
    end

    test "a fully answered batch has none" do
      messages = [user_msg("go"), assistant_msg([call("a"), call("b")]), tool_msg("b"), tool_msg("a")]
      assert Turn.unanswered_tool_calls(messages) == []
    end

    test "an unanswered batch returns every call in tool_use order" do
      messages = [user_msg("go"), assistant_msg([call("a"), call("b")])]
      assert Turn.unanswered_tool_calls(messages) == [call("a"), call("b")]
    end

    test "a partly answered batch returns the missing calls" do
      messages = [user_msg("go"), assistant_msg([call("a"), call("b")]), tool_msg("a")]
      assert Turn.unanswered_tool_calls(messages) == [call("b")]
    end

    test "results for an earlier batch do not answer the latest one" do
      messages = [user_msg("go"), assistant_msg([call("a")]), tool_msg("a"), assistant_msg([call("b")])]
      assert Turn.unanswered_tool_calls(messages) == [call("b")]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn_test.exs`
Expected: FAIL with `UndefinedFunctionError ... Turn.unanswered_tool_calls/1 is undefined or private`.

- [ ] **Step 3: Implement in `lib/normandy/agents/turn.ex`**

Add `alias Normandy.Components.Message` beside the existing `ToolCall`/`ToolResult` aliases. After the last `resume/1` clause add:

```elixir
  @doc """
  The tool calls of the latest assistant message that have no `%ToolResult{}` in a
  later `"tool"` message, in `tool_use` order; `[]` when the latest assistant message
  made no tool calls.

  A turn that fails or is killed between appending the assistant's `tool_use` and
  appending its results leaves such calls behind, and the Claude API rejects a
  request with an unanswered `tool_use`. `Turn.Server` uses this to close the batch
  at the start of the next turn.
  """
  @spec unanswered_tool_calls([Message.t()]) :: [ToolCall.t() | map()]
  def unanswered_tool_calls(messages) when is_list(messages) do
    {later, rest} =
      messages
      |> Enum.reverse()
      |> Enum.split_while(&(not match?(%Message{role: "assistant"}, &1)))

    case rest do
      [%Message{content: content} | _] ->
        answered =
          for %Message{role: "tool", content: %ToolResult{tool_call_id: id}} <- later,
              into: MapSet.new(),
              do: id

        content |> tool_calls() |> Enum.reject(&MapSet.member?(answered, Map.get(&1, :id)))

      [] ->
        []
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn.ex test/agents/turn_test.exs
git commit -m "feat(agents): Turn.unanswered_tool_calls/1 finds tool_use blocks left without results"
```

---

### Task 4: Server failure replies, guarded handlers, emit parity, subscriber isolation (AGENTS-1)

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`{:turn, _}` clause ~:179-198, `interpret/2` ~:283-345, `emit/3` ~:391-392; add `require Logger`)
- Test: `test/agents/turn/server_test.exs`

**Interfaces:**
- Consumes: Task 1's events (`:iteration` meta has `final`).
- Produces (private, used by Tasks 5 and 6):
  - `admit(config, user_input) :: {:ok, config} | {:rejected, exception}`
  - `start_turn(from, user_input, config, data)` — persists the user message and starts the turn (Task 6 changes it to `/5`).
  - `call_handler(data, name, fun) :: {:ok, term()} | {:crashed, {:handler_crashed, name, exception_or_term}}`
  - `guarded(data, name, fun, continue)` — runs `call_handler`; on crash calls `fail/2`.
  - Public behaviour: `run/2` may return `{:error, {:rejected, e}}` and `{:error, {:handler_crashed, name, e}}`; telemetry `[:normandy, :turn, :subscriber, :exception]` with `%{count: 1}` / `%{session_id:, event:, kind:}`.

- [ ] **Step 1: Write the failing tests**

In `test/agents/turn/server_test.exs`: add `import ExUnit.CaptureLog` under `use ExUnit.Case`, and add next to the `FakeTool` module:

```elixir
  # Input schema with a required field: `%{}` fails validation (ValidationError).
  defmodule RequiredQueryInput do
    use Normandy.Schema

    io_schema "Input requiring a query" do
      field(:query, :string, description: "query", required: true)
    end
  end
```

Append inside the module:

```elixir
  describe "failure replies and crashing callbacks (AGENTS-1)" do
    defp final_handlers(overrides \\ %{}) do
      Map.merge(
        %{
          BaseAgent.non_streaming_handlers()
          | call_llm: fn _c, _s, _r -> %Resp{content: "ok", tool_calls: nil} end
        },
        overrides
      )
    end

    defp start_server(sid, config, opts \\ []) do
      store = InMemory.new()

      base = [
        session_id: sid,
        config: config,
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: final_handlers()
      ]

      {:ok, srv} = Turn.Server.start_link(Keyword.merge(base, opts))
      {srv, store}
    end

    defp attach_telemetry(event) do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        event,
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      ref
    end

    test "schema-invalid input replies {:rejected, ValidationError}; nothing persisted" do
      config = %{base_config() | input_schema: %RequiredQueryInput{}}
      {srv, store} = start_server("s-rej-schema", config)

      assert {:error, {:rejected, %Normandy.Schema.ValidationError{}}} =
               Turn.Server.run(srv, %{})

      assert Process.alive?(srv)
      assert {:ok, []} = InMemory.history(store, "s-rej-schema")
      assert {:ok, %Resp{content: "ok"}} = Turn.Server.run(srv, %{query: "weather"})
    end

    test "an input guardrail block replies {:rejected, ViolationError}" do
      config = %{
        base_config()
        | input_guardrails: [{Normandy.Guardrails.Builtins.MaxLength, limit: 5}]
      }

      {srv, _store} = start_server("s-rej-guard", config)

      assert {:error, {:rejected, %Normandy.Guardrails.ViolationError{}}} =
               Turn.Server.run(srv, "too long input")

      assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
    end

    test "repeated rejected inputs do not take down Turn.Supervisor" do
      {:ok, sup} = Turn.Supervisor.start_link([])
      config = %{base_config() | input_schema: %RequiredQueryInput{}}

      {:ok, srv} =
        Turn.Supervisor.start_server(sup,
          session_id: "s-cascade",
          config: config,
          store: {InMemory, InMemory.new()},
          registry: {Native, Native.new()},
          handlers: final_handlers()
        )

      for _ <- 1..5, do: assert({:error, {:rejected, _}} = Turn.Server.run(srv, %{}))

      assert Process.alive?(srv)
      assert Process.alive?(sup)
    end

    test "a raising validate handler fails the turn; the session stays usable" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      validate = fn _config, value ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0,
          do: raise("validate boom"),
          else: value
      end

      {srv, store} =
        start_server("s-crash-validate", base_config(),
          handlers: final_handlers(%{validate: validate})
        )

      log =
        capture_log(fn ->
          assert {:error, {:handler_crashed, :validate, %RuntimeError{message: "validate boom"}}} =
                   Turn.Server.run(srv, "hi")
        end)

      assert log =~ "handler :validate crashed"
      assert log =~ "validate boom"
      assert Process.alive?(srv)

      assert {:ok, %Turn.State{status: :failed}} =
               InMemory.load_turn_state(store, "s-crash-validate")

      assert {:ok, %Resp{}} = Turn.Server.run(srv, "again")
    end

    test "an exiting append handler fails the turn with the exit reason" do
      append = fn _config, _role, _content -> exit(:store_timeout) end

      {srv, _store} =
        start_server("s-crash-append", base_config(), handlers: final_handlers(%{append: append}))

      capture_log(fn ->
        assert {:error, {:handler_crashed, :append, :store_timeout}} = Turn.Server.run(srv, "hi")
      end)

      assert Process.alive?(srv)
    end

    test "the Server calls handlers.emit for each event" do
      test_pid = self()
      emit = fn _config, name, meta -> send(test_pid, {:handler_emit, name, meta}) end

      {srv, _store} =
        start_server("s-emit", base_config(), handlers: final_handlers(%{emit: emit}))

      assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
      assert_received {:handler_emit, :iteration, %{iteration: 1, final: false}}
    end

    test "a nil handlers.emit is skipped" do
      {srv, _store} =
        start_server("s-emit-nil", base_config(), handlers: final_handlers(%{emit: nil}))

      assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
    end

    test "a raising subscriber is logged and reported; the turn still succeeds" do
      ref = attach_telemetry([:normandy, :turn, :subscriber, :exception])

      log =
        capture_log(fn ->
          {srv, _store} =
            start_server("s-sub-raise", base_config(),
              subscriber: fn _name, _meta -> raise "subscriber boom" end
            )

          assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
        end)

      assert log =~ "subscriber crashed"
      assert log =~ "subscriber boom"

      assert_received {:telemetry, ^ref, %{count: 1},
                       %{session_id: "s-sub-raise", event: :iteration, kind: :error}}
    end

    test "a subscriber that exits or throws does not fail the turn" do
      subscribers = [
        {"s-sub-exit", fn _name, _meta -> exit(:gone) end},
        {"s-sub-throw", fn _name, _meta -> throw(:nope) end}
      ]

      for {sid, sub} <- subscribers do
        capture_log(fn ->
          {srv, _store} = start_server(sid, base_config(), subscriber: sub)
          assert {:ok, %Resp{}} = Turn.Server.run(srv, "hi")
        end)
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/server_test.exs`
Expected: FAIL. The rejection, cascade and handler-crash tests fail with an exit from `:gen_statem.call` (server crashed). `"the Server calls handlers.emit"` fails on `assert_received`. The subscriber tests fail with an exit. `"a nil handlers.emit is skipped"` passes already (it guards against a regression in Step 3; it was never red).

- [ ] **Step 3: Implement in `lib/normandy/agents/turn/server.ex`**

Add `require Logger` after the aliases.

Replace the `{:turn, user_input}` `:idle` clause with:

```elixir
  def handle_event({:call, from}, {:turn, user_input}, :idle, data) do
    case admit(data.config, user_input) do
      {:ok, config} ->
        start_turn(from, user_input, config, data)

      {:rejected, exception} ->
        {:keep_state, data, [{:reply, from, {:error, {:rejected, exception}}}]}
    end
  end
```

Add below it:

```elixir
  # Schema and input-guardrail rejections are expected outcomes: reply them as data
  # without touching state. Anything else admit_turn_input raises is a bug and crashes.
  defp admit(config, user_input) do
    {:ok, BaseAgent.admit_turn_input(config, user_input)}
  rescue
    e in [Normandy.Schema.ValidationError, Normandy.Guardrails.ViolationError] ->
      {:rejected, e}
  end

  defp start_turn(from, user_input, config, data) do
    case persist_user_message(data, config, user_input) do
      :ok ->
        state =
          Turn.new(
            max_iterations: config.max_tool_iterations,
            response_model: BaseAgent.turn_response_model(config),
            output_schema: config.output_schema
          )

        data = %{data | config: config, pending_reply: from}
        {state, effects} = Turn.step(state, :start)
        interpret(effects, %{data | turn_state: state})

      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, {:persist_failed, reason}}}]}
    end
  end
```

In `interpret([effect | rest], data)` replace the `:emit_event`, `:append_message`, `:convert_output`, `:validate_output` and `:guard_output` branches with:

```elixir
      {:emit_event, name, meta} ->
        guarded(data, :emit, fn -> emit(data, name, meta) end, fn _ -> interpret(rest, data) end)

      {:append_message, role, content} ->
        guarded(
          data,
          :append,
          fn -> data.handlers.append.(data.config, role, content) end,
          fn config ->
            case append_to_store(data, role, content) do
              :ok -> interpret(rest, %{data | config: config})
              {:error, reason} -> fail(%{data | config: config}, {:persist_failed, reason})
            end
          end
        )

      {:convert_output, raw, schema} ->
        guarded(
          data,
          :convert,
          fn -> data.handlers.convert.(data.config, raw, schema) end,
          &advance(rest, data, {:output_converted, &1})
        )

      {:validate_output, value} ->
        guarded(
          data,
          :validate,
          fn -> data.handlers.validate.(data.config, value) end,
          &advance(rest, data, {:output_validated, &1})
        )

      {:guard_output, value} ->
        guarded(
          data,
          :guard,
          fn -> data.handlers.guard.(data.config, value) end,
          fn _ -> advance(rest, data, {:output_guarded, value}) end
        )
```

Replace the two `emit/3` clauses with:

```elixir
  # The agent's own emit handler first (a crash there is a handler crash), then the
  # subscriber, whose crash is logged and reported but never fails the turn.
  defp emit(%Data{handlers: handlers} = data, name, meta) do
    if handlers.emit, do: handlers.emit.(data.config, name, meta)
    notify_subscriber(data, name, meta)
  end

  defp notify_subscriber(%Data{subscriber: nil}, _name, _meta), do: :ok

  defp notify_subscriber(%Data{subscriber: sub} = data, name, meta) when is_function(sub, 2) do
    sub.(name, meta)
    :ok
  catch
    kind, reason ->
      Logger.error(
        "Turn.Server subscriber crashed on #{inspect(name)} " <>
          "(session #{inspect(data.session_id)}): " <>
          describe_crash(kind, reason, __STACKTRACE__)
      )

      :telemetry.execute(
        [:normandy, :turn, :subscriber, :exception],
        %{count: 1},
        %{session_id: data.session_id, event: name, kind: kind}
      )

      :ok
  end

  # Runs a synchronous handler in the server process. A raise, exit or throw becomes
  # {:crashed, {:handler_crashed, name, exception_or_term}} instead of crashing the
  # session (and, through restart intensity, Turn.Supervisor).
  defp call_handler(data, name, fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(
        "Turn.Server handler #{inspect(name)} crashed (session #{inspect(data.session_id)}): " <>
          describe_crash(kind, reason, stacktrace) <>
          "\n" <> Exception.format_stacktrace(arity_only(stacktrace))
      )

      {:crashed, {:handler_crashed, name, Exception.normalize(kind, reason, stacktrace)}}
  end

  defp guarded(data, name, fun, continue) do
    case call_handler(data, name, fun) do
      {:ok, value} -> continue.(value)
      {:crashed, reason} -> fail(data, reason)
    end
  end

  defp describe_crash(kind, reason, stacktrace) do
    case Exception.normalize(kind, reason, stacktrace) do
      exception when is_exception(exception) -> Exception.format_banner(:error, exception)
      other -> Exception.format_banner(kind, other)
    end
  end

  # Stack frames can carry call arguments (a FunctionClauseError's top frame does),
  # and an argument may be the config, which can hold credentials. Log arities only.
  defp arity_only(stacktrace) do
    Enum.map(stacktrace, fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      frame -> frame
    end)
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/server_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite and Credo**

Run: `mix test && mix credo --strict`
Expected: 0 failures; Credo "found no issues". A complexity finding on a function this task touched gets an inline `# credo:disable-for-next-line <Check>`.

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "fix(agents)!: Turn.Server replies rejected input and handler crashes instead of crashing

A schema or input-guardrail rejection replies {:error, {:rejected, e}}.
A raise, exit or throw in a synchronous handler fails the turn with
{:handler_crashed, name, e}. The Server now calls handlers.emit like the
Driver; a crashing subscriber is logged and reported via telemetry and
the turn continues. Closes audit AGENTS-1."
```

---

### Task 5: Approval expiry in the Server, `on_approval_timeout`, forwarding

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`Data` struct, `start_link/1`, `init/1`, `:approval_expiry` clause ~:254)
- Modify: `lib/normandy/agents/turn/session.ex` (both `Keyword.take` lists, ~:103-111 and ~:117-125)
- Modify: `lib/normandy/coordination/agent_process.ex` (`extra_session_opts` `Keyword.take`, ~:274-279; moduledoc option list ~:47)
- Test: `test/agents/turn/server_test.exs`, `test/agents/turn/session_test.exs`, `test/coordination/agent_process_server_test.exs`

**Interfaces:**
- Consumes: Task 2's `Turn.step(state, {:approval_expired, %{mode: m, timeout_ms: ms}})`; Task 4's `RequiredQueryInput` test module is not needed here. This task defines its own test helpers (`start_approval_server/2`, `run_async/2`, `attach_expiry_telemetry/0`); names do not clash with Task 4's.
- Produces: `Turn.Server.start_link(on_approval_timeout: :continue | :fail)` (default `:continue`); `ArgumentError` on any other value; telemetry `[:normandy, :turn, :approval, :expired]` with `%{count: n}` / `%{session_id:, mode:, timeout_ms:, tool_names:}`.

- [ ] **Step 1: Write the failing tests**

In `test/agents/turn/server_test.exs`: add `alias Normandy.Components.Message` and `alias Normandy.Components.ToolResult` to the aliases. Give `FakeTool` a sleep field and use it:

```elixir
  defmodule FakeTool do
    use Normandy.Schema

    schema do
      field(:name, :string)
      field(:notify, :any, default: nil)
      field(:sleep_ms, :integer, default: 0)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Agents.Turn.ServerTest.FakeTool do
    def tool_name(t), do: t.name
    def tool_description(_), do: "fake"
    def input_schema(_), do: %{}

    def run(t) do
      if t.sleep_ms > 0, do: Process.sleep(t.sleep_ms)
      if t.notify, do: send(t.notify, {:tool_ran, t.name})
      {:ok, "ran #{t.name}"}
    end
  end
```

Append inside the module:

```elixir
  describe "approval expiry" do
    defp billing_approval_policy do
      %Normandy.Behaviours.Config{
        policy:
          {Normandy.Behaviours.PolicyEngine.Ruleset,
           rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
           default_action: :allow}
      }
    end

    # 1st LLM call → weather (allowed) + billing (parked); later calls → final "done".
    # Each call reports {:llm_call, n, messages} so tests can inspect what the model saw.
    defp start_approval_server(sid, extra) do
      store = InMemory.new()
      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      call_llm = fn config, _s, _r ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
        send(test_pid, {:llm_call, n, AgentMemory.messages(config.memory)})

        if n == 0 do
          %Resp{
            content: "",
            tool_calls: [
              %ToolCall{id: "ok1", name: "weather", input: %{}},
              %ToolCall{id: "pk1", name: "billing", input: %{}}
            ]
          }
        else
          %Resp{content: "done", tool_calls: nil}
        end
      end

      opts = [
        session_id: sid,
        config: %{config_with_notify(test_pid) | behaviours: billing_approval_policy()},
        store: {InMemory, store},
        registry: {Native, Native.new()},
        handlers: %{BaseAgent.non_streaming_handlers() | call_llm: call_llm},
        approval_timeout_ms: 50,
        subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
      ]

      {:ok, srv} = Turn.Server.start_link(Keyword.merge(opts, extra))
      {srv, store}
    end

    defp run_async(srv, input) do
      parent = self()
      spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, input)}) end)
    end

    defp attach_expiry_telemetry do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:normandy, :turn, :approval, :expired],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      ref
    end

    test "default :continue tells the model the approval timed out" do
      ref = attach_expiry_telemetry()
      {srv, _store} = start_approval_server("s-exp-continue", [])

      run_async(srv, "go")

      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 2_000
      assert_received {:event, :approval_expired, %{expired: 1, mode: :continue}}

      assert_received {:telemetry, ^ref, %{count: 1},
                       %{
                         session_id: "s-exp-continue",
                         mode: :continue,
                         timeout_ms: 50,
                         tool_names: ["billing"]
                       }}

      assert_received {:llm_call, 1, messages}

      assert Enum.any?(
               messages,
               &match?(
                 %Message{
                   role: "tool",
                   content: %ToolResult{
                     tool_call_id: "pk1",
                     output: %{
                       expired: true,
                       error: "approval timed out: no approver responded within 50ms"
                     }
                   }
                 },
                 &1
               )
             )

      refute_received {:tool_ran, "billing"}
    end

    test ":fail ends the turn with {:approval_timeout, ids}; a late approval is dropped" do
      {srv, store} = start_approval_server("s-exp-fail", on_approval_timeout: :fail)

      run_async(srv, "go")

      assert_receive {:run_result, {:error, {:approval_timeout, ["pk1"]}}}, 2_000
      assert_received {:event, :approval_expired, %{expired: 1, mode: :fail}}
      refute_received {:llm_call, 1, _}

      {:ok, entries} = InMemory.history(store, "s-exp-fail")
      answered = for %{role: "tool", content: %ToolResult{tool_call_id: id}} <- entries, do: id
      assert Enum.sort(answered) == ["ok1", "pk1"]

      assert {:ok, %Turn.State{status: :failed, error: {:approval_timeout, ["pk1"]}}} =
               InMemory.load_turn_state(store, "s-exp-fail")

      :ok = Turn.Server.approve(srv, %{"pk1" => :approve})
      assert {:ok, %Resp{content: "done"}} = Turn.Server.run(srv, "again")
      refute_received {:tool_ran, "billing"}
    end

    test "an approval that arrives in time is not expired while the approved tool runs" do
      test_pid = self()

      config = %{
        base_config()
        | tool_registry:
            Normandy.Tools.Registry.new([
              %FakeTool{name: "weather", notify: test_pid},
              %FakeTool{name: "billing", notify: test_pid, sleep_ms: 600}
            ]),
          behaviours: billing_approval_policy()
      }

      {srv, _store} =
        start_approval_server("s-exp-intime", config: config, approval_timeout_ms: 200)

      run_async(srv, "go")
      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
      :ok = Turn.Server.approve(srv, %{"pk1" => :approve})

      assert_receive {:run_result, {:ok, %Resp{content: "done"}}}, 3_000
      assert_received {:tool_ran, "billing"}
      refute_received {:event, :approval_expired, _}
    end

    test "an invalid :on_approval_timeout raises ArgumentError naming the key and value" do
      assert_raise ArgumentError,
                   ~r/Turn\.Server\.start_link\/1: invalid :on_approval_timeout, expected :continue or :fail, got: :sometimes/,
                   fn ->
                     Turn.Server.start_link(
                       session_id: "s-bad-opt",
                       config: base_config(),
                       store: {InMemory, InMemory.new()},
                       registry: {Native, Native.new()},
                       on_approval_timeout: :sometimes
                     )
                   end
    end
  end
```

In `test/agents/turn/session_test.exs` add next to `FaultyStore`:

```elixir
  # A supervisor stand-in that reports the server opts Session built, then refuses.
  defmodule CapturingSupervisor do
    def start_server(test_pid, opts) do
      send(test_pid, {:server_opts, opts})
      {:error, :captured}
    end
  end
```

and the test:

```elixir
  test "run/2 forwards :on_approval_timeout to the server" do
    opts = [
      session_id: "s-fwd",
      config: session_config(),
      store: {InMemory, InMemory.new()},
      registry: {Native, Native.new()},
      supervisor: self(),
      supervisor_mod: CapturingSupervisor,
      on_approval_timeout: :fail
    ]

    assert {:error, :captured} = Turn.Session.run(opts, "hi")
    assert_received {:server_opts, server_opts}
    assert Keyword.fetch!(server_opts, :on_approval_timeout) == :fail
  end
```

In `test/coordination/agent_process_server_test.exs`, inside the `describe` that holds `"park → stays responsive → approve → resume → original caller gets final result"`, add:

```elixir
    test "forwards :on_approval_timeout; :fail surfaces {:approval_timeout, ids}" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [
            agent: approval_config(),
            turn_engine: :server,
            agent_id: "approval-expiry",
            handlers: approval_handlers(),
            approval_timeout_ms: 50,
            on_approval_timeout: :fail
          ] ++ infra
        )

      assert {:error, {:approval_timeout, ["pk1"]}} = AgentProcess.run(pid, "please charge")
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/server_test.exs test/agents/turn/session_test.exs test/coordination/agent_process_server_test.exs`
Expected: FAIL. `:continue` fails on `assert_received {:event, :approval_expired, _}` (the old path sends `{:approval, %{}}`). `:fail` gets `{:ok, _}`. The invalid-option test gets no raise. The Session test gets `KeyError` (key not forwarded). The AgentProcess test gets `{:ok, _}`. The in-time test passes already (the statem leaves `:awaiting_approval` when approval arrives); it guards Step 3 and was never red.

- [ ] **Step 3: Implement**

`lib/normandy/agents/turn/server.ex`:

Add `on_approval_timeout: :continue` to `defstruct` in `Data` (after `approval_timeout_ms: 300_000,`).

Replace `start_link/1`:

```elixir
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    validate_on_approval_timeout!(Keyword.get(opts, :on_approval_timeout, :continue))

    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  defp validate_on_approval_timeout!(mode) when mode in [:continue, :fail], do: :ok

  defp validate_on_approval_timeout!(other) do
    raise ArgumentError,
          "Turn.Server.start_link/1: invalid :on_approval_timeout, expected :continue or :fail, " <>
            "got: #{inspect(other)}"
  end
```

In `init/1`'s `%Data{}` add after `approval_timeout_ms: ...,`:

```elixir
      on_approval_timeout: Keyword.get(opts, :on_approval_timeout, :continue),
```

Replace the `:state_timeout, :approval_expiry` clause:

```elixir
  # Approval window closed with no decision. The core answers every parked call with
  # an expiry result and either continues or fails the turn (on_approval_timeout).
  def handle_event(:state_timeout, :approval_expiry, :awaiting_approval, data) do
    %Turn.State{parked_calls: parked} = data.turn_state
    mode = data.on_approval_timeout
    ms = data.approval_timeout_ms

    :telemetry.execute(
      [:normandy, :turn, :approval, :expired],
      %{count: length(parked)},
      %{
        session_id: data.session_id,
        mode: mode,
        timeout_ms: ms,
        tool_names: Enum.map(parked, & &1.name)
      }
    )

    {state, effects} = Turn.step(data.turn_state, {:approval_expired, %{mode: mode, timeout_ms: ms}})
    interpret(effects, %{data | turn_state: state})
  end
```

`lib/normandy/agents/turn/session.ex`: in both `Keyword.take([...])` lists add `:on_approval_timeout,` after `:approval_timeout_ms,`.

`lib/normandy/coordination/agent_process.ex`: in the `extra_session_opts: Keyword.take(opts, [...])` list add `:on_approval_timeout` after `:approval_timeout_ms,`; in the moduledoc sentence listing `` `:subscriber`, `:handlers`, `:approval_timeout_ms`, `` add `` `:on_approval_timeout`, `` after `` `:approval_timeout_ms`, ``.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/server_test.exs test/agents/turn/session_test.exs test/coordination/agent_process_server_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite and Credo**

Run: `mix test && mix credo --strict`
Expected: 0 failures; Credo "found no issues".

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/turn/server.ex lib/normandy/agents/turn/session.ex lib/normandy/coordination/agent_process.ex test/agents/turn/server_test.exs test/agents/turn/session_test.exs test/coordination/agent_process_server_test.exs
git commit -m "feat(agents): honest approval expiry and on_approval_timeout (:continue | :fail)

On expiry each parked call gets an expiry result (not 'rejected by
approver'), :approval_expired is emitted and
[:normandy, :turn, :approval, :expired] fires. :fail completes the batch
and replies {:error, {:approval_timeout, ids}}. Turn.Session and
AgentProcess forward the option."
```

---

### Task 6: Repair dangling `tool_use` batches at turn admission (A3)

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (`{:turn, _}` clause and `start_turn` from Task 4; new private helpers)
- Test: `test/agents/turn/server_test.exs`

**Interfaces:**
- Consumes: Task 3's `Turn.unanswered_tool_calls/1`; Task 4's `admit/2`, `start_turn/4`, `call_handler/3`.
- Produces: `start_turn/5` (adds the interrupted results to persist); repair behaviour on `run/2`.

- [ ] **Step 1: Write the failing tests**

Append inside `test/agents/turn/server_test.exs` (needs the `Message`/`ToolResult` aliases from Task 5 and `RequiredQueryInput` from Task 4):

```elixir
  describe "dangling tool_use repair" do
    defp dangling_memory do
      AgentMemory.new_memory()
      |> AgentMemory.add_message("user", "charge me")
      |> AgentMemory.add_message("assistant", %Resp{
        content: "",
        tool_calls: [%ToolCall{id: "t1", name: "billing", input: %{}}]
      })
    end

    # Store and memory both end in a tool_use with no result, as after a crash.
    defp start_dangling_server(sid, config_overrides, handler_overrides \\ %{}) do
      store = InMemory.new()
      memory = dangling_memory()

      for %Message{role: role, content: content} <- AgentMemory.messages(memory) do
        {:ok, _} =
          InMemory.append_entry(store, sid, %AgentMemory.Entry{
            turn_id: "live",
            role: role,
            content: content
          })
      end

      test_pid = self()

      call_llm = fn config, _s, _r ->
        send(test_pid, {:llm_messages, AgentMemory.messages(config.memory)})
        %Resp{content: "ok", tool_calls: nil}
      end

      handlers =
        Map.merge(%{BaseAgent.non_streaming_handlers() | call_llm: call_llm}, handler_overrides)

      {:ok, srv} =
        Turn.Server.start_link(
          session_id: sid,
          config: Map.merge(%{base_config() | memory: memory}, config_overrides),
          store: {InMemory, store},
          registry: {Native, Native.new()},
          handlers: handlers
        )

      {srv, store}
    end

    test "the next turn closes the unanswered tool_use before the user message" do
      {srv, store} = start_dangling_server("s-dangling", %{})

      log =
        capture_log(fn ->
          assert {:ok, %Resp{content: "ok"}} = Turn.Server.run(srv, "next")
        end)

      assert log =~ "interrupted"
      assert log =~ "billing"
      assert_received {:llm_messages, messages}

      assert [
               %Message{role: "user", content: "charge me"},
               %Message{role: "assistant"},
               %Message{
                 role: "tool",
                 content: %ToolResult{
                   tool_call_id: "t1",
                   is_error: true,
                   output: %{
                     interrupted: true,
                     error:
                       "tool call interrupted: the previous turn ended before a result was " <>
                         "recorded; the tool may or may not have run"
                   }
                 }
               },
               %Message{role: "user", content: "next"}
             ] = messages

      {:ok, entries} = InMemory.history(store, "s-dangling")
      assert ["user", "assistant", "tool", "user", "assistant"] = Enum.map(entries, & &1.role)
    end

    test "a repaired batch is not repaired again on the following turn" do
      {srv, store} = start_dangling_server("s-dangling-once", %{})

      capture_log(fn ->
        assert {:ok, _} = Turn.Server.run(srv, "next")
        assert {:ok, _} = Turn.Server.run(srv, "again")
      end)

      {:ok, entries} = InMemory.history(store, "s-dangling-once")
      assert Enum.count(entries, &(&1.role == "tool")) == 1
    end

    test "a rejected input in a dangling session changes nothing" do
      {srv, store} =
        start_dangling_server("s-dangling-reject", %{input_schema: %RequiredQueryInput{}})

      assert {:error, {:rejected, _}} = Turn.Server.run(srv, %{})
      {:ok, entries} = InMemory.history(store, "s-dangling-reject")
      assert Enum.map(entries, & &1.role) == ["user", "assistant"]
    end

    test "an append crash during repair replies {:handler_crashed, :append, _}; nothing persisted" do
      {srv, store} =
        start_dangling_server("s-dangling-crash", %{}, %{
          append: fn _config, _role, _content -> raise "append boom" end
        })

      capture_log(fn ->
        assert {:error, {:handler_crashed, :append, %RuntimeError{message: "append boom"}}} =
                 Turn.Server.run(srv, "next")
      end)

      assert Process.alive?(srv)
      {:ok, entries} = InMemory.history(store, "s-dangling-crash")
      assert Enum.map(entries, & &1.role) == ["user", "assistant"]
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix format && mix test test/agents/turn/server_test.exs`
Expected: FAIL. The first test sees no `"tool"` message between the assistant and the new user message, and no log. The second counts 0 tool entries. The append-crash test gets `{:ok, _}` or a different error, because nothing calls `append` before the turn. The rejected-input test passes already (Task 4 behaviour); it guards Step 3 and was never red.

- [ ] **Step 3: Implement in `lib/normandy/agents/turn/server.ex`**

Replace the `{:turn, user_input}` `:idle` clause (Task 4 version) with:

```elixir
  def handle_event({:call, from}, {:turn, user_input}, :idle, data) do
    missing = data.config.memory |> AgentMemory.messages() |> Turn.unanswered_tool_calls()
    interrupted = Enum.map(missing, &interrupted_result/1)

    with {:ok, repaired} <- close_batch(data, interrupted),
         {:ok, config} <- admit(repaired, user_input) do
      log_repair(data, missing)
      start_turn(from, user_input, config, interrupted, data)
    else
      {:rejected, exception} ->
        {:keep_state, data, [{:reply, from, {:error, {:rejected, exception}}}]}

      {:crashed, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}
    end
  end
```

Replace `start_turn/4` with `start_turn/5`:

```elixir
  # Store order mirrors memory order: interrupted results, then the user message.
  defp start_turn(from, user_input, config, interrupted, data) do
    with :ok <- persist_interrupted(data, interrupted),
         :ok <- persist_user_message(data, config, user_input) do
      state =
        Turn.new(
          max_iterations: config.max_tool_iterations,
          response_model: BaseAgent.turn_response_model(config),
          output_schema: config.output_schema
        )

      data = %{data | config: config, pending_reply: from}
      {state, effects} = Turn.step(state, :start)
      interpret(effects, %{data | turn_state: state})
    else
      {:error, reason} ->
        {:keep_state, data, [{:reply, from, {:error, {:persist_failed, reason}}}]}
    end
  end
```

Add the helpers below `start_turn/5`:

```elixir
  # A failed or killed turn can leave the last assistant tool_use without results;
  # the Claude API rejects the next request unless every tool_use is answered. Fold
  # an interrupted result per missing call into memory (no turn exists yet, so a
  # crashing append replies instead of going through fail/2).
  defp close_batch(%Data{config: config}, []), do: {:ok, config}

  defp close_batch(data, interrupted) do
    call_handler(data, :append, fn ->
      Enum.reduce(interrupted, data.config, &data.handlers.append.(&2, "tool", &1))
    end)
  end

  defp interrupted_result(call) do
    %Normandy.Components.ToolResult{
      tool_call_id: Map.get(call, :id),
      output: %{
        error:
          "tool call interrupted: the previous turn ended before a result was recorded; " <>
            "the tool may or may not have run",
        interrupted: true
      },
      is_error: true
    }
  end

  defp persist_interrupted(data, interrupted) do
    Enum.reduce_while(interrupted, :ok, fn result, :ok ->
      case append_to_store(data, "tool", result) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp log_repair(_data, []), do: :ok

  defp log_repair(data, missing) do
    Logger.warning(
      "Turn.Server closed #{length(missing)} interrupted tool call(s) left by a previous " <>
        "turn (session #{inspect(data.session_id)}): " <>
        Enum.map_join(missing, ", ", &to_string(Map.get(&1, :name)))
    )
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix test test/agents/turn/server_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite and Credo**

Run: `mix test && mix credo --strict`
Expected: 0 failures; Credo "found no issues".

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "fix(agents): Turn.Server closes tool_use batches a previous turn left unanswered

A turn that fails or is killed after appending the assistant's tool_use
left it without tool_result, so the next request was rejected by the
API. The next turn now appends an interrupted result per missing call
(memory and store) before the user message. Audit known item A3."
```

---

### Task 7: Docs and final verification

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (moduledoc)
- Modify: `MIGRATING-2.0.md` (new section 12 before `## New, non-breaking`)
- Modify: `CLAUDE.md` (Agent System section)

**Interfaces:**
- Consumes: everything above.
- Produces: documentation only.

- [ ] **Step 1: Replace the `Turn.Server` moduledoc**

```elixir
  @moduledoc """
  Asynchronous `:gen_statem` interpreter of the pure `Turn` FSM — the async analog
  of `Turn.Driver`. Coarse lifecycle states (`:running`, `:awaiting_approval`,
  `:idle`) hang Tasks and `state_timeout`s off the turn; they are NOT a
  re-encoding of the seven `Turn.State` statuses (the core stays the source of
  truth). Blocking effects (`:call_llm`, `:dispatch_tools`, `:execute_approved`)
  run in a monitored Task; non-blocking effects run synchronously in the handler.

  ## Options (besides `:session_id`, `:store`, `:registry`, `:config` / `:template_provider`)

    * `:handlers` — a `Turn.Driver.Handlers` set (default
      `BaseAgent.non_streaming_handlers/0`). A `nil` `:emit` is skipped.
    * `:subscriber` — `fn event_name, meta -> any end`, called in the server process
      for every event. A crash in it is logged, reported as
      `[:normandy, :turn, :subscriber, :exception]` telemetry, and ignored.
    * `:approval_timeout_ms` — how long a parked turn waits for `approve/2`
      (default 300_000).
    * `:on_approval_timeout` — `:continue` (default) or `:fail`. On expiry every
      parked call gets an `expired: true` tool result. `:continue` hands it to the
      model; `:fail` ends the turn with `{:error, {:approval_timeout, ids}}`.
    * `:idle_timeout_ms` — idle time before passivation (default 60_000).

  ## Events (`:subscriber`)

    * `:iteration` — `%{iteration: n, iterations_left: m, final: boolean}` before each
      LLM call; `final: true` marks the forced-final call after the budget is spent.
    * `:steering` — `%{iterations_left: m}` after a tool batch, once its state is saved.
    * `:awaiting_approval` — `%{parked: n, resumed: boolean}` when a batch parks, and
      again (`resumed: true`) when a restarted server resumes a parked turn.
    * `:approval_expired` — `%{expired: n, mode: :continue | :fail}`.

  ## Errors from `run/2`

    * `{:rejected, exception}` — the input failed its schema
      (`Normandy.Schema.ValidationError`) or an input guardrail
      (`Normandy.Guardrails.ViolationError`). Nothing was persisted.
    * `{:handler_crashed, name, exception_or_term}` — a synchronous handler
      (`:append`, `:convert`, `:validate`, `:guard`, `:emit`) raised, exited or threw.
    * `{:approval_timeout, [tool_call_id]}` — `on_approval_timeout: :fail`.
    * `{:persist_failed, reason}` — the session store rejected a write.
    * Core failures such as `{:task_down, reason}` or `{:unexpected_event, ...}`.

  ## Interrupted tool calls

  A turn that fails or is killed after the assistant's `tool_use` was appended leaves
  it unanswered. The next turn appends an `interrupted: true` tool result for each
  missing call, in memory and store, before the user message, and logs a warning.
  """
```

- [ ] **Step 2: Add section 12 to `MIGRATING-2.0.md`**

Insert before the line `## New, non-breaking`:

```markdown
## 12. `Turn.Server` failure replies and approval expiry

`Turn.Server.run/2` (and `Turn.Session.run/2`, `AgentProcess.run/2` with
`turn_engine: :server`) now replies where it used to crash the session:

| Reply | Before |
|---|---|
| `{:error, {:rejected, exception}}` — input failed its schema or an input guardrail | the server crashed; the caller got an exit |
| `{:error, {:handler_crashed, name, exception_or_term}}` — a handler raised, exited or threw | the server crashed |
| `{:error, {:approval_timeout, ids}}` — only with `on_approval_timeout: :fail` | n/a |

A raising `:subscriber` no longer crashes the session: it is logged and reported as
`[:normandy, :turn, :subscriber, :exception]`, and the turn continues.

Approval expiry: a parked call that nobody approved now gets
`%{error: "approval timed out: no approver responded within <ms>ms", denied: true,
expired: true}` instead of `"tool call rejected by approver"`, and an
`:approval_expired` event plus `[:normandy, :turn, :approval, :expired]` telemetry
are emitted. Pass `on_approval_timeout: :fail` to end the turn instead of continuing.

Event meta additions: `:iteration` gains `final` (and the forced-final call is now
announced), `:awaiting_approval` gains `resumed`. `:steering` is emitted after the
turn state is persisted.

A turn that failed after the assistant's `tool_use` no longer leaves the session
unusable: the next turn appends an `interrupted: true` tool result for each
unanswered call.
```

- [ ] **Step 3: Update `CLAUDE.md`**

Under `### Agent System`, after the `Normandy.Agents.Model` bullet group, add:

```markdown
- **`Normandy.Agents.Turn.Server`** - Durable `:gen_statem` turn shell
  - `run/2` replies `{:error, {:rejected, e}}` for rejected input and `{:error, {:handler_crashed, name, e}}` for a crashing handler instead of crashing
  - `on_approval_timeout: :continue | :fail` (default `:continue`) decides what an approval expiry does; expired calls get `expired: true` results
```

- [ ] **Step 4: Full verification**

Run: `mix precommit`
Expected: compile with no warnings, `deps.unlock --check-unused` clean, format applied, Credo "found no issues", Dialyzer "done (passed successfully)", tests 0 failures.

Run: `MIX_ENV=dev mix docs --warnings-as-errors`
Expected: docs build with no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn/server.ex MIGRATING-2.0.md CLAUDE.md
git commit -m "docs(agents): Turn.Server options, events, error replies and approval expiry"
```
