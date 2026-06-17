# Phase 5: Compaction Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire context-window compaction into the agent turn loop by making `:steering` a real FSM state that invokes a pluggable `Compactor` behaviour at every tool-batch boundary.

**Architecture:** The pure FSM core (`Normandy.Agents.Turn`) gains a real `:steering` state: after applying a tool batch it emits a blocking `{:maybe_compact, info}` effect, parks in `:steering`, and resolves continue-vs-forced-final only when the shell feeds back `{:compaction_done, meta}`. The shells (`Turn.Driver`, `Turn.Inline`) interpret `:maybe_compact` exactly like `:dispatch_tools` — run an injected handler, feed the result event back. A new `Normandy.Behaviours.Compactor` behaviour ships a `NoOp` default (zero-cost, observably identical to today) plus an opt-in `Compactor.WindowManager` impl that wraps the existing `Normandy.Context.WindowManager` strategies. `BaseAgent`'s production handler resolves the configured compactor and the model's context window (via the configured `ModelCatalog`) and compacts `config.memory`.

**Tech Stack:** Elixir, OTP, ExUnit + StreamData (property tests), `@behaviour` contracts. No new dependencies.

## Global Constraints

These apply to **every** task below (copied verbatim from the design + project rules):

- **Default-off principle:** every new behaviour ships a default impl that preserves *current* behavior, so the "everything off" path is observably identical to today. → The default `Compactor` is `NoOp` (no compaction). The WindowManager-backed compactor is opt-in only.
- **Pure core does no I/O:** `Turn.step/2` must remain a pure function `step(state, event) -> {state', [effect]}`. Token counting and compaction are shell-side effects, never done in the core.
- **`step/2` is a total function:** unexpected `(state, event)` pairs fall through to `:failed` (never raise). The fallback clause already exists; do not remove it.
- **Effect ordering:** `step/2` always places the single blocking/terminal effect (`:call_llm`, `:dispatch_tools`, `:maybe_compact`, `:finalize`, `:fail`) **last** in its returned effect list. The new `:maybe_compact` effect must be last in `apply_tool_results`'s list.
- **Suite stays green after every task:** project rule — "If tests fail, they must be fixed, even if [they] were items we were not working on." Each task ends with the **entire** `mix test` suite passing, not just the task's own tests. The task ordering below is designed so new shell paths stay dormant (the core doesn't emit `:maybe_compact` until Task 6) and nothing breaks between tasks.
- **Format before testing:** run `mix format` before `mix test` (project rule in CLAUDE.md).
- **No silent fallbacks:** a missing/`nil` compactor resolves to the explicit `NoOp` default, never to a silent skip.

---

## File Structure

**New files:**

- `lib/normandy/behaviours/compactor.ex` — the `Compactor` behaviour contract + nested `NoOp` default impl (mirrors `budget_tracker.ex` / `model_catalog.ex` layout).
- `lib/normandy/behaviours/compactor/window_manager.ex` — opt-in impl wrapping `Normandy.Context.WindowManager` (mirrors `session_store/ets.ex` layout for a substantive impl in its own file).
- `test/behaviours/compactor_test.exs` — contract tests for `NoOp` and `WindowManager`.
- `test/agents/turn_compaction_test.exs` — focused core tests for the new `:steering` transitions.
- `test/integration/compaction_turn_test.exs` — end-to-end test: opt-in compactor truncates an over-window conversation at the steering boundary; default `NoOp` leaves it untouched.

**Modified files:**

- `lib/normandy/agents/turn.ex` — `apply_tool_results/2` enters `:steering` + emits `{:maybe_compact, …}`; new `:steering` clauses resolve `{:compaction_done, …}`; moduledoc update.
- `lib/normandy/agents/turn/driver.ex` — `Handlers` gains a `compact` field; new `:maybe_compact` effect clause threads `acc`.
- `lib/normandy/agents/turn/inline.ex` — `deps` gains a `:compact` default (no-op); new `:maybe_compact` effect clause; moduledoc update.
- `lib/normandy/behaviours/config.ex` — new `compactor` slot (default `{Compactor.NoOp, []}`); moduledoc note. NOT a dispatch-path slot, so `to_pipeline/1` is untouched.
- `lib/normandy/behaviours/model_catalog.ex` — moduledoc: compaction consumption has landed (Phase 5).
- `lib/normandy/agents/base_agent.ex` — `compact_turn_memory/3` handler + helpers (`compactor_ref/1`, `catalog_ref/1`, `context_window_for/1`); wired into `non_streaming_handlers/0` and `streaming_handlers/1`; `emit_turn_event/3` clause for `:compaction`.
- `test/agents/turn_test.exs` — split the two steering-boundary assertions across the new two-step boundary.
- `test/agents/turn_approval_test.exs` — split the three steering-boundary assertions (all-rejected, approved-results, cap).
- `test/agents/turn_property_test.exs` — `drive/4` + `next_event/3` handle `:steering`; `event_gen` includes `{:compaction_done, …}`.
- `test/agents/turn_driver_test.exs` — both manual `%Handlers{}` get a no-op `compact` field.
- `test/behaviours/config_test.exs` — assert the `compactor` default slot.
- `test/agents/base_agent_exposure_test.exs` — assert `compact` is populated on the exposed handler set.

---

### Task 1: `Compactor` behaviour + `NoOp` default

**Files:**
- Create: `lib/normandy/behaviours/compactor.ex`
- Test: `test/behaviours/compactor_test.exs`

**Interfaces:**
- Consumes: nothing (foundation task).
- Produces:
  - `Normandy.Behaviours.Compactor` behaviour with `@callback maybe_compact(acc :: term(), ctx :: ctx(), opts :: keyword()) :: {term(), map()}` where `ctx :: %{model: String.t() | nil, window: pos_integer() | nil}`. Returns `{maybe_updated_acc, meta_map}`; `meta_map` always carries `:compacted` (boolean).
  - `Normandy.Behaviours.Compactor.NoOp` — returns `{acc, %{compacted: false}}` unchanged.

- [ ] **Step 1: Write the failing test**

Create `test/behaviours/compactor_test.exs`:

