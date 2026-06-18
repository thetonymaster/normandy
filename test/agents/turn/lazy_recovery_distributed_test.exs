defmodule Normandy.Agents.Turn.LazyRecoveryDistributedTest do
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed

  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  setup_all do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    end

    :ok
  end

  test "after the owning node dies, whereis returns :none (lazy-recovery precondition)" do
    reg = :"lazy_reg_#{System.unique_integer([:positive])}"
    {:ok, _} = HReg.start_link(name: reg)
    {peer, node} = start_peer(~c"lazypeer")
    {:ok, _} = start_horde_on_peer(node, name: reg)

    # Wait for Horde :auto membership to converge before registering.
    assert wait_until(fn ->
             members = Horde.Cluster.members(reg)
             Enum.any?(members, fn {_name, n} -> n == node end)
           end),
           "Horde membership did not converge in time"

    sid = "lazy-#{System.unique_integer([:positive])}"
    # Spawn a long-lived process on the peer that self-registers with Horde.
    # Horde.Registry.register/3 always registers self(), so registration must
    # happen inside the spawned process on the peer node.
    _remote = spawn_registered_on_peer(node, reg, sid)

    assert wait_until(fn -> match?({:ok, _}, HReg.whereis(reg, sid)) end),
           "registration did not propagate from peer in time"

    :peer.stop(peer)

    # Horde drops the registration when the owning node leaves the cluster.
    # This :none result is the lazy-recovery precondition: the next
    # Turn.Session.start_server/2 call hits :none and triggers rehydration.
    assert wait_until(fn -> HReg.whereis(reg, sid) == :none end, 300),
           "Horde did not drop the registration after peer stopped"
  end
end
