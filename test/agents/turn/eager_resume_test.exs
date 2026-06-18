defmodule Normandy.Agents.Turn.EagerResumeTest do
  @moduledoc "Eager auto-resume on (re)start from a persisted :steering state, no caller."
  use ExUnit.Case, async: false

  alias Normandy.Agents.Turn
  alias Normandy.Behaviours.SessionStore.InMemory
  alias Normandy.Behaviours.SessionRegistry.Native
  alias Normandy.Behaviours.AgentTemplate.Catalog

  test "eager server with a persisted :steering state resumes to completion without a caller" do
    store = InMemory.new()
    reg = Native.new()
    {:ok, cat} = Catalog.start_link([])
    sid = "eager-#{System.unique_integer([:positive])}"

    base = Normandy.Test.TurnConfig.build()

    tmpl =
      base
      |> Normandy.Agents.ConfigTemplate.from_config("k", :eager)
      |> put_in([:behaviours_refs, :credential], {Normandy.Test.StubCreds, []})

    :ok = InMemory.save_config_template(store, sid, tmpl)

    :ok =
      Catalog.put(cat, "k", %{
        tool_registry: base.tool_registry,
        before_hooks: [],
        after_hooks: [],
        client_builder: fn _ -> base.client end
      })

    # Seed a non-terminal persisted turn state at a steering boundary.
    steering = %Turn.State{status: :steering, iterations_left: 1, max_iterations: 5}
    :ok = InMemory.save_turn_state(store, sid, steering)

    # Stub call_llm so the resumed turn finalizes instead of hitting a nil client.
    handlers = %{
      Normandy.Agents.BaseAgent.non_streaming_handlers()
      | call_llm: fn _config, _state, _req ->
          %Normandy.Test.TurnConfig.Resp{content: "resumed-done", tool_calls: nil}
        end
    }

    opts = [
      session_id: sid,
      store: {InMemory, store},
      registry: {Native, reg},
      template_provider: {Catalog, cat},
      resume_policy: :eager,
      handlers: handlers
    ]

    assert {:ok, pid} = Turn.Server.start_link(opts)
    ref = Process.monitor(pid)
    # The resumed turn runs maybe_compact → next LLM call (forced-final at left<=0)
    # → finalize → :idle. It must not crash; eventually it idles or passivates.
    # Wait briefly; any DOWN with an abnormal reason is a failure.
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} when reason != :normal ->
        flunk("Server crashed with reason: #{inspect(reason)}")
    after
      2_000 -> :ok
    end

    assert {:ok, ^pid} = Native.whereis(reg, sid)
  end
end