```elixir
defmodule Normandy.Behaviours.CompactorTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.Compactor

  describe "NoOp default" do
    test "returns the acc unchanged and reports compacted: false" do
      acc = %{memory: :untouched, model: "claude-3-5-sonnet-20241022"}
      ctx = %{model: "claude-3-5-sonnet-20241022", window: 200_000}

      assert {^acc, meta} = Compactor.NoOp.maybe_compact(acc, ctx, [])
      assert meta.compacted == false
    end

    test "ignores ctx and opts entirely (never inspects the window)" do
      acc = :anything
      assert {:anything, %{compacted: false}} = Compactor.NoOp.maybe_compact(acc, %{model: nil, window: nil}, foo: :bar)
    end

    test "implements the Compactor behaviour" do
      behaviours = Compactor.NoOp.module_info(:attributes)[:behaviour] || []
      assert Normandy.Behaviours.Compactor in behaviours
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/compactor_test.exs`
Expected: FAIL — `Normandy.Behaviours.Compactor.NoOp` is undefined (module does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `lib/normandy/behaviours/compactor.ex`:

```elixir
defmodule Normandy.Behaviours.Compactor do
  @moduledoc """
  Contract for context-window compaction at the turn's `:steering` boundary.

  After each tool batch the FSM core (`Normandy.Agents.Turn`) emits a
  `{:maybe_compact, info}` effect and parks in `:steering`. The shell resolves
  that effect by invoking the configured Compactor, which may shrink the running
  conversation (held on `acc`) before the next LLM call, then feeds
  `{:compaction_done, meta}` back into the core.

  `ctx` carries the decision inputs the core cannot compute (it is pure):

    * `:model`  — the model id for this turn
    * `:window` — the model's context-window limit from the configured
      `ModelCatalog`, or `nil` if the model is unknown

  Implementations return `{maybe_updated_acc, meta}`. `meta` always carries
  `:compacted` (a boolean); the WindowManager impl adds `:tokens_before`,
  `:tokens_after`, and `:strategy`. The default impl `NoOp` performs no work and
  preserves current (non-compacting) behavior — the design's default-off
  principle.
  """

  @type ctx :: %{model: String.t() | nil, window: pos_integer() | nil}

  @callback maybe_compact(acc :: term(), ctx(), opts :: keyword()) :: {term(), map()}

  defmodule NoOp do
    @moduledoc "Default Compactor: never compacts (back-compat, zero cost)."
    @behaviour Normandy.Behaviours.Compactor

    @impl true
    def maybe_compact(acc, _ctx, _opts), do: {acc, %{compacted: false}}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/compactor_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/compactor.ex test/behaviours/compactor_test.exs
git commit -m "feat: add Compactor behaviour with NoOp default"
```

---

### Task 2: `Compactor.WindowManager` opt-in impl

**Files:**
- Create: `lib/normandy/behaviours/compactor/window_manager.ex`
- Test: `test/behaviours/compactor_test.exs` (add a describe block)

**Interfaces:**
- Consumes: `Normandy.Behaviours.Compactor` (Task 1); `Normandy.Context.WindowManager` (`new/1`, `estimate_conversation_tokens/1`, `ensure_within_limit/2`); `acc` is expected to be a struct/map with a `:memory` field (the production `acc` is `%BaseAgentConfig{}`).
- Produces: `Normandy.Behaviours.Compactor.WindowManager.maybe_compact/3` returning `{acc', %{compacted:, tokens_before:, tokens_after:, strategy:}}` or `{acc, %{compacted: false, reason: :no_window}}` / `{acc, %{compacted: false, error: reason}}`.

- [ ] **Step 1: Write the failing test**

Append to `test/behaviours/compactor_test.exs` (inside the module, after the `NoOp` describe block):

```elixir
  describe "WindowManager impl" do
    alias Normandy.Behaviours.Compactor.WindowManager, as: WMCompactor
    alias Normandy.Components.AgentMemory

    defp mem_with(messages) do
      Enum.reduce(messages, AgentMemory.new_memory(nil), fn {role, content}, m ->
        AgentMemory.add_message(m, role, content)
      end)
    end

    test "no window in ctx and no explicit max_tokens → skips, reason :no_window" do
      acc = %{memory: mem_with([{"user", "hi"}])}
      assert {^acc, %{compacted: false, reason: :no_window}} =
               WMCompactor.maybe_compact(acc, %{model: "mystery", window: nil}, [])
    end

    test "conversation under the window is left untouched" do
      acc = %{memory: mem_with([{"user", "short"}, {"assistant", "ok"}])}
      assert {result, meta} =
               WMCompactor.maybe_compact(acc, %{model: "m", window: 200_000}, [])

      assert meta.compacted == false
      assert AgentMemory.history(result.memory) == AgentMemory.history(acc.memory)
    end

    test "conversation over the window is truncated (oldest_first default)" do
      # ~25 chars each → ~6 tokens/msg + 10 overhead; 40 messages well exceeds a
      # tiny 80-token window minus 64 reserved.
      msgs = for i <- 1..40, do: {"user", "message number #{i} padding"}
      acc = %{memory: mem_with(msgs)}

      {result, meta} =
        WMCompactor.maybe_compact(acc, %{model: "m", window: 80}, reserved_tokens: 16)

      assert meta.compacted == true
      assert meta.tokens_after < meta.tokens_before
      assert length(AgentMemory.history(result.memory)) < length(AgentMemory.history(acc.memory))
      assert meta.strategy == :oldest_first
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/compactor_test.exs`
Expected: FAIL — `Normandy.Behaviours.Compactor.WindowManager` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/normandy/behaviours/compactor/window_manager.ex`:

```elixir
defmodule Normandy.Behaviours.Compactor.WindowManager do
  @moduledoc """
  Opt-in Compactor that wraps `Normandy.Context.WindowManager`'s truncation
  strategies (`:oldest_first | :sliding_window | :summarize`).

  Triggered at the turn's `:steering` boundary: builds a `WindowManager` whose
  `max_tokens` is the model's context window (from `ctx.window`, unless `opts`
  pins an explicit `:max_tokens`), then delegates to
  `WindowManager.ensure_within_limit/2` — a no-op when already under budget.

  `opts` flow straight to `WindowManager.new/1` (`:strategy`, `:reserved_tokens`,
  `:max_tokens`). The `:summarize` strategy needs `acc.client`; if summarization
  fails it returns the original `acc` with `%{compacted: false, error: reason}`
  rather than crashing the turn.
  """
  @behaviour Normandy.Behaviours.Compactor

  alias Normandy.Context.WindowManager, as: WM

  @impl true
  def maybe_compact(acc, %{window: window}, opts) do
    case build_manager(window, opts) do
      nil ->
        {acc, %{compacted: false, reason: :no_window}}

      %WM{} = manager ->
        run(acc, manager)
    end
  end

  # Honour an explicit opts :max_tokens; otherwise use the model window; if
  # neither is known, skip (no trigger basis).
  defp build_manager(window, opts) do
    cond do
      Keyword.has_key?(opts, :max_tokens) -> WM.new(opts)
      is_integer(window) -> %{WM.new(opts) | max_tokens: window}
      true -> nil
    end
  end

  defp run(acc, manager) do
    before = WM.estimate_conversation_tokens(acc.memory)

    case WM.ensure_within_limit(acc, manager) do
      {:ok, acc2} ->
        after_tokens = WM.estimate_conversation_tokens(acc2.memory)

        {acc2,
         %{
           compacted: after_tokens < before,
           tokens_before: before,
           tokens_after: after_tokens,
           strategy: manager.strategy
         }}

      {:error, reason} ->
        {acc, %{compacted: false, error: reason}}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/compactor_test.exs`
Expected: PASS (6 tests total — 3 NoOp + 3 WindowManager).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/compactor/window_manager.ex test/behaviours/compactor_test.exs
git commit -m "feat: add opt-in WindowManager-backed Compactor impl"
```

---

### Task 3: Add the `compactor` slot to `Behaviours.Config`

**Files:**
- Modify: `lib/normandy/behaviours/config.ex`
- Test: `test/behaviours/config_test.exs`

**Interfaces:**
- Consumes: `Normandy.Behaviours.Compactor.NoOp` (Task 1).
- Produces: `%Normandy.Behaviours.Config{}` gains field `compactor :: ref()`, defaulting to `{Compactor.NoOp, []}`. `to_pipeline/1` is unchanged (compactor is not a dispatch-path slot).

- [ ] **Step 1: Write the failing test**

In `test/behaviours/config_test.exs`, inside the `describe "default bundle"` block, add a test after the existing `"has all-default impl refs"` test:

```elixir
    test "default bundle carries the NoOp compactor slot" do
      b = %Config{}
      assert b.compactor == {Normandy.Behaviours.Compactor.NoOp, []}
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/behaviours/config_test.exs`
Expected: FAIL — `key :compactor not found` on `%Config{}` (KeyError) or assertion failure.

- [ ] **Step 3: Write minimal implementation**

In `lib/normandy/behaviours/config.ex`:

a) Add the alias near the other behaviour aliases (after `alias Normandy.Behaviours.BudgetTracker`):

