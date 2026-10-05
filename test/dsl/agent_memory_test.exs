defmodule Normandy.DSL.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{BaseTool, Memory, Toolset}

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

  defmodule BadNamespaceKeyAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      memory(namespace_key: "not_an_atom")
    end
  end

  defmodule UnknownOptionAgent do
    use Normandy.DSL.Agent

    agent do
      model("claude-haiku-4-5-20251001")
      memory(bogus_option: 1)
    end
  end

  defp client, do: %NormandyTest.Support.ModelMockup{}

  test "a declared memory is registered with the runtime store, and tool_context reaches the config" do
    store = {InMemory, InMemory.new()}

    agent =
      MemAgent.new(
        client: client(),
        memory_store: store,
        tool_context: %{memory_namespace: "acme/u-1"}
      )

    assert {:ok, %Memory{store: ^store, mounts: %{"/memories/org" => {"acme/kb", :read_only}}}} =
             Toolset.fetch(agent.toolset, "memory")

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

  test "a bad memory option raises at new/1, not at compile time" do
    store = {InMemory, InMemory.new()}

    assert_raise ArgumentError, ~r/:namespace_key must be an atom, got: "not_an_atom"/, fn ->
      BadNamespaceKeyAgent.new(client: client(), memory_store: store)
    end
  end

  test "an unknown memory option raises at new/1" do
    store = {InMemory, InMemory.new()}

    assert_raise ArgumentError, ~r/unknown option :bogus_option; allowed: :store/, fn ->
      UnknownOptionAgent.new(client: client(), memory_store: store)
    end
  end

  test "a non-map tool_context raises through new/1" do
    store = {InMemory, InMemory.new()}

    assert_raise ArgumentError,
                 ~r/:tool_context option: expected a plain map \(not a struct\), got: a string \(4 bytes\)/,
                 fn ->
                   MemAgent.new(client: client(), memory_store: store, tool_context: "acme")
                 end
  end

  test "a plain agent has no memory tool; a memory agent's tool is named \"memory\"" do
    plain = PlainAgent.new(client: client())
    # no tool was registered, so the registry is never built
    assert plain.toolset == nil

    agent = MemAgent.new(client: client(), memory_store: {InMemory, InMemory.new()})
    assert {:ok, tool} = Toolset.fetch(agent.toolset, "memory")
    assert BaseTool.tool_name(tool) == "memory"
    assert "memory" in Toolset.list_names(agent.toolset)
  end
end
