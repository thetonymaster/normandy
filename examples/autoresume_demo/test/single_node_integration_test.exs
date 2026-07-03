defmodule AutoresumeDemo.SingleNodeIntegrationTest do
  use ExUnit.Case, async: false

  alias AutoresumeDemo.{Agent, Seeds, Topology}
  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup

  setup do
    Application.put_env(:autoresume_demo, :demo_mode, :simulated)
    Application.put_env(:autoresume_demo, :sim_step_delay_ms, 0)

    start_supervised!(%{
      id: Topology.catalog(),
      start: {Catalog, :start_link, [[name: Topology.catalog()]]}
    })

    start_supervised!(%{
      id: Topology.registry(),
      start: {HReg, :start_link, [[name: Topology.registry()]]}
    })

    start_supervised!(%{
      id: Topology.supervisor(),
      start: {HSup, :start_link, [[name: Topology.supervisor()]]}
    })

    :ok = Agent.register_supplement(Topology.catalog())
    :ok
  end

  test "a simulated eager session runs the tool loop to a terminal state" do
    {store_mod, store_handle} = Topology.store()
    [sid] = Seeds.seed("raft", 1)

    assert eventually(
             fn ->
               case store_mod.load_turn_state(store_handle, sid) do
                 {:ok, %Turn.State{status: status}} -> status in [:stopped, :failed]
                 _ -> false
               end
             end,
             60
           )
  end

  defp eventually(fun, tries) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.(),
        do: {:halt, true},
        else:
          (
            Process.sleep(100)
            {:cont, false}
          )
    end)
  end
end
