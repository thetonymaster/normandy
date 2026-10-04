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

  describe "telemetry command metadata" do
    setup do
      test_pid = self()
      id = "memory-shell-tel-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          id,
          [[:normandy, :memory, :command, :start], [:normandy, :memory, :command, :stop]],
          &__MODULE__.forward/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    # Handlers run in the emitting process; ignore events from other async tests.
    def forward(event, _measurements, meta, test_pid) do
      if self() == test_pid, do: send(test_pid, {:tel, event, meta})
    end

    defp run_with(input) do
      t = Memory.prepare_input(tool(), input)
      Memory.run(t, %Context{tool_call_id: "c", values: %{memory_namespace: "acme/u"}})
    end

    test "a command outside the six names is reported as nil, never the model's value" do
      for bad <- ["rm -rf", String.duplicate("x", 500), %{"a" => 1}, 42] do
        run_with(%{"command" => bad, "path" => "/memories"})
        assert_receive {:tel, [:normandy, :memory, :command, :start], %{command: nil}}
        assert_receive {:tel, [:normandy, :memory, :command, :stop], %{command: nil}}
      end
    end

    test "a valid command name passes through" do
      run_with(%{"command" => "view", "path" => "/memories"})
      assert_receive {:tel, [:normandy, :memory, :command, :start], %{command: "view"}}
      assert_receive {:tel, [:normandy, :memory, :command, :stop], %{command: "view"}}
    end
  end

  describe "commands" do
    alias Normandy.Behaviours.MemoryStore
    alias Normandy.Test.{ConflictStore, DownStore}
    alias Normandy.Tools.Memory.Commands

    setup do
      store = InMemory.new()
      {:ok, store: store, t: Memory.new(store: {InMemory, store})}
    end

    defp call(tool, input, ns \\ "acme/u-1"),
      do:
        Memory.run(
          Memory.prepare_input(tool, input),
          %Context{tool_call_id: "c", values: %{memory_namespace: ns}}
        )

    test "view of an empty root is a listing, not an error", %{t: t} do
      assert {:ok, "Here're the files and directories up to 2 levels deep in /memories" <> _} =
               call(t, %{"command" => "view", "path" => "/memories"})
    end

    test "create, view, and the exact strings", %{t: t} do
      assert {:ok, "File created successfully at: /memories/p.md"} =
               call(t, %{
                 "command" => "create",
                 "path" => "/memories/p.md",
                 "file_text" => "color: blue\n"
               })

      assert {:ok, "Here's the content of /memories/p.md with line numbers:\n     1\tcolor: blue"} =
               call(t, %{"command" => "view", "path" => "/memories/p.md"})

      assert {:ok, "File created successfully at: /memories/p.md"} =
               call(t, %{
                 "command" => "create",
                 "path" => "/memories/p.md",
                 "file_text" => "overwritten"
               })

      assert {:error, "The path /memories/nope does not exist. Please provide a valid path."} =
               call(t, %{"command" => "view", "path" => "/memories/nope"})
    end

    test "str_replace: success snippet, no match, multiple matches, missing file, delete by omitting new_str",
         %{t: t} do
      call(t, %{
        "command" => "create",
        "path" => "/memories/p.md",
        "file_text" => "a\ncolor: blue\nb\nx x"
      })

      assert {:ok, "The memory file has been edited.\n" <> snippet} =
               call(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/p.md",
                 "old_str" => "blue",
                 "new_str" => "green"
               })

      assert snippet =~ "     2\tcolor: green"

      assert {:error,
              "No replacement was performed, old_str `purple` did not appear verbatim in /memories/p.md."} =
               call(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/p.md",
                 "old_str" => "purple",
                 "new_str" => "x"
               })

      assert {:error,
              "No replacement was performed. Multiple occurrences of old_str `x` in lines: 4, 4. Please ensure it is unique"} =
               call(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/p.md",
                 "old_str" => "x",
                 "new_str" => "y"
               })

      assert {:error,
              "Error: The path /memories/q.md does not exist. Please provide a valid path."} =
               call(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/q.md",
                 "old_str" => "a",
                 "new_str" => "b"
               })

      assert {:ok, _} =
               call(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/p.md",
                 "old_str" => "a\n"
               })

      assert {:ok, view} = call(t, %{"command" => "view", "path" => "/memories/p.md"})
      assert view =~ "     1\tcolor: green"
    end

    test "insert: at the top, after a line, out of range, missing file", %{t: t} do
      call(t, %{"command" => "create", "path" => "/memories/todo", "file_text" => "one\ntwo"})

      assert {:ok, "The file /memories/todo has been edited."} =
               call(t, %{
                 "command" => "insert",
                 "path" => "/memories/todo",
                 "insert_line" => 0,
                 "insert_text" => "zero\n"
               })

      assert {:ok, "The file /memories/todo has been edited."} =
               call(t, %{
                 "command" => "insert",
                 "path" => "/memories/todo",
                 "insert_line" => 3,
                 "insert_text" => "three"
               })

      assert {:ok, view} = call(t, %{"command" => "view", "path" => "/memories/todo"})
      assert view =~ "     1\tzero\n     2\tone\n     3\ttwo\n     4\tthree"

      assert {:error,
              "Error: Invalid `insert_line` parameter: 9. It should be within the range of lines of the file: [0, 4]"} =
               call(t, %{
                 "command" => "insert",
                 "path" => "/memories/todo",
                 "insert_line" => 9,
                 "insert_text" => "x"
               })

      assert {:error, "Error: The path /memories/none does not exist"} =
               call(t, %{
                 "command" => "insert",
                 "path" => "/memories/none",
                 "insert_line" => 0,
                 "insert_text" => "x"
               })
    end

    test "insert: a trailing newline ends the last line, so the range matches what view shows", %{
      store: store,
      t: t
    } do
      call(t, %{"command" => "create", "path" => "/memories/n", "file_text" => "a\nb\n"})

      assert {:error,
              "Error: Invalid `insert_line` parameter: 3. It should be within the range of lines of the file: [0, 2]"} =
               call(t, %{
                 "command" => "insert",
                 "path" => "/memories/n",
                 "insert_line" => 3,
                 "insert_text" => "x"
               })

      assert {:ok, _} =
               call(t, %{
                 "command" => "insert",
                 "path" => "/memories/n",
                 "insert_line" => 2,
                 "insert_text" => "c"
               })

      assert {:ok, %{content: "a\nb\nc\n"}} = InMemory.get(store, "acme/u-1", "/memories/n")
    end

    test "delete: a file, a directory recursively, missing, and never the root", %{t: t} do
      for p <- ["/memories/a", "/memories/d/1", "/memories/d/e/2"],
          do: call(t, %{"command" => "create", "path" => p, "file_text" => "x"})

      assert {:ok, "Successfully deleted /memories/a"} =
               call(t, %{"command" => "delete", "path" => "/memories/a"})

      assert {:ok, "Successfully deleted /memories/d"} =
               call(t, %{"command" => "delete", "path" => "/memories/d"})

      assert {:error, "Error: The path /memories/d does not exist"} =
               call(t, %{"command" => "delete", "path" => "/memories/d"})

      assert {:error, "Error: cannot delete the /memories directory"} =
               call(t, %{"command" => "delete", "path" => "/memories"})
    end

    test "rename: a file, a directory, onto an existing path, missing, and never the root", %{
      t: t
    } do
      for p <- ["/memories/a", "/memories/b", "/memories/d/1"],
          do: call(t, %{"command" => "create", "path" => p, "file_text" => "x"})

      assert {:ok, "Successfully renamed /memories/a to /memories/c"} =
               call(t, %{
                 "command" => "rename",
                 "old_path" => "/memories/a",
                 "new_path" => "/memories/c"
               })

      assert {:ok, "Successfully renamed /memories/d to /memories/z"} =
               call(t, %{
                 "command" => "rename",
                 "old_path" => "/memories/d",
                 "new_path" => "/memories/z"
               })

      assert {:error, "Error: The destination /memories/b already exists"} =
               call(t, %{
                 "command" => "rename",
                 "old_path" => "/memories/c",
                 "new_path" => "/memories/b"
               })

      assert {:error, "Error: The path /memories/nope does not exist"} =
               call(t, %{
                 "command" => "rename",
                 "old_path" => "/memories/nope",
                 "new_path" => "/memories/x"
               })

      assert {:error, "Error: cannot rename the /memories directory"} =
               call(t, %{
                 "command" => "rename",
                 "old_path" => "/memories",
                 "new_path" => "/memories/x"
               })
    end

    test "invalid paths never reach the store (Review Focus #2)" do
      down = Memory.new(store: {DownStore, nil})
      bad = "/memories/../etc/passwd"
      msg = "Error: /memories/../etc/passwd has an empty, . or .. segment"

      for input <- [
            %{"command" => "view", "path" => bad},
            %{"command" => "create", "path" => bad, "file_text" => "x"},
            %{"command" => "str_replace", "path" => bad, "old_str" => "a", "new_str" => "b"},
            %{"command" => "insert", "path" => bad, "insert_line" => 0, "insert_text" => "x"},
            %{"command" => "delete", "path" => bad},
            %{"command" => "rename", "old_path" => bad, "new_path" => "/memories/x"},
            %{"command" => "rename", "old_path" => "/memories/x", "new_path" => bad}
          ] do
        assert {:error, ^msg} = call(down, input)
      end

      for input <- [
            %{"command" => "view", "path" => "relative"},
            %{"command" => "view", "path" => nil},
            %{"command" => "rename", "old_path" => "/memories/x"}
          ] do
        assert {:error, "Error: " <> _ = got} = call(down, input)
        refute got =~ "unavailable"
      end
    end

    test "unknown command and missing fields", %{t: t} do
      assert {:error, "Error: unknown command \"wipe\"" <> _} = call(t, %{"command" => "wipe"})

      assert {:error, "Error: `file_text` must be a UTF-8 string for /memories/a"} =
               call(t, %{"command" => "create", "path" => "/memories/a"})

      assert {:error, "Error: `file_text` must be a UTF-8 string for /memories/a"} =
               call(t, %{"command" => "create", "path" => "/memories/a", "file_text" => <<0xFF>>})

      assert {:error, "Error: `old_str` must not be empty"} =
               call(t, %{"command" => "str_replace", "path" => "/memories/a", "old_str" => ""})

      assert {:error, "Error: `insert_line` must be an integer"} =
               call(t, %{"command" => "insert", "path" => "/memories/a", "insert_text" => "x"})
    end

    test "namespaces are separate", %{t: t} do
      call(
        t,
        %{"command" => "create", "path" => "/memories/a", "file_text" => "mine"},
        "acme/u-1"
      )

      assert {:error, "The path /memories/a does not exist" <> _} =
               call(t, %{"command" => "view", "path" => "/memories/a"}, "acme/u-2")
    end

    test "mounts: read through, writes to a read-only mount refused, no rename across mounts", %{
      store: store
    } do
      {:ok, _} = InMemory.put(store, "acme/kb", "/memories/policy.md", "be kind", :new)

      t =
        Memory.new(
          store: {InMemory, store},
          mounts: %{"/memories/org" => {"acme/kb", :read_only}}
        )

      assert {:ok, view} = call(t, %{"command" => "view", "path" => "/memories/org/policy.md"})
      assert view =~ "Here's the content of /memories/org/policy.md"
      assert {:ok, listing} = call(t, %{"command" => "view", "path" => "/memories/org"})
      assert listing =~ "\t/memories/org/policy.md"

      assert {:error, "Error: /memories/org/policy.md is read-only"} =
               call(t, %{
                 "command" => "create",
                 "path" => "/memories/org/policy.md",
                 "file_text" => "x"
               })

      rw =
        Memory.new(
          store: {InMemory, store},
          mounts: %{"/memories/team" => {"acme/team", :read_write}}
        )

      call(rw, %{"command" => "create", "path" => "/memories/mine", "file_text" => "x"})

      assert {:error, "Error: cannot rename across mounts"} =
               call(rw, %{
                 "command" => "rename",
                 "old_path" => "/memories/mine",
                 "new_path" => "/memories/team/mine"
               })
    end

    test "a document over max_document_bytes is refused", %{store: store} do
      t = Memory.new(store: {InMemory, store}, max_document_bytes: 10)

      assert {:error, "Error: /memories/big would be 11 bytes; the limit is 10"} =
               call(t, %{
                 "command" => "create",
                 "path" => "/memories/big",
                 "file_text" => String.duplicate("x", 11)
               })
    end

    test "a listing of list_limit/0 or more documents ends with a line saying it stopped", %{
      store: store,
      t: t
    } do
      limit = MemoryStore.list_limit()

      for i <- 1..limit,
          do:
            {:ok, _} =
              InMemory.put(
                store,
                "acme/u-1",
                "/memories/f#{String.pad_leading("#{i}", 5, "0")}",
                "x",
                :new
              )

      assert {:ok, listing} = call(t, %{"command" => "view", "path" => "/memories"})

      assert listing =~
               ~r/\n\(listing stopped at #{limit} files; view a subdirectory to see the rest\)\z/

      :ok = InMemory.delete(store, "acme/u-1", "/memories/f00001", :any)
      assert {:ok, short} = call(t, %{"command" => "view", "path" => "/memories"})
      refute short =~ "listing stopped"
    end

    test "compare-and-set gives up after max_cas_retries" do
      t = Memory.new(store: {ConflictStore, nil}, max_cas_retries: 2)

      assert {:error,
              "Error: /memories/a was changed by another writer 3 times while editing; view it and retry"} =
               call(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/a",
                 "old_str" => "alpha",
                 "new_str" => "x"
               })
    end

    test "a backend failure is reported as unavailable, never as missing (Review Focus #4)" do
      t = Memory.new(store: {DownStore, nil})

      for input <- [
            %{"command" => "view", "path" => "/memories/a"},
            %{"command" => "view", "path" => "/memories"},
            %{"command" => "create", "path" => "/memories/a", "file_text" => "x"},
            %{
              "command" => "str_replace",
              "path" => "/memories/a",
              "old_str" => "a",
              "new_str" => "b"
            },
            %{
              "command" => "insert",
              "path" => "/memories/a",
              "insert_line" => 0,
              "insert_text" => "x"
            },
            %{"command" => "delete", "path" => "/memories/a"},
            %{"command" => "rename", "old_path" => "/memories/a", "new_path" => "/memories/b"}
          ] do
        assert {:error, "Error: memory store unavailable: :timeout"} = call(t, input)
      end
    end

    test "a store that exits or raises is reported as unavailable with error_type :backend" do
      in_memory = InMemory.new()
      :ok = Agent.stop(in_memory)
      {ets_pid, _table} = ets = MemoryStore.ETS.new()
      :ok = GenServer.stop(ets_pid)

      # A dead Agent exits with :noproc; a dead ETS owner takes its table with it, so the
      # direct read raises ArgumentError.
      for {store, why} <- [
            {{InMemory, in_memory}, "{:exit, :noproc}"},
            {{MemoryStore.ETS, ets}, "{:exception, ArgumentError}"}
          ],
          input <- [
            %{"command" => "view", "path" => "/memories/a"},
            %{
              "command" => "str_replace",
              "path" => "/memories/a",
              "old_str" => "a",
              "new_str" => "b"
            }
          ] do
        t = Memory.prepare_input(Memory.new(store: store), input)
        text = "Error: memory store unavailable: " <> why

        assert {:error, :backend, ^text} = Commands.run(t, "acme/u-1")
        assert {:error, ^text} = call(Memory.new(store: store), input)
      end
    end
  end
end
