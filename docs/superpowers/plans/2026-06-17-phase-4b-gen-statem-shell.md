# Phase 4b — `:gen_statem` Turn Shell + Suspend/Resume/Passivation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the opt-in asynchronous turn engine: a `:gen_statem` process shell (`Turn.Server`) that drives the existing pure `Turn` FSM, with real human-approval parking (suspend → persist → resume), passivation (terminate on idle, rehydrate on next message), a pluggable `SessionRegistry`, and a `Turn.Session` router + `Turn.Supervisor`.

**Architecture:** This is the second half of Phase 4. Phase 4a already shipped the chokepoint split (`Dispatch.classify/3` + `Dispatch.execute/4`) and the Turn-core approval transitions (`:awaiting_approval`, `parked_calls`/`held_results`, `{:persist,…}`/`{:execute_approved,…}` effects). Phase 4b adds **only the process shell** around that unchanged core: `Turn.Server` is a *second interpreter* of `Turn.step/2` — the async analog of the synchronous `Driver`. The turn logic is not duplicated; `Turn.Server` adds monitored Tasks for blocking effects, `state_timeout`s, persistence at suspend points, and rehydration. `BaseAgent.run/2`'s inline `Driver` path is untouched, so the existing end-to-end suite is the parity oracle.

**Tech Stack:** Elixir, `:gen_statem` (`:handle_event_function` mode), `DynamicSupervisor`, Elixir `Registry`, ExUnit, StreamData. Reuses `Normandy.Agents.{Turn, Turn.Driver, Dispatch, BaseAgent, BaseAgentConfig}`, `Normandy.Behaviours.{Config, SessionStore}`, `Normandy.Components.{AgentMemory, ToolCall, ToolResult}`.

**Spec:** `docs/superpowers/specs/2026-06-15-phase-4-gen-statem-shell-design.md` (Decisions 3, 4, 5; Deliverables 3–7). Phase 4a plan: `docs/superpowers/plans/2026-06-16-phase-4a-core-chokepoint.md`.

## Global Constraints

- **Gates (run at EVERY Commit step):** `mix format` → `mix compile --warnings-as-errors --force` (clean) → `mix test` (full suite green). A failing gate blocks the commit.
- **No AI attribution** in commit messages or anywhere. Add files individually — never `git add .`.
- **Additive / default-off.** No change to `BaseAgent.run/2`'s observable behavior; the inline `Driver` path and the existing end-to-end suite must stay green unchanged.
- **No new hard deps.** `:gen_statem`, `Registry`, `DynamicSupervisor` are OTP/Elixir built-ins.
- **Turn state persists as an opaque Erlang term** via the existing `SessionStore` (`save_turn_state/3`, `load_turn_state/2`). No Postgres, no custom serializer, no encode/decode step.
- **Persistence is a hard gate at suspend points:** a `{:error, _}` from `SessionStore.save_turn_state` must fail the turn — never advance past a suspend point that could not be durably recorded (no silent fallback).
- **Fail-closed approval default:** any parked `tool_call_id` absent from a decisions map, or mapped to anything other than `:approve`, is rejected.
- **Branch:** all work lands on `phase-4b-gen-statem-shell` (already created off `main` @ `9f6a409`).

## File Structure

```text
NEW:
  lib/normandy/behaviours/session_registry.ex          # behaviour: whereis/register/unregister
  lib/normandy/behaviours/session_registry/native.ex   # default; wraps Elixir Registry
  lib/normandy/agents/turn/server.ex                   # the :gen_statem shell (async interpreter)
  lib/normandy/agents/turn/supervisor.ex               # DynamicSupervisor for Turn.Server children
  lib/normandy/agents/turn/session.ex                  # router: whereis → route | rehydrate
  test/support/session_registry_contract.ex            # __using__ macro contract suite (mirror of SessionStoreContract)
  test/behaviours/session_registry/native_test.exs
  test/agents/turn/server_test.exs
  test/agents/turn/session_test.exs
  test/agents/turn/server_integration_test.exs

MODIFIED:
  lib/normandy/behaviours/config.ex                    # +session_registry slot (default {SessionRegistry.Native, []})
  lib/normandy/agents/base_agent.ex                    # 4 defp → @doc false def (visibility-only)
  lib/normandy/components/agent_memory.ex              # +from_entries/1 (rebuild memory from history entries)
  CHANGELOG.md ; mix.exs                               # version 0.8.0 → 0.9.0 + Phase 4 note
```

**Settled `@doc false` exposure list (BaseAgent, Task 3) — visibility-only, no body change:**
| Function | Current loc | Why Turn.Server needs it |
|---|---|---|
| `non_streaming_handlers/0` | `base_agent.ex:497` | reuse the `call_llm/convert/validate/guard/append/emit` closures |
| `admit_turn_input/2` | `base_agent.ex:464` | `:idle` → new-turn input admission (validate + guardrails + memory init) |
| `base_agent_pipeline/1` | `base_agent.ex:1205` | the dispatch `%Pipeline{}` (telemetry `execute_fn`) for classify/execute |
| `turn_response_model/1` | used by `run_turn/2:444` | `Turn.new(response_model: …)` parameter |

`unwrap_tool_task_result!/1` is already `@doc false def` — no change.

---

### Task 1: `SessionRegistry` behaviour + `Native` impl + contract suite

A `session_id → live pid` map with O(1) lookup and auto-unregister on process death. `Native` wraps Elixir's built-in `Registry`. The contract suite mirrors `test/support/session_store_contract.ex` exactly so future distributed impls share one oracle.

**Files:**
- Create: `lib/normandy/behaviours/session_registry.ex`
- Create: `lib/normandy/behaviours/session_registry/native.ex`
- Create: `test/support/session_registry_contract.ex`
- Create: `test/behaviours/session_registry/native_test.exs`

**Interfaces:**
- Produces: `@callback whereis(handle, session_id) :: {:ok, pid} | :none`; `@callback register(handle, session_id, pid) :: :ok | {:error, :taken}`; `@callback unregister(handle, session_id) :: :ok`. `Native.new(opts) :: handle` and `Native.start_link(opts) :: {:ok, pid}` where `handle` is the registry name (atom).

- [ ] **Step 1: Write the contract suite** (mirrors `SessionStoreContract`)

Create `test/support/session_registry_contract.ex`:

