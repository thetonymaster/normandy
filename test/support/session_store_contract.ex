defmodule Normandy.SessionStoreContract do
  @moduledoc """
  Shared ExUnit contract for `Normandy.Behaviours.SessionStore` impls.

  Use in a test module that also `use ExUnit.Case`:

      use Normandy.SessionStoreContract,
        impl: Normandy.Behaviours.SessionStore.InMemory,
        stored_entry_ids: {__MODULE__, :stored_entry_ids}

  The impl must export `new/0` (or `new/1` with all defaults) returning the bare
  handle (not `{:ok, handle}`), passable directly to the callbacks.

  `:stored_entry_ids` names a public function of the test module that takes a handle and
  returns the ids of every entry the backend still stores, in any session (an entry with
  no `id` of its own counts under the id `history/2` returns for it). The delete rules
  use it to check that a deleted session's unshared entries are gone.
  """

  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)
    stored_entry_ids = Keyword.fetch!(opts, :stored_entry_ids)

    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [impl: impl, stored_entry_ids: stored_entry_ids] do
      alias Normandy.Components.AgentMemory.Entry

      @store impl
      @stored_entry_ids stored_entry_ids

      setup do
        {:ok, handle: @store.new()}
      end

      defp contract_entry(role, content), do: %Entry{turn_id: "t", role: role, content: content}

      test "append_entry returns an id; history is chronological", %{handle: h} do
        {:ok, id1} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        {:ok, id2} = @store.append_entry(h, "s1", contract_entry("assistant", "b"))

        assert is_binary(id1) and is_binary(id2)
        assert {:ok, entries} = @store.history(h, "s1")
        assert Enum.map(entries, & &1.content) == ["a", "b"]
      end

      test "history on an unknown session is empty", %{handle: h} do
        assert {:ok, []} = @store.history(h, "missing")
      end

      test "fork yields the ancestor chain and isolates appends", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        {:ok, at} = @store.append_entry(h, "s1", contract_entry("assistant", "b"))
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "c"))

        {:ok, forked} = @store.fork(h, "s1", at)
        assert {:ok, fe} = @store.history(h, forked)
        assert Enum.map(fe, & &1.content) == ["a", "b"]

        {:ok, _} = @store.append_entry(h, forked, contract_entry("assistant", "d"))
        assert {:ok, oe} = @store.history(h, "s1")
        assert Enum.map(oe, & &1.content) == ["a", "b", "c"]
        assert {:ok, fe2} = @store.history(h, forked)
        assert Enum.map(fe2, & &1.content) == ["a", "b", "d"]
      end

      # Turn.Server stores each compaction as a "compaction" entry whose content is the
      # conversation after it (Task 6.2g); AgentMemory.from_entries/1 applies the last one.
      test "a compaction snapshot round-trips in order, and a fork before it does not see it",
           %{handle: h} do
        alias Normandy.Components.AgentMemory

        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        {:ok, before} = @store.append_entry(h, "s1", contract_entry("assistant", "b"))

        snapshot = %{
          version: 1,
          entries: [%{id: "k1", turn_id: "t", role: "user", content: "summary of a and b"}]
        }

        {:ok, _} = @store.append_entry(h, "s1", contract_entry("compaction", snapshot))
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "c"))

        assert {:ok, entries} = @store.history(h, "s1")
        assert Enum.map(entries, & &1.role) == ["user", "assistant", "compaction", "user"]
        assert Enum.at(entries, 2).content == snapshot

        restored = entries |> AgentMemory.from_entries() |> AgentMemory.messages()
        assert Enum.map(restored, & &1.content) == ["summary of a and b", "c"]

        {:ok, forked} = @store.fork(h, "s1", before)
        assert {:ok, fe} = @store.history(h, forked)

        assert fe
               |> AgentMemory.from_entries()
               |> AgentMemory.messages()
               |> Enum.map(& &1.content) ==
                 ["a", "b"]
      end

      test "fork on an unknown entry errors", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        assert {:error, _} = @store.fork(h, "s1", "no-such-entry")
      end

      test "fork on an unknown session errors", %{handle: h} do
        assert {:error, _} = @store.fork(h, "no-such-session", "no-such-entry")
      end

      test "concurrent appends to one session do not lose entries", %{handle: h} do
        n = 200

        1..n
        |> Enum.map(fn i ->
          Task.async(fn -> @store.append_entry(h, "s1", contract_entry("user", i)) end)
        end)
        |> Enum.each(&Task.await(&1, 5000))

        assert {:ok, entries} = @store.history(h, "s1")
        assert length(entries) == n
      end

      test "turn state round-trips an opaque term; missing is :error", %{handle: h} do
        term = {:turn, %{step: 3, calls: [:a, :b]}, "opaque"}
        assert :ok = @store.save_turn_state(h, "s1", term, false)
        assert {:ok, ^term} = @store.load_turn_state(h, "s1")
        assert :error = @store.load_turn_state(h, "never-saved")
      end

      test "config template round-trips an opaque term; missing is :error", %{handle: h} do
        tmpl = %{template_id: "k", model: "m", behaviours_refs: %{policy: {Foo, []}}}
        assert :ok = @store.save_config_template(h, "s1", tmpl)
        assert {:ok, ^tmpl} = @store.load_config_template(h, "s1")

        # The template is an opaque term (behaviour: `term()`), not necessarily a map —
        # a backend must not assume map shape (e.g. Postgres mirroring resume_policy).
        opaque = {:opaque, [:not, :a, :map]}
        assert :ok = @store.save_config_template(h, "s2", opaque)
        assert {:ok, ^opaque} = @store.load_config_template(h, "s2")

        assert :error = @store.load_config_template(h, "never")
      end

      test "list_resumable lists the sessions whose last turn-state save was in flight",
           %{handle: h} do
        :ok = @store.save_turn_state(h, "parked", {:state, :awaiting_approval}, true)
        :ok = @store.save_turn_state(h, "steering", {:state, :steering}, true)
        :ok = @store.save_turn_state(h, "idle", {:state, :stopped}, false)

        assert {:ok, ids} = @store.list_resumable(h)
        assert Enum.sort(ids) == ["parked", "steering"]

        # The turn ends: the same write that saves the terminal state drops the session.
        :ok = @store.save_turn_state(h, "parked", {:state, :stopped}, false)
        assert {:ok, ["steering"]} = @store.list_resumable(h)

        # Saving it again in flight lists it again, once.
        :ok = @store.save_turn_state(h, "parked", {:state, :steering}, true)
        :ok = @store.save_turn_state(h, "parked", {:state, :steering}, true)
        assert {:ok, ids} = @store.list_resumable(h)
        assert Enum.sort(ids) == ["parked", "steering"]
      end

      test "an :eager config template does not list a session by itself", %{handle: h} do
        :ok = @store.save_config_template(h, "eager1", %{template_id: "k", resume_policy: :eager})
        assert {:ok, []} = @store.list_resumable(h)
      end

      defp contract_stored_ids(h) do
        {mod, fun} = @stored_entry_ids
        apply(mod, fun, [h])
      end

      # Entries with their own UUID ids, as Turn.Server writes them: every backend
      # returns that id (a Redis stream id is unique only within its stream).
      defp contract_entry_with_id(role, content),
        do: %{contract_entry(role, content) | id: UUID.uuid4()}

      test "delete_session removes the session; a second delete and a missing one are :ok",
           %{handle: h} do
        {:ok, _} = @store.append_entry(h, "doomed", contract_entry("user", "a"))
        :ok = @store.save_turn_state(h, "doomed", {:state, :steering}, true)
        :ok = @store.save_config_template(h, "doomed", %{template_id: "k", resume_policy: :eager})
        :ok = @store.save_turn_state(h, "kept", {:state, :steering}, true)

        assert :ok = @store.delete_session(h, "doomed")

        # The in-flight index shrinks: the reaper never sees a deleted session.
        assert {:ok, ["kept"]} = @store.list_resumable(h)
        assert {:ok, []} = @store.history(h, "doomed")
        assert :error = @store.load_turn_state(h, "doomed")
        assert :error = @store.load_config_template(h, "doomed")

        assert :ok = @store.delete_session(h, "doomed")
        assert :ok = @store.delete_session(h, "never-existed")
      end

      test "a deleted session's id starts a new history", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "reused", contract_entry("user", "old"))
        :ok = @store.delete_session(h, "reused")

        {:ok, _} = @store.append_entry(h, "reused", contract_entry("user", "new"))
        assert {:ok, [%{content: "new"}]} = @store.history(h, "reused")
      end

      # Review Focus 1: a compacted session, a fork from before its snapshot, then a
      # delete of the parent.
      test "deleting a fork's parent keeps the fork's history and drops the parent's own entries",
           %{handle: h} do
        {:ok, _} = @store.append_entry(h, "parent", contract_entry_with_id("user", "a"))
        {:ok, at} = @store.append_entry(h, "parent", contract_entry_with_id("assistant", "b"))
        {:ok, own} = @store.append_entry(h, "parent", contract_entry_with_id("user", "c"))

        snapshot = %{
          contract_entry_with_id("compaction", nil)
          | content: %{
              version: 1,
              entries: [%{id: "x", turn_id: "t", role: "user", content: "c"}]
            }
        }

        {:ok, snap} = @store.append_entry(h, "parent", snapshot)
        {:ok, forked} = @store.fork(h, "parent", at)

        assert :ok = @store.delete_session(h, "parent")

        assert {:ok, entries} = @store.history(h, forked)
        assert Enum.map(entries, & &1.content) == ["a", "b"]

        stored = contract_stored_ids(h)
        refute own in stored
        refute snap in stored
        assert Enum.all?(entries, &(&1.id in stored))
      end

      test "deleting a fork keeps its parent's history", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "parent", contract_entry_with_id("user", "a"))
        {:ok, at} = @store.append_entry(h, "parent", contract_entry_with_id("assistant", "b"))
        {:ok, _} = @store.append_entry(h, "parent", contract_entry_with_id("user", "c"))
        {:ok, forked} = @store.fork(h, "parent", at)
        {:ok, fork_own} = @store.append_entry(h, forked, contract_entry_with_id("assistant", "d"))

        assert :ok = @store.delete_session(h, forked)

        assert {:ok, entries} = @store.history(h, "parent")
        assert Enum.map(entries, & &1.content) == ["a", "b", "c"]
        refute fork_own in contract_stored_ids(h)
      end

      test "implements the SessionStore behaviour" do
        behaviours = @store.module_info(:attributes)[:behaviour] || []
        assert Normandy.Behaviours.SessionStore in behaviours
      end
    end
  end
end
