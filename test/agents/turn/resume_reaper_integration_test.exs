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
  # async: false — the Postgres sandbox runs in shared mode (one connection for every process).
  use ExUnit.Case, async: false
  import Normandy.Test.Eventually
  @moduletag :postgres

  alias Ecto.Adapters.SQL.Sandbox
  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Behaviours.SessionStore.Postgres, as: PG
  alias Normandy.Test.TurnConfig
  alias Normandy.Tools.Toolset

  setup do
    :ok = Sandbox.checkout(Normandy.TestRepo)
    Sandbox.mode(Normandy.TestRepo, {:shared, self()})
    :ok
  end

  test "on :nodedown the reaper reconstructs + resumes an eager session under Horde, from Postgres" do
    sid = "reap-#{System.unique_integer([:positive])}"
    reg = HReg.new()
    # Horde calls take the name; start_link's pid is Horde's outer Supervisor.
    sup = :"reapsup_#{System.unique_integer([:positive])}"
    # Under the test supervisor, which stops them (reverse start order, each with its
    # shutdown) and waits for them to be gone before the next test. Killing the Horde
    # supervisor in on_exit instead let its SignalShutdown child log an [error]
    # (`:horde_shutting_down` call to a killed process) into a later test's capture_log.
    start_supervised!(%{
      id: :horde_sup,
      start: {HSup, :start_link, [[name: sup]]},
      type: :supervisor
    })

    cat = start_supervised!(%{id: :catalog, start: {Catalog, :start_link, [[]]}})

    # Node-local supplement (non-serializable half of config) for template_id "k".
    :ok =
      Catalog.put(cat, "k", %{
        toolset: Toolset.new(),
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _token -> %{api_key: "k"} end
      })

    # Persist the eager session in Postgres: non-secret template (credential ref =
    # node-local StubCreds, via TurnConfig.build) + a non-terminal :awaiting_approval
    # turn state.
    tmpl = ConfigTemplate.from_config(TurnConfig.build(), "k", :eager)
    :ok = PG.save_config_template(Normandy.TestRepo, sid, tmpl)

    :ok =
      PG.save_turn_state(Normandy.TestRepo, sid, %Turn.State{status: :awaiting_approval}, true)

    # Precondition: not currently live anywhere.
    assert HReg.whereis(reg, sid) == :none

    reaper =
      start_supervised!(
        {ResumeReaper,
         store: {PG, Normandy.TestRepo},
         registry: {HReg, reg},
         supervisor: sup,
         supervisor_mod: HSup,
         template_provider: {Catalog, cat}}
      )

    send(reaper, {:nodedown, :"gone@127.0.0.1"})

    # The reaper reconstructed the config from Postgres + the local supplement and
    # started the server under Horde, which registered it.
    assert wait_until(fn -> match?({:ok, _}, HReg.whereis(reg, sid)) end),
           "reaper did not start/register the eager session after :nodedown " <>
             "(reconstruction may have failed — check the ResumeReaper logs)"

    {:ok, pid} = HReg.whereis(reg, sid)
    assert node(pid) == node()
  end
end