```elixir
  alias Normandy.Behaviours.Compactor
```

b) Add `compactor: ref()` to the `@type t` map (after the `budget: ref(),` line):

```elixir
          budget: ref(),
          compactor: ref(),
```

c) Add the defstruct default (after the `budget: {BudgetTracker.NoOp, []},` line):

```elixir
            budget: {BudgetTracker.NoOp, []},
            compactor: {Compactor.NoOp, []},
```

d) Extend the moduledoc's slot description. Change the sentence listing non-dispatch slots to include `compactor`:

```elixir
  `to_pipeline/1` adapts the **dispatch-path** slots (`policy`, `budget`,
  `before_hooks`, `after_hooks`) into a `%Normandy.Agents.Dispatch.Pipeline{}`.
  Building it here (not on `Dispatch`) keeps the Phase 1 chokepoint untouched —
  the dependency points Phase 2 → Phase 1. The `credential`, `compactor`,
  `model_catalog`, `session_store`, and `session_registry` slots are not
  dispatch-path concerns and are not placed on the pipeline. `compactor` selects
  the `:steering`-boundary compaction strategy (Phase 5); `session_store`
  selects where session entries / turn state persist; it is wired here but not
  yet consumed by the turn loop (Phase 4 reads it).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/behaviours/config_test.exs`
Expected: PASS. Also run `mix test` (full suite) to confirm the new struct field broke nothing.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/config.ex test/behaviours/config_test.exs
git commit -m "feat: add compactor slot to behaviours config (NoOp default)"
```

---

### Task 4: `Driver` + `Inline` `:maybe_compact` plumbing (dormant)

**Files:**
- Modify: `lib/normandy/agents/turn/driver.ex`
- Modify: `lib/normandy/agents/turn/inline.ex`
- Test: `test/agents/turn_driver_test.exs`

**Interfaces:**
- Consumes: nothing new (these clauses are dormant until the core emits `:maybe_compact` in Task 6).
- Produces:
  - `Driver.Handlers` gains field `compact :: (acc(), Turn.State.t(), map() -> {acc(), map()})`. The `:maybe_compact` effect runs it and feeds `{:compaction_done, meta}` back, threading the (possibly compacted) `acc`.
  - `Inline` gains a `:compact` dep default (`fn _info -> :ok end`); the `:maybe_compact` effect runs it and feeds `{:compaction_done, %{}}` back.

**Why dormant:** the core does not emit `{:maybe_compact, …}` until Task 6, so these clauses are not exercised by any existing turn until then. Adding them now (with the `compact` field populated by no-op in tests) keeps the suite green and lets Task 6's core change activate them without a second shell edit.

- [ ] **Step 1: Update the driver test handlers (still green) and add a focused clause test**

In `test/agents/turn_driver_test.exs`:

a) Add a `compact` field to `recording_handlers/1` (after the `append:` line, before `emit:`):

```elixir
      append: fn acc, role, _content -> [role | acc] end,
      compact: fn acc, _state, _info -> {acc, %{compacted: false}} end,
      emit: fn _acc, name, _meta -> send(pid, {:emit, name}) end
