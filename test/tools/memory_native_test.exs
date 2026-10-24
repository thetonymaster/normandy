defmodule Normandy.Tools.MemoryNativeTest do
  @moduledoc """
  AX-33: `ClaudioAdapter` sends `Normandy.Tools.Memory` as Anthropic's native memory tool
  (`memory_20250818`), with no description or input schema; the model learns the mounts
  from a view of /memories.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Normandy.Agents.BaseAgent
  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Test.{ReturnTool, WireScript}
  alias Normandy.Tool
  alias Normandy.Tools.{Context, Memory, Toolset}

  defp memory(opts \\ []),
    do: Memory.new(Keyword.merge([store: {InMemory, InMemory.new()}], opts))

  defp wire_tools(tools, options \\ %{}) do
    client =
      WireScript.client([{:json, [%{"type" => "text", "text" => "ok"}], "end_turn"}], options)

    config =
      Enum.reduce(
        tools,
        BaseAgent.init(%{
          client: client,
          model: "claude-opus-5-5",
          tool_context: %{memory_namespace: "acme/u-1"}
        }),
        &BaseAgent.register_tool(&2, &1)
      )

    assert {:ok, _config, _answer} = BaseAgent.run(config, "hi")
    assert_receive {:wire_body, 0, %{"tools" => wire}}
    wire
  end

  test "Memory declares the native definition; other tools declare none" do
    assert Tool.native_definition(memory()) == %{type: "memory_20250818"}
    assert Tool.native_definition(%ReturnTool{}) == nil
  end

  test "to_tool_schemas/1 carries the native definition beside the custom one" do
    toolset = Toolset.new() |> Toolset.register(memory()) |> Toolset.register(%ReturnTool{})

    assert [big, mem] = Enum.sort_by(Toolset.to_tool_schemas(toolset), & &1.name)
    refute Map.has_key?(big, :native)
    assert %{name: "memory", native: %{type: "memory_20250818"}, input_schema: %{}} = mem
  end

  test "on the wire Memory is the native tool, a custom tool is unchanged" do
    wire = wire_tools([%ReturnTool{}, memory()], %{enable_caching: false})

    assert %{"type" => "memory_20250818", "name" => "memory"} = native = find(wire, "memory")
    refute Map.has_key?(native, "input_schema")
    refute Map.has_key?(native, "description")
    assert %{"input_schema" => _, "description" => _} = find(wire, "big")
  end

  test "the last tool keeps its cache breakpoint when it is the native one" do
    wire = wire_tools([%ReturnTool{}, memory()])

    assert %{"name" => "memory", "cache_control" => %{"type" => "ephemeral"}} = List.last(wire)
  end

  describe "a view of /memories names the mounts" do
    defp view(tool, path \\ "/memories"),
      do:
        Memory.run(tool, %Context{
          tool_call_id: "c",
          values: %{memory_namespace: "acme/u-1"},
          input: %{"command" => "view", "path" => path}
        })

    test "an empty root lists the shared directories and their access" do
      tool =
        memory(
          mounts: %{
            "/memories/org" => {"acme/kb", :read_only},
            "/memories/team" => {"acme/team", :read_write}
          }
        )

      assert {:ok, text} = view(tool)

      assert String.ends_with?(
               text,
               "\nShared directories: /memories/org (read-only), /memories/team (read-write)."
             )
    end

    test "a root with files lists them too" do
      tool = memory(mounts: %{"/memories/org" => {"acme/kb", :read_only}})

      assert {:ok, _} =
               Memory.run(tool, %Context{
                 tool_call_id: "c",
                 values: %{memory_namespace: "acme/u-1"},
                 input: %{"command" => "create", "path" => "/memories/a.md", "file_text" => "x"}
               })

      assert {:ok, text} = view(tool)
      assert text =~ "/memories/a.md"
      assert String.ends_with?(text, "\nShared directories: /memories/org (read-only).")
    end

    test "no mounts, or a view below the root, adds nothing" do
      assert {:ok, text} = view(memory())
      refute text =~ "Shared directories"

      tool = memory(mounts: %{"/memories/org" => {"acme/kb", :read_only}})
      assert {:ok, _} = view(tool, "/memories/org")
      refute elem(view(tool, "/memories/org"), 1) =~ "Shared directories"
    end
  end

  defp find(wire, name), do: Enum.find(wire, &(&1["name"] == name))
end
