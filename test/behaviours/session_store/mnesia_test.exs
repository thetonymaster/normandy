defmodule Normandy.Behaviours.SessionStore.MnesiaTest do
  # async: false — Mnesia is node-global state; keep these serialized even though
  # each `new/0` makes uniquely-named tables.
  use ExUnit.Case, async: false

  # Reset Mnesia to a pristine state BEFORE each test (and therefore before the
  # SessionStoreContract setup that calls `new/0`). This guards against a subtle
  # test-isolation hazard: when the full suite is run with `--include distributed`,
  # one of the earlier distributed tests calls `:net_kernel.start/1`, which makes
  # this BEAM node distributed (node name changes from `:nonode@nohost` to e.g.
  # `primary@127.0.0.1`). Mnesia's in-memory schema still records `:nonode@nohost`
  # as a db_node. Any subsequent `create_table` call triggers a schema_transaction
  # that tries to coordinate with ALL db_nodes — including the now-unreachable
  # phantom `:nonode@nohost` — and hangs indefinitely.
  #
  # Fix: stop Mnesia, delete the stale schema (which removes `:nonode@nohost` from
  # db_nodes), then restart. After restart Mnesia re-initialises under the current
  # node name, so schema_transaction no longer waits for a phantom node.
  setup do
    :mnesia.stop()
    :mnesia.delete_schema([node()])
    :ok = :mnesia.start()

    on_exit(fn -> :mnesia.stop() end)
  end

  use Normandy.SessionStoreContract, impl: Normandy.Behaviours.SessionStore.Mnesia
end

defmodule Normandy.Behaviours.SessionStore.MnesiaBackendErrorTest do
  # async: false — Mnesia is node-global state.
  use ExUnit.Case, async: false

  alias Normandy.Behaviours.SessionStore.Mnesia

  setup do
    :mnesia.stop()
    :mnesia.delete_schema([node()])
    :ok = :mnesia.start()
    on_exit(fn -> :mnesia.stop() end)
  end

  # A handle whose table does not exist makes every transaction abort, the way
  # a table that is not loaded yet after a restart does.
  defp missing_table_handle, do: %{Mnesia.new() | sessions: :normandy_missing_table}

  test "load_turn_state reports an aborted transaction as {:error, reason}" do
    assert {:error, {:no_exists, :normandy_missing_table}} =
             Mnesia.load_turn_state(missing_table_handle(), "s1")
  end

  test "load_config_template reports an aborted transaction as {:error, reason}" do
    assert {:error, {:no_exists, :normandy_missing_table}} =
             Mnesia.load_config_template(missing_table_handle(), "s1")
  end

  test "a session with no saved state is still :error" do
    store = Mnesia.new()
    assert :error = Mnesia.load_turn_state(store, "unknown")
    assert :error = Mnesia.load_config_template(store, "unknown")
  end
end
