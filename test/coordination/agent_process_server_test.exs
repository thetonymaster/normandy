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
      Process.sleep(20)
      refute Enum.any?(owned, &Process.alive?/1)
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

      # GenServer is responsive while the turn is parked.
      t0 = System.monotonic_time(:millisecond)
      stats = AgentProcess.get_stats(pid)
      assert System.monotonic_time(:millisecond) - t0 < 50
      assert stats.agent_id == "approval-rt"

      :ok = AgentProcess.approve(pid, %{"pk1" => :approve})
      assert_receive {:result, {:ok, %Resp{content: "done"}}}, 2_000
    end
  end
end
