defmodule Normandy.Coordination.AgentProcessServerTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Normandy.Agents.BaseAgent
  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Components.AgentMemory
  alias Normandy.Components.ToolCall
  alias Normandy.Coordination.AgentProcess
  alias Normandy.Coordination.AgentProcess.ScopedRegistry
  alias Normandy.Test.FakeTool
  alias Normandy.Tools.Toolset
  alias Normandy.TurnError

  # Output struct the fake LLM returns; mirrors the Turn.Server test idiom.
  defmodule Resp do
    defstruct content: "", tool_calls: nil
  end

  # Memory encodes what it stores (AgentMemory.Entry's `wire`), so the fake answer
  # needs an encoding like any output schema.
  defimpl Normandy.Components.BaseIOSchema, for: Resp do
    def to_json(resp), do: resp.content
    def get_schema(_resp), do: %{}
  end

  # A plain BaseAgentConfig template (client is nil; the fake LLM is injected via handlers).
  defp server_config(extra \\ %{}) do
    base = %Normandy.Agents.BaseAgentConfig{
      input_schema: nil,
      output_schema: %Resp{},
      client: nil,
      model: "test",
      memory: AgentMemory.new_memory(),
      prompt_specification: %Normandy.Components.PromptSpecification{},
      initial_memory: AgentMemory.new_memory(),
      toolset: nil
    }

    Map.merge(base, extra)
  end

  # handlers whose call_llm always returns a no-tools final response.
  defp final_handlers(text \\ "ok") do
    %{
      AgentHandlers.non_streaming_handlers()
      | call_llm: fn _c, _s, _r -> %Resp{content: text} end
    }
  end

  # Supplied infra: a fresh store, registry, and supervisor for one test.
  defp supplied_infra do
    {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
    [store: {InMemory, InMemory.new()}, registry: {Native, Native.new()}, supervisor: sup]
  end

  # Poll until every pid is dead, up to ~2s. Owned infra is torn down via async
  # `Process.exit(:shutdown)` signals (incl. a DynamicSupervisor's graceful
  # shutdown), so a fixed sleep is fragile under slow/instrumented CI (e.g.
  # `mix test --cover`). Poll instead of asserting after one short sleep.
  defp assert_all_dead(pids, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    cond do
      not Enum.any?(pids, &Process.alive?/1) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("owned infra still alive: #{inspect(Enum.filter(pids, &Process.alive?/1))}")

      true ->
        Process.sleep(10)
        assert_all_dead(pids, deadline)
    end
  end

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

    %{AgentHandlers.non_streaming_handlers() | call_llm: call_llm}
  end

  defp approval_config do
    server_config(%{
      toolset: Toolset.new([%FakeTool{name: "billing"}]),
      behaviours: %Normandy.Behaviours.Config{
        policy:
          {Normandy.Behaviours.PolicyEngine.Ruleset,
           rules: [%{match: "billing", action: :require_approval, rule_id: "R1"}],
           default_action: :allow}
      }
    })
  end

  describe ":server infra ownership" do
    test "self-contained mode starts and owns store/registry/supervisor; stop tears them down" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent: server_config(),
          turn_engine: :server,
          handlers: final_handlers()
        )

      %{
        engine_state: %{
          session: %Normandy.Agents.Turn.Session{
            store: {_sm, store_h},
            registry: {ScopedRegistry, {reg_name, scope}},
            supervisor: sup
          }
        },
        owned: owned
      } = :sys.get_state(pid)

      assert is_pid(store_h)
      # A scope in Normandy's shared registry: nothing to start or own.
      assert reg_name == ScopedRegistry.registry_name()
      assert is_reference(scope)
      assert is_pid(sup)
      assert Enum.sort(owned) == Enum.sort([store_h, sup])
      assert Enum.all?(owned, &Process.alive?/1)

      :ok = AgentProcess.stop(pid)
      assert_all_dead(owned)
    end

    test "supplied infra is used and NOT owned (survives stop)" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra
        )

      %{owned: owned} = :sys.get_state(pid)
      assert owned == []

      {InMemory, store_h} = infra[:store]
      :ok = AgentProcess.stop(pid)
      # Wait until the AgentProcess has fully terminated (so terminate/2 ran),
      # then assert the SUPPLIED store survived — deterministic, not a fixed sleep.
      assert_all_dead([pid])
      assert Process.alive?(store_h)
    end
  end

  describe ":server run/3" do
    test "round-trips a turn through Turn.Session and returns the final result" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers("hello")] ++
            infra
        )

      assert {:ok, %Resp{content: "hello"}} = AgentProcess.run(pid, "hi there")

      stats = AgentProcess.get_stats(pid)
      assert stats.run_count == 1
      assert stats.last_run != nil
    end

    test "GenServer stays responsive while a run is in flight" do
      infra = supplied_infra()
      parent = self()

      slow_handlers = %{
        AgentHandlers.non_streaming_handlers()
        | call_llm: fn _c, _s, _r ->
            send(parent, :llm_started)
            Process.sleep(500)
            %Resp{content: "slow"}
          end
      }

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: slow_handlers] ++ infra
        )

      spawn(fn -> send(parent, {:result, AgentProcess.run(pid, "go")}) end)
      # Wait for proof the turn is actually inside call_llm before measuring;
      # a fixed sleep can't prove the run is in-flight (false-positive risk).
      assert_receive :llm_started, 1_000

      # The slow turn (500ms) is mid-flight; a sync call must still return
      # promptly. A blocking implementation would make this wait ~470ms; the
      # bound stays well below that while tolerating instrumented/slow CI.
      t0 = System.monotonic_time(:millisecond)
      _ = AgentProcess.get_stats(pid)
      assert System.monotonic_time(:millisecond) - t0 < 200

      assert_receive {:result, {:ok, %Resp{content: "slow"}}}, 2_000
    end
  end

  describe ":server cast/3" do
    test "delivers the async result to reply_to" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [
            agent: server_config(),
            turn_engine: :server,
            agent_id: "srv_async",
            handlers: final_handlers("async-ok")
          ] ++ infra
        )

      :ok = AgentProcess.cast(pid, "bg", reply_to: self())
      assert_receive {:agent_result, "srv_async", {:ok, %Resp{content: "async-ok"}}}, 2_000
    end

    test "delivers an error to reply_to when the turn crashes (no silent loss)" do
      infra = supplied_infra()

      crash_handlers = %{
        AgentHandlers.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> raise "boom" end
      }

      {:ok, pid} =
        AgentProcess.start_link(
          [
            agent: server_config(),
            turn_engine: :server,
            agent_id: "srv_async_crash",
            handlers: crash_handlers
          ] ++ infra
        )

      capture_log(fn ->
        :ok = AgentProcess.cast(pid, "bg", reply_to: self())
        # A crashing async turn must still notify reply_to with an error,
        # never drop the reply.
        assert_receive {:agent_result, "srv_async_crash", {:error, _reason}}, 2_000
      end)
    end
  end

  describe "approve/2" do
    test "inline mode rejects approve" do
      agent =
        BaseAgent.init(%{
          client: %NormandyTest.Support.ModelMockup{},
          model: "claude-haiku-4-5-20251001",
          temperature: 0.7
        })

      {:ok, pid} = AgentProcess.start_link(agent: agent)
      assert {:error, :inline_mode} = AgentProcess.approve(pid, %{"pk1" => :approve})
    end

    test "unknown session returns a :session_unavailable TurnError" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra
        )

      assert {:error, %Normandy.TurnError{type: :session_unavailable, reason: :no_session}} =
               AgentProcess.approve(pid, %{"pk1" => :approve})
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

      # GenServer is responsive while the turn is parked. A blocking
      # implementation would hang this call until the approval timeout (~300s);
      # the bound proves non-blocking with ample headroom for slow/instrumented CI.
      t0 = System.monotonic_time(:millisecond)
      stats = AgentProcess.get_stats(pid)
      assert System.monotonic_time(:millisecond) - t0 < 500
      assert stats.agent_id == "approval-rt"

      :ok = AgentProcess.approve(pid, %{"pk1" => :approve})
      assert_receive {:result, {:ok, %Resp{content: "done"}}}, 2_000
    end
  end

  describe ":server approval expiry" do
    test "forwards :on_approval_timeout; :fail surfaces an :approval_timeout TurnError" do
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

      assert {:error, %TurnError{type: :approval_timeout, reason: ["pk1"]}} =
               AgentProcess.run(pid, "please charge")
    end
  end

  describe ":server get_agent/1" do
    test "reconstructs config.memory from the SessionStore after a turn" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers("reply-1")] ++
            infra
        )

      assert {:ok, _} = AgentProcess.run(pid, "first message")

      agent = AgentProcess.get_agent(pid)
      contents = Enum.map(AgentMemory.entry_chain(agent.memory), & &1.content)

      # The user message persisted to the store is reflected back through get_agent.
      # :server mode wraps input via prepare_input/1, so the persisted content is the map form.
      assert Enum.any?(contents, fn c -> c == %{chat_message: "first message"} end)
    end
  end

  describe "handle_info resilience" do
    test "an unexpected info message does not crash the process (inline)" do
      agent =
        BaseAgent.init(%{
          client: %NormandyTest.Support.ModelMockup{},
          model: "claude-haiku-4-5-20251001",
          temperature: 0.7
        })

      {:ok, pid} = AgentProcess.start_link(agent: agent)
      send(pid, {:totally_unexpected, :stray})
      # still alive + responsive
      assert is_binary(AgentProcess.get_id(pid))
    end

    test "an unexpected info message does not crash the process (:server)" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra
        )

      send(pid, {:totally_unexpected, :stray})
      assert %{run_count: _} = AgentProcess.get_stats(pid)
    end
  end

  describe ":server worker-crash contract" do
    test ":server run/3 returns a :task_down TurnError when the turn worker crashes" do
      infra = supplied_infra()

      crash_handlers = %{
        AgentHandlers.non_streaming_handlers()
        | # exit/1 (not raise) so the abnormal worker exit doesn't spew an
          # exception crash-report into CI output; still yields a non-normal
          # :DOWN reason and thus a :task_down TurnError.
          call_llm: fn _c, _s, _r -> exit(:boom) end
      }

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: crash_handlers] ++ infra
        )

      assert {:error, %TurnError{type: :task_down, reason: :boom}} = AgentProcess.run(pid, "go")
      # GenServer survived the worker crash:
      assert %{agent_id: _} = AgentProcess.get_stats(pid)
    end

    defmodule ThrowingRegistry do
      def whereis(_handle, _sid), do: throw(:registry_gone)
    end

    test "a run worker that dies replies a :task_down TurnError without its stacktrace" do
      infra = Keyword.put(supplied_infra(), :registry, {ThrowingRegistry, nil})

      {:ok, pid} =
        AgentProcess.start_link([agent: server_config(), turn_engine: :server] ++ infra)

      # The worker's exit reason is {{:nocatch, :registry_gone}, stacktrace}.
      assert {:error, %TurnError{type: :task_down, reason: {:nocatch, :registry_gone}}} =
               AgentProcess.run(pid, "go")

      assert %{agent_id: _} = AgentProcess.get_stats(pid)
    end

    defmodule RaisingRegistry do
      def whereis(_handle, _sid), do: raise("registry bug")
    end

    defmodule LLMErrorRegistry do
      def whereis(_handle, _sid),
        do: raise(Normandy.LLMError.new(type: :overloaded, retryable?: true))
    end

    for {name, registry, expected} <- [
          {"a raised bug", RaisingRegistry,
           quote(do: %TurnError{type: :task_down, reason: %RuntimeError{message: "registry bug"}})},
          {"a raised domain exception", LLMErrorRegistry,
           quote(do: %Normandy.LLMError{type: :overloaded})},
          {"a throw", ThrowingRegistry,
           quote(do: %TurnError{type: :task_down, reason: {:nocatch, :registry_gone}})}
        ] do
      test "run/3 and cast/3 reply the same exception for #{name}" do
        infra = Keyword.put(supplied_infra(), :registry, {unquote(registry), nil})

        {:ok, pid} =
          AgentProcess.start_link([agent: server_config(), turn_engine: :server] ++ infra)

        assert {:error, unquote(expected) = sync} = AgentProcess.run(pid, "go")

        :ok = AgentProcess.cast(pid, "go", reply_to: self())
        assert_receive {:agent_result, _id, {:error, async}}, 2_000
        assert async == sync
      end
    end
  end

  describe ":server update_agent/2" do
    test "applies non-memory changes and discards memory mutations" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra
        )

      tampered =
        AgentMemory.add_message(
          AgentMemory.new_memory(),
          "user",
          "injected"
        )

      :ok =
        AgentProcess.update_agent(pid, fn a ->
          %{a | temperature: 0.42, memory: tampered}
        end)

      %{
        agent: agent,
        engine_state: %{session: %Normandy.Agents.Turn.Session{config: session_config}}
      } = :sys.get_state(pid)

      # The held session starts the next server with the updated config.
      assert session_config == agent
      # Non-memory change applied:
      assert agent.temperature == 0.42
      # Memory mutation discarded (still the empty template, not the injected one):
      assert AgentMemory.entry_chain(agent.memory) == []
    end

    # A template-backed session refuses a config without a credential provider
    # (Turn.Session.put_config/2 raises); the AgentProcess raises it in the caller and
    # keeps running with its config.
    test "a config without a credential provider is refused; the process lives" do
      creds = %Config{credential: {Normandy.Test.StubCreds, []}}
      {:ok, catalog} = Catalog.start_link([])

      {:ok, pid} =
        AgentProcess.start_link(
          [
            agent: server_config(%{behaviours: creds}),
            turn_engine: :server,
            template_provider: {Catalog, catalog}
          ] ++ supplied_infra()
        )

      assert_raise ArgumentError, ~r/:credential/, fn ->
        AgentProcess.update_agent(pid, fn a -> %{a | behaviours: nil} end)
      end

      assert Process.alive?(pid)
      assert %{agent: %{behaviours: ^creds}} = :sys.get_state(pid)
    end

    # The same refusal at start: start_link/1 raises it in the caller before any process
    # starts, never as an EXIT from init/1.
    test "start_link/1 refuses a template-backed config without a credential provider" do
      {:ok, catalog} = Catalog.start_link([])

      assert_raise ArgumentError, ~r/start_link\/1.*:credential/s, fn ->
        AgentProcess.start_link(
          [
            agent: server_config(%{behaviours: nil}),
            turn_engine: :server,
            template_provider: {Catalog, catalog}
          ] ++ supplied_infra()
        )
      end
    end
  end

  # An InMemory store whose history/2 exits or raises on demand (mode 1 or 2), like a
  # backend whose client call times out or whose connection errors.
  defmodule FaultyHistoryStore do
    @moduledoc false
    def new, do: {InMemory.new(), :atomics.new(1, [])}
    def fault({_mem, mode}, :exit), do: :atomics.put(mode, 1, 1)
    def fault({_mem, mode}, :raise), do: :atomics.put(mode, 1, 2)
    def fault({_mem, mode}, :none), do: :atomics.put(mode, 1, 0)

    def history({mem, mode}, sid) do
      case :atomics.get(mode, 1) do
        0 -> InMemory.history(mem, sid)
        1 -> exit(:timeout)
        2 -> raise RuntimeError, "connection refused"
      end
    end

    def append_entry({mem, _}, sid, entry), do: InMemory.append_entry(mem, sid, entry)
    def fork({mem, _}, sid, from), do: InMemory.fork(mem, sid, from)

    def save_turn_state({mem, _}, sid, s, inflight?),
      do: InMemory.save_turn_state(mem, sid, s, inflight?)

    def load_turn_state({mem, _}, sid), do: InMemory.load_turn_state(mem, sid)
    def save_config_template({mem, _}, sid, t), do: InMemory.save_config_template(mem, sid, t)
    def load_config_template({mem, _}, sid), do: InMemory.load_config_template(mem, sid)
    def list_resumable({mem, _}), do: InMemory.list_resumable(mem)
    def delete_session({mem, _}, sid), do: InMemory.delete_session(mem, sid)
  end

  describe ":server get_agent/1 when the store's history call exits or raises" do
    for fault <- [:exit, :raise] do
      test "#{fault}: logs, returns the template and keeps the process" do
        {:ok, sup} = Normandy.Agents.Turn.Supervisor.start_link([])
        store = FaultyHistoryStore.new()

        {:ok, pid} =
          AgentProcess.start_link(
            agent: server_config(),
            agent_id: "faulty-#{unquote(fault)}",
            turn_engine: :server,
            handlers: final_handlers(),
            store: {FaultyHistoryStore, store},
            registry: {Native, Native.new()},
            supervisor: sup
          )

        FaultyHistoryStore.fault(store, unquote(fault))

        log =
          capture_log(fn -> assert %{memory: %AgentMemory{}} = AgentProcess.get_agent(pid) end)

        assert log =~ "AgentProcess faulty-#{unquote(fault)}: get_agent could not read store"

        assert Process.alive?(pid)
        FaultyHistoryStore.fault(store, :none)
        assert %{memory: %AgentMemory{}} = AgentProcess.get_agent(pid)
      end
    end
  end

  # Final review M-d: a stored history from_entries/1 refuses (here a snapshot version a
  # newer node wrote during a rolling deploy) must not crash the AgentProcess.
  describe ":server get_agent/1 on a history it cannot rebuild" do
    test "logs, returns the template and keeps the process" do
      infra = supplied_infra()
      {InMemory, store} = Keyword.fetch!(infra, :store)

      {:ok, pid} =
        AgentProcess.start_link(
          [
            agent: server_config(),
            agent_id: "v2",
            turn_engine: :server,
            handlers: final_handlers()
          ] ++
            infra
        )

      entry = %AgentMemory.Entry{
        id: "c1",
        turn_id: "t1",
        role: "compaction",
        content: %{version: 2, entries: []}
      }

      {:ok, _} = InMemory.append_entry(store, "v2", entry)

      log = capture_log(fn -> assert %{memory: %AgentMemory{}} = AgentProcess.get_agent(pid) end)

      assert log =~
               "AgentProcess v2: get_agent could not rebuild the stored history: " <>
                 ~s|AgentMemory.from_entries/1: compaction entry "c1" has snapshot version 2|

      assert Process.alive?(pid)
      assert %{agent_id: "v2"} = AgentProcess.get_stats(pid)
    end
  end
end
