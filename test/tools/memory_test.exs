defmodule Normandy.Tools.MemoryTest do
  use ExUnit.Case, async: true

  alias Normandy.Behaviours.MemoryStore.InMemory
  alias Normandy.Test.OwnLog
  alias Normandy.Tool
  alias Normandy.Tools.{Context, Input, Memory, Toolset}

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
            {[], ~r/required :store option/},
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

    test "accepts a map and names every unknown option under the Options prefix" do
      assert %Memory{max_cas_retries: 7} =
               Memory.new(%{store: {InMemory, nil}, max_cas_retries: 7})

      error =
        assert_raise ArgumentError, fn ->
          Memory.new(store: {InMemory, nil}, bogus: 1, other: 2)
        end

      assert error.message =~ "Normandy.Tools.Memory.new/1: unknown options [:bogus, :other]"
    end

    test "a malformed :store is not echoed" do
      error =
        assert_raise ArgumentError, fn ->
          Memory.new(store: {InMemory, "secret-conn-string"}, mounts: 1)
        end

      refute error.message =~ "secret-conn-string"

      error = assert_raise ArgumentError, fn -> Memory.new(store: [pw: "secret-conn-string"]) end
      refute error.message =~ "secret-conn-string"
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

  test "Normandy.Tool: name, input schema and description" do
    t = tool(mounts: %{"/memories/org" => {"acme/kb", :read_only}})
    assert Tool.name(t) == "memory"

    assert %{required: ["command"], properties: %{command: %{enum: enum}}} = Tool.input_schema(t)

    assert enum == ~w(view create str_replace insert delete rename)

    assert Tool.description(t) == """
           Persistent memory that survives across conversations, stored as files under /memories.
           At the start of a task, view /memories to pick up earlier progress. Record durable progress and decisions as you go; your context may be reset.
           Keep the directory organized: rename or delete files that are no longer relevant, and do not create new files unless necessary. Never store secrets.
           Commands: view (a directory listing or a file with line numbers), create (create or overwrite a file), str_replace, insert, delete (a file or a directory), rename (a file or a directory).
           Shared directories: /memories/org (read-only).\
           """

    # No shouted instructions (AX-16): no run of two all-caps words.
    refute Tool.description(t) =~ ~r/\b[A-Z]{2,}\b[ :]+\b[A-Z]{2,}\b/
  end

  test "model input naming the store, mounts or limits is refused before the tool runs (Review Focus #5)" do
    input = %{
      "command" => "view",
      "path" => "/memories",
      "store" => "evil",
      "mounts" => %{"/memories/x" => "other"},
      "max_document_bytes" => 1,
      "namespace_key" => "other"
    }

    assert {:error, [%{constraint: :unknown_keys, message: message}]} =
             Input.validate(tool(), input)

    assert message ==
             ~s(unknown keys "max_document_bytes", "mounts", "namespace_key", "store"; ) <>
               ~s(expected only "command", "file_text", "insert_line", "insert_text", ) <>
               ~s("new_path", "new_str", "old_path", "old_str", "path", "view_range")
  end

  test "command/1 takes only the command fields, string keys first" do
    cmd = Memory.command(%{"command" => "view", :command => "delete", "extra" => 1})

    assert Map.keys(cmd) |> Enum.sort() ==
             Enum.sort(
               ~w(command path view_range file_text old_str new_str insert_line insert_text old_path new_path)a
             )

    assert cmd.command == "view"
    assert cmd.file_text == nil
  end

  test "a missing namespace raises, naming the key and the keys present" do
    ctx = %Context{
      tool_call_id: "c",
      values: %{tenant: "acme"},
      input: %{"command" => "view", "path" => "/memories"}
    }

    assert_raise ArgumentError, ~r/tool_context\[:memory_namespace\].*\[:tenant\]/, fn ->
      Memory.run(tool(), ctx)
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
      Memory.run(tool(), %Context{
        tool_call_id: "c",
        values: %{memory_namespace: "acme/u"},
        input: input
      })
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
        Memory.run(tool, %Context{
          tool_call_id: "c",
          values: %{memory_namespace: ns},
          input: input
        })

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

    defp typed(tool, input, ns \\ "acme/u-1"),
      do: Commands.run(tool, Memory.command(input), ns)

    test "rename: a directory into its own subtree is refused and nothing moves", %{
      store: store,
      t: t
    } do
      call(t, %{"command" => "create", "path" => "/memories/a/c", "file_text" => "x"})

      for new <- ["/memories/a/b", "/memories/a/b/deeper", "/memories/a"] do
        assert {:error, :invalid_input,
                "Error: cannot rename /memories/a into its own subdirectory " <> ^new} =
                 typed(t, %{
                   "command" => "rename",
                   "old_path" => "/memories/a",
                   "new_path" => new
                 })
      end

      assert {:ok, %{content: "x"}} = InMemory.get(store, "acme/u-1", "/memories/a/c")
    end

    test "rename: a sibling that shares a prefix is not a subdirectory", %{store: store, t: t} do
      call(t, %{"command" => "create", "path" => "/memories/a/c", "file_text" => "x"})

      assert {:ok, "Successfully renamed /memories/a to /memories/ab"} =
               call(t, %{
                 "command" => "rename",
                 "old_path" => "/memories/a",
                 "new_path" => "/memories/ab"
               })

      assert {:ok, %{content: "x"}} = InMemory.get(store, "acme/u-1", "/memories/ab/c")
    end

    test "rename: a directory rename that pushes a child past 255 bytes is refused", %{
      store: store,
      t: t
    } do
      child = "/memories/a/" <> String.duplicate("x", 235)
      assert byte_size(child) == 247
      {:ok, _} = InMemory.put(store, "acme/u-1", child, "x", :new)
      new = "/memories/" <> String.duplicate("n", 12)
      offending = new <> "/" <> String.duplicate("x", 235)
      assert byte_size(offending) == 258

      assert {:error, :invalid_path, msg} =
               typed(t, %{"command" => "rename", "old_path" => "/memories/a", "new_path" => new})

      assert msg ==
               "Error: renaming /memories/a to #{new} would make #{offending} longer than 255 bytes"

      assert {:ok, %{content: "x"}} = InMemory.get(store, "acme/u-1", child)

      # Exactly 255 bytes still moves.
      ok_new = "/memories/" <> String.duplicate("n", 9)
      assert byte_size(ok_new <> "/" <> String.duplicate("x", 235)) == 255

      assert {:ok, _, _} =
               typed(t, %{
                 "command" => "rename",
                 "old_path" => "/memories/a",
                 "new_path" => ok_new
               })
    end

    @tag :capture_log
    test "rename: a list error while sizing a directory rename is a backend error" do
      t = Memory.new(store: {Normandy.Test.DirDownStore, nil})

      assert {:error, :backend, "Error: memory store unavailable: :timeout"} =
               typed(t, %{
                 "command" => "rename",
                 "old_path" => "/memories/a",
                 "new_path" => "/memories/b"
               })
    end

    test "create on a directory path is refused; overwriting a file still works", %{
      store: store,
      t: t
    } do
      call(t, %{"command" => "create", "path" => "/memories/a/c", "file_text" => "x"})

      assert {:error, :exists, "Error: /memories/a is a directory; choose a file path"} =
               typed(t, %{"command" => "create", "path" => "/memories/a", "file_text" => "y"})

      assert :not_found = InMemory.get(store, "acme/u-1", "/memories/a")

      # A sibling sharing the prefix is not a child.
      assert {:ok, _} =
               call(t, %{"command" => "create", "path" => "/memories/ab", "file_text" => "z"})

      # Overwriting a document that has no children keeps working.
      assert {:ok, _} =
               call(t, %{"command" => "create", "path" => "/memories/ab", "file_text" => "w"})

      assert {:ok, %{content: "w"}} = InMemory.get(store, "acme/u-1", "/memories/ab")
    end

    @tag :capture_log
    test "create: a list error while checking for a directory is a backend error" do
      t = Memory.new(store: {Normandy.Test.DirDownStore, nil})

      assert {:error, :backend, "Error: memory store unavailable: :timeout"} =
               typed(t, %{"command" => "create", "path" => "/memories/a", "file_text" => "y"})
    end

    @tag :capture_log
    test "view of a directory and delete of a directory report a failing list/delete_tree" do
      t = Memory.new(store: {Normandy.Test.DirDownStore, nil})

      for input <- [
            %{"command" => "view", "path" => "/memories/d"},
            %{"command" => "delete", "path" => "/memories/d"}
          ] do
        assert {:error, :backend, "Error: memory store unavailable: :timeout"} = typed(t, input)
      end
    end

    test "read-only mounts refuse every write command" do
      store = InMemory.new()

      t =
        Memory.new(
          store: {InMemory, store},
          mounts: %{"/memories/org" => {"acme/kb", :read_only}}
        )

      ro = "/memories/org/policy.md"
      msg = "Error: #{ro} is read-only"

      for input <- [
            %{"command" => "create", "path" => ro, "file_text" => "x"},
            %{"command" => "str_replace", "path" => ro, "old_str" => "a", "new_str" => "b"},
            %{"command" => "insert", "path" => ro, "insert_line" => 0, "insert_text" => "x"},
            %{"command" => "delete", "path" => ro},
            %{"command" => "rename", "old_path" => ro, "new_path" => "/memories/x"},
            %{"command" => "rename", "old_path" => "/memories/x", "new_path" => ro}
          ] do
        assert {:error, :read_only, ^msg} = typed(t, input), "for #{inspect(input)}"
      end
    end

    @tag :capture_log
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

    @tag :capture_log
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

    @tag :capture_log
    test "a store that exits or raises is reported as unavailable with error_type :backend" do
      in_memory = InMemory.new()
      :ok = Agent.stop(in_memory)
      {ets_pid, _table} = ets = MemoryStore.ETS.new()
      :ok = GenServer.stop(ets_pid)

      # A dead Agent exits with :noproc; a dead ETS owner takes its table with it, so the
      # direct read raises ArgumentError.
      for {store, why} <- [
            {{InMemory, in_memory}, "{:exit, :noproc}"},
            {{MemoryStore.ETS, ets}, "ArgumentError"}
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
        text = "Error: memory store unavailable: " <> why

        assert {:error, :backend, ^text} =
                 Commands.run(Memory.new(store: store), Memory.command(input), "acme/u-1")

        assert {:error, ^text} = call(Memory.new(store: store), input)
      end
    end
  end

  describe "deferred batch B" do
    import ExUnit.CaptureLog
    alias Normandy.Behaviours.MemoryStore

    alias Normandy.Test.{
      AncestorDownStore,
      CountingStore,
      FullListStore,
      RawErrorStore,
      RecordingStore
    }

    alias Normandy.Tools.Memory.Commands

    defp create_in(t, path, text, ns \\ "acme/u-1"),
      do: typed(t, %{"command" => "create", "path" => path, "file_text" => text}, ns)

    defp doc(store, ns, path) do
      case InMemory.get(store, ns, path) do
        {:ok, %{content: c}} -> c
        other -> other
      end
    end

    # B1
    test "max_namespace_bytes: default, nil, and bad values" do
      assert tool().max_namespace_bytes == 1_000_000
      assert tool(max_namespace_bytes: nil).max_namespace_bytes == nil
      assert tool(max_namespace_bytes: 5).max_namespace_bytes == 5

      for bad <- [0, -1, 1.5, "x"] do
        assert_raise ArgumentError, ~r/:max_namespace_bytes/, fn ->
          tool(max_namespace_bytes: bad)
        end
      end
    end

    test "a create that would exceed the namespace cap is refused and nothing is written" do
      store = InMemory.new()
      t = Memory.new(store: {InMemory, store}, max_namespace_bytes: 10)
      assert {:ok, _, _} = create_in(t, "/memories/a", "123456")

      assert {:error, :namespace_full,
              "Error: memory is full: writing /memories/b would bring it to 12 bytes; the limit is 10. Delete or shorten files first."} =
               create_in(t, "/memories/b", "123456")

      assert InMemory.get(store, "acme/u-1", "/memories/b") == :not_found
    end

    test "str_replace and insert that would exceed the cap are refused, the document is unchanged" do
      store = InMemory.new()
      t = Memory.new(store: {InMemory, store}, max_namespace_bytes: 10)
      create_in(t, "/memories/a", "12345")

      assert {:error, :namespace_full,
              "Error: memory is full: writing /memories/a would bring it to 13 bytes" <> _} =
               typed(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/a",
                 "old_str" => "5",
                 "new_str" => "123456789"
               })

      assert {:error, :namespace_full,
              "Error: memory is full: writing /memories/a would bring it to 12 bytes" <> _} =
               typed(t, %{
                 "command" => "insert",
                 "path" => "/memories/a",
                 "insert_line" => 0,
                 "insert_text" => "abcdef"
               })

      assert doc(store, "acme/u-1", "/memories/a") == "12345"
    end

    test "replacing a document does not count its old size twice" do
      store = InMemory.new()
      t = Memory.new(store: {InMemory, store}, max_namespace_bytes: 10)
      create_in(t, "/memories/a", "123456789")
      assert {:ok, _, _} = create_in(t, "/memories/a", "abcdefghij")
      assert doc(store, "acme/u-1", "/memories/a") == "abcdefghij"
    end

    test "the cap counts the mount's namespace for a mounted path" do
      store = InMemory.new()

      t =
        Memory.new(
          store: {InMemory, store},
          max_namespace_bytes: 10,
          mounts: %{"/memories/org" => {"acme/org", :read_write}}
        )

      # The session namespace is full, but the mount's is not.
      create_in(t, "/memories/own", "1234567890")
      assert {:ok, _, _} = create_in(t, "/memories/org/a", "123456")

      assert {:error, :namespace_full, "Error: memory is full: writing /memories/org/b" <> _} =
               create_in(t, "/memories/org/b", "123456")

      assert doc(store, "acme/org", "/memories/a") == "123456"
    end

    test "every write passes the tool's caps to the store, nil included" do
      t = Memory.new(store: {RecordingStore, self()}, max_namespace_bytes: nil)
      assert {:ok, _, _} = create_in(t, "/memories/a", String.duplicate("x", 5_000))
      assert_received {:call, :put, [max_bytes: nil, max_documents: 1000]}
      # the only list is not_directory's, at the document's own path: no cap listing
      assert_received {:call, :list}
      refute_received {:call, :list}

      t = Memory.new(store: {RecordingStore, self()}, max_namespace_documents: nil)
      assert {:ok, _, _} = create_in(t, "/memories/a", "x")
      assert_received {:call, :put, [max_bytes: 1_000_000, max_documents: nil]}
    end

    test "an edit passes the caps on every compare-and-set attempt and lists nothing" do
      t = Memory.new(store: {CountingStore, self()}, max_cas_retries: 2)

      assert {:error, :conflict_exhausted, _} =
               typed(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/a",
                 "old_str" => "alpha",
                 "new_str" => "beta"
               })

      for _attempt <- 1..3,
          do: assert_received({:put, [max_bytes: 1_000_000, max_documents: 1000]})

      refute_received {:put, _}
      refute_received :listed
    end

    test "max_namespace_documents: default, nil, and bad values" do
      assert tool().max_namespace_documents == 1000
      assert tool(max_namespace_documents: nil).max_namespace_documents == nil
      assert tool(max_namespace_documents: 5).max_namespace_documents == 5

      for bad <- [0, -1, 1.5, "x"] do
        assert_raise ArgumentError,
                     ~r/:max_namespace_documents/,
                     fn -> tool(max_namespace_documents: bad) end
      end
    end

    test "a create past the document cap is refused; overwriting a file is not" do
      store = InMemory.new()
      t = Memory.new(store: {InMemory, store}, max_namespace_documents: 2)
      assert {:ok, _, _} = create_in(t, "/memories/a", "1")
      assert {:ok, _, _} = create_in(t, "/memories/b", "2")

      assert {:error, :namespace_full,
              "Error: memory is full: creating /memories/c would make 3 files; the limit is 2. Delete files first."} =
               create_in(t, "/memories/c", "3")

      assert InMemory.get(store, "acme/u-1", "/memories/c") == :not_found
      assert {:ok, _, _} = create_in(t, "/memories/b", "two")
    end

    test "the caps are independent: no byte cap still counts documents, and the reverse" do
      store = InMemory.new()

      t =
        Memory.new(
          store: {InMemory, store},
          max_document_bytes: 2_000_000,
          max_namespace_bytes: nil,
          max_namespace_documents: 1
        )

      assert {:ok, _, _} = create_in(t, "/memories/a", String.duplicate("x", 2_000_000))

      assert {:error, :namespace_full, "Error: memory is full: creating /memories/b" <> _} =
               create_in(t, "/memories/b", "x")

      t = Memory.new(store: {InMemory, store}, max_namespace_documents: nil)

      assert {:error, :namespace_full,
              "Error: memory is full: writing /memories/c would bring it to 2000001 bytes; the limit is 1000000. Delete or shorten files first."} =
               create_in(t, "/memories/c", "x")
    end

    test "a namespace over a lowered cap can still be shortened, not grown" do
      store = InMemory.new()
      create_in(Memory.new(store: {InMemory, store}), "/memories/a", "1234567890")
      t = Memory.new(store: {InMemory, store}, max_namespace_bytes: 5)

      assert {:ok, _, _} =
               typed(t, %{
                 "command" => "str_replace",
                 "path" => "/memories/a",
                 "old_str" => "12345",
                 "new_str" => ""
               })

      assert doc(store, "acme/u-1", "/memories/a") == "67890"

      assert {:error, :namespace_full,
              "Error: memory is full: writing /memories/a would bring it to 6 bytes; the limit is 5. Delete or shorten files first."} =
               typed(t, %{
                 "command" => "insert",
                 "path" => "/memories/a",
                 "insert_line" => 0,
                 "insert_text" => ""
               })
    end

    # B2
    @tag :capture_log
    test "backend text for an exception struct names only the module, in the log too" do
      reason = %RuntimeError{message: "SELECT secret FROM keys WHERE id = 7"}
      t = Memory.new(store: {RawErrorStore, reason})

      log =
        OwnLog.capture(fn ->
          assert {:error, :backend, "Error: memory store unavailable: RuntimeError"} =
                   typed(t, %{"command" => "view", "path" => "/memories/a"})
        end)

      assert log =~ "memory store failure: RuntimeError"
      refute log =~ "SELECT"
    end

    @tag :capture_log
    test "a Postgrex.Error is its module and SQLSTATE name, never its query or detail" do
      reason = %Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          detail: "Key (path)=(/memories/secret-doc) already exists."
        },
        query: "INSERT INTO normandy_memory_documents VALUES ('secret-content')"
      }

      t = Memory.new(store: {RawErrorStore, reason})

      log =
        OwnLog.capture(fn ->
          assert {:error, :backend,
                  "Error: memory store unavailable: Postgrex.Error (:unique_violation)"} =
                   typed(t, %{"command" => "view", "path" => "/memories/a"})
        end)

      refute log =~ "secret"
      refute log =~ "INSERT"
    end

    @tag :capture_log
    test "backend text for the {:exception, mod} wrapper is the module name" do
      t = Memory.new(store: {RawErrorStore, {:exception, Postgrex.Error}})

      capture_log(fn ->
        assert {:error, :backend, "Error: memory store unavailable: Postgrex.Error"} =
                 typed(t, %{"command" => "view", "path" => "/memories/a"})
      end)
    end

    @tag :capture_log
    test "a reason with data is its tag; a reason of atoms and integers is shown whole" do
      long = String.duplicate("x", 500)

      log =
        capture_log(fn ->
          for {reason, text} <- [
                {long, "a string (500 bytes)"},
                {{:http_error, %{"token" => "sk-secret"}}, ":http_error"},
                {%{password: "pw"}, "a map"}
              ] do
            t = Memory.new(store: {RawErrorStore, reason})

            assert {:error, :backend, "Error: memory store unavailable: " <> ^text} =
                     typed(t, %{"command" => "view", "path" => "/memories/a"})
          end
        end)

      refute log =~ "xxxxx"
      refute log =~ "sk-secret"
      refute log =~ "pw"

      capture_log(fn ->
        for {reason, text} <- [
              {:timeout, ":timeout"},
              {{:exit, :noproc}, "{:exit, :noproc}"},
              {{:namespace_full, :bytes, 10}, "{:namespace_full, :bytes, 10}"}
            ] do
          t = Memory.new(store: {RawErrorStore, reason})

          assert {:error, :backend, "Error: memory store unavailable: " <> ^text} =
                   typed(t, %{"command" => "view", "path" => "/memories/a"})
        end
      end)
    end

    # B3
    test "telemetry :stop reports the mount's namespace when the path resolves into a mount" do
      id = "memory-ns-#{System.unique_integer([:positive])}"
      pid = self()

      :ok =
        :telemetry.attach(
          id,
          [:normandy, :memory, :command, :stop],
          &__MODULE__.forward_ns/4,
          pid
        )

      on_exit(fn -> :telemetry.detach(id) end)

      t =
        tool(
          telemetry_include_paths: true,
          mounts: %{"/memories/org" => {"acme/org", :read_write}}
        )

      call(t, %{"command" => "create", "path" => "/memories/org/a", "file_text" => "x"}, "acme/u")
      assert_receive {:stop, %{namespace: "acme/org", path: "/memories/org/a", status: :ok}}

      call(t, %{"command" => "create", "path" => "/memories/own", "file_text" => "x"}, "acme/u")
      assert_receive {:stop, %{namespace: "acme/u"}}

      call(
        t,
        %{
          "command" => "rename",
          "old_path" => "/memories/org/a",
          "new_path" => "/memories/org/b"
        },
        "acme/u"
      )

      assert_receive {:stop, %{namespace: "acme/org"}}

      call(t, %{"command" => "view", "path" => 5}, "acme/u")
      assert_receive {:stop, %{namespace: "acme/u", status: :error}}
    end

    def forward_ns(_event, _m, meta, pid), do: if(self() == pid, do: send(pid, {:stop, meta}))

    # B5
    test "rename to an equal or shorter path makes no get or list call" do
      t = Memory.new(store: {RecordingStore, self()})

      for {from, to} <- [{"/memories/abc", "/memories/xyz"}, {"/memories/abc", "/memories/x"}] do
        assert {:ok, _, _} =
                 typed(t, %{"command" => "rename", "old_path" => from, "new_path" => to})
      end

      refute_received {:call, _}
    end

    test "rename to a longer path past the list limit fails closed" do
      t = Memory.new(store: {FullListStore, nil})

      assert {:error, :invalid_path,
              "Error: /memories/a holds too many files to check that renaming it to /memories/abc keeps every path within 255 bytes; rename its subdirectories first"} =
               typed(t, %{
                 "command" => "rename",
                 "old_path" => "/memories/a",
                 "new_path" => "/memories/abc"
               })

      assert MemoryStore.list_limit() == 1000
    end

    # B6
    test "create under a path that is a file is refused" do
      store = InMemory.new()
      t = Memory.new(store: {InMemory, store})
      create_in(t, "/memories/a", "x")

      for path <- ["/memories/a/b", "/memories/a/b/c"] do
        assert {:error, :exists,
                "Error: /memories/a is a file; cannot create " <> ^path <> " under it"} =
                 create_in(t, path, "y")
      end

      assert InMemory.get(store, "acme/u-1", "/memories/a/b") == :not_found
    end

    test "create under a directory, and under a mount root, still works" do
      store = InMemory.new()

      t =
        Memory.new(
          store: {InMemory, store},
          mounts: %{"/memories/org" => {"acme/org", :read_write}}
        )

      create_in(t, "/memories/d/one", "x")
      assert {:ok, _, _} = create_in(t, "/memories/d/two", "y")
      assert {:ok, _, _} = create_in(t, "/memories/org/new", "z")
      create_in(t, "/memories/org/f", "x")

      assert {:error, :exists,
              "Error: /memories/org/f is a file; cannot create /memories/org/f/g under it"} =
               create_in(t, "/memories/org/f/g", "y")
    end

    @tag :capture_log
    test "an ancestor lookup failure goes through the backend mapping" do
      t = Memory.new(store: {AncestorDownStore, nil})

      assert {:error, :backend, "Error: memory store unavailable: :timeout"} =
               create_in(t, "/memories/a/b", "x")
    end

    test "a file at /memories/a does not block create under the sibling /memories/ab" do
      t = Memory.new(store: {InMemory, InMemory.new()})
      create_in(t, "/memories/a", "x")
      assert {:ok, _, _} = create_in(t, "/memories/ab/x", "y")
    end
  end

  # AX-15: the reference error string reaches the model as it is, not as
  # {"error": "Error: ..."}.
  test "a memory error is sent bare, with is_error, through Dispatch" do
    alias Normandy.Agents.Dispatch
    alias Normandy.Components.{BaseIOSchema, ToolCall, ToolResult}

    config = %{
      name: "a",
      toolset: Toolset.new([tool()]),
      tool_context: %{memory_namespace: "acme/u-1"}
    }

    call = %ToolCall{
      id: "m1",
      name: "memory",
      input: %{"command" => "str_replace", "path" => "/memories/x.md", "old_str" => "a"}
    }

    expected = "Error: The path /memories/x.md does not exist. Please provide a valid path."

    assert %ToolResult{is_error: true, output: ^expected} =
             result = Dispatch.dispatch_one(config, call)

    assert [%{content: ^expected, is_error: true}] = BaseIOSchema.to_json(result)
  end
end