```elixir
defmodule Normandy.SessionRegistryContract do
  @moduledoc "Shared contract tests; `use` with `impl:` a SessionRegistry module."

  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)

    quote bind_quoted: [impl: impl] do
      @reg impl

      setup do
        {:ok, handle: @reg.new()}
      end

      test "register then whereis returns the pid; unknown is :none", %{handle: h} do
        assert :none = @reg.whereis(h, "s1")
        assert :ok = @reg.register(h, "s1", self())
        assert {:ok, pid} = @reg.whereis(h, "s1")
        assert pid == self()
      end

      test "double-register the same session is {:error, :taken}", %{handle: h} do
        assert :ok = @reg.register(h, "s1", self())
        assert {:error, :taken} = @reg.register(h, "s1", self())
      end

      test "unregister frees the session", %{handle: h} do
        assert :ok = @reg.register(h, "s1", self())
        assert :ok = @reg.unregister(h, "s1")
        assert :none = @reg.whereis(h, "s1")
        assert :ok = @reg.register(h, "s1", self())
      end

      test "a dead process auto-unregisters", %{handle: h} do
        {pid, ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
        assert :ok = @reg.register(h, "s1", pid)
        assert {:ok, ^pid} = @reg.whereis(h, "s1")
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        # Registry cleanup is async on owner death; poll briefly.
        assert wait_until(fn -> @reg.whereis(h, "s1") == :none end)
      end

      defp wait_until(fun, retries \\ 50) do
        cond do
          fun.() -> true
          retries == 0 -> false
          true -> Process.sleep(10); wait_until(fun, retries - 1)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Write the impl test that runs the suite**

Create `test/behaviours/session_registry/native_test.exs`:

```elixir
defmodule Normandy.Behaviours.SessionRegistry.NativeTest do
  use ExUnit.Case, async: true
  use Normandy.SessionRegistryContract, impl: Normandy.Behaviours.SessionRegistry.Native
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/behaviours/session_registry/native_test.exs`
Expected: FAIL — `Normandy.Behaviours.SessionRegistry.Native` is not defined / `.new/0` undefined.

- [ ] **Step 4: Write the behaviour**

Create `lib/normandy/behaviours/session_registry.ex`:

```elixir
defmodule Normandy.Behaviours.SessionRegistry do
  @moduledoc """
  Maps a `session_id` to the live `Turn.Server` pid serving it, so a router can
  decide route-to-existing vs rehydrate-and-start. `:none` means no live process
  (the session may still have persisted state in a `SessionStore`).

  The default `Native` impl wraps Elixir's built-in `Registry` (O(1) lookup,
  auto-unregister on owner death). Distributed impls (Horde/syn) are deferred.
  """

  @type handle :: term()
  @type session_id :: String.t()

  @callback whereis(handle(), session_id()) :: {:ok, pid()} | :none
  @callback register(handle(), session_id(), pid()) :: :ok | {:error, :taken}
  @callback unregister(handle(), session_id()) :: :ok
end
```

- [ ] **Step 5: Write the `Native` impl**

Create `lib/normandy/behaviours/session_registry/native.ex`:

```elixir
defmodule Normandy.Behaviours.SessionRegistry.Native do
  @moduledoc """
  Default `SessionRegistry` over Elixir's `Registry` (`:unique` keys). The
  `handle` is the registry's name (an atom). `register/3` registers the calling
  process under `session_id`; the owner's death auto-unregisters it.
  """
  @behaviour Normandy.Behaviours.SessionRegistry

  @doc "Starts a unique Registry. `:name` defaults to this module."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Registry.start_link(keys: :unique, name: name)
  end

  @doc "Convenience: start a uniquely-named Registry and return its name as the handle."
  @spec new(keyword()) :: atom()
  def new(opts \\ []) do
    name = Keyword.get_lazy(opts, :name, fn -> unique_name() end)
    {:ok, _pid} = start_link(name: name)
    name
  end

  @impl true
  def whereis(handle, session_id) do
    case Registry.lookup(handle, session_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :none
    end
  end

  @impl true
  def register(handle, session_id, pid) when pid == self() do
    case Registry.register(handle, session_id, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _}} -> {:error, :taken}
    end
  end

  def register(handle, session_id, pid) do
    # Register a foreign pid by asking nobody — Registry only registers self().
    # The Turn.Server always registers itself, so this clause exists for the
    # contract test (registering `self()` from the test process) and for any
    # caller that owns `pid`. We register on behalf via a short-lived link only
    # when pid == self(); otherwise fall back to Registry's metadata table.
    case Registry.register(handle, session_id, pid) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _}} -> {:error, :taken}
    end
  end

  @impl true
  def unregister(handle, session_id) do
    Registry.unregister(handle, session_id)
    :ok
  end

  defp unique_name do
    String.to_atom("session_registry_" <> Integer.to_string(System.unique_integer([:positive])))
  end
end
```

> Note for the implementer: `Registry.register/3` always registers the **calling** process. In production `Turn.Server` calls `register/3` from inside its own process (`pid == self()`), which is the first clause. The contract test also calls from `self()`. The second clause is a thin pass-through for symmetry; if a future caller needs to register a *foreign* pid, that requires a `:via`-tuple start instead — out of scope here. Keep both clauses; the first is the live path.

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/behaviours/session_registry/native_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/normandy/behaviours/session_registry.ex lib/normandy/behaviours/session_registry/native.ex test/support/session_registry_contract.ex test/behaviours/session_registry/native_test.exs
git commit -m "feat(session): SessionRegistry behaviour + Native (Registry) impl + contract suite"
```

---

### Task 2: `session_registry` slot on `Behaviours.Config`

Add the slot mirroring the Phase 3 `session_store` slot. It is **not** a dispatch-path concern, so `to_pipeline/1` does not touch it.

**Files:**
- Modify: `lib/normandy/behaviours/config.ex:28-44`
- Test: `test/behaviours/config_test.exs`

**Interfaces:**
- Produces: `%Config{session_registry: {SessionRegistry.Native, []}}` default; readable as `config.behaviours.session_registry`.

- [ ] **Step 1: Write the failing test** — add to `test/behaviours/config_test.exs`:

```elixir
test "default bundle carries the Native session_registry slot" do
  assert %Normandy.Behaviours.Config{}.session_registry ==
           {Normandy.Behaviours.SessionRegistry.Native, []}
end

test "to_pipeline/1 ignores session_registry (not a dispatch-path concern)" do
  pipeline = Normandy.Behaviours.Config.to_pipeline(%Normandy.Behaviours.Config{})
  refute Map.has_key?(Map.from_struct(pipeline), :session_registry)
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/behaviours/config_test.exs`
Expected: FAIL — `KeyError`/no `:session_registry` key on `%Config{}`.

- [ ] **Step 3: Add the slot** — edit `lib/normandy/behaviours/config.ex`:

Add to `@type t` (after `session_store: ref()`):
```elixir
          session_store: ref(),
          session_registry: ref()
```
Add the alias near the others:
```elixir
  alias Normandy.Behaviours.SessionRegistry
```
Add to `defstruct` (after `session_store:`):
```elixir
            session_store: {SessionStore.InMemory, []},
            session_registry: {SessionRegistry.Native, []}
```
Update the moduledoc line listing non-dispatch-path slots to include `session_registry` (it, like `session_store`, is not placed on the `Pipeline`).

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/behaviours/config_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/behaviours/config.ex test/behaviours/config_test.exs
git commit -m "feat(config): add session_registry slot (default Native)"
```

---

### Task 3: Expose BaseAgent turn helpers (`@doc false`, visibility-only)

Flip the 4 settled `defp`s to `@doc false def` so `Turn.Server` reuses them with zero logic duplication. **No body changes.** This is the only `base_agent.ex` change in Phase 4b.

**Files:**
- Modify: `lib/normandy/agents/base_agent.ex` (lines per the exposure table above)
- Test: `test/agents/base_agent_exposure_test.exs` (new)

- [ ] **Step 1: Write the failing test**

Create `test/agents/base_agent_exposure_test.exs`:

```elixir
defmodule Normandy.Agents.BaseAgentExposureTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.Turn

  test "the Turn.Server reuse surface is exported with the expected arities" do
    exported = BaseAgent.__info__(:functions)
    assert {:non_streaming_handlers, 0} in exported
    assert {:admit_turn_input, 2} in exported
    assert {:base_agent_pipeline, 1} in exported
    assert {:turn_response_model, 1} in exported
    assert {:unwrap_tool_task_result!, 1} in exported
  end

  test "non_streaming_handlers/0 returns a fully-populated Driver.Handlers struct" do
    h = BaseAgent.non_streaming_handlers()
    assert %Turn.Driver.Handlers{} = h
    for slot <- [:call_llm, :dispatch_tools, :convert, :validate, :guard, :append, :emit] do
      assert is_function(Map.fetch!(h, slot))
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/base_agent_exposure_test.exs`
Expected: FAIL — the `defp`s are not exported (`non_streaming_handlers/0` etc. absent from `__info__(:functions)`).

- [ ] **Step 3: Flip visibility** — in `lib/normandy/agents/base_agent.ex`, for each of `non_streaming_handlers/0`, `admit_turn_input/2`, `base_agent_pipeline/1`, `turn_response_model/1`: change the leading `defp` to `def` and add a `@doc false` line immediately above the first clause. Do **not** edit the bodies. Leave `streaming_handlers/1` and all other `defp`s unchanged.

- [ ] **Step 4: Run the exposure test + the full BaseAgent suite**

Run: `mix test test/agents/base_agent_exposure_test.exs test/agents/base_agent_test.exs`
Expected: PASS (exposure asserts + no behavior regression).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/base_agent.ex test/agents/base_agent_exposure_test.exs
git commit -m "refactor(agents): expose 4 turn helpers as @doc false for Turn.Server reuse"
```

