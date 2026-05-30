# Phase 1d — Streaming Cutover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut `BaseAgent`'s **streaming** turn (`stream_response/3`, `stream_with_tools/3`) over to run on the pure `Normandy.Agents.Turn` FSM, mirroring Phase 1c's non-streaming cutover, while the existing streaming test suite stays 100% green and the FSM core stays unchanged.

**Architecture:** Phase 1d makes **zero changes to the pure FSM** (`turn.ex`). Streaming maps at the existing LLM-call boundary — `step/2` never sees stream deltas; incremental mid-stream guarding stays encapsulated inside the streaming `call_llm` handler. The cutover is executed in two checkpoints: **Commit A** generalizes 1c's hardcoded production driver (`run_turn_effects/3`) into a reusable, injected-handler driver (`Normandy.Agents.Turn.Driver`) and moves the existing non-streaming handlers behind it **unchanged**, with the non-streaming suite (the 1c parity oracle) frozen green. **Commit B** adds a streaming handler set + `run_stream_turn/3`, wires the two public streaming entries to it, and retires `execute_streaming_tool_loop/3`.

**Tech Stack:** Elixir, ExUnit, `Task.async_stream` (tool concurrency), OpenTelemetry (`OtelCtx`, `:telemetry.span`), the existing `Normandy.Agents.Turn` FSM (Phase 1b) and `Normandy.Components.StreamProcessor`.

---

## The behavioral contract the cutover must preserve (verified from `base_agent.ex`)

These are the parity facts the streaming oracle pins. The new path must reproduce each:

1. **Entry routing (`run/2`, lines 366-371):** `if has_tools?(config) -> stream_with_tools else -> stream_response`. Symmetric to non-streaming. After cutover both delegate identically to `run_stream_turn/3` (mirroring 1c, where `run_without_tools` and `run_with_tools` are identical one-liners over `run_turn`).
2. **Admission (streaming-specific):** streaming runs `run_input_guardrails!` on the **raw** `user_input` and initializes memory, but does **NOT** schema-validate input (unlike `admit_turn_input/2`). See `stream_response/3` lines 678-699.
3. **Finalize is guard-only:** streaming does not schema-convert/validate output. Output guardrails run once on the final response (`run_streaming_output_guardrails/3`), or mid-stream in `:incremental` mode.
4. **Returned response shape:** a map with `:content` (a **list** of content blocks) and `:guardrail_violations` (a list). Tests assert `is_list(response.content)` and `Map.has_key?(response, :guardrail_violations)`. The shape test uses `Map.has_key?`, not exact-match, so extra keys do not break parity.
5. **Persisted assistant turn:** a `%ToolCallResponse{}` built from content blocks (`build_streaming_assistant_response/2`), with any `:guardrail_violations` absent. This survives `AgentMemory.history/1` re-serialization (regression test at `base_agent_streaming_test.exs:373`).
6. **Tool dispatch:** `Task.async_stream` with `max_tool_concurrency`, `OtelCtx` capture/restore, and a per-tool `callback.(:tool_result, result)` (lines 956-973).
7. **Iteration cap:** the forced-final at the cap currently re-streams via `stream_response(config, nil, callback)`; the FSM replaces this with its `awaiting_final` path (a streaming `call_llm`). Guardrails still run on the forced-final response.
8. **Errors:** a stream failure (`{:error, error}`) currently returns `{config, %{error: error}}` **early** — no assistant message persisted, no guardrails — after `IO.warn("Streaming error: ...")`. Test pins `response.error == "Stream failed"` (`base_agent_streaming_test.exs:498`). This differs from non-streaming (which raises); the new path reproduces the non-raising early return via `throw`/`catch`.

### Resolved open question (stream_response on a tools-agent)

