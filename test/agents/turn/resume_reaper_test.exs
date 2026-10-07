defmodule Normandy.Agents.Turn.ResumeReaperTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.ConfigTemplate
  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.Config
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Test.TurnConfig

  # A fake supervisor that records each start_server call (session_id + full opts)
  # instead of really starting a Turn.Server. The "supervisor" handle is the test pid.
  defmodule RecordingSup do
    @moduledoc false
    def start_server(test_pid, opts) when is_pid(test_pid) do
      send(test_pid, {:reaper_started, Keyword.fetch!(opts, :session_id), opts})
      {:ok, spawn(fn -> :ok end)}
    end
  end

  # An eager session whose turn-state load reports a backend fault.
  defmodule TurnStateFaultStore do
    @moduledoc false
    def list_resumable(_handle), do: {:ok, ["s-fault"]}
    def load_turn_state(_handle, _sid), do: {:error, :store_unavailable}
  end

  defp reaper(store, reg, cat, extra \\ []) do
    {:ok, pid} =
      ResumeReaper.start_link(
        [
          store: {InMemory, store},
          registry: {Native, reg},
          supervisor: self(),
          supervisor_mod: RecordingSup,
          template_provider: {Catalog, cat}
        ] ++ extra
      )

    pid
  end

  test "on :nodedown reaps only eager + unregistered + non-terminal sessions" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, cat} = Catalog.start_link([])

    # s-eager: eager + non-terminal + unregistered -> REAP
    :ok =
      InMemory.save_config_template(store, "s-eager", %{template_id: "k", resume_policy: :eager})

    :ok = InMemory.save_turn_state(store, "s-eager", %Turn.State{status: :steering}, true)

    # s-lazy: lazy -> saved not in flight -> not in list_resumable -> SKIP
    :ok =
      InMemory.save_config_template(store, "s-lazy", %{template_id: "k", resume_policy: :lazy})

    :ok = InMemory.save_turn_state(store, "s-lazy", %Turn.State{status: :steering}, false)

    # s-done / s-failed: listed (a stale index member, as a Redis crash between the
    # state and the index write leaves one) but terminal (:stopped / :failed) -> SKIP
    :ok =
      InMemory.save_config_template(store, "s-done", %{template_id: "k", resume_policy: :eager})

    :ok = InMemory.save_turn_state(store, "s-done", %Turn.State{status: :stopped}, true)

    :ok =
      InMemory.save_config_template(store, "s-failed", %{template_id: "k", resume_policy: :eager})

    :ok = InMemory.save_turn_state(store, "s-failed", %Turn.State{status: :failed}, true)

    # s-live: eager + non-terminal but already registered -> SKIP
    :ok =
      InMemory.save_config_template(store, "s-live", %{template_id: "k", resume_policy: :eager})

    :ok = InMemory.save_turn_state(store, "s-live", %Turn.State{status: :steering}, true)
    :ok = Native.register(reg, "s-live", self())

    r = reaper(store, reg, cat)
    send(r, {:nodedown, :"gone@127.0.0.1"})

    assert_receive {:reaper_started, "s-eager", _opts}, 1_000
    refute_received {:reaper_started, "s-lazy", _}
    refute_received {:reaper_started, "s-done", _}
    refute_received {:reaper_started, "s-failed", _}
    refute_received {:reaper_started, "s-live", _}
  end

  test "the reaped session is started as a thin :eager spec with the infra handles" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, cat} = Catalog.start_link([])

    :ok = InMemory.save_config_template(store, "s1", %{template_id: "k", resume_policy: :eager})
    :ok = InMemory.save_turn_state(store, "s1", %Turn.State{status: :steering}, true)

    r = reaper(store, reg, cat)
    send(r, {:nodedown, :"gone@127.0.0.1"})

    assert_receive {:reaper_started, "s1", opts}, 1_000
    assert opts[:resume_policy] == :eager
    assert opts[:store] == {InMemory, store}
    assert opts[:registry] == {Native, reg}
    assert opts[:template_provider] == {Catalog, cat}
    # Thin spec: no :config is forwarded (the server reconstructs it).
    refute Keyword.has_key?(opts, :config)
  end

  test "the reaped session gets the host's :subscriber and :handlers" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, cat} = Catalog.start_link([])
    handlers = %Turn.Driver.Handlers{call_llm: fn _, _, _ -> :stub end}
    subscriber = fn _event, _meta -> :ok end

    :ok = InMemory.save_config_template(store, "s1", %{template_id: "k", resume_policy: :eager})
    :ok = InMemory.save_turn_state(store, "s1", %Turn.State{status: :awaiting_approval}, true)

    r = reaper(store, reg, cat, subscriber: subscriber, handlers: handlers)
    send(r, {:nodedown, :"gone@127.0.0.1"})

    assert_receive {:reaper_started, "s1", opts}, 1_000
    assert opts[:subscriber] == subscriber
    assert opts[:handlers] == handlers
  end

  test "without :subscriber or :handlers the reaper passes neither" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, cat} = Catalog.start_link([])

    :ok = InMemory.save_config_template(store, "s1", %{template_id: "k", resume_policy: :eager})
    :ok = InMemory.save_turn_state(store, "s1", %Turn.State{status: :steering}, true)

    r = reaper(store, reg, cat)
    send(r, {:nodedown, :"gone@127.0.0.1"})

    assert_receive {:reaper_started, "s1", opts}, 1_000
    refute Keyword.has_key?(opts, :subscriber)
    refute Keyword.has_key?(opts, :handlers)
  end

  test "a turn-state load fault skips the session and logs it" do
    reg = Native.new()
    {:ok, cat} = Catalog.start_link([])

    {:ok, r} =
      ResumeReaper.start_link(
        store: {TurnStateFaultStore, nil},
        registry: {Native, reg},
        supervisor: self(),
        supervisor_mod: RecordingSup,
        template_provider: {Catalog, cat}
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(r, {:nodedown, :"gone@127.0.0.1"})
        # A call after the send returns once the reaper has handled :nodedown.
        :sys.get_state(r)
      end)

    refute_received {:reaper_started, "s-fault", _}
    assert log =~ "ResumeReaper: could not load the turn state of \"s-fault\""
    assert log =~ ":store_unavailable"
  end

  defmodule DownRegistry do
    def whereis(_handle, _sid), do: {:error, :registry_down}
  end

  test "a registry lookup that fails skips the session (no duplicate start) and logs it" do
    store = InMemory.new()
    {:ok, cat} = Catalog.start_link([])

    :ok =
      InMemory.save_config_template(store, "s-eager", %{template_id: "k", resume_policy: :eager})

    :ok = InMemory.save_turn_state(store, "s-eager", %Turn.State{status: :steering}, true)

    {:ok, r} =
      ResumeReaper.start_link(
        store: {InMemory, store},
        registry: {DownRegistry, nil},
        supervisor: self(),
        supervisor_mod: RecordingSup,
        template_provider: {Catalog, cat}
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(r, {:nodedown, :"gone@127.0.0.1"})
        :sys.get_state(r)
      end)

    refute_received {:reaper_started, "s-eager", _}
    assert log =~ "could not look up \"s-eager\" in the registry"
  end

  # Scripted fakes for the via-registration race. One Agent holds the queued replies of
  # start_server/2 and whereis/2 and counts the start calls.
  defmodule ScriptedSup do
    @moduledoc false
    def start_server(agent, _opts) do
      Agent.get_and_update(agent, fn %{starts: [reply | rest], calls: n} = st ->
        {reply, %{st | starts: rest, calls: n + 1}}
      end)
    end
  end

  defmodule ScriptedRegistry do
    @moduledoc false
    def whereis(agent, _sid) do
      Agent.get_and_update(agent, fn
        %{whereis: [reply | rest]} = st -> {reply, %{st | whereis: rest}}
        %{whereis: []} = st -> {:none, st}
      end)
    end
  end

  defmodule ResumableStore do
    @moduledoc false
    def list_resumable(_handle), do: {:ok, ["s-race"]}
    def load_turn_state(_handle, _sid), do: {:ok, %Normandy.Agents.Turn.State{status: :steering}}
  end

  defp race_reap(starts, whereis) do
    {:ok, agent} = Agent.start_link(fn -> %{starts: starts, whereis: whereis, calls: 0} end)

    state = %{
      store: {ResumableStore, nil},
      registry: {ScriptedRegistry, agent},
      supervisor: agent,
      supervisor_mod: ScriptedSup,
      template_provider: {Catalog, nil},
      host_server_opts: []
    }

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = ResumeReaper.reap(state) end)
    {log, Agent.get(agent, & &1.calls)}
  end

  # A credential provider that fails with a reason holding a secret.
  defmodule FailingCreds do
    @moduledoc false
    @behaviour Normandy.Behaviours.CredentialProvider
    @impl true
    def get_token(_provider, opts),
      do: {:error, {:vault_denied, Keyword.fetch!(opts, :marker)}}
  end

  # Starts a real, unlinked Turn.Server, so its start-up log is the reaper's to capture.
  defmodule ServerSup do
    @moduledoc false
    def start_server(_handle, opts) do
      {:ok, pid} = :gen_statem.start(Turn.Server, opts, [])
      {:ok, pid}
    end
  end

  # Decision 6: a resumed session whose credential provider fails is logged by the
  # provider's module and the reason's tag, never the reason's terms.
  test "a resumed session whose credential lookup fails logs no provider reason terms" do
    marker = "SECRET-REAPER-#{System.unique_integer([:positive])}"
    store = InMemory.new()
    reg = Native.new()
    {:ok, cat} = Catalog.start_link([])

    :ok =
      Catalog.put(cat, "kind-a", %{
        toolset: nil,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn token -> %{api_key: token} end
      })

    tmpl =
      %{
        TurnConfig.build()
        | behaviours: %Config{credential: {FailingCreds, [marker: marker]}}
      }
      |> ConfigTemplate.from_config("kind-a", :eager)

    :ok = InMemory.save_config_template(store, "s-creds", tmpl)
    :ok = InMemory.save_turn_state(store, "s-creds", %Turn.State{status: :steering}, true)

    state = %{
      store: {InMemory, store},
      registry: {Native, reg},
      supervisor: nil,
      supervisor_mod: ServerSup,
      template_provider: {Catalog, cat},
      host_server_opts: []
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = ResumeReaper.reap(state)
        assert {:ok, pid} = Native.whereis(reg, "s-creds")
        # The server loads after init/1 returns: get_state/1 answers once the load ran.
        assert {:unavailable, _} = :sys.get_state(pid)
        :gen_statem.stop(pid)
      end)

    assert log =~ "could not start session \"s-creds\""
    assert log =~ inspect(FailingCreds)
    assert log =~ ":vault_denied"
    refute log =~ marker
  end

  describe "the via-registration race" do
    test "a bare race is retried until the start succeeds" do
      race = {:error, {:process_not_registered_via, Horde.Registry}}
      # whereis: the reaper's own not_running? check, then one lookup per race.
      {log, calls} = race_reap([race, race, {:ok, self()}], [:none, :none, :none])

      assert calls == 3
      refute log =~ "failed to resume"
    end

    test "a race whose winner is now registered starts nothing further" do
      race = {:error, {:process_not_registered_via, Horde.Registry}}
      {log, calls} = race_reap([race], [:none, {:ok, self()}])

      assert calls == 1
      refute log =~ "failed to resume"
    end

    test "the supervisor-nested race shape is retried too" do
      race = {:error, {{:process_not_registered_via, Horde.Registry}, :child}}
      {log, calls} = race_reap([race, {:ok, self()}], [:none, :none])

      assert calls == 2
      refute log =~ "failed to resume"
    end

    test "an already-started loser is success: nothing logged, no retry" do
      {log, calls} = race_reap([{:error, {:already_started, self()}}], [:none])
      assert calls == 1
      refute log =~ "failed to resume"
      refute log =~ "unexpected start_server"

      {log, calls} = race_reap([{:error, {{:already_started, self()}, :child}}], [:none])
      assert calls == 1
      refute log =~ "failed to resume"
      refute log =~ "unexpected start_server"
    end

    test "a genuine error is logged once and not retried" do
      {log, calls} = race_reap([{:error, :boom}], [:none])

      assert calls == 1
      assert length(String.split(log, "failed to resume s-race")) == 2
      assert log =~ ":boom"
    end
  end

  describe "a sweep's concurrency (Task 6.2f)" do
    # A supervisor whose start_server/2 returns only once `n` starts have arrived: a
    # sweep that started sessions one at a time would wait at the first start for good.
    defmodule GatedSup do
      @moduledoc false
      use GenServer

      def start_link({test_pid, n}), do: GenServer.start_link(__MODULE__, {test_pid, n})

      def start_server(gate, opts),
        do: GenServer.call(gate, {:arrive, Keyword.fetch!(opts, :session_id)}, :infinity)

      @impl true
      def init({test_pid, n}), do: {:ok, %{test_pid: test_pid, n: n, waiting: []}}

      @impl true
      def handle_call({:arrive, sid}, from, state) do
        send(state.test_pid, {:reaper_started, sid})
        waiting = [from | state.waiting]

        if length(waiting) == state.n do
          Enum.each(waiting, &GenServer.reply(&1, {:ok, self()}))
          {:noreply, %{state | waiting: []}}
        else
          {:noreply, %{state | waiting: waiting}}
        end
      end
    end

    # start_server/2 raises for "s-raises" and records every other start. The
    # "supervisor" handle is the test pid.
    defmodule RaisingSup do
      @moduledoc false
      def start_server(test_pid, opts) do
        case Keyword.fetch!(opts, :session_id) do
          "s-raises" -> raise ArgumentError, "SECRET-START-BUG"
          sid -> send(test_pid, {:started, sid})
        end

        {:ok, self()}
      end
    end

    defp eager_sessions(sids) do
      store = InMemory.new()

      for sid <- sids do
        :ok =
          InMemory.save_config_template(store, sid, %{template_id: "k", resume_policy: :eager})

        :ok = InMemory.save_turn_state(store, sid, %Turn.State{status: :steering}, true)
      end

      store
    end

    defp sweep_state(store, sup, sup_mod) do
      {:ok, cat} = Catalog.start_link([])

      %{
        store: {InMemory, store},
        registry: {Native, Native.new()},
        supervisor: sup,
        supervisor_mod: sup_mod,
        template_provider: {Catalog, cat},
        host_server_opts: []
      }
    end

    test "the sessions of a sweep start at once" do
      sids = ["s-a", "s-b", "s-c"]
      {:ok, gate} = GatedSup.start_link({self(), length(sids)})
      state = sweep_state(eager_sessions(sids), gate, GatedSup)

      sweep = Task.async(fn -> ResumeReaper.reap(state) end)
      assert :ok = Task.await(sweep, 5_000)

      for sid <- sids, do: assert_received({:reaper_started, ^sid})
    end

    test "a session whose start raises is logged by type and skipped; the others start" do
      state = sweep_state(eager_sessions(["s-ok", "s-raises"]), self(), RaisingSup)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = ResumeReaper.reap(state)
        end)

      assert_received {:started, "s-ok"}
      assert log =~ ~s(ResumeReaper: resuming "s-raises" crashed: ArgumentError)
      refute log =~ "SECRET-START-BUG"
    end
  end
end
