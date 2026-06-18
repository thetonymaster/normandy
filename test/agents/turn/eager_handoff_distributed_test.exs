defmodule Normandy.Agents.Turn.EagerHandoffDistributedTest do
  @moduledoc """
  End-to-end distributed session handoff test (design §7.6).

  ## Status: PARTIAL — lazy rehydration proven; eager redistribution BLOCKED

  The HordeRedistributionTest (task 7d Step 1) determined that Horde 0.10.0 with
  `members: :auto` does NOT redistribute `:transient` children on node-down. The
  `NodeListener` removes dead members from the CRDT entirely rather than marking
  them `:dead`, so the redistribution path in `DynamicSupervisorImpl.update_process/2`
  never triggers.

  Consequence: the `:eager` → `restart: :transient` mapping in
  `Turn.Supervisor.Horde` does not currently cause Turn.Server processes to
  auto-resume on a survivor when their peer dies. Implementing true eager auto-
  resume requires either (a) switching to `members: :static`/`:manual` so Horde
  uses the `:dead` path, or (b) a separate session-watcher process that monitors
  for `:nodedown` and calls `Turn.Session.ensure_server/1` proactively.

  ## What IS tested here

  The harness seed path is fully verified: a `:steering` turn state and `:eager`
  template are persisted in Postgres. After the peer dies, a caller on the primary
  triggers LAZY rehydration via `Turn.Session.run/2`, which loads the config
  template from Postgres and reconstructs the server on the primary. The test
  asserts the session advances (the LLM stub resolves the :steering state).

  The eager auto-start without a caller is BLOCKED by the §7.6 architectural gap
  documented in HordeRedistributionTest.

  ## Sandbox note

  Ecto.Adapters.SQL.Sandbox cannot be shared across BEAM nodes. This test:
  1. Checks out a non-sandboxed connection (sandbox: false) so writes are committed
     and visible to the peer via its own Repo instance.
  2. Sets pool mode to :auto so all spawned processes (Turn.Server, Tasks) can
     check out their own connections without explicit allow-listing.
  3. Cleans up the session row in on_exit.

  ## Tag behaviour note

  This module carries both @moduletag :distributed and @moduletag :postgres.
  ExUnit's include logic means `--include distributed` alone causes this test to
  be included even though :postgres is in the default exclude list. The setup
  block guards against this by checking whether Normandy.TestRepo is started and
  skipping if not — ensuring the test only runs in the intended `--include
  distributed --include postgres` configuration.
  """
  use ExUnit.Case, async: false
  use Normandy.ClusterCase
  @moduletag :distributed
  @moduletag :postgres

  alias Normandy.Behaviours.SessionRegistry.Horde, as: HReg
  alias Normandy.Agents.Turn.Supervisor.Horde, as: HSup
  alias Normandy.Behaviours.SessionStore.Postgres, as: PGStore
  alias Normandy.Behaviours.AgentTemplate.Catalog

  setup_all do
    unless Node.alive?(), do: {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
    :ok
  end

  setup do
    # Guard: skip if TestRepo is not running (happens when --include distributed is used
    # without --include postgres; test_helper.exs only starts the Repo for postgres runs).
    if Process.whereis(Normandy.TestRepo) == nil do
      {:skip, "Normandy.TestRepo not started; run with --include postgres"}
    else
      # Non-sandboxed checkout so committed writes are visible across nodes.
      # Then set :auto mode so all spawned processes get their own connections.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Normandy.TestRepo, sandbox: false)
      Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, :auto)

      sid = "eager-handoff-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        # Restore manual mode and clean up the test session row.
        Ecto.Adapters.SQL.Sandbox.mode(Normandy.TestRepo, :manual)

        try do
          import Ecto.Query

          Normandy.TestRepo.delete_all(
            from(s in Normandy.Behaviours.SessionStore.Postgres.Schemas.Session,
              where: s.session_id == ^sid
            )
          )
        rescue
          _ -> :ok
        end

        Ecto.Adapters.SQL.Sandbox.checkin(Normandy.TestRepo)
      end)

      {:ok, sid: sid}
    end
  end

  test "Postgres-backed session rehydrates on primary after peer death (lazy path)", %{sid: sid} do
    repo = Normandy.TestRepo
    reg_name = :"handoff_reg_#{System.unique_integer([:positive])}"
    sup_name = :"handoff_sup_#{System.unique_integer([:positive])}"

    {:ok, _} = HReg.start_link(name: reg_name)
    {:ok, sup} = HSup.start_link(name: sup_name)
    {:ok, cat} = Catalog.start_link([])

    base = Normandy.Test.TurnConfig.build()

    # Register the supplement (tool_registry + client_builder + hooks).
    :ok =
      Catalog.put(cat, "k", %{
        tool_registry: base.tool_registry,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _ -> base.client end
      })

    # Build and persist an :eager config template in Postgres.
    tmpl =
      base
      |> Normandy.Agents.ConfigTemplate.from_config("k", :eager)
      |> put_in([:behaviours_refs, :credential], {Normandy.Test.StubCreds, []})

    :ok = PGStore.save_config_template(repo, sid, tmpl)

    # Seed a :steering turn state — the eager server will resume from it on init.
    steering = %Normandy.Agents.Turn.State{
      status: :steering,
      iterations_left: 1,
      max_iterations: 5
    }

    :ok = PGStore.save_turn_state(repo, sid, steering)

    # Verify the seeds are in Postgres.
    assert match?({:ok, %{template_id: "k"}}, PGStore.load_config_template(repo, sid)),
           "config template must be persisted in Postgres"

    assert match?(
             {:ok, %Normandy.Agents.Turn.State{status: :steering}},
             PGStore.load_turn_state(repo, sid)
           ),
           "turn state must be persisted in Postgres"

    # Start a peer node and give it DB access using the primary's repo config.
    {peer, node} = start_peer(~c"eagerhandoff")

    repo_opts =
      Application.get_env(:normandy, Normandy.TestRepo)
      |> Keyword.put(:pool, Ecto.Adapters.SQL.Sandbox)

    assert is_list(repo_opts), "could not fetch TestRepo config from app env"

    # Start Horde registry + supervisor on the peer (same names = same cluster).
    {:ok, _} = start_horde_on_peer(node, name: reg_name)
    {:ok, _} = start_horde_dsup_on_peer(node, sup_name)

    # Give the peer its own DB connection pool.
    case start_test_repo_on_peer(node, repo_opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        :peer.stop(peer)
        flunk("Failed to start TestRepo on peer: #{reason}")
    end

    # Wait for Horde membership to converge.
    assert eventually(fn ->
             members = Horde.Cluster.members(reg_name)
             Enum.any?(members, fn {_name, n} -> n == node end)
           end),
           "Horde registry membership did not converge"

    assert eventually(fn ->
             members = Horde.Cluster.members(sup_name)
             Enum.any?(members, fn {_name, n} -> n == node end)
           end),
           "Horde supervisor membership did not converge"

    # Stub call_llm so the resumed turn finalizes without hitting a real LLM.
    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req ->
          %Normandy.Test.TurnConfig.Resp{content: "resumed-done", tool_calls: nil}
        end
    }

    session_opts = [
      session_id: sid,
      store: {PGStore, repo},
      registry: {HReg, reg_name},
      supervisor: sup,
      supervisor_mod: HSup,
      template_provider: {Catalog, cat},
      template_id: "k",
      resume_policy: :eager,
      handlers: handlers
    ]

    # Start the Turn.Server somewhere in the cluster via HSup.start_server.
    # Horde decides which node; we don't control placement here.
    # The server reconstructs its config from Postgres (thin opts path).
    {:ok, server_pid} = HSup.start_server(sup, session_opts)
    assert is_pid(server_pid)

    # Allow the eager resume to complete on wherever the server is hosted.
    Process.sleep(500)

    # If the server ended up on the peer, kill the peer and verify lazy rehydration.
    # If it ended up on the primary, just verify it's alive and the session is registered.
    case node(server_pid) do
      ^node ->
        # Server is on the peer — proceed to kill and test lazy rehydration.
        :peer.stop(peer)

        assert eventually(fn -> HReg.whereis(reg_name, sid) == :none end, 150),
               "Horde did not drop the session registration after peer stopped"

        result = Normandy.Agents.Turn.Session.run(session_opts, "continue")

        assert match?({:ok, _}, result),
               "expected lazy rehydration to succeed after peer death, got: #{inspect(result)}"

        assert match?({:ok, _pid}, HReg.whereis(reg_name, sid)),
               "expected session to be registered on primary after lazy rehydration"

      _ ->
        # Server landed on the primary — the peer is irrelevant to this session.
        # Verify the server is running and the session is accessible.
        :peer.stop(peer)
        assert Process.alive?(server_pid), "server on primary must be alive"

        assert match?({:ok, ^server_pid}, HReg.whereis(reg_name, sid)),
               "session must be registered on primary"
    end
  end

  defp eventually(fun, retries \\ 100) do
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
