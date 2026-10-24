defmodule Normandy.Tools.MemoryMountNamespaceTest do
  # SEC-7: a session whose namespace is a mount's namespace would write the mount's
  # documents with read-write access, past the mount's :read_only.
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{Context, Memory}

  defp call(tool, input, ns),
    do:
      Memory.run(tool, %Context{tool_call_id: "c", values: %{memory_namespace: ns}, input: input})

  setup do
    store = InMemory.new()
    {:ok, _} = InMemory.put(store, "acme/kb", "/memories/policy.md", "be kind", :new)

    tool =
      Memory.new(store: {InMemory, store}, mounts: %{"/memories/org" => {"acme/kb", :read_only}})

    {:ok, store: store, tool: tool}
  end

  test "a session namespace equal to a mount's is refused before any write", %{
    store: store,
    tool: tool
  } do
    error =
      assert_raise ArgumentError, fn ->
        call(
          tool,
          %{"command" => "create", "path" => "/memories/policy.md", "file_text" => "EVIL"},
          "acme/kb"
        )
      end

    assert error.message ==
             "memory tool: tool_context[:memory_namespace] equals the namespace of mount " <>
               "/memories/org; a session namespace must differ from every mount's"

    refute error.message =~ "acme/kb"

    assert {:ok, %{content: "be kind"}} = InMemory.get(store, "acme/kb", "/memories/policy.md")

    assert {:ok, view} =
             call(tool, %{"command" => "view", "path" => "/memories/org/policy.md"}, "acme/u")

    assert view =~ "be kind"
    refute view =~ "EVIL"
  end

  test "reads from that namespace are refused too, whatever the command", %{tool: tool} do
    assert_raise ArgumentError, ~r/equals the namespace of mount \/memories\/org/, fn ->
      call(tool, %{"command" => "view", "path" => "/memories"}, "acme/kb")
    end
  end

  test "another session namespace is unaffected", %{tool: tool} do
    assert {:ok, _} =
             call(
               tool,
               %{"command" => "create", "path" => "/memories/notes.md", "file_text" => "x"},
               "acme/u"
             )
  end

  test "through dispatch the model gets an error result naming the mount, not the namespace", %{
    tool: tool
  } do
    alias Normandy.Agents.Dispatch
    alias Normandy.Components.{ToolCall, ToolResult}
    alias Normandy.Tools.Toolset

    config = %{
      name: "a",
      toolset: Toolset.new([tool]),
      tool_context: %{memory_namespace: "acme/kb"}
    }

    call = %ToolCall{
      id: "m1",
      name: "memory",
      input: %{"command" => "view", "path" => "/memories"}
    }

    assert %ToolResult{is_error: true} =
             result = Dispatch.dispatch_one(config, call, Dispatch.default_pipeline())

    text = inspect(result.output)
    assert text =~ "equals the namespace of mount /memories/org"
    refute text =~ "acme/kb"
  end

  describe "when the agent is built" do
    alias Normandy.Agents.BaseAgent
    alias Normandy.Test.FakeClient
    alias Normandy.Tools.Toolset

    defp agent(opts),
      do: BaseAgent.init(Map.merge(%{client: FakeClient.new([]), model: "m"}, opts))

    test "init/1 refuses a session namespace equal to a mount's", %{tool: tool} do
      assert_raise ArgumentError, ~r/equals the namespace of mount \/memories\/org/, fn ->
        agent(%{toolset: Toolset.new([tool]), tool_context: %{memory_namespace: "acme/kb"}})
      end
    end

    test "register_tool/3 refuses it too", %{tool: tool} do
      config = agent(%{tool_context: %{memory_namespace: "acme/kb"}})

      assert_raise ArgumentError, ~r/equals the namespace of mount \/memories\/org/, fn ->
        BaseAgent.register_tool(config, tool)
      end
    end

    test "ConfigTemplate.rebuild/3 refuses it too", %{tool: tool} do
      alias Normandy.Agents.ConfigTemplate

      base = agent(%{tool_context: %{memory_namespace: "acme/kb"}})

      tmpl =
        base
        |> ConfigTemplate.from_config("k", :eager)
        |> put_in([:behaviours_refs, :credential], {Normandy.Test.StubCreds, []})

      supplement = %{
        toolset: Toolset.new([tool]),
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _ -> base.client end
      }

      assert_raise ArgumentError, ~r/equals the namespace of mount \/memories\/org/, fn ->
        ConfigTemplate.rebuild(tmpl, supplement, "token")
      end
    end

    test "another namespace, or none yet (supplied per call), is accepted", %{tool: tool} do
      for context <- [%{memory_namespace: "acme/u"}, %{}] do
        assert %{} = agent(%{toolset: Toolset.new([tool]), tool_context: context})
        assert %{} = BaseAgent.register_tool(agent(%{tool_context: context}), tool)
      end
    end
  end

  describe "new/1" do
    test "two mounts of one namespace with different access are refused" do
      error =
        assert_raise ArgumentError, fn ->
          Memory.new(
            store: {InMemory, nil},
            mounts: %{
              "/memories/kb" => {"acme/kb", :read_only},
              "/memories/kb-edit" => {"acme/kb", :read_write}
            }
          )
        end

      assert error.message ==
               "Normandy.Tools.Memory.new/1: :mounts /memories/kb and /memories/kb-edit share a " <>
                 "namespace with different access; give one namespace one access"
    end

    test "two read-only views of one namespace are allowed" do
      assert %Memory{} =
               Memory.new(
                 store: {InMemory, nil},
                 mounts: %{
                   "/memories/a" => {"acme/kb", :read_only},
                   "/memories/b" => {"acme/kb", :read_only}
                 }
               )
    end
  end
end
