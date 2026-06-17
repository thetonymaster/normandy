# Phase 6 — AgentProcess Durable Turn Engine Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `AgentProcess` an opt-in `:server` mode that routes turns through the durable `Turn.Session`/`Turn.Server` engine (approval parking, passivation, persistence), while the default `:inline` mode stays byte-for-byte unchanged.

**Architecture:** All changes land in one module, `lib/normandy/coordination/agent_process.ex`, plus a new test file. `:server` mode makes `AgentProcess` a thin, stateful façade in front of the Phase 4b router: it holds a `%BaseAgentConfig{}` template + session infra (`store`/`registry`/`supervisor`) and calls `Turn.Session.run/2` and `Turn.Session.approve/2`. The single non-trivial mechanical change is that `:server`-mode `run` stops blocking the GenServer (it spawns a monitored worker and replies via `GenServer.reply/2`), so the process stays responsive while a turn is parked awaiting approval.

**Tech Stack:** Elixir, `GenServer`, `:gen_statem` (the engine, consumed not modified), ExUnit. No new dependencies. No new modules.

## Global Constraints

- **Default-off:** `turn_engine` defaults to `:inline`; the `:inline` code path is unchanged. `test/coordination/agent_process_test.exs` is the parity oracle and MUST stay green **unmodified**.
- **No new modules.** Reuse `Turn.Session`, `Turn.Supervisor`, `SessionRegistry.Native`, `SessionStore.InMemory` as-is.
- **No silent fallbacks.** Infra start failure in `:server` `init` is a hard `{:stop, reason}`. Store-write failures inside the engine already fail-closed (Phase 4b).
- **Caller contract preserved.** `run/3` returns `{:ok, result} | {:error, reason}` in both modes; `:server` reuses `prepare_input/1` and `extract_result/1` so the result shape matches `:inline`.
- **Commit message rule (this repo):** no AI attribution / no `Co-Authored-By` lines.
- **Gates (every commit):** `mix format` → `mix compile --warnings-as-errors --force` → `mix test`. Full suite green.
- **Final milestone phase → version `1.0.0`** (Task 7).

---

## File Structure

- **Modify:** `lib/normandy/coordination/agent_process.ex` — add `:turn_engine` mode, `:server` state + infra ownership, non-blocking `:server` `run`/`cast`, `approve/2`, store-authoritative `get_agent`/`update_agent`, `terminate/2`.
- **Create:** `test/coordination/agent_process_server_test.exs` — all `:server`-mode tests (`async: false`, isolated from the async `:inline` oracle).
- **Modify (Task 7 only):** `mix.exs` (`@version`), `CHANGELOG.md`.
- **Untouched:** `test/coordination/agent_process_test.exs`, `lib/normandy/agents/turn/*`, `lib/normandy/coordination/{agent_pool,reactive,agent_supervisor}.ex`.

---

