defmodule Normandy.Agents.Turn.Tier2IntegrationTest do
  @moduledoc "Tier-2 (Horde reg+sup, lazy) as a cluster-of-one, end to end."
  use ExUnit.Case, async: true
  import Normandy.Test.Eventually

  alias Normandy.Agents.BaseAgent.Handlers, as: AgentHandlers
  alias Normandy.Agents.Turn.Session
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig

  test "a turn runs through the Horde supervisor with reconstructed config" do
    reg = HReg.new()
    # Horde calls take the name; start_link's pid is Horde's outer Supervisor.
    sup = :"t2_#{System.unique_integer([:positive])}"
    {:ok, _} = HSup.start_link(name: sup)
    store = InMemory.new()
    {:ok, cat} = Catalog.start_link([])
    sid = "t2-#{System.unique_integer([:positive])}"

    base = TurnConfig.build()
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
        AgentHandlers.non_streaming_handlers()
        | call_llm: fn _c, _s, _r -> %Normandy.Test.TurnConfig.Resp{content: "ok"} end
      }
    ]

    assert {:ok, _result} = Session.run(Session.new(opts), "hello")
    assert wait_until(fn -> match?({:ok, _}, HReg.whereis(reg, sid)) end)
    # The template was persisted (reconstruction would work on another node).
    assert {:ok, _tmpl} =
             InMemory.load_config_template(store, sid)
  end

  defp register_supplement(cat, base) do
    Catalog.put(cat, "k", %{
      toolset: base.toolset,
      before_hooks: [],
      after_hooks: [],
      client_builder: fn _ -> base.client end
    })
  end
end
