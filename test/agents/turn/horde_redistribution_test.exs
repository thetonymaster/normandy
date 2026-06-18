defmodule Normandy.Agents.Turn.HordeRedistributionTest do
  @moduledoc """
  Verifies Horde redistribution behaviour across node boundaries (design §7.6).

  ## Findings (Horde 0.10.0, members: :auto)

  With `members: :auto`, `Horde.NodeListener` responds to `:nodedown` by calling
  `Horde.Cluster.set_members/2` with the updated live-node list. `DynamicSupervisorImpl`
  drops the dead member's CRDT entries entirely rather than marking them `:dead`.
  Since the dead-node restart path in `update_process/2` requires `current_member.status
  == :dead`, no redistribution occurs: peer children simply disappear when the peer dies.
  This holds regardless of `restart: :transient` vs `restart: :temporary`.

  ## Design implication (§7.6 resolution)

  The `restart` field does NOT drive dead-node redistribution in `members: :auto`
  mode. Eager vs lazy selectivity CANNOT be implemented via `restart` on a single
  `Horde.DynamicSupervisor` with `:auto` membership. Two separate supervisors are
  required (or manual membership management with explicit `:dead` marking).
  """
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed

  setup_all do
    unless Node.alive?(), do: {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    :ok
  end

  @doc """
  Children placed directly on a peer's ProcessesSupervisor are NOT redistributed
  to the surviving primary node after the peer dies — regardless of `restart` type.

  This is the §7.6 verdict: `restart: :transient` does NOT cause eager redistribution
  on node-down with `members: :auto`; the `restart` field only governs local crash
  restarts within a single Horde.ProcessesSupervisor instance.
  """
  test "peer children are NOT redistributed on node-down regardless of restart type" do
    sup = :"redist_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Horde.DynamicSupervisor.start_link(name: sup, strategy: :one_for_one, members: :auto)

    {peer, node} = start_peer(~c"redistpeer")
    {:ok, _} = start_horde_dsup_on_peer(node, sup)

    assert wait_until(fn ->
             members = Horde.Cluster.members(sup)
             Enum.any?(members, fn {_name, n} -> n == node end)
           end),
           "Horde DynamicSupervisor membership did not converge"

    # Use Agent.start_link/3 (module/fun/args) to avoid anonymous closures that
    # encode the defining test module and cannot be deserialised on the peer.
    transient_spec = %{
      id: :t,
      start: {Agent, :start_link, [Normandy.ClusterCase, :agent_initial_state, []]},
      restart: :transient
    }

    temporary_spec = %{
      id: :p,
      start: {Agent, :start_link, [Normandy.ClusterCase, :agent_initial_state, []]},
      restart: :temporary
    }

    # Force both children onto the peer by starting them directly in the peer's
    # ProcessesSupervisor (bypassing Horde's consistent-hash placement).
    {:ok, t_pid} = start_child_on_peer(node, sup, transient_spec)
    {:ok, p_pid} = start_child_on_peer(node, sup, temporary_spec)
    assert node(t_pid) == node, "transient child must be on peer node"
    assert node(p_pid) == node, "temporary child must be on peer node"

    # Wait for CRDT sync before killing the peer.
    Process.sleep(500)
    primary_count_before = local_child_count(sup)

    :peer.stop(peer)

    # After the peer dies, children that were running on it do NOT appear on the
    # primary, regardless of restart: :transient or restart: :temporary.
    # The primary's own local count must stay stable (no redistribution occurs).
    assert wait_until(fn -> local_child_count(sup) == primary_count_before end, 300),
           "expected no new children on primary after peer stop " <>
             "(neither :transient nor :temporary causes redistribution in members: :auto)"

    # Both peer pids are gone — `Process.alive?/1` raises ArgumentError for
    # pids on a disconnected node, so we check via :rpc instead.
    refute peer_alive?(t_pid), "transient child pid on dead peer should not be alive"
    refute peer_alive?(p_pid), "temporary child pid on dead peer should not be alive"
  end

  # Count children running locally on THIS node by querying the local ProcessesSupervisor.
  defp local_child_count(sup_name) do
    local_processes_sup = :"#{sup_name}.ProcessesSupervisor"

    try do
      Horde.ProcessesSupervisor.which_children(local_processes_sup) |> length()
    catch
      :exit, _ -> 0
    end
  end

  # Safe check: a pid on a disconnected node raises ArgumentError in Process.alive?/1.
  defp peer_alive?(pid) do
    Process.alive?(pid)
  rescue
    ArgumentError -> false
  end
end
