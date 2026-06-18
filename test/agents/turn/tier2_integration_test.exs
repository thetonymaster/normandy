defmodule Normandy.Agents.Turn.Tier2IntegrationTest do
  @moduledoc "Tier-2 (Horde reg+sup, lazy) as a cluster-of-one, end to end."
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn.{Session, Supervisor}
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup

  test "a turn runs through the Horde supervisor with reconstructed config" do
    reg = HReg.new()
    {:ok, sup} = HSup.start_link(name: :"t2_#{System.unique_integer([:positive])}")
    store = Normandy.Behaviours.SessionStore.InMemory.new()
    {:ok, cat} = Normandy.Behaviours.AgentTemplate.Catalog.start_link([])
    sid = "t2-#{System.unique_integer([:positive])}"

    base = Normandy.Test.TurnConfig.build()
    register_supplement(cat, base)

    opts = [
      session_id: sid,
      config: base,
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {HReg, reg},
      supervisor: sup,
      supervisor_mod: HSup,
      template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, cat},
      template_id: "k",
      resume_policy: :lazy,
      handlers: %{
        Normandy.Agents.BaseAgent.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %Normandy.Test.TurnConfig.Resp{content: "ok"} end
      }
    ]

    assert {:ok, _result} = Session.run(opts, "hello")
    assert {:ok, _pid} = HReg.whereis(reg, sid)
    # The template was persisted (reconstruction would work on another node).
    assert {:ok, _tmpl} =
             Normandy.Behaviours.SessionStore.InMemory.load_config_template(store, sid)
  end

  defp register_supplement(cat, base) do
    Normandy.Behaviours.AgentTemplate.Catalog.put(cat, "k", %{
      tool_registry: base.tool_registry,
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _ -> base.client end
    })
  end
end
