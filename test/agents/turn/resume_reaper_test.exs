defmodule Normandy.Agents.Turn.ResumeReaperTest do
  use ExUnit.Case, async: true

  alias Normandy.Agents.Turn
  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Behaviours.AgentTemplate.Catalog
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.SessionStore.InMemory

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

    :ok = InMemory.save_turn_state(store, "s-eager", %Turn.State{status: :steering})

    # s-lazy: lazy -> not in list_resumable -> SKIP
    :ok =
      InMemory.save_config_template(store, "s-lazy", %{template_id: "k", resume_policy: :lazy})

    :ok = InMemory.save_turn_state(store, "s-lazy", %Turn.State{status: :steering})

    # s-done / s-failed: eager but terminal turn state (:stopped / :failed) -> SKIP
    :ok =
      InMemory.save_config_template(store, "s-done", %{template_id: "k", resume_policy: :eager})

    :ok = InMemory.save_turn_state(store, "s-done", %Turn.State{status: :stopped})

    :ok =
      InMemory.save_config_template(store, "s-failed", %{template_id: "k", resume_policy: :eager})

    :ok = InMemory.save_turn_state(store, "s-failed", %Turn.State{status: :failed})

    # s-live: eager + non-terminal but already registered -> SKIP
    :ok =
      InMemory.save_config_template(store, "s-live", %{template_id: "k", resume_policy: :eager})

    :ok = InMemory.save_turn_state(store, "s-live", %Turn.State{status: :steering})
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
    :ok = InMemory.save_turn_state(store, "s1", %Turn.State{status: :steering})

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
    handlers = %{call_llm: fn _, _, _ -> :stub end}
    subscriber = fn _event, _meta -> :ok end

    :ok = InMemory.save_config_template(store, "s1", %{template_id: "k", resume_policy: :eager})
    :ok = InMemory.save_turn_state(store, "s1", %Turn.State{status: :awaiting_approval})

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
    :ok = InMemory.save_turn_state(store, "s1", %Turn.State{status: :steering})

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

    :ok = InMemory.save_turn_state(store, "s-eager", %Turn.State{status: :steering})

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
end
