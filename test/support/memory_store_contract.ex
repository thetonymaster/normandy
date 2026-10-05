defmodule Normandy.MemoryStoreContract do
  @moduledoc """
  Shared ExUnit contract for `Normandy.Behaviours.MemoryStore` impls:

      use Normandy.MemoryStoreContract, impl: Normandy.Behaviours.MemoryStore.InMemory

  The impl exports `new/0` returning the bare handle. Each test uses its own namespace,
  so impls with a shared backing store (Postgres, Redis) stay isolated.
  """

  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [impl: impl] do
      alias Normandy.Behaviours.MemoryStore
      alias Normandy.Tools.{Context, Memory}

      @store impl

      setup do
        {:ok, handle: @store.new(), ns: "contract-#{System.unique_integer([:positive])}"}
      end

      test "get on a missing document is :not_found", %{handle: h, ns: ns} do
        assert :not_found = @store.get(h, ns, "/memories/a.md")
      end

      test "put :new creates version 1; a second :new conflicts", %{handle: h, ns: ns} do
        assert {:ok, 1} = @store.put(h, ns, "/memories/a.md", "one", :new)
        assert {:error, :conflict} = @store.put(h, ns, "/memories/a.md", "two", :new)
        assert {:ok, %{content: "one", version: 1}} = @store.get(h, ns, "/memories/a.md")
      end

      test "put with the current version bumps it; a stale version conflicts", %{
        handle: h,
        ns: ns
      } do
        {:ok, 1} = @store.put(h, ns, "/memories/a.md", "one", :new)
        assert {:ok, 2} = @store.put(h, ns, "/memories/a.md", "two", 1)
        assert {:error, :conflict} = @store.put(h, ns, "/memories/a.md", "three", 1)
        assert {:ok, %{content: "two", version: 2}} = @store.get(h, ns, "/memories/a.md")
      end

      test "put with a version on a missing document conflicts", %{handle: h, ns: ns} do
        assert {:error, :conflict} = @store.put(h, ns, "/memories/a.md", "x", 3)
      end

      test "put :any creates or overwrites, bumping the version", %{handle: h, ns: ns} do
        assert {:ok, 1} = @store.put(h, ns, "/memories/a.md", "one", :any)
        assert {:ok, 2} = @store.put(h, ns, "/memories/a.md", "two", :any)
      end

      test "content round-trips UTF-8 and newlines exactly", %{handle: h, ns: ns} do
        text = "línea 1\n日本語\n\nend\n"
        {:ok, _} = @store.put(h, ns, "/memories/u.md", text, :new)
        assert {:ok, %{content: ^text}} = @store.get(h, ns, "/memories/u.md")
      end

      test "list returns documents at or under the prefix, sorted, with sizes", %{
        handle: h,
        ns: ns
      } do
        {:ok, _} = @store.put(h, ns, "/memories/b/2.md", "22", :new)
        {:ok, _} = @store.put(h, ns, "/memories/b/1.md", "1", :new)
        {:ok, _} = @store.put(h, ns, "/memories/bb.md", "x", :new)
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "aaa", :new)

        assert {:ok, entries} = @store.list(h, ns, "/memories/b")

        assert Enum.map(entries, &{&1.path, &1.size}) == [
                 {"/memories/b/1.md", 1},
                 {"/memories/b/2.md", 2}
               ]

        assert Enum.all?(entries, &match?(%DateTime{}, &1.updated_at))

        assert {:ok, all} = @store.list(h, ns, "/memories")

        assert Enum.map(all, & &1.path) ==
                 ["/memories/a.md", "/memories/b/1.md", "/memories/b/2.md", "/memories/bb.md"]
      end

      test "list sorts in byte order, not by a locale collation", %{handle: h, ns: ns} do
        for p <- ["/memories/a/b", "/memories/a.md", "/memories/a-b", "/memories/B.md"] do
          {:ok, _} = @store.put(h, ns, p, "x", :new)
        end

        assert {:ok, all} = @store.list(h, ns, "/memories")

        assert Enum.map(all, & &1.path) ==
                 ["/memories/B.md", "/memories/a-b", "/memories/a.md", "/memories/a/b"]
      end

      test "list includes the prefix itself when it is a document", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a", "file", :new)
        assert {:ok, [%{path: "/memories/a"}]} = @store.list(h, ns, "/memories/a")
      end

      test "updated_at moves forward on write", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/t.md", "1", :new)
        {:ok, [%{updated_at: t1}]} = @store.list(h, ns, "/memories/t.md")
        Process.sleep(5)
        {:ok, _} = @store.put(h, ns, "/memories/t.md", "2", :any)
        {:ok, [%{updated_at: t2}]} = @store.list(h, ns, "/memories/t.md")
        assert DateTime.compare(t2, t1) == :gt
      end

      test "list stops at list_limit/0 entries", %{handle: h, ns: ns} do
        limit = MemoryStore.list_limit()

        for i <- 1..(limit + 1) do
          {:ok, _} =
            @store.put(h, ns, "/memories/f#{String.pad_leading("#{i}", 5, "0")}", "x", :new)
        end

        assert {:ok, entries} = @store.list(h, ns, "/memories")
        assert length(entries) == limit
        # the limit applies after sorting: the first list_limit/0 paths in byte order
        assert hd(entries).path == "/memories/f00001"
        assert List.last(entries).path == "/memories/f01000"
      end

      test "namespaces are isolated", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "mine", :new)
        assert :not_found = @store.get(h, ns <> "-other", "/memories/a.md")
        assert {:ok, []} = @store.list(h, ns <> "-other", "/memories")
      end

      test "delete :any removes; a missing path is :not_found", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "x", :new)
        assert :ok = @store.delete(h, ns, "/memories/a.md", :any)
        assert :not_found = @store.delete(h, ns, "/memories/a.md", :any)
      end

      test "delete with a stale version conflicts and keeps the document", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "x", :new)
        {:ok, 2} = @store.put(h, ns, "/memories/a.md", "y", 1)
        assert {:error, :conflict} = @store.delete(h, ns, "/memories/a.md", 1)
        assert :ok = @store.delete(h, ns, "/memories/a.md", 2)
      end

      test "delete with a version on a missing document is :not_found", %{handle: h, ns: ns} do
        assert :not_found = @store.delete(h, ns, "/memories/a.md", 1)
      end

      test "delete_tree removes the prefix and everything under it", %{handle: h, ns: ns} do
        for p <- ["/memories/d", "/memories/d/1", "/memories/d/e/2", "/memories/dd"] do
          {:ok, _} = @store.put(h, ns, p, "x", :new)
        end

        assert {:ok, 3} = @store.delete_tree(h, ns, "/memories/d")
        assert {:ok, [%{path: "/memories/dd"}]} = @store.list(h, ns, "/memories")
        assert {:ok, 0} = @store.delete_tree(h, ns, "/memories/nothing")
      end

      test "rename moves a document and keeps its version", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a.md", "x", :new)
        {:ok, 2} = @store.put(h, ns, "/memories/a.md", "y", 1)
        assert {:ok, 1} = @store.rename(h, ns, "/memories/a.md", "/memories/b.md")
        assert :not_found = @store.get(h, ns, "/memories/a.md")
        assert {:ok, %{content: "y", version: 2}} = @store.get(h, ns, "/memories/b.md")
      end

      test "rename of a directory moves every document under it", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/d/1", "1", :new)
        {:ok, _} = @store.put(h, ns, "/memories/d/e/2", "2", :new)
        {:ok, _} = @store.put(h, ns, "/memories/dd", "keep", :new)

        assert {:ok, 2} = @store.rename(h, ns, "/memories/d", "/memories/z")
        assert {:ok, all} = @store.list(h, ns, "/memories")
        assert Enum.map(all, & &1.path) == ["/memories/dd", "/memories/z/1", "/memories/z/e/2"]
      end

      test "rename of a document that also has documents under it moves the document alone",
           %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/d", "doc", :new)
        {:ok, _} = @store.put(h, ns, "/memories/d/child", "kid", :new)

        assert {:ok, 1} = @store.rename(h, ns, "/memories/d", "/memories/e")
        assert {:ok, all} = @store.list(h, ns, "/memories")
        assert Enum.map(all, & &1.path) == ["/memories/d/child", "/memories/e"]
        assert {:ok, %{content: "doc"}} = @store.get(h, ns, "/memories/e")
      end

      test "rename onto an existing document or non-empty directory is {:error, :exists}", %{
        handle: h,
        ns: ns
      } do
        {:ok, _} = @store.put(h, ns, "/memories/a", "a", :new)
        {:ok, _} = @store.put(h, ns, "/memories/b", "b", :new)
        {:ok, _} = @store.put(h, ns, "/memories/dir/x", "x", :new)

        assert {:error, :exists} = @store.rename(h, ns, "/memories/a", "/memories/b")
        assert {:error, :exists} = @store.rename(h, ns, "/memories/a", "/memories/dir")
        assert {:ok, %{content: "a"}} = @store.get(h, ns, "/memories/a")
      end

      test "rename of a missing path is :not_found", %{handle: h, ns: ns} do
        assert :not_found = @store.rename(h, ns, "/memories/nope", "/memories/x")
      end

      test "delete_namespace removes everything and is idempotent", %{handle: h, ns: ns} do
        {:ok, _} = @store.put(h, ns, "/memories/a", "a", :new)
        {:ok, _} = @store.put(h, ns <> "-keep", "/memories/a", "a", :new)
        assert :ok = @store.delete_namespace(h, ns)
        assert {:ok, []} = @store.list(h, ns, "/memories")
        assert {:ok, [_]} = @store.list(h, ns <> "-keep", "/memories")
        assert :ok = @store.delete_namespace(h, "never-used")
      end

      # Review Focus #3: concurrent edits through the memory tool keep every edit.
      test "concurrent inserts through the memory tool lose no edit", %{handle: h, ns: ns} do
        tool = Memory.new(store: {@store, h}, max_cas_retries: 100)
        {:ok, _} = @store.put(h, ns, "/memories/log.md", "start", :new)
        ctx = %Context{tool_call_id: "c", values: %{memory_namespace: ns}}

        1..20
        |> Enum.map(fn i ->
          Task.async(fn ->
            input = %{
              "command" => "insert",
              "path" => "/memories/log.md",
              "insert_line" => 0,
              "insert_text" => "line-#{i}"
            }

            Memory.run(tool, %{ctx | input: input})
          end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))
        |> Enum.each(&assert({:ok, _} = &1))

        {:ok, %{content: content}} = @store.get(h, ns, "/memories/log.md")
        for i <- 1..20, do: assert(content =~ "line-#{i}\n", "lost line-#{i}")
        assert content |> String.split("\n") |> length() == 21
      end

      test "concurrent str_replaces through the memory tool lose no edit", %{handle: h, ns: ns} do
        tool = Memory.new(store: {@store, h}, max_cas_retries: 100)
        start = Enum.map_join(1..20, "\n", &"slot-#{&1}:todo")
        {:ok, _} = @store.put(h, ns, "/memories/slots.md", start, :new)
        ctx = %Context{tool_call_id: "c", values: %{memory_namespace: ns}}

        1..20
        |> Enum.map(fn i ->
          Task.async(fn ->
            input = %{
              "command" => "str_replace",
              "path" => "/memories/slots.md",
              "old_str" => "slot-#{i}:todo",
              "new_str" => "slot-#{i}:done"
            }

            Memory.run(tool, %{ctx | input: input})
          end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))
        |> Enum.each(&assert({:ok, _} = &1))

        {:ok, %{content: content}} = @store.get(h, ns, "/memories/slots.md")
        assert content == Enum.map_join(1..20, "\n", &"slot-#{&1}:done")
      end

      test "concurrent renames and writes leave no orphaned or duplicated document", %{
        handle: h,
        ns: ns
      } do
        {:ok, _} = @store.put(h, ns, "/memories/a/doc", "x", :new)

        tasks = [
          Task.async(fn -> @store.rename(h, ns, "/memories/a", "/memories/b") end),
          Task.async(fn -> @store.put(h, ns, "/memories/a/doc", "y", :any) end)
        ]

        Enum.each(tasks, &Task.await(&1, 5_000))
        {:ok, entries} = @store.list(h, ns, "/memories")

        outcome =
          Enum.map(entries, fn %{path: p} ->
            {:ok, %{content: c}} = @store.get(h, ns, p)
            {p, c}
          end)

        # put first then rename: one document, moved; rename first then put: both
        assert outcome in [
                 [{"/memories/a/doc", "y"}, {"/memories/b/doc", "x"}],
                 [{"/memories/b/doc", "y"}]
               ]
      end
    end
  end
end