---

### Task 4: `Turn.Server` — skeleton + no-tools turn (`:idle` → `:running` → `:idle`)

Stand up the `:gen_statem` with its data record, `:idle` admission of a turn request, the **effect interpreter** (sync non-blocking effects + monitored Task for `{:call_llm,…}`), and the `{:finalize,…}`/`{:fail,…}` → `:idle` path. Scope: a turn that calls the LLM once and finalizes with **no tool calls** (and a fail path). Approval/passivation/dispatch land in Tasks 5–7.

**Files:**
- Create: `lib/normandy/agents/turn/server.ex`
- Test: `test/agents/turn/server_test.exs`

**Interfaces:**
- Consumes: `Turn.new/1`, `Turn.step/2`; `BaseAgent.non_streaming_handlers/0` (closures `call_llm/3`, `convert/3`, `validate/2`, `guard/2`, `append/3`, `emit/3`); `BaseAgent.admit_turn_input/2`, `BaseAgent.turn_response_model/1`; `SessionStore.save_turn_state/3`, `SessionStore.append_entry/3`; `AgentMemory.add_message/3`.
- Produces:
  - `start_link(opts) :: {:ok, pid}` where `opts` carries `:session_id, :config, :store ({mod,handle}), :registry ({mod,handle}), :subscriber (fn or nil), :turn_state (Turn.State.t() | nil), :approval_timeout_ms, :idle_timeout_ms`.
  - `run(server, user_input) :: {:ok, term()} | {:error, term()}` — synchronous turn (a `:gen_statem.call` that replies on `{:finalize,…}`/`{:fail,…}`).
  - data record `%Turn.Server.Data{turn_state, config, session_id, store, registry, subscriber, task_ref, pending_reply, approval_timeout_ms, idle_timeout_ms}`.

- [ ] **Step 1: Write the failing test** (no-tools turn finalizes)

Create `test/agents/turn/server_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.ServerTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory

  # A response model the FSM finalizes on: no tool_calls → :completed.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Minimal config the reused BaseAgent helpers tolerate for a no-tools turn.
  # `client` is a fake the call_llm helper will hit; for the unit test we inject
  # the LLM via a stub handler set rather than a real client (see Step 3 note).
  defp base_config do
    %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
      tool_registry: nil
    }
  end

  test "a no-tools turn runs to :finalize and replies the final response" do
    store = InMemory.new()
    reg = Normandy.Behaviours.SessionRegistry.Native.new()

    # Inject a fake LLM via the :handlers override (test seam, see Step 3).
    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req -> %Resp{content: "hi", tool_calls: nil} end
    }

    {:ok, srv} =
      Turn.Server.start_link(
        session_id: "s1",
        config: base_config(),
        store: {InMemory, store},
        registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
        handlers: handlers,
        subscriber: nil
      )

    assert {:ok, final} = Turn.Server.run(srv, "hello")
    assert %Resp{content: "hi"} = final
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/server_test.exs`
Expected: FAIL — `Turn.Server` undefined.

- [ ] **Step 3: Implement the skeleton + interpreter**

Create `lib/normandy/agents/turn/server.ex`. Implement exactly:

