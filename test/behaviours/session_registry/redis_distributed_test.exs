defmodule Normandy.Behaviours.SessionRegistry.RedisDistributedTest do
  use ExUnit.Case, async: false
  # Needs BOTH a reachable Redis and a second node.
  @moduletag :distributed
  @moduletag :redis

  alias Normandy.Behaviours.SessionRegistry.Redis, as: Reg
  alias Normandy.ClusterCase

  setup do
    unless Node.alive?(), do: :ok = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    url = Application.get_env(:normandy, :redis_url, "redis://localhost:6379")
    ns = "reg_dist_#{System.unique_integer([:positive])}"
    {:ok, url: url, ns: ns}
  end

  test "whereis on node A returns a pid registered by a process on node B", %{url: url, ns: ns} do
    # Use :peer.start/1 (UNLINKED) so the peer outlives the test process long enough
    # for the explicit on_exit cleanup to run cleanly. :peer.start_link/1 tears down
    # the peer when the test process exits — before on_exit fires — causing a crash.
    {:ok, peer, peer_node} =
      :peer.start(%{name: :reg_peer, host: ~c"127.0.0.1", longnames: true})

    on_exit(fn -> :peer.stop(peer) end)
    :rpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    # Owner on each node, same Redis + namespace (shared name table).
    # ClusterCase.start_redis_on_peer/2 prevents the rpc worker from killing the
    # GenServer on return (same unlinking pattern as start_horde_on_peer/2).
    {:ok, _} = Reg.start_link(name: :reg_a, url: url, namespace: ns)
    {:ok, _} = ClusterCase.start_redis_on_peer(peer_node, name: :reg_b, url: url, namespace: ns)

    # A long-lived process on the peer registers itself under "s1".
    # ClusterCase.spawn_redis_registered_on_peer/3 avoids closures that reference
    # the test module (test beams aren't in elixirc_paths, so peers can't load them).
    peer_pid = ClusterCase.spawn_redis_registered_on_peer(peer_node, :reg_b, "s1")

    # The primary's owner sees the peer's pid (cross-node, alive because peer is connected).
    assert wait_until(fn -> Reg.whereis(:reg_a, "s1") == {:ok, peer_pid} end)
  end

  test "concurrent register from two nodes yields exactly one winner", %{url: url, ns: ns} do
    # Use :peer.start/1 (UNLINKED) — same rationale as above.
    {:ok, peer, peer_node} =
      :peer.start(%{name: :reg_peer2, host: ~c"127.0.0.1", longnames: true})

    on_exit(fn -> :peer.stop(peer) end)
    :rpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    {:ok, _} = Reg.start_link(name: :reg_a, url: url, namespace: ns)
    {:ok, _} = ClusterCase.start_redis_on_peer(peer_node, name: :reg_b, url: url, namespace: ns)

    a = Reg.register(:reg_a, "race", self())
    b = :rpc.call(peer_node, Reg, :register, [:reg_b, "race", self_on_peer(peer_node)])

    assert Enum.sort([a, elem_tag(b)]) == [:ok, :taken]
  end

  defp self_on_peer(node), do: :rpc.call(node, :erlang, :self, [])
  defp elem_tag(:ok), do: :ok
  defp elem_tag({:error, :taken}), do: :taken

  defp wait_until(fun, retries \\ 200) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, retries - 1)
    end
  end
end