## Task 1: `:turn_engine` mode + `:server` state & infra ownership

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex` (`init/1`; add `terminate/2`, `session_opts/1`, owned-infra helpers)
- Test: `test/coordination/agent_process_server_test.exs` (create)

**Interfaces:**
- Consumes: `Normandy.Agents.Turn.Supervisor.start_link/1` → `{:ok, pid}`; `Normandy.Behaviours.SessionStore.InMemory.new/0` → `pid`; `Normandy.Behaviours.SessionRegistry.Native.start_link/1` → `{:ok, pid}` (handle = the registry name atom).
- Produces: AgentProcess state map with new keys `turn_engine :: :inline | :server`, `store :: {module, term} | nil`, `registry :: {module, term} | nil`, `supervisor :: pid | nil`, `extra_session_opts :: keyword`, `owned :: [pid]`, `pending_runs :: %{reference => {GenServer.from, integer}}`. Private `session_opts(state) :: keyword` returning `[session_id:, config:, store:, registry:, supervisor:] ++ extra_session_opts`.

- [ ] **Step 1: Write the failing test** — create `test/coordination/agent_process_server_test.exs`:

```elixir
defmodule Normandy.Coordination.AgentProcessServerTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.BaseAgent
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Components.ToolCall
  alias Normandy.Coordination.AgentProcess

  # Output struct the fake LLM returns; mirrors the Turn.Server test idiom.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # A configurable fake billing tool used by the approval test (Task 4).
  defmodule FakeTool do
    use Normandy.Schema
    schema do
      field(:name, :string)
    end
  end

  defimpl Normandy.Tools.BaseTool, for: Normandy.Coordination.AgentProcessServerTest.FakeTool do
    def tool_name(t), do: t.name
    def tool_description(_), do: "fake billing tool"
    def input_schema(_), do: %{}
    def run(_t), do: {:ok, "charged"}
  end

  # A plain BaseAgentConfig template (client is nil; the fake LLM is injected via handlers).
  defp server_config(extra \\ %{}) do
    base = %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: Normandy.Components.AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: Normandy.Components.AgentMemory.new_memory(),
      tool_registry: nil
    }

    Map.merge(base, extra)
  end

  # handlers whose call_llm always returns a no-tools final response.
  defp final_handlers(text \\ "ok") do
    %{BaseAgent.non_streaming_handlers() | call_llm: fn _c, _s, _r -> %Resp{content: text} end}
  end

  # Supplied infra: a fresh store, registry, and supervisor for one test.
  defp supplied_infra do
    {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
    [store: {InMemory, InMemory.new()}, registry: {Native, Native.new()}, supervisor: sup]
  end

  describe ":server infra ownership" do
    test "self-contained mode starts and owns store/registry/supervisor; stop tears them down" do
      {:ok, pid} =
        AgentProcess.start_link(agent: server_config(), turn_engine: :server, handlers: final_handlers())

      %{store: {_sm, store_h}, registry: {_rm, reg_name}, supervisor: sup, owned: owned} =
        :sys.get_state(pid)

      assert is_pid(store_h)
      assert is_atom(reg_name)
      assert is_pid(sup)
      assert owned != []
      assert Enum.all?(owned, &Process.alive?/1)

      :ok = AgentProcess.stop(pid)
      Process.sleep(20)
      refute Enum.any?(owned, &Process.alive?/1)
    end

    test "supplied infra is used and NOT owned (survives stop)" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link([agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra)

      %{owned: owned} = :sys.get_state(pid)
      assert owned == []

      {InMemory, store_h} = infra[:store]
      :ok = AgentProcess.stop(pid)
      Process.sleep(20)
      assert Process.alive?(store_h)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/coordination/agent_process_server_test.exs`
Expected: FAIL — `:sys.get_state(pid)` returns the old state map without `:owned`/`:store` keys (a `KeyError` or match error), because `init/1` does not yet handle `:turn_engine`.

- [ ] **Step 3: Implement `init/1` mode handling + helpers**

In `lib/normandy/coordination/agent_process.ex`, replace the existing `init/1` (currently `agent_process.ex:191-208`) with:

```elixir
  @impl true
  def init(opts) do
    agent = Keyword.fetch!(opts, :agent)
    agent_id = Keyword.get(opts, :agent_id, UUID.uuid4())
    context_pid = Keyword.get(opts, :context_pid)
    turn_engine = Keyword.get(opts, :turn_engine, :inline)

    base = %{
      agent: agent,
      agent_id: agent_id,
      context_pid: context_pid,
      turn_engine: turn_engine,
      store: nil,
      registry: nil,
      supervisor: nil,
      extra_session_opts: [],
      owned: [],
      pending_runs: %{},
      run_count: 0,
      last_run: nil,
      total_runtime_ms: 0,
      created_at: DateTime.utc_now()
    }

    case turn_engine do
      :inline ->
        {:ok, base}

      :server ->
        case server_infra(opts) do
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
                     :idle_timeout_ms
                   ])
             }}

          {:error, reason} ->
            {:stop, {:server_init_failed, reason}}
        end
    end
  end

  # Resolve session infra: use what the caller supplied, else start+own defaults.
  # Returns {:ok, store, registry, supervisor, owned_pids} | {:error, reason}.
  defp server_infra(opts) do
    {store, owned_store} =
      case Keyword.get(opts, :store) do
        nil -> {{Normandy.Behaviours.SessionStore.InMemory, store_pid = Normandy.Behaviours.SessionStore.InMemory.new()}, [store_pid]}
        supplied -> {supplied, []}
      end

    {registry, owned_reg} =
      case Keyword.get(opts, :registry) do
        nil ->
          name = :"agentprocess_reg_#{System.unique_integer([:positive])}"
          {:ok, reg_pid} = Normandy.Behaviours.SessionRegistry.Native.start_link(name: name)
          {{Normandy.Behaviours.SessionRegistry.Native, name}, [reg_pid]}

        supplied ->
          {supplied, []}
      end

    {supervisor, owned_sup} =
      case Keyword.get(opts, :supervisor) do
        nil ->
          {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
          {sup, [sup]}

        supplied ->
          {supplied, []}
      end

    {:ok, store, registry, supervisor, owned_store ++ owned_reg ++ owned_sup}
  rescue
    e -> {:error, e}
  end

  @impl true
  def terminate(_reason, %{owned: owned}) when is_list(owned) do
    Enum.each(owned, fn pid ->
      if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # The keyword list Turn.Session.run/2 and Turn.Session.approve/2 expect.
  defp session_opts(state) do
    [
      session_id: state.agent_id,
      config: state.agent,
      store: state.store,
      registry: state.registry,
      supervisor: state.supervisor
    ] ++ state.extra_session_opts
  end
```

Add the alias near the top (after `alias Normandy.Agents.BaseAgent` at `agent_process.ex:32`):

```elixir
  alias Normandy.Agents.Turn
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix format && mix test test/coordination/agent_process_server_test.exs`
Expected: PASS (2 tests). Then `mix test test/coordination/agent_process_test.exs` — Expected: PASS (oracle unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/coordination/agent_process.ex test/coordination/agent_process_server_test.exs
git commit -m "feat(coordination): AgentProcess :server mode skeleton — infra ownership + session_opts"
```

---

## Task 2: Non-blocking `:server` `run/3` round-trip

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex` (`run/3` doc note optional; add `:server` `handle_call({:run, …})`, `handle_info/2` for worker results + `:DOWN`)
- Test: `test/coordination/agent_process_server_test.exs`

**Interfaces:**
- Consumes: `session_opts/1` (Task 1); `Turn.Session.run(opts, user_input) :: {:ok, term} | {:error, term}`; existing `prepare_input/1` (`agent_process.ex:300-308`) and `extract_result/1` (`agent_process.ex:310-314`).
- Produces: `:server`-mode `run/3` returning `{:ok, result} | {:error, reason}` via deferred `GenServer.reply/2`. Worker→server message `{:run_result, reference, term}`. `pending_runs` entries consumed on `{:run_result, …}` and `{:DOWN, …}`.

- [ ] **Step 1: Write the failing test** — append to `test/coordination/agent_process_server_test.exs` inside the module:

```elixir
  describe ":server run/3" do
    test "round-trips a turn through Turn.Session and returns the final result" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers("hello")] ++ infra
        )

      assert {:ok, %Resp{content: "hello"}} = AgentProcess.run(pid, "hi there")

      stats = AgentProcess.get_stats(pid)
      assert stats.run_count == 1
      assert stats.last_run != nil
    end

    test "GenServer stays responsive while a run is in flight" do
      infra = supplied_infra()

      slow_handlers = %{
        BaseAgent.non_streaming_handlers()
        | call_llm: fn _c, _s, _r ->
            Process.sleep(150)
            %Resp{content: "slow"}
          end
      }

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: slow_handlers] ++ infra
        )

      parent = self()
      spawn(fn -> send(parent, {:result, AgentProcess.run(pid, "go")}) end)
      Process.sleep(30)

      # The slow turn is mid-flight; a sync call must still return immediately.
      t0 = System.monotonic_time(:millisecond)
      _ = AgentProcess.get_stats(pid)
      assert System.monotonic_time(:millisecond) - t0 < 50

      assert_receive {:result, {:ok, %Resp{content: "slow"}}}, 2_000
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/coordination/agent_process_server_test.exs -- --only-describe ":server run/3"` (or run the whole file)
Expected: FAIL — `AgentProcess.run` hits the existing `:inline` `handle_call({:run, …})` which calls `BaseAgent.run(state.agent, …)`; with `client: nil` that raises, returning `{:error, {:exception, …}}` instead of `{:ok, %Resp{}}`.

- [ ] **Step 3: Implement the `:server` `run` clause + result handlers**

In `agent_process.ex`, the existing `handle_call({:run, input}, _from, state)` (at `agent_process.ex:211`) is the `:inline` path. **Add a more specific `:server` clause immediately before it** (Elixir matches top-to-bottom; pattern-match on `turn_engine`):

```elixir
  @impl true
  def handle_call({:run, input}, from, %{turn_engine: :server} = state) do
    start_time = System.monotonic_time(:millisecond)
    ref = spawn_run(state, prepare_input(input))
    {:noreply, %{state | pending_runs: Map.put(state.pending_runs, ref, {from, start_time})}}
  end