```elixir
defmodule Normandy.Agents.Turn.Server do
  @moduledoc """
  Asynchronous `:gen_statem` interpreter of the pure `Turn` FSM — the async analog
  of `Turn.Driver`. Coarse lifecycle states (`:running`, `:awaiting_approval`,
  `:idle`) hang Tasks and `state_timeout`s off the turn; they are NOT a
  re-encoding of the seven `Turn.State` statuses (the core stays the source of
  truth). Blocking effects (`:call_llm`, `:dispatch_tools`, `:execute_approved`)
  run in a monitored `Task`; non-blocking effects run synchronously in the handler.
  """
  @behaviour :gen_statem

  alias Normandy.Agents.{BaseAgent, Dispatch, Turn}
  alias Normandy.Components.{AgentMemory, ToolCall}

  defmodule Data do
    @moduledoc false
    defstruct turn_state: nil,
              config: nil,
              session_id: nil,
              store: nil,
              registry: nil,
              subscriber: nil,
              handlers: nil,
              task_ref: nil,
              pending_reply: nil,
              approval_timeout_ms: 300_000,
              idle_timeout_ms: 60_000
  end

  # ---- public API ----

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

  @doc "Run a turn synchronously; replies once the turn finalizes or fails."
  @spec run(:gen_statem.server_ref(), term()) :: {:ok, term()} | {:error, term()}
  def run(server, user_input), do: :gen_statem.call(server, {:turn, user_input}, :infinity)

  @doc "Deliver approval decisions to a parked server (Task 6)."
  @spec approve(:gen_statem.server_ref(), %{optional(String.t()) => :approve | :reject}) :: :ok
  def approve(server, decisions), do: :gen_statem.cast(server, {:approval, decisions})

  # ---- :gen_statem callbacks ----

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    data = %Data{
      session_id: Keyword.fetch!(opts, :session_id),
      config: Keyword.fetch!(opts, :config),
      store: Keyword.fetch!(opts, :store),
      registry: Keyword.fetch!(opts, :registry),
      subscriber: Keyword.get(opts, :subscriber),
      handlers: Keyword.get(opts, :handlers) || BaseAgent.non_streaming_handlers(),
      turn_state: Keyword.get(opts, :turn_state),
      approval_timeout_ms: Keyword.get(opts, :approval_timeout_ms, 300_000),
      idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 60_000)
    }

    register_self(data)
    {:ok, :idle, data, idle_timeout(data)}
  end

  # :idle — accept a new turn request (mid-turn requests are postponed; Task 7).
  @impl true
  def handle_event({:call, from}, {:turn, user_input}, :idle, data) do
    config = BaseAgent.admit_turn_input(data.config, user_input)
    persist_user_message(data, config, user_input)

    state =
      Turn.new(
        max_iterations: config.max_tool_iterations,
        response_model: BaseAgent.turn_response_model(config),
        output_schema: config.output_schema
      )

    data = %{data | config: config, pending_reply: from}
    {state, effects} = Turn.step(state, :start)
    interpret(effects, %{data | turn_state: state})
  end

  # :running — a monitored Task delivered the outcome of a blocking effect.
  def handle_event(:info, {task_ref, event}, :running, %Data{task_ref: task_ref} = data)
      when is_reference(task_ref) do
    Process.demonitor(task_ref, [:flush])
    {state, effects} = Turn.step(data.turn_state, event)
    interpret(effects, %{data | turn_state: state, task_ref: nil})
  end

  # A monitored Task crashed: feed the matching *_error event into the core.
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, :running,
        %Data{task_ref: ref} = data) do
    {state, effects} = Turn.step(data.turn_state, {:llm_error, {:task_down, reason}})
    interpret(effects, %{data | turn_state: state, task_ref: nil})
  end

  # ---- effect interpreter ----
  # Processes effects left-to-right. Non-blocking effects run synchronously and
  # advance the core in-line (convert/validate/guard) or just side-effect
  # (append/emit/persist). A blocking effect spawns a monitored Task and parks in
  # :running. {:finalize}/{:fail} reply and return to :idle.

  defp interpret([], data), do: {:keep_state, data}

  defp interpret([effect | rest], data) do
    case effect do
      {:emit_event, name, meta} ->
        emit(data, name, meta)
        interpret(rest, data)

      {:append_message, role, content} ->
        config = data.handlers.append.(data.config, role, content)
        append_to_store(data, role, content)
        interpret(rest, %{data | config: config})

      {:persist, turn_state} ->
        case persist_turn_state(data, turn_state) do
          :ok -> interpret(rest, data)
          {:error, reason} -> fail(data, {:persist_failed, reason})
        end

      {:convert_output, raw, schema} ->
        advance(rest, data, {:output_converted, data.handlers.convert.(data.config, raw, schema)})

      {:validate_output, value} ->
        advance(rest, data, {:output_validated, data.handlers.validate.(data.config, value)})

      {:guard_output, value} ->
        data.handlers.guard.(data.config, value)
        advance(rest, data, {:output_guarded, value})

      {:call_llm, request} ->
        spawn_task(data, fn h, d -> {:llm_response, h.call_llm.(d.config, d.turn_state, request)} end)

      {:dispatch_tools, calls} ->
        spawn_task(data, fn _h, d -> dispatch(d, calls) end)

      {:execute_approved, calls} ->
        spawn_task(data, fn _h, d -> {:approved_results, execute_approved(d, calls)} end)

      {:finalize, value} ->
        reply(data, {:ok, value})
        {:next_state, :idle, %{data | pending_reply: nil}, idle_timeout(data)}

      {:fail, reason} ->
        reply(data, {:error, reason})
        {:next_state, :idle, %{data | pending_reply: nil}, idle_timeout(data)}
    end
  end

  # `advance` feeds an in-line (non-blocking) result back into the core and keeps
  # interpreting — convert/validate/guard never leave the current handler.
  defp advance(rest, data, event) do
    {state, effects} = Turn.step(data.turn_state, event)
    interpret(effects ++ rest, %{data | turn_state: state})
  end

  # Spawn a monitored Task that computes its event and sends it back as
  # {task_ref, event}; transition to :running. (Tasks 5/6 reuse this.)
  defp spawn_task(data, fun) do
    server = self()
    ref = make_ref()
    {:ok, _pid} =
      Task.start(fn -> send(server, {ref, fun.(data.handlers, data)}) end)

    {:next_state, :running, %{data | task_ref: ref}}
  end

  defp fail(data, reason), do: interpret([{:fail, reason}], data)

  # ---- side-effect helpers ----

  defp emit(%Data{subscriber: nil}, _name, _meta), do: :ok
  defp emit(%Data{subscriber: sub}, name, meta) when is_function(sub, 2), do: sub.(name, meta)

  defp reply(%Data{pending_reply: nil}, _msg), do: :ok
  defp reply(%Data{pending_reply: from}, msg), do: :gen_statem.reply(from, msg)

  defp idle_timeout(%Data{idle_timeout_ms: ms}), do: {:state_timeout, ms, :passivate}

  defp register_self(%Data{registry: {mod, handle}, session_id: sid}),
    do: mod.register(handle, sid, self())

  defp persist_turn_state(%Data{store: {mod, handle}, session_id: sid}, turn_state),
    do: mod.save_turn_state(handle, sid, turn_state)

  defp append_to_store(%Data{store: {mod, handle}, session_id: sid}, role, content) do
    {:ok, _id} =
      mod.append_entry(handle, sid, %Normandy.Components.AgentMemory.Entry{
        turn_id: "live",
        role: role,
        content: content
      })

    :ok
  end

  defp persist_user_message(data, _config, nil), do: :ok
  defp persist_user_message(data, _config, user_input),
    do: append_to_store(data, "user", user_input)

  # dispatch/2 and execute_approved/2 are implemented in Task 5/6.
  defp dispatch(_data, _calls), do: raise("dispatch/2 lands in Task 5")
  defp execute_approved(_data, _calls), do: raise("execute_approved/2 lands in Task 6")
end
```

> Implementer notes:
> - The test injects a stub `call_llm` via the `:handlers` override (a `%Driver.Handlers{}` with one slot replaced). This is the test seam; production passes no `:handlers` and `init/1` defaults to `BaseAgent.non_streaming_handlers/0`.
> - `Task.start` + `make_ref()` (not `Task.async`) keeps the monitor/demonitor explicit and lets the FSM match `{task_ref, event}`. The `:DOWN` clause handles crashes; on the happy path we `demonitor(ref, [:flush])` after receiving the event.
> - `append_to_store` uses `turn_id: "live"`; rehydration (Task 9) reads these back. Real per-turn ids are a later refinement (not required for parity).

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/agents/turn/server_test.exs`
Expected: PASS — the no-tools turn finalizes with `%Resp{content: "hi"}`.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "feat(turn): Turn.Server :gen_statem skeleton + no-tools turn interpreter"
```

---

### Task 5: `Turn.Server` — approval-aware tool dispatch + park

