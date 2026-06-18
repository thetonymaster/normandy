defmodule Normandy.Agents.Turn.HordeDistributedTest do
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed

  alias Normandy.Behaviours.SessionRegistry.Horde, as: HordeReg

  # Use the atom directly to avoid the alias collision with HordeReg above.
  @horde_cluster :"Elixir.Horde.Cluster"

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    end

    :ok
  end

  test "a session registered on a peer is discoverable from this node" do
    reg = :"dist_reg_#{System.unique_integer([:positive])}"
    {:ok, _} = HordeReg.start_link(name: reg)
    {peer, node} = start_peer(~c"peer1")
    {:ok, _} = start_horde_on_peer(node, name: reg)

    # Wait for :auto membership to converge (both nodes see each other in Horde).
    assert eventually(fn ->
             members = @horde_cluster.members(reg)
             Enum.any?(members, fn {_name, n} -> n == node end)
           end),
           "Horde membership did not converge in time"

    sid = "cross-#{System.unique_integer([:positive])}"
    # Spawn a long-lived process on the peer that self-registers with Horde.
    # Horde.Registry.register/3 always registers self(), so registration must
    # happen from inside the spawned process, not via an erpc wrapper.
    remote = spawn_registered_on_peer(node, reg, sid)

    assert eventually(fn -> match?({:ok, ^remote}, HordeReg.whereis(reg, sid)) end),
           "cross-node whereis did not resolve in time"

    :peer.stop(peer)
  end

  test "double registration cluster-wide yields a single winner" do
    reg = :"dist_reg_#{System.unique_integer([:positive])}"
    {:ok, _} = HordeReg.start_link(name: reg)
    {peer, node} = start_peer(~c"peer2")
    {:ok, _} = start_horde_on_peer(node, name: reg)

    # Wait for :auto membership to converge before registering.
    assert eventually(fn ->
             members = @horde_cluster.members(reg)
             Enum.any?(members, fn {_name, n} -> n == node end)
           end),
           "Horde membership did not converge in time"

    sid = "dup-#{System.unique_integer([:positive])}"
    assert :ok = HordeReg.register(reg, sid, self())

    # Wait for the CRDT sync (sync_interval: 300ms) to propagate the registration
    # to the peer before attempting a duplicate registration there.
    assert eventually(fn ->
             case rpc(node, HordeReg, :whereis, [reg, sid]) do
               {:ok, _} -> true
               :none -> false
             end
           end),
           "registration did not propagate to peer in time"

    assert {:error, :taken} = rpc(node, HordeReg, :register, [reg, sid, self()])

    :peer.stop(peer)
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, retries - 1)
    end
  end
end