```

b) Add a `compact` field to the inline `%Handlers{}` in the `"runs a tool loop"` test (after its `append:` line, before `emit:`):

```elixir
      append: fn acc, role, _content -> [role | acc] end,
      compact: fn acc, _state, _info -> {acc, %{compacted: false}} end,
      emit: fn _acc, _name, _meta -> :ok end
```

c) Add a focused test at the end of the module (before the closing `end`) that drives the `:maybe_compact` effect directly via a `:steering` state. This test is written against the Task 6 core, so it is added here but will only pass once Task 6 lands; mark it so:

```elixir
  test "drive/3 runs the compact handler at the steering boundary and threads acc" do
    # Hand-build a state already at :tool_dispatch; one tool result drives it
    # through :steering -> {:maybe_compact} -> {:compaction_done} -> next call.
    state = %Turn.State{
      status: :tool_dispatch,
      max_iterations: 5,
      iterations_left: 5,
      response_model: :rm,
      output_schema: :rm,
      pending_calls: [%Normandy.Components.ToolCall{id: "c1", name: "t", input: %{}}]
    }

    pid = self()

    {:ok, responses} =
      Agent.start_link(fn -> [%{content: "final", tool_calls: []}] end)

    handlers = %Handlers{
      call_llm: fn _acc, _s, _r -> Agent.get_and_update(responses, fn [h | t] -> {h, t} end) end,
      dispatch_tools: fn _acc, calls -> Enum.map(calls, fn _ -> %{ok: true} end) end,
      convert: fn _acc, raw, _os -> raw end,
      validate: fn _acc, v -> v end,
      guard: fn _acc, _v -> :ok end,
      append: fn acc, role, _c -> [role | acc] end,
      compact: fn acc, _s, info ->
        send(pid, {:compacted, info})
        {[:compacted | acc], %{compacted: true}}
      end,
      emit: fn _acc, _n, _m -> :ok end
    }

    {acc, final} =
      Driver.drive(state |> Map.put(:status, :tool_dispatch), handlers, [])
      |> then(fn {acc, final} -> {acc, final} end)

    assert final.status == :stopped
    # compact handler ran exactly once, between the tool result and the next call
    assert_received {:compacted, %{iterations_left: 4}}
    assert :compacted in acc
  end
```

NOTE: feeding `:start`-driven entry requires the state to begin at `:provisioning`; here we instead invoke the FSM at `:tool_dispatch` by simulating the tool-results event. Since `Driver.drive/3` always begins with `Turn.step(state, :start)`, replace the test body's first step with a direct `Turn.step` walk if `drive/3` cannot start mid-turn. **Implementer note:** if `drive/3`'s hardcoded `:start` makes mid-turn entry awkward, assert the clause via `Turn.step/2` + a hand-rolled effect loop instead — the goal is only to prove the `:maybe_compact` → `compact` handler → `{:compaction_done}` wiring threads `acc`. Keep whichever form compiles cleanly.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agents/turn_driver_test.exs`
Expected: FAIL — the focused compaction test fails (the `Handlers` struct has no `:compact` key yet → `KeyError`), and/or the existing tests fail to compile because `compact:` is an unknown struct key.

- [ ] **Step 3: Write minimal implementation**

a) In `lib/normandy/agents/turn/driver.ex`, add `compact` to the `Handlers` `@type t` (after the `append:` line) and `defstruct`:

```elixir
            append: (acc(), String.t(), term() -> acc()),
            compact: (acc(), Turn.State.t(), map() -> {acc(), map()}),
            emit: (acc(), atom(), map() -> any())
          }
    defstruct [:call_llm, :dispatch_tools, :convert, :validate, :guard, :append, :compact, :emit]
```

b) Add the `:maybe_compact` effect clause in the `run/4` `case effect do` (place it right after the `{:dispatch_tools, calls}` clause):

```elixir
      {:maybe_compact, info} ->
        {acc2, meta} = handlers.compact.(acc, state, info)
        advance(acc2, state, {:compaction_done, meta}, handlers)
```

c) In `lib/normandy/agents/turn/inline.ex`, add the `:compact` default to the `deps` merge map (after the `guard:` default):

```elixir
          guard: fn _value -> :ok end,
          compact: fn _info -> :ok end
```

d) Add the `:maybe_compact` clause in `inline.ex`'s `process/3` `case effect do` (right after the `{:dispatch_tools, calls}` clause):

```elixir
      {:maybe_compact, info} ->
        deps.compact.(info)
        advance(state, {:compaction_done, %{}}, deps)
```

e) Update `inline.ex` moduledoc: change the line `Streaming, guardrails, validation, persistence, approval and compaction shells come in later phases.` to:

```elixir
  This is the library / scripted-run shell. It does NOT (yet) replace
  `BaseAgent.run/2`; it exists to prove the FSM core runs a real turn against a
  real `Dispatch` chokepoint. Compaction at the `:steering` boundary is
  supported via the optional `:compact` dep (default no-op); streaming,
  guardrails, validation, persistence and approval shells come in later phases.
```

f) Add the `:compact` dep to inline.ex's `deps` documentation list (after the `:guard` bullet):

```elixir
    * `:compact`  — `fn info -> any end` (optional, defaults to no-op). Invoked at the
                    `:steering` boundary; the inline shell does not thread memory, so
                    a real impl must compact external state by side effect.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/agents/turn_driver_test.exs test/agents/turn_inline_test.exs`
Expected: the existing driver/inline tests PASS. The focused compaction test added in Step 1 **will still fail** because the core does not yet emit `:maybe_compact` (Task 6). That is expected — tag it `@tag :pending_phase5_core` and exclude it for now:

Add `@tag :pending_phase5_core` above the focused test, then run:
`mix test test/agents/turn_driver_test.exs --exclude pending_phase5_core`
Expected: PASS. Run full suite `mix test --exclude pending_phase5_core` → PASS.