```

Leave the existing `handle_call({:run, input}, _from, state)` clause untouched as the `:inline` path (it already matches any state, so place the `:server` clause above it).

Add the worker spawn + result handlers (place near the other `handle_*` callbacks). This mirrors `Turn.Server.spawn_task/2` — monitored + unlinked so a worker crash does not take down the GenServer:

```elixir
  # Spawn a monitored, UNLINKED worker that runs the turn and tags its reply
  # with the monitor ref (so {:run_result, ref, …} and {:DOWN, ref, …} correlate).
  defp spawn_run(state, user_input) do
    server = self()
    opts = session_opts(state)

    worker =
      spawn(fn ->
        ref =
          receive do
            {:monitor_ref, r} -> r
          end

        result =
          case Turn.Session.run(opts, user_input) do
            {:ok, value} -> {:ok, extract_result(value)}
            {:error, _} = err -> err
          end

        send(server, {:run_result, ref, result})
      end)

    ref = Process.monitor(worker)
    send(worker, {:monitor_ref, ref})
    ref
  end

  @impl true
  def handle_info({:run_result, ref, result}, state) do
    case Map.pop(state.pending_runs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, start_time}, rest} ->
        Process.demonitor(ref, [:flush])
        runtime = System.monotonic_time(:millisecond) - start_time
        GenServer.reply(from, result)

        {:noreply,
         %{
           state
           | pending_runs: rest,
             run_count: state.run_count + 1,
             last_run: DateTime.utc_now(),
             total_runtime_ms: state.total_runtime_ms + runtime
         }}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending_runs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, _start}, rest} ->
        GenServer.reply(from, {:error, {:task_down, reason}})
        {:noreply, %{state | pending_runs: rest}}
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix format && mix test test/coordination/agent_process_server_test.exs`
Expected: PASS (4 tests). Then `mix test test/coordination/agent_process_test.exs` — Expected: PASS (oracle unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/coordination/agent_process.ex test/coordination/agent_process_server_test.exs
git commit -m "feat(coordination): non-blocking :server run/3 routing through Turn.Session"
```