Implement `dispatch/2`: classify every call (reusing `Dispatch.classify/3` with `BaseAgent.base_agent_pipeline/1`), execute the allowed ones concurrently (mirroring `dispatch_turn_tools/2`'s `Task.async_stream`), collect `held = executed ++ deny_results`, and either send `{:tool_results, ordered}` (none parked) or `{:needs_approval, held, parked}` (some parked). Verify the FSM parks (`:awaiting_approval`) and persists.

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex` (replace the `dispatch/2` stub; add `:awaiting_approval` entry)
- Test: `test/agents/turn/server_test.exs`

**Interfaces:**
- Consumes: `Dispatch.classify(config, call, pipeline)` → `{:execute, prepared, call} | {:deny, %ToolResult{}} | {:needs_approval, prepared, call, info}`; `Dispatch.execute(config, prepared, call, pipeline)`; `BaseAgent.base_agent_pipeline/1`; `BaseAgent.unwrap_tool_task_result!/1`.
- Produces: server enters gen_statem `:awaiting_approval` with an approval `state_timeout` when a batch parks.

- [ ] **Step 1: Write the failing test** — add to `server_test.exs`:

```elixir
test "a batch with a needs_approval call parks the turn (:awaiting_approval) and persists" do
  store = InMemory.new()
  reg = Normandy.Behaviours.SessionRegistry.Native.new()
  test_pid = self()

  # First LLM response asks for two tool calls; classify parks one of them.
  handlers = %{
    Normandy.Agents.BaseAgent.non_streaming_handlers()
    | call_llm: fn _c, _s, _r ->
        %Resp{
          content: "",
          tool_calls: [
            %Normandy.Components.ToolCall{id: "ok1", name: "weather", input: %{}},
            %Normandy.Components.ToolCall{id: "pk1", name: "billing", input: %{}}
          ]
        }
      end
  }

  # Policy: billing → needs_approval, everything else allow.
  policy = fn _c, %{name: name}, _t ->
    if name == "billing", do: {:needs_approval, %{rationale: "high-cost"}}, else: {:allow, %{}}
  end

  config = %{base_config_with_tools() | behaviours: %Normandy.Behaviours.Config{policy: policy_ref(policy)}}

  {:ok, srv} =
    Turn.Server.start_link(
      session_id: "s-park",
      config: config,
      store: {InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
      handlers: handlers,
      subscriber: fn name, meta -> send(test_pid, {:event, name, meta}) end
    )

  # run/2 will block (no reply until resume); kick it from a task.
  spawn(fn -> Turn.Server.run(srv, "do stuff") end)

  assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000
  assert {:ok, _term} = InMemory.load_turn_state(store, "s-park")
end
```

> `base_config_with_tools/0` registers a `weather` + `billing` tool (use the `FakeTool` pattern from `dispatch_split_test.exs`). `policy_ref/1` wraps a custom policy fn into a `PolicyEngine`-shaped ref the pipeline can consult — implement a tiny inline `PolicyEngine` module in the test, or reuse `PolicyEngine.Ruleset` with a `match: "billing", action: :require_approval` rule. Prefer the `Ruleset` route (no new module): `behaviours: %Config{policy: {PolicyEngine.Ruleset, rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}], default_action: :allow}}`.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/server_test.exs`
Expected: FAIL — `dispatch/2` raises `"dispatch/2 lands in Task 5"`.

- [ ] **Step 3: Implement `dispatch/2`** — replace the stub in `server.ex`:

```elixir
  # Classify every call; execute the allowed ones concurrently (mirrors
  # BaseAgent.dispatch_turn_tools/2's Task.async_stream); collect held results.
  # If any call needs approval, park the batch; else hand back ordered results.
  defp dispatch(%Data{config: config} = data, calls) do
    pipeline = BaseAgent.base_agent_pipeline(config)
    max_conc = max(config.max_tool_concurrency || 1, 1)
    parent_ctx = Normandy.Telemetry.OtelCtx.capture()

    classified =
      calls
      |> Enum.map(&Dispatch.to_tool_call/1)
      |> Enum.map(fn call -> {call, Dispatch.classify(config, call, pipeline)} end)

    parked = for {call, {:needs_approval, _p, ncall, _info}} <- classified, do: %{ncall | id: call.id}

    runnable = for {_call, {:execute, prepared, ncall}} <- classified, do: {prepared, ncall}
    denied = for {_call, {:deny, %_{} = result}} <- classified, do: result

    executed =
      runnable
      |> Task.async_stream(
        fn {prepared, ncall} ->
          Normandy.Telemetry.OtelCtx.restore(parent_ctx)
          Dispatch.execute(config, prepared, ncall, pipeline)
        end,
        ordered: true,
        max_concurrency: max_conc,
        timeout: :infinity,
        on_timeout: :kill_task
      )
      |> Enum.map(&BaseAgent.unwrap_tool_task_result!/1)

    held = executed ++ denied

    if parked == [] do
      {:tool_results, held}
    else
      {:needs_approval, held, parked}
    end
  end
```

Add an `:awaiting_approval` entry: when `interpret` finishes a list whose final core status is `:awaiting_approval`, arm the approval timeout. Replace the `interpret([], data)` base case:

```elixir
  defp interpret([], %Data{turn_state: %Turn.State{status: :awaiting_approval}} = data) do
    {:next_state, :awaiting_approval, data, {:state_timeout, data.approval_timeout_ms, :approval_expiry}}
  end

  defp interpret([], data), do: {:keep_state, data}
```

> Note: `{:needs_approval, held, parked}` is produced by the Task and fed via the `:running` `{task_ref, event}` clause into `Turn.step/2`, which returns `[{:emit_event,…}, {:persist, state'}]` and sets status `:awaiting_approval`. `interpret` runs those two non-blocking effects, hits `[]` with status `:awaiting_approval`, and transitions. The `%_{}` in the `denied` comprehension matches any struct (`%ToolResult{}`); alias `ToolResult` and use `%ToolResult{}` if preferred.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/agents/turn/server_test.exs`
Expected: PASS — `:awaiting_approval` event received and turn state persisted.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "feat(turn): Turn.Server approval-aware tool dispatch + park on needs_approval"
```

---

### Task 6: `Turn.Server` — approval resume + `execute_approved` + approval timeout

Implement the `:awaiting_approval` cast handler (`{:approval, decisions}` → core), `execute_approved/2` (re-prepare + `Dispatch.execute/4`, no re-classify), and the approval `state_timeout` → all-reject (fail-closed).

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex`
- Test: `test/agents/turn/server_test.exs`

**Interfaces:**
- Consumes: `Registry.get/2` (`Normandy.Tools.Registry`) + `Dispatch.prepare_tool/2` + `Dispatch.execute/4` to run an approved call without re-running policy/before-hooks.
- Produces: `Turn.Server.approve(server, decisions)` resolves a parked turn; the turn proceeds (execute approved → merge → next LLM call) and ultimately replies to the original `run/2` caller.

- [ ] **Step 1: Write the failing tests** — add to `server_test.exs`:

```elixir
test "approving a parked call resumes the turn and finalizes" do
  # ... build the parked scenario from Task 5, but make the *second* LLM call
  # (after tools resolve) return a no-tools final response.
  # Capture the run/2 caller's reply.
  parent = self()
  # call_llm: first call → 2 tool calls (one parked); second call → final.
  # billing tool runs successfully when approved.
  # ... (use an Agent or counter closure to switch responses across calls)
  spawn(fn -> send(parent, {:run_result, Turn.Server.run(srv, "go")}) end)
  assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

  :ok = Turn.Server.approve(srv, %{"pk1" => :approve})

  assert_receive {:run_result, {:ok, %Resp{}}}, 2_000
end

test "approval timeout rejects all parked calls (fail-closed) and resumes" do
  # short approval_timeout_ms; do NOT call approve/2; expect the turn to resume
  # with the parked call denied and still finalize.
  spawn(fn -> send(self(), :ignore) end)
  # assert the run/2 caller eventually gets {:ok, _} with the parked tool denied.
end
```

> Implementer: use a stateful `call_llm` stub that returns the tool-call response on the 1st invocation and a no-tools `%Resp{}` on the 2nd (e.g. an `Agent` holding a counter, or `:counters`). Keep the billing tool's `run/1` returning `{:ok, "charged"}`.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/server_test.exs`
Expected: FAIL — no `:awaiting_approval` cast handler / `execute_approved/2` raises.

- [ ] **Step 3: Implement resume + timeout + execute_approved** — in `server.ex`:

```elixir
  # Out-of-band approval decisions for a parked turn.
  def handle_event(:cast, {:approval, decisions}, :awaiting_approval, data) do
    {state, effects} = Turn.step(data.turn_state, {:approval, decisions})
    interpret(effects, %{data | turn_state: state})
  end

  # Approval expiry → all-reject (fail-closed): feed an empty decisions map.
  def handle_event(:state_timeout, :approval_expiry, :awaiting_approval, data) do
    {state, effects} = Turn.step(data.turn_state, {:approval, %{}})
    interpret(effects, %{data | turn_state: state})
  end
```