**Implementer note:** the focused test's exclusion tag is removed in Task 6, Step 6, once the core emits the effect.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn/driver.ex lib/normandy/agents/turn/inline.ex test/agents/turn_driver_test.exs
git commit -m "feat: add dormant :maybe_compact plumbing to Driver and Inline shells"
```

---

### Task 5: Production `compact` handler in `BaseAgent` (dormant)

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex`
- Modify: `lib/normandy/behaviours/model_catalog.ex` (moduledoc only)
- Test: `test/agents/base_agent_exposure_test.exs`

**Interfaces:**
- Consumes: `Normandy.Behaviours.Compactor` + `Compactor.NoOp` (Task 1); `%Normandy.Behaviours.Config{compactor:, model_catalog:}` (Task 3); `Driver.Handlers.compact` field (Task 4).
- Produces:
  - `BaseAgent.compact_turn_memory/3 :: (BaseAgentConfig.t(), Turn.State.t(), map()) -> {BaseAgentConfig.t(), map()}` — resolves the configured compactor + the model's context window, compacts `config.memory`, logs a lifecycle line when it actually compacts.
  - `non_streaming_handlers/0` and `streaming_handlers/1` now populate `compact: &compact_turn_memory/3`.

**Why dormant:** same as Task 4 — the core does not emit `:maybe_compact` until Task 6, so `compact_turn_memory/3` is wired but not invoked. With the default config (`compactor: {NoOp, []}`) it would no-op anyway.

- [ ] **Step 1: Write the failing test**

In `test/agents/base_agent_exposure_test.exs`, inside the existing `"non_streaming_handlers/0 returns a fully-populated Driver.Handlers struct"` test, add an assertion (alongside the existing field assertions):

```elixir
    assert is_function(h.compact, 3)
```

If a separate streaming-handler exposure test exists, add the same assertion there. If not, add a new test:

```elixir
  test "compact_turn_memory/3 with default config is a NoOp that returns memory unchanged" do
    alias Normandy.Agents.BaseAgentConfig
    alias Normandy.Components.AgentMemory

    memory =
      AgentMemory.new_memory(nil)
      |> AgentMemory.add_message("user", "hello")

    config = %BaseAgentConfig{model: "claude-3-5-sonnet-20241022", memory: memory, behaviours: nil}

    {config2, meta} = BaseAgent.compact_turn_memory(config, %Normandy.Agents.Turn.State{}, %{iterations_left: 3})

    assert meta.compacted == false
    assert AgentMemory.history(config2.memory) == AgentMemory.history(config.memory)
  end
```

