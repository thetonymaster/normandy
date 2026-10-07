defmodule Normandy.SessionStoreContract do
  @moduledoc """
  Shared ExUnit contract for `Normandy.Behaviours.SessionStore` impls.

  Use in a test module that also `use ExUnit.Case`:

      use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.InMemory

  The impl must export `new/0` (or `new/1` with all defaults) returning the bare
  handle (not `{:ok, handle}`), passable directly to the callbacks.
  """

  defmacro __using__(opts) do
    impl = Keyword.fetch!(opts, :impl)

    quote bind_quoted: [impl: impl] do
      alias Normandy.Components.AgentMemory.Entry

      @store impl

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

      test "implements the SessionStore behaviour" do
        behaviours = @store.module_info(:attributes)[:behaviour] || []
        assert Normandy.Behaviours.SessionStore in behaviours
      end
    end
  end
end
