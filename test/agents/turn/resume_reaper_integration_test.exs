defmodule Normandy.Agents.Turn.ResumeReaperIntegrationTest do
  @moduledoc """
  End-to-end eager handoff with REAL infra (cluster-of-one): `ResumeReaper` +
  `SessionStore.Postgres` + `SessionRegistry.Horde` + `Turn.Supervisor.Horde` +
  template reconstruction. Proves the full path the reaper unit test stubs:
  reap → start under Horde → `Turn.Server` reconstructs config from the persisted
  Postgres template + node-local supplement + credentials → registers → resumes.

  The node-down trigger is simulated by sending the reaper `{:nodedown, _}` (the
  reaped session's data lives in Postgres; multi-node delivery of that message is
  plain OTP `:net_kernel.monitor_nodes` and is covered separately). A non-terminal
  `:awaiting_approval` turn state is used so the resume is a no-op effect-wise
  (re-arms the approval wait) and needs no LLM — keeping the test deterministic.
  """
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Normandy.Agents.Turn
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Behaviours.SessionStore.Postgres, as: PG

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Normandy.TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, {:shared, self()})
    :ok
  end

  test "on :nodedown the reaper reconstructs + resumes an eager session under Horde, from Postgres" do
    sid = "reap-#{System.unique_integer([:positive])}"
    reg = HReg.new()
    {:ok, sup} = HSup.start_link(name: :"reapsup_#{System.unique_integer([:positive])}")
    {:ok, cat} = Catalog.start_link([])

    # Node-local supplement (non-serializable half of config) for template_id "k".
    :ok =
      Catalog.put(cat, "k", %{
        tool_registry: Normandy.Tools.Registry.new(),
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _token -> %{api_key: "k"} end
      })

    # Persist the eager session in Postgres: non-secret template (credential ref =
    # node-local StubCreds, via TurnConfig.build) + a non-terminal :awaiting_approval
    # turn state.
    tmpl = ConfigTemplate.from_config(Normandy.Test.TurnConfig.build(), "k", :eager)
    :ok = PG.save_config_template(Normandy.TestRepo, sid, tmpl)
    :ok = PG.save_turn_state(Normandy.TestRepo, sid, %Turn.State{status: :awaiting_approval})

    # Precondition: not currently live anywhere.
    assert HReg.whereis(reg, sid) == :none

    {:ok, reaper} =
      ResumeReaper.start_link(
        store: {PG, Normandy.TestRepo},
        registry: {HReg, reg},
        supervisor: sup,
        supervisor_mod: HSup,
        template_provider: {Catalog, cat}
      )

    send(reaper, {:nodedown, :"gone@127.0.0.1"})

    # The reaper reconstructed the config from Postgres + the local supplement and
    # started the server under Horde, which registered it.
    assert eventually(fn -> match?({:ok, _}, HReg.whereis(reg, sid)) end)
    {:ok, pid} = HReg.whereis(reg, sid)
    assert node(pid) == node()
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end
end
