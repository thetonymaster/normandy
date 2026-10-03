defmodule Normandy.DSL.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{Memory, Registry}

  defmodule MemAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      memory(mounts: %{"/memories/org" => {"acme/kb", :read_only}})
    end
  end

  defmodule PlainAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
    end
  end

  defp client, do: %NormandyTest.Support.ModelMockup{}

  test "a declared memory is registered with the runtime store, and tool_context reaches the config" do
    store = {InMemory, InMemory.new()}

    {:ok, agent} =
      MemAgent.new(
        client: client(),
        memory_store: store,
        tool_context: %{memory_namespace: "acme/u-1"}
      )

    assert {:ok, %Memory{store: ^store, mounts: %{"/memories/org" => {"acme/kb", :read_only}}}} =
             Registry.get(agent.tool_registry, "memory")

    assert agent.tool_context == %{memory_namespace: "acme/u-1"}
  end

  test "declared memory without :memory_store raises, naming the option" do
    assert_raise ArgumentError, ~r/declares memory; pass memory_store: \{module, handle\}/, fn ->
      MemAgent.new(client: client())
    end
  end

  test ":memory_store on an agent without memory raises" do
    assert_raise ArgumentError, ~r/does not declare memory/, fn ->
      PlainAgent.new(client: client(), memory_store: {InMemory, InMemory.new()})
    end
  end

  test "a :store in the memory declaration fails to compile, naming memory_store:" do
    assert_raise ArgumentError, ~r/memory\/1 does not take :store; .*memory_store:/, fn ->
      Code.compile_string("""
      defmodule Normandy.DSL.AgentMemoryTest.StoreDeclared do
        use Normandy.DSL.Agent

        agent do
          model("claude-haiku-4-5-20251001")
          memory(store: {Normandy.Behaviours.MemoryStore.InMemory, :h})
        end
      end
      """)
    end
  end

  test "a non-literal declaration carrying :store raises from new/1" do
    assert_raise ArgumentError, ~r/does not take :store/, fn ->
      Normandy.DSL.Agent.memory_tool!(MemAgent, [store: :x], {InMemory, :h})
    end
  end
end