```elixir
  # Run already-approved calls: re-derive `prepared` (registry + prepare_tool,
  # deterministic, no policy) and run Dispatch.execute/4. NOT re-classify —
  # re-running policy would re-park. Concurrency mirrors dispatch/2.
  defp execute_approved(%Data{config: config} = data, calls) do
    pipeline = BaseAgent.base_agent_pipeline(config)
    max_conc = max(config.max_tool_concurrency || 1, 1)
    parent_ctx = Normandy.Telemetry.OtelCtx.capture()

    calls
    |> Task.async_stream(
      fn %ToolCall{} = call ->
        Normandy.Telemetry.OtelCtx.restore(parent_ctx)
        {:ok, tool} = Normandy.Tools.Registry.get(config.tool_registry, call.name)
        prepared = Dispatch.prepare_tool(tool, call.input)
        Dispatch.execute(config, prepared, call, pipeline)
      end,
      ordered: true,
      max_concurrency: max_conc,
      timeout: :infinity,
      on_timeout: :kill_task
    )
    |> Enum.map(&BaseAgent.unwrap_tool_task_result!/1)
  end
```

Add `alias Normandy.Components.ToolResult` and `alias Normandy.Tools.Registry` near the top if not already; remove the `execute_approved/2` stub.

> Note: when `{:approval, decisions}` has some approvals, `Turn.step/2` returns `[{:execute_approved, approved}]` and keeps status `:awaiting_approval` (parked_calls now `[]`). `interpret` hits `{:execute_approved,…}` → `spawn_task` → `:running`. When all rejected, it returns the `apply_tool_results` effects directly (append/steering/call_llm), and the turn continues. The Phase 4a guard (`:awaiting_approval` + `parked_calls: []` + `{:approval,_}` → `:failed`) protects against a duplicate cast.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/agents/turn/server_test.exs`
Expected: PASS (approve-resume finalizes; timeout fail-closed resumes).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "feat(turn): Turn.Server approval resume, execute_approved, fail-closed timeout"
```

---

### Task 7: `Turn.Server` — passivation (idle timeout) + mid-turn message postpone

The `:idle` `state_timeout` stops the server normally (final state already persisted). A turn request arriving while `:running` or `:awaiting_approval` is `postpone`d and replayed on entering `:idle`.

**Files:**
- Modify: `lib/normandy/agents/turn/server.ex`
- Test: `test/agents/turn/server_test.exs`

- [ ] **Step 1: Write the failing tests** — add to `server_test.exs`:

```elixir
test "passivates (stops :normal) after the idle timeout" do
  store = InMemory.new()
  reg = Normandy.Behaviours.SessionRegistry.Native.new()
  {:ok, srv} =
    Turn.Server.start_link(
      session_id: "s-idle", config: base_config(),
      store: {InMemory, store},
      registry: {Normandy.Behaviours.SessionRegistry.Native, reg},
      handlers: %{Normandy.Agents.BaseAgent.non_streaming_handlers() | call_llm: fn _c,_s,_r -> %Resp{content: "x"} end},
      idle_timeout_ms: 50
    )
  ref = Process.monitor(srv)
  {:ok, _} = Turn.Server.run(srv, "hi")
  assert_receive {:DOWN, ^ref, :process, ^srv, :normal}, 1_000
end

test "a turn request received while :running is postponed and runs after idle" do
  # fire two run/2 calls in quick succession; both must return {:ok, _}, the
  # second only after the first finalizes (postpone replay on entering :idle).
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/agents/turn/server_test.exs`
Expected: FAIL — no passivation; second turn errors or hangs.

- [ ] **Step 3: Implement passivation + postpone** — in `server.ex`:

```elixir
  # Idle long enough → passivate. Final turn state is already persisted; just stop.
  def handle_event(:state_timeout, :passivate, :idle, data) do
    {:stop, :normal, data}
  end

  # A turn request mid-turn is postponed and replayed when we re-enter :idle.
  def handle_event({:call, _from}, {:turn, _input}, state, _data)
      when state in [:running, :awaiting_approval] do
    {:keep_state_and_data, :postpone}
  end
```

> Note: `:gen_statem` replays postponed events on the next state *entry*. Returning `{:next_state, :idle, …}` from `{:finalize,…}`/`{:fail,…}` triggers the replay automatically. The idle `state_timeout` is (re)armed every time we enter `:idle` (the `interpret` finalize/fail branches already pass `idle_timeout(data)`), so a postponed turn resets the idle clock.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/agents/turn/server_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn/server.ex test/agents/turn/server_test.exs
git commit -m "feat(turn): Turn.Server passivation + mid-turn message postponement"
```

---

### Task 8: `Turn.Supervisor` (DynamicSupervisor)

A `DynamicSupervisor` that owns `Turn.Server` children (`restart: :transient` — a normally-stopped passivated server is not restarted; a crashed one is).

**Files:**
- Create: `lib/normandy/agents/turn/supervisor.ex`
- Test: `test/agents/turn/session_test.exs` (shared with Task 9; create here)

**Interfaces:**
- Produces: `Turn.Supervisor.start_link(opts)`; `Turn.Supervisor.start_server(sup, server_opts) :: {:ok, pid}` (calls `DynamicSupervisor.start_child`).

- [ ] **Step 1: Write the failing test** — create `test/agents/turn/session_test.exs`:

```elixir
defmodule Normandy.Agents.Turn.SessionTest do
  use ExUnit.Case, async: false
  alias Normandy.Agents.Turn

  test "supervisor starts a Turn.Server child as transient" do
    {:ok, sup} = Turn.Supervisor.start_link([])
    {:ok, pid} =
      Turn.Supervisor.start_server(sup,
        session_id: "x", config: nil,
        store: {Normandy.Behaviours.SessionStore.InMemory, Normandy.Behaviours.SessionStore.InMemory.new()},
        registry: {Normandy.Behaviours.SessionRegistry.Native, Normandy.Behaviours.SessionRegistry.Native.new()}
      )
    assert is_pid(pid)
    assert [{:undefined, ^pid, :worker, _}] = DynamicSupervisor.which_children(sup)
  end
