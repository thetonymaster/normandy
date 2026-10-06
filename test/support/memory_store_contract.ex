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

      describe "put/6 limits" do
        test "the byte and document limits count every document, past the list limit", %{
          handle: h,
          ns: ns
        } do
          limit = MemoryStore.list_limit()

          for i <- 1..(limit + 1) do
            path = "/memories/f#{String.pad_leading("#{i}", 5, "0")}"
            {:ok, 1} = @store.put(h, ns, path, "x", :new, max_documents: nil)
          end

          assert {:error, {:namespace_full, :bytes, 1002}} =
                   @store.put(h, ns, "/memories/g", "y", :new, max_bytes: limit + 1)

          assert {:error, {:namespace_full, :documents, 1002}} =
                   @store.put(h, ns, "/memories/g", "y", :new, max_documents: limit + 1)

          assert {:ok, 1} = @store.put(h, ns, "/memories/g", "y", :new, max_bytes: limit + 2)
        end

        test "a new document past the count is refused and not written; an overwrite is not", %{
          handle: h,
          ns: ns
        } do
          lim = [max_documents: 3]

          for p <- ~w(/memories/a /memories/b /memories/c),
              do: {:ok, 1} = @store.put(h, ns, p, "x", :new, lim)

          assert {:error, {:namespace_full, :documents, 4}} =
                   @store.put(h, ns, "/memories/d", "x", :any, lim)

          assert :not_found = @store.get(h, ns, "/memories/d")
          assert {:ok, 2} = @store.put(h, ns, "/memories/a", "xx", :any, lim)
          assert {:ok, 3} = @store.put(h, ns, "/memories/a", "xxx", 2, lim)
        end

        test "replacing a document counts its old size once", %{handle: h, ns: ns} do
          {:ok, 1} = @store.put(h, ns, "/memories/a", "123456", :new)
          assert {:ok, 2} = @store.put(h, ns, "/memories/a", "1234567890", :any, max_bytes: 10)

          assert {:error, {:namespace_full, :bytes, 11}} =
                   @store.put(h, ns, "/memories/a", "12345678901", 2, max_bytes: 10)

          assert {:ok, %{content: "1234567890", version: 2}} = @store.get(h, ns, "/memories/a")
        end

        test "a write that does not grow the namespace is allowed over a lowered limit", %{
          handle: h,
          ns: ns
        } do
          {:ok, 1} = @store.put(h, ns, "/memories/a", "1234567890", :new)
          {:ok, 1} = @store.put(h, ns, "/memories/b", "12345", :new)
          lim = [max_bytes: 5, max_documents: 1]

          assert {:ok, 2} = @store.put(h, ns, "/memories/a", "123", 1, lim)
          assert {:ok, 3} = @store.put(h, ns, "/memories/a", "123", :any, lim)

          assert {:error, {:namespace_full, :bytes, 9}} =
                   @store.put(h, ns, "/memories/a", "1234", 3, lim)

          assert {:error, {:namespace_full, :documents, 3}} =
                   @store.put(h, ns, "/memories/c", "", :new, lim)
        end

        test "bytes are checked before documents, and a version conflict before both", %{
          handle: h,
          ns: ns
        } do
          {:ok, 1} = @store.put(h, ns, "/memories/a", "12345", :new)
          lim = [max_bytes: 5, max_documents: 1]

          assert {:error, {:namespace_full, :bytes, 6}} =
                   @store.put(h, ns, "/memories/b", "1", :new, lim)

          assert {:error, :conflict} = @store.put(h, ns, "/memories/a", "123456", :new, lim)
          assert {:error, :conflict} = @store.put(h, ns, "/memories/a", "123456", 7, lim)
        end

        # Review Focus #5. On Postgres the sandbox serializes both writers on one
        # connection, so this proves the check, not row-lock contention.
        test "two writers that fit alone but not together: one succeeds, one is full", %{
          handle: h,
          ns: ns
        } do
          parent = self()

          tasks =
            for p <- ["/memories/x", "/memories/y"] do
              Task.async(fn ->
                send(parent, {:ready, self()})

                receive do
                  :go -> @store.put(h, ns, p, "123456", :new, max_bytes: 10)
                end
              end)
            end

          for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
          Enum.each(tasks, &send(&1.pid, :go))
          results = Enum.map(tasks, &Task.await(&1, 5_000))

          assert Enum.sort(results) == [{:error, {:namespace_full, :bytes, 12}}, {:ok, 1}]
          assert {:ok, [_one]} = @store.list(h, ns, "/memories")
        end

        test "delete, delete_tree, rename and delete_namespace keep the totals", %{
          handle: h,
          ns: ns
        } do
          lim = [max_bytes: 10, max_documents: 3]
          {:ok, 1} = @store.put(h, ns, "/memories/a", "12345", :new, lim)
          {:ok, 1} = @store.put(h, ns, "/memories/d/1", "12", :new, lim)
          {:ok, 1} = @store.put(h, ns, "/memories/d/2", "12", :new, lim)

          assert {:error, {:namespace_full, :documents, 4}} =
                   @store.put(h, ns, "/memories/b", "", :new, lim)

          assert :ok = @store.delete(h, ns, "/memories/a", :any)
          assert {:ok, 1} = @store.put(h, ns, "/memories/b", "123456", :new, lim)
          assert {:ok, 2} = @store.rename(h, ns, "/memories/d", "/memories/e")

          assert {:error, {:namespace_full, :bytes, 11}} =
                   @store.put(h, ns, "/memories/c", "1", :new, lim)

          assert {:ok, 2} = @store.delete_tree(h, ns, "/memories/e")
          assert {:ok, 1} = @store.put(h, ns, "/memories/c", "1234", :new, lim)
          assert :ok = @store.delete(h, ns, "/memories/c", 1)
          assert {:ok, 2} = @store.put(h, ns, "/memories/b", "1234567890", 1, lim)

          assert :ok = @store.delete_namespace(h, ns)
          assert {:ok, 1} = @store.put(h, ns, "/memories/z", "1234567890", :new, lim)
          assert {:ok, 1} = @store.put(h, ns, "/memories/y", "", :new, lim)
        end

        test "an unknown limit raises, naming put/6", %{handle: h, ns: ns} do
          assert_raise ArgumentError,
                       "#{inspect(@store)}.put/6: unknown option :max_byte; supported: :max_bytes, :max_documents",
                       fn -> @store.put(h, ns, "/memories/a", "x", :new, max_byte: 1) end
        end
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