---

## Task 3: `:server` `cast/3` async

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex` (add `:server` `handle_cast({:run_async, …})`)
- Test: `test/coordination/agent_process_server_test.exs`

**Interfaces:**
- Consumes: `session_opts/1`, `prepare_input/1`, `extract_result/1`, `Turn.Session.run/2`.
- Produces: `:server`-mode `cast/3` that sends `{:agent_result, agent_id, {:ok, result} | {:error, reason}}` to `reply_to` (parity with the existing `:inline` cast contract).

- [ ] **Step 1: Write the failing test** — append inside the module:

```elixir
  describe ":server cast/3" do
    test "delivers the async result to reply_to" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, agent_id: "srv_async", handlers: final_handlers("async-ok")] ++ infra
        )

      :ok = AgentProcess.cast(pid, "bg", reply_to: self())
      assert_receive {:agent_result, "srv_async", {:ok, %Resp{content: "async-ok"}}}, 2_000
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/coordination/agent_process_server_test.exs`
Expected: FAIL — the async result is `{:error, {:exception, …}}` (existing `:inline` cast runs `BaseAgent.run` with `client: nil`), not `{:ok, %Resp{}}`.

- [ ] **Step 3: Implement the `:server` cast clause**

Add a `:server`-specific `handle_cast` clause **above** the existing `handle_cast({:run_async, input, reply_to}, state)` (`agent_process.ex:277`):

```elixir
  @impl true
  def handle_cast({:run_async, input, reply_to}, %{turn_engine: :server} = state) do
    opts = session_opts(state)
    agent_id = state.agent_id
    user_input = prepare_input(input)

    Task.start(fn ->
      result =
        case Turn.Session.run(opts, user_input) do
          {:ok, value} -> {:ok, extract_result(value)}
          {:error, _} = err -> err
        end

      if reply_to, do: send(reply_to, {:agent_result, agent_id, result})
    end)

    {:noreply, %{state | run_count: state.run_count + 1, last_run: DateTime.utc_now()}}
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix format && mix test test/coordination/agent_process_server_test.exs`
Expected: PASS (5 tests). `mix test test/coordination/agent_process_test.exs` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/coordination/agent_process.ex test/coordination/agent_process_server_test.exs
git commit -m "feat(coordination): :server cast/3 async routing through Turn.Session"
```