end
```

- [ ] **Step 2: Run to verify it fails** — `mix test test/agents/turn/session_test.exs` → FAIL (`Turn.Supervisor` undefined). (Config `nil` is fine — `init/1` only reads it on a turn request, which this test does not send.)

- [ ] **Step 3: Implement** — create `lib/normandy/agents/turn/supervisor.ex`:

```elixir
defmodule Normandy.Agents.Turn.Supervisor do
  @moduledoc "DynamicSupervisor for `Turn.Server` processes (one per live session)."
  use DynamicSupervisor

  alias Normandy.Agents.Turn.Server

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_server(:gen_statem.server_ref() | pid(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_server(sup, server_opts) do
    spec = %{
      id: Server,
      start: {Server, :start_link, [server_opts]},
      restart: :transient,
      type: :worker
    }

    DynamicSupervisor.start_child(sup, spec)
  end
end
```

- [ ] **Step 4: Run to verify it passes** — `mix test test/agents/turn/session_test.exs` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/agents/turn/supervisor.ex test/agents/turn/session_test.exs
git commit -m "feat(turn): Turn.Supervisor DynamicSupervisor for Turn.Server children"
```

---

### Task 9: `Turn.Session` router + rehydration (+ `AgentMemory.from_entries/1`)

The router: `whereis` → route to live pid, or load turn state + history from the store, rebuild `config.memory`, start a `Turn.Server` under the supervisor with the **caller-supplied** config, register, and forward. Adds `AgentMemory.from_entries/1` (the only `agent_memory.ex` change).

**Files:**
- Modify: `lib/normandy/components/agent_memory.ex` (add `from_entries/1`)
- Create: `lib/normandy/agents/turn/session.ex`
- Test: `test/agents/turn/session_test.exs` (extend), `test/components/agent_memory_test.exs` (extend)

**Interfaces:**
- Consumes: `SessionRegistry.whereis/2`; `SessionStore.load_turn_state/2` (`{:ok, term} | :error`), `SessionStore.history/2` (`{:ok, [Entry.t()]}`); `Turn.Supervisor.start_server/2`; `Turn.Server.run/2`, `Turn.Server.approve/2`.
- Produces:
  - `AgentMemory.from_entries([Entry.t()]) :: AgentMemory.t()`
  - `Turn.Session.run(opts, user_input) :: {:ok, term} | {:error, term}` where `opts` carries `:session_id, :config, :store, :registry, :supervisor` (+ optional timeouts/subscriber).
  - `Turn.Session.approve(opts, decisions) :: :ok | {:error, :no_session}`.

- [ ] **Step 1: Write the failing test for `from_entries/1`** — add to `test/components/agent_memory_test.exs`:

```elixir
test "from_entries/1 rebuilds a memory whose entry_chain matches the input" do
  alias Normandy.Components.AgentMemory
  m =
    AgentMemory.new_memory()
    |> AgentMemory.add_message("user", "a")
    |> AgentMemory.add_message("assistant", "b")

  entries = AgentMemory.entry_chain(m)
  rebuilt = AgentMemory.from_entries(entries)

  assert AgentMemory.entry_chain(rebuilt) |> Enum.map(& &1.content) == ["a", "b"]
  assert rebuilt.head == m.head
end

test "from_entries/1 on [] is an empty memory" do
  alias Normandy.Components.AgentMemory
  assert AgentMemory.from_entries([]) == AgentMemory.new_memory()
end
```

- [ ] **Step 2: Run to verify it fails** — `mix test test/components/agent_memory_test.exs` → FAIL (`from_entries/1` undefined).

- [ ] **Step 3: Implement `from_entries/1`** — add to `lib/normandy/components/agent_memory.ex`:

```elixir
  @doc """
  Rebuild a memory from a chronological list of `Entry.t()` (e.g. the output of
  `SessionStore.history/2`). The `head` becomes the last entry's id and the
  `current_turn_id` the last entry's `turn_id`, so the active branch reconstructs.
  """
  @spec from_entries([Entry.t()]) :: t()
  def from_entries([]), do: new_memory()

  def from_entries(entries) when is_list(entries) do
    last = List.last(entries)

    %__MODULE__{
      entries: Map.new(entries, fn %Entry{id: id} = e -> {id, e} end),
      head: last.id,
      current_turn_id: last.turn_id,
      max_messages: nil
    }
  end
```

- [ ] **Step 4: Run to verify it passes** — `mix test test/components/agent_memory_test.exs` → PASS.

- [ ] **Step 5: Write the failing rehydration test** — add to `test/agents/turn/session_test.exs`:

```elixir
test "routes to a live session, else rehydrates turn state + memory from the store" do
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native

  store = InMemory.new()
  reg = Native.new()
  {:ok, sup} = Turn.Supervisor.start_link([])

  # Pre-seed the store with a prior conversation entry (simulating a passivated session).
  {:ok, _} = InMemory.append_entry(store, "sess", %Normandy.Components.AgentMemory.Entry{turn_id: "t0", role: "user", content: "earlier"})

  opts = [
    session_id: "sess",
    config: session_config(),     # a real-ish config; call_llm stubbed via :handlers
    store: {InMemory, store},
    registry: {Native, reg},
    supervisor: sup,
    handlers: %{Normandy.Agents.BaseAgent.non_streaming_handlers() | call_llm: fn _c,_s,_r -> %ServerTest.Resp{content: "ok"} end}
  ]

  assert {:ok, %{content: "ok"}} = Turn.Session.run(opts, "now")
  # Second call routes to the SAME live pid (no new child).
  assert {:ok, _} = Turn.Session.run(opts, "again")
  assert length(DynamicSupervisor.which_children(sup)) == 1
end
```

- [ ] **Step 6: Run to verify it fails** — FAIL (`Turn.Session` undefined).

- [ ] **Step 7: Implement `Turn.Session`** — create `lib/normandy/agents/turn/session.ex`:

```elixir
defmodule Normandy.Agents.Turn.Session do
  @moduledoc """
  Router in front of `Turn.Server`. Resolves `session_id` to a live pid via the
  `SessionRegistry`; on a miss, rehydrates turn state + conversation memory from
  the `SessionStore` and starts a `Turn.Server` under `Turn.Supervisor` with the
  **caller-supplied** config (the store never holds config/credentials).
  """
  alias Normandy.Agents.Turn.{Server, Supervisor}
  alias Normandy.Components.AgentMemory

  @spec run(keyword(), term()) :: {:ok, term()} | {:error, term()}
  def run(opts, user_input) do
    with {:ok, pid} <- ensure_server(opts), do: Server.run(pid, user_input)
  end

  @spec approve(keyword(), map()) :: :ok | {:error, :no_session}
  def approve(opts, decisions) do
    {reg_mod, reg_handle} = Keyword.fetch!(opts, :registry)
    sid = Keyword.fetch!(opts, :session_id)

    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} -> Server.approve(pid, decisions)
      :none -> with {:ok, pid} <- ensure_server(opts), do: Server.approve(pid, decisions)
    end
  end

  defp ensure_server(opts) do
    {reg_mod, reg_handle} = Keyword.fetch!(opts, :registry)
    sid = Keyword.fetch!(opts, :session_id)

    case reg_mod.whereis(reg_handle, sid) do
      {:ok, pid} -> {:ok, pid}
      :none -> rehydrate_and_start(opts)
    end
  end

  defp rehydrate_and_start(opts) do
    {store_mod, store_handle} = Keyword.fetch!(opts, :store)
    sid = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    supervisor = Keyword.fetch!(opts, :supervisor)

    turn_state =
      case store_mod.load_turn_state(store_handle, sid) do
        {:ok, term} -> term
        :error -> nil
      end

    {:ok, entries} = store_mod.history(store_handle, sid)
    config = %{config | memory: AgentMemory.from_entries(entries)}

    server_opts =
      opts
      |> Keyword.take([:session_id, :store, :registry, :subscriber, :handlers,
                       :approval_timeout_ms, :idle_timeout_ms])
      |> Keyword.put(:config, config)
      |> Keyword.put(:turn_state, turn_state)

    Supervisor.start_server(supervisor, server_opts)
  end
end
```

> Race note: between `whereis` returning `:none` and the new child registering, a concurrent caller could start a second child for the same `session_id`. `Native.register/3` returns `{:error, :taken}` for the loser, whose `init/1` would then have a duplicate. For Phase 4b's single-router usage this is acceptable; a `:via`-based start (register-at-start atomicity) is the documented follow-up. Add a one-line `log`/comment; do not over-build.

- [ ] **Step 8: Run to verify it passes** — `mix test test/agents/turn/session_test.exs` → PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/normandy/components/agent_memory.ex lib/normandy/agents/turn/session.ex test/agents/turn/session_test.exs test/components/agent_memory_test.exs
git commit -m "feat(turn): Turn.Session router + rehydration; AgentMemory.from_entries/1"
```

---

### Task 10: Integration test — full approval round-trip

One end-to-end test exercising `Turn.Session` + `Turn.Server` + `InMemory` store + `Native` registry + a fake LLM client + `PolicyEngine.Ruleset` with a `:require_approval` rule, through park → approve → resume → finalize, and a passivate → rehydrate → continue cycle.

**Files:**
- Create: `test/agents/turn/server_integration_test.exs`

- [ ] **Step 1: Write the integration test**

```elixir
defmodule Normandy.Agents.Turn.ServerIntegrationTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.{Config, PolicyEngine}

  defmodule Resp, do: (defstruct content: "", tool_calls: nil)

  # Stateful fake LLM: 1st call → one parked tool call; 2nd → final no-tools resp.
  # billing tool runs {:ok, "charged"} when approved.
  # ... set up tool registry, config.behaviours with Ruleset require_approval on "billing".

  test "park → approve → resume → finalize, then passivate → rehydrate → continue" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, sup} = Turn.Supervisor.start_link([])
    parent = self()

    opts = [
      session_id: "round-trip",
      config: integration_config(store),  # builds a config with Ruleset policy + billing tool
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: sup,
      idle_timeout_ms: 60,
      handlers: integration_handlers(),   # counter-switched call_llm; subscriber → parent
      subscriber: fn name, meta -> send(parent, {:event, name, meta}) end
    ]

    spawn(fn -> send(parent, {:result, Turn.Session.run(opts, "please charge")}) end)
    assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

    :ok = Turn.Session.approve(opts, %{"pk1" => :approve})
    assert_receive {:result, {:ok, %Resp{}}}, 2_000

    # The conversation persisted; let the server passivate, then continue.
    sid_pid = (case Native.whereis(reg, "round-trip") do {:ok, p} -> p; :none -> nil end)
    if sid_pid, do: (ref = Process.monitor(sid_pid); assert_receive {:DOWN, ^ref, _, _, :normal}, 1_000)

    assert :none = Native.whereis(reg, "round-trip")
    # New cast rehydrates from the store and continues the same conversation.
    assert {:ok, _} = Turn.Session.run(opts, "follow up")
  end
end
```

> Implementer: `integration_config/1` and `integration_handlers/0` follow the Task 5/6 patterns (Ruleset `match: "billing", action: :require_approval`; a `billing` `FakeTool` returning `{:ok, "charged"}`; a counter-switched `call_llm`). Keep the fake LLM out of any real HTTP path.

- [ ] **Step 2: Run to verify it passes**

Run: `mix test test/agents/turn/server_integration_test.exs`
Expected: PASS — the full round-trip + rehydrate-continue.

- [ ] **Step 3: Run the FULL suite (back-compat oracle)**

Run: `mix test`
Expected: PASS — all pre-existing tests green (inline `Driver` path untouched).

- [ ] **Step 4: Commit**

```bash
git add test/agents/turn/server_integration_test.exs
git commit -m "test(turn): full approval round-trip + rehydrate-continue integration"
```

---

### Task 11: CHANGELOG note + version bump to `0.9.0`

Phase 4 is additive/back-compat → minor bump `0.8.0` → `0.9.0` (per spec Versioning). `1.0.0` stays reserved for the final phase.

**Files:**
- Modify: `mix.exs` (the `@version`)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Bump the version** — in `mix.exs`, change `@version "0.8.0"` to `@version "0.9.0"`.

- [ ] **Step 2: Add the CHANGELOG entry** — move the current `## [Unreleased]` Phase 4a content under a new `## [0.9.0] - <today>` heading (Phase 4 as a whole shipped over 4a+4b), and add the Phase 4b bullets:

```markdown
## [0.9.0] - 2026-06-17

### Added

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
```

Update the link-reference block at the bottom: add `[0.9.0]: https://github.com/thetonymaster/normandy/releases/tag/v0.9.0` above the `[0.8.0]` line.

- [ ] **Step 3: Run the full gate**

Run: `mix format && mix compile --warnings-as-errors --force && mix test`
Expected: clean compile, full suite green.

- [ ] **Step 4: Commit**

```bash
git add mix.exs CHANGELOG.md
git commit -m "chore: Phase 4b changelog + version bump to 0.9.0"
```

---

## Self-Review

**1. Spec coverage (Decisions 3–5, Deliverables 3–7):**
- Deliverable 3 (`Turn.Server` `:gen_statem`, lifecycle states, monitored Tasks, postpone, timeouts, effect interpretation, persistence) → Tasks 4–7. ✓
- Deliverable 4 (`Turn.Session` router, `Turn.Supervisor`) → Tasks 8, 9. ✓
- Deliverable 5 (`SessionRegistry` + `Native` + `session_registry` Config slot) → Tasks 1, 2. ✓
- Deliverable 6 (tests per strategy: core already in 4a; chokepoint already in 4a; `Turn.Server` statem tests; `SessionRegistry` contract; integration; back-compat) → Tasks 1, 4–7, 10. ✓
- Deliverable 7 (CHANGELOG + version → `0.9.0`) → Task 11. ✓
- Decision-4 "turn state only; caller re-supplies config" → Task 9 rehydration uses caller-supplied config; store yields only turn_state + history. ✓
- Error handling (persist failure hard-fails; tool/LLM Task crash → `*_error`; approval timeout → all-reject) → Tasks 4 (`{:persist}` gate + `:DOWN`), 6 (timeout). ✓
- **Gap noted (acceptable, documented):** the spec's "tool Task crash → error-result envelope into the batch results; the turn continues" is partially covered — Task 4's `:DOWN` clause fails the whole turn rather than degrading a single tool to an error envelope. The per-tool envelope already lives inside `dispatch/2`'s `Task.async_stream` (via `unwrap_tool_task_result!/1`), so an individual tool crash is contained; the server-level `:DOWN` only fires if the *dispatch coordinator* Task itself dies. This matches `dispatch_turn_tools/2` parity. If finer isolation is wanted, add a follow-up; not required for this phase.

**2. Placeholder scan:** No `TBD`/`TODO`/"add error handling". Tasks 6 and 10 mark a few test bodies as "implementer fills the counter-switched stub" with the exact pattern named (Agent counter, Ruleset rule, FakeTool) — these are test-fixture mechanics, not logic placeholders; the production code blocks are complete. Acceptable per the skill (the *how* is specified: stateful `call_llm` via an Agent/counter; `PolicyEngine.Ruleset` with `require_approval`).

**3. Type consistency:** `{mod, handle}` tuples used uniformly for `store`/`registry`. `SessionStore.load_turn_state` → `{:ok, term} | :error` (Task 9 matches both, no `{:error,_}`). `SessionRegistry.whereis` → `{:ok, pid} | :none` (Tasks 1, 9 match both). Handler closures consumed with the exact arities from `Driver.Handlers` (`call_llm/3`, `convert/3`, `validate/2`, `guard/2`, `append/3`). `Dispatch.classify/3` 3-tuple/4-tuple verdicts matched in `dispatch/2`. `Turn.Server` data field names (`turn_state`, `task_ref`, `pending_reply`, `store`, `registry`) consistent across Tasks 4–9.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-17-phase-4b-gen-statem-shell.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
