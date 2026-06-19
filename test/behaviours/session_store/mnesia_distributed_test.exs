defmodule Normandy.Behaviours.SessionStore.MnesiaDistributedTest do
  use ExUnit.Case, async: false
  @moduletag :distributed

  alias Normandy.Behaviours.SessionStore.Mnesia
  alias Normandy.Components.AgentMemory.Entry

  setup do
    # `:peer` requires this node to be alive (distributed). Tests are run with
    # `--name`/`--sname`; skip cleanly if not distributed.
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    end

    # Isolate Mnesia global state: stop any running instance (clearing all RAM
    # tables and schema locks left by previous tests) then start fresh before
    # we attempt to cluster with a peer.
    :mnesia.stop()
    :ok = :mnesia.start()

    on_exit(fn ->
      # Tear down Mnesia on exit so the next test (or next run) starts clean.
      :mnesia.stop()
    end)

    :ok
  end

  test "a session written on one node is replicated and readable on another" do
    {:ok, peer, peer_node} =
      :peer.start(%{name: :mnesia_peer, host: ~c"127.0.0.1", longnames: true})

    on_exit(fn -> :peer.stop(peer) end)

    # Ensure both nodes can load the module + mnesia.
    :ok = ensure_code(peer_node)

    nodes = [node(), peer_node]
    et = :"repl_entries_#{System.unique_integer([:positive])}"
    st = :"repl_sessions_#{System.unique_integer([:positive])}"

    # Cluster mnesia across both nodes, then create ram_copies replicas on both.
    # NOTE: :mnesia.start/0 returns :ok (not {:atomic, :ok}) — corrected from brief.
    :ok = :rpc.call(peer_node, :mnesia, :start, [])
    {:ok, _} = :mnesia.change_config(:extra_db_nodes, [peer_node])

    :ok = Mnesia.create_tables(entries: et, sessions: st, copies: :ram_copies, nodes: nodes)

    handle = %{entries: et, sessions: st}

    {:ok, _} =
      Mnesia.append_entry(handle, "s1", %Entry{turn_id: "t", role: "user", content: "hi"})

    # Read the same session through mnesia on the peer node.
    remote_history =
      :rpc.call(peer_node, Mnesia, :history, [handle, "s1"])

    assert {:ok, [%Entry{content: "hi"}]} = remote_history
  end

  defp ensure_code(peer_node) do
    # Make the peer load the same code paths as the primary.
    :rpc.call(peer_node, :code, :add_paths, [:code.get_path()])
    {:module, _} = :rpc.call(peer_node, :code, :ensure_loaded, [Mnesia])
    :ok
  end
end