---

## Task 4: `approve/2` + parking round-trip

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex` (public `approve/2`, `handle_call({:approve, …})` for both modes)
- Test: `test/coordination/agent_process_server_test.exs`

**Interfaces:**
- Consumes: `session_opts/1`; `Turn.Session.approve(opts, decisions) :: :ok | {:error, :no_session}`.
- Produces: `AgentProcess.approve(server, decisions :: %{optional(String.t) => :approve | :reject}) :: :ok | {:error, :no_session} | {:error, :inline_mode}`.

- [ ] **Step 1: Write the failing test** — append inside the module:

```elixir
  describe "approve/2" do
    # Counter-switched call_llm: 1st call parks one "billing" tool call; later calls finalize.
    defp approval_handlers do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      call_llm = fn _c, _s, _r ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0 do
          %Resp{content: "", tool_calls: [%ToolCall{id: "pk1", name: "billing", input: %{}}]}
        else
          %Resp{content: "done", tool_calls: nil}
        end
      end

      %{BaseAgent.non_streaming_handlers() | call_llm: call_llm}
    end

    defp approval_config do
      server_config(%{
        tool_registry: Normandy.Tools.Registry.new([%FakeTool{name: "billing"}]),
        behaviours: %Normandy.Behaviours.Config{
          policy:
            {Normandy.Behaviours.PolicyEngine.Ruleset,
             rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
             default_action: :allow}
        }
      })
    end

    test "inline mode rejects approve" do
      agent = BaseAgent.init(%{client: %NormandyTest.Support.ModelMockup{}, model: "claude-haiku-4-5-20251001", temperature: 0.7})
      {:ok, pid} = AgentProcess.start_link(agent: agent)
      assert {:error, :inline_mode} = AgentProcess.approve(pid, %{"pk1" => :approve})
    end

    test "unknown session returns {:error, :no_session}" do
      infra = supplied_infra()
      {:ok, pid} = AgentProcess.start_link([agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra)
      assert {:error, :no_session} = AgentProcess.approve(pid, %{"pk1" => :approve})
    end

    test "park → stays responsive → approve → resume → original caller gets final result" do
      infra = supplied_infra()
      parent = self()

      {:ok, pid} =
        AgentProcess.start_link(
          [
            agent: approval_config(),
            turn_engine: :server,
            agent_id: "approval-rt",
            handlers: approval_handlers(),
            subscriber: fn name, meta -> send(parent, {:event, name, meta}) end
          ] ++ infra
        )

      # run blocks the CALLER until the turn finalizes, so run it from another process.
      spawn(fn -> send(parent, {:result, AgentProcess.run(pid, "please charge")}) end)

      assert_receive {:event, :awaiting_approval, %{parked: 1}}, 2_000

      # GenServer is responsive while the turn is parked.
      t0 = System.monotonic_time(:millisecond)
      stats = AgentProcess.get_stats(pid)
      assert System.monotonic_time(:millisecond) - t0 < 50
      assert stats.agent_id == "approval-rt"

      :ok = AgentProcess.approve(pid, %{"pk1" => :approve})
      assert_receive {:result, {:ok, %Resp{content: "done"}}}, 2_000
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/coordination/agent_process_server_test.exs`
Expected: FAIL — `AgentProcess.approve/2` is undefined (compile error / `UndefinedFunctionError`).

- [ ] **Step 3: Implement `approve/2` + handlers**

Add the public function near the other client API (after `cast/3`, around `agent_process.ex:116`):

```elixir
  @doc """
  Delivers approval decisions to a turn parked awaiting human approval
  (`:server` mode only). `decisions` maps `tool_call_id` to `:approve | :reject`;
  any parked id absent or `:reject` is treated as rejected (fail-closed).

  Returns `:ok`, `{:error, :no_session}` if no live parked session exists, or
  `{:error, :inline_mode}` when the process runs in `:inline` mode.
  """
  @spec approve(GenServer.server(), %{optional(String.t()) => :approve | :reject}) ::
          :ok | {:error, :no_session} | {:error, :inline_mode}
  def approve(server, decisions) do
    GenServer.call(server, {:approve, decisions})
  end
```

Add the `handle_call` clauses (the `:server` clause first, then the catch-all `:inline` reject):

```elixir
  @impl true
  def handle_call({:approve, decisions}, _from, %{turn_engine: :server} = state) do
    {:reply, Turn.Session.approve(session_opts(state), decisions), state}
  end

  @impl true
  def handle_call({:approve, _decisions}, _from, state) do
    {:reply, {:error, :inline_mode}, state}
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix format && mix test test/coordination/agent_process_server_test.exs`
Expected: PASS (8 tests). `mix test test/coordination/agent_process_test.exs` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/coordination/agent_process.ex test/coordination/agent_process_server_test.exs
git commit -m "feat(coordination): AgentProcess.approve/2 + parking round-trip in :server mode"
```

---

## Task 5: Store-authoritative `get_agent/1`

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex` (add `:server` `handle_call(:get_agent, …)` + `reconstruct_agent/1`)
- Test: `test/coordination/agent_process_server_test.exs`

**Interfaces:**
- Consumes: `state.store :: {module, handle}`; `module.history(handle, session_id) :: {:ok, [Entry]} | {:error, term}`; `Normandy.Components.AgentMemory.from_entries/1`; `state.agent.memory.max_messages`.
- Produces: `:server` `get_agent/1` returns the config template with `:memory` rebuilt from the store.

- [ ] **Step 1: Write the failing test** — append inside the module:

```elixir
  describe ":server get_agent/1" do
    test "reconstructs config.memory from the SessionStore after a turn" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers("reply-1")] ++ infra
        )

      assert {:ok, _} = AgentProcess.run(pid, "first message")

      agent = AgentProcess.get_agent(pid)
      contents = Enum.map(Normandy.Components.AgentMemory.entry_chain(agent.memory), & &1.content)

      # The user message persisted to the store is reflected back through get_agent.
      assert Enum.any?(contents, fn c -> c == %{chat_message: "first message"} or c == "first message" end)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/coordination/agent_process_server_test.exs`
Expected: FAIL — the existing `handle_call(:get_agent, …)` returns `state.agent`, whose `memory` is the empty template (never updated in `:server` mode); the user message is absent.

- [ ] **Step 3: Implement `:server` `get_agent` + `reconstruct_agent/1`**

Add a `:server`-specific clause **above** the existing `handle_call(:get_agent, _from, state)` (`agent_process.ex:248`):

```elixir
  @impl true
  def handle_call(:get_agent, _from, %{turn_engine: :server} = state) do
    {:reply, reconstruct_agent(state), state}
  end
