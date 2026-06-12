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

      test "fork on an unknown entry errors", %{handle: h} do
        {:ok, _} = @store.append_entry(h, "s1", contract_entry("user", "a"))
        assert {:error, _} = @store.fork(h, "s1", "no-such-entry")
      end

      test "fork on an unknown session errors", %{handle: h} do
        assert {:error, _} = @store.fork(h, "no-such-session", "no-such-entry")
      end

      test "turn state round-trips an opaque term; missing is :error", %{handle: h} do
        term = {:turn, %{step: 3, calls: [:a, :b]}, "opaque"}
        assert :ok = @store.save_turn_state(h, "s1", term)
        assert {:ok, ^term} = @store.load_turn_state(h, "s1")
        assert :error = @store.load_turn_state(h, "never-saved")
      end

      test "implements the SessionStore behaviour" do
        behaviours = @store.module_info(:attributes)[:behaviour] || []
        assert Normandy.Behaviours.SessionStore in behaviours
      end
    end
  end
end