The spec deferred this to the oracle. **Verified: every `stream_response/3` test uses a no-tools client/config.** Nothing pins "return unexecuted `tool_use` on a tools-agent." Therefore we take full 1c symmetry: `stream_response/3` and `stream_with_tools/3` both delegate to `run_stream_turn/3`, and the `has_tools?` branching lives inside it (via `turn_response_model/1` + the no-tools `tool_calls` strip in the streaming `call_llm` handler). A direct `stream_response` call on a tools-agent will now loop/dispatch (previously it returned unexecuted blocks); this is untested and out of `stream_response`'s documented no-tools contract. **Document it in the Commit B message.**

### Two deliberate, oracle-sanctioned behavior changes (note in commit messages)

- **`stream_response` no-tools final is persisted as a `%ToolCallResponse{}`** (via the unified assistant-append handler) instead of the raw streamed map. All streaming tests pass; this unifies persistence with the tool-loop path. (Contract fact #5 above is already the loop's behavior; this extends it to the no-tools entry.)
- **`stream_response` direct-call on a tools-agent now executes tools** (see resolved open question).

---

## File Structure

- **Create:** `lib/normandy/agents/turn/driver.ex` — `Normandy.Agents.Turn.Driver` (generic injected-handler interpreter) + `Turn.Driver.Handlers` struct. One responsibility: drive the FSM to a stop via injected side-effecting handlers, threading an opaque `acc`.
- **Create:** `test/agents/turn_driver_test.exs` — unit tests for `Turn.Driver` with fake handlers (effect sequencing, `acc` threading, `{acc, state}` return, the `:fail` raise).
- **Modify:** `lib/normandy/agents/base_agent.ex`
  - Commit A: replace `drive_turn/2`, `run_turn_effects/3`, `advance_turn/3` with delegation to `Turn.Driver.drive/3` + a `non_streaming_handlers/0` handler set built from the existing (unchanged) `call_turn_llm/3`, `dispatch_turn_tools/2`, `convert_turn_output/3`, `validate_turn_output/2`, `run_output_guardrails/2`, `emit_turn_event/3`, `AgentMemory.add_message/3`.
  - Commit B: add `build_stream_messages/1`, `stream_opts/2`, `streaming_handlers/1`, `call_stream_llm/3`, `dispatch_stream_tools/3`, `append_stream_message/3`, `run_stream_turn/3` (a `defp`); rewrite `stream_response/3` and `stream_with_tools/3` as one-line delegations; delete `execute_streaming_tool_loop/3`.

**No new streaming test file.** This is a parity refactor: the existing streaming suite (`base_agent_streaming_test.exs`, `base_agent_streaming_guardrails_test.exs`) is the oracle. Its mock clients are module-local to those files and produce event shapes `StreamProcessor.build_final_message/1` understands, so the cutover is verified by wiring the public entries through `run_stream_turn/3` and running that suite — not by a hand-rolled mock in a new file (which would risk event-shape drift).

---

## Task 1: `Normandy.Agents.Turn.Driver` — generic injected-handler interpreter (Commit A)

**Files:**
- Create: `lib/normandy/agents/turn/driver.ex`
- Test: `test/agents/turn_driver_test.exs`

This is a faithful generalization of 1c's `run_turn_effects/3`: same effect ordering, same `:fail` raise message, but the side effects are injected as a `%Handlers{}` set and the threaded value is an opaque `acc` (the production shells pass `%BaseAgentConfig{}`).

- [ ] **Step 1: Write the failing test**

Create `test/agents/turn_driver_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.DriverTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.Driver
  alias Normandy.Agents.Turn.Driver.Handlers

  # A response with no tool calls so a no-tools turn finalizes immediately.
  defp recording_handlers(pid) do
    %Handlers{
      call_llm: fn acc, _state, _req ->
        send(pid, {:call_llm, acc})
        %{content: "hi", tool_calls: []}
      end,
      dispatch_tools: fn _acc, calls -> Enum.map(calls, fn _ -> :result end) ++ [] end,
      convert: fn _acc, raw, _os -> raw end,
      validate: fn _acc, value -> value end,
      guard: fn _acc, _value -> :ok end,
      append: fn acc, role, _content -> [role | acc] end,
      emit: fn _acc, name, _meta -> send(pid, {:emit, name}) end
    }
  end

  test "drive/3 runs a no-tools turn to :stopped, threading acc through append" do
    state = Turn.new(response_model: :rm, output_schema: :rm)
    {acc, final} = Driver.drive(state, recording_handlers(self()), [])

    assert final.status == :stopped
    # The single assistant append threaded "assistant" into the acc list.
    assert acc == ["assistant"]
    assert_received {:call_llm, []}
    assert_received {:emit, :iteration}
  end

  test "drive/3 raises on an unexpected :fail effect" do
    # Feed a state whose next event triggers the FSM's unexpected-event guard.
    state = %Turn.State{status: :tool_dispatch, max_iterations: 5, iterations_left: 5}

    handlers = recording_handlers(self())

    assert_raise RuntimeError, ~r/Turn FSM reached :failed unexpectedly/, fn ->
      # :start on a :tool_dispatch state is unexpected -> {:fail, reason}
      Driver.drive(state, handlers, [])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agents/turn_driver_test.exs`
Expected: FAIL with `module Normandy.Agents.Turn.Driver is not available` (or `Driver.drive/3 undefined`).

- [ ] **Step 3: Write the Driver module**

Create `lib/normandy/agents/turn/driver.ex`:

```elixir
defmodule Normandy.Agents.Turn.Driver do
  @moduledoc """
  Generic synchronous interpreter for the pure `Normandy.Agents.Turn` core.

  Drives a turn to a stop by feeding `:start` into `Turn.step/2`, performing each
  returned effect via an injected `%Handlers{}` set, and feeding the resulting
  event back into `step/2` until the turn reaches a terminal effect. The driver
  owns FSM stepping and `acc` threading; the handlers own all side effects (LLM
  calls, tool dispatch, memory, guards, telemetry) and return the updated `acc`.

  `acc` is opaque to the driver — the production shells pass the running
  `%BaseAgentConfig{}` (the memory accumulator). This lets one driver serve the
  non-streaming and streaming production paths (and future shells) with different
  handler sets, the same way `Turn.Inline` serves the test/library path.

  By design, `step/2` always places the single blocking/terminal effect last in
  its effect list, so the driver performs the leading `:emit_event` /
  `:append_message` effects in order, then acts on the terminal one.
  """

  alias Normandy.Agents.Turn

  defmodule Handlers do
    @moduledoc "The injected side-effecting functions the driver consults per effect."

    @type acc :: term()
    @type t :: %__MODULE__{
            call_llm: (acc(), Turn.State.t(), map() -> term()),
            dispatch_tools: (acc(), [term()] -> [term()]),
            convert: (acc(), term(), term() -> term()),
            validate: (acc(), term() -> term()),
            guard: (acc(), term() -> any()),
            append: (acc(), String.t(), term() -> acc()),
            emit: (acc(), atom(), map() -> any())
          }
    defstruct [:call_llm, :dispatch_tools, :convert, :validate, :guard, :append, :emit]
  end

  @spec drive(Turn.State.t(), Handlers.t(), term()) :: {term(), Turn.State.t()}
  def drive(%Turn.State{} = state, %Handlers{} = handlers, acc) do
    {state, effects} = Turn.step(state, :start)
    run(acc, state, effects, handlers)
  end

  defp run(acc, state, [], _handlers), do: {acc, state}

  defp run(acc, state, [effect | rest], handlers) do
    case effect do
      {:emit_event, name, meta} ->
        handlers.emit.(acc, name, meta)
        run(acc, state, rest, handlers)

      {:append_message, role, content} ->
        run(handlers.append.(acc, role, content), state, rest, handlers)

      {:call_llm, request} ->
        response = handlers.call_llm.(acc, state, request)
        advance(acc, state, {:llm_response, response}, handlers)

      {:dispatch_tools, calls} ->
        results = handlers.dispatch_tools.(acc, calls)
        advance(acc, state, {:tool_results, results}, handlers)

      {:convert_output, raw, output_schema} ->
        advance(acc, state, {:output_converted, handlers.convert.(acc, raw, output_schema)}, handlers)

      {:validate_output, value} ->
        advance(acc, state, {:output_validated, handlers.validate.(acc, value)}, handlers)

      {:guard_output, value} ->
        handlers.guard.(acc, value)
        advance(acc, state, {:output_guarded, value}, handlers)

      {:finalize, _value} ->
        {acc, state}

      {:fail, reason} ->
        raise "Turn FSM reached :failed unexpectedly: #{inspect(reason)}"
    end
  end

  defp advance(acc, state, event, handlers) do
    {state, effects} = Turn.step(state, event)
    run(acc, state, effects, handlers)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/agents/turn_driver_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
mix format lib/normandy/agents/turn/driver.ex test/agents/turn_driver_test.exs
git add lib/normandy/agents/turn/driver.ex test/agents/turn_driver_test.exs
git commit -m "feat(turn): generic injected-handler Turn.Driver interpreter"
```

---

## Task 2: Rewire the non-streaming production path onto `Turn.Driver` (Commit A checkpoint)

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (replace `drive_turn/2`, `run_turn_effects/3`, `advance_turn/3`; add `non_streaming_handlers/0`)

The existing handler functions (`call_turn_llm/3`, `dispatch_turn_tools/2`, `convert_turn_output/3`, `validate_turn_output/2`, `emit_turn_event/3`) already have the exact arities the `%Handlers{}` slots expect, so they slot in directly. `guard` and `append` are thin closures over the existing `run_output_guardrails/2` and `AgentMemory.add_message/3`. **No handler body changes** — this is a pure refactor whose correctness is proven by the non-streaming suite staying green *before any streaming exists*.

- [ ] **Step 1: Add the alias for the driver**

In `lib/normandy/agents/base_agent.ex`, near the existing `alias Normandy.Agents.Turn` (added in Phase 1c), add:

```elixir
  alias Normandy.Agents.Turn.Driver
```

- [ ] **Step 2: Replace the driver internals**

Find the Phase 1c block (`drive_turn/2`, `run_turn_effects/3`, `advance_turn/3` — around lines 491-541) and replace **all three** with:

```elixir
  defp drive_turn(%BaseAgentConfig{} = config, %Turn.State{} = state) do
    Driver.drive(state, non_streaming_handlers(), config)
  end

  defp non_streaming_handlers do
    %Driver.Handlers{
      call_llm: &call_turn_llm/3,
      dispatch_tools: &dispatch_turn_tools/2,
      convert: &convert_turn_output/3,
      validate: &validate_turn_output/2,
      guard: fn config, value -> run_output_guardrails(config, value) end,
      append: fn config, role, content ->
        Map.put(config, :memory, AgentMemory.add_message(config.memory, role, content))
      end,
      emit: &emit_turn_event/3
    }
  end
```

Leave `run_turn/2`, `turn_response_model/1`, `admit_turn_input/2`, and all the effect-handler functions (`call_turn_llm/3`, `dispatch_turn_tools/2`, `convert_turn_output/3`, `validate_turn_output/2`, `emit_turn_event/3`) exactly as they are. `run_turn/2` still calls `drive_turn(config, state)` and destructures `{config, final_state}` — unchanged, since `Driver.drive/3` returns `{acc, state}`.

- [ ] **Step 3: Compile and confirm no leftover references**

Run: `mix compile --warnings-as-errors --force`
Expected: clean compile, no "unused function" warnings (the old `run_turn_effects/3` and `advance_turn/3` are gone; nothing else referenced them).

- [ ] **Step 4: Run the non-streaming parity oracle**

Run: `mix test test/agents/base_agent_turn_driver_test.exs test/agents/base_agent_tool_loop_test.exs test/agents/base_agent_guardrails_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 5: Run the full suite (streaming still on the old path)**

Run: `mix test`
Expected: PASS, 0 failures (streaming untouched; non-streaming now routed through `Turn.Driver`).

- [ ] **Step 6: Commit (Commit A checkpoint)**

```bash
mix format lib/normandy/agents/base_agent.ex
git add lib/normandy/agents/base_agent.ex
git commit -m "refactor(base_agent): drive non-streaming turn via generic Turn.Driver

Pure refactor: move the existing non-streaming effect handlers behind an
injected %Turn.Driver.Handlers{} set and delete the hardcoded
run_turn_effects/3 + advance_turn/3. Handler bodies unchanged; the
non-streaming suite (1c parity oracle) stays green, proving the driver
generalization is behavior-preserving before any streaming is added."
```

---

## Task 3: Streaming cutover — handlers, `run_stream_turn/3`, wire entries, retire the loop (Commit B)

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex`

This is one atomic cutover, verified by the existing streaming oracle (its mock clients produce event shapes `StreamProcessor` understands). Add the streaming machinery, flip `stream_response/3` + `stream_with_tools/3` to delegate to `run_stream_turn/3` (a `defp`), and delete `execute_streaming_tool_loop/3`.

Key design points (all preserve the contract above without touching the FSM):
- The streamed final message uses `:content` blocks, but the FSM's `tool_calls/1` reads `.tool_calls`. So `call_stream_llm/3` threads an **augmented map** = `Map.put(final_message, :tool_calls, tool_calls)` so the FSM can branch; `run_stream_turn/3` strips the synthetic `:tool_calls` key from the returned response.
- Output guardrails go in the **`validate` slot** (the value-transforming finalize step whose result becomes `final_response`), because the FSM ignores the `guard` slot's return value. The `guard` slot is a no-op.
- A stream `{:error, error}` is surfaced by `throw`ing past the driver and catching in `run_stream_turn/3`, reproducing the current non-raising early return (no persist, no guardrails). The throw is raised **outside** `with_llm_call_span/3` so no span-exception event is emitted (matching today).

- [ ] **Step 1: Add the shared stream message/opts helpers**

In `lib/normandy/agents/base_agent.ex`, add near the other streaming helpers (these replace the duplicated message/opts blocks currently inline in `stream_response/3` and `execute_streaming_tool_loop/3`):

```elixir
  # Build the [system | history] message list for a streaming LLM call.
  # History plain maps are converted to %Message{} structs so the adapter's
  # add_single_message picks them up (otherwise the catch-all drops them).
  defp build_stream_messages(config) do
    history_messages =
      AgentMemory.history(config.memory)
      |> Enum.map(fn %{role: role, content: content} ->
        %Message{role: role, content: content}
      end)

    [
      %Message{
        role: "system",
        content:
          SystemPromptGenerator.generate_prompt(
            config.prompt_specification,
            config.tool_registry
          )
      }
    ] ++ history_messages
  end

  defp stream_opts(config, callback) do
    if has_tools?(config) do
      [tools: Registry.to_tool_schemas(config.tool_registry), callback: callback]
    else
      [callback: callback]
    end
  end
```

- [ ] **Step 2: Add the streaming effect handlers**

In `lib/normandy/agents/base_agent.ex`, add:

```elixir
  # ── Streaming Turn FSM handlers (Phase 1d) ───────────────────────────────────

  defp streaming_handlers(callback) do
    %Driver.Handlers{
      call_llm: fn config, state, _request -> call_stream_llm(config, state, callback) end,
      dispatch_tools: fn config, calls -> dispatch_stream_tools(config, calls, callback) end,
      convert: fn _config, raw, _output_schema -> raw end,
      validate: fn config, value -> run_streaming_output_guardrails(config, value, callback) end,
      guard: fn _config, _value -> :ok end,
      append: fn config, role, content -> append_stream_message(config, role, content) end,
      emit: &emit_turn_event/3
    }
  end

  # Streams one LLM call to a final message, augmenting it with a :tool_calls key
  # so the pure FSM (which branches on .tool_calls) can dispatch. Tool calls are
  # stripped for no-tools agents (parity: stream_response never executed tools),
  # mirroring call_turn_llm's no-tools strip. A stream failure is thrown past the
  # driver and caught in run_stream_turn/3 (parity: non-raising early return).
  defp call_stream_llm(config, state, callback) do
    iteration = config.max_tool_iterations - state.iterations_left + 1
    llm_metadata = %{model: config.model, iteration: iteration, agent_name: config.name}

    result =
      with_llm_call_span(config, llm_metadata, fn ->
        r = stream_response_from_llm(config, build_stream_messages(config), stream_opts(config, callback))

        stop_metadata =
          case r do
            {:ok, final_message} ->
              tcs = if has_tools?(config), do: extract_tool_calls(final_message) || [], else: []
              Map.merge(llm_metadata, %{has_tool_calls: tcs != [], tool_call_count: length(tcs)})

            {:error, _error} ->
              Map.merge(llm_metadata, %{has_tool_calls: false, tool_call_count: 0})
          end

        {r, stop_metadata}
      end)

    case result do
      {:ok, final_message} ->
        tool_calls = if has_tools?(config), do: extract_tool_calls(final_message) || [], else: []
        Map.put(final_message, :tool_calls, tool_calls)

      {:error, error} ->
        throw({:stream_turn_error, error, config})
    end
  end

  # Mirror of dispatch_turn_tools with the streaming per-tool :tool_result
  # callback. Same Task.async_stream parallelism + OtelCtx propagation.
  defp dispatch_stream_tools(config, calls, callback) do
    parent_otel_ctx = OtelCtx.capture()
    max_concurrency = max(config.max_tool_concurrency || 1, 1)

    calls
    |> Task.async_stream(
      fn call ->
        OtelCtx.restore(parent_otel_ctx)
        result = execute_one_streaming_tool_call(config, call)
        callback.(:tool_result, result)
        result
      end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.map(&unwrap_tool_task_result!/1)
  end

  # Assistant turns are persisted as a %ToolCallResponse{} built from content
  # blocks so tool_use survives AgentMemory.history/1 re-serialization; any
  # :guardrail_violations is dropped (build produces a fresh struct without it).
  # Other roles (e.g. "tool") persist their content unchanged.
  defp append_stream_message(config, "assistant", content) do
    tool_calls = extract_tool_calls(content) || []
    message = build_streaming_assistant_response(content, tool_calls)
    Map.put(config, :memory, AgentMemory.add_message(config.memory, "assistant", message))
  end

  defp append_stream_message(config, role, content) do
    Map.put(config, :memory, AgentMemory.add_message(config.memory, role, content))
  end

  # ── End streaming Turn FSM handlers ──────────────────────────────────────────
```

- [ ] **Step 3: Add `run_stream_turn/3`**

In `lib/normandy/agents/base_agent.ex`, add (near `run_turn/2`):

```elixir
  # Streaming analog of run_turn/2. Admission (input guardrails + memory init,
  # NO schema validation — streaming parity) before Turn.step(:start), then drive
  # the FSM with the streaming handler set. Returns {config, final_response}; the
  # synthetic :tool_calls key (added so the FSM could branch) is stripped from the
  # returned response. A thrown stream error becomes the non-raising early return.
  defp run_stream_turn(config, user_input, callback) when is_function(callback, 2) do
    config = admit_stream_turn_input(config, user_input)

    state =
      Turn.new(
        max_iterations: config.max_tool_iterations,
        response_model: turn_response_model(config),
        output_schema: config.output_schema
      )

    try do
      {config, final_state} = Driver.drive(state, streaming_handlers(callback), config)
      {config, Map.delete(final_state.final_response, :tool_calls)}
    catch
      {:stream_turn_error, error, config_at_failure} ->
        IO.warn("Streaming error: #{inspect(error)}")
        {config_at_failure, %{error: error}}
    end
  end

  # Streaming admission: input guardrails on the RAW user_input + memory init.
  # Unlike admit_turn_input/2, streaming does NOT schema-validate input.
  defp admit_stream_turn_input(config, nil), do: config

  defp admit_stream_turn_input(config, user_input) do
    run_input_guardrails!(config, user_input)

    updated_memory =
      config.memory
      |> AgentMemory.initialize_turn()
      |> AgentMemory.add_message("user", user_input)

    config
    |> Map.put(:current_user_input, user_input)
    |> Map.put(:memory, updated_memory)
  end
```

- [ ] **Step 4: Rewrite `stream_response/3` as a delegation**

Replace the entire body of `stream_response/3` (currently lines ~677-774, from `def stream_response(...)` through its final `end`) with:

```elixir
  def stream_response(config, user_input \\ nil, callback) when is_function(callback, 2) do
    run_stream_turn(config, user_input, callback)
  end
```

Keep the `@doc` block above it.

- [ ] **Step 5: Rewrite `stream_with_tools/3` as a delegation**

Replace the entire body of `stream_with_tools/3` (currently lines ~822-852) with:

```elixir
  def stream_with_tools(config = %BaseAgentConfig{}, user_input \\ nil, callback)
      when is_function(callback, 2) do
    run_stream_turn(config, user_input, callback)
  end
```

Keep the `@doc` and `@spec` blocks above it.

- [ ] **Step 6: Delete `execute_streaming_tool_loop/3`**

Delete both clauses of `execute_streaming_tool_loop/3` (the `iterations_left <= 0` clause and the main clause, currently lines ~854-992).

- [ ] **Step 7: Compile and let the compiler find newly-dead code**

Run: `mix compile --warnings-as-errors --force`
Expected: clean. If the compiler reports an unused private function, verify it is genuinely unreferenced before deleting:
- `extract_tool_calls/1` — **keep** (used by `call_stream_llm/3` and `append_stream_message/3`).
- `build_streaming_assistant_response/2` — **keep** (used by `append_stream_message/3`).
- `consume_stream_with_incremental_guards/3`, `strip_partial_tool_use/1`, `run_streaming_output_guardrails/3`, `extract_streaming_text/1`, `extract_text_delta_for_guard/1`, `report_incremental_violation/4` — **keep** (used by the streaming `call_llm`/`validate` handlers).
- `pending_tool_call_count/1` — **keep** (used by `emit_turn_event/3`).

If the compiler flags anything not in this keep-list as unused, delete it.

- [ ] **Step 8: Run the streaming parity oracle**

Run: `mix test test/agents/base_agent_streaming_test.exs test/agents/base_agent_streaming_guardrails_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 9: Run the full suite**

Run: `mix test`
Expected: PASS, 0 failures.

- [ ] **Step 10: Commit (Commit B cutover)**

```bash
mix format lib/normandy/agents/base_agent.ex
git add lib/normandy/agents/base_agent.ex
git commit -m "refactor(base_agent): cut streaming turn onto the Turn FSM

stream_response/3 and stream_with_tools/3 now delegate to run_stream_turn/3
(both identically; has_tools? branching lives inside it, mirroring 1c).
execute_streaming_tool_loop/3 deleted. The forced-final at the iteration
cap is now the FSM's awaiting_final streaming call.

Two oracle-sanctioned behavior changes: (1) stream_response's no-tools
final is persisted as a %ToolCallResponse{} (unifies with the loop path);
(2) a direct stream_response call on a tools-agent now executes tools
(previously returned unexecuted tool_use) — untested and out of
stream_response's documented no-tools contract."
```

---

## Task 4: Full-suite verification and formatting gate

**Files:** none (verification only)

- [ ] **Step 1: Format check**

Run: `mix format --check-formatted`
Expected: no output (all formatted). If it fails, run `mix format` and amend the relevant commit.

- [ ] **Step 2: Warnings-as-errors compile**

Run: `mix compile --warnings-as-errors --force`
Expected: clean.

- [ ] **Step 3: Full suite**

Run: `mix test`
Expected: PASS, 0 failures. Note the doctest/property/test counts (should be the prior totals plus the new `turn_driver_test` cases).

- [ ] **Step 4: Confirm the FSM core is unchanged**

Run: `git diff main -- lib/normandy/agents/turn.ex`
Expected: **empty** (no changes to the pure FSM in this phase).

- [ ] **Step 5: Confirm non-streaming handler bodies are unchanged**

Run: `git diff main -- lib/normandy/agents/base_agent.ex | grep -E "^[-+].*defp (call_turn_llm|dispatch_turn_tools|convert_turn_output|validate_turn_output|emit_turn_event)"`
Expected: no `+`/`-` lines touching those function *definitions* (they were only moved behind the handler set, not edited).

---

## Self-Review (completed during planning)

**1. Spec coverage:**
- Decision 1 (FSM unchanged, LLM-call boundary) → Task 4 Step 4 verifies the `turn.ex` diff is empty. ✓
- Decision 2 (one injected-handler driver, refactor-first) → Task 1 (driver) + Task 2 (non-streaming behind it, Commit A green) + Task 3 (streaming, Commit B). ✓
- Handler table (7 slots, streaming vs non-streaming) → Task 2 `non_streaming_handlers/0` + Task 3 `streaming_handlers/1`. ✓
- Entry wiring (both → `run_stream_turn`, forced-final via `awaiting_final`) → Task 3 Steps 4-5. ✓
- Open question (stream_response on tools-agent) → resolved in the contract section against the oracle; documented in the Task 3 cutover commit. ✓
- Guard-only finalize via identity convert/validate → Task 3 `streaming_handlers/1` (`convert` identity, guardrails in `validate`, `guard` no-op). ✓
- Incremental guarding encapsulated in `call_llm` → Task 3 reuses `stream_response_from_llm/3` (which calls `consume_stream_with_incremental_guards/3`). ✓
- Parity oracle green throughout → Task 2 Step 5, Task 3 Steps 8-9, Task 4 Step 3. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step shows complete code. The "keep-list" in Task 3 Step 7 enumerates exact functions. ✓

**3. Type/name consistency:**
- `Driver.Handlers` slots: `call_llm/3`, `dispatch_tools/2`, `convert/3`, `validate/2`, `guard/2`, `append/3`, `emit/3` — used identically in `non_streaming_handlers/0` (Task 2) and `streaming_handlers/1` (Task 3). ✓
- `Driver.drive/3` returns `{acc, state}` — consumed as `{config, final_state}` in both `drive_turn/2` (Task 2) and `run_stream_turn/3` (Task 3). ✓
- `run_stream_turn/3` is a `defp` (Task 3), called only by the rewritten `stream_response/3` and `stream_with_tools/3`. ✓
- `call_stream_llm/3`, `dispatch_stream_tools/3`, `append_stream_message/3`, `build_stream_messages/1`, `stream_opts/2`, `admit_stream_turn_input/2` — defined in Task 3, referenced only by Task 3 code + the `streaming_handlers/1` closures. ✓
- The synthetic `:tool_calls` key is added in `call_stream_llm/3` (Task 3) and stripped in `run_stream_turn/3` (Task 3). ✓

**4. Risk note:** Task 2 is the only commit that touches merged 1c production code; it adds no streaming, so its green non-streaming suite isolates the refactor's correctness. The `throw`/`catch` in Task 3 is the single non-obvious control-flow choice and is justified by error-path contract #8.