```

Add the helper:

```elixir
  # Store-authoritative read: rebuild config.memory from the SessionStore so callers
  # see durable truth. On a store fault, log and return the template unchanged.
  defp reconstruct_agent(%{store: {mod, handle}, agent: agent, agent_id: sid}) do
    case mod.history(handle, sid) do
      {:ok, entries} ->
        rebuilt = %{
          Normandy.Components.AgentMemory.from_entries(entries)
          | max_messages: agent.memory.max_messages
        }

        %{agent | memory: rebuilt}

      {:error, reason} ->
        Logger.warning("AgentProcess #{sid}: get_agent could not read store: #{inspect(reason)}")
        agent
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix format && mix test test/coordination/agent_process_server_test.exs`
Expected: PASS (9 tests). `mix test test/coordination/agent_process_test.exs` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/coordination/agent_process.ex test/coordination/agent_process_server_test.exs
git commit -m "feat(coordination): store-authoritative get_agent/1 in :server mode"
```

---

## Task 6: Template-only `update_agent/2`

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex` (add `:server` `handle_call({:update_agent, …})`)
- Test: `test/coordination/agent_process_server_test.exs`

**Interfaces:**
- Consumes: `state.agent :: %BaseAgentConfig{}`.
- Produces: `:server` `update_agent/2` applies the fn to the template; a detected `:memory` mutation is discarded (with a warning) — the store stays authoritative; non-memory changes take effect on the next turn.

- [ ] **Step 1: Write the failing test** — append inside the module:

```elixir
  describe ":server update_agent/2" do
    test "applies non-memory changes and discards memory mutations" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra
        )

      tampered = Normandy.Components.AgentMemory.add_message(Normandy.Components.AgentMemory.new_memory(), "user", "injected")

      :ok =
        AgentProcess.update_agent(pid, fn a ->
          %{a | temperature: 0.42, memory: tampered}
        end)

      %{agent: agent} = :sys.get_state(pid)
      # Non-memory change applied:
      assert agent.temperature == 0.42
      # Memory mutation discarded (still the empty template, not the injected one):
      assert Normandy.Components.AgentMemory.entry_chain(agent.memory) == []
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/coordination/agent_process_server_test.exs`
Expected: FAIL — the existing `handle_call({:update_agent, …})` writes the whole returned struct (including the injected memory), so `entry_chain` is non-empty.

- [ ] **Step 3: Implement the `:server` `update_agent` clause**

Add a `:server`-specific clause **above** the existing `handle_call({:update_agent, update_fn}, _from, state)` (`agent_process.ex:271`):

```elixir
  @impl true
  def handle_call({:update_agent, update_fn}, _from, %{turn_engine: :server} = state) do
    updated = update_fn.(state.agent)

    new_agent =
      if updated.memory != state.agent.memory do
        Logger.warning(
          "AgentProcess #{state.agent_id}: update_agent memory mutation ignored in :server mode " <>
            "(SessionStore is authoritative)"
        )

        %{updated | memory: state.agent.memory}
      else
        updated
      end

    {:reply, :ok, %{state | agent: new_agent}}
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix format && mix test test/coordination/agent_process_server_test.exs`
Expected: PASS (10 tests). Then run the FULL suite: `mix test` — Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/normandy/coordination/agent_process.ex test/coordination/agent_process_server_test.exs
git commit -m "feat(coordination): template-only update_agent/2 in :server mode"
```

