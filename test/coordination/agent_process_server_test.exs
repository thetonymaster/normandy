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

  describe ":server infra ownership" do
    test "self-contained mode starts and owns store/registry/supervisor; stop tears them down" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent: server_config(),
          turn_engine: :server,
          handlers: final_handlers()
        )

      %{store: {_sm, store_h}, registry: {_rm, reg_name}, supervisor: sup, owned: owned} =
        :sys.get_state(pid)

      assert is_pid(store_h)
      assert is_atom(reg_name)
      assert is_pid(sup)
      assert owned != []
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
      Process.sleep(20)
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

      slow_handlers = %{
        BaseAgent.non_streaming_handlers()
        | call_llm: fn _c, _s, _r ->
            Process.sleep(500)
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

    test "unknown session returns {:error, :no_session}" do
      infra = supplied_infra()

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: final_handlers()] ++ infra
        )

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
      contents = Enum.map(Normandy.Components.AgentMemory.entry_chain(agent.memory), & &1.content)

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
    test ":server run/3 returns {:error, {:task_down, _}} when the turn worker crashes" do
      infra = supplied_infra()

      crash_handlers = %{
        BaseAgent.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> raise "boom" end
      }

      {:ok, pid} =
        AgentProcess.start_link(
          [agent: server_config(), turn_engine: :server, handlers: crash_handlers] ++ infra
        )

      assert {:error, {:task_down, _reason}} = AgentProcess.run(pid, "go")
      # GenServer survived the worker crash:
      assert %{agent_id: _} = AgentProcess.get_stats(pid)
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
        Normandy.Components.AgentMemory.add_message(
          Normandy.Components.AgentMemory.new_memory(),
          "user",
          "injected"
        )

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
end