(This requires `compact_turn_memory/3` to be a public `@doc false` function, mirroring the existing public `non_streaming_handlers/0`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agents/base_agent_exposure_test.exs`
Expected: FAIL — `h.compact` is `nil` (not a function) and `BaseAgent.compact_turn_memory/3` is undefined.

- [ ] **Step 3: Write minimal implementation**

In `lib/normandy/agents/base_agent.ex`:

a) Add `compact: &compact_turn_memory/3` to `non_streaming_handlers/0`'s `%Driver.Handlers{}` (after the `append:` field, before `emit:`):

```elixir
      append: fn config, role, content ->
        Map.put(config, :memory, AgentMemory.add_message(config.memory, role, content))
      end,
      compact: &compact_turn_memory/3,
      emit: &emit_turn_event/3
```

b) Add the same to `streaming_handlers/1`'s `%Driver.Handlers{}` (after its `append:` field, before `emit:`):

```elixir
      append: fn config, role, content -> append_stream_message(config, role, content) end,
      compact: &compact_turn_memory/3,
      emit: &emit_turn_event/3
```

c) Add the handler + helpers. Place them in the "Effect handlers" region, after `emit_turn_event/3`'s clauses (before the `# ── End Turn FSM production interpreter ──` marker):

```elixir
  # Compaction at the :steering boundary. Resolves the configured Compactor and
  # the model's context window (via the configured ModelCatalog), compacts the
  # running config.memory, and logs when it actually shrinks the conversation.
  # The default config selects Compactor.NoOp, so this is observably a no-op
  # unless an agent opts into a real compactor.
  @doc false
  def compact_turn_memory(%BaseAgentConfig{} = config, %Turn.State{} = _state, info) do
    {mod, opts} = compactor_ref(config)
    ctx = %{model: config.model, window: context_window_for(config)}
    {config2, meta} = mod.maybe_compact(config, ctx, opts)

    if Map.get(meta, :compacted) do
      log_lifecycle(:debug, "normandy agent compaction",
        agent: log_agent_name(config),
        iterations_left: Map.get(info, :iterations_left),
        tokens_before: Map.get(meta, :tokens_before),
        tokens_after: Map.get(meta, :tokens_after),
        strategy: Map.get(meta, :strategy)
      )
    end

    {config2, meta}
  end

  defp compactor_ref(%BaseAgentConfig{behaviours: %Normandy.Behaviours.Config{compactor: ref}}),
    do: ref

  defp compactor_ref(_config), do: {Normandy.Behaviours.Compactor.NoOp, []}

  defp context_window_for(%BaseAgentConfig{model: model} = config) do
    {catalog_mod, _opts} = catalog_ref(config)
    catalog_mod.context_window(model)
  end

  defp catalog_ref(%BaseAgentConfig{behaviours: %Normandy.Behaviours.Config{model_catalog: ref}}),
    do: ref

  defp catalog_ref(_config), do: {Normandy.Behaviours.ModelCatalog.Static, []}
```

The compaction "event" the design calls for is the `log_lifecycle(:debug, "normandy agent compaction", …)` line inside `compact_turn_memory/3` above — do NOT add a separate `emit_turn_event(_, :compaction, _)` clause; nothing emits a `:compaction` event (the core emits `:steering`), so such a clause would be dead code.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix format && mix test test/agents/base_agent_exposure_test.exs`
Expected: PASS. Then run the full suite `mix test --exclude pending_phase5_core` → PASS (the handler is wired but dormant; default config makes it a no-op).

- [ ] **Step 5: Update `model_catalog.ex` moduledoc**

In `lib/normandy/behaviours/model_catalog.ex`, change the final moduledoc sentence:

```elixir
  The default impl `Static` is the canonical home for the context-window limits
  that previously lived hardcoded on `Normandy.Context.WindowManager`. Phase 2
  consumption is `WindowManager` sourcing its limits here; Phase 5 adds turn-loop
  consumption — `BaseAgent.compact_turn_memory/3` reads `context_window/1` to
  decide the `:steering`-boundary compaction trigger.
```

- [ ] **Step 6: Commit**

```bash
git add lib/normandy/agents/base_agent.ex lib/normandy/behaviours/model_catalog.ex test/agents/base_agent_exposure_test.exs
git commit -m "feat: wire production compact handler into BaseAgent turn drivers"
```

---

### Task 6: FSM core — real `:steering` state + `:maybe_compact` / `:compaction_done`

**Files:**
- Modify: `lib/normandy/agents/turn.ex`
- Test: `test/agents/turn_test.exs`, `test/agents/turn_approval_test.exs`, `test/agents/turn_property_test.exs`, `test/agents/turn_compaction_test.exs` (new), `test/agents/turn_driver_test.exs` (un-skip the focused test)

**Interfaces:**
- Consumes: shells from Tasks 4–5 (they now interpret `:maybe_compact` and feed `{:compaction_done, meta}`).
- Produces: at the tool-batch boundary the core enters `:steering` and emits `{:maybe_compact, %{iterations_left: n}}` as the last effect; on `{:compaction_done, _meta}` it resolves to `:assistant_streaming` (continue, emitting `:iteration` + `:call_llm`) or, at the cap, sets `awaiting_final` + the forced-final `:call_llm`.

- [ ] **Step 1: Write the failing core tests**

Create `test/agents/turn_compaction_test.exs`:

```elixir
defmodule Normandy.Agents.TurnCompactionTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.State
  alias Normandy.Components.ToolCall
  alias Normandy.Components.ToolResult

  describe "steering boundary" do
    test "a completed tool batch parks in :steering and emits :maybe_compact last" do
      s = %State{
        status: :tool_dispatch,
        iterations_left: 5,
        max_iterations: 5,
        response_model: :rm,
        output_schema: :os,
        pending_calls: [%ToolCall{id: "c1", name: "t", input: %{}}]
      }

      results = [%ToolResult{tool_call_id: "c1", output: "ok", is_error: false}]
      {s2, effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :steering
      assert s2.iterations_left == 4
      assert s2.pending_calls == []
      assert s2.awaiting_final == false

      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:maybe_compact, %{iterations_left: 4}}
             ]
    end

    test "compaction_done below the cap continues with :iteration + next call" do
      s = %State{status: :steering, iterations_left: 4, max_iterations: 5, response_model: :rm, output_schema: :os}
      {s2, effects} = Turn.step(s, {:compaction_done, %{compacted: false}})

      assert s2.status == :assistant_streaming
      assert s2.awaiting_final == false

      assert effects == [
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
    end

    test "compaction_done at the cap issues the forced-final call" do
      s = %State{status: :steering, iterations_left: 0, max_iterations: 5, response_model: :rm, output_schema: :os}
      {s2, effects} = Turn.step(s, {:compaction_done, %{compacted: true}})

      assert s2.status == :assistant_streaming
      assert s2.awaiting_final == true
      assert effects == [{:call_llm, %{response_model: :os, final: true}}]
    end

    test "compaction_done meta is ignored by the pure core (it already mutated acc in the shell)" do
      s = %State{status: :steering, iterations_left: 3, max_iterations: 5, response_model: :rm, output_schema: :os}
      {s_a, eff_a} = Turn.step(s, {:compaction_done, %{compacted: true, tokens_after: 10}})
      {s_b, eff_b} = Turn.step(s, {:compaction_done, %{compacted: false}})
      assert s_a == s_b
      assert eff_a == eff_b
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn_compaction_test.exs`
Expected: FAIL — `{:tool_results, …}` currently returns `:assistant_streaming` (not `:steering`) and there are no `:steering` clauses, so the `{:compaction_done, …}` steps hit the total-function fallback (`:failed`).

- [ ] **Step 3: Implement the core change**

In `lib/normandy/agents/turn.ex`:

a) Replace the body of `apply_tool_results/2` so it enters `:steering` and emits `:maybe_compact` last (it no longer decides continue-vs-final or emits `:iteration`/`:call_llm` — those move to the `:compaction_done` clauses):

```elixir
  # The batch-results transition, shared by the normal `:tool_dispatch` path and
  # the approval-resume paths. Appends each result, decrements the iteration
  # counter exactly once per batch, emits the steering boundary event, then parks
  # in `:steering` and asks the shell to (maybe) compact before the next LLM call.
  # The continue-vs-forced-final decision is deferred to the `:compaction_done`
  # clauses below. Always clears the per-batch scratch fields (`pending_calls`,
  # `parked_calls`, `held_results`); on the normal path the latter two are empty.
  defp apply_tool_results(%State{} = s, results) do
    new_left = s.iterations_left - 1
    append_effects = Enum.map(results, fn r -> {:append_message, "tool", r} end)
    steering = {:emit_event, :steering, %{iterations_left: new_left}}

    s2 = %{
      s
      | status: :steering,
        iterations_left: new_left,
        pending_calls: [],
        parked_calls: [],
        held_results: []
    }

    {s2, append_effects ++ [steering, {:maybe_compact, %{iterations_left: new_left}}]}
  end
```

b) Add the two `:steering` resolution clauses. Place them immediately after the `apply_tool_results`-driven clauses — concretely, right after the `step(%State{status: :tool_dispatch} = s, {:tool_results, results})` clause (around line 149) and before the `:needs_approval` clause, OR grouped with the other `step/2` heads. They must come before the total-function fallback:

```elixir
  # Compaction (or its no-op) finished. Resolve the steering boundary. At/after
  # the iteration cap, issue the forced-final call (skipping convert, like the old
  # path); otherwise emit the next :iteration and continue. iterations_left was
  # already decremented in apply_tool_results.
  def step(%State{status: :steering, iterations_left: left} = s, {:compaction_done, _meta})
      when left <= 0 do
    {%{s | status: :assistant_streaming, awaiting_final: true},
     [{:call_llm, %{response_model: s.output_schema, final: true}}]}
  end

  def step(%State{status: :steering} = s, {:compaction_done, _meta}) do
    iteration =
      {:emit_event, :iteration,
       %{iteration: s.max_iterations - s.iterations_left + 1, iterations_left: s.iterations_left}}

    {%{s | status: :assistant_streaming},
     [iteration, {:call_llm, %{response_model: s.response_model, final: false}}]}
  end
```

c) Update the moduledoc `## States` paragraph:

```elixir
  Seven statuses are defined. `:awaiting_approval` (suspend/resume for human
  approval) is entered when a dispatched batch parks calls. `:steering` is a
  resting state entered at every tool-batch boundary: the core emits a
  `{:maybe_compact, info}` effect there and resumes on `{:compaction_done, _}`,
  which is where context-window compaction (Phase 5) runs in the shell.
```

- [ ] **Step 4: Run the new core tests to verify they pass**

Run: `mix format && mix test test/agents/turn_compaction_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Update the existing core tests that assert the steering boundary**

The boundary is now two steps. Update each affected assertion to step through `:steering` then `{:compaction_done, %{}}`.

In `test/agents/turn_test.exs`, the `"tool_dispatch results that continue"` test (currently asserting status `:assistant_streaming` + the full `[append, append, steering, iteration, call_llm]` list) becomes:

```elixir
      {s2, effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :steering
      assert s2.iterations_left == 4
      assert s2.pending_calls == []
      assert s2.awaiting_final == false

      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:append_message, "tool", Enum.at(results, 1)},
               {:emit_event, :steering, %{iterations_left: 4}},
               {:maybe_compact, %{iterations_left: 4}}
             ]

      {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

      assert s3.status == :assistant_streaming

      assert effects2 == [
               {:emit_event, :iteration, %{iteration: 2, iterations_left: 4}},
               {:call_llm, %{response_model: :rm, final: false}}
             ]
```

And the `"tool_dispatch results that exhaust the cap"` test becomes:

```elixir
      {s2, effects} = Turn.step(s, {:tool_results, results})

      assert s2.status == :steering
      assert s2.awaiting_final == false
      assert s2.iterations_left == 0

      assert effects == [
               {:append_message, "tool", Enum.at(results, 0)},
               {:emit_event, :steering, %{iterations_left: 0}},
               {:maybe_compact, %{iterations_left: 0}}
             ]

      {s3, effects2} = Turn.step(s2, {:compaction_done, %{}})

      assert s3.status == :assistant_streaming
      assert s3.awaiting_final == true

      assert effects2 == [{:call_llm, %{response_model: :os, final: true}}]
```

In `test/agents/turn_approval_test.exs`, apply the same two-step split to three tests:

- `"all rejected → applies held + denial results in batch order, decrements once"` (~line 64): the `{:approval, %{"p1" => :reject}}` step now yields `s2.status == :steering` and effects ending `…, {:emit_event, :steering, %{iterations_left: 4}}, {:maybe_compact, %{iterations_left: 4}}`; add a follow-up `{:compaction_done, %{}}` step asserting `:assistant_streaming` + `[{:emit_event, :iteration, %{iteration: 2, iterations_left: 4}}, {:call_llm, %{response_model: :rm, final: false}}]`. Keep the existing `s2.parked_calls == []` / `s2.held_results == []` assertions (still true after the approval step).
- `"merges held + approved results in batch order and applies once"` (~line 133): the `{:approved_results, …}` step now yields `:steering` + effects ending in `{:maybe_compact, %{iterations_left: 4}}`; add the `{:compaction_done, %{}}` follow-up asserting `:assistant_streaming` + `[iteration, call_llm]`.
- `"at the iteration cap, the resolved batch issues the forced-final call"` (~line 165): the `{:approved_results, …}` step now yields `:steering`, `iterations_left == 0`, effects ending `{:maybe_compact, %{iterations_left: 0}}`; add the `{:compaction_done, %{}}` follow-up asserting `:assistant_streaming`, `awaiting_final == true`, `[{:call_llm, %{response_model: :os, final: true}}]`.

The `"absent decision is treated as rejected"`, `"some approved → stays :awaiting_approval"`, and `"a retried :approval … fails"` tests are **unchanged** (they do not reach the batch boundary).

In `test/agents/turn_property_test.exs`:

- Add `{:compaction_done, %{}}` to `event_gen/0`'s `one_of` list:

```elixir
      constant({:approved_results, [%ToolResult{tool_call_id: "p", output: "o", is_error: false}]}),
      constant({:compaction_done, %{}}),
      constant({:bogus_event, 1})
```

- Teach the `drive/4` helper to walk through `:steering` by adding a `next_event` clause (after the `:tool_dispatch` clause):

```elixir
  defp next_event(%State{status: :steering}, _tr, _res), do: {:compaction_done, %{}}
```

The `:call_llm`-counting property still holds: the next call is now emitted from the `{:compaction_done, …}` step, still counted by `Enum.count(effects, &match?({:call_llm, _}, &1))`.

- [ ] **Step 6: Un-skip the Task 4 driver compaction test**

In `test/agents/turn_driver_test.exs`, remove the `@tag :pending_phase5_core` from the `"drive/3 runs the compact handler at the steering boundary"` test added in Task 4.

- [ ] **Step 7: Run the full suite**

Run: `mix format && mix test`
Expected: PASS — entire suite green (no `--exclude` needed now). Pay attention to `test/agents/turn_inline_test.exs` and `test/agents/base_agent_turn_driver_test.exs`: their tool-loop turns now route through `:steering`, but the Inline default `:compact` dep and the production `NoOp` compactor make this transparent (same emitted events, same memory). If any asserts an exact effect/event sequence that changed, update it to include the now-entered `:steering` round-trip (the emitted `:iteration`/`:steering` events are unchanged; only the intermediate state differs).

- [ ] **Step 8: Commit**

```bash
git add lib/normandy/agents/turn.ex test/agents/turn_test.exs test/agents/turn_approval_test.exs test/agents/turn_property_test.exs test/agents/turn_compaction_test.exs test/agents/turn_driver_test.exs
git commit -m "feat: enter real :steering state with maybe_compact/compaction_done in Turn core"
```

---

### Task 7: End-to-end compaction integration test

**Files:**
- Create: `test/integration/compaction_turn_test.exs`

**Interfaces:**
- Consumes: the full Phase 5 stack — opt-in `Compactor.WindowManager` via `Behaviours.Config`, the `:steering` core, and `BaseAgent.compact_turn_memory/3`.
- Produces: proof that (a) the default `NoOp` compactor leaves memory untouched across a turn (back-compat), and (b) an opt-in `WindowManager` compactor with a tiny window truncates memory at the steering boundary.

- [ ] **Step 1: Write the failing test**

Create `test/integration/compaction_turn_test.exs`. This drives `BaseAgent.compact_turn_memory/3` directly with a realistic `%BaseAgentConfig{}` for the two configs (the unit-level path the core exercises), avoiding live LLM calls:

```elixir
defmodule Normandy.Integration.CompactionTurnTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgentConfig
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.Compactor
  alias Normandy.Behaviours.Config
  alias Normandy.Components.AgentMemory

  defp big_memory do
    Enum.reduce(1..60, AgentMemory.new_memory(nil), fn i, m ->
      AgentMemory.add_message(m, "user", "padded conversation message number #{i} text")
    end)
  end

  test "default (NoOp) compactor leaves memory untouched at the steering boundary" do
    config = %BaseAgentConfig{
      model: "claude-3-5-sonnet-20241022",
      memory: big_memory(),
      behaviours: %Config{}
    }

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3})

    assert meta.compacted == false
    assert AgentMemory.history(config2.memory) == AgentMemory.history(config.memory)
  end

  test "opt-in WindowManager compactor with a tiny window truncates at the boundary" do
    config = %BaseAgentConfig{
      model: "claude-3-5-sonnet-20241022",
      memory: big_memory(),
      behaviours: %Config{
        compactor: {Compactor.WindowManager, [max_tokens: 80, reserved_tokens: 16]}
      }
    }

    {config2, meta} =
      BaseAgent.compact_turn_memory(config, %Turn.State{}, %{iterations_left: 3})

    assert meta.compacted == true
    assert meta.tokens_after < meta.tokens_before

    assert length(AgentMemory.history(config2.memory)) <
             length(AgentMemory.history(config.memory))
  end
