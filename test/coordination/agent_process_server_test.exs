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
end
