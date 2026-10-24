defmodule Normandy.Agents.Turn.RedisComboTest do
  # Single-node integration of the new Redis backends with the reaper (needs Redis).
  use ExUnit.Case, async: true
  @moduletag :redis

  alias Normandy.Agents.Turn.ResumeReaper
  alias Normandy.Agents.Turn.State
  alias Normandy.Behaviours.SessionRegistry.Redis, as: Reg
  alias Normandy.Behaviours.SessionStore.Redis, as: Store

  # Stub supervisor: records which sessions the reaper tried to start.
  defmodule StubSup do
    @behaviour Normandy.Agents.Turn.ServerSupervisor

    def start_server(test_pid, opts) do
      send(test_pid, {:started, Keyword.fetch!(opts, :session_id)})
      {:ok, spawn(fn -> :ok end)}
    end

    def stop_server(_sup, _pid), do: {:error, :not_found}
  end

  test "reaper starts only eager, unregistered, non-terminal sessions over Redis backends" do
    store = Normandy.TestHandles.redis_session_store()
    reg = Normandy.TestHandles.redis_registry()

    # eager + non-terminal + unregistered  -> SHOULD be reaped
    :ok = Store.save_config_template(store, "eager_live", %{resume_policy: :eager})
    :ok = Store.save_turn_state(store, "eager_live", %State{status: :steering}, true)

    # eager + non-terminal but REGISTERED   -> skipped (whereis != :none)
    :ok = Store.save_config_template(store, "eager_registered", %{resume_policy: :eager})
    :ok = Store.save_turn_state(store, "eager_registered", %State{status: :steering}, true)
    :ok = Reg.register(reg, "eager_registered", self())

    # eager but TERMINAL                     -> not in flight, so not listed
    :ok = Store.save_config_template(store, "eager_done", %{resume_policy: :eager})
    :ok = Store.save_turn_state(store, "eager_done", %State{status: :stopped}, false)

    # lazy                                   -> not in list_resumable at all
    :ok = Store.save_config_template(store, "lazy_one", %{resume_policy: :lazy})

    state = %{
      store: {Store, store},
      registry: {Reg, reg},
      supervisor: self(),
      supervisor_mod: StubSup,
      template_provider: {Foo, []}
    }

    :ok = ResumeReaper.reap(state)

    assert_receive {:started, "eager_live"}, 1_000
    refute_receive {:started, "eager_registered"}, 200
    refute_receive {:started, "eager_done"}, 200
    refute_receive {:started, "lazy_one"}, 200
  end
end
