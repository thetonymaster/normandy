defmodule Normandy.Tools.MemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Tools.{BaseTool, Context, Memory}

  defp tool(opts \\ []), do: Memory.new(Keyword.merge([store: {InMemory, InMemory.new()}], opts))

  describe "new/1" do
    test "defaults" do
      t = tool()

      assert %Memory{
               namespace_key: :memory_namespace,
               mounts: %{},
               max_document_bytes: 100_000,
               max_view_chars: 16_000,
               max_cas_retries: 3,
               telemetry_include_paths: false
             } = t
    end

    test "raises on each malformed option, naming it" do
      for {opts, pattern} <- [
            {[], ~r/:store is required/},
            {[store: :nope], ~r/:store must be \{module, handle\}/},
            {[store: {String, nil}], ~r/does not implement Normandy.Behaviours.MemoryStore/},
            {[store: {InMemory, nil}, bogus: 1], ~r/unknown option :bogus/},
            {[store: {InMemory, nil}, mounts: %{"/etc" => {"n", :read_only}}], ~r/:mounts/},
            {[store: {InMemory, nil}, mounts: %{"/memories" => {"n", :read_only}}], ~r/:mounts/},
            {[store: {InMemory, nil}, mounts: %{"/memories/o" => {"", :read_only}}], ~r/:mounts/},
            {[store: {InMemory, nil}, mounts: %{"/memories/o" => {"n", :rw}}], ~r/:mounts/},
            {[store: {InMemory, nil}, max_document_bytes: 0], ~r/:max_document_bytes/},
            {[store: {InMemory, nil}, max_cas_retries: -1], ~r/:max_cas_retries/},
            {[store: {InMemory, nil}, namespace_key: "k"], ~r/:namespace_key/}
          ] do
        assert_raise ArgumentError, pattern, fn -> Memory.new(opts) end
      end
    end

    test "a mount key must round-trip through Paths.validate exactly" do
      # "/memories/" validates to "/memories" but resolve/3 would never match it.
      for key <- ["/memories/", "/memories/o/"] do
        assert_raise ArgumentError, ~r/:mounts/, fn ->
          Memory.new(store: {InMemory, nil}, mounts: %{key => {"n", :read_write}})
        end
      end

      assert %Memory{} =
               Memory.new(store: {InMemory, nil}, mounts: %{"/memories/o" => {"n", :read_write}})
    end
  end

  test "BaseTool: name, schema, description, and run/1 without context is an error" do
    t = tool(mounts: %{"/memories/org" => {"acme/kb", :read_only}})
    assert BaseTool.tool_name(t) == "memory"

    assert %{required: ["command"], properties: %{command: %{enum: enum}}} =
             BaseTool.input_schema(t)

    assert enum == ~w(view create str_replace insert delete rename)

    assert BaseTool.tool_description(t) =~
             "ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE"

    assert BaseTool.tool_description(t) =~ "/memories/org (read-only)"
    assert {:error, "memory requires tool context" <> _} = BaseTool.run(t)
  end

  test "prepare_input/2 fills only :command; model input cannot set store, mounts or limits (Review Focus #5)" do
    t = tool()

    prepared =
      Memory.prepare_input(t, %{
        "command" => "view",
        "path" => "/memories",
        "store" => {Evil, :x},
        "mounts" => %{"/memories/x" => {"other", :read_write}},
        "max_document_bytes" => 1,
        :namespace_key => :other
      })

    assert prepared.store == t.store
    assert prepared.mounts == %{}
    assert prepared.max_document_bytes == 100_000
    assert prepared.namespace_key == :memory_namespace
    assert prepared.command.command == "view"
    assert prepared.command.path == "/memories"
    assert prepared.command.file_text == nil
  end

  test "a missing namespace raises, naming the key and the keys present" do
    t = Memory.prepare_input(tool(), %{"command" => "view", "path" => "/memories"})

    assert_raise ArgumentError, ~r/tool_context\[:memory_namespace\].*\[:tenant\]/, fn ->
      Memory.run(t, %Context{tool_call_id: "c", values: %{tenant: "acme"}})
    end
  end
end
