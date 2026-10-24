defmodule Normandy.Test.SessionStoreContract do
  @schema NimbleOptions.new!(
            impl: [
              type: :atom,
              required: true,
              doc: "The module implementing `Normandy.Behaviours.SessionStore`."
            ],
            new: [
              type: :mfa,
              doc:
                "`{module, function, args}` returning a fresh, empty handle, called once " <>
                  "per test. Default: `{impl, :new, []}`."
            ],
            stored_entry_ids: [
              type: {:or, [:mfa, nil]},
              default: nil,
              doc:
                "`{module, function, args}` called with the handle appended to `args`; it " <>
                  "returns the id of every entry the backend still stores, in any session " <>
                  "(an entry without an `id` of its own counts under the id `history/2` " <>
                  "returns for it). `nil` skips the storage-level delete checks."
            ]
          )

  @moduledoc """
  The ExUnit tests every `Normandy.Behaviours.SessionStore` implementation must pass.
  Normandy runs them against its own five backends; run them against yours.

      defmodule MyApp.SessionStoreTest do
        use ExUnit.Case, async: true

        use Normandy.Test.SessionStoreContract,
          impl: MyApp.SessionStore,
          new: {MyApp.SessionStore, :new, [[url: "..."]]}
      end

  Options, checked when the test module compiles (a bad one raises `ArgumentError`):

  #{Normandy.Options.docs(@schema)}

  Every test builds its handle with `:new` and needs it **empty**: tests use fixed
  session ids (`"s1"`, `"parked"`) and assert exact `list_resumable/1` results. A
  backend whose storage is shared between handles (a database, a node-global table)
  must give each handle its own namespace, or reset the storage in a `setup` placed
  before the `use` line, and its test module must be `async: false` when handles can
  see each other's data.

  The tests run real concurrency (200 `Task`s appending to one session, awaited for up
  to 5 s) and fork and delete sessions.

  With `:stored_entry_ids`, the two tests that delete a fork's parent or a fork also
  check that the deleted session's own entries are gone from storage; without it they
  check through the behaviour's callbacks only (`history/2` of the survivor).
  """

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts),
    do: Normandy.Options.validate!(opts, @schema, {__MODULE__, :__using__, 1})

  defmacro __using__(opts) do
    # credo:disable-for-next-line Credo.Check.Refactor.LongQuoteBlocks
    quote bind_quoted: [opts: opts, contract: __MODULE__] do
      alias Normandy.Components.AgentMemory.Entry

      contract_opts = contract.validate!(opts)
      @store Keyword.fetch!(contract_opts, :impl)
      @new_handle Keyword.get(contract_opts, :new) || {@store, :new, []}
      @stored_entry_ids Keyword.fetch!(contract_opts, :stored_entry_ids)

      setup do
        {mod, fun, args} = @new_handle
        {:ok, handle: apply(mod, fun, args)}
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

      # nil when the test module passed no :stored_entry_ids: the storage checks are skipped.
      defp contract_stored_ids(h) do
        case @stored_entry_ids do
          nil -> nil
          {mod, fun, args} -> apply(mod, fun, args ++ [h])
        end
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
        assert {:ok, []} = @store.history(h, "parent")

        assert {:ok, entries} = @store.history(h, forked)
        assert Enum.map(entries, & &1.content) == ["a", "b"]

        case contract_stored_ids(h) do
          nil ->
            :ok

          stored ->
            refute own in stored
            refute snap in stored
            assert Enum.all?(entries, &(&1.id in stored))
        end
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
        assert {:ok, []} = @store.history(h, forked)

        case contract_stored_ids(h) do
          nil -> :ok
          stored -> refute fork_own in stored
        end
      end

      defp contract_snapshot(contents) do
        %{
          contract_entry_with_id("compaction", nil)
          | content: %{
              version: 1,
              entries:
                Enum.map(contents, &%{id: UUID.uuid4(), turn_id: "t", role: "user", content: &1})
            }
        }
      end

      # What a restore reads (SessionStore.restore_history/3): the store's
      # history_since_compaction/2 when it exports one, else history/2. Either way it
      # rebuilds the same memory as the whole history.
      test "restore_history rebuilds the memory history/2 does, from the last snapshot on",
           %{handle: h} do
        alias Normandy.Behaviours.SessionStore
        alias Normandy.Components.AgentMemory

        since? =
          Code.ensure_loaded?(@store) and function_exported?(@store, :history_since_compaction, 2)

        rebuilt = fn entries -> entries |> AgentMemory.from_entries() |> AgentMemory.history() end

        assert {:ok, []} = SessionStore.restore_history(@store, h, "missing")

        {:ok, _} = @store.append_entry(h, "s1", contract_entry_with_id("user", "a"))
        {:ok, at} = @store.append_entry(h, "s1", contract_entry_with_id("assistant", "b"))
        assert SessionStore.restore_history(@store, h, "s1") == @store.history(h, "s1")

        {:ok, _} = @store.append_entry(h, "s1", contract_snapshot(["sum-1"]))
        {:ok, _} = @store.append_entry(h, "s1", contract_entry_with_id("user", "c"))
        {:ok, last} = @store.append_entry(h, "s1", contract_snapshot(["sum-1", "c"]))
        {:ok, _} = @store.append_entry(h, "s1", contract_entry_with_id("assistant", "d"))

        {:ok, full} = @store.history(h, "s1")
        assert {:ok, restored} = SessionStore.restore_history(@store, h, "s1")
        assert rebuilt.(restored) == rebuilt.(full)

        if since?,
          do: assert([%{id: ^last, role: "compaction"}, %{content: "d"}] = restored)

        # A fork from before the snapshots has none: its whole history.
        {:ok, forked} = @store.fork(h, "s1", at)
        assert SessionStore.restore_history(@store, h, forked) == @store.history(h, forked)
      end

      # An append with an explicit parent_id leaves the entries after that parent on a
      # branch the head no longer reaches: they are the session's too.
      test "deleting a session removes the branches its head left behind", %{handle: h} do
        {:ok, a} = @store.append_entry(h, "branched", contract_entry_with_id("user", "a"))
        {:ok, b} = @store.append_entry(h, "branched", contract_entry_with_id("assistant", "b"))

        {:ok, c} =
          @store.append_entry(h, "branched", %{
            contract_entry_with_id("assistant", "c")
            | parent_id: a
          })

        assert :ok = @store.delete_session(h, "branched")
        assert {:ok, []} = @store.history(h, "branched")

        case contract_stored_ids(h) do
          nil -> :ok
          stored -> assert Enum.filter([a, b, c], &(&1 in stored)) == []
        end
      end

      test "deleting a branched session keeps what a fork reaches and drops the rest",
           %{handle: h} do
        {:ok, a} = @store.append_entry(h, "branched", contract_entry_with_id("user", "a"))
        {:ok, b} = @store.append_entry(h, "branched", contract_entry_with_id("assistant", "b"))
        {:ok, forked} = @store.fork(h, "branched", a)

        {:ok, c} =
          @store.append_entry(h, "branched", %{
            contract_entry_with_id("assistant", "c")
            | parent_id: a
          })

        assert :ok = @store.delete_session(h, "branched")
        assert {:ok, [%{content: "a"}]} = @store.history(h, forked)

        case contract_stored_ids(h) do
          nil -> :ok
          stored -> assert Enum.filter([b, c], &(&1 in stored)) == []
        end
      end

      test "implements the SessionStore behaviour" do
        behaviours = @store.module_info(:attributes)[:behaviour] || []
        assert Normandy.Behaviours.SessionStore in behaviours
      end
    end
  end
end