---

## Task 7: Moduledoc, CHANGELOG, and `1.0.0` version cut

**Files:**
- Modify: `lib/normandy/coordination/agent_process.ex` (moduledoc — document `:server` mode + `turn_engine` opt)
- Modify: `CHANGELOG.md`
- Modify: `mix.exs` (`@version`)

**Interfaces:** none (docs + metadata).

- [ ] **Step 1: Reconcile the version baseline**

Run: `git log --oneline -8` and `grep -n "@version" mix.exs` and read the top `## [..]` heading in `CHANGELOG.md`.
Decision rule:
- If the current `0.9.0` heading already lists Phase 5 (compaction, #32): Phase 6 bumps directly to `1.0.0`.
- If Phase 5 is **not** recorded under any version heading: add a `## [0.10.0]` entry for Phase 5 first (one line crediting #32), then `## [1.0.0]` for Phase 6 below your new entry — keeping the changelog monotonic.
No code change in this step; it determines the headings used in Steps 3–4.

- [ ] **Step 2: Document `:server` mode in the moduledoc**

Extend the `AgentProcess` `@moduledoc` (`agent_process.ex:2-27`) — add this section before the closing `"""`:

```elixir
  ## Durable turn engine (`:server` mode)

  Pass `turn_engine: :server` to route turns through the durable
  `Normandy.Agents.Turn.Session`/`Turn.Server` engine (approval parking,
  passivation, persistence) instead of the default synchronous `:inline`
  `BaseAgent.run/2` path. `:inline` is the default and is unchanged.

      {:ok, pid} = AgentProcess.start_link(agent: config, turn_engine: :server)

  In `:server` mode:

  - `run/3` is non-blocking internally (the GenServer stays responsive while a
    turn is parked); `approve/2` delivers human-approval decisions to a parked turn.
  - The `SessionStore` owns conversation memory: `get_agent/1` reconstructs it
    from the store, and `update_agent/2` updates only the config template
    (model/temperature/behaviours/tools) — memory mutations are ignored.
  - Session infra (`:store`, `:registry`, `:supervisor`) may be supplied via
    `start_link`; if omitted, the process starts and owns in-memory defaults
    that terminate with it. `:subscriber`, `:handlers`, `:approval_timeout_ms`,
    and `:idle_timeout_ms` are forwarded to `Turn.Session` when supplied.
```

- [ ] **Step 3: Add the CHANGELOG entry**

Under the heading chosen in Step 1 (`## [1.0.0]`), add:

```markdown
## [1.0.0]

### Added
- `Normandy.Coordination.AgentProcess` opt-in `:server` mode (`turn_engine: :server`)
  routing turns through the durable `Turn.Session`/`Turn.Server` engine: approval
  parking, passivation, and persistence.
- `AgentProcess.approve/2` delivers human-approval decisions to a parked turn.

### Changed
- In `:server` mode, `run/3`/`cast/3` route through `Turn.Session`; `run/3` is
  non-blocking so the process stays responsive while a turn is parked.
- In `:server` mode, the `SessionStore` is authoritative for conversation memory:
  `get_agent/1` reconstructs memory from the store; `update_agent/2` is config-template
  only (memory mutations are ignored).
- Final phase of the harness-decomposition milestone.

### Migration
- No action required: `:inline` is the default and is byte-for-byte unchanged.
- To adopt the durable engine: `AgentProcess.start_link(agent: config, turn_engine: :server)`,
  optionally passing shared `:store`/`:registry`/`:supervisor`.
```

- [ ] **Step 4: Cut the version**

Edit `mix.exs` line 4: `@version "0.9.0"` → `@version "1.0.0"`.

- [ ] **Step 5: Verify gates and commit**

Run: `mix format && mix compile --warnings-as-errors --force && mix test`
Expected: clean compile, full suite green.

```bash
git add lib/normandy/coordination/agent_process.ex CHANGELOG.md mix.exs
git commit -m "docs(coordination): document :server mode; cut 1.0.0 (final milestone phase)"
```

---

## Self-Review

**1. Spec coverage** (spec §Decisions / §Data flow / §Testing → task):
- Decision 1 (mode, default-off) → Task 1 (`turn_engine` in `init`, default `:inline`).
- Decision 2 (route through `Turn.Session`, owned-vs-supplied infra, hard-fail init) → Task 1.
- Decision 3 row `run` (non-blocking) → Task 2; `cast` → Task 3; `approve/2` → Task 4; `get_agent` reconstruct → Task 5; `update_agent` template-only → Task 6; `get_id`/`get_stats`/`stop` unchanged → covered by oracle (not modified).
- Decision 4 (policy spectrum) → Task 4 uses `{Ruleset, …, :require_approval}`; default allow-all exercised by Tasks 2/3/5.
- Data flow A (no approval) → Task 2; B (approval) → Task 4; C (passivation/rehydrate) → exercised by the engine; the `:server` path inherits it (the Phase 4b integration test already covers passivate→rehydrate; not re-tested here since AgentProcess adds no engine logic).
- Error handling: `Turn.Session.run {:error}` → Task 2 (`{:error, _} = err -> err`); run worker crash → Task 2 (`:DOWN`); approval timeout → engine (fail-closed, inherited); `approve` no-session → Task 4; `:inline` approve → Task 4; `get_agent` store fault → Task 5; `update_agent` memory mutation → Task 6; infra init failure → Task 1 (`{:stop, …}`).
- Versioning → Task 7 (incl. the `0.9.0`/Phase-5 reconciliation as Step 1).

**2. Placeholder scan:** No `TBD`/`TODO`/"handle edge cases"/"similar to". Every code step shows complete code; every run step shows the command + expected outcome.

**3. Type consistency:** `session_opts/1` defined in Task 1 is consumed verbatim in Tasks 2/3/4. `prepare_input/1` + `extract_result/1` (existing) used identically in Tasks 2/3. `pending_runs` keyed by monitor `reference`, written in Task 2's `spawn_run`, consumed by both `handle_info` clauses. `{:run_result, ref, result}` tag matches between `spawn_run` and `handle_info`. `Turn.Session.run/2` return `{:ok, value} | {:error, reason}` and `Turn.Session.approve/2` return `:ok | {:error, :no_session}` match the verified signatures. `reconstruct_agent/1` uses `AgentMemory.from_entries/1` + `max_messages` exactly as `Turn.Session` rehydration does.
