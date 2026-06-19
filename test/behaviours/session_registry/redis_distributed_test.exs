defmodule Normandy.Behaviours.SessionRegistry.RedisDistributedTest do
  use ExUnit.Case, async: false
  # Needs BOTH a reachable Redis and a second node. Tagged ONLY :distributed (NOT
  # :redis): a :redis tag would make `mix test.redis` pull this in via ExUnit's
  # include-overrides-exclude rule, where the setup below starts distribution
  # mid-suite and corrupts unrelated tests. Run it with:
  #   elixir --name primary@127.0.0.1 -S mix test.redis <file> --include distributed
  @moduletag :distributed

  alias Normandy.Behaviours.SessionRegistry.Redis, as: Reg
  alias Normandy.ClusterCase

  setup do
    unless Node.alive?(), do: {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
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

    # Stable, long-lived owner pids on each node. A registrant dying triggers the
    # registry's DOWN cleanup, which releases the SET NX lock — so both owners must
    # outlive the register calls, else the second registration sees a freed lock and
    # also wins. (The previous peer pid was a transient rpc-worker, hence the spawn.)
    local_pid = spawn(fn -> Process.sleep(:infinity) end)
    peer_pid = :rpc.call(peer_node, :erlang, :spawn, [Process, :sleep, [:infinity]])
    on_exit(fn -> Process.exit(local_pid, :kill) end)

    # Fire both registrations concurrently so they genuinely contend for the
    # SET NX lock, rather than the local one always winning by completing first.
    local = Task.async(fn -> Reg.register(:reg_a, "race", local_pid) end)

    remote =
      Task.async(fn -> :rpc.call(peer_node, Reg, :register, [:reg_b, "race", peer_pid]) end)

    a = Task.await(local, 5_000)
    b = Task.await(remote, 5_000)

    assert Enum.sort([a, elem_tag(b)]) == [:ok, :taken]
  end

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