end
```

- [ ] **Step 2: Run to verify it fails (then passes)**

Run: `mix test test/integration/compaction_turn_test.exs`
Expected: PASS if Tasks 1–6 are complete (this is a confirmation/regression test for the assembled stack). If it FAILS, the failure pinpoints which wiring is wrong (NoOp resolution, opt-in opts threading, or window lookup) — fix per the failure, do not weaken the assertions.

- [ ] **Step 3: Run the full suite + commit**

Run: `mix format && mix test`
Expected: PASS (entire suite).

```bash
git add test/integration/compaction_turn_test.exs
git commit -m "test: end-to-end compaction at the steering boundary (NoOp vs opt-in)"
```

---

## Self-Review (run against the design doc)

**1. Spec coverage** — design #4 "Compaction":
- "`Normandy.Behaviours.Compactor` wraps the existing `WindowManager` strategies" → Tasks 1–2 ✅
- "The FSM invokes it at the `:steering` turn boundary" → Task 6 (`apply_tool_results` enters `:steering`, emits `:maybe_compact`) ✅
- "when `TokenCounter` exceeds `ModelCatalog.context_window(model)`" → Task 5 (`context_window_for/1` via configured catalog) + Task 2 (WindowManager estimate vs window gate inside `ensure_within_limit`). **Note:** the trigger uses `WindowManager.estimate_conversation_tokens/1` (free, char-based) rather than the live `TokenCounter` API, to avoid a token-counting API round-trip on every tool batch. The design names "TokenCounter" as the conceptual token source; the cheap estimate is the faithful, cost-safe wiring (and `TokenCounter` remains available for callers who want exactness). Flagged for Q's confirmation below. ✅ (with note)
- "Emits a compaction event" → Task 5 (`log_lifecycle(:debug, "normandy agent compaction", …)` when `meta.compacted`) ✅
- "wires up code that exists today but is never called by the turn loop" → Tasks 5–6 connect `WindowManager`/`Summarizer` to the loop ✅
- Default-off principle → `Compactor.NoOp` default in Config (Task 3) ✅

**2. Placeholder scan** — every code step shows complete code. One implementer-judgment note remains in Task 4 Step 1 (mid-turn `drive/3` entry) with an explicit fallback instruction; this is a test-ergonomics choice, not a missing implementation.

**3. Type consistency** — `maybe_compact/3` signature `(acc, ctx, opts) -> {acc, map()}` is identical in the behaviour (Task 1), both impls (Tasks 1–2), the `Driver.Handlers.compact` type (Task 4), and `compact_turn_memory/3` (Task 5). The effect name `{:maybe_compact, %{iterations_left: n}}` and event `{:compaction_done, meta}` match across core (Task 6), Driver/Inline (Task 4). `ctx` keys `:model`/`:window` match between `context_window_for/1` (Task 5) and `build_manager/2` (Task 2).

---

## Open decision for Q (confirm before/at execution)

1. **Default compactor = `NoOp`.** Chosen to honor the design's "default-off principle" (everything-off path observably identical to today) and to match the `BudgetTracker.NoOp` / `PolicyEngine.AllowAll` precedent. The WindowManager-backed compactor is opt-in. If you instead want compaction *on by default* (e.g. `{Compactor.WindowManager, []}` so long conversations self-trim out of the box), say so — it's a one-line change in `config.ex` (Task 3) plus adjusted Task 7 expectations.
2. **Trigger token source = `WindowManager.estimate_*` (char heuristic), not the live `TokenCounter` API.** Avoids an API call per tool batch. If you want exact API counts at the boundary (accepting the latency/cost), the trigger moves into `compact_turn_memory/3` calling `TokenCounter.count_conversation/2` and short-circuiting before invoking the compactor.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-17-phase-5-compaction-wiring.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

Which approach?
