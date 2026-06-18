defmodule Normandy.Agents.Turn.Supervisor.HordeTest do
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg

  test "starts a server under Horde with a :via name and restart :temporary" do
    {:ok, sup} = HSup.start_link(name: :"hsup_#{System.unique_integer([:positive])}")
    reg = HReg.new()
    store = Normandy.Behaviours.SessionStore.InMemory.new()
    {:ok, cat} = Normandy.Behaviours.AgentTemplate.Catalog.start_link([])
    sid = "h-#{System.unique_integer([:positive])}"

    base = build_test_config()

    tmpl =
      put_in(
        Normandy.Agents.ConfigTemplate.from_config(base, "k").behaviours_refs.credential,
        {Normandy.Test.StubCreds, []}
      )

    :ok = Normandy.Behaviours.SessionStore.InMemory.save_config_template(store, sid, tmpl)

    :ok =
      Normandy.Behaviours.AgentTemplate.Catalog.put(cat, "k", %{
        tool_registry: base.tool_registry,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _ -> base.client end
      })

    opts = [
      session_id: sid,
      store: {Normandy.Behaviours.SessionStore.InMemory, store},
      registry: {HReg, reg},
      template_provider: {Normandy.Behaviours.AgentTemplate.Catalog, cat},
      resume_policy: :lazy
    ]

    assert {:ok, pid} = HSup.start_server(sup, opts)
    assert {:ok, ^pid} = HReg.whereis(reg, sid)
  end

  defp build_test_config, do: Normandy.Test.TurnConfig.build()
end
